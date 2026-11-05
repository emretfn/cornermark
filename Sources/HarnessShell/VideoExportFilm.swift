import AppKit
import CornermarkCapture
import CornermarkCore
import CornermarkDesign
@testable import CornermarkVideoEditor
@testable import CornermarkShell

/// Films export for review: the real editor, its export panel and the real Quick Access card of a harness world, rendered offscreen
/// and driven by scripted clicks, next to frames lifted from the file the export wrote. The export itself is the app's own and runs at
/// its own speed while the film samples it, so the progress in the film is real but the film's clock is not the wall clock; the
/// render time is printed in the X6 film's status line. Pointer arrow, captions, outlines and result cards are drawn by the harness.
/// Run with `CORNERMARK_EXPORT_FILM=<folder> swift run HarnessShell`.
@MainActor
enum VideoExportFilm {
    static func run(out: URL) async -> Bool {
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var ok = true
        for (name, frames, scene) in [("X1", 120, x1), ("X2", 600, x2), ("X3", 120, x3), ("X6", 600, x6)] as [(String, Int, (Film, EditorStage) async throws -> Void)] {
            guard let film = Film(url: out.appendingPathComponent("\(name).mp4")) else { return false }
            do {
                let stage = try await EditorStage(film, frames: frames)
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

    static func x1(_ f: Film, _ s: EditorStage) async throws {
        f.title = "X1  Export at the top right opens a panel: resolution, quality and an estimate of the file size."
        guard let editor = try await s.openProject() else { throw FilmError.missing("the editor") }
        let export = editor.view(identifier: "video.export") as! NSButton
        f.hold(1.4, "The editor. Export is its one primary button, top right.")
        s.outline = s.rect("video.export", in: editor)
        f.refresh()
        f.hold(1.6, "Export")
        s.outline = nil
        await s.press(export, in: editor, note: "Export")
        f.hold(2, "The panel drops from the button. Its own Export becomes the primary action; the header's steps back.")
        for (id, note) in [("video.export.resolution", "Resolution: the original size and each smaller standard size, never larger."),
                           ("video.export.quality", "Quality: Low, Medium or High, the bits spent on each frame."),
                           ("video.export.estimate", "The estimated size, from what the recording itself needed, capped by the chosen bit rate."),
                           ("video.export.details", "What it will write: size, frame rate, length and codec.")] {
            s.outline = s.rect(id, in: editor)
            f.refresh()
            f.hold(2.2, note)
        }
        s.outline = nil
        let resolution = editor.view(identifier: "video.export.resolution") as! NSPopUpButton
        f.glide(to: s.point(of: resolution, in: editor), "Resolution")
        resolution.selectItem(at: 1)
        fire(resolution)
        await s.settle(editor)
        f.hold(2.2, "854 x 480: fewer pixels, a smaller estimate.")
        let quality = editor.view(identifier: "video.export.quality") as! NSSlider
        f.glide(to: s.point(of: quality, in: editor), "Quality")
        for v in [1.0, 0.0] {
            quality.doubleValue = v
            fire(quality)
            await s.settle(editor)
            f.hold(1.4, "Quality: \(ExportQuality(rawValue: Int(v))!.title). This recording is nearly still, so it needs few bits at any quality.")
        }
        resolution.selectItem(at: 0)
        fire(resolution)
        quality.doubleValue = 2
        fire(quality)
        await s.settle(editor)
        f.hold(1.4, "Back to the original size at High.")
        await s.press(editor.view(identifier: "video.export.cancel") as! NSButton, in: editor, note: "Cancel")
        f.hold(1.6, "Cancel closes the panel. Export is primary again.")
        await s.press(export, in: editor, note: "Export")
        f.dark = true
        f.refresh()
        f.hold(2.5, "The panel in Dark appearance.")
    }

    static func x2(_ f: Film, _ s: EditorStage) async throws {
        f.title = "X2  Exporting video: a bar, the percent and Cancel. A cancelled export leaves no file."
        guard let editor = try await s.openProject() else { throw FilmError.missing("the editor") }
        let incoming = s.w.store.incomingDirectory
        func leftovers() -> Int { (try? FileManager.default.contentsOfDirectory(atPath: incoming.path))?.count ?? 0 }
        f.status = { "export=\(editor.state.export)  files in the export folder: \(leftovers())  History entries: \(s.w.store.list().count)" }
        f.hold(1.4, "A 10 second recording, so the export takes a moment.")
        await s.press(editor.view(identifier: "video.export") as! NSButton, in: editor, note: "Export")
        f.hold(1.2, "The panel.")
        await s.press(editor.view(identifier: "video.export.start") as! NSButton, in: editor, note: "Export")
        let cancel = editor.view(identifier: "video.export.cancel") as! NSButton
        f.glide(to: s.point(of: cancel, in: editor), "Exporting video. The film samples the real export as it runs.", frames: 8)
        await sample(f, s, editor, until: 0.4) { "Exporting video: \(Int($0 * 100))%. The film samples the real export as it runs." }
        cancel.performClick(nil)
        _ = await waitUntil(5) { !editor.state.export.isExporting }
        f.refresh()
        f.hold(2.6, editor.state.export == .choosing && leftovers() == 0
               ? "Cancelled at \(percent(editor)). The panel offers the choices again, and the export folder holds no file."
               : "The export finished before Cancel landed.")
        await s.press(editor.view(identifier: "video.export.start") as! NSButton, in: editor, note: "Export again")
        await sample(f, s, editor, until: 1.01) { "Exporting video: \(Int($0 * 100))%" }
        _ = await waitUntil(5) { s.w.coordinator.overlay.stack.contains { $0.record.ownsVideo } }
        f.layers = { [unowned s, unowned editor] in s.layers(editor) + f.cardLayers(s.w) }
        f.refresh()
        f.hold(2.4, "Done: the panel closes and the export's card appears.")
        if let made = s.w.store.list().first(where: \.ownsVideo), let file = made.video?.file {
            await f.show(file, label: "the exported file at 5.0 s", at: 5)
            f.layers = { [unowned s, unowned editor] in s.layers(editor) + f.cardLayers(s.w) + f.resultLayers() }
            f.refresh()
            f.hold(3, "A frame of the finished file, read back from disk.")
            f.layers = { [unowned s, unowned editor] in s.layers(editor) + f.cardLayers(s.w) }
        }
        await s.press(editor.view(identifier: "video.export") as! NSButton, in: editor, note: "Export")
        await s.press(editor.view(identifier: "video.export.start") as! NSButton, in: editor, note: "Export")
        f.dark = true
        let exports = s.w.store.list().filter(\.ownsVideo).count
        await sample(f, s, editor, until: 0.5) { "Exporting in Dark appearance: \(Int($0 * 100))%" }
        (editor.view(identifier: "video.export.cancel") as! NSButton).performClick(nil)
        _ = await waitUntil(5) { !editor.state.export.isExporting }
        f.refresh()
        let kept = s.w.store.list().filter(\.ownsVideo).count
        f.hold(2.4, kept == exports && leftovers() == 0
               ? "Cancelled again at \(percent(editor)): still \(kept) export in History and no file left behind."
               : "The export finished before Cancel landed: \(kept) exports in History.")
    }

    static func x3(_ f: Film, _ s: EditorStage) async throws {
        f.title = "X3  When the export is done, a Quick Access card offers Copy and Save and shows the duration and the file size."
        guard let editor = try await s.openProject() else { throw FilmError.missing("the editor") }
        let c = s.w.coordinator
        c.overlay.closeAll()
        f.hold(1.2, "The editor. The recording's own card is closed, so the next card is the export's.")
        await s.press(editor.view(identifier: "video.export") as! NSButton, in: editor, note: "Export")
        await s.press(editor.view(identifier: "video.export.start") as! NSButton, in: editor, note: "Export")
        await sample(f, s, editor, until: 1.01) { "Exporting video: \(Int($0 * 100))%" }
        guard await waitUntil(5, { c.overlay.stack.contains { $0.record.ownsVideo } }), let card = c.overlay.stack.first(where: { $0.record.ownsVideo }), let view = c.overlay.cardView(for: card),
              let panel = c.overlay.panel(for: card), let file = card.record.video?.file else { throw FilmError.missing("the export's card") }
        f.layers = { [unowned s, unowned editor] in s.layers(editor) + f.cardLayers(s.w) + f.magnified(s.w) }
        let bytes = ((try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? NSNumber)?.int64Value ?? 0
        f.status = { "card: \(card.info.replacingOccurrences(of: "  \u{00B7}  ", with: " | "))  file: \(file.lastPathComponent) \(bytes) bytes  hud: \(c.hud.lastMessage ?? "-")" }
        f.refresh()
        f.hold(2.2, "The export's card: \(card.info.replacingOccurrences(of: "  \u{00B7}  ", with: ", ")).")
        f.glide(to: CGPoint(x: panel.frame.midX, y: panel.frame.midY), "Pointing at the card")
        view.mouseEntered(with: Synth.enterExit(.mouseEntered, in: panel))
        f.refresh()
        f.hold(1.8, "Copy, Save, Play and Close.")
        f.press(view.buttons[.copy]!, in: panel, note: "Copy")
        let copied = (s.w.pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL])?.first
        f.status = { "pasteboard: \(copied?.lastPathComponent ?? "nothing")  hud: \(c.hud.lastMessage ?? "-")" }
        f.refresh()
        f.hold(2, "Copy puts the video file on the pasteboard.")
        f.press(view.buttons[.save]!, in: panel, note: "Save")
        let folder = c.settings.value.resolvedSaveFolder(default: s.w.env.defaultSaveFolder)
        let saved = folder.appendingPathComponent(file.lastPathComponent)
        let same = FileManager.default.contentsEqual(atPath: saved.path, andPath: file.path)
        f.status = { "saved: <save folder>/\(saved.lastPathComponent) identical=\(same)  hud: \(c.hud.lastMessage ?? "-")" }
        f.refresh()
        f.hold(2.4, "Save copies the export into the save folder, next to the recordings.")
        await f.show(saved, label: "the saved copy at 1.0 s", at: 1)
        f.layers = { [unowned s, unowned editor] in s.layers(editor) + f.cardLayers(s.w) + f.resultLayers() }
        f.refresh()
        f.hold(3, "A frame of the saved file, read back from disk.")
        f.dark = true
        f.refresh()
        f.hold(2.4, "The card in Dark appearance.")
    }

    static func x6(_ f: Film, _ s: EditorStage) async throws {
        f.title = "X6  Hardware encoding: the export asks VideoToolbox for the hardware H.264 encoder and reports which one ran."
        guard let editor = try await s.openProject() else { throw FilmError.missing("the editor") }
        var report: ExportReport?
        let forward = editor.onExport
        editor.onExport = { event in
            if case .finished(let r) = event { report = r }
            forward(event)
        }
        f.hold(1.2, "A 10 second recording at 1280 x 720, 60 fps.")
        await s.press(editor.view(identifier: "video.export") as! NSButton, in: editor, note: "Export")
        await s.press(editor.view(identifier: "video.export.start") as! NSButton, in: editor, note: "Export")
        await sample(f, s, editor, until: 1.01) { "Exporting video: \(Int($0 * 100))%" }
        _ = await waitUntil(5) { report != nil && s.w.store.list().contains(where: \.ownsVideo) }
        guard let r = report, let stored = s.w.store.list().first(where: \.ownsVideo)?.video?.file else { throw FilmError.missing("the export report") }
        let line = String(format: "encoder=%@ hardware=%@ frames=%d seconds=%.3f renderSeconds=%.3f (%.0f frames/s) bytes=%lld",
                          r.encoderID, r.usesHardware ? "true" : "false", r.framesWritten, r.duration, r.renderSeconds,
                          Double(r.framesWritten) / r.renderSeconds, r.bytes)
        print("X6 \(line)")
        f.status = { line }
        f.refresh()
        f.hold(3, r.usesHardware ? "The encoder session reports the hardware encoder." : "The hardware encoder was not available; the software one wrote the file.")
        for t in [2.0, 7.5] {
            editor.seek(to: t)
            await s.settle(editor)
            let preview = previewFrame(editor, size: CGSize(width: r.plan.width, height: r.plan.height))
            let file = await decodedFrame(stored, at: t)
            let diff = preview.flatMap { a in file.flatMap { PixelDifference(a, $0, edge: 4) } }
            f.results.append(("preview at \(t) s", preview, "the editor's preview layers"))
            f.results.append(("file at \(t) s", file, diff.map { "vs preview: \($0)" } ?? "unreadable"))
            f.layers = { [unowned s, unowned editor] in s.layers(editor) + f.resultLayers() }
            f.refresh()
            f.hold(3.2, String(format: "At %.1f s: the preview and the exported frame. %@", t, diff.map { String(format: "Mean difference %.2f of 255.", $0.mean) } ?? ""))
        }
        f.dark = true
        f.refresh()
        f.hold(2, "The same in Dark appearance. The video's pixels do not follow the appearance.")
    }

    static func sample(_ f: Film, _ s: EditorStage, _ editor: VideoEditorWindowController, until fraction: Double, note: (Double) -> String) async {
        while case .exporting(let x) = editor.state.export, x < fraction {
            try? await Task.sleep(nanoseconds: 4_000_000)
            editor.window?.contentView?.layoutSubtreeIfNeeded()
            f.refresh()
            if case .exporting(let now) = editor.state.export { f.hold(1 / Double(Film.fps), note(now)) }
        }
    }

    static func percent(_ editor: VideoEditorWindowController) -> String {
        (editor.view(identifier: "video.export.percent") as? NSTextField)?.stringValue ?? "?"
    }
}
