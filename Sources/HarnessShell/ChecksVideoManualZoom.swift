import AppKit
import CornermarkCapture
import CornermarkCore
import CornermarkDesign
@testable import CornermarkVideoEditor
@testable import CornermarkShell

/// Pointer input for the zoom target, at fractions of its picture from the top-left corner.
@MainActor
struct TargetHand {
    let view: ZoomTargetView

    func point(_ x: Double, _ y: Double) -> CGPoint {
        let p = view.pictureRect
        return view.convert(CGPoint(x: p.minX + p.width * x, y: p.minY + p.height * y), to: nil)
    }

    func event(_ type: NSEvent.EventType, _ x: Double, _ y: Double) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: point(x, y), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: view.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    /// `step` runs after each move, so a film can draw the drag.
    func drag(from a: (Double, Double), to b: (Double, Double), steps: Int = 12, step: () async -> Void = {}) async {
        view.mouseDown(with: event(.leftMouseDown, a.0, a.1))
        for i in 1...steps {
            let k = Double(i) / Double(steps)
            view.mouseDragged(with: event(.leftMouseDragged, a.0 + (b.0 - a.0) * k, a.1 + (b.1 - a.1) * k))
            await step()
        }
        view.mouseUp(with: event(.leftMouseUp, b.0, b.1))
    }

    func click(_ x: Double, _ y: Double) {
        view.mouseDown(with: event(.leftMouseDown, x, y))
        view.mouseUp(with: event(.leftMouseUp, x, y))
    }
}

@MainActor
func checkVideoManualZoom() async throws {
    section("video editor: a manual zoom's target")
    let (w, _) = try recordingWorld(frames: 480)
    defer { w.cleanup() }
    w.env.pointerSource = { ScriptedPointerSource(pacing: .fixed(origin: 0, count: 480)) }
    let clock = ScriptedClock()
    var decoder: StillFrames?
    w.coordinator.makeVideoEditor = { folder in
        let project = try RecordingProjectFile.read(from: folder)
        let d = StillFrames(url: folder.appendingPathComponent(project.source.video))
        decoder = d
        return VideoEditorWindowController(folder: folder, project: project, frames: d, clock: { clock.now })
    }
    guard let recorded = await recordOnce(w, "display=1&x=0&y=0&width=640&height=360"), let folder = recorded.video?.location else {
        return check(false, "a project is recorded")
    }
    var plain = try RecordingProjectFile.read(from: folder)
    plain.edits.motionBlur.scope = .off
    try RecordingProjectFile.write(plain, to: folder)
    guard let editor = w.coordinator.openVideoEditor(folder), let window = editor.window, let content = window.contentView,
          let target = editor.view(identifier: "video.zoom.target") as? ZoomTargetView,
          let mode = editor.view(identifier: "video.zoom.mode") as? NSPopUpButton,
          let settingsButton = editor.view(identifier: "video.zoom.animationSettings") as? NSButton else {
        return check(false, "the project opens with a zoom target and an Animation Settings button")
    }
    defer { w.coordinator.closeAllEditors() }
    window.setContentSize(NSSize(width: 1200, height: 760))
    content.layoutSubtreeIfNeeded()
    await editor.ready()
    let hand = TargetHand(view: target)
    guard let id = editor.addZoom(from: 1, to: 4)?.id else { return check(false, "a zoom is added") }
    editor.setZoomScale(2, of: id)
    let picked = { editor.state.project.edits.zooms.first { $0.id == id } }
    content.layoutSubtreeIfNeeded()
    check(target.isHiddenOrHasHiddenAncestor && !settingsButton.isHiddenOrHasHiddenAncestor,
          "a Follow Cursor zoom shows Animation Settings but no target, since it aims at the pointer")
    mode.selectItem(at: 1)
    fire(mode)
    content.layoutSubtreeIfNeeded()
    let note = (editor.view(identifier: "video.zoom.modeNote") as? NSTextField)?.stringValue
    check(picked()?.mode == .manual && !target.isHiddenOrHasHiddenAncestor, "choosing Manual shows the target")
    check(note == ZoomPanel.modeNote(.manual) && note?.contains("Drag the frame") == true, "the note says how to pick the spot", detail: note ?? "nil")
    await editor.zoomTargetSettled()
    let mid = frameState(editor.state.project, outputTime: 2.5).sourceTime
    check(target.picture != nil && (target.picture?.width ?? 0) >= 400, "the target shows the recording at the zoom's middle, sharp enough for the panel",
          detail: "\(target.picture?.width ?? 0)x\(target.picture?.height ?? 0) at \(String(format: "%.3f", mid)) s")
    let aspect = target.pictureRect.width / max(target.pictureRect.height, 1)
    check(abs(aspect - 16.0 / 9) < 0.03 && target.pictureRect.width >= SettingsPanel.inner - 1, "the picture keeps the recording's shape across the panel",
          detail: "\(target.pictureRect)")
    let before = picked()?.center ?? .middle
    let shown = picked().map { ZoomCamera.target($0) } ?? .full
    await hand.drag(from: (shown.x + shown.width / 2, shown.y + shown.height / 2), to: (0.3, 0.32))
    let dragged = picked()?.center ?? .middle
    check(abs(dragged.x - 0.3) < 0.01 && abs(dragged.y - 0.32) < 0.01, "dragging the frame moves the zoom's centre with it",
          detail: String(format: "%.3f, %.3f", dragged.x, dragged.y))
    editor.undo()
    check(picked()?.center == before, "one drag is one undo step", detail: "\(String(describing: picked()?.center))")
    editor.redo()
    editor.seek(to: 2.5)
    await decoder?.prepare(frameState(editor.state.project, outputTime: 2.5).sourceTime)
    editor.tick()
    let crop = editor.previewState?.crop
    check(crop.map { abs($0.x - (dragged.x - 0.25)) < 1e-9 && abs($0.y - (dragged.y - 0.25)) < 1e-9 && $0.width == 0.5 } == true,
          "the preview shows the view the frame marks", detail: "\(String(describing: crop))")
    await hand.drag(from: (0.3, 0.32), to: (0.02, 0.98))
    check(picked()?.center == ZoomPoint(x: 0.25, y: 0.75), "dragged past a corner, the frame stops at the picture's edge",
          detail: "\(String(describing: picked()?.center))")
    hand.click(0.7, 0.4)
    check(picked().map { abs($0.center.x - 0.7) < 0.01 && abs($0.center.y - 0.4) < 0.01 } == true, "a click outside the frame puts its centre there",
          detail: "\(String(describing: picked()?.center))")
    check(window.firstResponder === target, "clicking the target gives it keyboard focus")
    let clicked = picked()?.center
    func arrow(_ code: UInt16, _ mods: NSEvent.ModifierFlags = []) { target.keyDown(with: Synth.keyEvent(window, code, "", modifiers: mods)) }
    for _ in 0..<3 { arrow(124) }
    arrow(125, .shift)
    check(picked().map { abs($0.center.x - 0.73) < 1e-9 && abs($0.center.y - 0.5) < 1e-9 } == true,
          "Right moves it a hundredth of the picture and Shift-Down a tenth", detail: "\(String(describing: picked()?.center))")
    for _ in 0..<5 { arrow(124, .shift) }
    check(picked()?.center.x == 0.75, "the keys stop at the picture's edge too", detail: "\(String(describing: picked()?.center))")
    let spoken = target.accessibilityValue() as? String
    check(spoken?.contains("75% across") == true, "VoiceOver hears where the frame is", detail: spoken ?? "nil")
    Synth.key(window, 6, "z", modifiers: .command)
    check(picked()?.center == clicked, "Command-Z takes the whole run of arrow presses back in one step", detail: "\(String(describing: picked()?.center))")
    editor.setZoomCenter(ZoomPoint(x: 0.36, y: 0.4), of: id)
    content.layoutSubtreeIfNeeded()
    snapshotEditor(editor, name: "video-zoom-manual")
    snapshotEditor(editor, name: "video-zoom-manual-dark", dark: true)
    window.appearance = nil
    window.setFrame(NSRect(origin: window.frame.origin, size: window.minSize), display: false)
    content.layoutSubtreeIfNeeded()
    let remove = frameInWindow(editor.view(identifier: "video.zoom.remove")), column = frameInWindow(editor.view(identifier: "video.panel"))
    check(remove.minY >= column.minY && target.bounds.height >= ZoomTargetView.minHeight && target.pictureRect.width / max(target.pictureRect.height, 1) > 1.7,
          "in the smallest window the picture gives up height and every control stays in the column",
          detail: "remove \(remove) column \(column) picture \(target.pictureRect)")
    snapshotEditor(editor, name: "video-zoom-manual-min")
    window.setContentSize(NSSize(width: 1200, height: 760))
    content.layoutSubtreeIfNeeded()

    section("video editor: animation settings")
    check(settingsButton.title == "Animation Settings", "the zoom panel has an Animation Settings button", detail: settingsButton.title)
    settingsButton.performClick(nil)
    let panel = editor.view(identifier: "video.zoomAnimation.panel")
    let duration = editor.view(identifier: "video.zoomAnimation.duration") as? TrackingSlider
    let hold = editor.view(identifier: "video.zoomAnimation.holdArea") as? TrackingSlider
    let catchUp = editor.view(identifier: "video.zoomAnimation.catchUp") as? TrackingSlider
    let reset = editor.view(identifier: "video.zoomAnimation.reset") as? NSButton
    func readout(_ slider: NSSlider?) -> String? { (slider?.superview as? NSStackView)?.arrangedSubviews.compactMap { $0 as? NSTextField }.last?.stringValue }
    check(editor.state.showsZoomAnimation && panel?.isHidden == false && window.firstResponder === duration, "the button opens the panel with focus on its first slider")
    check(readout(duration) == "0.78 s" && readout(hold) == "50%" && readout(catchUp) == "0.68 s" && reset?.isEnabled == false,
          "the panel opens on the defaults: 0.78 s moves, a 50% hold area and a 0.68 s catch-up", detail: [duration, hold, catchUp].map { readout($0) ?? "nil" }.joined(separator: " "))
    if let f = panel.map({ $0.convert($0.bounds.insetBy(dx: ZoomAnimationPanel.inset, dy: ZoomAnimationPanel.inset), to: nil) }),
       let preview = editor.view(identifier: "video.preview") {
        let stage = preview.convert(preview.bounds, to: nil), button = settingsButton.convert(settingsButton.bounds, to: nil)
        let timeline = frameInWindow(editor.view(identifier: "video.timeline"))
        check(f.maxX <= stage.minX && f.minX > 0 && f.minY >= timeline.maxY && f.maxY >= button.maxY - 1,
              "it floats over the settings column, at or above its button, leaving the preview and the timeline uncovered",
              detail: "\(f) button \(button) preview \(stage) timeline \(timeline)")
    }
    for v in [0.9, 1.05, 1.2] {
        duration?.doubleValue = v
        if let duration { fire(duration) }
    }
    duration?.onTrackingEnd()
    check(editor.state.project.edits.zoomAnimation.duration == 1.2 && readout(duration) == "1.20 s", "the duration slider sets the move's length")
    editor.undo()
    check(editor.state.project.edits.zoomAnimation.duration == 0.78, "one slider drag is one undo step")
    editor.redo()
    hold?.doubleValue = 0.31
    if let hold { fire(hold) }
    hold?.onTrackingEnd()
    catchUp?.doubleValue = 0.4
    if let catchUp { fire(catchUp) }
    catchUp?.onTrackingEnd()
    let set = editor.state.project.edits.zoomAnimation
    check(set.deadZone == 0.3 && abs(set.settleTime - 0.4) < 1e-9 && readout(hold) == "30%" && readout(catchUp) == "0.40 s",
          "the hold area moves in steps of 5% and catch-up in hundredths of a second", detail: "\(set)")
    check(reset?.isEnabled == true, "Reset to Defaults turns on once a value differs")
    snapshotEditor(editor, name: "video-zoom-animation")
    snapshotEditor(editor, name: "video-zoom-animation-dark", dark: true)
    window.appearance = nil
    Synth.key(window, 53, "\u{1b}")
    check(!editor.state.showsZoomAnimation && panel?.isHidden == true && window.firstResponder === settingsButton,
          "Esc closes the panel and returns focus to its button", detail: "open=\(editor.state.showsZoomAnimation) hidden=\(String(describing: panel?.isHidden)) focus=\(String(describing: window.firstResponder))")
    check(editor.state.selectedZoom == id, "the zoom stays picked after Esc closed the panel")
    let lane = editor.view(identifier: "video.zoomLane") as? ZoomLaneView
    let menu = lane.map { ZoomHand(lane: $0) }.flatMap { $0.menu(x: $0.x(2.5)) }
    check(menu?.pick("Animation Settings\u{2026}") == true && editor.state.showsZoomAnimation, "the zoom's menu opens Animation Settings too")
    reset?.performClick(nil)
    check(editor.state.project.edits.zoomAnimation == ZoomAnimation() && reset?.isEnabled == false, "Reset to Defaults puts every value back")
    editor.undo()
    check(editor.state.project.edits.zoomAnimation == set, "and Command-Z brings the chosen values back")
    editor.selectZoom(nil)
    check(!editor.state.showsZoomAnimation, "letting go of the zoom closes the panel with it")
    editor.selectZoom(id)
    editor.openExport()
    editor.closeExport()
    editor.openZoomAnimation()
    editor.openExport()
    check(!editor.state.showsZoomAnimation && editor.state.export == .choosing, "opening Export closes Animation Settings, so one panel floats at a time")
    editor.closeExport()

    section("video export: a manual zoom with a longer move matches the preview")
    editor.removeAllZooms()
    guard let manual = editor.addZoom(from: 0.6, to: 3.4)?.id, let follow = editor.addZoom(from: 4, to: 7)?.id else { return check(false, "two zooms are added") }
    editor.setZoomScale(2.5, of: manual)
    editor.setZoomMode(.manual, of: manual)
    editor.setZoomCenter(ZoomPoint(x: 0.3, y: 0.35), of: manual)
    editor.setZoomScale(2, of: follow)
    editor.setZoomAnimation(ZoomAnimation(duration: 1.2, deadZone: 0.3, driftRate: 12))
    editor.selectZoom(nil)
    let project = editor.state.project
    check(frameState(project, outputTime: 0.6 + 0.78).crop.scale < 2.4 && abs(frameState(project, outputTime: 0.6 + 1.2).crop.scale - 2.5) < 1e-9,
          "with 1.2 s moves the camera is still on its way where a 0.78 s move would have arrived")
    let out = w.root.appendingPathComponent("zoomed-manual.mp4")
    let report = try await VideoExporter.export(project: project, video: editor.videoURL, settings: ExportSettings(), to: out)
    if let decoder {
        // Partway in, where the default would already hold, holding on the picked spot, partway out, and in the following zoom.
        let times = [60, 84, 108, 150, 192, 272, 330].map { Double($0) / 60 }
        let rows = await measureParity(editor, frames: decoder, clock: clock, export: out, plan: report.plan, project: project, times: times,
                                       name: "parity-zoom-manual")
        for r in rows {
            let c = frameState(project, outputTime: r.time).crop
            print(String(format: "PARITY manual zoom t=%.2f scale=%.3f centre=(%.3f,%.3f) duration=%.2f preview-vs-drawn %@ | preview-vs-file %@", r.time, c.scale,
                         c.x + c.width / 2, c.y + c.height / 2, project.edits.zoomAnimation.duration, r.drawn.description, r.encoded.description))
        }
        check(times.contains { (1.01...2.49).contains(frameState(project, outputTime: $0).crop.scale) && $0 > 0.6 + 0.78 },
              "a measured moment is mid-move after the default duration would have ended")
        check(rows.count == times.count && rows.allSatisfy { $0.drawn.mean < 0.5 && $0.drawn.over16 < 0.001 },
              "manual and changed-duration frames: the export draws what the preview shows, before compression", detail: rows.map { $0.drawn.description }.joined(separator: "; "))
        check(rows.count == times.count && rows.allSatisfy { $0.encoded.psnr > 35 }, "manual and changed-duration frames: the file matches the preview within compression loss",
              detail: rows.map { $0.encoded.description }.joined(separator: "; "))
    } else { check(false, "the harness decoder is known") }

    section("video editor: animation settings are saved")
    window.close()
    let stored = try RecordingProjectFile.read(from: folder)
    check(stored.edits.zoomAnimation == ZoomAnimation(duration: 1.2, deadZone: 0.3, driftRate: 12) && stored.edits.zooms.first?.center == ZoomPoint(x: 0.3, y: 0.35),
          "closing the editor writes the animation settings and the picked centre to project.json", detail: "\(stored.edits.zoomAnimation)")
}
