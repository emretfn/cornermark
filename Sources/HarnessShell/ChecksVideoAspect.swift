import AppKit
import CornermarkCore
import CornermarkDesign
@testable import CornermarkVideoEditor
@testable import CornermarkShell

@MainActor
func pickAspect(_ aspect: VideoAspect, in editor: VideoEditorWindowController) {
    guard let menu = editor.view(identifier: "video.background.aspect") as? NSPopUpButton else { return }
    let tag: Int
    if case .custom = aspect { tag = VideoAspect.presets.count } else { tag = VideoAspect.presets.firstIndex(of: aspect) ?? 0 }
    menu.selectItem(withTag: tag)
    fire(menu)
}

/// The mean of a band of pixels, 0...255 over RGB.
func meanGray(_ image: CGImage, _ rect: CGRect) -> Double {
    guard let px = Pix.bytes(image) else { return -1 }
    var sum = 0.0, n = 0.0
    for y in Int(rect.minY)..<Int(rect.maxY) {
        for x in Int(rect.minX)..<Int(rect.maxX) {
            let i = (y * image.width + x) * 4
            sum += Double(px[i]) + Double(px[i + 1]) + Double(px[i + 2]); n += 3
        }
    }
    return sum / max(n, 1)
}

@MainActor
func checkVideoAspect(_ w: World, folder: URL) async throws {
    section("video editor: aspect ratio")
    guard let editor = w.coordinator.openVideoEditor(folder), let window = editor.window, let content = window.contentView else {
        return check(false, "the editor opens")
    }
    defer { w.coordinator.closeAllEditors() }
    window.setContentSize(NSSize(width: 1200, height: 760))
    content.layoutSubtreeIfNeeded()
    await editor.ready()
    (editor.view(identifier: "video.rail.background") as? NSButton)?.performClick(nil)
    content.layoutSubtreeIfNeeded()
    let source = editor.state.project.source
    let menu = editor.view(identifier: "video.background.aspect") as? NSPopUpButton
    let titles = menu?.itemArray.filter { !$0.isSeparatorItem }.map(\.title) ?? []
    check(titles == ["Auto", "1:1", "5:4", "4:3", "3:2", "16:9", "4:5", "3:4", "9:16", "Custom"],
          "Ratio offers Auto, the wide and square shapes, the tall ones, and Custom", detail: "\(titles)")
    check(menu?.itemArray.filter(\.isSeparatorItem).count == 3, "separators group Auto, wide, tall and Custom")
    check(menu?.titleOfSelectedItem == "Auto" && editor.state.project.edits.background.aspect == .auto, "a recording starts at Auto")
    let p = frameInWindow(editor.view(identifier: "video.background"))
    check(abs(frameInWindow(menu).maxX - (p.minX + DS.Space.s16 + BackgroundPanel.inner)) < 0.5, "the menu ends on the panel's right edge",
          detail: "\(frameInWindow(menu)) \(p)")
    check(menu?.isEnabled == true, "the shape can be picked without a background")
    let width = editor.view(identifier: "video.background.aspect.width") as? NSTextField
    let height = editor.view(identifier: "video.background.aspect.height") as? NSTextField
    check(width?.isHiddenOrHasHiddenAncestor == true, "the Custom fields stay hidden until Custom is picked")

    let resolution = editor.view(identifier: "video.export.resolution") as? NSPopUpButton
    let estimate = editor.view(identifier: "video.export.estimate") as? NSTextField
    let note = editor.view(identifier: "video.background.note") as? NSTextField
    let autoEstimate = estimate?.stringValue
    pickAspect(.ratio(width: 9, height: 16), in: editor)
    editor.tick()
    content.layoutSubtreeIfNeeded()
    var plan = ExportPlan(project: editor.state.project, settings: ExportSettings())
    check(editor.state.project.edits.background.aspect == .ratio(width: 9, height: 16) && plan.width == source.pixelWidth
          && plan.height == even(Double(source.pixelWidth) * 16 / 9),
          "9:16 without a background keeps the recording's width and grows the height to the shape", detail: "\(plan.width)x\(plan.height)")
    check(note?.isHidden == false && note?.stringValue.hasPrefix("Black bars fill the rest of the video.") == true,
          "without a background the panel says black bars fill the rest", detail: note?.stringValue ?? "nil")
    if let frame = previewFrame(editor, size: CGSize(width: 180, height: 320)) {
        let top = meanGray(frame, CGRect(x: 20, y: 6, width: 140, height: 30)), middle = meanGray(frame, CGRect(x: 20, y: 150, width: 140, height: 20))
        check(top < 2 && middle > 20, "the preview shows black bars above and below the recording", detail: String(format: "top=%.1f middle=%.1f", top, middle))
    } else { check(false, "the preview frame renders") }
    check(resolution?.itemTitles.first == "\(plan.width) \u{00D7} \(plan.height) (Original)", "the export sizes follow the shape",
          detail: resolution?.itemTitles.first ?? "nil")
    check(resolution?.itemTitles.contains("480 \u{00D7} 854") == true, "a smaller size is named by the short side, here the width",
          detail: "\(resolution?.itemTitles ?? [])")
    check(estimate?.stringValue != nil, "the estimate is shown for the new shape", detail: "\(autoEstimate ?? "nil") -> \(estimate?.stringValue ?? "nil")")
    snapshotEditor(editor, name: "video-aspect-bars")

    pickAspect(.auto, in: editor)
    _ = click("video.background.gradient.4", in: content)
    pickAspect(.ratio(width: 1, height: 1), in: editor)
    editor.tick()
    var bg = editor.state.project.edits.background
    plan = ExportPlan(project: editor.state.project, settings: ExportSettings())
    let padded = (source.pointWidth + 2 * bg.padding) * Double(source.pixelWidth) / source.pointWidth
    check(plan.width == plan.height && plan.width == even(padded), "1:1 on a gradient is a square as wide as the padded recording",
          detail: "\(plan.width)x\(plan.height)")
    let canvas = editor.state.project.canvas
    check(abs(canvas.frame.midX - canvas.size.width / 2) <= 0.5 && abs(canvas.frame.midY - canvas.size.height / 2) <= 0.5, "the recording sits in the middle",
          detail: "\(canvas.frame) in \(canvas.size)")
    pickAspect(.ratio(width: 9, height: 16), in: editor)
    editor.tick()
    content.layoutSubtreeIfNeeded()
    let tall = editor.state.project.canvas
    check(tall.frame.width == canvas.frame.width && tall.size.height > canvas.size.height,
          "on 9:16 the recording keeps its size in points and the video grows, so at a fixed export size it shrinks", detail: "\(tall.size)")
    let small = ExportPlan(project: editor.state.project, settings: ExportSettings(resolution: .shortSide(480)))
    check(small.width == 480 && small.height == 854, "a 9:16 export at 480 is exactly 480 x 854", detail: "\(small.width)x\(small.height)")
    snapshotEditor(editor, name: "video-aspect-tall")
    snapshotEditor(editor, name: "video-aspect-tall-dark", dark: true)
    window.appearance = nil

    editor.undo()
    check(editor.state.project.edits.background.aspect == .ratio(width: 1, height: 1) && menu?.titleOfSelectedItem == "1:1", "Undo takes the shape back to 1:1")
    editor.undo()
    check(editor.state.project.edits.background.aspect == .auto && editor.state.project.edits.background.fill == .gradient(index: 4) && menu?.titleOfSelectedItem == "Auto",
          "then to Auto, one step per pick")
    editor.redo(); editor.redo()
    check(editor.state.project.edits.background.aspect == .ratio(width: 9, height: 16) && menu?.titleOfSelectedItem == "9:16", "redo brings both back")

    let before = ExportPlan(project: editor.state.project, settings: ExportSettings())
    pickAspect(.custom(width: 1, height: 1), in: editor)
    content.layoutSubtreeIfNeeded()
    let seeded = ExportPlan(project: editor.state.project, settings: ExportSettings())
    check(editor.state.project.edits.background.aspect == .custom(width: before.width, height: before.height) && width?.isHiddenOrHasHiddenAncestor == false
          && width?.stringValue == "\(before.width)" && height?.stringValue == "\(before.height)" && [seeded.width, seeded.height] == [before.width, before.height],
          "Custom starts at the video's size in pixels, so picking it changes nothing", detail: "\(editor.state.project.edits.background.aspect)")
    check(abs(frameInWindow(height).maxX - (p.minX + DS.Space.s16 + BackgroundPanel.inner)) < 0.5, "the Custom fields end on the panel's right edge")
    width?.stringValue = "1080"; width.map(fire)
    height?.stringValue = "1350"; height.map(fire)
    editor.tick()
    plan = ExportPlan(project: editor.state.project, settings: ExportSettings(resolution: .shortSide(1080)))
    check(editor.state.project.edits.background.aspect == .custom(width: 1080, height: 1350) && plan.width == 1080 && plan.height == 1350,
          "typed numbers set the shape, and Export sizes it: 1080 x 1350 at 1080", detail: "\(plan.width)x\(plan.height)")
    height?.stringValue = "99999"; height.map(fire)
    check(editor.state.project.edits.background.aspect == .custom(width: 2500, height: 9999) && height?.stringValue == "9999" && width?.stringValue == "2500",
          "a number past the limits is held to them and the fields show what the video uses", detail: "\(editor.state.project.edits.background.aspect)")
    width?.stringValue = "abc"; width.map(fire)
    check(width?.stringValue == "2500", "a field that is not a number goes back to the value in use")
    editor.undo(); editor.undo()
    check(editor.state.project.edits.background.aspect == .custom(width: 1080, height: before.height), "each typed number is one undo step",
          detail: "\(editor.state.project.edits.background.aspect)")
    editor.redo()
    snapshotEditor(editor, name: "video-aspect-custom")

    section("video editor: typing in a ratio field")
    editor.seek(to: 1.0)
    editor.splitAtPlayhead()
    let clips = editor.state.project.edits.clips.count
    if let width {
        window.makeFirstResponder(width)
        let typedBefore = (width.currentEditor() as? NSTextView)?.string
        let caught = SilentNoResponder.catching { Synth.key(window, 51, "\u{7F}") }
        let typedAfter = (width.currentEditor() as? NSTextView)?.string
        check(clips == 2 && editor.state.project.edits.clips.count == clips && typedBefore == "1080" && typedAfter == "" && caught.isEmpty,
              "Delete in a ratio field edits the number and leaves the clips alone", detail: "\(typedBefore ?? "nil") -> \(typedAfter ?? "nil") clips=\(editor.state.project.edits.clips.count) caught=\(caught)")
        (width.currentEditor() as? NSTextView)?.string = "1080"
        window.makeFirstResponder(nil)
        check(editor.state.project.edits.background.aspect == .custom(width: 1080, height: 1350), "leaving the field keeps the number")
    }
    editor.undo()
    check(editor.state.project.edits.clips.count == 1, "undo takes back the split")

    pickAspect(.auto, in: editor)
    check(editor.state.project.edits.background.aspect == .auto && width?.isHiddenOrHasHiddenAncestor == true, "Auto hides the Custom fields")
    let original = ExportPlan(project: editor.state.project, settings: ExportSettings())
    pickAspect(.custom(width: 1, height: 1), in: editor)
    check(editor.state.project.edits.background.aspect == .custom(width: original.width, height: original.height),
          "Custom from Auto starts at the video's size in pixels too", detail: "\(editor.state.project.edits.background.aspect)")

    let stored = editor.state.project
    w.coordinator.closeAllEditors()
    check(try RecordingProjectFile.read(from: folder).edits.background.aspect == stored.edits.background.aspect, "closing writes the shape to project.json")
    guard let again = w.coordinator.openVideoEditor(folder) else { return check(false, "the editor reopens") }
    bg = VideoBackground()
    again.setBackground(bg)
    w.coordinator.closeAllEditors()
}

/// Exports square and tall videos and holds each file to the preview, the way the plain export is held.
@MainActor
func checkAspectParity(_ editor: VideoEditorWindowController, frames: StillFrames, clock: ScriptedClock, root: URL) async throws {
    let cases: [(String, VideoBackground)] = [
        ("1:1 gradient", VideoBackground(fill: .gradient(index: 6), padding: 48, shadow: 70, cornerRadius: 20, aspect: .ratio(width: 1, height: 1))),
        ("9:16 gradient", VideoBackground(fill: .gradient(index: 6), padding: 48, shadow: 70, cornerRadius: 20, aspect: .ratio(width: 9, height: 16))),
        ("9:16 none", VideoBackground(fill: .none, aspect: .ratio(width: 9, height: 16))),
    ]
    for (name, bg) in cases {
        section("video export: the file matches the preview at \(name)")
        editor.setBackground(bg)
        let project = editor.state.project
        let out = root.appendingPathComponent("aspect-\(name.replacingOccurrences(of: ":", with: "x").replacingOccurrences(of: " ", with: "-")).mp4")
        let report = try await VideoExporter.export(project: project, video: editor.videoURL, settings: ExportSettings(), to: out)
        let ratio = bg.aspect.value ?? 1
        check(abs(Double(report.plan.width) / Double(report.plan.height) - ratio) < 0.002, "the file has the shape",
              detail: "\(report.plan.width)x\(report.plan.height) hardware=\(report.usesHardware)")
        let rows = await measureParity(editor, frames: frames, clock: clock, export: out, plan: report.plan, project: project, times: [0.25, 1.0, 1.75],
                                       name: "parity-\(name.replacingOccurrences(of: ":", with: "x").replacingOccurrences(of: " ", with: "-"))")
        for r in rows { print(String(format: "PARITY %@ t=%.2f preview-vs-drawn %@ | preview-vs-file %@", name, r.time, r.drawn.description, r.encoded.description)) }
        check(rows.count == 3 && rows.allSatisfy { $0.drawn.mean < 0.5 && $0.drawn.over16 < 0.001 },
              "the export draws what the preview shows, before compression", detail: rows.map { $0.drawn.description }.joined(separator: "; "))
        check(rows.count == 3 && rows.allSatisfy { $0.encoded.psnr > 35 }, "the file's frames match the preview within compression loss",
              detail: rows.map { $0.encoded.description }.joined(separator: "; "))
    }
    editor.setBackground(VideoBackground())
}

/// H.264 sides are even, as `ExportPlan` rounds them.
private func even(_ value: Double) -> Int { max(2, Int((value / 2).rounded()) * 2) }
