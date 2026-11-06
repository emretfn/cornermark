import AppKit
import CornermarkCore
@testable import CornermarkVideoEditor
@testable import CornermarkShell

/// Films trimming for review: the real editor of a harness world, rendered offscreen and driven by scripted keys, clicks and drags
/// on its timeline, next to frames read back from the file a trimmed export wrote. Pointer arrow, captions, outlines, the magnified
/// timeline and result cards are drawn by the harness. Run with `CORNERMARK_TRIM_FILM=<folder> swift run HarnessShell`.
@MainActor
enum VideoTrimFilm {
    static func run(out: URL) async -> Bool {
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var ok = true
        for (name, scene) in [("E5", e5), ("E6", e6)] as [(String, (Film, EditorStage) async throws -> Void)] {
            guard let film = Film(url: out.appendingPathComponent("\(name).mp4")) else { return false }
            do {
                let stage = try await EditorStage(film, frames: 600)
                // The whole fixture display, so the clock it shows reads in the preview and in the exported frames.
                stage.area = "display=1&x=0&y=0&width=1280&height=720"
                defer { stage.w.cleanup() }
                try await scene(film, stage)
            } catch { film.failures.append("\(error)") }
            let written = await film.finish()
            print("FILM \(name).mp4 frames=\(written) failures=\(film.failures)")
            ok = ok && written > 0 && film.failures.isEmpty
        }
        return ok
    }

    // MARK: Scenes

    static func e5(_ f: Film, _ s: EditorStage) async throws {
        f.title = "E5  Trim: split a clip at the playhead (Command-B), delete a piece, drag a clip's edge. Undo and redo."
        guard let editor = try await s.openProject(), let window = editor.window, let timeline = timelineView(editor) else { throw FilmError.missing("the editor") }
        status(f, s, editor)
        f.hold(1.6, "A 10 second recording: one clip, the whole recording.")
        Synth.key(window, 49, " ")
        await s.play(editor, seconds: 2, note: "Playing. The playhead stops where the first piece should end.")
        Synth.key(window, 49, " ")
        await s.settle(editor)
        f.hold(1, "Paused at \(Timecode.text(editor.state.transport.time(at: s.clock.now))).")
        Synth.key(window, 11, "b", modifiers: .command)
        await s.settle(editor)
        s.outline = s.rect("clip", in: editor)
        f.refresh()
        f.hold(2.4, "Command-B: the clip splits at the playhead. Two clips, the same 10 seconds.")
        s.outline = nil
        await scrub(f, s, editor, timeline, to: 5, note: "Moving the playhead to 0:05")
        await s.press(editor.view(identifier: "video.split") as! NSButton, in: editor, note: "Split Clip at Playhead")
        f.hold(2, "The scissors button does the same: three clips.")
        let lane = timeline.clipLaneRect
        await click(f, s, editor, timeline, at: CGPoint(x: CGFloat(timeline.scale.x(3.5)), y: lane.midY), note: "Clicking the middle clip")
        f.hold(2, "The middle clip is picked: a frame with a grip on each edge.")
        Synth.key(window, 51, "\u{7f}")
        await s.settle(editor)
        f.hold(2.6, "Delete: the piece is gone and the video is 3 seconds shorter. The playhead waits on the new cut.")
        let end = CGPoint(x: timeline.clipRects[0].maxX - 2, y: lane.midY)
        await drag(f, s, editor, timeline, from: end, to: CGPoint(x: end.x - CGFloat(0.8 * timeline.scale.pointsPerSecond), y: lane.midY),
                   note: "Dragging the first clip's end to the left. The preview shows the frame the clip now ends on.")
        f.hold(2, "The first clip now ends 0.8 s earlier.")
        let start = CGPoint(x: timeline.clipRects[1].minX + 2, y: lane.midY)
        await drag(f, s, editor, timeline, from: start, to: CGPoint(x: start.x - CGFloat(1.5 * timeline.scale.pointsPerSecond), y: lane.midY),
                   note: "Dragging the second clip's start to the left brings back part of what was deleted.")
        f.hold(2, "The second clip starts 1.5 s earlier in the recording.")
        Synth.key(window, 6, "z", modifiers: .command)
        await s.settle(editor)
        f.hold(1.8, "Command-Z: the last drag is undone in one step.")
        Synth.key(window, 6, "z", modifiers: .command)
        await s.settle(editor)
        f.hold(1.8, "Command-Z again: the first drag is undone too.")
        Synth.key(window, 6, "Z", modifiers: [.command, .shift])
        Synth.key(window, 6, "Z", modifiers: [.command, .shift])
        await s.settle(editor)
        f.hold(1.8, "Shift-Command-Z twice: both trims are back.")
        await s.press(editor.view(identifier: "video.start") as! NSButton, in: editor, note: "Go to Start")
        Synth.key(window, 49, " ")
        await s.play(editor, seconds: 3, note: "Playing the trimmed video: it jumps over what was cut.")
        Synth.key(window, 49, " ")
        await s.settle(editor)
        f.dark = true
        f.refresh()
        f.hold(2.4, "The same in Dark appearance.")
        editor.window?.close()
        let stored = try RecordingProjectFile.read(from: editor.folder)
        f.layers = { [] }
        f.status = { "project.json after closing: clips=\(describe(stored.edits.clips))" }
        f.refresh()
        f.hold(2.4, "Closing the editor writes the clips to project.json. The recording itself is not touched.")
    }

    static func e6(_ f: Film, _ s: EditorStage) async throws {
        f.title = "E6  The clip lane marks every cut. The exported video cuts at the same frames."
        guard let editor = try await s.openProject(), let window = editor.window, let timeline = timelineView(editor) else { throw FilmError.missing("the editor") }
        status(f, s, editor)
        f.hold(1.4, "One clip, no cuts.")
        for t in [2.0, 4.0, 7.5] {
            await scrub(f, s, editor, timeline, to: t, note: "Moving the playhead to \(Timecode.text(t))")
            Synth.key(window, 11, "b", modifiers: .command)
            await s.settle(editor)
            f.hold(1.2, "Command-B at \(Timecode.text(t)): a cut, marked above and below the clip lane.")
        }
        f.layers = { [unowned s, unowned editor] in s.layers(editor) + magnified(editor, f) }
        f.refresh()
        f.hold(3.2, "Three cuts, three marks. Each clip shows the pictures of its own stretch of the recording.")
        let lane = timeline.clipLaneRect
        await click(f, s, editor, timeline, at: CGPoint(x: CGFloat(timeline.scale.x(3)), y: lane.midY), note: "Picking the second clip")
        Synth.key(window, 51, "\u{7f}")
        await s.settle(editor)
        f.hold(2.6, "Deleting it removes a clip and one mark; the cut between what remains is marked.")
        f.layers = { [unowned s, unowned editor] in s.layers(editor) }
        f.refresh()
        let clips = editor.state.project.timeline
        await s.press(editor.view(identifier: "video.export") as! NSButton, in: editor, note: "Export")
        await s.press(editor.view(identifier: "video.export.start") as! NSButton, in: editor, note: "Export")
        await VideoExportFilm.sample(f, s, editor, until: 1.01) { "Exporting the trimmed video: \(Int($0 * 100))%" }
        _ = await waitUntil(10) { s.w.store.list().contains(where: \.ownsVideo) }
        guard let file = s.w.store.list().first(where: \.ownsVideo)?.video?.file else { throw FilmError.missing("the export") }
        let facts = await fileFacts(file)
        f.status = { "export: \(facts?.frames ?? 0) frames at \(Int(facts?.fps ?? 0)) fps = \(Timecode.text(Double(facts?.frames ?? 0) / max(facts?.fps ?? 1, 1)))  clips: \(describe(clips.clips))" }
        f.refresh()
        f.hold(2.4, "The file is as long as the clips: \(Timecode.text(clips.duration)), not 0:10.00.")
        let plan = ExportPlan(project: editor.state.project, settings: ExportSettings(), video: editor.videoURL)
        let renderer = ExportFrameRenderer(plan: plan, project: editor.state.project, folder: editor.folder)
        /// Which source moment a frame of the file is: its difference from the export's drawing of the expected source frame,
        /// and from the frame the same moment would show without the cuts.
        func identify(_ output: Double) async -> String {
            let state = frameState(editor.state.project, outputTime: output)
            guard let file = await decodedFrame(file, at: output),
                  let expected = await decodedFrame(editor.videoURL, at: state.sourceTime).flatMap({ renderer.image(state, source: $0) }),
                  let uncut = await decodedFrame(editor.videoURL, at: output).flatMap({ renderer.image(state, source: $0) }),
                  let a = PixelDifference(file, expected, edge: 4), let b = PixelDifference(file, uncut, edge: 4) else { return "  unreadable" }
            print(String(format: "E6 CUTFRAME output=%.3f source=%.3f vs-expected psnr=%.1fdB vs-uncut(%.3f) psnr=%.1fdB", output, state.sourceTime, a.psnr, output, b.psnr))
            return String(format: "\nvs source %.3f s: %.1f dB  vs source %.3f s: %.1f dB", state.sourceTime, a.psnr, output, b.psnr)
        }
        for cut in clips.cuts {
            let before = cut - clips.frame, source = clips.sourceTime(at: cut), last = clips.sourceTime(at: before)
            await f.show(file, label: String(format: "%.3f s, last frame before the cut", before), at: before, extra: await identify(before))
            await f.show(file, label: String(format: "%.3f s, first frame after the cut", cut), at: cut, extra: await identify(cut))
            f.layers = { [unowned s, unowned editor] in s.layers(editor) + f.resultLayers() }
            f.refresh()
            let removed = source - last > clips.frame * 1.5
            f.hold(4.5, removed
                   ? String(format: "The cut at %@: the file's clock jumps from %.3f s to %.3f s of the recording.", Timecode.text(cut), last, source)
                   : String(format: "The cut at %@ was a split with nothing removed: the clock runs on from %.3f s to %.3f s.", Timecode.text(cut), last, source))
        }
        f.dark = true
        f.layers = { [unowned s, unowned editor] in s.layers(editor) + magnified(editor, f) }
        f.refresh()
        f.hold(2.6, "The marks in Dark appearance.")
    }

    // MARK: Driving the timeline

    static func timelineView(_ editor: VideoEditorWindowController) -> TimelineView? { editor.view(identifier: "video.timeline") as? TimelineView }

    static func describe(_ clips: [Clip]) -> String {
        clips.map { String(format: "%.2f-%.2f", $0.start, $0.end) }.joined(separator: ", ")
    }

    static func status(_ f: Film, _ s: EditorStage, _ editor: VideoEditorWindowController) {
        f.status = { [unowned s, unowned editor] in
            let st = editor.state
            return "clips=[\(describe(st.project.edits.clips))] length=\(Timecode.text(st.transport.duration)) t=\(Timecode.text(st.transport.time(at: s.clock.now))) picked=\(st.selectedClip.map(String.init) ?? "none") undo=\(editor.canUndo) redo=\(editor.canRedo)"
        }
    }

    static func global(_ p: CGPoint, in timeline: TimelineView, _ s: EditorStage) -> CGPoint {
        let w = timeline.convert(p, to: nil)
        return CGPoint(x: s.origin.x + w.x, y: s.origin.y + w.y)
    }

    static func event(_ type: NSEvent.EventType, _ p: CGPoint, _ timeline: TimelineView) -> NSEvent {
        let window = timeline.window!
        return Synth.mouse(type, at: window.convertPoint(toScreen: timeline.convert(p, to: nil)), in: window)
    }

    static func click(_ f: Film, _ s: EditorStage, _ editor: VideoEditorWindowController, _ timeline: TimelineView, at p: CGPoint, note: String) async {
        f.glide(to: global(p, in: timeline, s), note, frames: 14)
        timeline.mouseDown(with: event(.leftMouseDown, p, timeline))
        timeline.mouseUp(with: event(.leftMouseUp, p, timeline))
        await s.settle(editor)
        f.hold(0.3, note)
    }

    static func scrub(_ f: Film, _ s: EditorStage, _ editor: VideoEditorWindowController, _ timeline: TimelineView, to t: Double, note: String) async {
        let y = timeline.rulerRect.midY
        let from = CGPoint(x: CGFloat(timeline.scale.x(editor.state.transport.time(at: s.clock.now))), y: y)
        let to = CGPoint(x: CGFloat(timeline.scale.x(t)), y: y)
        f.glide(to: global(from, in: timeline, s), note, frames: 12)
        timeline.mouseDown(with: event(.leftMouseDown, from, timeline))
        await stepwise(f, s, editor, timeline, from: from, to: to, steps: 14, note: note)
        timeline.mouseUp(with: event(.leftMouseUp, to, timeline))
        await s.settle(editor)
    }

    static func drag(_ f: Film, _ s: EditorStage, _ editor: VideoEditorWindowController, _ timeline: TimelineView, from a: CGPoint, to b: CGPoint, note: String) async {
        f.glide(to: global(a, in: timeline, s), note, frames: 14)
        timeline.mouseDown(with: event(.leftMouseDown, a, timeline))
        await s.settle(editor)
        f.hold(0.4, note)
        await stepwise(f, s, editor, timeline, from: a, to: b, steps: 40, note: note)
        f.hold(0.6, note)
        timeline.mouseUp(with: event(.leftMouseUp, b, timeline))
        await s.settle(editor)
    }

    private static func stepwise(_ f: Film, _ s: EditorStage, _ editor: VideoEditorWindowController, _ timeline: TimelineView,
                                 from a: CGPoint, to b: CGPoint, steps: Int, note: String) async {
        for i in 1...steps {
            let k = CGFloat(i) / CGFloat(steps), e = k * k * (3 - 2 * k)
            let p = CGPoint(x: a.x + (b.x - a.x) * e, y: a.y + (b.y - a.y) * e)
            timeline.mouseDragged(with: event(.leftMouseDragged, p, timeline))
            await s.settle(editor)
            f.glide(to: global(p, in: timeline, s), note, frames: 1)
        }
    }

    /// The clip lane again at twice its size, labelled, so the marks read in the film.
    static func magnified(_ editor: VideoEditorWindowController, _ f: Film) -> [(CGImage, CGRect)] {
        guard let window = editor.window, let timeline = timelineView(editor), let image = editorImage(editor, dark: f.dark) else { return [] }
        let marks = timeline.cutMarks
        let center = marks.isEmpty ? timeline.clipLaneRect.midX : (marks.first! + marks.last!) / 2
        let span: CGFloat = 540
        let local = CGRect(x: center - span / 2, y: timeline.clipLaneRect.minY - 10, width: span, height: timeline.clipLaneRect.height + 20)
        let lane = timeline.convert(local, to: nil)
        let crop = CGRect(x: lane.minX * 2, y: (window.frame.height - lane.maxY) * 2, width: lane.width * 2, height: lane.height * 2)
        guard let part = image.cropping(to: crop) else { return [] }
        let width = span * 2, height = lane.height * 2
        let box = CGRect(x: 90, y: 330, width: width + 20, height: height + 44)
        let ctx = Pix.context(Int(box.width * 2), Int(box.height * 2))
        ctx.scaleBy(x: 2, y: 2)
        ctx.setFillColor(CGColor(gray: 0.08, alpha: 0.92))
        ctx.addPath(CGPath(roundedRect: CGRect(origin: .zero, size: box.size), cornerWidth: 10, cornerHeight: 10, transform: nil))
        ctx.fillPath()
        ctx.interpolationQuality = .high
        ctx.draw(part, in: CGRect(x: 10, y: 10, width: width, height: height))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        ("Harness zoom: the middle of the clip lane at 2x" as NSString).draw(in: CGRect(x: 10, y: box.height - 28, width: box.width - 20, height: 20),
                                                               withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.white])
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage().map { [($0, box)] } ?? []
    }
}
