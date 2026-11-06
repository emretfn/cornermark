import AppKit
import AVFoundation
import CornermarkCapture
import CornermarkCore

/// Films the recording overlay for review: the real overlay windows and panel, offscreen, driven by scripted events through
/// `NSWindow.sendEvent`, one picture per frame. The desktop is the synthetic fixture. The pointer arrow and the caption strip are
/// drawn by this harness, because an offscreen window has neither. Run with `CORNERMARK_OVERLAY_FILM=<folder>`.
@MainActor
enum OverlayFilm {
    static let display = CGRect(x: 0, y: 0, width: 1280, height: 720)
    static let notes = Fixtures.window(21, "Draft", "Notes", 120, 140, 520, 340)
    static let terminal = Fixtures.window(22, "build", "Terminal", 600, 260, 560, 360)

    static func run(out: URL) async -> Bool {
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let screen = Fixtures.display(id: 1, frame: display, scale: 2, windows: [terminal, notes], seed: 4)
        let source = FixtureScreenSource(displays: [screen], windows: [terminal, notes])
        var ok = true
        for (name, scene) in [("R1", r1), ("R2", r2), ("R3", r3), ("R4", r4), ("R5", r5), ("R7", r7)] as [(String, (Reel) async -> Void)] {
            guard let reel = Reel(url: out.appendingPathComponent("\(name).mp4"), source: source, desktop: screen.image, row: name) else { return false }
            await scene(reel)
            let frames = await reel.finish()
            print("FILM \(name).mp4 frames=\(frames) failures=\(reel.failures)")
            ok = ok && frames > 0 && reel.failures.isEmpty
        }
        return ok
    }

    // MARK: Scenes

    static func r1(_ r: Reel) async {
        r.title = "R1  Record Screen starts from choosing an area. A small panel with size fields, the aspect lock and the start buttons sits in the selection."
        await r.open(at: CGPoint(x: 330, y: 520))
        r.hold(1.2, note: "Ctrl+Shift+9 (Record Screen) opened the overlay. Nothing is selected, so the start buttons wait.")
        r.drag(from: CGPoint(x: 330, y: 520), to: CGPoint(x: 950, y: 170), frames: 45, note: "Dragging an area")
        r.hold(1.5, note: "The panel sits in the middle of the selection: targets, W x H, aspect ratio, Record MP4, Record Project.")
        r.type("640", into: "width", note: "Typing an exact width")
        r.type("360", into: "height", note: "Typing an exact height")
        r.hold(1.0, note: "The selection is now 640 x 360, top-left corner kept.")
        r.choose(aspect: 2, note: "Aspect ratio set to 4:3 in the panel")
        r.hold(1.0, note: "The aspect lock keeps the width and makes it 4:3: 640 x 480.")
        await r.click("start.video", note: "Record MP4")
        await r.result(1.8)
    }

    static func r2(_ r: Reel) async {
        r.title = "R2  The panel has three start buttons, each showing its shortcut: Record MP4 (Return), Record Project (Shift-Return), Record GIF (Option-Return)."
        let area = CGRect(x: 300, y: 180, width: 680, height: 380)
        r.remember(area)
        await r.open(at: CGPoint(x: 640, y: 300))
        r.hold(1.5, note: "Record MP4 is the one primary action. Record Project keeps the pointer and edits changeable. Record GIF makes an animated GIF.")
        r.glide(to: r.center(of: "start.video"), frames: 18, note: "Record MP4 shows Return")
        r.hold(0.8, note: "Record MP4 shows Return")
        r.glide(to: r.center(of: "start.editing"), frames: 14, note: "Record Project shows Shift-Return")
        r.hold(0.8, note: "Record Project shows Shift-Return")
        r.key(36, "\r", [.shift], note: "Pressed Shift-Return")
        await r.result(1.6)
        r.remember(area)
        await r.open(at: CGPoint(x: 640, y: 300))
        r.hold(0.6, note: "Opened again on the same area")
        r.key(36, "\r", [], note: "Pressed Return")
        await r.result(1.6)
        r.remember(area)
        await r.open(at: CGPoint(x: 640, y: 300))
        await r.click("start.editing", note: "Clicked Record Project")
        await r.result(1.6)
    }

    static func r7(_ r: Reel) async {
        r.title = "R7  Record GIF from the panel: its button, or Option-Return. The overlay hands the area over as a GIF recording."
        let area = CGRect(x: 300, y: 180, width: 680, height: 380)
        r.remember(area)
        await r.open(at: CGPoint(x: 640, y: 300))
        r.hold(1.2, note: "The overlay opens on the last area. Three start buttons: Record MP4, Record Project, Record GIF.")
        r.glide(to: r.center(of: "start.gif"), frames: 18, note: "Record GIF shows Option-Return")
        r.hold(1.0, note: "Record GIF shows Option-Return")
        await r.click("start.gif", note: "Clicked Record GIF")
        await r.result(1.8)
        r.remember(area)
        await r.open(at: CGPoint(x: 640, y: 300))
        r.hold(0.6, note: "Opened again on the same area")
        r.key(36, "\r", [.option], note: "Pressed Option-Return")
        await r.result(1.8)
        await r.open(at: CGPoint(x: 640, y: 680))
        await r.click("target.window", note: "Window target")
        r.glide(to: CGPoint(x: 330, y: 230), frames: 22, note: "Hovering Notes")
        r.clickDesktop(note: "Clicked Notes: it stays picked")
        await r.click("start.gif", note: "Record GIF of just that window")
        await r.result(1.8)
    }

    static func r3(_ r: Reel) async {
        r.title = "R3  Choose what to record: a custom area, a window, or the whole display, from the panel's target buttons."
        await r.open(at: CGPoint(x: 200, y: 600))
        r.drag(from: CGPoint(x: 200, y: 600), to: CGPoint(x: 760, y: 300), frames: 30, note: "Area: drag any rectangle")
        r.hold(1.0, note: "Target: Area")
        await r.click("target.window", note: "Window target")
        r.glide(to: CGPoint(x: 300, y: 300), frames: 20, note: "Window: the window under the pointer lights up")
        r.glide(to: CGPoint(x: 900, y: 500), frames: 24, note: "Window: the window under the pointer lights up")
        r.hold(0.8, note: "Window: Terminal under the pointer")
        await r.click("target.fullscreen", note: "Fullscreen target")
        r.hold(1.4, note: "Fullscreen selects the whole display and waits for a start button; the fields read 1280 x 720.")
        await r.click("target.area", note: "Area target again")
        r.hold(0.8, note: "Back to drawing an area")
        r.drag(from: CGPoint(x: 420, y: 560), to: CGPoint(x: 1000, y: 220), frames: 26, note: "Area")
        await r.click("start.video", note: "Record MP4")
        await r.result(1.5)
        await r.open(at: CGPoint(x: 640, y: 360))
        await r.click("target.fullscreen", note: "Fullscreen target")
        r.key(36, "\r", [], note: "Pressed Return")
        await r.result(1.5)
        await r.open(at: CGPoint(x: 640, y: 360))
        await r.click("target.window", note: "Window target")
        r.glide(to: CGPoint(x: 350, y: 330), frames: 18, note: "Pointing at Notes")
        r.clickDesktop(note: "Clicked Notes")
        r.key(36, "\r", [], note: "Pressed Return")
        await r.result(1.5)
    }

    static func r4(_ r: Reel) async {
        r.title = "R4  Record a single window: pick it with a click, then start. The recording follows that window, not a screen area."
        await r.open(at: CGPoint(x: 640, y: 680))
        await r.click("target.window", note: "Window target")
        r.glide(to: CGPoint(x: 900, y: 560), frames: 22, note: "Hovering Terminal")
        r.glide(to: CGPoint(x: 330, y: 230), frames: 22, note: "Hovering Notes")
        r.clickDesktop(note: "Clicked Notes: it stays picked")
        r.hold(1.2, note: "Picked. The panel shows the window's size, read-only.")
        r.glide(to: CGPoint(x: 1050, y: 560), frames: 22, note: "Moving away keeps the pick")
        r.hold(0.6, note: "Moving away keeps the pick")
        r.clickDesktop(note: "Clicked Terminal: the pick moves to it")
        r.hold(1.2, note: "Terminal picked")
        await r.click("start.video", note: "Record MP4")
        await r.result(2.0)
    }

    static func r5(_ r: Reel) async {
        r.title = "R5  Aspect lock, Option to grow from the centre, snapping to window and display edges, and the last area remembered."
        await r.open(at: CGPoint(x: 640, y: 100))
        r.choose(aspect: 3, note: "Aspect ratio 16:9 before drawing")
        r.drag(from: CGPoint(x: 260, y: 600), to: CGPoint(x: 700, y: 420), frames: 30, note: "Aspect lock: the drag keeps 16:9")
        r.hold(1.0, note: "Aspect lock: the drag keeps 16:9")
        r.choose(aspect: 0, note: "Aspect ratio back to Free")
        r.drag(from: CGPoint(x: 1000, y: 200), to: CGPoint(x: 1100, y: 260), frames: 34, modifiers: [.option], note: "Option held: grows from its centre (1000, 200)")
        r.hold(1.0, note: "Option held: the centre stayed at (1000, 200)")
        r.drag(from: CGPoint(x: 200, y: 640), to: CGPoint(x: 596, y: 330), frames: 24, note: "Drawing: the corner pulls onto Terminal's left edge (600)")
        r.hold(1.0, note: "Snapped: right edge at 600, Terminal's left edge, from 4 points away")
        if let handle = r.selection.map({ CGPoint(x: $0.maxX, y: $0.midY) }) {
            r.drag(from: handle, to: CGPoint(x: 634, y: handle.y), frames: 30, note: "Dragging the right edge towards Notes' edge")
            r.hold(1.4, note: "Snapped: the edge jumped onto Notes' right edge (640) from 6 points away")
            r.drag(from: CGPoint(x: 640, y: handle.y), to: CGPoint(x: 634, y: handle.y), frames: 14, modifiers: [.command], note: "Command held: no snapping")
            r.hold(1.2, note: "Command held: the edge stays at 634")
        }
        r.drag(from: CGPoint(x: 300, y: 370), to: CGPoint(x: 300, y: 445), frames: 24, note: "Moving the selection up towards the top of the display")
        r.hold(1.4, note: "Moved and snapped: top flush with the display (720), right edge back on Notes (640)")
        await r.click("start.video", note: "Record MP4")
        await r.result(1.4)
        await r.open(at: CGPoint(x: 640, y: 100))
        r.hold(2.0, note: "Opened again: the last area is already selected")
        r.key(53, "\u{1b}", [], note: "Escape leaves without recording")
        await r.result(1.2)
    }
}

/// One video file and the overlay session it films.
@MainActor
final class Reel {
    static let scale: CGFloat = 1.5
    static let captionHeight = 132
    static let fps: Int32 = 30

    let row: String
    var title = ""
    private(set) var failures: [String] = []
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let width: Int
    private let height: Int
    private let source: FixtureScreenSource
    private let desktop: CGImage
    private var controller: CaptureController
    private var outcome: CaptureOutcome?
    private var cursor = CGPoint.zero
    private var frames = 0
    private var last: CGImage?

    init?(url: URL, source: FixtureScreenSource, desktop: CGImage, row: String) {
        try? FileManager.default.removeItem(at: url)
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mp4) else { return nil }
        width = Int(OverlayFilm.display.width * Self.scale)
        height = Int(OverlayFilm.display.height * Self.scale) + Self.captionHeight
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 8_000_000],
        ])
        input.expectsMediaDataInRealTime = false
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        guard writer.startWriting() else { return nil }
        writer.startSession(atSourceTime: .zero)
        self.writer = writer
        self.source = source
        self.desktop = desktop
        self.row = row
        controller = CaptureController(source: source, presentation: .offscreen)
        controller.settleDelay = 0
    }

    private var window: NSWindow? { controller.overlayWindows.first }

    var selection: CGRect? {
        switch controller.overlayState {
        case .adjusting(let s, _)?: return s.rect
        case .dragging(let d)?: return d.rect
        default: return nil
        }
    }

    // MARK: Driving

    func remember(_ rect: CGRect) { controller.lastSelection = PreviousSelection(rect: rect) }

    func open(at p: CGPoint) async {
        cursor = p
        outcome = nil
        let remembered = controller.lastSelection
        controller = CaptureController(source: source, presentation: .offscreen)
        controller.settleDelay = 0
        controller.lastSelection = remembered
        controller.pointerLocation = { p }
        controller.begin(.recording) { [weak self] in self?.outcome = $0 }
        if !(await waitUntil { self.window != nil }) { failures.append("the overlay did not open") }
        if let window { Synth.move(window, to: p) }
    }

    func hold(_ seconds: Double, note: String) {
        for _ in 0..<max(1, Int(seconds * Double(Self.fps))) { frame(note) }
    }

    func glide(to p: CGPoint, frames n: Int, note: String, pressed: Bool = false, modifiers: NSEvent.ModifierFlags = []) {
        let a = cursor
        for i in 1...max(1, n) {
            let t = CGFloat(i) / CGFloat(max(1, n))
            let e = t * t * (3 - 2 * t)
            cursor = CGPoint(x: a.x + (p.x - a.x) * e, y: a.y + (p.y - a.y) * e)
            if let window { pressed ? Synth.dragged(window, to: cursor, modifiers: modifiers) : Synth.move(window, to: cursor) }
            frame(note)
        }
    }

    func drag(from a: CGPoint, to b: CGPoint, frames n: Int, modifiers: NSEvent.ModifierFlags = [], note: String) {
        if cursor != a { glide(to: a, frames: 10, note: note) }
        guard let window else { return failures.append("no overlay to drag in") }
        // A press on one of the panel's controls would start AppKit's own tracking loop, which waits for real input.
        if window.contentView?.hitTest(window.convertPoint(fromScreen: a)) is NSControl { return failures.append("a drag began on a control at \(a)") }
        Synth.down(window, at: a, modifiers: modifiers)
        frame(note)
        glide(to: b, frames: n, note: note, pressed: true, modifiers: modifiers)
        Synth.up(window, at: b, modifiers: modifiers)
        frame(note)
    }

    func clickDesktop(note: String) {
        guard let window else { return failures.append("no overlay to click in") }
        Synth.down(window, at: cursor)
        Synth.up(window, at: cursor)
        hold(0.3, note: note)
    }

    func center(of id: String) -> CGPoint {
        guard let view = findView("cornermark.record." + id, in: controller.overlayWindows) else { failures.append("no \(id)"); return cursor }
        let r = view.convert(view.bounds, to: nil)
        return CGPoint(x: r.midX, y: r.midY)
    }

    func click(_ id: String, note: String) async {
        let target = center(of: id)
        glide(to: target, frames: 16, note: note)
        guard let button = findView("cornermark.record." + id, in: controller.overlayWindows) as? NSButton else { return failures.append("no button \(id)") }
        if !button.isEnabled { failures.append("\(id) was disabled when clicked") }
        button.isHighlighted = true
        hold(0.2, note: note)
        button.isHighlighted = false
        button.performClick(nil)
        _ = await waitUntil(1) { self.outcome != nil || self.window != nil }
        frame(note)
    }

    func type(_ text: String, into id: String, note: String) {
        guard let field = findView("cornermark.record." + id, in: controller.overlayWindows) as? NSTextField else { return failures.append("no field \(id)") }
        glide(to: center(of: id), frames: 14, note: note)
        for i in 1...text.count {
            field.stringValue = String(text.prefix(i))
            hold(0.15, note: note)
        }
        field.sendAction(field.action, to: field.target)
        frame(note)
    }

    func choose(aspect index: Int, note: String) {
        guard let popup = findView("cornermark.record.aspect", in: controller.overlayWindows) as? NSPopUpButton else { return failures.append("no aspect menu") }
        glide(to: center(of: "aspect"), frames: 14, note: note)
        popup.selectItem(at: index)
        popup.sendAction(popup.action, to: popup.target)
        hold(0.4, note: note)
    }

    func key(_ code: UInt16, _ chars: String, _ modifiers: NSEvent.ModifierFlags, note: String) {
        guard let window else { return failures.append("no overlay for a key") }
        Synth.key(window, code, chars, modifiers: modifiers)
        frame(note)
    }

    /// The overlay has closed: the desktop as it is, with what the overlay handed over.
    func result(_ seconds: Double) async {
        _ = await waitUntil(1) { self.outcome != nil }
        if window != nil { failures.append("the overlay is still open after a start") }
        let text: String
        switch outcome {
        case .record(let target, let style)?:
            let what: String
            switch target {
            case .window(let id):
                let name = [OverlayFilm.notes, OverlayFilm.terminal].first { $0.id == id }.map { " (\($0.appName))" } ?? ""
                what = "window \(id)\(name) only"
            case .display(let id, let area?):
                what = "display \(id.map(String.init) ?? "?"), area at (\(Int(area.minX)), \(Int(area.minY))) size \(Int(area.width)) x \(Int(area.height))"
            case .display(let id, nil):
                what = "the whole of display \(id.map(String.init) ?? "?")"
            }
            let result: [RecordingStyle: String] = [.video: "a video (Record MP4)", .editing: "a project (Record Project)", .gif: "an animated GIF (Record GIF)"]
            text = "Overlay closed. It asks to record \(what), as \(result[style] ?? style.rawValue)."
        case .cancelled?: text = "Overlay closed. Nothing is recorded."
        default:
            text = "Overlay closed with no outcome."
            failures.append("no outcome")
        }
        for _ in 0..<Int(seconds * Double(Self.fps)) { frame(text, overlay: false) }
    }

    func finish() async -> Int {
        input.markAsFinished()
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in writer.finishWriting { done.resume() } }
        if writer.status != .completed { failures.append("writer: \(String(describing: writer.error))") }
        return frames
    }

    // MARK: Pictures

    private func frame(_ note: String, overlay: Bool = true) {
        var picture: CGImage?
        if overlay, let content = window?.contentView { picture = render(content) } else if !overlay { picture = desktop }
        guard let screen = picture ?? last else { return }
        if overlay { last = screen }
        guard let buffer = pixelBuffer() else { return }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return }
        let caption = CGFloat(Self.captionHeight)
        let screenRect = CGRect(x: 0, y: caption, width: CGFloat(width), height: CGFloat(height) - caption)
        ctx.interpolationQuality = .high
        ctx.draw(screen, in: screenRect)
        if overlay { drawPointer(ctx, at: CGPoint(x: cursor.x * Self.scale, y: caption + cursor.y * Self.scale)) }
        ctx.setFillColor(CGColor(gray: 0.08, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: caption))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        let small: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 19, weight: .medium), .foregroundColor: NSColor(white: 0.62, alpha: 1)]
        let big: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 26, weight: .semibold), .foregroundColor: NSColor.white]
        let mono: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 18, weight: .regular), .foregroundColor: NSColor(white: 0.78, alpha: 1)]
        (title as NSString).draw(in: CGRect(x: 24, y: 92, width: CGFloat(width) - 48, height: 30), withAttributes: small)
        (note as NSString).draw(in: CGRect(x: 24, y: 50, width: CGFloat(width) - 48, height: 36), withAttributes: big)
        let state = overlay ? describe(controller.overlayState) : "harness: synthetic desktop, real overlay views rendered offscreen, pointer arrow drawn by the harness"
        (state as NSString).draw(in: CGRect(x: 24, y: 14, width: CGFloat(width) - 48, height: 26), withAttributes: mono)
        NSGraphicsContext.restoreGraphicsState()
        let time = CMTime(value: CMTimeValue(frames), timescale: Self.fps)
        while !input.isReadyForMoreMediaData { RunLoop.current.run(until: Date().addingTimeInterval(0.002)) }
        if adaptor.append(buffer, withPresentationTime: time) { frames += 1 } else { failures.append("append failed at \(frames)") }
    }

    private func render(_ view: NSView) -> CGImage? {
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height - Self.captionHeight, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = view.bounds.size
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.cgImage
    }

    private func pixelBuffer() -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        if let pool = adaptor.pixelBufferPool { CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) }
        return buffer
    }

    private func drawPointer(_ ctx: CGContext, at p: CGPoint) {
        let s: CGFloat = 1.5
        let shape: [CGPoint] = [(0, 0), (0, -17), (4, -13), (7, -20), (10, -19), (7, -12), (12, -12)].map { CGPoint(x: p.x + $0.0 * s, y: p.y + $0.1 * s) }
        let path = CGMutablePath()
        path.addLines(between: shape)
        path.closeSubpath()
        ctx.addPath(path)
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 1))
        ctx.setLineWidth(2)
        ctx.drawPath(using: .fillStroke)
    }

    private func describe(_ state: OverlayState?) -> String {
        func r(_ rect: CGRect) -> String {
            "x \(Int(rect.minX)) y \(Int(rect.minY)) w \(Int(rect.width)) h \(Int(rect.height))  centre (\(Int(rect.midX)), \(Int(rect.midY)))  ratio \(String(format: "%.3f", rect.width / max(rect.height, 1)))"
        }
        switch state {
        case .armed?: return "state: armed"
        case .dragging(let d)?: return "state: dragging  \(r(d.rect))\(d.fromCenter ? "  from centre" : "")"
        case .adjusting(let s, _)?: return "state: selected  \(r(s.rect))"
        case .windowHover(let w)?: return "state: window target, hovering \(w.map { "\($0.appName) \(Int($0.frame.width)) x \(Int($0.frame.height))" } ?? "nothing")"
        case .windowPicked(let w)?: return "state: window picked  \(w.appName) (id \(w.id))  \(Int(w.frame.width)) x \(Int(w.frame.height))"
        case nil: return "state: closed"
        default: return "state: \(String(describing: state!))"
        }
    }
}
