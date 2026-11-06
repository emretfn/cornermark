import AppKit
import CornermarkCapture
import CornermarkCore
import CornermarkDesign
@testable import CornermarkShell

/// Films the recording panel's source toggles: the real overlay and panel, offscreen, over the synthetic desktop, with the system in light
/// and then dark appearance. Clicks go through the panel's own buttons and the app's own toggle logic; macOS's answers come from the harness, which
/// counts every request. Writes `panel.mp4` and one picture of the panel per state. Run with `CORNERMARK_PANEL_SOURCES_FILM=<folder>`.
@MainActor
enum PanelSourcesFilm {
    static func run(out: URL) async -> Bool {
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        guard let film = Film(url: out.appendingPathComponent("panel.mp4")) else { return false }
        for dark in [false, true] {
            film.dark = dark
            do { try await scene(film, out: out) } catch { film.failures.append("\(error)") }
        }
        let frames = await film.finish()
        print("FILM panel.mp4 frames=\(frames) failures=\(film.failures)")
        return frames > 0 && film.failures.isEmpty
    }

    static func scene(_ f: Film, out: URL) async throws {
        let w = try World()
        defer { w.cleanup() }
        let c = w.coordinator
        var mic = MicrophoneAccess.notAsked, camera = CameraAccess.notAsked, input = false
        var requests: [RecordingSource: Int] = [:]
        w.env.microphoneAccess = { mic }
        w.env.requestMicrophoneAccess = { done in
            requests[.microphone, default: 0] += 1
            DispatchQueue.main.async { mic = .allowed; done(true) }
        }
        w.env.cameraAccess = { camera }
        w.env.requestCameraAccess = { done in
            requests[.camera, default: 0] += 1
            DispatchQueue.main.async { camera = .denied; done(false) }
        }
        w.env.hasInputPermission = { input }
        w.env.requestInputPermission = {
            requests[.input, default: 0] += 1
            return input
        }
        let mode = f.dark ? "dark" : "light"
        f.title = "Recording panel sources, system appearance \(mode): real overlay and panel rendered offscreen, synthetic desktop, permission answers from the harness"
        c.capture.lastSelection = PreviousSelection(rect: CGRect(x: 200, y: 180, width: 880, height: 420))
        c.perform(.capture(.recording))
        guard await waitUntil(5, { !c.capture.overlayWindows.isEmpty }), let window = c.capture.overlayWindows.first else { throw FilmError.missing("the overlay") }
        guard let panel = findView("cornermark.record.source.microphone", in: window.contentView)?.superview else { throw FilmError.missing("the panel") }
        // The system appearance changes; the overlay keeps its own dark appearance over any screen content, so both passes look alike.
        NSApp.appearance = NSAppearance(named: f.dark ? .darkAqua : .aqua)
        defer { NSApp.appearance = nil }

        func image(_ view: NSView, scale: CGFloat) -> CGImage? {
            view.layoutSubtreeIfNeeded()
            view.displayIfNeeded()
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width * scale), pixelsHigh: Int(view.bounds.height * scale),
                                             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                             bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
            rep.size = view.bounds.size
            view.cacheDisplay(in: view.bounds, to: rep)
            return rep.cgImage
        }
        let zoom = CGRect(x: 20, y: 20, width: panel.bounds.width * 1.6, height: panel.bounds.height * 1.6)
        f.layers = {
            var layers: [(CGImage, CGRect)] = []
            if let content = window.contentView, let screen = image(content, scale: 1) { layers.append((screen, window.frame)) }
            if let big = image(panel, scale: 3) { layers.append((big, zoom)) }
            return layers
        }
        f.status = {
            let r = w.settings.value.recording
            let asked = requests.map { "\($0.key.rawValue)=\($0.value)" }.sorted().joined(separator: " ")
            return "settings: microphone=\(r.audio.microphone) systemAudio=\(r.audio.systemAudio) camera=\(r.camera.isVisible) clicks=\(r.clicks.isVisible) keys=\(r.keystrokes.isVisible)  requests: \(asked.isEmpty ? "none" : asked)  real: mic=\(MicrophoneAccess.requests) camera=\(CameraAccess.requests) input=\(LiveInputSource.requests)"
        }
        func toggle(_ s: RecordingSource) -> IconButton? { findView("cornermark.record.source.\(s.rawValue)", in: window.contentView) as? IconButton }
        func snap(_ name: String) {
            guard let picture = image(panel, scale: 2), let data = NSBitmapImageRep(cgImage: picture).representation(using: .png, properties: [:]) else {
                return f.failures.append("no picture for \(name)")
            }
            try? data.write(to: out.appendingPathComponent("panel-\(mode)-\(name).png"))
        }
        func click(_ s: RecordingSource, _ note: String) async {
            guard let button = toggle(s) else { return f.failures.append("no toggle \(s.rawValue)") }
            f.glide(to: f.center(of: button, in: window, at: window.frame.origin), note)
            button.isHighlighted = true
            f.refresh()
            f.hold(0.15, note)
            button.isHighlighted = false
            button.performClick(nil)
            _ = await waitUntil(0.2) { false }
            f.refresh()
            f.hold(1.4, note)
        }

        f.refresh()
        f.hold(1.6, "Every source is off: four toggles with slashed glyphs, between the size row and the start buttons")
        snap("all-off")
        await click(.microphone, "Microphone: macOS has not asked yet, so it asks now. Allowed, the toggle turns on")
        await click(.systemAudio, "System audio needs no extra permission and turns on. The note says Record GIF never records sound")
        await click(.camera, "Camera: macOS asks now. Refused, it stays off and the note says where to allow it")
        snap("camera-refused")
        await click(.input, "Clicks and keys: Input Monitoring is asked for once. Refused, it stays off with a note")
        snap("input-refused")
        input = true
        camera = .allowed
        f.hold(0.8, "In System Settings the person allows Input Monitoring and the camera (set by the harness)")
        await click(.input, "Clicks and keys: allowed now, one click turns it on and asks nothing")
        await click(.camera, "Camera: allowed now, one click turns it on and asks nothing")
        snap("all-on")
        f.hold(1.0, "Everything on. Settings > Audio, Camera and Recording show the same choices")
        for s in RecordingSource.allCases { await click(s, "\(s.name) off") }
        snap("all-off-again")
        if requests != [.microphone: 1, .camera: 1, .input: 1] { f.failures.append("requests \(requests)") }
        if MicrophoneAccess.requests + CameraAccess.requests + LiveInputSource.requests != 0 { f.failures.append("a real prompt was asked for") }
        c.capture.cancel()
        _ = await waitUntil { c.capture.overlayWindows.isEmpty }
    }
}
