import AppKit
import AVFoundation
import CornermarkCore
@testable import CornermarkVideoEditor
@testable import CornermarkShell

/// Films a zoom that follows the cursor for review: the real editor of a harness world, rendered offscreen, its project given a
/// scripted pointer track that rests, wiggles, leaves the middle of the view and turns back mid-drift. The orange box over the
/// preview, the speed chart and the caption are the harness's drawings from `frameState`, not part of the app.
/// Run with `CORNERMARK_FOLLOW_FILM=<folder> swift run HarnessShell`.
@MainActor
enum VideoFollowFilm {
    static func run(out: URL) async -> Bool {
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var ok = true
        let scenes: [(String, (Film, EditorStage, VideoEditorWindowController) async throws -> Void)] = [("Z5", z5), ("Z8", z8), ("Z9", z9), ("Z10", z10)]
        let only = ProcessInfo.processInfo.environment["CORNERMARK_FOLLOW_SCENES"].map { Set($0.split(separator: ",").map(String.init)) }
        for (name, scene) in scenes where only?.contains(name) ?? true {
            guard let film = Film(url: out.appendingPathComponent("\(name).mp4")) else { return false }
            do {
                let stage = try await EditorStage(film, frames: 600)
                stage.area = "display=1&x=0&y=0&width=1280&height=720"
                defer { stage.w.cleanup() }
                guard let editor = try await open(stage) else { throw FilmError.missing("the editor") }
                try await scene(film, stage, editor)
            } catch { film.failures.append("\(error)") }
            let written = await film.finish()
            print("FILM \(name).mp4 frames=\(written) failures=\(film.failures)")
            ok = ok && written > 0 && film.failures.isEmpty
        }
        return ok
    }

    // MARK: The scripted track

    nonisolated static let zoomStart = 1.0, zoomEnd = 9.0

    /// Rests in the middle, wiggles inside it from 1.6 s, leaves to the upper right at 3 s, rests, crosses to the lower left at 5 s,
    /// rests, heads up and right at 6.5 s and turns back left at 6.9 s while the camera is still on its way.
    nonisolated static func track(width w: Double, height h: Double) -> [PointerSample] {
        func ease(_ u: Double) -> Double { let x = min(max(u, 0), 1); return x * x * (3 - 2 * x) }
        func at(_ t: Double) -> (Double, Double) {
            if t < 1.6 { return (0.5, 0.5) }
            if t < 2.8 { let k = t - 1.6; return (0.5 + 0.08 * sin(7 * k), 0.5 + 0.07 * sin(5 * k)) }
            let wiggleEnd = (0.5 + 0.08 * sin(7 * 1.2), 0.5 + 0.07 * sin(5 * 1.2))
            func leg(_ a: (Double, Double), _ b: (Double, Double), _ t0: Double, _ d: Double) -> (Double, Double) {
                let e = ease((t - t0) / d); return (a.0 + (b.0 - a.0) * e, a.1 + (b.1 - a.1) * e)
            }
            if t < 3.0 { return wiggleEnd }
            if t < 5.0 { return leg(wiggleEnd, (0.84, 0.32), 3.0, 0.6) }
            if t < 6.5 { return leg((0.84, 0.32), (0.3, 0.74), 5.0, 0.7) }
            if t < 6.9 { return leg((0.3, 0.74), (0.62, 0.36), 6.5, 0.4) }
            return leg((0.62, 0.36), (0.22, 0.42), 6.9, 0.6)
        }
        return stride(from: 0.0, through: 10, by: 1.0 / 120).map { t in let p = at(t); return PointerSample(t: t, x: p.0 * w, y: p.1 * h) }
    }

    static func open(_ s: EditorStage) async throws -> VideoEditorWindowController? {
        guard let record = try await s.recordProject(), let folder = record.video?.location else { return nil }
        var project = try RecordingProjectFile.read(from: folder)
        project.events.pointer = track(width: project.source.pointWidth, height: project.source.pointHeight)
        project.edits.cursor = CursorSettings(scale: 2.2, style: .black)
        try RecordingProjectFile.write(project, to: folder)
        guard let editor = s.w.coordinator.openVideoEditor(folder) else { return nil }
        await s.show(editor)
        editor.addZoom(from: zoomStart, to: zoomEnd)
        editor.selectZoom(nil)
        editor.seek(to: 0)
        await s.settle(editor)
        return editor
    }

    // MARK: Scenes

    static func z5(_ f: Film, _ s: EditorStage, _ editor: VideoEditorWindowController) async throws {
        f.title = "Z5  Zoom Mode: Follow Cursor keeps the pointer in view as it moves. Manual holds the spot where the zoom was added (picking that spot by hand comes in a later change)."
        let x = Extras()
        layers(f, s, editor, x)
        guard let id = editor.state.project.edits.zooms.first?.id else { throw FilmError.missing("the zoom") }
        editor.selectZoom(id)
        await s.settle(editor)
        guard let mode = editor.view(identifier: "video.zoom.mode") as? NSPopUpButton, let window = editor.window else { throw FilmError.missing("the mode menu") }
        // The arrow rests on the menu's chevron, so the menu's title and the note under it stay readable.
        let chevron = { let c = f.center(of: mode, in: window, at: s.origin); return CGPoint(x: c.x + mode.bounds.width / 2 - 8, y: c.y) }
        f.glide(to: chevron(), "The zoom is picked. Its panel shows Mode: Follow Cursor and what that does.")
        f.hold(2.6, "The zoom is picked. Its panel shows Mode: Follow Cursor and what that does.")
        x.box = true
        await play(f, s, editor, from: 0, to: 9.6, note: "Follow Cursor: the camera keeps the pointer in view.")
        f.hold(0.8, "Follow Cursor: the camera keeps the pointer in view.")
        f.glide(to: chevron(), "Choosing Manual in the Mode menu.", frames: 10)
        mode.selectItem(at: 1)
        fire(mode)
        await s.settle(editor)
        f.hold(2.4, "Mode: Manual. The panel now says the camera stays on the spot where the zoom was added.")
        await play(f, s, editor, from: 0, to: 9.6, note: "Manual: the camera holds its spot and the pointer leaves the view.")
        mode.selectItem(at: 0)
        fire(mode)
        await s.settle(editor)
        f.hold(1.6, "Back to Follow Cursor.")
        f.dark = true
        f.refresh()
        await play(f, s, editor, from: 2.6, to: 6, note: "The same in Dark appearance.")
        f.hold(1, "The same in Dark appearance.")
    }

    static func z8(_ f: Film, _ s: EditorStage, _ editor: VideoEditorWindowController) async throws {
        park(f)
        f.title = "Z8  Following is not constant tracking: the camera holds, then drifts after the pointer and eases to a stop. Cornermark drifts smoothly instead of moving in separate steps."
        let x = Extras()
        x.box = true
        x.chart = true
        layers(f, s, editor, x)
        f.hold(2, "One zoom at 200%, 1.0 s to 9.0 s, Follow Cursor. The chart is the camera's speed, drawn by the harness from frameState.")
        await play(f, s, editor, from: 0, to: 9.6, note: "Playing at the recording's speed: still while the pointer wiggles in the middle, then a smooth drift each time it leaves.")
        f.hold(1, "Back at 100%.")
        await play(f, s, editor, from: 2.8, to: 4.6, speed: 0.25, note: "The first drift, slowed four times: the speed rises and falls without a step.")
        f.hold(1.2, "The camera came to rest a quarter of the view short of the pointer.")
        f.dark = true
        f.refresh()
        await play(f, s, editor, from: 4.8, to: 6.6, note: "The same in Dark appearance.")
        f.hold(1, "The same in Dark appearance.")
    }

    static func z9(_ f: Film, _ s: EditorStage, _ editor: VideoEditorWindowController) async throws {
        park(f)
        f.title = "Z9  What starts the drift: the pointer leaving the middle of the view (orange box). Inside it the camera does not move."
        let x = Extras()
        x.box = true
        x.chart = true
        layers(f, s, editor, x)
        f.hold(1.6, "The orange box is the middle half of the view, drawn by the harness.")
        await play(f, s, editor, from: 1.4, to: 2.95, speed: 0.5, note: "The pointer wiggles inside the box: camera speed 0.")
        await play(f, s, editor, from: 2.95, to: 3.9, speed: 0.2, note: "It reaches the box's edge and pushes past: the camera starts to drift, gently.")
        f.hold(1, "Once the pointer rests, the camera eases to a stop.")
        await play(f, s, editor, from: 4.8, to: 6.4, speed: 0.5, note: "Across to the lower left: out of the box again, so the camera drifts again.")
        f.dark = true
        f.refresh()
        await play(f, s, editor, from: 1.6, to: 3.8, note: "The same in Dark appearance.")
        f.hold(1, "The same in Dark appearance.")
    }

    static func z10(_ f: Film, _ s: EditorStage, _ editor: VideoEditorWindowController) async throws {
        park(f)
        f.title = String(format: "Z10  Cornermark's own choice: the box is the middle %d%% of the view, the drift settles 95%% of a move in 0.68 s, and a new target mid-drift bends the move.",
                         Int(ZoomFollow.deadZone * 100))
        let x = Extras()
        x.box = true
        x.chart = true
        layers(f, s, editor, x)
        f.hold(2.4, "The pointer can travel a quarter of the view from its centre before the camera moves. No reference shows this value.")
        await play(f, s, editor, from: 6.2, to: 7.0, speed: 0.25, note: "The pointer heads up and right, out of the box: the camera starts after it.")
        await play(f, s, editor, from: 7.0, to: 8.2, speed: 0.25, note: "Mid-drift the pointer turns back left: the camera slows, turns and follows, with no jump.")
        f.hold(1.2, "The speed chart never steps: a new target retargets the spring, it does not restart a move.")
        await play(f, s, editor, from: 6.0, to: 9.6, note: "The same at the recording's speed, through the move out.")
        f.dark = true
        f.refresh()
        await play(f, s, editor, from: 6.2, to: 8.2, speed: 0.5, note: "The same in Dark appearance.")
        f.hold(1, "The same in Dark appearance.")
    }

    // MARK: Helpers

    /// What the harness draws over the editor.
    final class Extras {
        var box = false
        var chart = false
    }

    static func play(_ f: Film, _ s: EditorStage, _ editor: VideoEditorWindowController, from: Double, to: Double, speed: Double = 1, note: String) async {
        await CursorFilm.play(f, s, editor, from: from, to: to, speed: speed, note: note)
    }

    /// The film's own arrow rests off the window, so the only arrow over the preview is the one the app draws.
    static func park(_ f: Film) { f.glide(to: CGPoint(x: Film.stage.width - 30, y: 20), "", frames: 1) }

    static func layers(_ f: Film, _ s: EditorStage, _ editor: VideoEditorWindowController, _ x: Extras) {
        f.status = { [unowned editor, unowned s] in status(s, editor) }
        f.layers = { [unowned editor, unowned s] in
            var layers = s.layers(editor)
            if x.box, let box = box(s, editor) { layers.append(box) }
            if x.chart, let chart = speedChart(s, editor) { layers.append((chart, CGRect(x: s.origin.x + 8, y: s.origin.y + 330, width: 286, height: 150))) }
            return layers
        }
        f.refresh()
    }

    /// The camera's centre in recording points and its speed in points a second at `t`, from `frameState`.
    static func camera(_ project: RecordingProject, at t: Double) -> (x: Double, y: Double, speed: Double) {
        func c(_ t: Double) -> (Double, Double) {
            let r = frameState(project, outputTime: t).crop
            return ((r.x + r.width / 2) * project.source.pointWidth, (r.y + r.height / 2) * project.source.pointHeight)
        }
        let a = c(t), b = c(t + 1.0 / 240)
        return (a.0, a.1, hypot(b.0 - a.0, b.1 - a.1) * 240)
    }

    /// Whether the drawn pointer is inside the middle half of the view at `t`.
    static func inside(_ project: RecordingProject, at t: Double) -> Bool? {
        let state = frameState(project, outputTime: t)
        guard let p = state.cursor, project.source.pointWidth > 0 else { return nil }
        let r = state.crop, fx = p.x / project.source.pointWidth, fy = p.y / project.source.pointHeight
        // A settled camera leaves the pointer exactly on the edge, so a hair's tolerance keeps rounding from calling that outside.
        let half = ZoomFollow.deadZone / 2 + 0.005
        return abs(fx - (r.x + r.width / 2)) <= r.width * half && abs(fy - (r.y + r.height / 2)) <= r.height * half
    }

    static func status(_ s: EditorStage, _ editor: VideoEditorWindowController) -> String {
        let project = editor.state.project
        let t = editor.state.transport.time(at: s.clock.now)
        let cam = camera(project, at: t), crop = frameState(project, outputTime: t).crop
        let mode = project.edits.zooms.first?.mode.title ?? "none"
        let cursor = editor.previewState?.cursor.map { String(format: "x=%.0f y=%.0f", $0.x, $0.y) } ?? "none"
        let held = project.edits.zooms.first?.mode == .followCursor && crop.width < 1 && abs(crop.scale - (project.edits.zooms.first?.scale ?? 1)) < 0.01
        let middle = held ? (inside(project, at: t).map { $0 ? "inside" : "OUTSIDE" } ?? "-") : "-"
        return String(format: "t=%@  mode=%@  scale=%.3f  camera centre x=%.0f y=%.0f  speed=%.0f pt/s  pointer %@  pointer vs middle half: %@",
                      Timecode.text(t), mode, crop.scale, cam.x, cam.y, cam.speed, cursor, middle)
    }

    /// The middle half of the view over the preview, while a following zoom holds its level. Drawn by the harness, not the app.
    static func box(_ s: EditorStage, _ editor: VideoEditorWindowController) -> (CGImage, CGRect)? {
        let project = editor.state.project
        let t = editor.state.transport.time(at: s.clock.now)
        let crop = frameState(project, outputTime: t).crop
        guard let zoom = project.edits.zooms.first, zoom.mode == .followCursor, crop.width < 1, abs(crop.scale - zoom.scale) < 0.01,
              let preview = editor.view(identifier: "video.preview") as? PreviewView else { return nil }
        let r = preview.convert(preview.pictureRect, to: nil)
        let k = ZoomFollow.deadZone
        let size = CGSize(width: r.width * k, height: r.height * k)
        let out = inside(project, at: t) == false
        let ctx = Pix.context(Int(size.width * 2), Int(size.height * 2))
        ctx.scaleBy(x: 2, y: 2)
        ctx.setStrokeColor(CGColor(srgbRed: 1, green: 0.55, blue: 0.1, alpha: 1))
        ctx.setLineWidth(out ? 3 : 2)
        if !out { ctx.setLineDash(phase: 0, lengths: [8, 5]) }
        ctx.stroke(CGRect(origin: .zero, size: size).insetBy(dx: 1.5, dy: 1.5))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        let label = out ? "Harness: pointer outside the middle half, the camera drifts" : "Harness: middle half of the view, the camera holds"
        (label as NSString).draw(at: CGPoint(x: 6, y: size.height - 18), withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                                                                                            .foregroundColor: NSColor(srgbRed: 1, green: 0.55, blue: 0.1, alpha: 1)])
        NSGraphicsContext.restoreGraphicsState()
        guard let image = ctx.makeImage() else { return nil }
        return (image, CGRect(x: s.origin.x + r.midX - size.width / 2, y: s.origin.y + r.midY - size.height / 2, width: size.width, height: size.height))
    }

    /// The camera centre's speed from 0 to the end, with a dot at the playhead. Drawn by the harness from `frameState`.
    static func speedChart(_ s: EditorStage, _ editor: VideoEditorWindowController) -> CGImage? {
        let size = CGSize(width: 286, height: 150)
        let ctx = Pix.context(Int(size.width * 2), Int(size.height * 2))
        ctx.scaleBy(x: 2, y: 2)
        ctx.setFillColor(CGColor(gray: 0.08, alpha: 0.88))
        ctx.addPath(CGPath(roundedRect: CGRect(origin: .zero, size: size), cornerWidth: 8, cornerHeight: 8, transform: nil))
        ctx.fillPath()
        let project = editor.state.project, d = editor.state.transport.duration
        let plot = CGRect(x: 38, y: 16, width: size.width - 50, height: size.height - 46)
        let samples = (0...480).map { i -> (Double, Double) in let t = d * Double(i) / 480; return (t, camera(project, at: t).speed) }
        let top = max(400, (samples.map(\.1).max() ?? 0) * 1.1)
        func p(_ t: Double, _ v: Double) -> CGPoint { CGPoint(x: plot.minX + plot.width * CGFloat(t / max(d, 1e-9)), y: plot.minY + plot.height * CGFloat(min(v / top, 1))) }
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.25))
        for v in stride(from: 0.0, through: top, by: top / 4) { ctx.move(to: p(0, v)); ctx.addLine(to: p(d, v)) }
        ctx.strokePath()
        ctx.setStrokeColor(CGColor(srgbRed: 1, green: 0.55, blue: 0.1, alpha: 1))
        ctx.setLineWidth(2)
        for (i, sample) in samples.enumerated() { i == 0 ? ctx.move(to: p(sample.0, sample.1)) : ctx.addLine(to: p(sample.0, sample.1)) }
        ctx.strokePath()
        let now = editor.state.transport.time(at: s.clock.now)
        let dot = p(now, camera(project, at: now).speed)
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: dot.x - 4, y: dot.y - 4, width: 8, height: 8))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 9, weight: .regular), .foregroundColor: NSColor(white: 1, alpha: 0.8)]
        for v in stride(from: 0.0, through: top, by: top / 2) { ("\(Int(v))" as NSString).draw(at: CGPoint(x: 4, y: p(0, v).y - 6), withAttributes: attrs) }
        ("Harness chart: camera speed, pt/s, from frameState" as NSString).draw(at: CGPoint(x: 10, y: size.height - 18),
                                                                              withAttributes: [.font: NSFont.systemFont(ofSize: 10, weight: .semibold), .foregroundColor: NSColor.white])
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }
}

/// Exports a video with one following zoom over the film's scripted pointer, for measuring the camera on a file Cornermark wrote.
/// `CORNERMARK_FOLLOW_EXPORT=<folder holding screen.mp4> swift run HarnessShell` writes `<folder>/followed.mp4` and `<folder>/truth.csv`,
/// the crop `frameState` gives at each frame.
enum FollowExport {
    static func run(folder: URL) async -> Bool {
        let video = folder.appendingPathComponent(RecordingProjectFile.videoName)
        let asset = AVURLAsset(url: video)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first, let size = try? await track.load(.naturalSize),
              let rate = try? await track.load(.nominalFrameRate), let duration = try? await asset.load(.duration).seconds else { return false }
        let source = RecordingProject.Source(pixelWidth: Int(size.width), pixelHeight: Int(size.height), pointWidth: size.width, pointHeight: size.height,
                                             fps: Int(rate.rounded()), duration: duration)
        var project = RecordingProject(source: source, events: .init(pointer: VideoFollowFilm.track(width: size.width, height: size.height)),
                                       edits: .init(zooms: [Zoom(start: VideoFollowFilm.zoomStart, end: VideoFollowFilm.zoomEnd, scale: 2)]))
        project.edits.cursor.isVisible = false
        let out = folder.appendingPathComponent("followed.mp4")
        try? FileManager.default.removeItem(at: out)
        do {
            let report = try await VideoExporter.export(project: project, video: video, settings: ExportSettings(), to: out)
            var csv = "frame,t,x,y,width\n"
            for i in 0..<report.framesWritten {
                let t = Double(i) / Double(source.fps), r = frameState(project, outputTime: t).crop
                csv += String(format: "%d,%.6f,%.9f,%.9f,%.9f\n", i, t, r.x, r.y, r.width)
            }
            try csv.write(to: folder.appendingPathComponent("truth.csv"), atomically: true, encoding: .utf8)
            print(String(format: "FOLLOW EXPORT %@ frames=%d seconds=%.3f size=%dx%d", out.path, report.framesWritten, report.duration, Int(size.width), Int(size.height)))
            return true
        } catch {
            print("FOLLOW EXPORT failed \(error)")
            return false
        }
    }
}
