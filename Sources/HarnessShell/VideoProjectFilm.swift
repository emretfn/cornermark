import AppKit
import AVFoundation
import CornermarkCore
@testable import CornermarkVideoEditor
@testable import CornermarkShell

/// Films opening a video file, saving a project and the project package for review: the real editor of a harness world, rendered
/// offscreen and driven by scripted clicks and keys sent to its window. The file listings, the pointer and the captions are drawn by
/// the harness. Run with `CORNERMARK_PROJECT_FILM=<folder> swift run HarnessShell`.
@MainActor
enum VideoProjectFilm {
    static func run(out: URL) async -> Bool {
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var ok = true
        for (name, scene) in [("E8", e8), ("E9", e9), ("E11", e11)] as [(String, (Film, EditorStage) async throws -> Void)] {
            guard let film = Film(url: out.appendingPathComponent("\(name).mp4")) else { return false }
            do {
                let stage = try await EditorStage(film, frames: 180)
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

    static func e8(_ f: Film, _ s: EditorStage) async throws {
        f.title = "E8  Open a video file in the video editor. It becomes a project; the file is copied as it is, never encoded again."
        let inbox = s.w.root.appendingPathComponent("Movies", isDirectory: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let movie = inbox.appendingPathComponent("synthetic clip.mov")
        try await SyntheticMovie.write(to: movie, SyntheticMovie.Spec(frames: 90))
        let original = sha256OrUnreadable(movie)
        s.hasAudio = true
        f.layers = { [listing("A video someone already has", [movie], note: "made by the harness: H.264 and a 440 Hz tone")] }
        f.status = { "file=\(movie.lastPathComponent) sha256=\(original.prefix(12))" }
        f.refresh()
        f.hold(2.6, "A movie file outside Cornermark. Nothing in it comes from the screen.")
        f.hold(1.6, "Open With Cornermark in Finder, File > Open Video, or the open link all hand the file to the app.")
        let c = s.w.coordinator
        c.perform(.openFile(movie))
        guard await waitUntil(10, { !c.videoEditors.isEmpty }), let editor = s.current else { throw FilmError.missing("the editor") }
        await s.show(editor)
        f.layers = { [unowned s, unowned editor] in s.layers(editor) }
        let package = editor.folder
        let copyHash = sha256OrUnreadable(package.appendingPathComponent(movie.lastPathComponent))
        f.status = { [unowned editor] in
            let p = editor.state.project
            return "origin=\(p.source.origin.rawValue) \(p.source.pixelWidth)x\(p.source.pixelHeight) \(p.source.fps) fps \(String(format: "%.1f", p.source.duration)) s  pointer=\(p.events.pointer.count) clicks=\(p.events.clicks.count) keys=\(p.events.keys.count)  copy sha256=\(copyHash.prefix(12)) \(copyHash == original ? "== original" : "!= original")"
        }
        f.hold(2.4, "The editor opens the new project, titled with the video's name.")
        f.layers = { [unowned s, unowned editor] in s.layers(editor) + [listing("The new project package in the save folder", [package], note: "the video inside has the original's bytes")] }
        f.refresh()
        f.hold(3.2, "\(package.lastPathComponent): the video under its own name and project.json.")
        f.layers = { [unowned s, unowned editor] in s.layers(editor) }
        f.refresh()
        for (section, note) in [(EditorSection.cursor, "Cursor: a video from a file has no pointer track, so the panel says why instead of offering settings."),
                                (.keystrokes, "Keystrokes: none were recorded with this video."),
                                (.audio, "Audio: the video's own sound plays and goes into the export.")] {
            await s.press(editor.view(identifier: "video.rail.\(section.rawValue)") as! NSButton, in: editor, note: section.title)
            f.hold(2.6, note)
        }
        await s.press(editor.view(identifier: "video.rail.background") as! NSButton, in: editor, note: "Background")
        await s.press(editor.view(identifier: "video.background.gradient.2") as! NSButton, in: editor, note: "A gradient")
        f.hold(1.6, "Every edit works as it does for a recording.")
        editor.togglePlayback()
        await s.play(editor, seconds: 2, note: "Playing the opened video.")
        editor.togglePlayback()
        await s.press(editor.view(identifier: "video.export") as! NSButton, in: editor, note: "Export")
        await s.press(editor.view(identifier: "video.export.start") as! NSButton, in: editor, note: "Export")
        await VideoExportFilm.sample(f, s, editor, until: 1.01) { "Exporting: \(Int($0 * 100))%" }
        _ = await waitUntil(20) { s.w.store.list().contains(where: \.ownsVideo) }
        guard let file = s.w.store.list().first(where: \.ownsVideo)?.video?.file else { throw FilmError.missing("the export") }
        let sound = (try? await AVURLAsset(url: file).loadTracks(withMediaType: .audio))?.count ?? 0
        await f.show(file, label: "the export at 1.5 s", at: 1.5, extra: ", sound tracks: \(sound)")
        f.layers = { [unowned s, unowned editor] in s.layers(editor) + f.resultLayers() }
        f.refresh()
        f.hold(3.2, "A frame read back from the export: on the gradient, with the video's sound track.")
        f.layers = { [unowned s, unowned editor] in s.layers(editor) + [listing("The original file, after all this", [movie], note: "sha256 \(sha256OrUnreadable(movie).prefix(12)), unchanged")] }
        f.refresh()
        f.hold(2.6, "The original file was only read.")
    }

    static func e9(_ f: Film, _ s: EditorStage) async throws {
        f.title = "E9  Save a project. Command-S saves now; closing saves without asking; reopening brings every edit back."
        guard let editor = try await s.openProject(), let window = editor.window else { throw FilmError.missing("the editor") }
        f.layers = { [unowned s, unowned editor] in s.layers(editor) }
        let folder = editor.folder
        diskStatus(f, editor, folder: folder)
        f.hold(2, "A project recorded for editing, just opened. The header says nothing yet.")
        await s.press(editor.view(identifier: "video.rail.background") as! NSButton, in: editor, note: "Background")
        await s.press(editor.view(identifier: "video.background.gradient.4") as! NSButton, in: editor, note: "A gradient")
        editor.seek(to: 1.2)
        await s.settle(editor)
        await s.press(editor.view(identifier: "video.split") as! NSButton, in: editor, note: "Split at the playhead")
        f.hold(2.6, "Two edits: the header says Edited and the window's close button shows a dot. project.json is not written yet.")
        Synth.key(window, 1, "s", modifiers: .command)
        await s.settle(editor)
        f.hold(2.8, "Command-S: Saved. The status line reads project.json from disk: the clips and the gradient are in it.")
        Synth.key(window, 6, "z", modifiers: .command)
        await s.settle(editor)
        f.hold(2, "Command-Z still undoes after saving: Edited again.")
        Synth.key(window, 6, "Z", modifiers: [.command, .shift])
        await s.settle(editor)
        f.hold(2, "Shift-Command-Z redoes, which matches the saved file again: Saved.")
        await s.press(editor.view(identifier: "video.background.gradient.7") as! NSButton, in: editor, note: "Another gradient")
        f.hold(2, "One more edit, not saved.")
        f.glide(to: CGPoint(x: s.origin.x + 18, y: s.origin.y + window.frame.height - 14), "The close button", frames: 14)
        f.hold(0.6, "The close button")
        let closes = editor.windowShouldClose(window)
        window.close()
        let sheet = window.attachedSheet == nil && NSApp.modalWindow == nil
        f.status = { "window closed  " + projectSummary(folder).components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: ", ") }
        f.layers = { [listing("After closing: no dialog appeared (\(sheet ? "none" : "one did")); the window \(closes ? "closed" : "stayed")", [folder], note: projectSummary(folder))] }
        f.refresh()
        f.hold(3.4, "Closing saved the last edit without asking. project.json holds it.")
        guard let again = s.w.coordinator.openVideoEditor(folder) else { throw FilmError.missing("the reopened editor") }
        await s.show(again)
        f.layers = { [unowned s, unowned again] in s.layers(again) }
        diskStatus(f, again, folder: folder)
        f.status = { [unowned again] in
            let p = again.state.project
            return "reopened: clips=\(p.timeline.clips.count) fill=\(name(p.edits.background.fill)) matches disk=\((try? RecordingProjectFile.read(from: folder)) == p)"
        }
        f.hold(2.4, "Reopened from History or a link: the split, the gradient and the last edit are all back.")
        await s.press(again.view(identifier: "video.rail.background") as! NSButton, in: again, note: "Background")
        f.hold(1.6, "The picked gradient is the one saved on close.")
        again.seek(to: 0.6)
        again.togglePlayback()
        await s.play(again, seconds: 2, note: "Playing across the saved cut.")
        again.togglePlayback()
    }

    static func e11(_ f: Film, _ s: EditorStage) async throws {
        f.title = "E11  A project is one package, <name>.cornermarkvideo: project.json, the video and its media. Save As copies it; older folders still open."
        guard let editor = try await s.openProject() else { throw FilmError.missing("the editor") }
        f.layers = { [unowned s, unowned editor] in s.layers(editor) }
        let first = editor.folder
        f.layers = { [unowned s, unowned editor] in s.layers(editor) + [listing("The project on disk", [first], note: projectSummary(first)), typeCard()] }
        f.status = { "package=\(first.lastPathComponent)" }
        f.refresh()
        f.hold(4, "Inside the package: the source video, never written again, and project.json with every edit.")
        f.hold(3.2, "The app declares the cornermarkvideo type as a package, so Finder shows one document and opens it here.")
        f.layers = { [unowned s, unowned editor] in s.layers(editor) }
        f.refresh()
        await s.press(editor.view(identifier: "video.rail.background") as! NSButton, in: editor, note: "Background")
        await s.press(editor.view(identifier: "video.background.gradient.6") as! NSButton, in: editor, note: "A gradient")
        f.hold(1.4, "An edit, not saved yet.")
        let target = s.w.coordinator.settings.value.resolvedSaveFolder(default: s.w.env.defaultSaveFolder).appendingPathComponent("Review copy")
        editor.chooseSaveLocation = { _, _, done in done(target) }
        Synth.key(editor.window!, 1, "S", modifiers: [.command, .shift])
        await s.settle(editor)
        let copy = editor.folder
        f.status = { [unowned editor] in "editing=\(editor.folder.lastPathComponent)  title=\(editor.window?.title ?? "")  original fill=\(name((try? RecordingProjectFile.read(from: first))?.edits.background.fill))  copy fill=\(name((try? RecordingProjectFile.read(from: copy))?.edits.background.fill))" }
        f.hold(2.4, "File > Save As (Shift-Command-S), named Review copy; the save panel is answered by the harness.")
        f.layers = { [unowned s, unowned editor] in s.layers(editor) + [listing("Both packages", [first, copy], note: "the copy has the edit; the original keeps what it last saved")] }
        f.refresh()
        f.hold(4, "The editor now edits Review copy. The original package is left as it was last saved.")
        f.layers = { [unowned s, unowned editor] in s.layers(editor) }
        f.refresh()
        let count = s.w.coordinator.videoEditors.count
        _ = s.w.coordinator.openVideoEditor(copy)
        f.hold(2, "Opening the same project again brings this window forward instead of a second editor (\(count) open, then \(s.w.coordinator.videoEditors.count)).")
        s.w.coordinator.closeAllEditors()

        let old = s.w.root.appendingPathComponent("Old Recording", isDirectory: true)
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        for name in [RecordingProjectFile.videoName, RecordingProjectFile.projectName] {
            try FileManager.default.copyItem(at: first.appendingPathComponent(name), to: old.appendingPathComponent(name))
        }
        f.layers = { [listing("A project folder from before packages", [old], note: "a plain folder, no extension")] }
        f.status = { "folder=\(old.lastPathComponent)" }
        f.refresh()
        f.hold(2.4, "An older project: a plain folder with the same two files.")
        guard let legacy = s.w.coordinator.openVideoEditor(old) else { throw FilmError.missing("the older project") }
        await s.show(legacy)
        f.layers = { [unowned s, unowned legacy] in s.layers(legacy) }
        f.status = { [unowned legacy] in "editing=\(legacy.folder.lastPathComponent)  title=\(legacy.window?.title ?? "")  clips=\(legacy.state.project.timeline.clips.count)" }
        f.hold(2.6, "It opens the same way, with its edits. Save writes into the folder; Save As makes a package.")
    }

    // MARK: Pictures

    private static func diskStatus(_ f: Film, _ editor: VideoEditorWindowController, folder: URL) {
        f.status = { [unowned editor] in
            let disk = try? RecordingProjectFile.read(from: folder)
            let header = (editor.view(identifier: "video.document.status") as? NSTextField).map { $0.isHidden ? "(nothing)" : $0.stringValue } ?? "?"
            return "header=\(header) edited=\(editor.window?.isDocumentEdited == true)  project.json: clips=\(disk?.timeline.clips.count ?? 0) fill=\(name(disk?.edits.background.fill))"
        }
    }

    static func projectSummary(_ folder: URL) -> String {
        guard let p = try? RecordingProjectFile.read(from: folder) else { return "no project.json" }
        return "project.json: version \(p.version), origin \(p.source.origin.rawValue), video \(p.source.video)\n              clips \(p.timeline.clips.count), fill \(name(p.edits.background.fill)), cursor \(p.edits.cursor.isVisible ? "shown" : "hidden") \(p.edits.cursor.scale)x"
    }

    /// A Finder-like listing of folders and files with their sizes. Drawn by the harness; not part of the app.
    static func listing(_ title: String, _ items: [URL], note: String) -> (CGImage, CGRect) {
        var lines: [String] = []
        let fm = FileManager.default
        func size(_ url: URL) -> String {
            let bytes = ((try? fm.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.intValue ?? 0
            return bytes > 1024 ? "\(bytes / 1024) KB" : "\(bytes) B"
        }
        for item in items {
            var isFolder: ObjCBool = false
            fm.fileExists(atPath: item.path, isDirectory: &isFolder)
            guard isFolder.boolValue else { lines.append("\(item.lastPathComponent)   \(size(item))"); continue }
            let package = item.pathExtension == RecordingProjectFile.packageExtension
            lines.append("\(item.lastPathComponent)\(package ? "" : "/")")
            if package { lines.append("    a package: Finder shows it as one document") }
            for name in ((try? fm.contentsOfDirectory(atPath: item.path)) ?? []).sorted() { lines.append("    \(name)   \(size(item.appendingPathComponent(name)))") }
        }
        return card(title, lines + [""] + note.components(separatedBy: "\n"), top: 600)
    }

    static func typeCard() -> (CGImage, CGRect) {
        card("Info.plist: the project type", [
            "UTTypeIdentifier  \(VideoEditorWindowController.packageType.identifier)",
            "UTTypeConformsTo  com.apple.package, public.composite-content",
            "extension         .\(RecordingProjectFile.packageExtension)",
            "CFBundleDocumentTypes: Editor, LSTypeIsPackage = true",
            "MP4 and MOV: Editor, rank Alternate (never the default player)",
        ], top: 290)
    }

    /// A dark card whose top edge sits at `top` in stage points, as tall as its lines.
    private static func card(_ title: String, _ lines: [String], top: CGFloat) -> (CGImage, CGRect) {
        let height = 46 + CGFloat(lines.count) * 18
        let box = CGRect(x: 560, y: top - height, width: 700, height: height)
        let s: CGFloat = 2
        let ctx = Pix.context(Int(box.width * s), Int(box.height * s))
        ctx.scaleBy(x: s, y: s)
        ctx.setFillColor(CGColor(gray: 0.08, alpha: 0.95))
        ctx.addPath(CGPath(roundedRect: CGRect(origin: .zero, size: box.size), cornerWidth: 10, cornerHeight: 10, transform: nil))
        ctx.fillPath()
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        let head: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 14, weight: .semibold), .foregroundColor: NSColor.white]
        let body: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular), .foregroundColor: NSColor(white: 0.82, alpha: 1)]
        (title as NSString).draw(in: CGRect(x: 14, y: box.height - 30, width: box.width - 28, height: 20), withAttributes: head)
        for (i, line) in lines.enumerated() {
            (line as NSString).draw(in: CGRect(x: 14, y: box.height - 54 - CGFloat(i) * 18, width: box.width - 28, height: 18), withAttributes: body)
        }
        NSGraphicsContext.restoreGraphicsState()
        return (ctx.makeImage()!, box)
    }
}

private func name(_ fill: VideoBackground.Fill?) -> String {
    guard let fill else { return "?" }
    switch fill {
    case .none: return "none"
    case .gradient(let i): return "gradient \(BuiltinBackgrounds.all[i].name)"
    case .wallpaper(let i): return "wallpaper \(BuiltinBackgrounds.all[i].name)"
    case .solid: return "colour"
    case .image: return "image"
    }
}

