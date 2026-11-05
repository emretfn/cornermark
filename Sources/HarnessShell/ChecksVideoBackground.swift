import AppKit
import CornermarkCore
import CornermarkDesign
@testable import CornermarkVideoEditor
@testable import CornermarkShell

/// Writes a synthetic picture, bands of colour with a diagonal, for an added background.
func writeBackgroundPicture(to url: URL) throws {
    let ctx = Pix.context(320, 200)
    for (i, hue) in [0.08, 0.32, 0.55, 0.8].enumerated() {
        ctx.setFillColor(NSColor(calibratedHue: hue, saturation: 0.5, brightness: 0.85, alpha: 1).cgColor)
        ctx.fill(CGRect(x: i * 80, y: 0, width: 80, height: 200))
    }
    ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.8))
    ctx.setLineWidth(12)
    ctx.strokeLineSegments(between: [CGPoint(x: 0, y: 0), CGPoint(x: 320, y: 200)])
    guard let image = ctx.makeImage(), let png = AssetStore.pngData(from: image) else { throw CocoaError(.fileWriteUnknown) }
    try png.write(to: url)
}

/// H.264 sides are even, as `ExportPlan` rounds them.
private func even(_ value: Double) -> Int { max(2, Int((value / 2).rounded()) * 2) }

@MainActor
func visibleTiles(_ prefix: String, in editor: VideoEditorWindowController) -> [NSView] {
    func walk(_ v: NSView) -> [NSView] {
        let me = (v.accessibilityIdentifier().hasPrefix(prefix) && !v.isHiddenOrHasHiddenAncestor && v.window != nil) ? [v] : []
        return me + v.subviews.flatMap(walk)
    }
    return editor.window?.contentView.map(walk) ?? []
}

@MainActor
func checkVideoBackground(_ w: World, folder: URL) async throws {
    section("video editor: background")
    guard let editor = w.coordinator.openVideoEditor(folder), let window = editor.window, let content = window.contentView else {
        return check(false, "the editor opens")
    }
    defer { w.coordinator.closeAllEditors() }
    window.setContentSize(NSSize(width: 1200, height: 760))
    content.layoutSubtreeIfNeeded()
    await editor.ready()
    let project = editor.state.project
    let source = project.source
    (editor.view(identifier: "video.rail.background") as? NSButton)?.performClick(nil)
    content.layoutSubtreeIfNeeded()
    let panel = editor.view(identifier: "video.background")
    let note = editor.view(identifier: "video.panel.note")
    check(editor.state.section == .background && panel?.isHiddenOrHasHiddenAncestor == false && note?.isHidden == true,
          "Background shows its settings instead of a note")
    let none = editor.view(identifier: "video.background.none")
    check(project.edits.background.fill == .none && none?.accessibilityValue() as? Int == 1, "a recording starts with no background, and None says it is picked")
    let padding = editor.view(identifier: "video.background.padding") as? NSSlider
    let shadow = editor.view(identifier: "video.background.shadow") as? NSSlider
    let corners = editor.view(identifier: "video.background.corners") as? NSSlider
    let frameNote = editor.view(identifier: "video.background.note")
    check([padding, shadow, corners].allSatisfy { $0?.isEnabled == false } && frameNote?.isHidden == false,
          "without a background the frame sliders are off and the panel says why")
    check(ExportPlan(project: project, settings: ExportSettings()).width == source.pixelWidth, "without a background the video is the recording's own size")

    let inner = BackgroundPanel.inner
    let p = frameInWindow(panel)
    check(inner == InspectorView.panelWidth - 2 * DS.Space.s16 && visibleTiles("video.background.", in: editor).allSatisfy { frameInWindow($0).maxX <= p.minX + DS.Space.s16 + inner + 0.5 },
          "every tile and row ends on the panel's one right edge", detail: "inner=\(inner)")
    check(visibleTiles("video.background.gradient.", in: editor).count == BackgroundPanel.firstGradients, "two rows of gradients show at first",
          detail: "\(visibleTiles("video.background.gradient.", in: editor).count)")
    let more = editor.view(identifier: "video.background.more") as? Button
    more?.performClick(nil)
    content.layoutSubtreeIfNeeded()
    check(visibleTiles("video.background.gradient.", in: editor).count == BuiltinBackgrounds.all.count && more?.title == "Show less",
          "Show more shows all \(BuiltinBackgrounds.all.count) gradients and becomes Show less")
    snapshotEditor(editor, name: "video-background-more")
    more?.performClick(nil)
    content.layoutSubtreeIfNeeded()
    check(visibleTiles("video.background.gradient.", in: editor).count == BackgroundPanel.firstGradients && more?.title == "Show more", "Show less folds them back")
    editor.setBackground(VideoBackground(fill: .gradient(index: 17)))
    content.layoutSubtreeIfNeeded()
    check(editor.view(identifier: "video.background.gradient.17")?.isHiddenOrHasHiddenAncestor == false && more?.title == "Show less",
          "a gradient picked from the folded rows, here by the harness as undo would, opens them so its ring shows")
    editor.undo()
    more?.performClick(nil)
    content.layoutSubtreeIfNeeded()
    check(visibleTiles("video.background.wallpaper.", in: editor).count == VideoBackground.wallpapers.count && editor.view(identifier: "video.background.add")?.isHidden == false
          && editor.view(identifier: "video.background.image")?.isHiddenOrHasHiddenAncestor != false,
          "Wallpapers offer Add image and \(VideoBackground.wallpapers.count) wallpapers; no picture of your own yet",
          detail: "\(visibleTiles("video.background.wallpaper.", in: editor).count) \(String(describing: editor.view(identifier: "video.background.add")?.isHidden)) \(String(describing: editor.view(identifier: "video.background.image")?.isHiddenOrHasHiddenAncestor))")
    check(visibleTiles("video.background.color.", in: editor).count == BackgroundPanel.colors.count + 1, "Colour offers three colours and a custom colour")

    _ = click("video.background.gradient.3", in: content)
    editor.tick()
    var bg = editor.state.project.edits.background
    let pad = bg.padding
    let scale = Double(source.pixelWidth) / source.pointWidth
    var plan = ExportPlan(project: editor.state.project, settings: ExportSettings())
    check(bg.fill == .gradient(index: 3) && editor.view(identifier: "video.background.gradient.3")?.accessibilityValue() as? Int == 1 && none?.accessibilityValue() as? Int == 0,
          "a gradient tile picks that gradient and takes the ring from None")
    check(plan.width == even((source.pointWidth + 2 * pad) * scale) && plan.height == even((source.pointHeight + 2 * pad) * scale),
          "the video grows by the padding on every side", detail: "\(plan.width)x\(plan.height) pad=\(pad)")
    check([padding, shadow, corners].allSatisfy { $0?.isEnabled == true } && frameNote?.isHidden == true, "with a background the frame sliders work")

    for v in [100.0, 140.0] {
        padding?.doubleValue = v
        padding.map(fire)
    }
    shadow?.doubleValue = 80
    shadow.map(fire)
    (shadow as? TrackingSlider)?.onTrackingEnd()
    corners?.doubleValue = 24
    corners.map(fire)
    editor.tick()
    bg = editor.state.project.edits.background
    plan = ExportPlan(project: editor.state.project, settings: ExportSettings())
    check(bg.padding == 140 && bg.shadow == 80 && bg.cornerRadius == 24 && plan.width == even((source.pointWidth + 280) * scale),
          "Padding, Shadow and Corners change the background as they move", detail: "\(bg)")
    let readout = (padding?.superview as? NSStackView)?.arrangedSubviews.last as? NSTextField
    check(readout?.stringValue == "140", "the padding readout follows the slider", detail: readout?.stringValue ?? "nil")
    let exportPanel = editor.view(identifier: "video.export.resolution") as? NSPopUpButton
    check(exportPanel?.itemTitles.first == "\(plan.width) \u{00D7} \(plan.height) (Original)", "the export panel's sizes follow the background",
          detail: exportPanel?.itemTitles.first ?? "nil")
    snapshotEditor(editor, name: "video-background")
    snapshotEditor(editor, name: "video-background-dark", dark: true)
    window.appearance = nil

    editor.undo()
    check(editor.state.project.edits.background.cornerRadius == 12 && editor.state.project.edits.background.shadow == 80, "Undo takes back the corners")
    editor.undo()
    check(editor.state.project.edits.background.shadow == 50 && editor.state.project.edits.background.padding == 140, "then the shadow")
    editor.undo()
    check(editor.state.project.edits.background.padding == pad, "one drag of Padding is one undo step")
    _ = editor.handleKey(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                          characters: "z", charactersIgnoringModifiers: "z", isARepeat: false, keyCode: 6)!)
    check(editor.state.project.edits.background.fill == .none && padding?.isEnabled == false, "Command-Z takes back the gradient")
    for _ in 0..<4 { editor.redo() }
    check(editor.state.project.edits.background == bg, "redo brings every step back", detail: "\(editor.state.project.edits.background)")

    _ = click("video.background.wallpaper.\(VideoBackground.wallpapers[0])", in: content)
    check(editor.state.project.edits.background.fill == .wallpaper(index: VideoBackground.wallpapers[0]), "a wallpaper tile picks the wallpaper")
    _ = click("video.background.color.0", in: content)
    check(editor.state.project.edits.background.fill == .solid(color: BackgroundPanel.colors[0].color), "a colour tile picks a plain colour")

    let picked = w.root.appendingPathComponent("background-source.png")
    try writeBackgroundPicture(to: picked)
    var asked = 0
    editor.chooseImage = { _, done in asked += 1; done(picked) }
    _ = click("video.background.add", in: content)
    content.layoutSubtreeIfNeeded()
    bg = editor.state.project.edits.background
    let copy = bg.image.map { folder.appendingPathComponent($0) }
    check(asked == 1 && bg.fill == .image && copy.map { FileManager.default.contentsEqual(atPath: $0.path, andPath: picked.path) } == true,
          "Add image asks for a picture and copies it into the project folder", detail: bg.image ?? "nil")
    check(editor.view(identifier: "video.background.image")?.isHiddenOrHasHiddenAncestor == false
          && editor.view(identifier: "video.background.image")?.accessibilityValue() as? Int == 1, "your picture gets a tile of its own, picked")
    _ = click("video.background.gradient.0", in: content)
    check(editor.view(identifier: "video.background.image")?.isHiddenOrHasHiddenAncestor == false, "the picture's tile stays after another fill is picked")
    _ = click("video.background.image", in: content)
    check(editor.state.project.edits.background.fill == .image, "and picks the picture again")
    editor.chooseImage = { _, done in done(nil) }
    _ = click("video.background.add", in: content)
    check(editor.state.project.edits.background == bg, "cancelling Add image changes nothing")
    editor.chooseImage = { _, done in done(w.root.appendingPathComponent("missing.png")) }
    _ = click("video.background.add", in: content)
    let problem = editor.view(identifier: "video.background.problem") as? NSTextField
    check(editor.state.project.edits.background == bg && problem?.isHidden == false && problem?.stringValue == "missing.png could not be added. Choose another image.",
          "a picture that cannot be read changes nothing and the panel says so, without a sound", detail: problem?.stringValue ?? "nil")
    _ = click("video.background.gradient.1", in: content)
    _ = click("video.background.image", in: content)
    check(problem?.isHidden == true, "the next change clears the message")
    _ = await waitUntil(3) { editor.tick(); return editor.previewImage != nil }
    snapshotEditor(editor, name: "video-background-image")

    let stored = editor.state.project
    w.coordinator.closeAllEditors()
    check(try RecordingProjectFile.read(from: folder).edits.background == stored.edits.background, "closing writes the background to project.json")
    guard let again = w.coordinator.openVideoEditor(folder) else { return check(false, "the editor reopens") }
    again.setBackground(VideoBackground())
    w.coordinator.closeAllEditors()
}

/// Exports with a background and holds the file to the preview, frame by frame, the way the plain export is held.
@MainActor
func checkBackgroundParity(_ editor: VideoEditorWindowController, frames: StillFrames, clock: ScriptedClock, root: URL) async throws {
    let picture = root.appendingPathComponent("parity-background.png")
    try writeBackgroundPicture(to: picture)
    let cases: [(String, VideoBackground.Fill)] = [("gradient", .gradient(index: 6)), ("wallpaper", .wallpaper(index: VideoBackground.wallpapers[2])), ("image", .image)]
    for (name, fill) in cases {
        section("video export: the file matches the preview on a \(name) background")
        if fill == .image { try editor.useBackgroundImage(at: picture) }
        var bg = editor.state.project.edits.background
        bg.fill = fill
        bg.padding = 48; bg.shadow = 70; bg.cornerRadius = 20
        editor.setBackground(bg)
        let project = editor.state.project
        let out = root.appendingPathComponent("background-\(name).mp4")
        let report = try await VideoExporter.export(project: project, video: editor.videoURL, settings: ExportSettings(), to: out)
        let canvas = ExportPlan.canvasPixels(project)
        check(report.plan.width == even(canvas.width) && report.plan.height == even(canvas.height),
              "the file is the canvas's size", detail: "\(report.plan.width)x\(report.plan.height)")
        let rows = await measureParity(editor, frames: frames, clock: clock, export: out, plan: report.plan, project: project, times: [0.25, 1.0, 1.75], name: "parity-\(name)")
        for r in rows { print(String(format: "PARITY %@ t=%.2f preview-vs-drawn %@ | preview-vs-file %@", name, r.time, r.drawn.description, r.encoded.description)) }
        check(rows.count == 3 && rows.allSatisfy { $0.drawn.mean < 0.5 && $0.drawn.over16 < 0.001 },
              "the export draws what the preview shows, before compression", detail: rows.map { $0.drawn.description }.joined(separator: "; "))
        check(rows.count == 3 && rows.allSatisfy { $0.encoded.psnr > 35 }, "the file's frames match the preview within compression loss",
              detail: rows.map { $0.encoded.description }.joined(separator: "; "))
    }
    editor.setBackground(VideoBackground())
}
