import AppKit
import CornermarkCore
import CornermarkDesign
@testable import CornermarkVideoEditor
@testable import CornermarkShell

let scriptedClicks: [Double] = [0.5, 1.05, 1.5, 1.62]

func clickingCopy(of folder: URL, in root: URL) throws -> URL {
    let copy = try movingPointerCopy(of: folder, in: root)
    var project = try RecordingProjectFile.read(from: copy)
    project.events.clicks = scriptedClicks.map { t in
        let at = PointerTrack.position(project.events.pointer, at: t) ?? (0, 0)
        return ClickEvent(t: t, x: at.x, y: at.y)
    }
    try RecordingProjectFile.write(project, to: copy)
    return copy
}

@MainActor
func checkVideoEditorClicks(_ w: World, folder: URL) async throws {
    section("video editor: click press and ripple")
    let clicking = try clickingCopy(of: folder, in: w.root)
    guard let editor = w.coordinator.openVideoEditor(clicking), let window = editor.window, let content = window.contentView else {
        return check(false, "the editor opens")
    }
    window.setContentSize(window.minSize)
    content.layoutSubtreeIfNeeded()
    let before = editor.state.project.edits
    (editor.view(identifier: "video.rail.clicks") as? NSButton)?.performClick(nil)
    let press = editor.view(identifier: "video.clicks.press") as? NSButton
    let ripple = editor.view(identifier: "video.clicks.ripple") as? NSButton
    let color = editor.view(identifier: "video.clicks.color") as? NSPopUpButton
    let size = editor.view(identifier: "video.clicks.size") as? Segments
    let style = editor.view(identifier: "video.clicks.style") as? Segments
    let motion = editor.view(identifier: "video.clicks.motion") as? Segments
    let panel = frameInWindow(editor.view(identifier: "video.panel"))
    let controls: [NSView?] = [press, ripple, color, size, style, motion]
    check(editor.state.section == .clicks && controls.allSatisfy { $0 != nil && !$0!.isHiddenOrHasHiddenAncestor && panel.contains(frameInWindow($0)) },
          "at the smallest window the Clicks panel holds Press effect, Ripple, Color, Size, Style and Motion inside its edges",
          detail: controls.map { "\(frameInWindow($0))" }.joined(separator: " "))
    let rows = controls.map { frameInWindow($0) }
    check(zip(rows, rows.dropFirst()).allSatisfy { $0.minY >= $1.maxY }, "the click settings stack top to bottom without overlapping")
    check(editor.view(identifier: "video.cursor.show")?.isHiddenOrHasHiddenAncestor == true && editor.view(identifier: "video.clicks.note")?.isHidden == true,
          "the Cursor settings and the no-clicks note are hidden while Clicks shows")
    check(press?.state == .off && ripple?.state == .off && [color, size, style, motion].allSatisfy { ($0 as NSControl?)?.isEnabled == false },
          "a project recorded with clicks hidden starts with both effects off and the ring's look turned off with Ripple")
    check(color?.itemTitles == ["Lemon", "White", "Orange", "Red", "Green"] && color?.itemArray.allSatisfy { $0.image != nil } == true
          && (0..<3).map { size?.label(forSegment: $0) } == ["Small", "Medium", "Large"] && (0..<2).map { style?.label(forSegment: $0) } == ["Outline", "Filled"]
          && (0..<2).map { motion?.label(forSegment: $0) } == ["Grow", "Still"], "Color shows five swatches; Size, Style and Motion name their choices")

    func at(_ t: Double) -> FrameState? {
        editor.seek(to: t)
        return editor.previewState
    }
    check(at(1.55)?.input.rings.isEmpty == true, "Ripple off: no ring in the preview")
    ripple?.performClick(nil)
    check(editor.state.project.edits.clicks.isVisible && [color, size, style, motion].allSatisfy { ($0 as NSControl?)?.isEnabled == true },
          "Ripple on turns on the ring's look")
    let ring = at(1.55)?.input.rings
    check(ring?.count == 1 && ring == frameState(editor.state.project, outputTime: 1.55).input.rings, "the preview shows the ring frameState places")
    let preview = editor.view(identifier: "video.preview") as? PreviewView
    let shown = preview?.layer?.sublayers?.first?.sublayers?.first?.sublayers?.filter { !$0.isHidden && $0.className.contains("RingLayer") }.count
    check(shown == 1, "and draws it as one ring layer under the pointer", detail: "\(shown ?? -1)")
    let late = at(1.5 + ClickHighlight.lifetime + 0.01)?.input.rings
    check(late?.count == 1
          && editor.state.project.clickRings(at: 1.62 + ClickHighlight.lifetime + 0.001).isEmpty,
          "each ring is gone \(ClickHighlight.lifetime) s after its click", detail: "\(late ?? [])")

    color?.selectItem(at: 2)
    color.map(fire)
    size?.selectedSegment = 2
    size.map(fire)
    style?.selectedSegment = 1
    style.map(fire)
    check(editor.state.project.edits.clicks == ClickHighlight(isVisible: true, color: .orange, style: .filled, size: .large),
          "Color, Size and Style change the ring", detail: "\(editor.state.project.edits.clicks)")
    motion?.selectedSegment = 1
    motion.map(fire)
    check(!editor.state.project.edits.clicks.animates && at(1.55)?.input.rings.first?.radius == ClickHighlight.Size.large.radius,
          "Still draws the ring at its full size")
    motion?.selectedSegment = 0
    motion.map(fire)

    press?.performClick(nil)
    check(editor.state.project.edits.cursor.pressesOnClick && (at(1.5 + CursorTrack.pressDown)?.cursor?.scale ?? 1) < 0.81,
          "Press effect shrinks the preview's pointer at a click", detail: "\(at(1.5 + CursorTrack.pressDown)?.cursor?.scale ?? -1)")
    snapshotEditor(editor, name: "video-editor-clicks-min")

    (editor.view(identifier: "video.rail.cursor") as? NSButton)?.performClick(nil)
    (editor.view(identifier: "video.cursor.show") as? NSButton)?.performClick(nil)
    (editor.view(identifier: "video.rail.clicks") as? NSButton)?.performClick(nil)
    check(press?.isEnabled == false && ripple?.isEnabled == true && at(1.55)?.cursor == nil && at(1.55)?.input.rings.count == 1,
          "with Show cursor off the press effect is off and says why, and the ring still marks the click")
    snapshotEditor(editor, name: "video-editor-clicks-cursor-off")

    let steps = editor.state.project.edits
    Synth.key(window, 6, "z", modifiers: .command)
    check(editor.state.project.edits.cursor.isVisible && press?.isEnabled == true, "Command-Z brings the cursor back")
    Synth.key(window, 6, "z", modifiers: .command)
    check(!editor.state.project.edits.cursor.pressesOnClick && press?.state == .off, "Command-Z again takes back the press effect")
    Synth.key(window, 6, "Z", modifiers: [.command, .shift])
    Synth.key(window, 6, "Z", modifiers: [.command, .shift])
    check(editor.state.project.edits == steps, "Shift-Command-Z redoes both")
    for _ in 0..<12 { Synth.key(window, 6, "z", modifiers: .command) }
    check(editor.state.project.edits == before && ripple?.state == .off, "undoing every step returns to the project as it opened")
    for _ in 0..<12 { Synth.key(window, 6, "Z", modifiers: [.command, .shift]) }
    (editor.view(identifier: "video.rail.cursor") as? NSButton)?.performClick(nil)
    (editor.view(identifier: "video.cursor.show") as? NSButton)?.performClick(nil)
    (editor.view(identifier: "video.rail.clicks") as? NSButton)?.performClick(nil)

    window.setContentSize(NSSize(width: 1200, height: 760))
    content.layoutSubtreeIfNeeded()
    editor.seek(to: 1.5 + 0.15)
    _ = await waitUntil(3) { editor.tick(); return editor.previewImage != nil }
    snapshotEditor(editor, name: "video-editor-clicks")
    snapshotEditor(editor, name: "video-editor-clicks-dark", dark: true)
    window.appearance = nil
    let saved = editor.state.project.edits
    w.coordinator.closeAllEditors()
    let stored = try RecordingProjectFile.read(from: clicking)
    check(stored.edits.clicks == saved.clicks && stored.edits.cursor.pressesOnClick && stored.edits.clicks.isVisible,
          "closing writes the ripple and the press effect to project.json")

    var silent = try RecordingProjectFile.read(from: clicking)
    silent.events.clicks = []
    try RecordingProjectFile.write(silent, to: clicking)
    guard let none = w.coordinator.openVideoEditor(clicking) else { return check(false, "the project without clicks opens") }
    (none.view(identifier: "video.rail.clicks") as? NSButton)?.performClick(nil)
    let note = none.view(identifier: "video.clicks.note") as? NSTextField
    let off = ["video.clicks.press", "video.clicks.ripple", "video.clicks.color", "video.clicks.size"].allSatisfy { (none.view(identifier: $0) as? NSControl)?.isEnabled == false }
    check(note?.isHidden == false && note?.stringValue.hasPrefix("This recording has no clicks.") == true && off,
          "a recording without clicks says so and turns the settings off", detail: note?.stringValue ?? "")
    snapshotEditor(none, name: "video-editor-clicks-none")
    w.coordinator.closeAllEditors()
}

@MainActor
func checkClickExport(_ editor: VideoEditorWindowController, frames: StillFrames, clock: ScriptedClock, root: URL) async throws {
    section("video export: press and ripple match the preview")
    editor.setBackground(VideoBackground())
    editor.setCursor(CursorSettings(scale: 2.4, motion: .smooth, pressesOnClick: true))
    editor.setClickHighlight(ClickHighlight(isVisible: true, color: .orange, style: .filled, size: .large))
    let project = editor.state.project
    check(project.events.clicks.count == scriptedClicks.count, "the copy has \(scriptedClicks.count) clicks", detail: "\(project.events.clicks.count)")
    let out = root.appendingPathComponent("clicks.mp4")
    let report = try await VideoExporter.export(project: project, video: editor.videoURL, settings: ExportSettings(), to: out)
    var mismatched: [Int] = []
    var ringed = 0, pressed = 0
    for k in 0..<report.plan.frameCount {
        let t = report.plan.time(ofFrame: k)
        editor.seek(to: t)
        let exported = frameState(project, outputTime: t)
        if editor.previewState != exported { mismatched.append(k) }
        if !exported.input.rings.isEmpty { ringed += 1 }
        if let s = exported.cursor?.scale, s < 2.4 { pressed += 1 }
    }
    print("PARITYFRAMES clicks frames=\(report.plan.frameCount) mismatched=\(mismatched.count) ringed=\(ringed) pressed=\(pressed)")
    check(mismatched.isEmpty && ringed > 0 && pressed > 0, "press and ripple: the preview places the rings and sizes the pointer as the export does, every frame",
          detail: "\(mismatched.prefix(5))")
    let times = [0.55, 1.1, 1.65, 1.75]
    let rows = await measureParity(editor, frames: frames, clock: clock, export: out, plan: report.plan, project: project, times: times, name: "parity-clicks")
    for r in rows {
        let s = frameState(project, outputTime: r.time)
        let rings = s.input.rings.map { String(format: "r=%.1f a=%.2f", $0.radius, $0.opacity) }.joined(separator: ",")
        print(String(format: "PARITY clicks t=%.2f scale=%.2f rings=[%@] preview-vs-drawn %@ | preview-vs-file %@", r.time, s.cursor?.scale ?? 0, rings,
                     r.drawn.description, r.encoded.description))
    }
    check(times.allSatisfy { !frameState(project, outputTime: $0).input.rings.isEmpty } && frameState(project, outputTime: 1.75).input.rings.count == 2
          && (frameState(project, outputTime: 1.1).cursor?.scale ?? 9) < 2.4, "the measured moments include a ring mid-ripple, a pointer mid-press and two rings at once")
    check(rows.count == times.count && rows.allSatisfy { $0.drawn.mean < 0.5 && $0.drawn.over16 < 0.001 },
          "press and ripple: the export draws what the preview shows, before compression", detail: rows.map { $0.drawn.description }.joined(separator: "; "))
    check(rows.count == times.count && rows.allSatisfy { $0.encoded.psnr > 35 }, "press and ripple: the file's frames match the preview within compression loss",
          detail: rows.map { $0.encoded.description }.joined(separator: "; "))
    _ = editor.addZoom(from: 0.9, to: 2.0)
    editor.selectZoom(nil)
    let zoomed = editor.state.project
    let zoomedOut = root.appendingPathComponent("clicks-zoomed.mp4")
    let zoomedReport = try await VideoExporter.export(project: zoomed, video: editor.videoURL, settings: ExportSettings(), to: zoomedOut)
    let zoomedRows = await measureParity(editor, frames: frames, clock: clock, export: zoomedOut, plan: zoomedReport.plan, project: zoomed, times: [1.65],
                                         name: "parity-clicks-zoomed")
    for r in zoomedRows {
        print(String(format: "PARITY clicks zoomed t=%.2f crop=%.2f preview-vs-drawn %@ | preview-vs-file %@", r.time,
                     frameState(zoomed, outputTime: r.time).crop.width, r.drawn.description, r.encoded.description))
    }
    check(frameState(zoomed, outputTime: 1.65).crop.width < 1 && zoomedRows.count == 1 && zoomedRows.allSatisfy { $0.drawn.mean < 0.5 && $0.drawn.over16 < 0.001 && $0.encoded.psnr > 35 },
          "zoomed in, the rings follow the crop in the preview as in the export", detail: zoomedRows.map { $0.drawn.description }.joined(separator: "; "))
    editor.undo()

    editor.setKeystrokes(KeystrokeDisplay(isVisible: true, keys: .shortcuts, position: .topCenter, size: .large, theme: .light))
    let both = editor.state.project
    let bothOut = root.appendingPathComponent("clicks-badge.mp4")
    let bothReport = try await VideoExporter.export(project: both, video: editor.videoURL, settings: ExportSettings(), to: bothOut)
    let bothTimes = [1.65, 1.75]
    let bothRows = await measureParity(editor, frames: frames, clock: clock, export: bothOut, plan: bothReport.plan, project: both, times: bothTimes, name: "parity-clicks-badge")
    for r in bothRows {
        let s = frameState(both, outputTime: r.time)
        print(String(format: "PARITY clicks+badge t=%.2f rings=%d badge=%@ drawn-rings-in-preview=%d preview-vs-drawn %@ | preview-vs-file %@", r.time, s.input.rings.count,
                     s.input.badge?.text ?? "none", editor.previewRingLayerCount, r.drawn.description, r.encoded.description))
    }
    let atBoth = bothTimes.map { frameState(both, outputTime: $0) }
    check(atBoth.allSatisfy { !$0.input.rings.isEmpty && $0.input.badge != nil } && atBoth.last?.input.rings.count == 2,
          "the measured moments have a ring and a badge on screen together, the last with two rings")
    check(editor.previewRingLayerCount == atBoth.last?.input.rings.count, "the preview draws each ring once: one ring layer per ring, and the badge layer paints no ring",
          detail: "\(editor.previewRingLayerCount) ring layers for \(atBoth.last?.input.rings.count ?? -1) rings")
    check(bothRows.count == bothTimes.count && bothRows.allSatisfy { $0.drawn.mean < 0.5 && $0.drawn.over16 < 0.001 },
          "a ring and a badge together: the export draws what the preview shows, so no ring is drawn twice in either", detail: bothRows.map { $0.drawn.description }.joined(separator: "; "))
    check(bothRows.count == bothTimes.count && bothRows.allSatisfy { $0.encoded.psnr > 35 }, "a ring and a badge together: the file's frames match the preview within compression loss",
          detail: bothRows.map { $0.encoded.description }.joined(separator: "; "))
    editor.setKeystrokes(KeystrokeDisplay())
    editor.setClickHighlight(ClickHighlight())
}
