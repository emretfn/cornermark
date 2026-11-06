import AppKit
import CornermarkCore
import CornermarkDesign
@testable import CornermarkVideoEditor
@testable import CornermarkShell

/// A synthetic project with two zooms and a moving pointer, so a frame export shows the crop, the pointer and the background together.
enum ShortcutScene {
    /// `pointerZoom` adds a third zoom over the pointer's sweep, which leaves no gap long enough for a new zoom.
    static func apply(_ project: inout RecordingProject, pointerZoom: Bool = true) {
        BlurScene.apply(&project)
        project.edits.motionBlur.scope = .off
        project.edits.background.fill = .gradient(index: 3)
        project.edits.background.padding = 48
        if pointerZoom { project.edits.zooms.append(Zoom(start: 5.6, end: 7.6, scale: 2, mode: .manual, center: ZoomPoint(x: 0.5, y: 0.7))) }
    }

    /// Where the pointer is drawn in the finished frame, as fractions of the canvas from the top-left.
    static func pointer(_ project: RecordingProject, _ state: FrameState) -> CGPoint? {
        guard let c = state.cursor else { return nil }
        let w = project.source.pointWidth, h = project.source.pointHeight, crop = state.crop, canvas = project.canvas
        let u = (c.x / w - crop.x) / crop.width, v = (c.y / h - crop.y) / crop.height
        return CGPoint(x: (canvas.frame.minX + u * canvas.frame.width) / canvas.size.width, y: (canvas.frame.minY + v * canvas.frame.height) / canvas.size.height)
    }
}

@MainActor
func checkVideoShortcuts() async throws {
    section("video editor: the shortcut list in Settings is the editor's table")
    let (w, _) = try recordingWorld(frames: 480)
    defer { w.cleanup() }
    let c = w.coordinator
    c.perform(.openSettings)
    guard let sw = c.settingsWindow, let pane = sw.panes.first(where: { $0 is ShortcutsPane }) else { return check(false, "the Shortcuts pane opens") }
    sw.select(pane: pane)
    var listed: [String: [String]] = [:]
    for command in EditorCommand.allCases {
        if let caps = findView("editorShortcut.\(command.rawValue)", in: pane.view) as? KeyCaps { listed[command.rawValue] = caps.keys }
    }
    let expected = Dictionary(uniqueKeysWithValues: EditorShortcuts.all.map { ($0.command.rawValue, $0.keys.map(\.display)) })
    check(listed == expected && listed.count == EditorCommand.allCases.count, "every editor command is listed once, with the keys the editor answers",
          detail: "\(listed.count) of \(EditorCommand.allCases.count)")
    let trim = findView("editorShortcut.trimEnd", in: pane.view)
    check(trim?.accessibilityLabel() == "Option Command Left Arrow, Option Command Right Arrow" && trim?.accessibilityRole() == .staticText,
          "VoiceOver hears each key in words", detail: trim?.accessibilityLabel() ?? "nil")
    let text = collectText(pane.view)
    check(EditorCommand.allCases.allSatisfy { text.contains($0.title) } && EditorCommand.Group.allCases.allSatisfy { text.contains($0.title) },
          "each command's name and each group's heading are on the pane")
    print("SHORTCUTS " + EditorShortcuts.all.map { "\($0.command.rawValue)=\($0.keyText)" }.joined(separator: " "))
    _ = snapshot(pane.view, name: "settings-editor-shortcuts", in: sw.window)
    _ = snapshot(pane.view, name: "settings-editor-shortcuts-dark", dark: true, in: sw.window)
    sw.window?.appearance = nil

    section("video editor: the menu's keys come from the same table")
    let menu = MainMenu.make(openVideo: #selector(NSObject.copy), target: NSObject())
    let items = menu.items.compactMap(\.submenu).flatMap(\.items)
    let byAction: [String: EditorCommand] = ["saveDocument:": .save, "saveDocumentAs:": .saveAs, "exportVideo:": .export, "exportCurrentFrame:": .exportFrame,
                                             "undo:": .undo, "redo:": .redo, "copy": .openVideo]
    var matched = 0
    for item in items {
        guard let action = item.action.map(NSStringFromSelector), let command = byAction[action] else { continue }
        let key = EditorShortcuts.shortcut(for: command).keys[0].menuKey
        check(item.keyEquivalent == key?.0 && item.keyEquivalentModifierMask == key?.1, "\(item.title) carries \(EditorShortcuts.shortcut(for: command).keyText)",
              detail: "\(item.keyEquivalent) \(item.keyEquivalentModifierMask.rawValue)")
        matched += 1
    }
    check(matched == byAction.count, "File has Export… and Export Current Frame as Image beside Open Video, Save and Save As", detail: "\(matched)")

    let clock = ScriptedClock()
    var decoder: StillFrames?
    c.makeVideoEditor = { folder in
        let project = try RecordingProjectFile.read(from: folder)
        let d = StillFrames(url: folder.appendingPathComponent(project.source.video))
        decoder = d
        return VideoEditorWindowController(folder: folder, project: project, frames: d, clock: { clock.now })
    }
    guard let recorded = await recordOnce(w, "display=1&x=0&y=0&width=640&height=360"), let folder = recorded.video?.location else {
        return check(false, "a project is recorded")
    }
    var scripted = try RecordingProjectFile.read(from: folder)
    ShortcutScene.apply(&scripted)
    try RecordingProjectFile.write(scripted, to: folder)
    guard let editor = c.openVideoEditor(folder), let window = editor.window, let content = window.contentView else { return check(false, "the project opens") }
    defer { c.closeAllEditors() }
    editor.chooseSaveLocation = { _, _, done in done(nil) }
    var saves = 0
    let onSave = editor.onSave
    editor.onSave = { saves += 1; onSave($0) }
    window.setContentSize(NSSize(width: 1200, height: 760))
    content.layoutSubtreeIfNeeded()
    await editor.ready()
    let beepsBefore = SilentNoResponder.count
    func press(_ command: EditorCommand, _ index: Int = 0, shift: Bool = false) {
        var chord = EditorShortcuts.shortcut(for: command).keys[index]
        if shift { chord.modifiers.insert(.shift) }
        Synth.key(window, chord.keyCode, "", modifiers: chord.eventFlags)
    }
    let zooms = { editor.state.project.edits.zooms.count }
    let clips = { editor.state.project.edits.clips.count }
    let time = { editor.state.transport.time(at: clock.now) }

    section("video export: Export Current Frame as Image")
    let project = editor.state.project
    let fps = Double(project.source.fps)
    let t = (BlurScene.fastestCrop(project, in: 1.0...1.8) * fps).rounded() / fps
    editor.seek(to: t)
    await decoder?.prepare(frameState(project, outputTime: t).sourceTime)
    editor.tick()
    let historyBefore = Set(w.env.store.list().map(\.id))
    let cardsBefore = c.overlay.stack.count
    press(.exportFrame)
    await editor.frameJob?.value
    let added = { w.env.store.list().filter { !historyBefore.contains($0.id) } }
    let listed2 = await waitUntil(5) { added().count == 1 }
    guard listed2, let record = added().first, record.video == nil,
          let stored = NSImage(contentsOf: w.env.store.paths(for: record).image)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        return check(false, "Shift-Command-E lists the frame in History as a picture", detail: "\(added().map { "\($0.kind) video=\($0.video != nil)" }) hud \(c.hud.lastMessage ?? "none")")
    }
    let plan = ExportPlan(project: project, settings: ExportSettings(resolution: .original))
    let imageFile = w.env.store.paths(for: record).image
    check(imageFile.pathExtension == "png" && stored.width == plan.width && stored.height == plan.height,
          "Shift-Command-E lists a PNG in History at the canvas size", detail: "\(imageFile.lastPathComponent) \(stored.width)x\(stored.height) plan \(plan.width)x\(plan.height)")
    check(c.overlay.stack.count == cardsBefore + 1 && c.overlay.stack.contains { $0.record.id == record.id }, "and shows its Quick Access card, like a screenshot")
    let pngURL = URL(fileURLWithPath: scratch + "frame-export.png")
    try? FileManager.default.removeItem(at: pngURL)
    try? FileManager.default.copyItem(at: imageFile, to: pngURL)
    let exported = w.root.appendingPathComponent("frame-parity.mp4")
    let report = try await VideoExporter.export(project: project, video: editor.videoURL, settings: ExportSettings(), to: exported)
    guard let file = await decodedFrame(exported, at: t), let diff = PixelDifference(stored, file, edge: 4) else {
        return check(false, "the export's frame at the same moment is read back")
    }
    if let png = AssetStore.pngData(from: file) { try? png.write(to: URL(fileURLWithPath: scratch + "frame-export-video.png")) }
    let state = frameState(project, outputTime: t)
    print(String(format: "FRAMEPARITY t=%.4f size=%dx%d zoom=%.2f cursor=%@ file=%dx%d %@", t, stored.width, stored.height, state.crop.scale,
                 state.cursor == nil ? "none" : "drawn", report.plan.width, report.plan.height, diff.description))
    check(diff.psnr > 40 && diff.over16 < 0.01, "the PNG matches the exported video's frame at that moment, up to H.264's loss", detail: diff.description)
    let renderer = ExportFrameRenderer(plan: report.plan, project: project, folder: editor.folder)
    if let source = await decodedFrame(editor.videoURL, at: state.sourceTime), let drawn = renderer.image(state, source: source),
       let before = PixelDifference(stored, drawn, edge: 0) {
        print("FRAMEPARITY png-vs-drawn \(before.description)")
        check(before.psnr > 45, "and the export's own drawing of that moment before encoding", detail: before.description)
    } else {
        check(false, "the export's drawing of that moment is made")
    }
    check(SilentNoResponder.count == beepsBefore, "Export Current Frame made no beep")

    section("video editor: every listed key does what the list says")
    press(.playPause)
    let playing = editor.state.transport.isPlaying
    press(.playPause)
    check(playing && !editor.state.transport.isPlaying, "Space plays, and again pauses")
    editor.removeAllZooms()
    editor.seek(to: 2)
    press(.addZoom)
    check(zooms() == 1 && editor.state.selectedZoom != nil, "Z adds a zoom at the playhead and picks it", detail: "\(zooms())")
    press(.duplicateZoom)
    check(zooms() == 2, "Command-D duplicates the picked zoom", detail: "\(zooms())")
    press(.delete)
    let afterDelete = zooms()
    editor.selectZoom(editor.state.project.edits.zooms.last?.id)
    press(.delete, 1)
    check(afterDelete == 1 && zooms() == 0, "Delete and Forward Delete remove the picked zoom", detail: "\(afterDelete) then \(zooms())")
    editor.seek(to: 4)
    press(.split)
    check(clips() == 2, "Command-B splits the clip at the playhead", detail: "\(clips())")
    press(.undo)
    let undone = clips()
    press(.redo)
    check(undone == 1 && clips() == 2, "Command-Z undoes and Shift-Command-Z redoes", detail: "\(undone) then \(clips())")
    editor.selectClip(0)
    press(.escape)
    check(editor.state.selectedClip == nil, "Esc lets go of the picked clip")
    press(.fullScreen)
    let full = editor.state.isPreviewOnly
    press(.escape)
    check(full && !editor.state.isPreviewOnly, "Control-Command-F opens Full Screen Preview and Esc leaves it")
    press(.save)
    check(saves == 1 && (editor.view(identifier: "video.document.status") as? NSTextField)?.stringValue == "Saved", "Command-S saves", detail: "\(saves)")
    press(.saveAs)
    check(editor.folder == folder, "Shift-Command-S asks where to save a copy; cancelled, the editor stays on the project")

    window.makeFirstResponder(editor.timeline)
    editor.seek(to: 2)
    let frame = 1 / Double(editor.state.project.source.fps)
    press(.step, 1)
    let stepped = time()
    press(.step, 0, shift: true)
    check(abs(stepped - 2 - frame) < 1e-6 && abs(time() - (1 + frame)) < 1e-6, "on the focused timeline, Right steps a frame and Shift-Left a second",
          detail: String(format: "%.4f then %.4f", stepped, time()))
    press(.jump, 1)
    let atEnd = time()
    press(.jump, 0)
    check(abs(atEnd - editor.state.transport.duration) < 1e-6 && time() == 0, "End and Home jump to the ends")
    editor.seek(to: 1)
    let before = editor.state.project.edits.clips
    press(.trimStart, 1)
    press(.trimEnd, 0, shift: true)
    let after = editor.state.project.edits.clips
    check(abs(after[0].start - before[0].start - frame) < 1e-6 && abs(after[0].end - (before[0].end - 1)) < 1e-6,
          "Option-Right trims the start of the clip under the playhead by a frame and Shift-Option-Command-Left its end by a second", detail: "\(before) -> \(after)")
    guard let lane = editor.view(identifier: "video.zoomLane") as? ZoomLaneView else { return check(false, "the zoom lane is there") }
    editor.seek(to: 5)
    press(.addZoom)
    window.makeFirstResponder(lane)
    editor.selectZoom(nil)
    press(.pickZoom, 1)
    let picked = editor.state.selectedZoom
    let start = editor.state.project.edits.zooms.first { $0.id == picked }?.start ?? -1
    press(.moveZoom, 0)
    press(.resizeZoom, 0, shift: true)
    let moved = editor.state.project.edits.zooms.first { $0.id == picked }
    check(picked != nil && abs((moved?.start ?? 0) - (start - 0.1)) < 1e-6, "on the focused zoom lane, Right picks a zoom and Option-Left moves it 0.1 s earlier",
          detail: "\(start) -> \(moved?.start ?? -1)")
    check(moved.map { abs($0.end - $0.start - 1) < 1e-6 } ?? false, "Shift-Option-Command-Left pulls its end in a second", detail: "\(String(describing: moved))")
    window.makeFirstResponder(nil)
    press(.export)
    check(editor.state.export == .choosing, "Command-E opens the export panel")
    editor.closeExport()
    check(SilentNoResponder.count == beepsBefore, "no listed key fell through to a beep", detail: SilentNoResponder.selectors.joined(separator: " "))
    let unlisted = Synth.keyEvent(window, 15, "r", modifiers: .command)
    check(!editor.handleKey(unlisted), "a key the table does not list is not the editor's")
}
