import AppKit
import CornermarkCapture

let scratch = "build/harness/capture/"
let multiScratch = "build/harness/multi/"

@MainActor
final class Checks {
    static let shared = Checks()
    private(set) var passed = 0
    private(set) var failed = 0

    func check(_ ok: Bool, _ name: String, detail: @autoclosure () -> String = "") {
        if ok {
            passed += 1
            print("PASS \(name)")
        } else {
            failed += 1
            let d = detail()
            print("FAIL \(name)" + (d.isEmpty ? "" : "  [\(d)]"))
        }
    }
}

@MainActor
func check(_ ok: Bool, _ name: String, detail: @autoclosure () -> String = "") {
    Checks.shared.check(ok, name, detail: detail())
}

@MainActor
func section(_ name: String) { print("\n== \(name)") }

struct LCG {
    var state: UInt64
    init(_ seed: UInt64) { state = seed &* 6364136223846793005 &+ 1442695040888963407 }
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state >> 33
    }
    mutating func unit() -> CGFloat { CGFloat(next() % 1000) / 1000 }
    mutating func byte() -> UInt8 { UInt8(next() % 256) }
}

enum Pixels {
    static let space = CGColorSpace(name: CGColorSpace.sRGB)!

    static func context(_ w: Int, _ h: Int) -> CGContext {
        CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    }

    /// Tightly packed RGBA, row 0 = top.
    static func rgba(_ image: CGImage) -> [UInt8] {
        let w = image.width, h = image.height
        let ctx = context(w, h)
        ctx.interpolationQuality = .none
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var out = [UInt8](repeating: 0, count: w * h * 4)
        let bpr = ctx.bytesPerRow
        let base = ctx.data!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<h { for i in 0..<(w * 4) { out[y * w * 4 + i] = base[y * bpr + i] } }
        return out
    }

    static func sub(_ rgba: [UInt8], width: Int, rect: CGRect) -> [UInt8] {
        var out: [UInt8] = []
        let x0 = Int(rect.minX), y0 = Int(rect.minY), w = Int(rect.width), h = Int(rect.height)
        out.reserveCapacity(w * h * 4)
        for y in y0..<(y0 + h) { out.append(contentsOf: rgba[((y * width + x0) * 4)..<((y * width + x0 + w) * 4)]) }
        return out
    }

    static func pngData(_ image: CGImage) -> Data? {
        NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }
}

enum Fixtures {
    static func window(_ id: CGWindowID, _ title: String, _ app: String, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> WindowSnapshot {
        WindowSnapshot(id: id, title: title, appName: app, frame: CGRect(x: x, y: y, width: w, height: h))
    }

    /// A screen with a gradient desktop, menu bar, noise blocks (so no two regions look alike) and drawn windows.
    static func display(id: CGDirectDisplayID, frame: CGRect, scale: Double, windows: [WindowSnapshot], seed: UInt64) -> DisplaySnapshot {
        let s = CGFloat(scale)
        let w = Int(frame.width * s), h = Int(frame.height * s)
        let ctx = Pixels.context(w, h)
        var rng = LCG(seed)
        let gradient = CGGradient(colorsSpace: Pixels.space, colors: [
            CGColor(srgbRed: 0.13, green: 0.27, blue: 0.52, alpha: 1), CGColor(srgbRed: 0.58, green: 0.33, blue: 0.58, alpha: 1),
        ] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: CGFloat(h)), end: CGPoint(x: CGFloat(w), y: 0), options: [])

        for _ in 0..<(w * h / 900) {
            let bx = CGFloat(rng.next() % UInt64(w)), by = CGFloat(rng.next() % UInt64(h))
            ctx.setFillColor(CGColor(srgbRed: rng.unit(), green: rng.unit(), blue: rng.unit(), alpha: 1))
            ctx.fill(CGRect(x: bx, y: by, width: 3 * s, height: 3 * s))
        }
        ctx.setFillColor(CGColor(gray: 1, alpha: 0.07))
        var gx: CGFloat = 0
        while gx < frame.width { ctx.fill(CGRect(x: gx * s, y: 0, width: 1, height: CGFloat(h))); gx += 50 }
        var gy: CGFloat = 0
        while gy < frame.height { ctx.fill(CGRect(x: 0, y: gy * s, width: CGFloat(w), height: 1)); gy += 50 }

        ctx.setFillColor(CGColor(gray: 0.93, alpha: 0.96))
        ctx.fill(CGRect(x: 0, y: CGFloat(h) - 24 * s, width: CGFloat(w), height: 24 * s))
        text(ctx, "Cornermark  File  Edit  View", at: CGPoint(x: 12 * s, y: CGFloat(h) - 18 * s), size: 12 * s, color: .black)

        for win in windows.reversed() where win.frame.intersects(frame) {
            let r = CGRect(x: (win.frame.minX - frame.minX) * s, y: (win.frame.minY - frame.minY) * s,
                           width: win.frame.width * s, height: win.frame.height * s)
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -6 * s), blur: 14 * s, color: CGColor(gray: 0, alpha: 0.45))
            ctx.setFillColor(CGColor(gray: 0.97, alpha: 1))
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: 8 * s, cornerHeight: 8 * s, transform: nil))
            ctx.fillPath()
            ctx.restoreGState()
            ctx.setFillColor(CGColor(gray: 0.86, alpha: 1))
            ctx.fill(CGRect(x: r.minX, y: r.maxY - 28 * s, width: r.width, height: 28 * s))
            for (i, c) in [(1.0, 0.37, 0.34), (1.0, 0.74, 0.18), (0.16, 0.79, 0.25)].enumerated() {
                ctx.setFillColor(CGColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1))
                ctx.fillEllipse(in: CGRect(x: r.minX + (10 + CGFloat(i) * 18) * s, y: r.maxY - 20 * s, width: 12 * s, height: 12 * s))
            }
            text(ctx, "\(win.appName) - \(win.title)", at: CGPoint(x: r.minX + 72 * s, y: r.maxY - 21 * s), size: 12 * s, color: NSColor(white: 0.25, alpha: 1))
            var ty = r.maxY - 48 * s
            var line = rng
            while ty > r.minY + 12 * s {
                ctx.setFillColor(CGColor(gray: 0.25 + 0.5 * line.unit(), alpha: 1))
                ctx.fill(CGRect(x: r.minX + 14 * s, y: ty, width: (r.width - 28 * s) * (0.3 + 0.65 * line.unit()), height: 5 * s))
                ty -= 14 * s
            }
            ctx.setFillColor(CGColor(srgbRed: 0.1, green: 0.55, blue: 0.95, alpha: 1))
            ctx.fill(CGRect(x: r.maxX - 60 * s, y: r.minY + 12 * s, width: 44 * s, height: 22 * s))
            rng = line
        }
        return DisplaySnapshot(displayID: id, frame: frame, scale: scale, image: ctx.makeImage()!)
    }

    static func text(_ ctx: CGContext, _ string: String, at p: CGPoint, size: CGFloat, color: NSColor) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        (string as NSString).draw(at: p, withAttributes: [.font: NSFont.systemFont(ofSize: size), .foregroundColor: color])
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Rows of pseudo-random pixels, so every row is distinct for the stitcher.
    static func page(width: Int, height: Int, seed: UInt64) -> CGImage {
        let ctx = Pixels.context(width, height)
        var rng = LCG(seed)
        let base = ctx.data!.assumingMemoryBound(to: UInt8.self)
        let bpr = ctx.bytesPerRow
        for y in 0..<height {
            let band = UInt8((y / 100) * 30 % 200)
            for x in 0..<width {
                let o = y * bpr + x * 4
                base[o] = rng.byte() / 2 &+ band / 2; base[o + 1] = rng.byte() / 2 &+ 40; base[o + 2] = rng.byte() / 2 &+ 60; base[o + 3] = 255
            }
        }
        return ctx.makeImage()!
    }
}

@MainActor
enum Synth {
    private static var serial = 0

    static func mouse(_ type: NSEvent.EventType, at global: CGPoint, in window: NSWindow, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        serial += 1
        return NSEvent.mouseEvent(with: type, location: window.convertPoint(fromScreen: global), modifierFlags: modifiers,
                                  timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                                  eventNumber: serial, clickCount: 1, pressure: 1)!
    }

    static func move(_ window: NSWindow, to p: CGPoint) { window.sendEvent(mouse(.mouseMoved, at: p, in: window)) }

    static func down(_ window: NSWindow, at p: CGPoint, modifiers: NSEvent.ModifierFlags = []) {
        window.sendEvent(mouse(.leftMouseDown, at: p, in: window, modifiers: modifiers))
    }

    static func dragged(_ window: NSWindow, to p: CGPoint, modifiers: NSEvent.ModifierFlags = []) {
        window.sendEvent(mouse(.leftMouseDragged, at: p, in: window, modifiers: modifiers))
    }

    static func up(_ window: NSWindow, at p: CGPoint, modifiers: NSEvent.ModifierFlags = []) {
        window.sendEvent(mouse(.leftMouseUp, at: p, in: window, modifiers: modifiers))
    }

    static func drag(_ window: NSWindow, from a: CGPoint, to b: CGPoint, modifiers: NSEvent.ModifierFlags = [], release: Bool = true) {
        move(window, to: a)
        down(window, at: a, modifiers: modifiers)
        for i in 1...6 {
            let t = CGFloat(i) / 6
            dragged(window, to: CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t), modifiers: modifiers)
        }
        if release { up(window, at: b, modifiers: modifiers) }
    }

    static func key(_ window: NSWindow, _ code: UInt16, _ chars: String = "", modifiers: NSEvent.ModifierFlags = [], up: Bool = false) {
        window.sendEvent(NSEvent.keyEvent(with: up ? .keyUp : .keyDown, location: .zero, modifierFlags: modifiers,
                                          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                                          characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!)
    }

    static func escape(_ w: NSWindow) { key(w, 53, "\u{1b}") }
    static func returnKey(_ w: NSWindow) { key(w, 36, "\r") }
    static func arrow(_ w: NSWindow, _ code: UInt16, shift: Bool = false) { key(w, code, "", modifiers: shift ? [.shift] : []) }
}

@MainActor
func waitUntil(_ seconds: Double = 3, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return condition()
}

@MainActor
func findView(_ id: String, in view: NSView?) -> NSView? {
    guard let view else { return nil }
    if view.accessibilityIdentifier() == id { return view }
    for sub in view.subviews { if let hit = findView(id, in: sub) { return hit } }
    return nil
}

@MainActor
func findView(_ id: String, in windows: [NSWindow]) -> NSView? {
    for w in windows { if let v = findView(id, in: w.contentView) { return v } }
    return nil
}

@MainActor
@discardableResult
func snapshot(_ window: NSWindow, name: String, in dir: String = scratch) -> CGImage? {
    guard let root = window.contentView, let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds) else {
        check(false, "snapshot \(name) could not create bitmap")
        return nil
    }
    root.cacheDisplay(in: root.bounds, to: rep)
    let path = dir + name + ".png"
    if let data = rep.representation(using: .png, properties: [:]) {
        try? data.write(to: URL(fileURLWithPath: path))
        print("SNAPSHOT \(path) \(rep.pixelsWide)x\(rep.pixelsHigh)")
    }
    return rep.cgImage
}

@MainActor
final class Outcome {
    var value: CaptureOutcome?
    var output: CaptureOutput? { if case .captured(let o)? = value { return o } else { return nil } }
    var isCancelled: Bool { if case .cancelled? = value { return true } else { return false } }
    var failure: CaptureFailure? { if case .failed(let f)? = value { return f } else { return nil } }
}

@MainActor
func makeController(_ source: ScreenSource, pointer: CGPoint = CGPoint(x: 10, y: 10)) -> CaptureController {
    let c = CaptureController(source: source, presentation: .offscreen)
    c.settleDelay = 0
    c.countdownTickInterval = 0.03
    c.scrollPollInterval = 0.05
    c.pointerLocation = { pointer }
    return c
}

@MainActor
func start(_ c: CaptureController, _ mode: CaptureMode) async -> Outcome {
    let out = Outcome()
    c.begin(mode) { out.value = $0 }
    _ = await waitUntil { !c.overlayWindows.isEmpty || out.value != nil }
    return out
}

@MainActor
func overlay(_ c: CaptureController, frame: CGRect) -> NSWindow? {
    c.overlayWindows.first { $0.frame == frame }
}

@MainActor var closedWindows = Set<ObjectIdentifier>()

@MainActor
func observeWindowClosing() {
    NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { note in
        guard let window = note.object as? NSWindow else { return }
        MainActor.assumeIsolated { _ = closedWindows.insert(ObjectIdentifier(window)) }
    }
}

/// Displays whose every pixel is a flat 20pt cell of a color derived from (display id, cell), so any pixel of a
/// composite can be predicted from where it came from, and a resampled cell stays flat away from its edges.
enum Cells {
    static let size: CGFloat = 20

    static func hash(_ v: UInt64) -> UInt64 {
        var x = v &+ 0x9E3779B97F4A7C15
        x = (x ^ (x >> 30)) &* 0xBF58476D1CE4E5B9
        x = (x ^ (x >> 27)) &* 0x94D049BB133111EB
        return x ^ (x >> 31)
    }

    static func color(_ id: CGDirectDisplayID, cx: Int, cy: Int) -> [UInt8] {
        let h = hash(UInt64(id) << 48 ^ UInt64(UInt32(bitPattern: Int32(cx))) << 20 ^ UInt64(UInt32(bitPattern: Int32(cy))))
        return [UInt8(96 + h % 160), UInt8(96 + (h >> 16) % 160), UInt8(96 + (h >> 32) % 160), 255]
    }

    /// The cell color under a global point, nil if no display holds it.
    static func color(at global: CGPoint, in displays: [DisplaySnapshot]) -> [UInt8]? {
        guard let d = displays.first(where: { $0.frame.contains(global) }) else { return nil }
        return color(d.displayID, cx: Int(floor((global.x - d.frame.minX) / size)), cy: Int(floor((d.frame.maxY - global.y) / size)))
    }

    static func display(id: CGDirectDisplayID, frame: CGRect, scale: Double) -> DisplaySnapshot {
        let w = Int(frame.width * scale), h = Int(frame.height * scale)
        let ctx = Pixels.context(w, h)
        let base = ctx.data!.assumingMemoryBound(to: UInt8.self)
        let bpr = ctx.bytesPerRow
        for y in 0..<h {
            for x in 0..<w {
                let c = color(id, cx: Int(floor(CGFloat(x) / CGFloat(scale) / size)), cy: Int(floor(CGFloat(y) / CGFloat(scale) / size)))
                for i in 0..<4 { base[y * bpr + x * 4 + i] = c[i] }
            }
        }
        return DisplaySnapshot(displayID: id, frame: frame, scale: scale, image: ctx.makeImage()!)
    }
}

func mostlyEqual(_ a: [UInt8], _ b: [UInt8], tolerance: Int) -> Bool {
    a.count == b.count && zip(a, b).allSatisfy { abs(Int($0) - Int($1)) <= tolerance }
}
