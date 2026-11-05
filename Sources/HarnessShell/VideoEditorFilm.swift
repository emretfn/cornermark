import AppKit
import CornermarkCapture
import CornermarkCore
import CornermarkDesign
@testable import CornermarkVideoEditor
@testable import CornermarkShell

/// Films the video editor for review: the real editor window of a harness world, rendered offscreen frame by frame over the
/// synthetic desktop and driven by scripted clicks and keys. The project is recorded from the fixture display. The harness decodes
/// the source one frame at a time on a scripted clock, so playback in the film runs at its true speed; the live decoder's cost is
/// the `PERF` line of `swift run HarnessShell`. The pointer arrow, the caption strip and the orange outlines are drawn by the harness.
/// Run with `CORNERMARK_EDITOR_FILM=<folder> swift run HarnessShell`.
@MainActor
enum VideoEditorFilm {
    static func run(out: URL) async -> Bool {
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var ok = true
        for (name, scene) in [("E2", e2), ("E3", e3), ("E4", e4), ("E10", e10)] as [(String, (Film, EditorStage) async throws -> Void)] {
            guard let film = Film(url: out.appendingPathComponent("\(name).mp4")) else { return false }
            do {
                let stage = try await EditorStage(film)
                defer { stage.w.cleanup() }
                try await scene(film, stage)
            } catch { film.failures.append("\(error)") }
            let frames = await film.finish()
            print("FILM \(name).mp4 frames=\(frames) failures=\(film.failures)")
            ok = ok && frames > 0 && film.failures.isEmpty
        }
        return ok
    }

    // MARK: Scenes

    static func e2(_ f: Film, _ s: EditorStage) async throws {
        f.title = "E2  The video editor: settings rail on the left, preview in the middle, playback under it, then the ruler, the zoom lane and the clip lane."
        let c = s.w.coordinator
        f.layers = { f.cardLayers(s.w) }
        f.hold(1.2, "The desktop. Nothing is recording.")
        guard let project = try await s.recordProject() else { throw FilmError.missing("a project") }
        guard let card = c.overlay.card(forRecord: project.id), let view = c.overlay.cardView(for: card), let panel = c.overlay.panel(for: card) else {
            throw FilmError.missing("the project's card")
        }
        f.hold(1.6, "Record for Editing finished: its Quick Access card offers Edit instead of Play.")
        f.glide(to: CGPoint(x: panel.frame.midX, y: panel.frame.midY), "Pointing at the card")
        view.mouseEntered(with: Synth.enterExit(.mouseEntered, in: panel))
        f.refresh()
        f.hold(1.2, "Copy, Edit, Reveal in Finder and Close")
        f.press(view.buttons[.edit]!, in: panel, note: "Edit")
        guard let editor = s.current else { throw FilmError.missing("the editor") }
        await s.show(editor)
        f.hold(1.6, "The project opens in the video editor.")
        for (id, note) in [("video.rail", "Left: the icon rail. Each icon opens one group of settings."),
                           ("video.panel", "Next to it: the settings of the chosen group, here Cursor."),
                           ("video.preview", "Middle: the preview, drawn from the project, not burned into the video."),
                           ("transport", "Under it: go to start, play, go to end, the time, the volume and full screen."),
                           ("ruler", "Bottom: the ruler in seconds, with the playhead."),
                           ("zoom", "The zoom lane. It is empty until zooms are added."),
                           ("clip", "The clip lane: one clip, the whole recording, with pictures of it.")] {
            s.outline = s.rect(id, in: editor)
            f.refresh()
            f.hold(2.2, note)
        }
        s.outline = nil
        f.refresh()
        editor.window?.close()
        f.layers = { f.cardLayers(s.w) }
        f.refresh()
        f.hold(1, "The editor is closed.")

        c.perform(.openHistory)
        guard let h = c.history, let hw = h.window else { throw FilmError.missing("History") }
        hw.setContentSize(NSSize(width: 920, height: 600))
        f.layers = { f.windowLayer(hw, at: f.historyOrigin) }
        h.reload()
        _ = await waitUntil(3) { h.records.allSatisfy { c.thumbnails.cached($0.id, maxPixel: HistoryWindowController.thumbnailPixels) != nil } }
        h.reload()
        h.collectionView.layoutSubtreeIfNeeded()
        _ = await waitUntil(1) { false }
        h.select(recordIDs: [project.id])
        f.refresh()
        f.hold(1.6, "Capture History with the recording selected. Edit is on for a recording made for editing.")
        if let edit = findView("history.edit", in: hw.contentView) as? NSButton {
            f.glide(to: f.center(of: edit, in: hw, at: f.historyOrigin), "Edit in History")
            edit.isHighlighted = true
            f.refresh()
            f.hold(0.2, "Edit in History")
            edit.isHighlighted = false
            edit.performClick(nil)
        }
        guard let again = s.current else { throw FilmError.missing("the editor from History") }
        await s.show(again)
        f.hold(2, "History's Edit opens the same editor.")
        again.window?.close()

        let path = project.video!.location.path
        let link = "\(URLCommand.scheme)://edit-recording?path=\(path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!)"
        f.layers = { [] }
        f.refresh()
        f.hold(1.4, "A link opens a project folder too: \(URLCommand.scheme)://edit-recording?path=<folder>")
        guard c.handle(url: URL(string: link)!), let linked = s.current else { throw FilmError.missing("the editor from a link") }
        await s.show(linked)
        f.hold(2, "The link opened the editor on \(project.video!.location.lastPathComponent).")
        f.dark = true
        f.refresh()
        f.hold(2.5, "The editor in Dark appearance.")
    }

    static func e3(_ f: Film, _ s: EditorStage) async throws {
        f.title = "E3  The settings rail: Cursor, Keystrokes, Audio, Camera, Background and Motion Blur. Choosing one switches the panel."
        guard let editor = try await s.openProject() else { throw FilmError.missing("the editor") }
        let video = editor.videoURL
        let before = sha256OrUnreadable(video)
        f.hold(1.5, "The rail starts on Cursor.")
        for section in EditorSection.allCases.dropFirst() + [.cursor] {
            let button = editor.view(identifier: "video.rail.\(section.rawValue)") as! NSButton
            await s.press(button, in: editor, note: section.title)
            f.hold(1.6, "\(section.title): \(section == .cursor ? "Show cursor and Size." : InspectorView.note(section))")
        }
        let show = editor.view(identifier: "video.cursor.show") as! NSButton
        await s.press(show, in: editor, note: "Show cursor: off")
        f.hold(1.8, "The pointer leaves the preview. The video itself never had one.")
        await s.press(show, in: editor, note: "Show cursor: on")
        f.hold(1.2, "The pointer is back.")
        let size = editor.view(identifier: "video.cursor.size") as! NSSlider
        f.glide(to: s.point(of: size, in: editor), "Size")
        for v in stride(from: 1.0, through: 3.0, by: 0.25) {
            size.doubleValue = v
            fire(size)
            await s.settle(editor)
            f.hold(0.12, "Size: \(String(format: "%.1f", v))x")
        }
        f.hold(1.8, "The preview draws the pointer three times larger, from the project's track.")
        f.dark = true
        f.refresh()
        f.hold(2.5, "The same in Dark appearance.")
        editor.window?.close()
        let stored = try RecordingProjectFile.read(from: editor.folder)
        f.layers = { [] }
        let after = sha256OrUnreadable(video)
        f.status = { "project.json after closing: cursor.isVisible=\(stored.edits.cursor.isVisible) cursor.scale=\(stored.edits.cursor.scale)  screen.mp4 sha256 \(before.prefix(12)) before, \(after.prefix(12)) after" }
        f.refresh()
        f.hold(2.5, "Closing the editor writes the change to project.json. The video file is not touched.")
    }

    static func e4(_ f: Film, _ s: EditorStage) async throws {
        f.title = "E4  Space plays and pauses. Go to Start, Go to End, and the volume."
        guard let editor = try await s.openProject(), let window = editor.window else { throw FilmError.missing("the editor") }
        f.hold(1.5, "Paused at 0:00.00.")
        Synth.key(window, 49, " ")
        f.hold(0.3, "Space")
        await s.play(editor, seconds: 1.2, note: "Space: playing. The preview, the playhead and the time move together.")
        Synth.key(window, 49, " ")
        await s.settle(editor)
        f.hold(1.6, "Space again: paused where it was.")
        await s.press(editor.view(identifier: "video.end") as! NSButton, in: editor, note: "Go to End")
        f.hold(1.4, "At the end. Go to End is off.")
        Synth.key(window, 49, " ")
        await s.play(editor, seconds: 0.8, note: "Space at the end plays from the start.")
        Synth.key(window, 49, " ")
        await s.settle(editor)
        await s.press(editor.view(identifier: "video.start") as! NSButton, in: editor, note: "Go to Start")
        f.hold(1.4, "Back at 0:00.00. Go to Start is off.")
        let mute = editor.view(identifier: "video.mute") as! NSButton
        f.glide(to: s.point(of: mute, in: editor), "The volume")
        f.hold(2.4, "This recording has no sound, so the speaker is off and says so. No level slider pretends otherwise.")
        editor.window?.close()

        s.hasAudio = true
        guard let loud = try await s.openProject() else { throw FilmError.missing("the editor with sound") }
        f.hold(2, "Harness: the same project with a source that reports sound, so the volume control has something to set. Nothing is played.")
        let volume = loud.view(identifier: "video.volume") as! NSSlider
        f.glide(to: s.point(of: volume, in: loud), "Volume")
        for percent in stride(from: 100, through: 30, by: -10) {
            volume.doubleValue = Double(percent) / 100
            fire(volume)
            await s.settle(loud)
            f.hold(0.1, "Volume: \(percent)%")
        }
        f.hold(1, "Volume: 30%")
        await s.press(loud.view(identifier: "video.mute") as! NSButton, in: loud, note: "Mute")
        f.hold(1.4, "Muted. The slider reads 0 and the speaker offers Unmute.")
        await s.press(loud.view(identifier: "video.unmute") as! NSButton, in: loud, note: "Unmute")
        f.hold(1.4, "Unmuted at 30% again.")
        f.dark = true
        f.refresh()
        f.hold(2.5, "The same in Dark appearance.")
    }

    static func e10(_ f: Film, _ s: EditorStage) async throws {
        f.title = "E10  Full Screen Preview: the preview fills the screen with playback under it. Esc or the same button returns."
        guard let editor = try await s.openProject(), let window = editor.window else { throw FilmError.missing("the editor") }
        f.hold(1.4, "The editor.")
        await s.press(editor.view(identifier: "video.fullscreen") as! NSButton, in: editor, note: "Full Screen Preview")
        // An offscreen window cannot enter macOS full screen, so the harness gives it the display's size the way full screen would.
        s.origin = .zero
        window.setContentSize(Film.stage)
        window.contentView?.layoutSubtreeIfNeeded()
        await s.settle(editor)
        f.hold(2.4, "Only the preview and playback remain, at the display's size. Full screen preview is dark in either appearance.")
        Synth.key(window, 49, " ")
        await s.play(editor, seconds: 1.4, note: "Space plays in full screen.")
        Synth.key(window, 49, " ")
        await s.settle(editor)
        f.hold(1.2, "Paused.")
        Synth.key(window, 53, "\u{1b}")
        window.setContentSize(EditorStage.editorSize)
        s.origin = EditorStage.editorOrigin
        window.contentView?.layoutSubtreeIfNeeded()
        await s.settle(editor)
        f.hold(2, "Esc: the settings and the timeline come back.")
        await s.press(editor.view(identifier: "video.fullscreen") as! NSButton, in: editor, note: "Full Screen Preview again")
        s.origin = .zero
        window.setContentSize(Film.stage)
        window.contentView?.layoutSubtreeIfNeeded()
        await s.settle(editor)
        f.hold(1.2, "Full screen again.")
        await s.press(editor.view(identifier: "video.exitFullscreen") as! NSButton, in: editor, note: "Exit Full Screen Preview")
        window.setContentSize(EditorStage.editorSize)
        s.origin = EditorStage.editorOrigin
        window.contentView?.layoutSubtreeIfNeeded()
        await s.settle(editor)
        f.hold(1.6, "The button returns too.")
        f.dark = true
        f.refresh()
        f.hold(2, "The editor in Dark appearance.")
    }
}

/// The world, the editor it opens, and the scripted clock and decoder behind it.
@MainActor
final class EditorStage {
    static let editorOrigin = CGPoint(x: 90, y: 40)
    static let editorSize = NSSize(width: 1100, height: 690)

    let film: Film
    let w: World
    let clock = ScriptedClock()
    var origin = editorOrigin
    var hasAudio = false
    var outline: CGRect?
    private(set) var frames: [URL: StillFrames] = [:]
    private var project: CaptureRecord?

    init(_ film: Film, frames count: Int = 120) async throws {
        self.film = film
        (w, _) = try recordingWorld(frames: count)
        // Two seconds of pointer readings, so the pointer moves while the film plays.
        w.env.pointerSource = { ScriptedPointerSource(pacing: .fixed(origin: 0, count: 240)) }
        w.coordinator.makeVideoEditor = { [unowned self] folder in
            let project = try RecordingProjectFile.read(from: folder)
            let decoder = StillFrames(url: folder.appendingPathComponent(project.source.video), hasAudio: hasAudio)
            frames[folder] = decoder
            return VideoEditorWindowController(folder: folder, project: project, frames: decoder, clock: { [unowned self] in clock.now })
        }
    }

    var current: VideoEditorWindowController? { w.coordinator.videoEditors.values.first }

    func recordProject() async throws -> CaptureRecord? {
        film.hold(0.6, "Record for Editing: \(URLCommand.scheme)://record?display=1&x=0&y=0&width=640&height=360")
        project = await recordOnce(w, "display=1&x=0&y=0&width=640&height=360")
        film.refresh()
        return project
    }

    func openProject() async throws -> VideoEditorWindowController? {
        if project == nil { _ = try await recordProject() }
        guard let folder = project?.video?.location, let editor = w.coordinator.openVideoEditor(folder) else { return nil }
        await show(editor)
        return editor
    }

    func show(_ editor: VideoEditorWindowController) async {
        editor.window?.setContentSize(Self.editorSize)
        editor.window?.contentView?.layoutSubtreeIfNeeded()
        await editor.ready()
        film.layers = { [unowned self, unowned editor] in layers(editor) }
        film.status = { [unowned self, unowned editor] in
            let st = editor.state
            return "section=\(st.section.rawValue) playing=\(st.transport.isPlaying) t=\(Timecode.text(st.transport.time(at: clock.now))) previewOnly=\(st.isPreviewOnly) cursor.visible=\(st.project.edits.cursor.isVisible) cursor.scale=\(st.project.edits.cursor.scale) volume=\(st.isMuted ? 0 : st.volume)"
        }
        await settle(editor)
    }

    /// Decodes the frame the playhead is on, ticks the editor, and redraws the film's layers.
    func settle(_ editor: VideoEditorWindowController) async {
        let t = editor.state.transport.time(at: clock.now)
        await frames[editor.folder]?.prepare(frameState(editor.state.project, outputTime: t).sourceTime)
        editor.tick()
        film.refresh()
    }

    /// Plays on the scripted clock, one film frame at a time, at the recording's own speed.
    func play(_ editor: VideoEditorWindowController, seconds: Double, note: String) async {
        for _ in 0..<Int(seconds * Double(Film.fps)) {
            clock.now += 1 / Double(Film.fps)
            await settle(editor)
            film.hold(1 / Double(Film.fps), note)
        }
    }

    func point(of view: NSView, in editor: VideoEditorWindowController) -> CGPoint {
        film.center(of: view, in: editor.window!, at: origin)
    }

    func press(_ button: NSButton, in editor: VideoEditorWindowController, note: String) async {
        film.glide(to: point(of: button, in: editor), note, frames: 12)
        button.isHighlighted = true
        film.refresh()
        film.hold(0.2, note)
        button.isHighlighted = false
        button.performClick(nil)
        await settle(editor)
    }

    /// A part of the editor in window points, y up, for the harness outline.
    func rect(_ id: String, in editor: VideoEditorWindowController) -> CGRect? {
        if id == "transport" { return frameInWindow(editor.view(identifier: "video.play")?.superview?.superview) }
        guard ["ruler", "zoom", "clip"].contains(id) else { return frameInWindow(editor.view(identifier: id)) }
        guard let tl = editor.view(identifier: "video.timeline") as? TimelineView else { return nil }
        let r = id == "ruler" ? tl.rulerRect : id == "zoom" ? tl.zoomLaneRect : tl.clipLaneRect
        return tl.convert(r, to: nil)
    }

    func layers(_ editor: VideoEditorWindowController) -> [(CGImage, CGRect)] {
        guard let window = editor.window, let image = editorImage(editor, dark: film.dark) else { film.failures.append("could not render the editor"); return [] }
        var layers = [(image, CGRect(origin: origin, size: window.frame.size))]
        if editor.state.isPreviewOnly, let content = window.contentView?.frame.size {
            // Full screen has no title bar, so only the content is shown.
            let bar = (window.frame.height - content.height) * 2
            if let cropped = image.cropping(to: CGRect(x: 0, y: bar, width: content.width * 2, height: content.height * 2)) {
                layers = [(cropped, CGRect(origin: origin, size: content))]
            }
        }
        if let outline, let box = Self.outlineImage(size: outline.insetBy(dx: -4, dy: -4).size) {
            layers.append((box, outline.insetBy(dx: -4, dy: -4).offsetBy(dx: origin.x, dy: origin.y)))
        }
        return layers
    }

    /// The harness's orange outline around one part of the editor. Not part of the app.
    static func outlineImage(size: CGSize) -> CGImage? {
        let ctx = Pix.context(Int(size.width * 2), Int(size.height * 2))
        ctx.scaleBy(x: 2, y: 2)
        ctx.setStrokeColor(CGColor(srgbRed: 1, green: 0.55, blue: 0.1, alpha: 1))
        ctx.setLineWidth(3)
        ctx.addPath(CGPath(roundedRect: CGRect(origin: .zero, size: size).insetBy(dx: 1.5, dy: 1.5), cornerWidth: 6, cornerHeight: 6, transform: nil))
        ctx.strokePath()
        return ctx.makeImage()
    }
}
