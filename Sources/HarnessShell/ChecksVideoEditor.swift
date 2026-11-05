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

func sha256(_ url: URL) -> String {
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
    check(plainCard?.actions == [.copy, .play, .reveal, .close] && plainCard?.openAction == .play, "a plain video's card keeps Play", detail: "\(plainCard?.actions ?? [])")
    check(projectCard?.actions == [.copy, .edit, .reveal, .close] && projectCard?.openAction == .edit, "a project's card offers Edit", detail: "\(projectCard?.actions ?? [])")
    let videoHash = sha256(folder.appendingPathComponent(RecordingProjectFile.videoName))

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
    try await checkVideoEditorPerformance(folder: folder)
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
    let parts = ["video.start", "video.end", "video.time", "video.mute", "video.fullscreen"].map { frameInWindow(editor.view(identifier: $0)) }
    let row = frameInWindow(bar)
    let apart = parts[1].maxX <= parts[2].minX && parts[2].maxX <= parts[3].minX && parts.allSatisfy { row.contains($0) }
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
    check(sha256(folder.appendingPathComponent(RecordingProjectFile.videoName)) == videoHash, "the source video is unchanged", detail: videoHash)
    check(Set(try FileManager.default.contentsOfDirectory(atPath: folder.path)) == [RecordingProjectFile.videoName, RecordingProjectFile.projectName],
          "the folder still holds only screen.mp4 and project.json")
    guard let again = w.coordinator.openVideoEditor(folder) else { return check(false, "the editor reopens") }
    check(again.state.project.edits.cursor.scale == 2.5, "reopening shows the saved edit")
    w.coordinator.closeAllEditors()
    check(try RecordingProjectFile.read(from: folder) == stored, "closing without a change leaves the file alone")
}

/// The live path: the player decodes in real time and a 60 Hz tick draws each frame into the preview.
@MainActor
private func checkVideoEditorPerformance(folder: URL) async throws {
    section("video editor: preview frame time")
    let editor = try VideoEditorWindowController.open(folder: folder)
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
    print(String(format: "PERF preview frame cost ms median=%.2f p95=%.2f max=%.2f ticks=%d (%.1f/s, interval median %.1f ms) distinct frames=%d source fps=%d preview %@",
                 median, p95, worst, costs.count, ticks, (tick.isEmpty ? 0 : tick[tick.count / 2]) * 1000, shown, editor.state.project.source.fps,
                 "\(Int(preview.bounds.width))x\(Int(preview.bounds.height)) pt"))
    check(p95 < 1000.0 / 60, "95% of preview frames cost under one 60 Hz frame (16.7 ms)", detail: String(format: "p95 %.2f ms", p95))
    check(Double(shown) > Double(costs.count) * 0.9, "nearly every tick shows a new source frame", detail: "\(shown) new frames in \(costs.count) ticks")
    check(nothingOnScreen(), "measuring put nothing on screen")
}
