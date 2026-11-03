import AppKit

@MainActor
protocol OverlayHost: AnyObject {
    var machine: SelectionMachine { get }
    /// Global frame of the visible toolbar, so other chrome can stay out from under it.
    var toolbarPill: CGRect? { get }
    func send(_ input: Input)
    /// True when the host consumed the event.
    func handleKey(_ event: NSEvent) -> Bool
}

extension Modifiers {
    init(_ flags: NSEvent.ModifierFlags) {
        var m: Modifiers = []
        if flags.contains(.shift) { m.insert(.shift) }
        if flags.contains(.option) { m.insert(.option) }
        if flags.contains(.command) { m.insert(.command) }
        self = m
    }
}

extension Key {
    init?(_ event: NSEvent) {
        switch event.keyCode {
        case 53: self = .escape
        case 36, 76: self = .confirm
        case 49: self = .space
        case 123: self = .arrow(.left)
        case 124: self = .arrow(.right)
        case 125: self = .arrow(.down)
        case 126: self = .arrow(.up)
        default: return nil
        }
    }
}

/// Borderless, non-activating, and above the menu bar and Dock. Key handling is intercepted in
/// `sendEvent` so Escape works whatever has focus, including the toolbar's text fields.
class OverlayWindow: NSPanel {
    weak var keyHost: OverlayHost?

    init(frame: CGRect) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        isMovable = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        setFrame(frame, display: false)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    /// AppKit drops mouse events for a window that was never ordered in. Route them by hand so an
    /// offscreen window (tests) behaves like a visible one.
    private var mouseTarget: NSView?

    override func sendEvent(_ event: NSEvent) {
        if !isVisible, let content = contentView {
            switch event.type {
            case .leftMouseDown:
                mouseTarget = content.hitTest(content.convert(event.locationInWindow, from: nil))
                mouseTarget?.mouseDown(with: event)
                return
            case .leftMouseDragged:
                mouseTarget?.mouseDragged(with: event)
                return
            case .leftMouseUp:
                mouseTarget?.mouseUp(with: event)
                mouseTarget = nil
                return
            default: break
            }
        }
        switch event.type {
        case .keyDown, .keyUp:
            let editing = firstResponder is NSText
            let isEscape = event.keyCode == 53
            if (isEscape || !editing), !event.modifierFlags.contains(.command), keyHost?.handleKey(event) == true { return }
        case .flagsChanged:
            _ = keyHost?.handleKey(event)
        default: break
        }
        super.sendEvent(event)
    }
}

final class OverlayPanel: OverlayWindow {
    let display: DisplaySnapshot
    let chrome: ChromeView

    init(display: DisplaySnapshot, host: OverlayHost) {
        self.display = display
        let bounds = CGRect(origin: .zero, size: display.frame.size)
        let root = NSView(frame: bounds)
        root.wantsLayer = true
        let backdrop = BackdropView(frame: bounds, image: display.image)
        chrome = ChromeView(frame: bounds, display: display, host: host)
        root.addSubview(backdrop)
        root.addSubview(chrome)
        super.init(frame: display.frame)
        keyHost = host
        contentView = root
        acceptsMouseMovedEvents = true
        initialFirstResponder = chrome
    }

    var root: NSView { contentView! }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .mouseMoved {
            chrome.mouseMoved(with: event)
            return
        }
        super.sendEvent(event)
    }
}

final class BackdropView: NSView {
    private let image: CGImage

    init(frame: CGRect, image: CGImage) {
        self.image = image
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isOpaque: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.interpolationQuality = .none
        ctx.draw(image, in: bounds)
    }
}

struct LoupeSample {
    var patch: CGImage
    var hex: String
    var color: NSColor
}

enum Loupe {
    static let radius = 7

    /// `center` is a pixel in top-left image coordinates. Pixels outside the image come out transparent.
    static func sample(_ image: CGImage, center: (x: Int, y: Int)) -> LoupeSample? {
        let n = radius * 2 + 1
        guard let ctx = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .none
        let want = CGRect(x: center.x - radius, y: center.y - radius, width: n, height: n)
        let visible = want.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        if !visible.isNull, let crop = image.cropping(to: visible) {
            ctx.draw(crop, in: CGRect(x: visible.minX - want.minX, y: CGFloat(n) - (visible.minY - want.minY) - visible.height,
                                      width: visible.width, height: visible.height))
        }
        guard let data = ctx.data, let patch = ctx.makeImage() else { return nil }
        let p = data.advanced(by: radius * ctx.bytesPerRow + radius * 4).assumingMemoryBound(to: UInt8.self)
        let hex = String(format: "#%02X%02X%02X", p[0], p[1], p[2])
        let color = NSColor(srgbRed: CGFloat(p[0]) / 255, green: CGFloat(p[1]) / 255, blue: CGFloat(p[2]) / 255, alpha: 1)
        return LoupeSample(patch: patch, hex: hex, color: color)
    }
}

final class ChromeView: NSView {
    let display: DisplaySnapshot
    private weak var host: OverlayHost?

    init(frame: CGRect, display: DisplaySnapshot, host: OverlayHost) {
        self.display = display
        self.host = host
        super.init(frame: frame)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect, .cursorUpdate], owner: self))
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func global(_ event: NSEvent) -> CGPoint {
        window?.convertPoint(toScreen: event.locationInWindow) ?? event.locationInWindow
    }

    override func mouseMoved(with event: NSEvent) {
        host?.send(.move(global(event)))
        updateCursor()
    }

    override func cursorUpdate(with event: NSEvent) { updateCursor() }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        host?.send(.down(global(event), Modifiers(event.modifierFlags)))
        updateCursor()
    }

    override func mouseDragged(with event: NSEvent) {
        host?.send(.drag(global(event), Modifiers(event.modifierFlags)))
        updateCursor()
    }

    override func mouseUp(with event: NSEvent) {
        host?.send(.up(global(event), Modifiers(event.modifierFlags)))
        updateCursor()
    }

    func updateCursor() {
        guard let m = host?.machine else { return }
        desiredCursor(m).set()
    }

    private func desiredCursor(_ m: SelectionMachine) -> NSCursor {
        switch m.state {
        case .windowHover: return .pointingHand
        case .adjusting(_, let gesture):
            if case .move? = gesture { return .closedHand }
            switch m.hitZone(at: m.cursor) {
            case .inside: return .openHand
            case .outside: return .crosshair
            case .handle(let h):
                switch h {
                case .left, .right: return .resizeLeftRight
                case .top, .bottom: return .resizeUpDown
                default: return .crosshair
                }
            }
        default: return .crosshair
        }
    }

    // MARK: Drawing

    private func local(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x - display.frame.minX, y: p.y - display.frame.minY) }
    private func local(_ r: CGRect) -> CGRect { r.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY) }

    override func draw(_ dirtyRect: NSRect) {
        guard let host, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let m = host.machine
        let cursorHere = m.cursorDisplay?.id == display.displayID

        switch m.state {
        case .armed:
            if cursorHere { drawCrosshair(local(m.cursor)); drawLoupe(ctx, at: local(m.cursor)) }
        case .dragging(let d):
            drawSelectionPart(d.rect, handles: false, machine: m)
            if cursorHere { drawCrosshair(local(m.cursor)); drawLoupe(ctx, at: local(m.cursor)) }
        case .adjusting(let sel, let gesture):
            drawSelectionPart(sel.rect, handles: true, machine: m)
            if case .resize? = gesture, cursorHere { drawLoupe(ctx, at: local(m.cursor)) }
        case .windowHover(let w):
            let r = w.map { local($0.frame).intersection(bounds) }
            drawDim(except: r.flatMap { $0.isNull ? nil : $0 })
            if let w, let r, !r.isNull { drawWindowHighlight(r, window: w) }
        default: break
        }
    }

    /// The selection spans panels, so each panel draws only what falls on it: its dim with a hole, the border
    /// and any handle landing here, and the one size badge if this panel carries it.
    private func drawSelectionPart(_ r: CGRect, handles: Bool, machine m: SelectionMachine) {
        let rect = local(r)
        let visible = rect.intersection(bounds)
        drawDim(except: visible.isEmpty ? nil : visible)
        if rect.insetBy(dx: -2, dy: -2).intersects(bounds) { drawSelection(rect, handles: handles) }
        if !visible.isEmpty, m.chromeDisplay(for: r)?.id == display.displayID {
            drawBadge(text: "\(Int(r.width.rounded())) × \(Int(r.height.rounded()))", anchoredTo: visible)
        }
    }

    private func drawDim(except hole: CGRect?) {
        let path = NSBezierPath(rect: bounds)
        if let hole { path.appendRect(hole) }
        path.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.5).setFill()
        path.fill()
    }

    private func drawSelection(_ r: CGRect, handles: Bool) {
        let outer = NSBezierPath(rect: r.insetBy(dx: -1.5, dy: -1.5))
        outer.lineWidth = 1
        NSColor.black.withAlphaComponent(0.35).setStroke()
        outer.stroke()
        let line = NSBezierPath(rect: r.insetBy(dx: -0.5, dy: -0.5))
        line.lineWidth = 1
        NSColor.white.setStroke()
        line.stroke()
        guard handles else { return }
        for h in Handle.allCases {
            let c = h.position(on: r)
            let dotRect = CGRect(x: c.x - 4.5, y: c.y - 4.5, width: 9, height: 9)
            guard dotRect.intersects(bounds) else { continue }
            let dot = NSBezierPath(ovalIn: dotRect)
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
            shadow.shadowBlurRadius = 3
            shadow.shadowOffset = NSSize(width: 0, height: -1)
            shadow.set()
            NSColor.white.setFill()
            dot.fill()
            NSGraphicsContext.restoreGraphicsState()
            NSColor.black.withAlphaComponent(0.3).setStroke()
            dot.lineWidth = 0.75
            dot.stroke()
        }
    }

    private static let pillFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)

    @discardableResult
    private func drawPill(_ text: String, at origin: CGPoint, tint: NSColor = NSColor.black.withAlphaComponent(0.78)) -> CGRect {
        let attrs: [NSAttributedString.Key: Any] = [.font: Self.pillFont, .foregroundColor: NSColor.white]
        let size = (text as NSString).size(withAttributes: attrs)
        let rect = CGRect(x: origin.x, y: origin.y, width: ceil(size.width) + 16, height: 22)
        tint.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 11, yRadius: 11).fill()
        (text as NSString).draw(at: CGPoint(x: rect.minX + 8, y: rect.minY + (rect.height - size.height) / 2), withAttributes: attrs)
        return rect
    }

    private func drawBadge(text: String, anchoredTo r: CGRect) {
        let size = CGSize(width: (text as NSString).size(withAttributes: [.font: Self.pillFont]).width + 16, height: 22)
        let avoid = host?.toolbarPill.map { local($0).insetBy(dx: -6, dy: -6) }
        let x = min(max(r.minX, bounds.minX + 4), bounds.maxX - size.width - 4)
        let candidates = [CGPoint(x: x, y: r.maxY + 7), CGPoint(x: x, y: r.minY - 7 - size.height), CGPoint(x: x + 6, y: r.maxY - 28)]
        let fits = candidates.first {
            let box = CGRect(origin: $0, size: size)
            return bounds.insetBy(dx: 2, dy: 2).contains(box) && !(avoid?.intersects(box) ?? false)
        }
        drawPill(text, at: fits ?? candidates[2])
    }

    private func drawWindowHighlight(_ r: CGRect, window w: WindowSnapshot) {
        NSColor.controlAccentColor.withAlphaComponent(0.28).setFill()
        r.fill()
        let border = NSBezierPath(rect: r.insetBy(dx: 1, dy: 1))
        border.lineWidth = 2
        NSColor.controlAccentColor.setStroke()
        border.stroke()
        let text = [w.appName, "\(Int(w.frame.width.rounded())) × \(Int(w.frame.height.rounded()))"].filter { !$0.isEmpty }.joined(separator: "  ")
        let width = (text as NSString).size(withAttributes: [.font: Self.pillFont]).width + 16
        drawPill(text, at: CGPoint(x: r.midX - width / 2, y: r.midY - 11))
    }

    private func drawCrosshair(_ c: CGPoint) {
        let h = NSBezierPath(), v = NSBezierPath()
        h.move(to: CGPoint(x: bounds.minX, y: c.y)); h.line(to: CGPoint(x: bounds.maxX, y: c.y))
        v.move(to: CGPoint(x: c.x, y: bounds.minY)); v.line(to: CGPoint(x: c.x, y: bounds.maxY))
        for (path, color, width) in [(h, NSColor.black.withAlphaComponent(0.28), 3.0), (v, NSColor.black.withAlphaComponent(0.28), 3.0),
                                     (h, NSColor.white.withAlphaComponent(0.85), 1.0), (v, NSColor.white.withAlphaComponent(0.85), 1.0)] {
            path.lineWidth = CGFloat(width)
            color.setStroke()
            path.stroke()
        }
    }

    private func drawLoupe(_ ctx: CGContext, at c: CGPoint) {
        let n = Loupe.radius * 2 + 1, cell: CGFloat = 9, side = CGFloat(n) * cell, infoH: CGFloat = 44, gap: CGFloat = 24
        let s = display.scale
        let px = min(max(Int(floor(c.x * s)), 0), display.image.width - 1)
        let py = min(max(Int(floor((bounds.height - c.y) * s)), 0), display.image.height - 1)
        guard let sample = Loupe.sample(display.image, center: (px, py)) else { return }

        var origin = CGPoint(x: c.x + gap, y: c.y - gap - side - infoH)
        if origin.x + side > bounds.maxX - 6 { origin.x = c.x - gap - side }
        if origin.y < bounds.minY + 6 { origin.y = c.y + gap }
        origin.x = max(origin.x, bounds.minX + 6)
        origin.y = min(origin.y, bounds.maxY - side - infoH - 6)
        let total = CGRect(x: origin.x, y: origin.y, width: side, height: side + infoH)
        let picture = CGRect(x: origin.x, y: origin.y + infoH, width: side, height: side)
        let shape = NSBezierPath(roundedRect: total, xRadius: 12, yRadius: 12)

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.5)
        shadow.shadowBlurRadius = 14
        shadow.shadowOffset = NSSize(width: 0, height: -4)
        shadow.set()
        NSColor(white: 0.1, alpha: 1).setFill()
        shape.fill()
        NSGraphicsContext.restoreGraphicsState()

        ctx.saveGState()
        shape.addClip()
        ctx.interpolationQuality = .none
        ctx.draw(sample.patch, in: picture)
        for i in 0...n {
            let t = CGFloat(i) * cell
            let v = NSBezierPath(), h = NSBezierPath()
            v.move(to: CGPoint(x: picture.minX + t, y: picture.minY)); v.line(to: CGPoint(x: picture.minX + t, y: picture.maxY))
            h.move(to: CGPoint(x: picture.minX, y: picture.minY + t)); h.line(to: CGPoint(x: picture.maxX, y: picture.minY + t))
            for p in [v, h] { p.lineWidth = 0.5; NSColor.black.withAlphaComponent(0.22).setStroke(); p.stroke() }
        }
        let centerCell = CGRect(x: picture.minX + CGFloat(Loupe.radius) * cell, y: picture.minY + CGFloat(Loupe.radius) * cell, width: cell, height: cell)
        let dark = NSBezierPath(rect: centerCell.insetBy(dx: -1, dy: -1)); dark.lineWidth = 1
        NSColor.black.setStroke(); dark.stroke()
        let light = NSBezierPath(rect: centerCell); light.lineWidth = 1.5
        NSColor.white.setStroke(); light.stroke()
        ctx.restoreGState()

        let mono = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
        let attrs: [NSAttributedString.Key: Any] = [.font: mono, .foregroundColor: NSColor.white.withAlphaComponent(0.92)]
        let coords = "\(Int(c.x)), \(Int(bounds.height - c.y))"
        let coordSize = (coords as NSString).size(withAttributes: attrs)
        (coords as NSString).draw(at: CGPoint(x: total.midX - coordSize.width / 2, y: origin.y + infoH - 4 - coordSize.height), withAttributes: attrs)

        let hexSize = (sample.hex as NSString).size(withAttributes: attrs)
        let rowWidth = 14 + 6 + hexSize.width
        let rowX = total.midX - rowWidth / 2, rowY = origin.y + 7
        let swatch = NSBezierPath(roundedRect: CGRect(x: rowX, y: rowY + (hexSize.height - 14) / 2, width: 14, height: 14), xRadius: 3, yRadius: 3)
        sample.color.setFill(); swatch.fill()
        NSColor.white.withAlphaComponent(0.6).setStroke(); swatch.lineWidth = 1; swatch.stroke()
        (sample.hex as NSString).draw(at: CGPoint(x: rowX + 20, y: rowY), withAttributes: attrs)

        let rim = NSBezierPath(roundedRect: total.insetBy(dx: 0.5, dy: 0.5), xRadius: 12, yRadius: 12)
        rim.lineWidth = 1
        NSColor.white.withAlphaComponent(0.55).setStroke()
        rim.stroke()
    }
}
