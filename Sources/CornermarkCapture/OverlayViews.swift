import AppKit
import CornermarkDesign

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
        // The overlay always sits over arbitrary screen content, so it is dark in every system appearance and its views use the same tokens.
        appearance = NSAppearance(named: .darkAqua)
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
        DS.Color.bgScrim.setFill()
        path.fill()
    }

    private func drawSelection(_ r: CGRect, handles: Bool) {
        let outer = NSBezierPath(rect: r.insetBy(dx: -1.5, dy: -1.5))
        outer.lineWidth = 1
        DS.Color.selectionHalo.setStroke()
        outer.stroke()
        let line = NSBezierPath(rect: r.insetBy(dx: -0.5, dy: -0.5))
        line.lineWidth = 1
        DS.Color.selectionStroke.setStroke()
        line.stroke()
        guard handles else { return }
        for h in Handle.allCases {
            let c = h.position(on: r)
            let dotRect = CGRect(x: c.x - 4.5, y: c.y - 4.5, width: 9, height: 9)
            guard dotRect.intersects(bounds) else { continue }
            DS.Color.selectionHalo.setFill()
            NSBezierPath(ovalIn: dotRect.insetBy(dx: -1, dy: -1)).fill()
            DS.Color.selectionStroke.setFill()
            NSBezierPath(ovalIn: dotRect).fill()
        }
    }

    private static let pillStyle = DS.Text.readout

    private func pillSize(_ text: String) -> CGSize {
        let width = NSAttributedString(string: text, attributes: Self.pillStyle.attributes(color: DS.Color.textPrimary)).size().width
        return CGSize(width: ceil(width) + 2 * DS.Space.s8, height: DS.Size.controlSmall)
    }

    @discardableResult
    private func drawPill(_ text: String, at origin: CGPoint, tint: NSColor = DS.Color.bgHud) -> CGRect {
        let rect = CGRect(origin: origin, size: pillSize(text))
        DS.Elevation.raised.draw(NSBezierPath.continuous(rect, radius: DS.Radius.sm), fill: tint)
        let line = CGRect(x: rect.minX + DS.Space.s8, y: rect.midY - Self.pillStyle.lineHeight / 2, width: rect.width - 2 * DS.Space.s8, height: Self.pillStyle.lineHeight)
        NSAttributedString(string: text, attributes: Self.pillStyle.attributes(color: DS.Color.textPrimary))
            .draw(with: line, options: [.usesLineFragmentOrigin])
        return rect
    }

    private func drawBadge(text: String, anchoredTo r: CGRect) {
        let size = pillSize(text)
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
        DS.Color.accentWash.setFill()
        r.fill()
        let halo = NSBezierPath(rect: r.insetBy(dx: -0.5, dy: -0.5))
        halo.lineWidth = 1
        DS.Color.selectionHalo.setStroke()
        halo.stroke()
        let border = NSBezierPath(rect: r.insetBy(dx: 1, dy: 1))
        border.lineWidth = 2
        DS.Color.accentSolid.setStroke()
        border.stroke()
        let text = [w.appName, "\(Int(w.frame.width.rounded())) × \(Int(w.frame.height.rounded()))"].filter { !$0.isEmpty }.joined(separator: "  ")
        let size = pillSize(text)
        drawPill(text, at: CGPoint(x: r.midX - size.width / 2, y: r.midY - size.height / 2))
    }

    private func drawCrosshair(_ c: CGPoint) {
        let h = NSBezierPath(), v = NSBezierPath()
        h.move(to: CGPoint(x: bounds.minX, y: c.y)); h.line(to: CGPoint(x: bounds.maxX, y: c.y))
        v.move(to: CGPoint(x: c.x, y: bounds.minY)); v.line(to: CGPoint(x: c.x, y: bounds.maxY))
        for (path, color, width) in [(h, DS.Color.selectionHalo, 3.0), (v, DS.Color.selectionHalo, 3.0),
                                     (h, DS.Color.selectionStroke, 1.0), (v, DS.Color.selectionStroke, 1.0)] {
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
        let shape = NSBezierPath.continuous(total, radius: DS.Radius.lg)
        // The magnified patch sits on this surface, so unlike the toolbar it must not let the screen show through.
        DS.Elevation.hud.draw(shape, fill: DS.Color.bgHud.withAlphaComponent(1))

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
        let dark = NSBezierPath(rect: centerCell.insetBy(dx: -1, dy: -1)); dark.lineWidth = 1.5
        DS.Color.selectionHalo.setStroke(); dark.stroke()
        let light = NSBezierPath(rect: centerCell); light.lineWidth = 1.5
        DS.Color.selectionStroke.setStroke(); light.stroke()
        ctx.restoreGState()

        let attrs = DS.Text.readout.attributes(color: DS.Color.textPrimary)
        let lineHeight = DS.Text.readout.lineHeight
        let coords = "\(Int(c.x)), \(Int(bounds.height - c.y))"
        let coordWidth = ceil((coords as NSString).size(withAttributes: attrs).width)
        (coords as NSString).draw(with: CGRect(x: total.midX - coordWidth / 2, y: origin.y + infoH - DS.Space.s4 - lineHeight, width: coordWidth, height: lineHeight),
                                  options: .usesLineFragmentOrigin, attributes: attrs)

        let hexWidth = ceil((sample.hex as NSString).size(withAttributes: attrs).width)
        let rowWidth = 14 + DS.Space.s6 + hexWidth
        let rowX = total.midX - rowWidth / 2, rowY = origin.y + 7
        let swatch = NSBezierPath.continuous(CGRect(x: rowX, y: rowY + (lineHeight - 14) / 2, width: 14, height: 14), radius: DS.Radius.xs)
        sample.color.setFill(); swatch.fill()
        DS.Color.borderStrong.setStroke(); swatch.lineWidth = 1; swatch.stroke()
        (sample.hex as NSString).draw(with: CGRect(x: rowX + 14 + DS.Space.s6, y: rowY, width: hexWidth, height: lineHeight), options: .usesLineFragmentOrigin, attributes: attrs)

        let rim = NSBezierPath.continuous(total.insetBy(dx: 0.5, dy: 0.5), radius: DS.Radius.lg)
        rim.lineWidth = 1
        DS.Color.border.setStroke()
        rim.stroke()
    }
}
