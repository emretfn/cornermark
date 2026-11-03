import AppKit
import KadrajCore
import KadrajEditor

var failures = 0
var passes = 0

func check(_ name: String, _ ok: @autoclosure () -> Bool, _ detail: @autoclosure () -> String = "") {
    if ok() {
        passes += 1
        print("PASS \(name)")
    } else {
        failures += 1
        print("FAIL \(name)\(detail().isEmpty ? "" : "  [\(detail())]")")
    }
}

func near(_ a: CGPoint, _ b: CGPoint, _ tol: CGFloat = 1.5) -> Bool { hypot(a.x - b.x, a.y - b.y) <= tol }
func near(_ a: CGRect, _ b: CGRect, _ tol: CGFloat = 1.5) -> Bool {
    abs(a.minX - b.minX) <= tol && abs(a.minY - b.minY) <= tol && abs(a.width - b.width) <= tol && abs(a.height - b.height) <= tol
}
func fmt(_ p: CGPoint) -> String { String(format: "(%.1f, %.1f)", p.x, p.y) }
func fmt(_ r: CGRect) -> String { String(format: "(%.1f, %.1f, %.1f x %.1f)", r.minX, r.minY, r.width, r.height) }

func settle(_ seconds: TimeInterval = 0.05) {
    RunLoop.current.run(until: Date().addingTimeInterval(seconds))
}

let snapshotDir = URL(fileURLWithPath: "build/harness/editor", isDirectory: true)

enum Fixture {
    /// A busy, asymmetric picture so rotation and crop mistakes are visible: coloured quadrants, a grid and text.
    static func image(width: Int, height: Int) -> CGImage {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        let w = CGFloat(width), h = CGFloat(height)
        let g = CGGradient(colorsSpace: cs, colors: [CGColor(srgbRed: 0.93, green: 0.96, blue: 1, alpha: 1),
                                                     CGColor(srgbRed: 0.82, green: 0.88, blue: 0.97, alpha: 1)] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: w, y: h), options: [])
        ctx.setFillColor(CGColor(srgbRed: 0.98, green: 0.98, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h * 0.07))
        for (i, c) in [(0.95, 0.35, 0.3), (0.98, 0.75, 0.2), (0.3, 0.75, 0.4)].enumerated() {
            ctx.setFillColor(CGColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1))
            ctx.fillEllipse(in: CGRect(x: 14 + CGFloat(i) * 26 * w / 1200, y: h * 0.02, width: h * 0.03, height: h * 0.03))
        }
        ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.08))
        ctx.setLineWidth(1)
        for x in stride(from: 0, through: w, by: w / 24) { ctx.move(to: CGPoint(x: x, y: h * 0.07)); ctx.addLine(to: CGPoint(x: x, y: h)) }
        for y in stride(from: h * 0.07, through: h, by: h / 16) { ctx.move(to: CGPoint(x: 0, y: y)); ctx.addLine(to: CGPoint(x: w, y: y)) }
        ctx.strokePath()
        ctx.setFillColor(CGColor(srgbRed: 0.2, green: 0.45, blue: 0.9, alpha: 1))
        ctx.fill(CGRect(x: w * 0.08, y: h * 0.18, width: w * 0.28, height: h * 0.34))
        ctx.setFillColor(CGColor(srgbRed: 0.95, green: 0.55, blue: 0.2, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: w * 0.55, y: h * 0.22, width: w * 0.26, height: w * 0.26))
        ctx.setFillColor(CGColor(gray: 0.15, alpha: 1))
        ctx.fill(CGRect(x: w * 0.1, y: h * 0.62, width: w * 0.5, height: h * 0.025))
        ctx.fill(CGRect(x: w * 0.1, y: h * 0.69, width: w * 0.36, height: h * 0.025))
        ctx.fill(CGRect(x: w * 0.1, y: h * 0.76, width: w * 0.44, height: h * 0.025))
        return ctx.makeImage()!
    }

    static func make(width: Int = 1200, height: Int = 800) -> (Document, AssetStore) {
        let store = AssetStore()
        let id = store.add(image: image(width: width, height: height))!
        return (Document(base: id, pixelSize: CGSize(width: width, height: height), pointScale: 2), store)
    }
}

/// Synthesises NSEvents and delivers them through `window.sendEvent`, the same entry real input uses.
final class Driver {
    let controller: EditorWindowController
    let window: NSWindow
    private var eventNumber = 0

    init(_ controller: EditorWindowController) {
        self.controller = controller
        window = controller.window!
    }

    var canvas: NSView { controller.canvasView }

    /// Source pixel to window coordinates, derived from `Renderer` and the view geometry, not from the editor's own inverse.
    func windowPoint(source p: CGPoint, document: Document? = nil) -> CGPoint {
        var doc = document ?? controller.currentDocument
        doc.outputScale *= Double(min(controller.zoom, 1))
        let canvasPoint = p.applying(Renderer.sourceToCanvas(doc, assets: controller.assets))
        let m = EditorWindowController.canvasMargin
        return canvas.convert(CGPoint(x: canvasPoint.x + m, y: canvasPoint.y + m), to: nil)
    }

    private func mouse(_ type: NSEvent.EventType, _ p: CGPoint, flags: NSEvent.ModifierFlags, clicks: Int) {
        eventNumber += 1
        let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                   windowNumber: window.windowNumber, context: nil, eventNumber: eventNumber, clickCount: clicks,
                                   pressure: type == .leftMouseUp ? 0 : 1)!
        deliver(e)
    }

    /// The window is never ordered in, so AppKit's window-level routing is skipped: the event goes to the
    /// view a real click at that point would reach, and drag/up follow the view that took the press.
    private var pressTarget: NSView?

    private func deliver(_ e: NSEvent) {
        let root = window.contentView!
        switch e.type {
        case .leftMouseDown:
            let hit = root.hitTest(root.superview!.convert(e.locationInWindow, from: nil))
            pressTarget = hit
            hit?.mouseDown(with: e)
        case .leftMouseDragged: pressTarget?.mouseDragged(with: e)
        case .leftMouseUp:
            pressTarget?.mouseUp(with: e)
            pressTarget = nil
        default: break
        }
    }

    func down(_ p: CGPoint, flags: NSEvent.ModifierFlags = [], clicks: Int = 1) { mouse(.leftMouseDown, p, flags: flags, clicks: clicks) }
    func move(_ p: CGPoint, flags: NSEvent.ModifierFlags = []) { mouse(.leftMouseDragged, p, flags: flags, clicks: 1) }
    func up(_ p: CGPoint, flags: NSEvent.ModifierFlags = [], clicks: Int = 1) { mouse(.leftMouseUp, p, flags: flags, clicks: clicks) }

    func drag(_ a: CGPoint, _ b: CGPoint, steps: Int = 8, flags: NSEvent.ModifierFlags = []) {
        down(a, flags: flags)
        for i in 1...steps { move(a.lerp(b, CGFloat(i) / CGFloat(steps)), flags: flags) }
        up(b, flags: flags)
    }

    func drag(source a: CGPoint, to b: CGPoint, steps: Int = 8, flags: NSEvent.ModifierFlags = []) {
        drag(windowPoint(source: a), windowPoint(source: b), steps: steps, flags: flags)
    }

    func click(_ p: CGPoint, clicks: Int = 1) {
        down(p, clicks: clicks)
        up(p, clicks: clicks)
    }

    func key(_ chars: String, code: UInt16 = 0, flags: NSEvent.ModifierFlags = []) {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                     windowNumber: window.windowNumber, context: nil, characters: chars,
                                     charactersIgnoringModifiers: chars.lowercased(), isARepeat: false, keyCode: code)!
            window.sendEvent(e)
        }
    }

    private func event(_ type: NSEvent.EventType, _ p: CGPoint) -> NSEvent {
        eventNumber += 1
        return NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                  windowNumber: window.windowNumber, context: nil, eventNumber: eventNumber, clickCount: 1,
                                  pressure: type == .leftMouseUp ? 0 : 1)!
    }

    /// A segment press without a tracking loop.
    func clickSegment(_ seg: NSSegmentedControl, _ index: Int) {
        if seg.trackingMode == .momentary {
            controller.pressToolbarButton(seg.accessibilityIdentifier(), segment: index)
        } else {
            seg.selectedSegment = index
            seg.sendAction(seg.action, to: seg.target)
        }
    }

    /// Slider ticks as a drag delivers them: one action per value, no tracking loop.
    func dragSlider(_ slider: NSSlider, toFraction target: Double, steps: Int = 6) {
        let start = slider.doubleValue
        let end = slider.minValue + (slider.maxValue - slider.minValue) * target
        for i in 1...steps {
            slider.doubleValue = start + (end - start) * Double(i) / Double(steps)
            slider.sendAction(slider.action, to: slider.target)
        }
    }

    func type(_ text: String) {
        for ch in text { key(String(ch), code: ch == " " ? 49 : 0) }
    }

    static let keyCodes: [Character: UInt16] = ["a": 0, "l": 37, "r": 15, "o": 31, "t": 17, "n": 45, "p": 35, "h": 4, "b": 11,
                                                "x": 7, "s": 1, "c": 8, "v": 9, "z": 6, "g": 5]

    func tapKey(_ ch: Character, flags: NSEvent.ModifierFlags = []) { key(String(ch), code: Self.keyCodes[ch] ?? 0, flags: flags) }
    func escape() { key("\u{1b}", code: 53) }
    func returnKey() { key("\r", code: 36) }
    func deleteKey() { key("\u{7f}", code: 51) }
}

extension CGPoint {
    func lerp(_ o: CGPoint, _ t: CGFloat) -> CGPoint { CGPoint(x: x + (o.x - x) * t, y: y + (o.y - y) * t) }
}

func writePNG(_ rep: NSBitmapImageRep, to url: URL) {
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    if let data = rep.representation(using: .png, properties: [:]) { try? data.write(to: url) }
}

/// Captures the whole window, title bar and toolbar included, via the theme frame view.
@discardableResult
func snapshot(_ controller: EditorWindowController, _ name: String, appearance: NSAppearance.Name) -> URL {
    let window = controller.window!
    window.appearance = NSAppearance(named: appearance)
    settle(0.15)
    window.displayIfNeeded()
    let view = window.contentView!.superview!
    let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
    view.cacheDisplay(in: view.bounds, to: rep)
    let url = snapshotDir.appendingPathComponent("\(name).png")
    writePNG(rep, to: url)
    return url
}

func pixels(_ image: CGImage) -> [UInt8] {
    let w = image.width, h = image.height
    var out = [UInt8](repeating: 0, count: w * h * 4)
    let ctx = CGContext(data: &out, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    return out
}

func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int, a: Int) {
    let p = pixels(image)
    let i = (y * image.width + x) * 4
    return (Int(p[i]), Int(p[i + 1]), Int(p[i + 2]), Int(p[i + 3]))
}

struct Rig {
    let controller: EditorWindowController
    let driver: Driver
    let assets: AssetStore
    var doc: Document { controller.currentDocument }
    var last: Annotation? { controller.currentDocument.annotations.last }
}

var openedWindows: [EditorWindowController] = []

func makeRig(width: Int = 1200, height: Int = 800, zoom: CGFloat? = 0.6, callbacks: EditorCallbacks = EditorCallbacks(),
             pasteboard: NSPasteboard? = nil) -> Rig {
    let (doc, assets) = Fixture.make(width: width, height: height)
    let c = EditorWindowController(document: doc, assets: assets, callbacks: callbacks, defaults: defaults)
    if let pasteboard { c.pasteboard = pasteboard }
    c.window?.contentView?.layoutSubtreeIfNeeded()
    openedWindows.append(c)
    settle(0.1)
    if let zoom { c.zoom = zoom }
    settle(0.1)
    return Rig(controller: c, driver: Driver(c), assets: assets)
}

func closeRig(_ rig: Rig) {
    rig.controller.window?.close()
    openedWindows.removeAll { $0 === rig.controller }
}

func relayout(_ rig: Rig) {
    rig.controller.window?.contentView?.layoutSubtreeIfNeeded()
    settle(0.08)
    rig.controller.window?.contentView?.layoutSubtreeIfNeeded()
}

func section(_ title: String) { print("\n== \(title)") }
