import AppKit
import AVFoundation
import CornermarkCore
import CornermarkDesign
@testable import CornermarkVideoEditor
@testable import CornermarkShell

/// Films motion blur for review. B8 is the real editor of a harness world, rendered offscreen and driven by scripted presses and
/// slider moves on its Motion Blur panel while the preview is paused on a fast zoom and a fast pointer. B9 lays frames read back from
/// three exports of the same project side by side, blur off, 180° and 360°, at one-eighth speed through a fast zoom, a pan and a pointer
/// sweep. No key events are sent. The pointer arrow, captions and labels are drawn by the harness.
/// Run with `CORNERMARK_BLUR_FILM=<folder> swift run HarnessShell`.
@MainActor
enum VideoMotionBlurFilm {
    static func run(out: URL) async -> Bool {
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var ok = true
        for (name, scene) in [("B8", b8), ("B9", b9)] as [(String, (Film, EditorStage) async throws -> Void)] {
            guard let film = Film(url: out.appendingPathComponent("\(name).mp4")) else { return false }
            do {
                let stage = try await EditorStage(film, frames: 480)
                stage.area = name == "B8" ? "display=1&x=0&y=0&width=1280&height=720" : "display=1&x=0&y=0&width=640&height=360"
                defer { stage.w.cleanup() }
                try await scene(film, stage)
            } catch { film.failures.append("\(error)") }
            let written = await film.finish()
            print("FILM \(name).mp4 frames=\(written) failures=\(film.failures)")
            ok = ok && written > 0 && film.failures.isEmpty
        }
        return ok
    }

    static func openScripted(_ s: EditorStage) async throws -> VideoEditorWindowController {
        guard let record = try await s.recordProject(), let folder = record.video?.location else { throw FilmError.missing("the recording") }
        var project = try RecordingProjectFile.read(from: folder)
        BlurScene.apply(&project)
        try RecordingProjectFile.write(project, to: folder)
        guard let editor = s.w.coordinator.openVideoEditor(folder) else { throw FilmError.missing("the editor") }
        await s.show(editor)
        s.film.status = { [unowned s, unowned editor] in
            let p = editor.state.project, t = editor.state.transport.time(at: s.clock.now)
            let n = exportSamples(p, at: t).count
            return String(format: "blur=%@ shutter=%d° t=%.3f samples-at-t=%d preview=%@", p.edits.motionBlur.scope.rawValue, Int(p.edits.motionBlur.shutterAngle), t, n,
                          editor.previewStill == nil ? "sharp layers" : "blurred still")
        }
        return editor
    }

    // MARK: B8

    static func b8(_ f: Film, _ s: EditorStage) async throws {
        f.title = "B8  Motion Blur: what blurs (Off, Zooms, Zooms + cursor) and Intensity, the shutter angle. Paused, the preview shows the export's blurred frame."
        let editor = try await openScripted(s)
        let project = editor.state.project
        let zoom = BlurScene.fastestCrop(project, in: 1.0...1.8), pointer = BlurScene.fastestPointer(project, in: 6.0...6.45)
        f.hold(1.2, "A recording with two zooms to 300% and a pointer sweep. Blur starts on: Zooms + cursor, 180°.")
        await s.press(editor.view(identifier: "video.rail.motionBlur") as! NSButton, in: editor, note: "Motion Blur in the settings rail")
        f.hold(2, "The section: what blurs, a note on it, and Intensity in degrees of shutter.")
        await seek(zoom, f, s, editor, "Paused on the fastest frame of the zoom moving in: the picture smears along the move.")
        await scope(0, f, s, editor, "Off: every frame is sharp, the preview is back to its live layers.")
        await scope(1, f, s, editor, "Zooms: the zoom's move blurs again.")
        await slide(through: [180, 360, 60, 180], f, s, editor)
        await seek(pointer, f, s, editor, "Paused on the fastest frame of the pointer sweep. Zooms: the camera is still, so the pointer is sharp.")
        await scope(2, f, s, editor, "Zooms + cursor: the pointer smears along its path. The recording under it stays sharp.")
        await slide(through: [180, 360, 180], f, s, editor)
        await seek(BlurScene.fastestCrop(project, in: 2.9...3.6), f, s, editor, "The pan from one zoom to the next blurs sideways.")
        await s.play(editor, seconds: 1.2, note: "Playing: the preview draws sharp frames live. The export always blurs.")
        await seek(zoom, f, s, editor, "Paused again: the blurred frame is back once it is drawn, off the main thread.")
        f.dark = true
        f.refresh()
        f.hold(2.2, "The same in Dark appearance.")
        f.dark = false
        f.refresh()
        editor.undo()
        await s.settle(editor)
        f.hold(1.4, "Edit > Undo: the last change to blur goes back in one step.")
    }

    private static func seek(_ t: Double, _ f: Film, _ s: EditorStage, _ editor: VideoEditorWindowController, _ note: String) async {
        editor.seek(to: t)
        await s.settle(editor)
        await editor.previewSettled()
        f.refresh()
        f.hold(2.4, note)
    }

    private static func scope(_ index: Int, _ f: Film, _ s: EditorStage, _ editor: VideoEditorWindowController, _ note: String) async {
        guard let control = editor.view(identifier: "video.blur.scope") as? Segments, let window = editor.window else { return f.failures.append("no scope control") }
        f.glide(to: f.center(of: control, in: window, at: s.origin, segment: index), MotionBlurPanel.title(MotionBlur.Scope.allCases[index]), frames: 12)
        control.selectedSegment = index
        fire(control)
        await s.settle(editor)
        await editor.previewSettled()
        f.refresh()
        f.hold(2.2, note)
    }

    private static func slide(through values: [Double], _ f: Film, _ s: EditorStage, _ editor: VideoEditorWindowController) async {
        guard let slider = editor.view(identifier: "video.blur.intensity") as? TrackingSlider else { return f.failures.append("no intensity slider") }
        func knob(_ v: Double) -> CGPoint {
            let r = slider.convert(slider.bounds, to: nil), k = (v - slider.minValue) / (slider.maxValue - slider.minValue)
            return CGPoint(x: s.origin.x + r.minX + 7 + CGFloat(k) * (r.width - 14), y: s.origin.y + r.midY)
        }
        f.glide(to: knob(slider.doubleValue), "Intensity")
        for (a, b) in zip(values, values.dropFirst()) {
            for i in 1...18 {
                let t = Double(i) / 18, e = t * t * (3 - 2 * t)
                slider.doubleValue = a + (b - a) * e
                fire(slider)
                await s.settle(editor)
                await editor.previewSettled()
                f.refresh()
                f.glide(to: knob(slider.doubleValue), "Intensity \(Int(editor.state.project.edits.motionBlur.shutterAngle))°", frames: 1)
            }
            f.hold(1.2, "Intensity \(Int(b))°: " + (b >= 360 ? "the shutter is open the whole frame." : b <= 90 ? "a short shutter, a faint smear." : "half a frame, the default."))
        }
        slider.onTrackingEnd()
    }

    // MARK: B9

    static func b9(_ f: Film, _ s: EditorStage) async throws {
        f.title = "B9  Motion blur covers the zoom, the pan and the pointer. Frames read back from three exports of one project, shown at one-eighth speed."
        let editor = try await openScripted(s)
        let base = editor.state.project
        var files: [(String, URL)] = []
        for (label, blur) in [("Off", MotionBlur(scope: .off)), ("180°", MotionBlur()), ("360°", MotionBlur(shutterAngle: 360))] {
            var p = base
            p.edits.motionBlur = blur
            let out = s.w.root.appendingPathComponent("b9-\(files.count).mp4")
            f.hold(0.2, "Exporting with blur \(label)")
            let r = try await VideoExporter.export(project: p, video: editor.videoURL, settings: ExportSettings(), to: out)
            print(String(format: "B9 export %@ %dx%d render=%.2fs blurred=%d drawings=%d", label, r.plan.width, r.plan.height, r.renderSeconds, r.blurredFrames, r.drawings))
            files.append((label, out))
        }
        f.layers = { [] }
        f.glide(to: CGPoint(x: Film.stage.width - 2, y: 2), "Three exports written", frames: 1)
        let zoom = BlurScene.fastestCrop(base, in: 1.0...1.8), pan = BlurScene.fastestCrop(base, in: 2.9...3.6)
        let pointer = BlurScene.fastestPointer(base, in: 6.0...6.45)
        for (t, note) in [(zoom, "Zoom moving in: Off is sharp, 180° smears along the move, 360° smears twice as far."),
                          (pan, "Pan from one zoom to the next: the picture smears sideways."),
                          (pointer, "Pointer sweep with the camera still: only the pointer smears. The recording under it is sharp.")] {
            let detail = await mostBlurred(files, at: t)
            try await stretch(files, from: t - 0.25, to: t + 0.25, detail: detail, f, note)
        }
        try await still(files, at: zoom, detail: await mostBlurred(files, at: zoom), f, String(format: "Held at %.3f s, the fastest zoom frame.", zoom))
        try await still(files, at: pointer, detail: await mostBlurred(files, at: pointer), f, String(format: "Held at %.3f s, the fastest pointer frame.", pointer))
    }

    /// Where blur changes the picture most at `t`: the centre of the 16 x 9 cell where the sharp and 360° frames differ most, as fractions from the top-left.
    private static func mostBlurred(_ files: [(String, URL)], at t: Double) async -> CGPoint {
        guard let a = await decodedFrame(files[0].1, at: t), let b = await decodedFrame(files[files.count - 1].1, at: t),
              let pa = Pix.bytes(a), let pb = Pix.bytes(b) else { return CGPoint(x: 0.5, y: 0.5) }
        var cells = [Int](repeating: 0, count: 16 * 9)
        for y in stride(from: 0, to: a.height, by: 3) {
            for x in stride(from: 0, to: a.width, by: 3) {
                let i = (y * a.width + x) * 4
                cells[min(y * 9 / a.height, 8) * 16 + min(x * 16 / a.width, 15)] += abs(Int(pa[i]) - Int(pb[i])) + abs(Int(pa[i + 1]) - Int(pb[i + 1]))
            }
        }
        let best = cells.indices.max { cells[$0] < cells[$1] } ?? 0
        return CGPoint(x: (Double(best % 16) + 0.5) / 16, y: (Double(best / 16) + 0.5) / 9)
    }

    private static func stretch(_ files: [(String, URL)], from: Double, to: Double, detail: CGPoint, _ f: Film, _ note: String) async throws {
        var t = (from * 60).rounded() / 60
        while t <= to {
            guard let board = await board(files, at: t, detail: detail) else { throw FilmError.missing(String(format: "frames at %.3f s", t)) }
            f.layers = { [(board, CGRect(x: 20, y: 20, width: Film.stage.width - 40, height: Film.stage.height - 40))] }
            let at = t
            f.status = { String(format: "t=%.3f s  one-eighth speed: each 60 fps exported frame shows for 4 film frames at 30 fps", at) }
            f.refresh()
            f.hold(4.0 / Double(Film.fps), note)
            t += 1.0 / 60
        }
    }

    private static func still(_ files: [(String, URL)], at t: Double, detail: CGPoint, _ f: Film, _ note: String) async throws {
        guard let board = await board(files, at: t, detail: detail) else { throw FilmError.missing("frames") }
        f.layers = { [(board, CGRect(x: 20, y: 20, width: Film.stage.width - 40, height: Film.stage.height - 40))] }
        f.status = { String(format: "t=%.3f s  held", t) }
        f.refresh()
        f.hold(3, note)
    }

    /// The three files' frames at `t` across the top, and a 3x close-up of each around `detail` below.
    private static func board(_ files: [(String, URL)], at t: Double, detail: CGPoint) async -> CGImage? {
        var frames: [CGImage] = []
        for (_, url) in files { if let frame = await decodedFrame(url, at: t) { frames.append(frame) } }
        guard frames.count == files.count, let first = frames.first else { return nil }
        let size = CGSize(width: Film.stage.width - 40, height: Film.stage.height - 40), k: CGFloat = 2
        let ctx = Pix.context(Int(size.width * k), Int(size.height * k))
        ctx.scaleBy(x: k, y: k)
        ctx.setFillColor(CGColor(gray: 0.1, alpha: 1))
        ctx.fill(CGRect(origin: .zero, size: size))
        ctx.interpolationQuality = .high
        let gap: CGFloat = 12, tw = (size.width - gap * 4) / 3, th = tw * CGFloat(first.height) / CGFloat(first.width)
        let crop = CGFloat(first.width) / 3.0 / 3.0
        for (i, frame) in frames.enumerated() {
            let x = gap + CGFloat(i) * (tw + gap)
            ctx.draw(frame, in: CGRect(x: x, y: size.height - 40 - th, width: tw, height: th))
            let cx = min(max(detail.x * CGFloat(frame.width) - crop / 2, 0), CGFloat(frame.width) - crop)
            let cy = min(max(detail.y * CGFloat(frame.height) - crop * 0.75 / 2, 0), CGFloat(frame.height) - crop * 0.75)
            if let part = frame.cropping(to: CGRect(x: cx, y: cy, width: crop, height: crop * 0.75)) {
                let ph = tw * 0.75
                ctx.draw(part, in: CGRect(x: x, y: size.height - 40 - th - gap - 22 - ph, width: tw, height: ph))
            }
            Pix.draw(ctx, files[i].0, at: CGPoint(x: x, y: size.height - 30), size: 20, color: .white)
            Pix.draw(ctx, "3x close-up", at: CGPoint(x: x, y: size.height - 40 - th - gap - 20), size: 13, color: NSColor(white: 0.7, alpha: 1))
        }
        return ctx.makeImage()
    }
}
