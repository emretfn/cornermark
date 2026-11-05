import AppKit
import CornermarkDesign
import CornermarkCore

enum CardState: Equatable { case visible, hovering, dragging, closing }

enum CardAction: CaseIterable {
    case copy, save, annotate, pin, ocr, play, edit, makeGif, reveal, close

    /// The two small buttons in the image's top corners. The rest sit in one centred row.
    static let corners: Set<CardAction> = [.close, .pin]

    /// What a card offers, in row order, for a picture (nil) or a recording's format. A recording is already saved, so it shows its
    /// file instead of saving one. A project opens in the video editor; a plain video plays and turns into a GIF, since a project's
    /// pointer is not in its video's picture; a GIF plays.
    static func offered(for recording: RecordedVideo.Format?) -> [CardAction] {
        switch recording {
        case nil: return [.copy, .save, .annotate, .ocr, .pin, .close]
        case .video: return [.copy, .play, .makeGif, .reveal, .close]
        case .project: return [.copy, .edit, .reveal, .close]
        case .gif: return [.copy, .play, .reveal, .close]
        }
    }
}

@MainActor
final class QuickAccessCard {
    let id = UUID()
    let record: CaptureRecord
    let image: CGImage
    let thumbnail: CGImage
    var state: CardState = .visible
    /// Seconds left before the card closes by itself; nil keeps it until dismissed.
    var remaining: TimeInterval?
    var actions: [CardAction] { CardAction.offered(for: record.video?.format) }
    var openAction: CardAction { record.opensVideoEditor ? .edit : record.isRecording ? .play : .annotate }
    var info: String {
        guard let video = record.video else { return ImageOutput.dimensionText(CGSize(width: image.width, height: image.height)) }
        let length = "\(ImageOutput.durationText(video.duration))  \u{00B7}  \(ImageOutput.dimensionText(record.pixelSize))"
        return video.format == .gif ? "GIF  \u{00B7}  \(length)" : length
    }

    init(record: CaptureRecord, image: CGImage, thumbnail: CGImage, remaining: TimeInterval?) {
        self.record = record; self.image = image; self.thumbnail = thumbnail; self.remaining = remaining
    }
}

enum QuickAccessLayout {
    static let margin: CGFloat = 16
    static let spacing: CGFloat = 10

    static func cardSize(width: CGFloat) -> CGSize { CGSize(width: width, height: (width * 0.68).rounded()) }

    /// Index 0 sits in the corner; later cards stack away from it.
    static func frames(count: Int, cardSize: CGSize, corner: ScreenCorner, in bounds: CGRect) -> [CGRect] {
        (0..<count).map { i in
            let x = corner.isRight ? bounds.maxX - margin - cardSize.width : bounds.minX + margin
            let step = CGFloat(i) * (cardSize.height + spacing)
            let y = corner.isBottom ? bounds.minY + margin + step : bounds.maxY - margin - cardSize.height - step
            return CGRect(origin: CGPoint(x: x, y: y), size: cardSize)
        }
    }
}

final class QuickAccessPanel: NSPanel {
    init(frame: CGRect) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The ordered stack of Quick Access cards on the display with the cursor.
@MainActor
final class QuickAccessManager {
    private let env: AppEnvironment
    private let settings: () -> Settings
    var perform: (CardAction, QuickAccessCard) -> Void = { _, _ in }

    private(set) var stack: [QuickAccessCard] = []
    private(set) var recentlyClosed: [QuickAccessCard] = []
    private(set) var isHidden = false
    private var panels: [UUID: QuickAccessPanel] = [:]
    private var lastTick: Date
    private var timer: Timer?
    static let recentLimit = 10

    init(env: AppEnvironment, settings: @escaping () -> Settings) {
        self.env = env
        self.settings = settings
        lastTick = env.clock()
    }

    func panel(for card: QuickAccessCard) -> QuickAccessPanel? { panels[card.id] }
    func cardView(for card: QuickAccessCard) -> QuickAccessCardView? { panels[card.id]?.contentView as? QuickAccessCardView }
    func card(forRecord id: UUID) -> QuickAccessCard? { stack.first { $0.record.id == id } }

    // MARK: Lifecycle

    @discardableResult
    func add(record: CaptureRecord, image: CGImage) -> QuickAccessCard {
        if stack.isEmpty { lastTick = env.clock() }
        let card = QuickAccessCard(record: record, image: image, thumbnail: Thumbnailer.make(image, maxPixel: 640),
                                   remaining: settings().overlayAutoClose)
        setHidden(false)
        insert(card, animated: true)
        return card
    }

    func close(_ card: QuickAccessCard) {
        guard let i = stack.firstIndex(where: { $0.id == card.id }) else { return }
        card.state = .closing
        stack.remove(at: i)
        recentlyClosed.append(card)
        if recentlyClosed.count > Self.recentLimit { recentlyClosed.removeFirst() }
        if let panel = panels.removeValue(forKey: card.id) { dismiss(panel) }
        relayout(animated: true)
        stopTimerIfIdle()
    }

    func closeAll() { for card in stack { close(card) } }

    /// Brings back the most recently closed card, unless it is already showing.
    @discardableResult
    func restoreLast() -> QuickAccessCard? {
        while let card = recentlyClosed.popLast() {
            guard card.state == .closing, self.card(forRecord: card.record.id) == nil else { continue }
            card.state = .visible
            card.remaining = settings().overlayAutoClose
            if stack.isEmpty { lastTick = env.clock() }
            setHidden(false)
            insert(card, animated: true)
            return card
        }
        return nil
    }

    func setHidden(_ hidden: Bool) {
        guard hidden != isHidden else { return }
        isHidden = hidden
        if !hidden { lastTick = env.clock() }
        relayout(animated: false)
    }

    func toggleHidden() { setHidden(!isHidden) }

    // MARK: Interaction state

    func setHovering(_ card: QuickAccessCard, _ hovering: Bool) {
        guard card.state == .visible || card.state == .hovering else { return }
        card.state = hovering ? .hovering : .visible
    }

    func beginDrag(_ card: QuickAccessCard) { if card.state != .closing { card.state = .dragging } }

    /// A card that landed somewhere closes; one dropped on nothing stays.
    func endDrag(_ card: QuickAccessCard, dropped: Bool) {
        guard card.state == .dragging else { return }
        card.state = .visible
        if dropped { close(card) }
    }

    /// Cards count down only while idle: hovering, dragging and hidden overlays pause the timer.
    func tick() {
        let now = env.clock()
        let dt = max(0, now.timeIntervalSince(lastTick))
        lastTick = now
        guard !isHidden else { return }
        var expired: [QuickAccessCard] = []
        for card in stack where card.state == .visible {
            guard let left = card.remaining else { continue }
            card.remaining = left - dt
            if left - dt <= 0 { expired.append(card) }
        }
        expired.forEach(close)
    }

    func settingsChanged() {
        for card in stack where card.remaining != nil { card.remaining = settings().overlayAutoClose }
        for card in stack { cardView(for: card)?.setCardSize(QuickAccessLayout.cardSize(width: settings().overlaySize.cardWidth)) }
        relayout(animated: false)
    }

    // MARK: Windows

    private func insert(_ card: QuickAccessCard, animated: Bool) {
        stack.insert(card, at: 0)
        let size = QuickAccessLayout.cardSize(width: settings().overlaySize.cardWidth)
        let view = QuickAccessCardView(card: card, size: size)
        wire(view, card)
        let panel = QuickAccessPanel(frame: CGRect(origin: .zero, size: size))
        panel.contentView = view
        panels[card.id] = panel
        relayout(animated: false)
        if env.isOnscreen && !isHidden && animated { springIn(panel) }
        startTimerIfNeeded()
    }

    private func wire(_ view: QuickAccessCardView, _ card: QuickAccessCard) {
        view.onAction = { [weak self] action in
            guard let self else { return }
            action == .close ? self.close(card) : self.perform(action, card)
        }
        view.onHover = { [weak self] hovering in self?.setHovering(card, hovering) }
        view.onDragBegan = { [weak self] in self?.beginDrag(card) }
        view.onDragEnded = { [weak self] dropped in self?.endDrag(card, dropped: dropped) }
        view.onSwipeDismiss = { [weak self] in self?.close(card) }
        view.dragFile = { [weak self] in self?.dragFile(for: card) }
        view.swipeDirection = { [weak self] in (self?.settings().overlayCorner.isRight ?? true) ? 1 : -1 }
    }

    func relayout(animated: Bool) {
        let bounds = env.cursorScreenFrame()
        let size = QuickAccessLayout.cardSize(width: settings().overlaySize.cardWidth)
        let frames = QuickAccessLayout.frames(count: stack.count, cardSize: size, corner: settings().overlayCorner, in: bounds)
        for (card, frame) in zip(stack, frames) {
            guard let panel = panels[card.id] else { continue }
            let fits = bounds.contains(frame)
            if animated && env.isOnscreen && panel.isVisible && !DS.Motion.isReduced {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = DS.Motion.Duration.base
                    ctx.timingFunction = DS.Motion.Curve.easeOut
                    panel.animator().setFrame(frame, display: true)
                }
            } else {
                panel.setFrame(frame, display: false)
            }
            guard env.isOnscreen else { continue }
            if fits && !isHidden { panel.orderFrontRegardless() } else { panel.orderOut(nil) }
        }
    }

    private func springIn(_ panel: QuickAccessPanel) {
        guard let layer = panel.contentView?.layer else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0; fade.toValue = 1; fade.duration = DS.Motion.Duration.fast
        layer.add(fade, forKey: "fadeIn")
        guard !DS.Motion.isReduced else { return }
        let cx = layer.bounds.midX, cy = layer.bounds.midY
        let ax = layer.anchorPoint.x * layer.bounds.width, ay = layer.anchorPoint.y * layer.bounds.height
        var from = CATransform3DMakeTranslation(cx - ax, cy - ay, 0)
        from = CATransform3DScale(from, DS.Motion.enterScale, DS.Motion.enterScale, 1)
        from = CATransform3DTranslate(from, ax - cx, ay - cy, 0)
        let spring = CASpringAnimation(keyPath: "transform")
        spring.fromValue = NSValue(caTransform3D: from)
        spring.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        spring.mass = 1; spring.stiffness = 320
        spring.damping = 2 * (spring.stiffness * spring.mass).squareRoot()
        spring.duration = spring.settlingDuration
        layer.add(spring, forKey: "springIn")
    }

    private func dismiss(_ panel: QuickAccessPanel) {
        guard env.isOnscreen, panel.isVisible else { panel.close(); return }
        let reduced = DS.Motion.isReduced
        let toward: CGFloat = settings().overlayCorner.isRight ? 1 : -1
        var target = panel.frame
        target.origin.x += toward * (panel.frame.width + QuickAccessLayout.margin)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = DS.Motion.Duration.fast
            ctx.timingFunction = DS.Motion.Curve.easeOut
            if !reduced { panel.animator().setFrame(target, display: true) }
            panel.animator().alphaValue = 0
        }, completionHandler: { panel.close() })
    }

    // MARK: Drag file

    /// A copy of the capture under a readable name, so the receiving app gets `Cornermark ... .png`. A recording drags its own video file.
    func dragFile(for card: QuickAccessCard) -> URL? {
        let fm = FileManager.default
        if let video = card.record.video { return fm.fileExists(atPath: video.file.path) ? video.file : nil }
        try? fm.createDirectory(at: env.dragDirectory, withIntermediateDirectories: true)
        let url = ImageOutput.uniqueURL(in: env.dragDirectory, for: card.record.createdAt, format: .png)
        if (try? fm.copyItem(at: env.store.paths(for: card.record).image, to: url)) != nil { return url }
        guard let png = AssetStore.pngData(from: card.image), (try? png.write(to: url)) != nil else { return nil }
        return url
    }

    // MARK: Timer

    private func startTimerIfNeeded() {
        guard env.isOnscreen, timer == nil, !stack.isEmpty else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func stopTimerIfIdle() {
        guard stack.isEmpty else { return }
        timer?.invalidate()
        timer = nil
    }
}

enum Thumbnailer {
    /// Aspect-preserving downscale to at most `maxPixel` on the long side; never upscales.
    static func make(_ image: CGImage, maxPixel: Int) -> CGImage {
        let longSide = max(image.width, image.height)
        guard longSide > maxPixel else { return image }
        let scale = Double(maxPixel) / Double(longSide)
        let w = max(1, Int((Double(image.width) * scale).rounded())), h = max(1, Int((Double(image.height) * scale).rounded()))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage() ?? image
    }
}
