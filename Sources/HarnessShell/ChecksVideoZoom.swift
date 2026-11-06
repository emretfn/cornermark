import AppKit
import CornermarkCapture
import CornermarkCore
import CornermarkDesign
@testable import CornermarkVideoEditor
@testable import CornermarkShell

/// Pointer input for the zoom lane, sent to the lane's own handlers at moments of the timeline.
@MainActor
struct ZoomHand {
    let lane: ZoomLaneView

    func x(_ t: Double) -> CGFloat { CGFloat(lane.scale.x(t)) }

    func event(_ type: NSEvent.EventType, x: CGFloat) -> NSEvent {
        let p = lane.convert(CGPoint(x: x, y: lane.bounds.midY), to: nil)
        return NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                  windowNumber: lane.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    func hover(x: CGFloat) { lane.mouseMoved(with: event(.mouseMoved, x: x)) }

    func click(x: CGFloat) {
        lane.mouseDown(with: event(.leftMouseDown, x: x))
        lane.mouseUp(with: event(.leftMouseUp, x: x))
    }

    /// `step` runs after each move, so a film can draw the drag.
    func drag(from a: CGFloat, to b: CGFloat, steps: Int = 12, step: () async -> Void = {}) async {
        lane.mouseDown(with: event(.leftMouseDown, x: a))
        for i in 1...steps {
            let k = CGFloat(i) / CGFloat(steps)
            lane.mouseDragged(with: event(.leftMouseDragged, x: a + (b - a) * k))
            await step()
        }
        lane.mouseUp(with: event(.leftMouseUp, x: b))
    }

    func menu(x: CGFloat) -> NSMenu? { lane.menu(for: event(.rightMouseDown, x: x)) }

    /// The edge of `zoom` the lane resizes from, a point inside the block.
    func edge(_ zoom: Zoom, _ edge: ZoomLane.Edge) -> CGFloat {
        let r = lane.rect(of: zoom)
        return edge == .start ? r.minX + 2 : r.maxX - 2
    }
}

extension NSMenu {
    func pick(_ path: String...) -> Bool {
        var menu: NSMenu? = self
        for (i, title) in path.enumerated() {
            guard let item = menu?.items.first(where: { $0.title == title }), item.isEnabled else { return false }
            if i == path.count - 1 {
                guard let action = item.action else { return false }
                return NSApp.sendAction(action, to: item.target, from: item)
            }
            menu = item.submenu
        }
        return false
    }
}

@MainActor
func checkVideoZoom() async throws {
    section("video editor: zooms on the timeline")
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
    // The recording has no typing of its own. Command keys at known moments give the combined case a badge to place; they stay hidden
    // (Show keystrokes is off) until that case turns them on.
    var typed = try RecordingProjectFile.read(from: folder)
    typed.events.keys = [KeyEvent(t: 0.3, label: "\u{2318}K", isCommand: true), KeyEvent(t: 1.2, label: "\u{2318}J", isCommand: true),
                         KeyEvent(t: 1.9, label: "\u{2318}H", isCommand: true), KeyEvent(t: 5.5, label: "\u{2318}G", isCommand: true)]
    typed.edits.keystrokes.isVisible = false
    typed.edits.motionBlur.scope = .off
    try RecordingProjectFile.write(typed, to: folder)
    guard let editor = w.coordinator.openVideoEditor(folder), let window = editor.window, let content = window.contentView,
          let lane = editor.view(identifier: "video.zoomLane") as? ZoomLaneView else {
        return check(false, "the project opens with a zoom lane")
    }
    defer { w.coordinator.closeAllEditors() }
    window.setContentSize(NSSize(width: 1200, height: 760))
    content.layoutSubtreeIfNeeded()
    await editor.ready()
    let hand = ZoomHand(lane: lane)
    let duration = editor.state.transport.duration
    check(duration > 7.5, "the project is long enough for several zooms", detail: "\(duration)")
    // Tenths, since a drag lands on whole points of the lane.
    func zooms() -> [[Double]] { editor.state.project.edits.zooms.map { [($0.start * 10).rounded() / 10, ($0.end * 10).rounded() / 10] } }
    let title = editor.view(identifier: "video.panel.title") as? NSTextField
    let panel = editor.view(identifier: "video.zoom.panel")

    check(editor.state.project.edits.zooms.isEmpty && !lane.showsHint, "the lane starts empty and quiet")
    hand.hover(x: hand.x(1))
    check(lane.showsHint && lane.accessibilityHelp() == ZoomLaneView.hint, "hovering empty lane shows where a zoom would go and says \"\(ZoomLaneView.hint)\"")

    hand.click(x: hand.x(1))
    let first = editor.state.project.edits.zooms.first
    check(zooms() == [[1, 3]] && first?.scale == 2 && editor.state.selectedZoom == first?.id, "a click adds a 2 s zoom at 200% there and picks it", detail: "\(zooms())")
    check(!lane.showsHint, "the hint gives way over a zoom")
    check(title?.stringValue == "Zoom" && panel?.isHidden == false && editor.view(identifier: "video.cursor.show")?.isHidden == true,
          "picking a zoom switches the panel to the zoom's settings", detail: title?.stringValue ?? "nil")
    let rail = EditorSection.allCases.compactMap { editor.view(identifier: "video.rail.\($0.rawValue)") as? IconButton }
    check(rail.count == EditorSection.allCases.count && rail.allSatisfy { !$0.isSelected }, "the rail marks no section while a zoom has the panel")
    let blocks = (lane.accessibilityChildren() as? [NSAccessibilityElement]) ?? []
    check(blocks.count == 1 && blocks[0].accessibilityLabel() == "Zoom 200%, \(Timecode.text(1)) to \(Timecode.text(3))" && blocks[0].isAccessibilitySelected(),
          "each zoom is an accessible button naming its level and times", detail: blocks.first?.accessibilityLabel() ?? "none")

    await hand.drag(from: hand.x(4), to: hand.x(6))
    check(zooms() == [[1, 3], [4, 6]] && editor.state.selectedZoom == editor.state.project.edits.zooms.last?.id, "a drag adds a zoom over the dragged stretch",
          detail: "\(zooms())")
    if let center = editor.state.project.edits.zooms.last?.center, let p = PointerTrack.position(editor.state.project.events.pointer, at: 5) {
        let src = editor.state.project.source
        check(abs(center.x - p.x / src.pointWidth) < 1e-6 && abs(center.y - p.y / src.pointHeight) < 1e-6,
              "a new zoom aims where the pointer was halfway through it", detail: "\(center)")
    }

    guard let a = editor.state.project.edits.zooms.first else { return }
    await hand.drag(from: hand.x(2), to: hand.x(2.5))
    check(zooms() == [[1.5, 3.5], [4, 6]] && editor.state.selectedZoom == a.id, "dragging a zoom's body moves it and picks it", detail: "\(zooms())")
    editor.undo()
    check(zooms() == [[1, 3], [4, 6]], "one drag is one undo step", detail: "\(zooms())")
    editor.redo()
    check(zooms() == [[1.5, 3.5], [4, 6]], "redo moves it again")
    guard let moved = editor.state.project.edits.zooms.first else { return }
    await hand.drag(from: hand.edge(moved, .end), to: hand.x(5))
    check(zooms() == [[1.5, 4], [4, 6]], "dragging its end resizes it and stops at the next zoom", detail: "\(zooms())")
    guard let grown = editor.state.project.edits.zooms.first else { return }
    await hand.drag(from: hand.edge(grown, .start), to: hand.x(0.5))
    check(zooms() == [[0.5, 4], [4, 6]], "dragging its start resizes it from the other side", detail: "\(zooms())")
    await hand.drag(from: hand.edge(editor.state.project.edits.zooms[0], .start), to: hand.x(3.9))
    check(zooms() == [[3.5, 4], [4, 6]], "a zoom keeps the shortest length", detail: "\(zooms())")
    editor.undo()
    lane.display()

    section("video editor: a zoom's menu")
    guard let menu = hand.menu(x: hand.x(2)) else { return check(false, "a right click on a zoom opens its menu") }
    check(menu.items.map(\.title) == ["Level", "Apply Level to All", "Mode", "", "Split at Playhead", "Duplicate", "", "Remove Zoom", "Remove All Zooms"],
          "the menu offers level, apply level to all, mode, split, duplicate, remove and remove all", detail: "\(menu.items.map(\.title))")
    let levels = menu.items.first { $0.title == "Level" }?.submenu?.items ?? []
    check(levels.map(\.title) == ["100%", "150%", "200%", "300%", "400%"] && levels.first { $0.state == .on }?.title == "200%",
          "Level lists 100% to 400% and checks the zoom's own", detail: "\(levels.map(\.title))")
    check(menu.items.first { $0.title == "Mode" }?.submenu?.items.map(\.title) == ["Follow Cursor", "Manual"], "Mode offers Follow Cursor and Manual")
    check(hand.menu(x: hand.x(7)) == nil, "empty lane has no zoom menu")
    check(menu.pick("Level", "300%") && editor.state.project.edits.zooms[0].scale == 3, "Level 300% sets the zoom's level")
    check(hand.menu(x: hand.x(2))?.pick("Apply Level to All") == true && editor.state.project.edits.zooms.allSatisfy { $0.scale == 3 },
          "Apply Level to All gives every zoom that level")
    check(hand.menu(x: hand.x(2))?.pick("Mode", "Manual") == true && editor.state.project.edits.zooms[0].mode == .manual, "Mode switches to Manual")
    editor.seek(to: 2)
    check(hand.menu(x: hand.x(2))?.pick("Split at Playhead") == true && zooms() == [[0.5, 2], [2, 4], [4, 6]], "Split at Playhead cuts the zoom at the playhead",
          detail: "\(zooms())")
    check(editor.state.project.edits.zooms[1].scale == 3 && editor.state.project.edits.zooms[1].mode == .manual, "both parts keep its settings")
    check(hand.menu(x: hand.x(1))?.pick("Duplicate") == true && zooms() == [[0.5, 2], [2, 4], [4, 6], [6, 7.5]], "Duplicate puts a copy in the first gap that holds it",
          detail: "\(zooms())")
    check(hand.menu(x: hand.x(6.5))?.pick("Remove Zoom") == true && zooms() == [[0.5, 2], [2, 4], [4, 6]], "Remove takes that zoom away")
    check(hand.menu(x: hand.x(3))?.pick("Remove All Zooms") == true && zooms().isEmpty, "Remove All Zooms empties the lane")
    check(editor.state.selectedZoom == nil && title?.stringValue == EditorSection.cursor.title, "with its zoom gone the panel returns to the section")
    editor.undo()
    check(zooms() == [[0.5, 2], [2, 4], [4, 6]], "Undo brings every zoom back", detail: "\(zooms())")

    section("video editor: the zoom panel")
    hand.click(x: hand.x(5))
    let presets = editor.view(identifier: "video.zoom.presets") as? NSSegmentedControl
    let slider = editor.view(identifier: "video.zoom.level") as? NSSlider
    let mode = editor.view(identifier: "video.zoom.mode") as? NSPopUpButton
    let picked = { editor.state.project.edits.zooms.first { $0.id == editor.state.selectedZoom } }
    check(presets?.selectedSegment == 3 && slider?.doubleValue == 3 && mode?.titleOfSelectedItem == "Follow Cursor",
          "the panel shows the picked zoom's level and mode", detail: "\(presets?.selectedSegment ?? -9) \(slider?.doubleValue ?? -1)")
    presets?.selectedSegment = 1
    if let presets { fire(presets) }
    check(picked()?.scale == 1.5, "a preset sets the level", detail: "\(picked()?.scale ?? -1)")
    slider?.doubleValue = 2.47
    if let slider { fire(slider) }
    check(picked()?.scale == 2.47 && (editor.view(identifier: "video.zoom.panel")?.subviews.isEmpty == false), "the slider sets any level between", detail: "\(picked()?.scale ?? -1)")
    slider?.doubleValue = 2.98
    if let slider { fire(slider) }
    check(picked()?.scale == 3, "the slider settles on a preset it passes close to", detail: "\(picked()?.scale ?? -1)")
    mode?.selectItem(at: 1)
    if let mode { fire(mode) }
    check(picked()?.mode == .manual, "the mode menu sets the mode")
    let note = { (editor.view(identifier: "video.zoom.modeNote") as? NSTextField)?.stringValue }
    check(note() == ZoomPanel.modeNote(.manual), "the panel says a Manual zoom stays where it was added", detail: note() ?? "nil")
    mode?.selectItem(at: 0)
    if let mode { fire(mode) }
    check(picked()?.mode == .followCursor && note() == ZoomPanel.modeNote(.followCursor), "and that a Follow Cursor zoom keeps the pointer in view", detail: note() ?? "nil")
    mode?.selectItem(at: 1)
    if let mode { fire(mode) }
    (editor.view(identifier: "video.zoom.remove") as? NSButton)?.performClick(nil)
    check(zooms() == [[0.5, 2], [2, 4]] && title?.stringValue == EditorSection.cursor.title, "Remove Zoom in the panel removes it and the panel returns")
    editor.undo()

    section("video editor: zooms from the keyboard")
    hand.click(x: hand.x(1))
    Synth.key(window, 53, "\u{1b}")
    check(editor.state.selectedZoom == nil && title?.stringValue == EditorSection.cursor.title, "Esc lets go of the zoom")
    editor.seek(to: 6.5)
    Synth.key(window, 6, "z")
    check(zooms().last == [6, 8] && editor.state.selectedZoom != nil, "Z adds a zoom at the playhead and picks it", detail: "\(zooms())")
    Synth.key(window, 51, "\u{7f}")
    check(zooms() == [[0.5, 2], [2, 4], [4, 6]], "Delete removes the picked zoom", detail: "\(zooms())")
    Synth.key(window, 6, "z", modifiers: .command)
    check(zooms().last == [6, 8], "Command-Z brings it back")
    Synth.key(window, 6, "z", modifiers: [.command, .shift])
    check(zooms().count == 3, "Shift-Command-Z removes it again")
    func arrow(_ code: UInt16, _ mods: NSEvent.ModifierFlags = []) { lane.keyDown(with: Synth.keyEvent(window, code, "", modifiers: mods)) }
    hand.click(x: hand.x(1))
    check(window.firstResponder === lane, "clicking the lane gives it keyboard focus")
    arrow(124)
    check(editor.state.selectedZoom == editor.state.project.edits.zooms[1].id, "Right on the focused lane picks the next zoom")
    arrow(123)
    check(editor.state.selectedZoom == editor.state.project.edits.zooms[0].id, "Left picks the one before")
    arrow(124, .option)
    arrow(124, .option)
    check(zooms()[0] == [0.5, 2], "Option-Right moves the picked zoom a tenth of a second, stopping at its neighbour", detail: "\(zooms())")
    arrow(123, .option)
    arrow(123, [.option, .shift])
    check(zooms()[0] == [0, 1.5], "Option-Left moves it earlier, Shift a whole second, stopping at the start", detail: "\(zooms())")
    arrow(124, [.option, .command])
    check(zooms()[0] == [0, 1.6], "Option-Command-Right moves its end", detail: "\(zooms())")
    editor.undo()
    check(zooms()[0] == [0, 1.5], "the end edit is its own undo step", detail: "\(zooms())")
    editor.undo()
    check(zooms()[0] == [0.5, 2], "presses in a row are one undo step per edit", detail: "\(zooms())")
    editor.seek(to: 1.2)
    Synth.key(window, 11, "b", modifiers: .command)
    check(zooms().prefix(2) == [[0.5, 1.2], [1.2, 2]], "Command-B splits the picked zoom at the playhead instead of the clip", detail: "\(zooms())")
    check(editor.state.project.edits.clips.count == 1, "and leaves the clips alone")
    Synth.key(window, 2, "d", modifiers: .command)
    check(zooms().count == 5 && zooms().last == [6, 6.8], "Command-D duplicates the picked zoom into the first gap that holds it", detail: "\(zooms())")
    editor.undo()
    editor.undo()
    hand.click(x: hand.x(1))
    (editor.view(identifier: "video.rail.audio") as? NSButton)?.performClick(nil)
    check(editor.state.selectedZoom == nil && title?.stringValue == "Audio", "choosing a section in the rail lets go of the zoom")

    section("video editor: the preview zooms")
    editor.removeAllZooms()
    let near = editor.addZoom(from: 1, to: 3)
    if let id = near?.id { editor.setZoomScale(2, of: id) }
    let far = editor.addZoom(from: 3.8, to: 6)
    if let id = far?.id { editor.setZoomScale(3, of: id) }
    editor.selectZoom(nil)
    let project = editor.state.project
    for t in [0.5, 2.0, 5.0] {
        editor.seek(to: t)
        await decoder?.prepare(frameState(project, outputTime: t).sourceTime)
        editor.tick()
        check(editor.previewState?.crop == ZoomCamera.rect(project, at: t), String(format: "at %.1f s the preview shows the crop frameState gives", t),
              detail: "\(String(describing: editor.previewState?.crop))")
    }
    editor.seek(to: 2)
    await decoder?.prepare(frameState(project, outputTime: 2).sourceTime)
    editor.tick()
    if let id = near?.id { editor.selectZoom(id) }
    content.layoutSubtreeIfNeeded()
    lane.display()
    snapshotEditor(editor, name: "video-zoom")
    snapshotEditor(editor, name: "video-zoom-dark", dark: true)
    window.appearance = nil
    editor.selectZoom(nil)

    section("video editor: zoomed frames in the file match the preview")
    let out = w.root.appendingPathComponent("zoomed.mp4")
    let report = try await VideoExporter.export(project: project, video: editor.videoURL, settings: ExportSettings(), to: out)
    if let decoder {
        // Whole frames, so the file's frame is the moment the preview drew even while the camera moves.
        let times = [30, 81, 120, 159, 234, 249, 300, 339, 372].map { Double($0) / 60 }
        let rows = await measureParity(editor, frames: decoder, clock: clock, export: out, plan: report.plan, project: project, times: times)
        for r in rows {
            let cam = ZoomCamera.rect(project, at: r.time)
            print(String(format: "PARITY zoom t=%.2f scale=%.3f preview-vs-drawn %@ | preview-vs-file %@", r.time, cam.scale, r.drawn.description, r.encoded.description))
        }
        // Both zooms follow the cursor, so a measured moment at a held level has the camera drifting after the recorded pointer.
        let drifting = times.filter { t in
            let a = ZoomCamera.rect(project, at: t), b = ZoomCamera.rect(project, at: t + 1.0 / 60)
            return a.width == b.width && a.width < 1 && hypot(b.x - a.x, b.y - a.y) > 1e-4 && a != ZoomCamera.rect(project.edits.zooms, at: t)
        }
        print("FOLLOW parity moments with the camera drifting: \(drifting.map { String(format: "%.2f", $0) })")
        check(!drifting.isEmpty, "a measured moment has the camera drifting after the pointer, away from the stored center", detail: "\(drifting)")
        check(rows.count == times.count && rows.allSatisfy { $0.drawn.mean < 0.5 && $0.drawn.over16 < 0.001 },
              "zoomed export frames draw what the preview shows, before compression", detail: rows.map { $0.drawn.description }.joined(separator: "; "))
        check(rows.count == times.count && rows.allSatisfy { $0.encoded.psnr > 35 }, "zoomed file frames match the preview within compression loss",
              detail: rows.map { $0.encoded.description }.joined(separator: "; "))
    } else { check(false, "the harness decoder is known") }
    section("video export: a following pan is blurred")
    // Blur reads the crop through frameState, so a pan made by following the pointer smears like any other camera move.
    var panning = project
    panning.edits.motionBlur = MotionBlur(scope: .zooms)
    let pan = Array(Int(1.8 * 60)...Int(3.7 * 60)).map { Double($0) / 60 }.max { a, b in
        func step(_ t: Double) -> Double { let x = ZoomCamera.rect(panning, at: t), y = ZoomCamera.rect(panning, at: t + 1.0 / 60); return hypot(y.x - x.x, y.y - x.y) }
        return step(a) < step(b)
    } ?? 2
    let panOut = w.root.appendingPathComponent("zoomed-follow-blur.mp4")
    let panReport = try await VideoExporter.export(project: panning, video: editor.videoURL, settings: ExportSettings(), to: panOut)
    let panRenderer = ExportFrameRenderer(plan: panReport.plan, project: panning, folder: editor.folder)
    let panSamples = frameSamples(panning, outputTime: pan, fps: panReport.plan.fps, pixelsAcross: panRenderer.frameRect.width)
    let crops = panSamples.map(\.crop)
    check(panSamples.count > 1 && crops.allSatisfy { abs($0.width - crops[0].width) < 1e-12 && $0.width < 1 }
          && hypot((crops.last?.x ?? 0) - crops[0].x, (crops.last?.y ?? 0) - crops[0].y) > 1e-4,
          String(format: "at %.3f s the level holds and the following camera pans inside the shutter window, so export averages %d moments", pan, panSamples.count),
          detail: crops.map { String(format: "(%.4f,%.4f)", $0.x, $0.y) }.joined(separator: " "))
    if let source = await decodedFrame(editor.videoURL, at: panSamples[0].sourceTime),
       let reference = averageOf(panSamples.compactMap { panRenderer.image($0, source: source) }),
       let sharp = panRenderer.image(panSamples[0], source: source), let file = await decodedFrame(panOut, at: pan),
       let toReference = PixelDifference(file, reference, edge: 4), let toSharp = PixelDifference(file, sharp, edge: 4) {
        print(String(format: "BLUR follow pan t=%.3f samples=%d file-vs-blurred-reference %@ | file-vs-sharp %@", pan, panSamples.count, toReference.description, toSharp.description))
        check(toReference.psnr > 35 && toSharp.mean > toReference.mean, "the file's frame is the blurred average of the pan, not the sharp frame",
              detail: "reference \(toReference.description) vs sharp \(toSharp.description)")
    } else { check(false, "the following pan's blurred frame could be measured") }

    section("video editor: zoom, background, pointer and keystroke badge together match the preview")
    let plainCursor = editor.state.project.edits.cursor
    editor.setCursor(CursorSettings(scale: 2.4, style: .black, motion: .smooth))
    var framed = editor.state.project.edits.background
    framed.fill = .gradient(index: 6)
    framed.padding = 48; framed.shadow = 70; framed.cornerRadius = 20
    editor.setBackground(framed)
    editor.setKeystrokes(KeystrokeDisplay(isVisible: true, keys: .shortcuts, position: .center, size: .large, theme: .light))
    // The first zoom holds its stored spot, which leaves the badge's cell out of the view; the second follows the pointer.
    if let id = near?.id { editor.setZoomMode(.manual, of: id) }
    let combined = editor.state.project
    let combinedOut = w.root.appendingPathComponent("zoomed-framed.mp4")
    let combinedReport = try await VideoExporter.export(project: combined, video: editor.videoURL, settings: ExportSettings(), to: combinedOut)
    if let decoder {
        // Before any zoom, partway into the first one, holding at its level, and partway out of the second.
        let times = [30, 81, 120, 339].map { Double($0) / 60 }
        let rows = await measureParity(editor, frames: decoder, clock: clock, export: combinedOut, plan: combinedReport.plan, project: combined, times: times,
                                       name: "parity-zoom-framed")
        for r in rows {
            let state = frameState(combined, outputTime: r.time)
            print(String(format: "PARITY zoom+background+cursor+badge t=%.2f scale=%.3f pointer=%@ badge=%@ preview-vs-drawn %@ | preview-vs-file %@", r.time, state.crop.scale,
                         state.cursor == nil ? "hidden" : "shown", state.input.badge?.text ?? "none", r.drawn.description, r.encoded.description))
        }
        // The badge sits in recording points, so a zoom that leaves its cell out leaves the badge out, as it does the pointer.
        let area = CGSize(width: combined.source.pointWidth, height: combined.source.pointHeight)
        func badgeInView(_ t: Double) -> Bool {
            let state = frameState(combined, outputTime: t)
            guard let badge = state.input.badge else { return false }
            let frame = InputOverlayPainter.badgeFrame(text: badge.text, area: area, combined.edits.keystrokes)
            let fx = frame.midX / area.width, fy = frame.midY / area.height
            return fx >= state.crop.x && fx <= state.crop.x + state.crop.width && fy >= state.crop.y && fy <= state.crop.y + state.crop.height
        }
        check(times.allSatisfy { frameState(combined, outputTime: $0).input.badge != nil }, "a badge is showing at each measured moment",
              detail: times.map { frameState(combined, outputTime: $0).input.badge?.text ?? "none" }.joined(separator: " "))
        let inView = times.map(badgeInView)
        print("BADGE in zoomed view per measured moment: \(inView)")
        check(inView.contains(true) && inView.contains(false), "the measured moments include a zoom that keeps the badge's cell in view and one that leaves it out", detail: "\(inView)")
        // Against the same frame drawn without the badge, the file differs inside the cell the crop maps the badge to, and only there.
        let renderer = ExportFrameRenderer(plan: combinedReport.plan, project: combined, folder: editor.folder)
        let canvas = combined.canvas, plan = combinedReport.plan
        let kx = Double(plan.width) / canvas.size.width, ky = Double(plan.height) / canvas.size.height
        func cell(_ badge: CGRect, crop: ZoomRect) -> CGRect {
            let f = canvas.frame
            let x = f.minX + (badge.minX / area.width - crop.x) / crop.width * f.width, y = f.minY + (badge.minY / area.height - crop.y) / crop.height * f.height
            return CGRect(x: x * kx, y: y * ky, width: badge.width / (area.width * crop.width) * f.width * kx, height: badge.height / (area.height * crop.height) * f.height * ky)
        }
        var landed: [String] = [], moved = true
        for (t, visible) in zip(times, inView) {
            var state = frameState(combined, outputTime: t)
            guard let badge = state.input.badge, let file = await decodedFrame(combinedOut, at: t), let picture = await decodedFrame(editor.videoURL, at: state.sourceTime) else {
                moved = false
                continue
            }
            state.input = InputOverlayState()
            guard let without = renderer.image(state, source: picture) else { moved = false; continue }
            let frame = InputOverlayPainter.badgeFrame(text: badge.text, area: area, combined.edits.keystrokes)
            let mapped = changedShare(file, without, in: cell(frame, crop: state.crop).insetBy(dx: 6, dy: 6))
            let pinned = changedShare(file, without, in: cell(frame, crop: .full).insetBy(dx: 6, dy: 6))
            landed.append(String(format: "t=%.2f scale=%.2f mapped=%.3f pinned=%.3f", t, state.crop.scale, mapped, pinned))
            if visible { moved = moved && mapped > 0.3 && (state.crop.scale < 1.01 || pinned < 0.05) } else { moved = moved && pinned < 0.05 }
        }
        print("PLACEMENT badge under zoom: " + landed.joined(separator: " | "))
        check(moved && landed.count == times.count, "in the file the badge is where the crop maps its cell, not pinned to the frame, and not drawn at the frame cell when the crop leaves its own cell out", detail: landed.joined(separator: "; "))
        let source = combined.source
        check(rows.count == times.count && times.allSatisfy { t in
            let state = frameState(combined, outputTime: t)
            guard let p = state.cursor, source.pointWidth > 0, source.pointHeight > 0 else { return false }
            let fx = p.x / source.pointWidth, fy = p.y / source.pointHeight
            return fx >= state.crop.x && fx <= state.crop.x + state.crop.width && fy >= state.crop.y && fy <= state.crop.y + state.crop.height
        }, "the pointer is inside the zoomed view at each measured moment")
        check(times.contains { (1.01...1.99).contains(frameState(combined, outputTime: $0).crop.scale) }, "one measured moment is partway through a zoom")
        // The preview lays the badge's glyphs with a layer and export with a bitmap, so their edges differ a little more than the picture's.
        check(rows.count == times.count && rows.allSatisfy { $0.drawn.mean < 0.5 && $0.drawn.over16 < 0.005 && $0.drawn.psnr > 34 },
              "zoom, background, pointer and badge: the export draws what the preview shows, before compression", detail: rows.map { $0.drawn.description }.joined(separator: "; "))
        check(rows.count == times.count && rows.allSatisfy { $0.encoded.psnr > 34 }, "zoom, background, pointer and badge: the file's frames match the preview within compression loss",
              detail: rows.map { $0.encoded.description }.joined(separator: "; "))
    } else { check(false, "the harness decoder is known") }
    editor.setBackground(VideoBackground())
    editor.setCursor(plainCursor)
    if let id = near?.id { editor.setZoomMode(.followCursor, of: id) }

    if let dir = ProcessInfo.processInfo.environment["CORNERMARK_ZOOM_EXPORT"] {
        let copy = URL(fileURLWithPath: dir).appendingPathComponent("zoom-export.mp4")
        try? FileManager.default.removeItem(at: copy)
        try? FileManager.default.copyItem(at: out, to: copy)
        print("ZOOM EXPORT \(copy.path) zooms=\(project.edits.zooms.map { String(format: "%.2f-%.2f@%.1f", $0.start, $0.end, $0.scale) })")
    }

    section("video editor: zooms are saved")
    window.close()
    let stored = try RecordingProjectFile.read(from: folder)
    check(stored.edits.zooms == project.edits.zooms, "closing the editor writes the zooms to project.json", detail: "\(stored.edits.zooms.count)")
}
