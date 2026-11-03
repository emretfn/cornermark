import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import KadrajCapture
import KadrajCore
@testable import KadrajShell

let scratch = "/private/tmp/claude-501/-Users-emretufan-Documents-test-projects-cornermark/c5db439d-4599-415b-bcac-b995a06e3ad7/scratchpad/shell/"

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

@MainActor
func waitUntil(_ seconds: Double = 5, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return condition()
}

// MARK: Fakes

final class FakeLoginItem: LoginItemControlling {
    var isEnabled = false
    var failure: Error?
    func setEnabled(_ enabled: Bool) throws {
        if let failure { throw failure }
        isEnabled = enabled
    }
}

final class FakeHotKeyBackend: HotKeyBackend {
    var onPressed: ((UInt32) -> Void)?
    var failing: [HotKey: Int32] = [:]
    private(set) var registered: [UInt32: HotKey] = [:]
    private(set) var unregisterCalls = 0

    func register(_ key: HotKey, id: UInt32) -> Int32 {
        if let code = failing[key] { return code }
        registered[id] = key
        return 0
    }

    func unregisterAll() { registered = [:]; unregisterCalls += 1 }
    func press(_ id: UInt32) { onPressed?(id) }
}

// MARK: World

enum Fixture {
    static let displayFrame = CGRect(x: 0, y: 0, width: 1280, height: 800)
    /// Top-left coordinates inside the fixture display.
    static let textBox = CGRect(x: 100, y: 100, width: 700, height: 220)
    static let qrBox = CGRect(x: 900, y: 100, width: 260, height: 260)
    static let textLines = ["Hello Kadraj OCR", "Second line 12345", "Third line done"]
    static let qrPayload = "https://example.com/kadraj?ref=qr-42"

    /// Global AppKit points for a top-left box on the fixture display.
    static func global(_ box: CGRect, grow: CGFloat = 0) -> CGRect {
        CGRect(x: box.minX - grow, y: displayFrame.height - box.maxY - grow, width: box.width + 2 * grow, height: box.height + 2 * grow)
    }

    static func timestamp(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int, _ s: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: s))!
    }
}

enum Pix {
    static let space = CGColorSpace(name: CGColorSpace.sRGB)!

    static func context(_ w: Int, _ h: Int) -> CGContext {
        CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    }

    static func draw(_ ctx: CGContext, _ text: String, at p: CGPoint, size: CGFloat, color: NSColor = .black) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        (text as NSString).draw(at: p, withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: .medium), .foregroundColor: color])
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Black text on white, one line per entry, fonts big enough for Vision to be certain.
    static func textImage(_ lines: [String], size: CGFloat = 44, width: Int = 700) -> CGImage {
        let lineHeight = size * 1.5
        let h = Int(lineHeight * CGFloat(lines.count) + 40)
        let ctx = context(width, h)
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: h))
        for (i, line) in lines.enumerated() {
            draw(ctx, line, at: CGPoint(x: 24, y: CGFloat(h) - 20 - lineHeight * CGFloat(i + 1) + 8), size: size)
        }
        return ctx.makeImage()!
    }

    static func qrImage(_ payload: String, module: Int = 8, quiet: Int = 4) -> CGImage {
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(payload.utf8)
        f.correctionLevel = "M"
        let raw = f.outputImage!
        let n = Int(raw.extent.width)
        let side = (n + 2 * quiet) * module
        let ctx = context(side, side)
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
        let cg = CIContext().createCGImage(raw, from: raw.extent)!
        ctx.interpolationQuality = .none
        ctx.draw(cg, in: CGRect(x: quiet * module, y: quiet * module, width: n * module, height: n * module))
        return ctx.makeImage()!
    }

    /// A desktop-like screen with a document box of text and a QR code at known places.
    static func fixtureDisplay(id: CGDirectDisplayID = 1) -> DisplaySnapshot {
        let f = Fixture.displayFrame
        let w = Int(f.width), h = Int(f.height)
        let ctx = context(w, h)
        let gradient = CGGradient(colorsSpace: space, colors: [
            CGColor(srgbRed: 0.13, green: 0.27, blue: 0.52, alpha: 1), CGColor(srgbRed: 0.58, green: 0.33, blue: 0.58, alpha: 1),
        ] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: CGFloat(h)), end: CGPoint(x: CGFloat(w), y: 0), options: [])
        let box = Fixture.textBox
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: box.minX, y: CGFloat(h) - box.maxY, width: box.width, height: box.height))
        for (i, line) in Fixture.textLines.enumerated() {
            draw(ctx, line, at: CGPoint(x: box.minX + 24, y: CGFloat(h) - box.minY - 70 - CGFloat(i) * 66), size: 44)
        }
        let qr = qrImage(Fixture.qrPayload, module: 6, quiet: 2)
        let qb = Fixture.qrBox
        ctx.interpolationQuality = .none
        ctx.draw(qr, in: CGRect(x: qb.minX, y: CGFloat(h) - qb.maxY, width: qb.width, height: qb.height))
        ctx.setFillColor(CGColor(gray: 0.93, alpha: 0.96))
        ctx.fill(CGRect(x: 0, y: CGFloat(h) - 24, width: CGFloat(w), height: 24))
        return DisplaySnapshot(displayID: id, frame: f, scale: 1, image: ctx.makeImage()!)
    }

    static func flat(_ w: Int, _ h: Int, r: Double, g: Double, b: Double, label: String? = nil) -> CGImage {
        let ctx = context(w, h)
        let grad = CGGradient(colorsSpace: space, colors: [
            CGColor(srgbRed: r, green: g, blue: b, alpha: 1), CGColor(srgbRed: b, green: r, blue: g, alpha: 1),
        ] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(grad, start: .zero, end: CGPoint(x: w, y: h), options: [])
        if let label { draw(ctx, label, at: CGPoint(x: 16, y: CGFloat(h) / 2 - 14), size: 28, color: .white) }
        return ctx.makeImage()!
    }

    static func rgba(_ image: CGImage) -> [UInt8] {
        let ctx = context(image.width, image.height)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Array(UnsafeBufferPointer(start: ctx.data!.assumingMemoryBound(to: UInt8.self), count: ctx.bytesPerRow * image.height))
    }

    static func decode(_ data: Data) -> CGImage? {
        CGImageSourceCreateWithData(data as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
    }

    static func decode(_ url: URL) -> CGImage? {
        CGImageSourceCreateWithURL(url as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
    }
}

@MainActor
final class World {
    let root: URL
    let suite: String
    let defaults: UserDefaults
    let pasteboard: NSPasteboard
    var now = Fixture.timestamp(2026, 11, 3, 14, 5, 9)
    var permission = true
    var cursorFrame = CGRect(x: 0, y: 60, width: 1280, height: 715)
    var opened: [URL] = []
    var revealed: [URL] = []
    var sounds = 0
    var quits = 0
    var presented: [NSWindow] = []
    var pickedFolder: URL?
    let login = FakeLoginItem()
    let source: FixtureScreenSource
    let display: DisplaySnapshot
    let env: AppEnvironment
    let coordinator: AppCoordinator
    let backend = FakeHotKeyBackend()

    var store: CaptureStore { env.store }
    var settings: SettingsStore { coordinator.settings }
    var saveDir: URL { root.appendingPathComponent("saved", isDirectory: true) }

    init(after: AfterCapture = [.showOverlay], hotKeys: Bool = false) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("KadrajHarness-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        suite = "local.emretufan.kadraj.harness.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        pasteboard = NSPasteboard(name: NSPasteboard.Name(suite))
        display = Pix.fixtureDisplay()
        source = FixtureScreenSource(displays: [display])
        let history = try CaptureStore(root: root.appendingPathComponent("history", isDirectory: true))
        let drag = root.appendingPathComponent("drag", isDirectory: true)
        let box = WorldBox()
        env = AppEnvironment(
            screen: source, store: history, defaults: defaults, pasteboard: pasteboard, presentation: .offscreen,
            clock: { box.world?.now ?? Date() }, cursorScreenFrame: { box.world?.cursorFrame ?? .zero },
            hasScreenPermission: { box.world?.permission ?? false }, requestScreenPermission: {},
            openURL: { box.world?.opened.append($0) }, revealInFinder: { box.world?.revealed.append($0) },
            playSound: { box.world?.sounds += 1 }, pickFolder: { done in done(box.world?.pickedFolder) },
            loginItem: login, defaultSaveFolder: root.appendingPathComponent("desktop", isDirectory: true),
            dragDirectory: drag, quit: { box.world?.quits += 1 })
        env.willPresent = { box.world?.presented.append($0) }
        coordinator = AppCoordinator(env: env)
        box.world = self
        coordinator.capture.settleDelay = 0
        coordinator.capture.countdownTickInterval = 0.03
        coordinator.capture.pointerLocation = { CGPoint(x: 10, y: 10) }
        settings.update {
            $0.afterCapture = after
            $0.saveFolder = saveDir.path
            $0.playSound = false
        }
        if hotKeys { coordinator.installHotKeys(backend: backend) }
    }

    func cleanup() {
        for e in coordinator.editors.values { e.window?.close() }
        coordinator.pins.closeAll()
        coordinator.overlay.closeAll()
        pasteboard.releaseGlobally()
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }

    func capture(_ mode: CaptureMode = .fullscreen, expecting count: Int) async -> Bool {
        coordinator.perform(.capture(mode))
        return await waitUntil { store.list().count >= count }
    }

    func pasteboardImage() -> CGImage? { pasteboard.data(forType: .png).flatMap(Pix.decode) }
}

final class WorldBox { @MainActor weak var world: World? }

// MARK: Events

@MainActor
enum Synth {
    private static var serial = 0

    static func mouse(_ type: NSEvent.EventType, at global: CGPoint, in window: NSWindow, clickCount: Int = 1) -> NSEvent {
        serial += 1
        return NSEvent.mouseEvent(with: type, location: window.convertPoint(fromScreen: global), modifierFlags: [],
                                  timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                                  eventNumber: serial, clickCount: clickCount, pressure: 1)!
    }

    static func drag(_ window: NSWindow, from a: CGPoint, to b: CGPoint) {
        window.sendEvent(mouse(.mouseMoved, at: a, in: window))
        window.sendEvent(mouse(.leftMouseDown, at: a, in: window))
        for i in 1...6 {
            let t = CGFloat(i) / 6
            window.sendEvent(mouse(.leftMouseDragged, at: CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t), in: window))
        }
        window.sendEvent(mouse(.leftMouseUp, at: b, in: window))
    }

    static func enterExit(_ type: NSEvent.EventType, in window: NSWindow) -> NSEvent {
        serial += 1
        return NSEvent.enterExitEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                      windowNumber: window.windowNumber, context: nil, eventNumber: serial, trackingNumber: 0, userData: nil)!
    }

    static func key(_ window: NSWindow, _ code: UInt16, _ chars: String = "", modifiers: NSEvent.ModifierFlags = []) {
        window.sendEvent(keyEvent(window, code, chars, modifiers: modifiers))
    }

    static func keyEvent(_ window: NSWindow?, _ code: UInt16, _ chars: String = "", modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                         windowNumber: window?.windowNumber ?? 0, context: nil, characters: chars, charactersIgnoringModifiers: chars,
                         isARepeat: false, keyCode: code)!
    }

    /// A trackpad-style scroll built from a CGEvent, the only way to make an NSEvent scroll wheel.
    static func scroll(dx: Int32 = 0, dy: Int32 = 0, phase: Int64 = 2) -> NSEvent? {
        guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0) else { return nil }
        cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        return NSEvent(cgEvent: cg)
    }
}

// MARK: Views

@MainActor
func findView(_ id: String, in view: NSView?) -> NSView? {
    guard let view else { return nil }
    if view.accessibilityIdentifier() == id { return view }
    for sub in view.subviews { if let hit = findView(id, in: sub) { return hit } }
    return nil
}

@MainActor
func click(_ id: String, in view: NSView?) -> Bool {
    guard let control = findView(id, in: view) as? NSControl else { return false }
    control.performClick(nil)
    return true
}

/// Runs a control's action without tracking, which performClick would do for popups and steppers.
@MainActor
func fire(_ control: NSControl) { control.sendAction(control.action, to: control.target) }

/// cacheDisplay of a view, composited over a backdrop so rounded corners and alpha are visible.
@MainActor
@discardableResult
func snapshot(_ view: NSView, name: String, dark: Bool = false, backdrop: NSColor? = nil, in window: NSWindow? = nil) -> URL? {
    let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    (window ?? view.window)?.appearance = appearance
    view.appearance = appearance
    view.layoutSubtreeIfNeeded()
    view.displayIfNeeded()
    let pw = Int(view.bounds.width * 2), ph = Int(view.bounds.height * 2)
    guard pw > 0, ph > 0, let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pw, pixelsHigh: ph, bitsPerSample: 8, samplesPerPixel: 4,
                                                     hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
        check(false, "snapshot \(name) could not create a bitmap")
        return nil
    }
    rep.size = view.bounds.size
    view.cacheDisplay(in: view.bounds, to: rep)
    let w = rep.pixelsWide, h = rep.pixelsHigh
    let ctx = Pix.context(w, h)
    let bg = backdrop ?? (dark ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.86, alpha: 1))
    ctx.setFillColor((bg.usingColorSpace(.sRGB) ?? bg).cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    if let cg = rep.cgImage { ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h)) }
    let url = URL(fileURLWithPath: scratch + name + ".png")
    guard let image = ctx.makeImage(), let png = AssetStore.pngData(from: image), (try? png.write(to: url)) != nil else {
        check(false, "snapshot \(name) could not be written")
        return nil
    }
    print("SNAPSHOT \(url.path) \(w)x\(h)")
    return url
}

/// A view that is not in any ordered window: give it a hidden, never-shown window so it lays out and resolves appearance.
@MainActor
func hostOffscreen(_ view: NSView, size: NSSize? = nil) -> NSWindow {
    let s = size ?? view.frame.size
    let w = NSWindow(contentRect: NSRect(origin: .zero, size: s), styleMask: [.titled], backing: .buffered, defer: true)
    w.isReleasedWhenClosed = false
    w.contentView = view
    view.frame = NSRect(origin: .zero, size: s)
    return w
}

@MainActor
func nothingOnScreen() -> Bool {
    NSApp.windows.allSatisfy { !$0.isVisible } && !NSApp.isActive
}
