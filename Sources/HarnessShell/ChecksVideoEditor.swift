import AppKit
import AVFoundation
import CornermarkCore
import CornermarkDesign
@testable import CornermarkVideoEditor
import CryptoKit
@testable import CornermarkShell

/// Source pictures decoded one at a time on request, so a check or a film decides exactly which moment the preview shows.
@MainActor
final class StillFrames: SourceFrames {
    private let generator: AVAssetImageGenerator
    private var ready: (time: Double, image: CGImage)?
    private var delivered: Double?
    private(set) var followed: [(time: Double, playing: Bool)] = []
    var hasAudio: Bool
    var volume: Float = 1

    init(url: URL, hasAudio: Bool = false) {
        generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        self.hasAudio = hasAudio
    }

    func load() async {}

    /// Decodes the picture at `time` so the next `frame(at: time)` returns it.
    func prepare(_ time: Double) async {
        guard ready?.time != time else { return }
        if let image = try? await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image { ready = (time, image) }
    }

    func follow(sourceTime: Double, playing: Bool) { followed.append((sourceTime, playing)) }

    func frame(at sourceTime: Double) -> CGImage? {
        guard let ready, abs(ready.time - sourceTime) < 1e-6, delivered != sourceTime else { return nil }
        delivered = sourceTime
        return ready.image
    }
}

final class ScriptedClock { var now = 100.0 }

func sha256OrUnreadable(_ url: URL) -> String {
    (try? Data(contentsOf: url)).map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() } ?? "unreadable"
}

/// The editor window at 2 pixels per point. The preview's picture and pointer are layers, which `cacheDisplay` leaves out,
/// so they are rendered from the layer tree on top of the rest of the window.
@MainActor
func editorImage(_ editor: VideoEditorWindowController, dark: Bool = false) -> CGImage? {
    guard let window = editor.window, let base = windowImage(window, dark: dark || editor.state.isPreviewOnly) else { return nil }
    guard let preview = editor.view(identifier: "video.preview") as? PreviewView, !preview.isHidden, let layer = preview.layer else { return base }
    let ctx = Pix.context(base.width, base.height)
    ctx.draw(base, in: CGRect(x: 0, y: 0, width: base.width, height: base.height))
    let r = preview.convert(preview.bounds, to: nil)
    ctx.scaleBy(x: 2, y: 2)
    ctx.translateBy(x: r.minX, y: r.minY)
    preview.appearance = window.appearance
    preview.layoutSubtreeIfNeeded()
    preview.updateLayer()
    layer.render(in: ctx)
    if let panel = editor.view(identifier: "video.export.panel"), !panel.isHiddenOrHasHiddenAncestor,
       let rep = panel.bitmapImageRepForCachingDisplay(in: panel.bounds) {
        panel.appearance = window.appearance
        panel.cacheDisplay(in: panel.bounds, to: rep)
        let f = panel.convert(panel.bounds, to: nil)
        if let image = rep.cgImage { ctx.draw(image, in: CGRect(x: f.minX - r.minX, y: f.minY - r.minY, width: f.width, height: f.height)) }
    }
    return ctx.makeImage()
}

@MainActor
func snapshotEditor(_ editor: VideoEditorWindowController, name: String, dark: Bool = false) {
    let url = URL(fileURLWithPath: scratch + name + ".png")
    guard let image = editorImage(editor, dark: dark), let png = AssetStore.pngData(from: image), (try? png.write(to: url)) != nil else {
        return check(false, "snapshot \(name) could not be written")
    }
    print("SNAPSHOT \(url.path) \(image.width)x\(image.height)")
}

/// The frame of `view` in its window's content, y up.
@MainActor
func frameInWindow(_ view: NSView?) -> CGRect { view.map { $0.convert($0.bounds, to: nil) } ?? .null }

@MainActor
func checkVideoEditor() async throws {
    section("video editor: opening")
    let (w, _) = try recordingWorld(frames: 120)
    defer { w.cleanup() }
    let c = w.coordinator
    guard let plain = await recordOnce(w, "display=1&x=0&y=0&width=640&height=360&style=video"),
          let project = await recordOnce(w, "display=1&x=0&y=0&width=640&height=360"), let folder = project.video?.location else {
        return check(false, "a plain video and a project are recorded from the fixture display")
    }
    check(!plain.opensVideoEditor && project.opensVideoEditor, "a recording for editing opens in the video editor, a plain video does not")
    let plainCard = c.overlay.card(forRecord: plain.id), projectCard = c.overlay.card(forRecord: project.id)
    check(plainCard?.actions == [.copy, .play, .makeGif, .reveal, .close] && plainCard?.openAction == .play, "a plain video's card keeps Play and adds Convert to GIF", detail: "\(plainCard?.actions ?? [])")
    check(projectCard?.actions == [.copy, .edit, .reveal, .close] && projectCard?.openAction == .edit, "a project's card offers Edit", detail: "\(projectCard?.actions ?? [])")
    let videoHash = sha256OrUnreadable(folder.appendingPathComponent(RecordingProjectFile.videoName))

    if let card = projectCard, let view = c.overlay.cardView(for: card), let button = view.buttons[.edit] {
        check(button.toolTip == "Edit" && button.accessibilityLabel() == "Edit", "the card's Edit button is labelled Edit")
        check(click("card.edit", in: view), "the card's Edit button is pressed")
    }
    let key = folder.standardizedFileURL.resolvingSymlinksInPath()
    check(c.videoEditors[key] != nil && c.editors.isEmpty, "Quick Access Edit opens the video editor, not the picture editor")
    check(c.overlay.card(forRecord: project.id) == nil || c.overlay.card(forRecord: project.id)?.state == .closing, "and closes the card")
    check(w.presented.contains { $0 === c.videoEditors[key]?.window } && nothingOnScreen(), "the editor is presented through the environment and stays off screen here")
    let editor = c.videoEditors[key]
    check(editor?.window?.title == folder.lastPathComponent, "the window is titled with the recording's name", detail: editor?.window?.title ?? "nil")

    c.perform(.openHistory)
    guard let h = c.history else { return check(false, "History opens") }
    h.setFilter(.recordings)
    h.select(recordIDs: [plain.id])
    check(h.actionButtons["edit"]?.isEnabled == false, "History Edit is off for a plain video")
    h.select(recordIDs: [project.id])
    check(h.actionButtons["edit"]?.isEnabled == true, "History Edit is on for a recording for editing")
    h.editSelected()
    check(c.videoEditors.count == 1 && c.videoEditors[key] === editor, "History Edit brings back the open editor instead of a second one")
    h.select(recordIDs: [plain.id, project.id])
    let opened = w.opened.count
    h.editSelected()
    check(w.opened.count == opened && c.videoEditors.count == 1, "editing a mixed selection opens the project and leaves the plain video alone")

    c.closeAllEditors()
    check(c.videoEditors.isEmpty, "closing the window forgets the editor")
    func link(_ path: String) -> URL { URL(string: "\(URLCommand.scheme)://edit-recording?path=\(path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!)")! }
    check(c.handle(url: link(folder.path)) && c.videoEditors[key] != nil, "an edit-recording link opens the project folder")
    check(URLCommand.parse(link(plain.video!.file.path)) == .failure(.invalidProject(plain.video!.file.path)), "a link to a plain video is refused")
    check(URLCommand.parse(link(w.root.path)) == .failure(.invalidProject(w.root.path)), "a link to a folder without a project is refused")
    check(URLCommand.parse(URL(string: "\(URLCommand.scheme)://edit-recording")!) == .failure(.missingPath), "a link without a path is refused")
    check(URLCommand.parse(link("relative/folder")) == .failure(.invalidProject("relative/folder")), "a relative path is refused")
    c.closeAllEditors()

    let damaged = w.root.appendingPathComponent("damaged", isDirectory: true)
    try FileManager.default.createDirectory(at: damaged, withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: damaged.appendingPathComponent(RecordingProjectFile.projectName))
    check(c.openVideoEditor(damaged) == nil && c.hud.lastMessage == "Could not open the recording: its video is missing. Look for it in the save folder.",
          "a project whose video is missing is refused, saying what is missing and where to look", detail: c.hud.lastMessage ?? "nil")
    try Data("not json".utf8).write(to: damaged.appendingPathComponent(RecordingProjectFile.projectName))
    check(c.openVideoEditor(damaged) == nil && c.hud.lastMessage == "Could not open the recording: its project file is missing or damaged.",
          "a damaged project file is refused with its own message", detail: c.hud.lastMessage ?? "nil")

    try await checkVideoEditorLayout(w, folder: folder)
    try await checkVideoEditorPlayback(w, folder: folder)
    try await checkVideoEditorSaving(w, folder: folder, videoHash: videoHash)
    try await checkVideoEditorClips(w, folder: folder, videoHash: videoHash)
    try await checkVideoEditorCursor(w, folder: folder)
    try await checkVideoEditorPerformance(folder: folder)
    try await checkVideoEditorLiveCut(folder: folder)
}

@MainActor
func dragTimeline(_ timeline: TimelineView, from a: CGPoint, to b: CGPoint, steps: Int = 6, during: (Int) -> Void = { _ in }) {
    guard let window = timeline.window else { return }
    func event(_ type: NSEvent.EventType, _ p: CGPoint) -> NSEvent {
        Synth.mouse(type, at: window.convertPoint(toScreen: timeline.convert(p, to: nil)), in: window)
    }
    timeline.mouseDown(with: event(.leftMouseDown, a))
    for i in 1...max(steps, 1) {
        let f = CGFloat(i) / CGFloat(max(steps, 1))
        timeline.mouseDragged(with: event(.leftMouseDragged, CGPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f)))
        during(i)
    }
    timeline.mouseUp(with: event(.leftMouseUp, b))
}

@MainActor
private func checkVideoEditorClips(_ w: World, folder: URL, videoHash: String) async throws {
    section("video editor: split, delete and trim")
    let project = try RecordingProjectFile.read(from: folder)
    let clock = ScriptedClock()
    let frames = StillFrames(url: folder.appendingPathComponent(project.source.video))
    let editor = VideoEditorWindowController(folder: folder, project: project, frames: frames, clock: { clock.now })
    defer { editor.window?.close() }
    guard let window = editor.window, let content = window.contentView, let timeline = editor.view(identifier: "video.timeline") as? TimelineView,
          let split = editor.view(identifier: "video.split") as? NSButton, let delete = editor.view(identifier: "video.deleteClip") as? NSButton else {
        return check(false, "an editor with a timeline and the clip buttons")
    }
    window.setContentSize(NSSize(width: 1200, height: 760))
    content.layoutSubtreeIfNeeded()
    await editor.ready()
    func clips() -> [[Double]] { editor.state.project.edits.clips.map { [$0.start, $0.end] } }
    func now() -> Double { editor.state.transport.time(at: clock.now) }
    check(project.edits.clips == [Clip(start: 0, end: project.source.duration)] && timeline.clipRects.count == 1 && timeline.cutMarks.isEmpty,
          "a new recording is one clip, the whole recording, with no cut marks", detail: "\(clips())")
    check(split.isEnabled == false && delete.isEnabled == false && delete.toolTip == "A video keeps at least one clip",
          "at the start Split is off, and Delete is off and says a video keeps one clip")

    editor.seek(to: 0.5)
    check(split.isEnabled, "inside a clip Split is on")
    Synth.key(window, 11, "b", modifiers: .command)
    check(clips() == [[0, 0.5], [0.5, 2]] && editor.state.transport.duration == 2, "Command-B splits the clip at the playhead and keeps every frame",
          detail: "\(clips())")
    content.layoutSubtreeIfNeeded()
    let mark = CGFloat(timeline.scale.x(0.5)).rounded()
    check(timeline.cutMarks == [mark] && timeline.clipRects.count == 2 && timeline.clipRects[0].maxX < mark && timeline.clipRects[1].minX > mark,
          "the clip lane marks the cut and leaves a seam between the two clips", detail: "\(timeline.cutMarks) \(timeline.clipRects)")
    check(delete.isEnabled && !split.isEnabled, "on the cut Split is off and Delete is on")
    editor.seek(to: 1.5)
    split.performClick(nil)
    check(clips() == [[0, 0.5], [0.5, 1.5], [1.5, 2]] && timeline.cutMarks.count == 2, "the Split button splits at the playhead too", detail: "\(clips())")
    check(timeline.accessibilityValue() as? String == "0:01.50, clip 3 of 3", "the timeline says which clip the playhead is in",
          detail: "\(timeline.accessibilityValue() ?? "nil")")
    snapshotEditor(editor, name: "video-editor-clips-split")

    let lane = timeline.clipLaneRect
    let middle = CGPoint(x: CGFloat(timeline.scale.x(1)), y: lane.midY)
    dragTimeline(timeline, from: middle, to: middle, steps: 1)
    check(editor.state.selectedClip == 1 && timeline.selection == 1 && abs(now() - 1) < 0.01, "a click on a clip picks it and moves the playhead there")
    snapshotEditor(editor, name: "video-editor-clips-selected")
    snapshotEditor(editor, name: "video-editor-clips-selected-dark", dark: true)
    window.appearance = nil
    Synth.key(window, 51, "\u{7f}")
    check(clips() == [[0, 0.5], [1.5, 2]] && editor.state.transport.duration == 1 && editor.state.selectedClip == nil,
          "Delete removes the picked clip and the video is a second shorter", detail: "\(clips())")
    check(abs(now() - 0.5) < 1e-9 && editor.previewState?.sourceTime == 1.5, "the playhead waits on the cut, where the preview now shows source 1.5 s",
          detail: "\(now()) \(String(describing: editor.previewState?.sourceTime))")
    check(timeline.accessibilityValue() as? String == "0:00.50, clip 2 of 2", "the cut belongs to the clip it starts")

    let before = clips()
    content.layoutSubtreeIfNeeded()
    let pps = timeline.scale.pointsPerSecond
    let endEdge = CGPoint(x: timeline.clipRects[0].maxX - 2, y: lane.midY)
    check(timeline.edge(at: endEdge).map { $0.index == 0 && $0.edge == .end } == true
          && timeline.edge(at: CGPoint(x: timeline.clipRects[1].minX + 2, y: lane.midY)).map { $0.index == 1 && $0.edge == .start } == true,
          "at a seam each side takes its own clip's edge")
    var midDrag: [Double] = []
    dragTimeline(timeline, from: endEdge, to: CGPoint(x: endEdge.x - 0.25 * pps, y: lane.midY)) { _ in
        midDrag.append(Double(timeline.clipRects[0].maxX) + Double(TimelineView.Metrics.seam) / 2)
    }
    check(clips() == [[0, 0.25], [1.5, 2]], "dragging the first clip's end a quarter second left trims it to 0.25 s", detail: "\(clips())")
    check(abs((midDrag.last ?? 0) - (Double(endEdge.x) + 2 - 0.25 * pps)) < 1.5, "while dragging, the edge stays under the pointer",
          detail: "\(midDrag.map { Int($0) }) pointer end \(Int(Double(endEdge.x) - 0.25 * pps))")
    check(abs(now() - (0.25 - 1.0 / 60)) < 1e-9 && editor.previewState?.sourceTime == 0.25 - 1.0 / 60,
          "the playhead rides the edge: the preview shows the clip's new last frame", detail: "\(now())")
    check(editor.state.transport.duration == 0.75 && editor.state.selectedClip == 0, "the video is shorter and the trimmed clip stays picked")
    content.layoutSubtreeIfNeeded()
    let startEdge = CGPoint(x: timeline.clipRects[1].minX + 2, y: lane.midY)
    let pps2 = timeline.scale.pointsPerSecond
    var anchored: [CGFloat] = []
    dragTimeline(timeline, from: startEdge, to: CGPoint(x: startEdge.x - 0.25 * pps2, y: lane.midY)) { _ in anchored.append(timeline.clipRects[1].maxX) }
    check(clips() == [[0, 0.25], [1.25, 2]], "dragging the next clip's start left brings back a quarter second that was cut", detail: "\(clips())")
    check(Set(anchored).count == 1, "while its start moves, the clip's end stays where it was", detail: "\(anchored)")
    check(abs(now() - 0.25) < 1e-9 && editor.previewState?.sourceTime == 1.25, "the preview shows the clip's new first frame")
    dragTimeline(timeline, from: CGPoint(x: timeline.clipRects[1].minX + 2, y: lane.midY), to: CGPoint(x: timeline.clipRects[1].maxX + 300, y: lane.midY))
    let refused = clips()
    check(abs(refused[1][1] - refused[1][0] - 1.0 / 60) < 1e-9, "a start dragged past the end leaves a one-frame clip, never an empty one", detail: "\(refused)")

    let undoItem = NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
    check(editor.canUndo && window.validateMenuItem(undoItem), "the Edit menu's Undo is on after an edit")
    check(NSApp.sendAction(Selector(("undo:")), to: window, from: undoItem) && clips() == [[0, 0.25], [1.25, 2]],
          "the Edit menu's Undo reaches the editor and undoes the whole last drag in one step", detail: "\(clips())")
    Synth.key(window, 6, "z", modifiers: .command)
    Synth.key(window, 6, "z", modifiers: .command)
    check(clips() == before && editor.state.transport.duration == 1, "two more undo both trims", detail: "\(clips())")
    Synth.key(window, 6, "z", modifiers: .command)
    Synth.key(window, 6, "z", modifiers: .command)
    Synth.key(window, 6, "z", modifiers: .command)
    check(clips() == [[0, 2]] && editor.state.transport.duration == 2 && timeline.cutMarks.isEmpty, "undoing every step brings back the one whole clip")
    editor.undo()
    check(clips() == [[0, 2]] && editor.state.project.edits == project.edits, "undo past the first edit does nothing")
    Synth.key(window, 6, "Z", modifiers: [.command, .shift])
    check(clips() == [[0, 0.5], [0.5, 2]], "Shift-Command-Z redoes the first split", detail: "\(clips())")
    for _ in 0..<5 { editor.redo() }
    check(clips() == refused && !editor.canRedo, "redo walks forward to the last edit", detail: "\(clips())")
    editor.undo()
    editor.setCursor(CursorSettings(isVisible: true, scale: 3))
    editor.setCursor(CursorSettings(isVisible: true, scale: 3.5))
    editor.undo()
    check(editor.state.project.edits.cursor.scale == project.edits.cursor.scale && clips() == [[0, 0.25], [1.25, 2]],
          "a size drag is one undo step and leaves the clips alone")
    editor.selectClip(0)
    Synth.key(window, 53, "\u{1b}")
    check(editor.state.selectedClip == nil && !editor.state.isPreviewOnly, "Esc lets go of the picked clip")
    Synth.key(window, 11, "b")
    check(clips() == [[0, 0.25], [1.25, 2]], "B without Command is not taken")

    editor.seek(to: 0.1)
    let f = 1.0 / Double(project.source.fps)
    timeline.keyDown(with: Synth.keyEvent(window, 124, modifiers: .option))
    check(abs(clips()[0][0] - f) < 1e-9 && now() == 0 && editor.previewState?.sourceTime == f,
          "Option-Right on the focused timeline trims a frame off the clip's start, and the preview shows its new first frame",
          detail: "\(clips())")
    timeline.keyDown(with: Synth.keyEvent(window, 123, modifiers: [.option, .shift]))
    check(clips()[0][0] == 0, "Option-Shift-Left brings the start back, stopping at the recording's start")
    for _ in 0..<3 { timeline.keyDown(with: Synth.keyEvent(window, 124, modifiers: [.option, .command])) }
    check(abs(clips()[0][1] - (0.25 + 3 * f)) < 1e-9 && abs(now() - (0.25 + 2 * f)) < 1e-9,
          "Option-Command-Right moves the clip's end out a frame per press, and the playhead shows its last frame", detail: "\(clips())")
    editor.undo()
    check(abs(clips()[0][1] - 0.25) < 1e-9 && clips()[0][0] == 0, "three presses on one edge are one undo step", detail: "\(clips())")
    editor.selectClip(1)
    check((timeline.accessibilityValue() as? String)?.hasSuffix("clip 2 of 2, clip 2 picked") == true && timeline.accessibilityHelp()?.contains("Option") == true,
          "the timeline says which clip is picked and how to trim from the keyboard", detail: "\(timeline.accessibilityValue() ?? "nil")")
    timeline.keyDown(with: Synth.keyEvent(window, 123, modifiers: [.option, .command, .shift]))
    check(abs(clips()[1][1] - (1.25 + f)) < 1e-9 && clips()[0] == [0, 0.25] && editor.state.selectedClip == 1,
          "with a clip picked, the keys trim that clip, stop a frame after its start, and keep it picked", detail: "\(clips())")
    editor.undo()

    let held = clips()
    let grip = CGPoint(x: timeline.clipRects[1].maxX - 2, y: lane.midY)
    func mouse(_ type: NSEvent.EventType, _ p: CGPoint) -> NSEvent { Synth.mouse(type, at: window.convertPoint(toScreen: timeline.convert(p, to: nil)), in: window) }
    timeline.mouseDown(with: mouse(.leftMouseDown, grip))
    Synth.key(window, 51, "\u{7f}")
    check(clips() == [held[0]] && timeline.trim == nil && editor.state.selectedClip == nil, "Delete while an edge is held removes the clip and ends the drag")
    timeline.keyDown(with: Synth.keyEvent(window, 124, modifiers: .option))
    timeline.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: grip.x - 80, y: grip.y)))
    timeline.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: grip.x - 80, y: grip.y)))
    check(clips().count == 1 && clips()[0][0] > 0, "keys and the rest of that drag act on what is there now, and nothing brings the deleted clip back",
          detail: "\(clips())")
    editor.undo()
    editor.undo()
    check(clips() == held, "two undo steps put back the nudge and the deleted clip", detail: "\(clips())")

    editor.window?.close()
    let stored = try RecordingProjectFile.read(from: folder)
    check(stored.edits.clips == [Clip(start: 0, end: 0.25), Clip(start: 1.25, end: 2)], "closing writes the clips to project.json",
          detail: "\(stored.edits.clips)")
    check(sha256OrUnreadable(folder.appendingPathComponent(RecordingProjectFile.videoName)) == videoHash, "the source video is unchanged")
    guard let again = w.coordinator.openVideoEditor(folder) else { return check(false, "the editor reopens") }
    check(again.state.project.edits.clips == stored.edits.clips && again.state.transport.duration == 1 && !again.canUndo,
          "reopening shows the two clips, one second long, with nothing to undo")
    w.coordinator.closeAllEditors()
    var offGrid = project
    offGrid.source.duration = project.source.duration + 0.004
    offGrid.edits.clips = []
    let odd = VideoEditorWindowController(folder: folder, project: offGrid, frames: StillFrames(url: folder.appendingPathComponent(project.source.video)), clock: { clock.now })
    if let oddTimeline = odd.view(identifier: "video.timeline") as? TimelineView, let oddWindow = odd.window {
        let f = 1.0 / Double(project.source.fps)
        var ends: [Double] = []
        for (code, mods) in [(123, NSEvent.ModifierFlags([.option, .command])), (123, [.option, .command]), (124, [.option, .command]), (124, [.option, .command])] {
            oddTimeline.keyDown(with: Synth.keyEvent(oddWindow, UInt16(code), modifiers: mods))
            ends.append(odd.state.project.edits.clips[0].end)
        }
        let want = [2, 2 - f, 2, 2.004]
        check(zip(ends, want).allSatisfy { abs($0 - $1) < 1e-9 }, "an end off the frame grid steps to the frame next to it and back, one frame per press",
              detail: "\(ends)")
        odd.window?.close()
    }
    var whole = stored
    whole.edits.clips = []
    try RecordingProjectFile.write(whole, to: folder)
    check(try RecordingProjectFile.read(from: folder).edits.clips == [Clip(start: 0, end: project.source.duration)], "the fixture is back to one clip for the checks after this")
}

@MainActor
private func checkVideoEditorLiveCut(folder: URL) async throws {
    section("video editor: playing across a cut")
    var project = try RecordingProjectFile.read(from: folder)
    project.edits.clips = [Clip(start: 0, end: 0.6), Clip(start: 1.2, end: 2)]
    let video = folder.appendingPathComponent(project.source.video)
    let live = PlayerFrames(url: video)
    let editor = VideoEditorWindowController(folder: folder, project: project, frames: live)
    defer { editor.window?.close() }
    editor.window?.setContentSize(NSSize(width: 1200, height: 760))
    await editor.ready()
    editor.togglePlayback()
    let begin = CACurrentMediaTime()
    var after: [(late: Double, off: Double)] = []
    while CACurrentMediaTime() - begin < 1.2 {
        try? await Task.sleep(nanoseconds: 16_666_667)
        editor.tick()
        let t = editor.state.transport.time(at: CACurrentMediaTime())
        guard t > 0.6 + 1e-3, t < 1.3 else { continue }
        let expected = editor.state.project.timeline.sourceTime(at: t)
        after.append((t - 0.6, abs(live.player.currentTime().seconds - expected)))
    }
    editor.togglePlayback()
    let first = after.first
    let worst = after.dropFirst().map(\.off).max() ?? 99
    print(String(format: "CUT live player after the cut at 0.60 s: first tick %.1f ms after it, off by %.1f ms; worst afterwards %.1f ms over %d ticks; player syncs=%d",
                 (first?.late ?? 0) * 1000, (first?.off ?? 0) * 1000, worst * 1000, after.count, live.syncs))
    check(live.syncs == 2, "the player is put in step twice: when playing starts and at the cut", detail: "\(live.syncs)")
    check(first.map { $0.off < 0.05 } == true && worst < 0.05, "the live player jumps over the removed part with the playhead",
          detail: String(format: "first off %.3f s, worst %.3f s", first?.off ?? -1, worst))
    check(nothingOnScreen(), "playing across a cut put nothing on screen")
}

@MainActor
private func checkVideoEditorLayout(_ w: World, folder: URL) async throws {
    section("video editor: layout and sections")
    guard let editor = w.coordinator.openVideoEditor(folder), let window = editor.window, let content = window.contentView else {
        return check(false, "the editor opens")
    }
    defer { w.coordinator.closeAllEditors() }
    window.setContentSize(NSSize(width: 1200, height: 760))
    content.layoutSubtreeIfNeeded()
    await editor.ready()
    let rail = editor.view(identifier: "video.rail"), panel = editor.view(identifier: "video.panel")
    let preview = editor.view(identifier: "video.preview"), timeline = editor.view(identifier: "video.timeline")
    let bar = editor.view(identifier: "video.play")?.superview?.superview
    let r = frameInWindow(rail), p = frameInWindow(panel), v = frameInWindow(preview), t = frameInWindow(timeline), b = frameInWindow(bar)
    check(r.minX == 0 && r.width == 48 && p.minX > r.maxX && v.minX >= p.maxX, "left to right: the icon rail, the settings panel, the preview", detail: "\(r) \(p) \(v)")
    check(b.maxY <= v.minY + 0.5 && b.minX == v.minX && b.width == v.width, "playback sits under the preview", detail: "\(b) \(v)")
    check(t.minX == 0 && t.width == content.bounds.width && t.maxY <= min(b.minY, p.minY) + 1.5 && t.minY == 0, "the timeline runs the full width at the bottom", detail: "\(t)")
    let ids = EditorSection.allCases.map { "video.rail.\($0.rawValue)" }
    let railButtons = ids.compactMap { editor.view(identifier: $0) as? IconButton }
    check(railButtons.count == 6 && railButtons.map { $0.accessibilityLabel() ?? "" } == ["Cursor", "Keystrokes", "Audio", "Camera", "Background", "Motion Blur"],
          "the rail holds Cursor, Keystrokes, Audio, Camera, Background and Motion Blur in that order")
    check(railButtons.allSatisfy { NSImage(systemSymbolName: $0.symbol, accessibilityDescription: nil) != nil }, "every rail symbol exists")
    check(railButtons.allSatisfy { $0.selection == .neutral } && railButtons.first?.isSelected == true, "the rail is navigation: neutral selection, Cursor chosen first")

    let title = editor.view(identifier: "video.panel.title") as? NSTextField
    let note = editor.view(identifier: "video.panel.note") as? NSTextField
    let show = editor.view(identifier: "video.cursor.show") as? NSButton
    for (i, section) in EditorSection.allCases.enumerated() {
        railButtons[i].performClick(nil)
        let only = railButtons.enumerated().allSatisfy { $0.element.isSelected == ($0.offset == i) }
        let shows = section == .cursor ? (show?.isHidden == false && note?.isHidden == true) : (show?.isHidden == true && note?.isHidden == false && note?.stringValue.isEmpty == false)
        check(editor.state.section == section && title?.stringValue == section.title && only && shows,
              "\(section.title): the panel shows its title and \(section == .cursor ? "its settings" : "\"\(note?.stringValue ?? "")\"")")
    }
    railButtons[0].performClick(nil)

    window.setContentSize(window.minSize)
    content.layoutSubtreeIfNeeded()
    let parts = ["video.start", "video.end", "video.split", "video.deleteClip", "video.time", "video.mute", "video.fullscreen"]
        .map { frameInWindow(editor.view(identifier: $0)) }
    let row = frameInWindow(bar)
    let apart = zip(parts.dropFirst(), parts.dropFirst(2)).allSatisfy { $0.maxX <= $1.minX } && parts.allSatisfy { row.contains($0) }
    check(apart && frameInWindow(preview).height > 200, "at the smallest window size the playback row neither overlaps nor clips", detail: "\(parts)")
    _ = await waitUntil(3) { editor.tick(); return editor.previewImage != nil }
    snapshotEditor(editor, name: "video-editor-min")
    window.setContentSize(NSSize(width: 1200, height: 760))
    content.layoutSubtreeIfNeeded()

    if let tl = timeline as? TimelineView {
        check(tl.rulerRect.maxY < tl.zoomLaneRect.minY && tl.zoomLaneRect.maxY < tl.clipLaneRect.minY && tl.zoomLaneRect.width == tl.clipLaneRect.width,
              "the timeline stacks a ruler, a zoom lane and a clip lane of one width")
        check(tl.thumbnails.count == 24 && tl.duration == editor.state.project.source.duration, "the clip lane holds pictures of the recording", detail: "\(tl.thumbnails.count)")
        check(tl.accessibilityRole() == .slider && tl.accessibilityValue() as? String == "0:00.00", "the timeline reads as a slider with the playhead's time")
    } else { check(false, "a timeline view") }
    _ = await waitUntil(3) { editor.tick(); return editor.previewImage != nil }
    snapshotEditor(editor, name: "video-editor")
    snapshotEditor(editor, name: "video-editor-dark", dark: true)
    window.appearance = nil
}

@MainActor
private func checkVideoEditorPlayback(_ w: World, folder: URL) async throws {
    section("video editor: playback")
    let project = try RecordingProjectFile.read(from: folder)
    let video = folder.appendingPathComponent(project.source.video)
    let clock = ScriptedClock()
    let frames = StillFrames(url: video)
    let editor = VideoEditorWindowController(folder: folder, project: project, frames: frames, clock: { clock.now })
    defer { editor.window?.close() }
    guard let window = editor.window else { return check(false, "an editor window") }
    await editor.ready()
    await frames.prepare(0)
    editor.tick()
    check(editor.previewImage != nil && editor.previewState == frameState(project, outputTime: 0), "the preview shows the frame frameState names at 0")
    check(project.source.duration > 1.9, "the fixture project is about two seconds long", detail: "\(project.source.duration)")
    let start = editor.view(identifier: "video.start") as? NSButton, end = editor.view(identifier: "video.end") as? NSButton
    let play = editor.view(identifier: "video.play") as? NSButton, pause = editor.view(identifier: "video.pause") as? NSButton
    let time = editor.view(identifier: "video.time") as? NSTextField
    check(start?.isEnabled == false && end?.isEnabled == true && play?.isHidden == false && pause?.isHidden == true, "at the start: Go to Start is off, Play shows")

    Synth.key(window, 49, " ")
    check(editor.state.transport.isPlaying && play?.isHidden == true && pause?.isHidden == false, "Space plays and Pause takes Play's place")
    clock.now += 0.5
    await frames.prepare(0.5)
    editor.tick()
    check(editor.previewState == frameState(project, outputTime: 0.5) && time?.stringValue == "0:00.50 / \(Timecode.text(project.source.duration))",
          "half a second later the preview and the readout are at 0:00.50", detail: time?.stringValue ?? "nil")
    check(frames.followed.last?.playing == true && frames.followed.last?.time == 0.5, "the source decoder follows the playhead while playing")
    if let cursor = editor.previewState?.cursor, let expected = frameState(project, outputTime: 0.5).cursor {
        check(cursor == expected, "the pointer is drawn where frameState puts it")
    } else { check(project.events.pointer.isEmpty, "the pointer is drawn when the project has a track") }
    Synth.key(window, 49, " ")
    clock.now += 1
    editor.tick()
    check(!editor.state.transport.isPlaying && editor.state.transport.time(at: clock.now) == 0.5, "Space again pauses where it was")
    Synth.key(window, 49, " ", modifiers: .command)
    check(!editor.state.transport.isPlaying, "Command-Space is not taken")

    end?.performClick(nil)
    check(editor.state.transport.time(at: clock.now) == project.source.duration && end?.isEnabled == false, "Go to End moves to the last moment")
    Synth.key(window, 49, " ")
    check(editor.state.transport.time(at: clock.now) == 0 && editor.state.transport.isPlaying, "Space at the end plays from the start")
    clock.now += project.source.duration + 1
    editor.tick()
    check(!editor.state.transport.isPlaying && editor.state.transport.time(at: clock.now) == project.source.duration, "playing stops at the end")
    start?.performClick(nil)
    check(editor.state.transport.time(at: clock.now) == 0 && start?.isEnabled == false, "Go to Start moves back to 0")

    if let timeline = editor.view(identifier: "video.timeline") {
        let s = TimelineScale(duration: project.source.duration, start: 36, end: Double(timeline.bounds.width - 16))
        let p = timeline.convert(CGPoint(x: s.x(1), y: 70), to: nil)
        let global = window.convertPoint(toScreen: p)
        timeline.mouseDown(with: Synth.mouse(.leftMouseDown, at: global, in: window))
        timeline.mouseUp(with: Synth.mouse(.leftMouseUp, at: global, in: window))
        check(abs(editor.state.transport.time(at: clock.now) - 1) < 0.01, "a click on the timeline moves the playhead there",
              detail: "\(editor.state.transport.time(at: clock.now))")
        check(timeline.acceptsFirstResponder && window.makeFirstResponder(timeline), "the timeline takes keyboard focus")
        let before = editor.state.transport.time(at: clock.now)
        timeline.keyDown(with: Synth.keyEvent(window, 124))
        let frame = 1 / Double(project.source.fps)
        check(abs(editor.state.transport.time(at: clock.now) - before - frame) < 1e-6, "Right moves the playhead one frame")
        timeline.keyDown(with: Synth.keyEvent(window, 123, modifiers: .shift))
        check(abs(editor.state.transport.time(at: clock.now) - (before + frame - 1)) < 1e-6, "Shift-Left moves it back a second")
        timeline.keyDown(with: Synth.keyEvent(window, 119))
        check(editor.state.transport.time(at: clock.now) == project.source.duration, "End jumps to the end")
        check(timeline.accessibilityPerformDecrement() && editor.state.transport.time(at: clock.now) == project.source.duration - 1, "VoiceOver's decrement steps back a second")
        timeline.keyDown(with: Synth.keyEvent(window, 115))
        check(editor.state.transport.time(at: clock.now) == 0, "Home jumps to the start")
        window.makeFirstResponder(nil)
    }

    let mute = editor.view(identifier: "video.mute") as? NSButton, volume = editor.view(identifier: "video.volume") as? NSSlider
    check(mute?.isEnabled == false && volume?.isHidden == true && mute?.toolTip == "This recording has no sound",
          "a recording without sound shows the speaker off, says why, and hides the level slider")
    let live = PlayerFrames(url: video)
    await live.load()
    live.volume = 0.4
    check(!live.hasAudio && live.player.volume == 0.4, "the live decoder reports no sound in the fixture and passes the volume to its player")
    let loud = StillFrames(url: video, hasAudio: true)
    let withSound = VideoEditorWindowController(folder: folder, project: project, frames: loud, clock: { clock.now })
    await withSound.ready()
    withSound.tick()
    let loudMute = withSound.view(identifier: "video.mute") as? NSButton, loudVolume = withSound.view(identifier: "video.volume") as? NSSlider
    check(loudMute?.isEnabled == true && loudVolume?.isHidden == false && loudVolume?.isEnabled == true, "with sound the volume controls are on")
    loudVolume?.doubleValue = 0.3
    loudVolume.map(fire)
    check(abs(loud.volume - 0.3) < 0.001, "the slider sets the playback volume", detail: "\(loud.volume)")
    loudMute?.performClick(nil)
    check(loud.volume == 0 && withSound.state.isMuted && (withSound.view(identifier: "video.unmute") as? NSButton)?.isHidden == false, "Mute silences it and offers Unmute")
    (withSound.view(identifier: "video.unmute") as? NSButton)?.performClick(nil)
    check(abs(loud.volume - 0.3) < 0.001 && !withSound.state.isMuted, "Unmute restores the level")
    withSound.window?.close()

    section("video editor: full screen preview")
    let full = editor.view(identifier: "video.fullscreen") as? NSButton
    let preview = editor.view(identifier: "video.preview")
    full?.performClick(nil)
    window.contentView?.layoutSubtreeIfNeeded()
    let fp = frameInWindow(preview)
    check(editor.state.isPreviewOnly && editor.view(identifier: "video.timeline")?.isHidden == true && editor.view(identifier: "video.rail")?.superview?.isHidden == true,
          "Full Screen Preview hides the settings and the timeline")
    check(fp.minX == 0 && fp.width == window.contentView!.bounds.width && fp.maxY == window.contentView!.bounds.height, "the preview fills the window", detail: "\(fp)")
    check((editor.view(identifier: "video.exitFullscreen") as? NSButton)?.isHidden == false && full?.isHidden == true, "the button turns into Exit Full Screen Preview")
    check(window.appearance?.name == .darkAqua, "full screen preview is dark, like the capture overlay")
    Synth.key(window, 49, " ")
    check(editor.state.transport.isPlaying, "Space still plays in full screen")
    Synth.key(window, 49, " ")
    Synth.key(window, 53, "\u{1b}")
    window.contentView?.layoutSubtreeIfNeeded()
    check(!editor.state.isPreviewOnly && editor.view(identifier: "video.timeline")?.isHidden == false && frameInWindow(preview).minX > 0 && window.appearance == nil,
          "Escape brings the editor back in the system appearance")
    check(nothingOnScreen(), "full screen preview put nothing on screen in the harness")
}

@MainActor
private func checkVideoEditorSaving(_ w: World, folder: URL, videoHash: String) async throws {
    section("video editor: edits and the project file")
    guard let editor = w.coordinator.openVideoEditor(folder) else { return check(false, "the editor opens") }
    let project = editor.state.project
    let show = editor.view(identifier: "video.cursor.show") as? NSButton
    let size = editor.view(identifier: "video.cursor.size") as? NSSlider
    show?.performClick(nil)
    check(editor.state.project.edits.cursor.isVisible == !project.edits.cursor.isVisible && size?.isEnabled == editor.state.project.edits.cursor.isVisible,
          "Show cursor changes the project and the size follows it")
    editor.tick()
    check(editor.previewState == frameState(editor.state.project, outputTime: 0), "the preview redraws through frameState with the new setting")
    if !editor.state.project.edits.cursor.isVisible { show?.performClick(nil) }
    size?.doubleValue = 2.5
    size.map(fire)
    editor.tick()
    check(editor.state.project.edits.cursor.scale == 2.5 && (editor.previewState?.cursor?.scale ?? 2.5) == 2.5, "Size scales the pointer in the preview")
    w.coordinator.closeAllEditors()
    let stored = try RecordingProjectFile.read(from: folder)
    check(stored.edits.cursor.scale == 2.5 && stored.events == project.events && stored.source == project.source, "closing writes the edits to project.json and keeps the rest")
    check(sha256OrUnreadable(folder.appendingPathComponent(RecordingProjectFile.videoName)) == videoHash, "the source video is unchanged", detail: videoHash)
    check(Set(try FileManager.default.contentsOfDirectory(atPath: folder.path)) == [RecordingProjectFile.videoName, RecordingProjectFile.projectName],
          "the folder still holds only screen.mp4 and project.json")
    guard let again = w.coordinator.openVideoEditor(folder) else { return check(false, "the editor reopens") }
    check(again.state.project.edits.cursor.scale == 2.5, "reopening shows the saved edit")
    w.coordinator.closeAllEditors()
    check(try RecordingProjectFile.read(from: folder) == stored, "closing without a change leaves the file alone")
}

@MainActor
private func checkVideoEditorCursor(_ w: World, folder: URL) async throws {
    section("video editor: cursor size, style, motion and hiding")
    guard let editor = w.coordinator.openVideoEditor(folder), let window = editor.window, let content = window.contentView else {
        return check(false, "the editor opens")
    }
    window.setContentSize(window.minSize)
    content.layoutSubtreeIfNeeded()
    let before = editor.state.project.edits
    let show = editor.view(identifier: "video.cursor.show") as? NSButton
    let size = editor.view(identifier: "video.cursor.size") as? NSSlider
    let style = editor.view(identifier: "video.cursor.style") as? Segments
    let motion = editor.view(identifier: "video.cursor.motion") as? Segments
    let idle = editor.view(identifier: "video.cursor.hideIdle") as? NSButton
    let typing = editor.view(identifier: "video.cursor.hideTyping") as? NSButton
    let panel = frameInWindow(editor.view(identifier: "video.panel"))
    let controls: [NSView?] = [show, size, style, motion, idle, typing]
    check(controls.allSatisfy { $0 != nil && panel.contains(frameInWindow($0)) },
          "at the smallest window the panel holds Show cursor, Size, Style, Motion and both hiding options inside its edges",
          detail: controls.map { "\(frameInWindow($0))" }.joined(separator: " "))
    let rows = controls.map { frameInWindow($0) }
    check(zip(rows, rows.dropFirst()).allSatisfy { $0.minY >= $1.maxY }, "the settings stack top to bottom without overlapping")
    check((0..<3).map { style?.label(forSegment: $0) } == ["White", "Black", "Dot"] && style?.toolTip(forSegment: 2) == "Translucent dot",
          "Style offers White, Black and Dot, each named in its tooltip")
    check((0..<2).map { motion?.label(forSegment: $0) } == ["Natural", "Smooth"], "Motion offers Natural and Smooth")
    check(style?.selectedSegment == 0 && motion?.selectedSegment == 0 && idle?.state == .off && typing?.state == .off,
          "a new project draws the white arrow along the recorded path and never hides it")

    func at(_ t: Double) -> FrameState? {
        editor.seek(to: t)
        return editor.previewState
    }
    style?.selectedSegment = 2
    style.map(fire)
    check(editor.state.project.edits.cursor.style == .dot && at(0.5)?.cursor?.style == .dot, "Dot draws the dot in the preview")
    motion?.selectedSegment = 1
    motion.map(fire)
    let smooth = editor.state.project
    check(smooth.edits.cursor.motion == .smooth && at(1.1) == frameState(smooth, outputTime: 1.1), "Smooth redraws the preview through frameState")
    var natural = smooth
    natural.edits.cursor.motion = .natural
    let lag = hypot((frameState(smooth, outputTime: 1.1).cursor?.x ?? 0) - (frameState(natural, outputTime: 1.1).cursor?.x ?? 0),
                    (frameState(smooth, outputTime: 1.1).cursor?.y ?? 0) - (frameState(natural, outputTime: 1.1).cursor?.y ?? 0))
    check(lag > 1, "on a moving stretch the smooth pointer trails the recorded one", detail: String(format: "%.1f pt", lag))
    idle?.performClick(nil)
    typing?.performClick(nil)
    check(editor.state.project.edits.cursor.hidesWhenIdle && editor.state.project.edits.cursor.hidesWhenTyping, "both hiding options are on")
    show?.performClick(nil)
    check(!editor.state.project.edits.cursor.isVisible && [size, style, motion, idle, typing].allSatisfy { ($0 as? NSControl)?.isEnabled == false },
          "with Show cursor off the other settings are off too")
    show?.performClick(nil)

    let steps = editor.state.project.edits
    for v in [1.5, 2.0, 2.5] {
        size?.doubleValue = v
        size.map(fire)
    }
    check(editor.state.project.edits.cursor.scale == 2.5 && at(0.5)?.cursor?.scale == 2.5, "the preview follows the size as it changes")
    Synth.key(window, 6, "z", modifiers: .command)
    check(editor.state.project.edits == steps && size?.doubleValue == steps.cursor.scale, "Command-Z takes back a run of size changes in one step")
    Synth.key(window, 6, "z", modifiers: .command)
    check(editor.state.project.edits.cursor.isVisible == false, "Command-Z again brings back the step before it")
    Synth.key(window, 6, "Z", modifiers: [.command, .shift])
    Synth.key(window, 6, "Z", modifiers: [.command, .shift])
    check(editor.state.project.edits.cursor.scale == 2.5 && style?.selectedSegment == 2 && motion?.selectedSegment == 1,
          "Shift-Command-Z redoes both and the panel shows them")
    for _ in 0..<12 { Synth.key(window, 6, "z", modifiers: .command) }
    check(editor.state.project.edits == before && !editor.canUndo && editor.canRedo, "undoing every step returns to the project as it opened")
    let undoItem = NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
    check((window as? VideoEditorWindow)?.validateMenuItem(undoItem) == false, "the Edit menu's Undo is off with nothing to undo")
    for _ in 0..<12 { Synth.key(window, 6, "Z", modifiers: [.command, .shift]) }
    check(editor.state.project.edits.cursor == CursorSettings(scale: 2.5, style: .dot, motion: .smooth, hidesWhenIdle: true, hidesWhenTyping: true),
          "redoing every step returns to the last choice", detail: "\(editor.state.project.edits.cursor)")

    window.setContentSize(NSSize(width: 1200, height: 760))
    content.layoutSubtreeIfNeeded()
    _ = await waitUntil(3) { editor.tick(); return editor.previewImage != nil }
    snapshotEditor(editor, name: "video-editor-cursor")
    snapshotEditor(editor, name: "video-editor-cursor-dark", dark: true)
    window.appearance = nil
    w.coordinator.closeAllEditors()
    let stored = try RecordingProjectFile.read(from: folder)
    check(stored.edits.cursor == CursorSettings(scale: 2.5, style: .dot, motion: .smooth, hidesWhenIdle: true, hidesWhenTyping: true),
          "closing writes style, motion and both hiding options to project.json")
}

/// The live path: the player decodes in real time and a 60 Hz tick draws each frame into the preview.
@MainActor
private func checkVideoEditorPerformance(folder: URL) async throws {
    section("video editor: preview frame time")
    let project = try RecordingProjectFile.read(from: folder)
    let live = PlayerFrames(url: folder.appendingPathComponent(project.source.video))
    let editor = VideoEditorWindowController(folder: folder, project: project, frames: live)
    defer { editor.window?.close() }
    guard let window = editor.window, let preview = editor.view(identifier: "video.preview") else { return check(false, "an editor") }
    window.setContentSize(NSSize(width: 1200, height: 760))
    window.contentView?.layoutSubtreeIfNeeded()
    await editor.ready()
    var costs: [Double] = []
    var shown = 0
    var lastImage: CGImage?
    var intervals: [Double] = []
    editor.togglePlayback()
    let begin = CACurrentMediaTime()
    var last = begin
    while CACurrentMediaTime() - begin < 1.8 {
        try? await Task.sleep(nanoseconds: 16_666_667)
        let t0 = CACurrentMediaTime()
        intervals.append(t0 - last)
        last = t0
        editor.tick()
        // Commits the layer change now, so handing the frame to Core Animation is inside the measured time.
        CATransaction.flush()
        costs.append((CACurrentMediaTime() - t0) * 1000)
        if let image = editor.previewImage, image !== lastImage { shown += 1; lastImage = image }
    }
    editor.togglePlayback()
    let sorted = costs.sorted()
    let median = sorted[sorted.count / 2], p95 = sorted[Int(Double(sorted.count - 1) * 0.95)], worst = sorted.last ?? 0
    let tick = intervals.dropFirst().sorted()
    let ticks = Double(costs.count) / 1.8
    print(String(format: "PERF preview frame cost ms median=%.2f p95=%.2f max=%.2f ticks=%d (%.1f/s, interval median %.1f ms) distinct frames=%d source fps=%d player syncs=%d preview %@",
                 median, p95, worst, costs.count, ticks, (tick.isEmpty ? 0 : tick[tick.count / 2]) * 1000, shown, editor.state.project.source.fps, live.syncs,
                 "\(Int(preview.bounds.width))x\(Int(preview.bounds.height)) pt"))
    check(p95 < 1000.0 / 60, "95% of preview frames cost under one 60 Hz frame (16.7 ms)", detail: String(format: "p95 %.2f ms", p95))
    check(Double(shown) > Double(costs.count) * 0.9, "nearly every tick shows a new source frame", detail: "\(shown) new frames in \(costs.count) ticks")
    check(nothingOnScreen(), "measuring put nothing on screen")
}
