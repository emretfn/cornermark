import AppKit
import KadrajCore

/// Large countdown digits centred on a display. Keys still reach the session so Escape cancels.
final class CountdownPanel: OverlayWindow {
    private let view: CountdownView

    init(display: DisplayGeometry, host: OverlayHost) {
        let size = CGSize(width: 220, height: 240)
        let frame = CGRect(x: display.frame.midX - size.width / 2, y: display.frame.midY - size.height / 2, width: size.width, height: size.height)
        view = CountdownView(frame: CGRect(origin: .zero, size: size))
        super.init(frame: frame)
        keyHost = host
        contentView = view
    }

    func show(_ remaining: Int) {
        view.remaining = remaining
    }
}

private final class CountdownView: NSView {
    var remaining = 0 { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let card = bounds.insetBy(dx: 16, dy: 16)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
        shadow.shadowBlurRadius = 16
        shadow.shadowOffset = NSSize(width: 0, height: -5)
        shadow.set()
        NSColor(white: 0.1, alpha: 0.92).setFill()
        NSBezierPath(roundedRect: card, xRadius: 28, yRadius: 28).fill()
        NSGraphicsContext.restoreGraphicsState()

        let digit = NSAttributedString(string: "\(remaining)", attributes: [
            .font: NSFont.systemFont(ofSize: 112, weight: .semibold).rounded,
            .foregroundColor: NSColor.white,
        ])
        let ds = digit.size()
        digit.draw(at: CGPoint(x: bounds.midX - ds.width / 2, y: bounds.midY - ds.height / 2 + 12))

        let hint = NSAttributedString(string: "Esc to cancel", attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.55),
        ])
        hint.draw(at: CGPoint(x: bounds.midX - hint.size().width / 2, y: card.minY + 16))
    }
}

private extension NSFont {
    var rounded: NSFont {
        guard let d = fontDescriptor.withDesign(.rounded) else { return self }
        return NSFont(descriptor: d, size: pointSize) ?? self
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
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5), xRadius: 3, yRadius: 3)
        path.lineWidth = 3
        NSColor.controlAccentColor.setStroke()
        path.stroke()
    }
}

final class ScrollHUDPanel: OverlayWindow {
    let hud: ScrollHUDView

    init(near area: CGRect, on display: DisplayGeometry, host: OverlayHost) {
        hud = ScrollHUDView(frame: CGRect(x: 0, y: 0, width: ScrollHUDView.size.width, height: ScrollHUDView.size.height))
        let size = ScrollHUDView.size
        let b = display.frame
        var origin = CGPoint(x: area.midX - size.width / 2, y: area.minY - 14 - size.height)
        if origin.y < b.minY + 8 { origin.y = area.maxY + 14 }
        if origin.y + size.height > b.maxY - 8 { origin.y = area.minY + 14 }
        origin.x = min(max(origin.x, b.minX + 8), b.maxX - size.width - 8)
        super.init(frame: CGRect(origin: origin, size: size))
        keyHost = host
        contentView = hud
    }
}

final class ScrollHUDView: NSView {
    static let size = CGSize(width: 340, height: 150)

    var onDone: (() -> Void)?
    var onCancel: (() -> Void)?
    private var lines = 0
    private var hint = ScrollHint.clear
    private var preview: CGImage?
    private let done = PillButton(title: "Done", prominent: true)
    private let cancel = PillButton(title: "Cancel", prominent: false)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        appearance = NSAppearance(named: .darkAqua)
        done.frame = CGRect(x: frameRect.width - 16 - 76, y: 18, width: 76, height: 28)
        done.target = self; done.action = #selector(doneTapped)
        done.setAccessibilityIdentifier("kadraj.scroll.done")
        cancel.frame = CGRect(x: done.frame.minX - 8 - 76, y: 18, width: 76, height: 28)
        cancel.target = self; cancel.action = #selector(cancelTapped)
        cancel.setAccessibilityIdentifier("kadraj.scroll.cancel")
        addSubview(done)
        addSubview(cancel)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {}

    @objc private func doneTapped() { onDone?() }
    @objc private func cancelTapped() { onCancel?() }

    func apply(_ progress: ScrollProgress, preview: CGImage?) {
        lines = progress.lines
        hint = progress.hint
        if let preview { self.preview = preview }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let card = bounds.insetBy(dx: 8, dy: 8)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.4)
        shadow.shadowBlurRadius = 14
        shadow.shadowOffset = NSSize(width: 0, height: -4)
        shadow.set()
        NSColor(white: 0.12, alpha: 0.95).setFill()
        NSBezierPath(roundedRect: card, xRadius: 14, yRadius: 14).fill()
        NSGraphicsContext.restoreGraphicsState()

        let well = CGRect(x: card.minX + 12, y: card.minY + 12, width: 52, height: card.height - 24)
        NSColor.white.withAlphaComponent(0.08).setFill()
        NSBezierPath(roundedRect: well, xRadius: 6, yRadius: 6).fill()
        if let preview, let ctx = NSGraphicsContext.current?.cgContext {
            let k = min((well.width - 6) / CGFloat(preview.width), (well.height - 6) / CGFloat(preview.height))
            let size = CGSize(width: CGFloat(preview.width) * k, height: CGFloat(preview.height) * k)
            ctx.interpolationQuality = .medium
            ctx.draw(preview, in: CGRect(x: well.midX - size.width / 2, y: well.maxY - 3 - size.height, width: size.width, height: size.height))
        }

        let textX = well.maxX + 14
        NSAttributedString(string: "SCROLLING CAPTURE", attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .semibold), .foregroundColor: NSColor.white.withAlphaComponent(0.5), .kern: 0.6,
        ]).draw(at: CGPoint(x: textX, y: card.maxY - 26))

        let height = NSAttributedString(string: Self.format(lines), attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 24, weight: .semibold), .foregroundColor: NSColor.white,
        ])
        height.draw(at: CGPoint(x: textX, y: card.maxY - 58))

        let (text, color): (String, NSColor) = hint == .scrollSlower
            ? ("Scroll slower, or back up a little", .systemOrange)
            : (lines == 0 ? "Starting" : "Keep scrolling down", NSColor.white.withAlphaComponent(0.55))
        NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 11.5, weight: .medium), .foregroundColor: color])
            .draw(at: CGPoint(x: textX, y: card.maxY - 78))
    }

    private static func format(_ lines: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return (f.string(from: NSNumber(value: lines)) ?? "\(lines)") + " px"
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
