import AppKit
import CornermarkCore
import CornermarkDesign
import CornermarkL10n

/// Large countdown digits centred on a display. Keys still reach the session so Escape cancels.
final class CountdownPanel: OverlayWindow {
    private let view: CountdownView

    init(display: DisplayGeometry, host: OverlayHost) {
        let size = CountdownView.size
        let frame = CGRect(x: display.frame.midX - size.width / 2, y: display.frame.midY - size.height / 2, width: size.width, height: size.height)
        view = CountdownView(frame: CGRect(origin: .zero, size: size), hint: tr("Esc to cancel"))
        super.init(frame: frame)
        keyHost = host
        contentView = view
        view.applyLanguageDirection()
    }

    func show(_ remaining: Int) {
        view.remaining = remaining
    }
}

/// Large digits on a card, with a short line under them. A capture's timer and a recording's countdown both use it.
public final class CountdownView: NSView {
    /// The card plus the transparent margin that holds the `hud` elevation's shadow.
    static let inset = DS.Space.s32
    static let card = CGSize(width: 160, height: 160)
    public static let size = CGSize(width: card.width + 2 * inset, height: card.height + 2 * inset)

    public var remaining = 0 { didSet { needsDisplay = true } }
    public let hint: String

    public init(frame: CGRect, hint: String) {
        self.hint = hint
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError("CountdownView is created in code") }

    public override func draw(_ dirtyRect: NSRect) {
        let card = bounds.insetBy(dx: Self.inset, dy: Self.inset)
        DS.Elevation.hud.draw(NSBezierPath.continuous(card, radius: DS.Radius.xl), fill: DS.Color.bgHud)

        let hint = DS.Text.label
        let hintBox = CGRect(x: card.minX, y: card.minY + DS.Space.s16, width: card.width, height: hint.lineHeight)
        let digit = DS.Text.numeral
        let digitBox = CGRect(x: card.minX, y: hintBox.maxY + DS.Space.s8, width: card.width, height: digit.lineHeight)
        for (text, style, color, box) in [(Readout.number(remaining), digit, DS.Color.textPrimary, digitBox), (self.hint, hint, DS.Color.textSecondary, hintBox)] {
            var attributes = style.attributes(color: color)
            let paragraph = (attributes[.paragraphStyle] as! NSParagraphStyle).mutableCopy() as! NSMutableParagraphStyle
            paragraph.alignment = .center
            attributes[.paragraphStyle] = paragraph
            (text as NSString).draw(with: box, options: .usesLineFragmentOrigin, attributes: attributes)
        }
    }
}

/// Click-through border around the area being scrolled.
final class ScrollFramePanel: OverlayWindow {
    init(area: CGRect) {
        let outset: CGFloat = 4
        let frame = area.insetBy(dx: -outset, dy: -outset)
        super.init(frame: frame)
        ignoresMouseEvents = true
        contentView = ScrollFrameView(frame: CGRect(origin: .zero, size: frame.size))
    }
}

private final class ScrollFrameView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let halo = NSBezierPath.continuous(bounds.insetBy(dx: 1.5, dy: 1.5), radius: DS.Radius.xs)
        halo.lineWidth = 3
        DS.Color.selectionHalo.setStroke()
        halo.stroke()
        let line = NSBezierPath.continuous(bounds.insetBy(dx: 2, dy: 2), radius: DS.Radius.xs)
        line.lineWidth = 2
        DS.Color.accentSolid.setStroke()
        line.stroke()
    }
}

final class ScrollHUDPanel: OverlayWindow {
    let hud: ScrollHUDView

    init(near area: CGRect, on display: DisplayGeometry, host: OverlayHost) {
        let view = ScrollHUDView(frame: .zero)
        hud = view
        let card = ScrollHUDView.card
        let b = display.frame
        // The gap equals the shadow margin, so the window never lies over the area and swallows its scroll events.
        let gap = ScrollHUDView.inset
        var origin = CGPoint(x: area.midX - card.width / 2, y: area.minY - gap - card.height)
        if origin.y < b.minY + 8 { origin.y = area.maxY + gap }
        if origin.y + card.height > b.maxY - 8 { origin.y = area.minY + gap }
        origin.x = min(max(origin.x, b.minX + 8), b.maxX - card.width - 8)
        // The window carries the shadow margin, and a window must not straddle displays, so the margin is clamped too.
        let margin = ScrollHUDView.inset, size = view.frame.size
        let window = CGPoint(x: min(max(origin.x - margin, b.minX), b.maxX - size.width), y: min(max(origin.y - margin, b.minY), b.maxY - size.height))
        super.init(frame: CGRect(origin: window, size: size))
        keyHost = host
        contentView = view
    }
}

final class ScrollHUDView: Surface {
    static let inset = DS.Space.s32
    static let card = CGSize(width: 340, height: 124)
    static let size = CGSize(width: card.width + 2 * inset, height: card.height + 2 * inset)

    var onDone: (() -> Void)?
    var onCancel: (() -> Void)?
    private var preview: CGImage?
    private var progress = ScrollProgress()
    private var languageObserver: NSObjectProtocol?
    private let done = Button(title: tr("Done"), variant: .primary)
    private let cancel = Button(title: tr("Cancel"), variant: .secondary)
    private let title = NSTextField.label(tr("Scrolling capture"), style: DS.Text.captionStrong, color: DS.Color.textSecondary)
    private let height = NSTextField.label("", style: DS.Text.readoutLarge, color: DS.Color.textPrimary)
    private let hintIcon = NSImageView()
    private let hintText = NSTextField.label("", style: DS.Text.caption, color: DS.Color.textSecondary)
    private var leftToRight = LeftToRightFrames()
    /// Where the text column starts, laid out left to right.
    private var textX: CGFloat = 0
    private var leftToRightWell: CGRect { contentRect.insetBy(dx: DS.Space.s12, dy: DS.Space.s12).divided(atDistance: 52, from: .minXEdge).slice }
    /// The preview's well sits first in reading order, so on the right in a right-to-left language. The picture in it is never mirrored.
    private var well: CGRect { mirrored(leftToRightWell) }

    init(frame frameRect: NSRect) {
        super.init(style: .hud, shadowInset: Self.inset)
        setFrameSize(Self.size)

        let card = contentRect
        textX = leftToRightWell.maxX + DS.Space.s12
        let textWidth = card.maxX - DS.Space.s12 - textX
        title.frame = CGRect(x: textX, y: card.maxY - DS.Space.s12 - DS.Text.captionStrong.lineHeight, width: textWidth, height: DS.Text.captionStrong.lineHeight)
        height.frame = CGRect(x: textX, y: title.frame.minY - DS.Space.s2 - DS.Text.readoutLarge.lineHeight, width: textWidth, height: DS.Text.readoutLarge.lineHeight)
        hintIcon.symbolConfiguration = .init(pointSize: DS.Size.iconSmall, weight: .medium)
        hintIcon.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: tr("Warning"))
        hintIcon.contentTintColor = DS.Color.warningText
        hintIcon.frame = CGRect(x: textX, y: height.frame.minY - DS.Space.s4 - DS.Text.caption.lineHeight, width: DS.Size.iconSmall, height: DS.Text.caption.lineHeight)
        hintText.frame = CGRect(x: textX, y: hintIcon.frame.minY, width: textWidth, height: DS.Text.caption.lineHeight)

        done.target = self; done.action = #selector(doneTapped)
        done.setAccessibilityIdentifier("cornermark.scroll.done")
        cancel.target = self; cancel.action = #selector(cancelTapped)
        cancel.setAccessibilityIdentifier("cornermark.scroll.cancel")
        for v in [title, height, hintIcon, hintText, done, cancel] as [NSView] { addSubview(v) }
        layoutButtons()
        apply(ScrollProgress(), preview: nil)
        leftToRight.record(in: self)
        applyLanguageDirection()
        leftToRight.apply(to: self)
        languageObserver = NotificationCenter.default.addObserver(forName: L10n.didChange, object: nil, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { self?.languageChanged() }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let languageObserver { NotificationCenter.default.removeObserver(languageObserver) }
    }

    /// Done sits at the end of the card and Cancel before it, each as wide as its title, so a new language lays them out again.
    private func layoutButtons() {
        let card = contentRect
        for button in [done, cancel] { button.frame.size = button.intrinsicContentSize }
        let doneFrame = CGRect(origin: CGPoint(x: card.maxX - DS.Space.s12 - done.frame.width, y: card.minY + DS.Space.s12), size: done.frame.size)
        place(done, ltr: doneFrame)
        place(cancel, ltr: CGRect(origin: CGPoint(x: doneFrame.minX - DS.Space.s8 - cancel.frame.width, y: doneFrame.minY), size: cancel.frame.size))
    }

    private func place(_ view: NSView, ltr: CGRect) {
        view.frame = mirrored(ltr)
        leftToRight.record(view, in: self)
    }

    /// The card is on screen while a capture scrolls, so a language switch re-words it in place and keeps its progress and preview.
    private func languageChanged() {
        title.stringValue = tr("Scrolling capture")
        done.title = tr("Done")
        cancel.title = tr("Cancel")
        done.setAccessibilityLabel(done.title)
        cancel.setAccessibilityLabel(cancel.title)
        hintIcon.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: tr("Warning"))
        layoutButtons()
        apply(progress, preview: nil)
        applyLanguageDirection()
        needsDisplay = true
    }

    override var userInterfaceLayoutDirection: NSUserInterfaceLayoutDirection {
        didSet { leftToRight.apply(to: self) }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {}

    @objc private func doneTapped() { onDone?() }
    @objc private func cancelTapped() { onCancel?() }

    func apply(_ progress: ScrollProgress, preview: CGImage?) {
        if let preview { self.preview = preview }
        self.progress = progress
        height.stringValue = Self.format(progress.lines)
        let warning = progress.hint == .scrollSlower
        // The warning never rides on colour alone: it keeps its own symbol and wording.
        hintIcon.isHidden = !warning
        hintText.textColor = warning ? DS.Color.warningText : DS.Color.textSecondary
        hintText.stringValue = warning ? tr("Scroll slower, or back up a little") : (progress.lines == 0 ? tr("Starting") : tr("Keep scrolling down"))
        let hintX = warning ? textX + DS.Size.iconSmall + DS.Space.s4 : textX
        hintText.frame = mirrored(CGRect(x: hintX, y: hintText.frame.minY, width: contentRect.maxX - DS.Space.s12 - hintX, height: hintText.frame.height))
        leftToRight.record(hintText, in: self)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let well = self.well
        DS.Color.bgControl.setFill()
        NSBezierPath.continuous(well, radius: DS.Radius.sm).fill()
        if let preview, let ctx = NSGraphicsContext.current?.cgContext {
            let k = min((well.width - 6) / CGFloat(preview.width), (well.height - 6) / CGFloat(preview.height))
            let size = CGSize(width: CGFloat(preview.width) * k, height: CGFloat(preview.height) * k)
            ctx.interpolationQuality = .medium
            ctx.draw(preview, in: CGRect(x: well.midX - size.width / 2, y: well.maxY - 3 - size.height, width: size.width, height: size.height))
        }
    }

    private static func format(_ lines: Int) -> String {
        tr("{lines} px", ["lines": lines])
    }
}

/// Polls the live screen, feeds the stitcher, and owns the border and HUD windows.
@MainActor
final class ScrollCapture {
    private let source: ScreenSource
    let area: ScrollArea
    private weak var host: CaptureSession?
    private var stitcher = ScrollStitcher()
    private var task: Task<Void, Never>?
    private var lastPreview = Date.distantPast
    private let frame: ScrollFramePanel
    let hudPanel: ScrollHUDPanel

    /// Stops runaway capture well under the stitcher's pixel ceiling.
    private let lineLimit = 40_000

    init(area: ScrollArea, source: ScreenSource, host: CaptureSession) {
        self.area = area
        self.source = source
        self.host = host
        frame = ScrollFramePanel(area: area.rect)
        hudPanel = ScrollHUDPanel(near: area.rect, on: area.display, host: host)
        hudPanel.hud.onDone = { [weak host] in host?.send(.toolbar(.done)) }
        hudPanel.hud.onCancel = { [weak host] in host?.send(.keyDown(.escape, [])) }
    }

    var windows: [NSWindow] { [frame, hudPanel] }

    func start(interval: TimeInterval, present: Bool) {
        if present {
            frame.orderFrontRegardless()
            hudPanel.makeKeyAndOrderFront(nil)
        }
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.poll()
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        frame.orderOut(nil); frame.close()
        hudPanel.orderOut(nil); hudPanel.close()
    }

    var image: CGImage? { stitcher.image }

    func update(_ progress: ScrollProgress) {
        hudPanel.hud.apply(progress, preview: nil)
    }

    private func poll() async {
        do {
            let snap = try await source.capture(displayID: area.display.id)
            guard !Task.isCancelled, let crop = ImageCrop.crop(snap, rect: area.rect) else { return }
            let outcome = stitcher.add(crop)
            let lines = stitcher.lineCount
            var preview: CGImage?
            if case .appended = outcome, Date().timeIntervalSince(lastPreview) > 0.4 {
                lastPreview = Date()
                preview = stitcher.image
            }
            host?.send(.scroll(outcome, lines: lines))
            if let preview, case .scrollingCapture(_, let progress) = host?.machine.state { hudPanel.hud.apply(progress, preview: preview) }
            if lines >= lineLimit { host?.send(.toolbar(.done)) }
        } catch {
            host?.fail(error)
        }
    }
}
