import AppKit
import CornermarkCapture
import CornermarkCore
import CornermarkDesign
@testable import CornermarkShell

/// Films the real Camera pane and the real camera bubble view, offscreen, over the synthetic desktop. The camera is the synthetic one.
/// The bubble's window never appears in any capture, so this film is how its look on screen is shown.
@MainActor
enum CameraFilm {
    static func run(out: URL) async -> Bool {
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        guard let film = Film(url: out.appendingPathComponent("R11-onscreen.mp4")) else { return false }
        do { try await scene(film) } catch { film.failures.append("\(error)") }
        let frames = await film.finish()
        print("FILM R11-onscreen.mp4 frames=\(frames) failures=\(film.failures)")
        return frames > 0 && film.failures.isEmpty
    }

    static let k: CGFloat = 0.62
    static let origin = CGPoint(x: 16, y: 226)
    static let zoomBox = CGRect(x: 830, y: 226, width: 434, height: 446)

    static func toStage(_ r: CGRect) -> CGRect {
        CGRect(x: origin.x + r.minX * k, y: origin.y + r.minY * k, width: r.width * k, height: r.height * k)
    }

    static func scene(_ f: Film) async throws {
        let m = try ManualRecordingWorld()
        let w = m.world, c = w.coordinator
        var cameras: [ScriptedCameraSource] = []
        w.env.cameraAccess = { .allowed }
        w.env.cameraSource = {
            let camera = ScriptedCameraSource(pacing: .manual(origin: 0))
            cameras.append(camera)
            return camera
        }
        f.title = "R11 camera bubble: real Camera pane and real bubble view, rendered offscreen, synthetic camera"

        c.perform(.openSettings)
        guard let sw = c.settingsWindow, let window = sw.window, let pane = sw.panes.first(where: { $0 is CameraPane }) else { throw FilmError.missing("the Camera pane") }
        sw.select(pane: pane)
        f.layers = { f.windowLayer(window, at: f.settingsOrigin) }
        f.status = {
            let cam = w.settings.value.recording.camera
            return "settings.recording.camera: isVisible=\(cam.isVisible) shape=\(cam.shape.rawValue) size=\(cam.size.rawValue) corner=\(cam.position.rawValue) mirrored=\(cam.isMirrored)  CameraAccess.requests=\(CameraAccess.requests) LiveCameraSource.sessionsOpened=\(LiveCameraSource.sessionsOpened)"
        }
        f.refresh()
        f.hold(1.2, "Settings > Camera, camera off: its look cannot be changed yet")
        f.toggle("camera.show", in: sw, note: "Show camera on")
        if let shape = findView("camera.shape", in: pane.view) as? NSSegmentedControl {
            for i in [1, 2, 0] {
                f.glide(to: f.center(of: shape, in: window, at: f.settingsOrigin, segment: i), "Shape: \(CameraBubble.Shape.allCases[i].title)")
                shape.selectedSegment = i
                fire(shape)
                f.refresh()
                f.hold(0.6, "Shape: \(CameraBubble.Shape.allCases[i].title)")
            }
        }
        f.choose("camera.size", 1, in: sw, note: "Size: Medium")
        f.choose("camera.position", 0, in: sw, note: "Position: Bottom left")
        f.hold(1.0, "Mirror camera is on by default; camera access reads Allowed in this harness and is never asked for")
        window.close()

        var time = 0.0
        func screen() -> CGImage? {
            let size = FixtureFrameSource.displayFrame.size
            let ctx = Pix.context(Int(size.width), Int(size.height))
            ctx.translateBy(x: 0, y: size.height)
            ctx.scaleBy(x: 1, y: -1)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
            SyntheticScene.draw(size: size, time: time)
            NSGraphicsContext.restoreGraphicsState()
            return ctx.makeImage()
        }
        func bubbleImage() -> CGImage? {
            guard let view = c.controls.camera.view, view.bounds.width > 0 else { return nil }
            view.layoutSubtreeIfNeeded()
            view.displayIfNeeded()
            let s: CGFloat = 2
            let ctx = Pix.context(Int(view.bounds.width * s), Int(view.bounds.height * s))
            ctx.scaleBy(x: s, y: s)
            view.layer?.render(in: ctx)
            return ctx.makeImage()
        }
        f.layers = {
            var out: [(CGImage, CGRect)] = []
            if let s = screen() { out.append((s, toStage(FixtureFrameSource.displayFrame))) }
            if let bar = c.controls.bar, let view = c.controls.barView, let image = viewImageOf(view) { out.append((image, toStage(bar.frame))) }
            if let panel = c.controls.camera.panel, let image = bubbleImage() {
                out.append((image, toStage(panel.frame)))
                let fit = min(zoomBox.width / panel.frame.width, zoomBox.height / panel.frame.height, 1.6)
                let size = CGSize(width: panel.frame.width * fit, height: panel.frame.height * fit)
                out.append((image, CGRect(x: zoomBox.midX - size.width / 2, y: zoomBox.midY - size.height / 2, width: size.width, height: size.height)))
            }
            return out
        }
        f.status = {
            let look = c.recording.cameraLook?.current
            let panel = c.controls.camera.panel
            let window = panel.map { "window \"\($0.title)\" sharingType=\($0.sharingType == .none ? "none" : "readOnly") frame=\(NSStringFromRect($0.frame))" } ?? "no camera window"
            return "phase=\(c.recording.phase) look: \(look.map { "\($0.shape.rawValue) \($0.size.rawValue) \($0.position.rawValue) mirrored=\($0.isMirrored)" } ?? "none") fullScreen=\(c.recording.cameraLook?.isFullScreen ?? false) picture=\(c.controls.camera.view?.image.map { "\($0.width)x\($0.height)" } ?? "none") pictures=\(cameras.last?.picturesDelivered ?? 0)  \(window)"
        }
        // The camera's pictures reach the bubble through the main queue, so each film frame gives it a turn.
        func run(_ seconds: Double, _ note: String) async {
            for _ in 0..<Int(seconds * Double(Film.fps)) {
                time += 1 / Double(Film.fps)
                try? m.source?.advance(2)
                cameras.last?.advance(1)
                try? await Task.sleep(nanoseconds: 6_000_000)
                f.refresh()
                f.hold(1 / Double(Film.fps), note)
            }
        }
        f.hold(0.6, "cornermark://record?display=1&x=0&y=0&width=1280&height=720&style=editing")
        guard m.link("record?display=1&x=0&y=0&width=1280&height=720&style=editing"), await waitUntil(5, { m.phase == .recording }) else {
            throw FilmError.missing("a recording")
        }
        await run(2.0, "Recording: the camera's own window sits over the bottom-left of the area. Right: the same real view at a larger size")
        guard let view = c.controls.camera.view else { throw FilmError.missing("the bubble view") }
        let enter = NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                           eventNumber: 0, trackingNumber: 0, userData: nil)!
        view.mouseEntered(with: enter)
        await run(1.4, "Pointer over the bubble: a badge says a click fills the recording with the camera")
        _ = view.accessibilityPerformPress()
        await run(2.0, "Click: the camera fills the recorded area (the window grows to it; on screen this moves over 0.30 s)")
        _ = view.accessibilityPerformPress()
        view.mouseExited(with: enter)
        await run(1.4, "Click again: back to the bubble")
        for (q, note) in [("shape=square", "Shape: square"), ("shape=rectangle&corner=topRight", "Shape: rectangle, top right"),
                          ("size=large", "Size: large"), ("mirror=0", "Mirror off: the marker moves to the left side"),
                          ("size=small&corner=bottomRight&shape=circle&mirror=1", "Small mirrored circle, bottom right")] {
            _ = m.link("record/camera?\(q)")
            await run(1.6, "cornermark://record/camera?\(q)  \(note)")
        }
        if let panel = c.controls.camera.panel {
            panel.setFrameOrigin(NSPoint(x: 60, y: 600))
            await run(0.6, "Drag: the bubble is let go near the top-left")
            view.onDrop(CGPoint(x: panel.frame.midX, y: panel.frame.midY))
            await run(1.4, "and settles in the nearest corner, which the next recording keeps (settings corner=\(w.settings.value.recording.camera.position.rawValue))")
        }
        _ = m.link("record/stop")
        _ = await waitUntil(10, { m.phase == .idle })
        f.refresh()
        f.hold(1.5, "Stop: the camera's window closes. Real camera sessions opened: \(LiveCameraSource.sessionsOpened), access requests: \(CameraAccess.requests)")
        if LiveCameraSource.sessionsOpened != 0 || CameraAccess.requests != 0 { f.failures.append("a real camera was touched") }
    }

    private static func viewImageOf(_ view: NSView) -> CGImage? {
        let s: CGFloat = 2
        view.layoutSubtreeIfNeeded()
        guard view.bounds.width > 0, let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width * s), pixelsHigh: Int(view.bounds.height * s),
                                                                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                                                bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = view.bounds.size
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.cgImage
    }
}
