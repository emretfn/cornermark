import AppKit
import AVFoundation
import CornermarkCore
import CornermarkDesign
@testable import CornermarkVideoEditor
@testable import CornermarkShell

/// How far apart two pictures of one size are, over RGB, leaving out a band at the edges where the preview draws its outline.
struct PixelDifference: CustomStringConvertible {
    var mean = 0.0
    var max = 0
    var over16 = 0.0
    var psnr = 0.0

    var description: String { String(format: "mean=%.3f max=%d over16=%.4f%% psnr=%.1fdB", mean, max, over16 * 100, psnr) }

    init?(_ a: CGImage, _ b: CGImage, edge: Int) {
        let w = a.width, h = a.height
        guard b.width == w, b.height == h, let pa = Pix.bytes(a), let pb = Pix.bytes(b) else { return nil }
        var sum = 0.0, squares = 0.0, count = 0, over = 0, pixels = 0
        for y in edge..<(h - edge) {
            for x in edge..<(w - edge) {
                let i = (y * w + x) * 4
                var loud = false
                for c in 0..<3 {
                    let d = abs(Int(pa[i + c]) - Int(pb[i + c]))
                    sum += Double(d); squares += Double(d * d); count += 1
                    max = Swift.max(max, d)
                    if d > 16 { loud = true }
                }
                pixels += 1
                if loud { over += 1 }
            }
        }
        mean = sum / Double(Swift.max(count, 1))
        over16 = Double(over) / Double(Swift.max(pixels, 1))
        let mse = squares / Double(Swift.max(count, 1))
        psnr = mse == 0 ? 99 : 10 * log10(255 * 255 / mse)
    }
}

extension Pix {
    static func bytes(_ image: CGImage) -> [UInt8]? {
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4, space: Pix.space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let data = ctx.data else { return nil }
        return Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: image.width * 4 * image.height))
    }
}

@MainActor
func previewFrame(_ editor: VideoEditorWindowController, size: CGSize) -> CGImage? {
    guard let preview = editor.view(identifier: "video.preview") as? PreviewView else { return nil }
    preview.layoutSubtreeIfNeeded()
    guard let picture = preview.layer?.sublayers?.first else { return nil }
    let ctx = Pix.context(Int(size.width), Int(size.height))
    ctx.scaleBy(x: size.width / picture.bounds.width, y: size.height / picture.bounds.height)
    picture.render(in: ctx)
    return ctx.makeImage()
}

func decodedFrame(_ url: URL, at time: Double) async -> CGImage? {
    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = .zero
    return try? await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image
}

/// The parity of one moment: the preview against the export's own drawing before compression, and against the frame in the file.
struct ParityRow {
    var time: Double
    var drawn: PixelDifference
    var encoded: PixelDifference
}

@MainActor
func measureParity(_ editor: VideoEditorWindowController, frames: StillFrames, clock: ScriptedClock, export: URL, plan: ExportPlan, project: RecordingProject,
                   times: [Double], name: String = "parity") async -> [ParityRow] {
    var rows: [ParityRow] = []
    let renderer = ExportFrameRenderer(plan: plan, project: project, folder: editor.folder)
    let size = CGSize(width: plan.width, height: plan.height)
    for t in times {
        editor.seek(to: t)
        let state = frameState(project, outputTime: t)
        await frames.prepare(state.sourceTime)
        editor.tick()
        guard let preview = previewFrame(editor, size: size), let source = await decodedFrame(editor.videoURL, at: state.sourceTime),
              let drawn = renderer.image(state, source: source), let file = await decodedFrame(export, at: t),
              let a = PixelDifference(preview, drawn, edge: 4), let b = PixelDifference(preview, file, edge: 4) else { continue }
        for (kind, image) in [("preview", preview), ("drawn", drawn), ("file", file)] {
            let url = URL(fileURLWithPath: scratch + String(format: "%@-%.2f-%@.png", name, t, kind))
            if let png = AssetStore.pngData(from: image) { try? png.write(to: url) }
        }
        rows.append(ParityRow(time: t, drawn: a, encoded: b))
    }
    return rows
}

@MainActor
func checkVideoExport() async throws {
    section("video export: panel")
    let (w, _) = try recordingWorld(frames: 120)
    defer { w.cleanup() }
    let c = w.coordinator
    let clock = ScriptedClock()
    var decoders: [URL: StillFrames] = [:]
    c.makeVideoEditor = { folder in
        let project = try RecordingProjectFile.read(from: folder)
        let decoder = StillFrames(url: folder.appendingPathComponent(project.source.video))
        decoders[folder] = decoder
        return VideoEditorWindowController(folder: folder, project: project, frames: decoder, clock: { clock.now })
    }
    guard let recorded = await recordOnce(w, "display=1&x=0&y=0&width=640&height=360"), let folder = recorded.video?.location,
          let editor = c.openVideoEditor(folder), let window = editor.window, let content = window.contentView else {
        return check(false, "a project is recorded and opens in the editor")
    }
    defer { c.closeAllEditors() }
    window.setContentSize(NSSize(width: 1200, height: 760))
    content.layoutSubtreeIfNeeded()
    await editor.ready()

    if let decoder = decoders.values.first {
        await decoder.prepare(frameState(editor.state.project, outputTime: 0).sourceTime)
        editor.tick()
    }
    let export = editor.view(identifier: "video.export") as? Button
    let e = frameInWindow(export)
    check(export?.variant == .primary && e.maxX == content.bounds.width - DS.Space.s12 && e.maxY > frameInWindow(editor.view(identifier: "video.preview")).maxY,
          "Export is the view's primary button, top right above the preview", detail: "\(e)")
    func primaries() -> Int {
        func walk(_ v: NSView) -> Int { (v.isHiddenOrHasHiddenAncestor ? 0 : ((v as? Button)?.variant == .primary ? 1 : 0)) + v.subviews.map(walk).reduce(0, +) }
        return walk(content)
    }
    check(primaries() == 1, "one filled accent button in the editor", detail: "\(primaries())")
    check(editor.view(identifier: "video.export.panel")?.isHidden == true, "the export panel starts closed")

    export?.performClick(nil)
    let panel = editor.view(identifier: "video.export.panel")
    check(editor.state.export == .choosing && panel?.isHidden == false, "Export opens the panel")
    check(window.firstResponder === editor.view(identifier: "video.export.resolution"), "keyboard focus moves into the panel, on Resolution",
          detail: "\(String(describing: window.firstResponder))")
    check((editor.view(identifier: "video.export.quality") as? NSSlider)?.accessibilityValueDescription() == "High", "the quality slider reads its step by name")
    check(primaries() == 1 && export?.variant == .secondary, "with the panel open its own Export is the primary action and the header's steps back")
    let p = frameInWindow(panel)
    check(abs(p.maxX - ExportPanel.inset - e.maxX) < 0.5 && p.maxY - ExportPanel.inset <= e.minY, "the panel hangs under the button, edges aligned", detail: "\(p) \(e)")
    let resolution = editor.view(identifier: "video.export.resolution") as? NSPopUpButton
    let quality = editor.view(identifier: "video.export.quality") as? NSSlider
    let estimate = editor.view(identifier: "video.export.estimate") as? NSTextField
    let details = editor.view(identifier: "video.export.details") as? NSTextField
    check(resolution?.itemTitles == ["1280 \u{00D7} 720 (Original)", "854 \u{00D7} 480"], "Resolution offers the original and each smaller standard size",
          detail: "\(resolution?.itemTitles ?? [])")
    let project = editor.state.project
    let high = ExportPlan(project: project, settings: ExportSettings(), video: editor.videoURL)
    check(quality?.doubleValue == 2 && estimate?.stringValue == "About \(ExportPanel.bytes(high.estimatedBytes))",
          "Quality starts at High and the panel estimates the file size", detail: estimate?.stringValue ?? "nil")
    check(details?.stringValue == "1280 \u{00D7} 720, 60 fps, 0:02.00, H.264", "the panel says the size, rate, length and codec it will write", detail: details?.stringValue ?? "nil")
    resolution?.selectItem(at: 1)
    if let resolution { fire(resolution) }
    quality?.doubleValue = 0
    if let quality { fire(quality) }
    let small = ExportPlan(project: project, settings: ExportSettings(resolution: .shortSide(480), quality: .low), video: editor.videoURL)
    check(editor.state.exportSettings == ExportSettings(resolution: .shortSide(480), quality: .low) && estimate?.stringValue == "About \(ExportPanel.bytes(small.estimatedBytes))"
          && small.estimatedBytes < high.estimatedBytes, "a smaller size and lower quality shrink the estimate", detail: estimate?.stringValue ?? "nil")
    _ = click("video.export.cancel", in: content)
    check(editor.state.export == .closed && panel?.isHidden == true && export?.variant == .primary, "Cancel closes the panel and Export is primary again")
    check(window.firstResponder === export, "closing the panel gives focus back to Export")
    snapshotEditor(editor, name: "video-export-closed")

    section("video export: progress and the file")
    editor.setCursor(CursorSettings(isVisible: true, scale: 3))
    editor.openExport()
    editor.setExportSettings(ExportSettings())
    content.layoutSubtreeIfNeeded()
    snapshotEditor(editor, name: "video-export-panel")
    snapshotEditor(editor, name: "video-export-panel-dark", dark: true)
    window.appearance = nil
    let before = Set(w.store.list().map(\.id))
    var fractions: [Double] = []
    editor.startExport()
    check(try RecordingProjectFile.read(from: folder).edits.cursor.scale == 3, "Export writes the editor's unsaved edits to the project first")
    check(editor.view(identifier: "video.export.resolution")?.isHiddenOrHasHiddenAncestor == true && export?.isEnabled == false
          && (editor.view(identifier: "video.export.title") as? NSTextField)?.stringValue == "Exporting video",
          "while exporting the panel shows the progress and the header's Export waits")
    var shot = false
    let finished = await waitUntil(30) {
        if case .exporting(let f) = editor.state.export { fractions.append(f) }
        if !shot, case .exporting(let f) = editor.state.export, f > 0.3 {
            content.layoutSubtreeIfNeeded()
            snapshotEditor(editor, name: "video-export-progress")
            shot = true
        }
        return editor.state.export == .closed && w.store.list().count > before.count
    }
    check(finished && fractions == fractions.sorted(), "the export finishes and its progress only grows", detail: "\(fractions.count) readings")
    let percent = (editor.view(identifier: "video.export.percent") as? NSTextField)?.stringValue
    check(percent == "100%" || percent?.hasSuffix("%") == true, "the percent readout follows the progress", detail: percent ?? "nil")
    guard let made = w.store.list().first(where: { !before.contains($0.id) }), let video = made.video else { return check(false, "the export is listed in History") }
    check(made.ownsVideo && video.format == .video && video.file.lastPathComponent == "\(RecordingProjectFile.displayName(of: folder)).mp4",
          "the export is a History entry holding its own file, named after the recording", detail: video.file.path)
    let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: w.store.incomingDirectory.path)) ?? []
    check(leftovers.isEmpty, "nothing is left where the export was written", detail: "\(leftovers)")
    let facts = await fileFacts(video.file)
    let fileSeconds = (try? await AVURLAsset(url: video.file).load(.duration).seconds) ?? 0
    check(facts?.width == 1280 && facts?.height == 720 && facts?.frames == 120 && abs(fileSeconds - project.source.duration) < 1.0 / 60,
          "the file is 1280 x 720 with 120 frames and as long as the project", detail: "\(String(describing: facts)) \(fileSeconds) s vs \(project.source.duration) s")
    let probe = try VideoExporter.probeEncoder(plan: high)
    check(probe.usesHardware, "VideoToolbox reports the hardware encoder for this size", detail: probe.encoderID)
    let bytes = ((try? FileManager.default.attributesOfItem(atPath: video.file.path))?[.size] as? NSNumber)?.int64Value ?? 0
    print(String(format: "EXPORT size=%dx%d frames=%d seconds=%.3f bytes=%lld estimatedBytes=%lld ratio=%.2f encoder=%@ hardware=%@",
                 high.width, high.height, facts?.frames ?? 0, fileSeconds, bytes, high.estimatedBytes, Double(bytes) / Double(high.estimatedBytes),
                 probe.encoderID, probe.usesHardware ? "true" : "false"))

    section("video export: size estimate")
    var ratios: [Double] = []
    for resolution in ExportResolution.choices(for: project) {
        for q in ExportQuality.allCases {
            let settings = ExportSettings(resolution: resolution, quality: q)
            let out = w.root.appendingPathComponent("estimate-\(ratios.count).mp4")
            let report = try await VideoExporter.export(project: project, video: editor.videoURL, settings: settings, to: out)
            let ratio = Double(report.bytes) / Double(report.plan.estimatedBytes)
            ratios.append(ratio)
            print(String(format: "ESTIMATE %dx%d %@ estimated=%lld actual=%lld actual/estimated=%.2f ceiling=%lld renderSeconds=%.3f hardware=%@",
                         report.plan.width, report.plan.height, q.title, report.plan.estimatedBytes, report.bytes, ratio,
                         Int64(Double(report.plan.bitRate) * report.plan.duration / 8), report.renderSeconds, report.usesHardware ? "true" : "false"))
        }
    }
    check(ratios.allSatisfy { $0 > 0.5 && $0 < 2 }, "every estimate is within a factor of two of the file it predicted", detail: ratios.map { String(format: "%.2f", $0) }.joined(separator: " "))

    section("video export: Quick Access card")
    guard let card = c.overlay.card(forRecord: made.id) else { return check(false, "the export gets a Quick Access card") }
    check(card.actions == [.copy, .save, .play, .close], "the card offers Copy, Save, Play and Close", detail: "\(card.actions)")
    check(card.info == "0:02  \u{00B7}  \(ImageOutput.byteText(bytes))", "the card shows the duration and the file size", detail: card.info)
    if let view = c.overlay.cardView(for: card), let cardPanel = c.overlay.panel(for: card) {
        view.mouseEntered(with: Synth.enterExit(.mouseEntered, in: cardPanel))
        check(click("card.copy", in: view), "Copy is pressed")
        check((w.pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL]) == [video.file], "Copy puts the exported file on the pasteboard")
        check(click("card.save", in: view), "Save is pressed")
        let saved = c.settings.value.resolvedSaveFolder(default: w.env.defaultSaveFolder).appendingPathComponent(video.file.lastPathComponent)
        check(FileManager.default.contentsEqual(atPath: saved.path, andPath: video.file.path) && c.hud.lastMessage == "Saved \(saved.lastPathComponent)",
              "Save copies the export into the save folder and says so", detail: c.hud.lastMessage ?? "nil")
        check(click("card.play", in: view) && w.opened.last == video.file, "Play opens the exported file")
    } else { check(false, "the card has a view") }

    section("video export: the file matches the preview")
    if let frames = decoders[folder.standardizedFileURL.resolvingSymlinksInPath()] ?? decoders.values.first {
        let rows = await measureParity(editor, frames: frames, clock: clock, export: video.file, plan: high, project: editor.state.project, times: [0.25, 1.0, 1.75])
        for r in rows { print(String(format: "PARITY t=%.2f preview-vs-drawn %@ | preview-vs-file %@", r.time, r.drawn.description, r.encoded.description)) }
        check(rows.count == 3 && rows.allSatisfy { $0.drawn.mean < 0.5 && $0.drawn.over16 < 0.001 },
              "the export draws what the preview shows, before compression", detail: rows.map { $0.drawn.description }.joined(separator: "; "))
        check(rows.count == 3 && rows.allSatisfy { $0.encoded.psnr > 35 }, "the file's frames match the preview within compression loss",
              detail: rows.map { $0.encoded.description }.joined(separator: "; "))
        try await checkTrimmedExport(editor, frames: frames, clock: clock, root: w.root)
    } else { check(false, "the harness decoder is known") }
    if let frames = decoders[folder.standardizedFileURL.resolvingSymlinksInPath()] ?? decoders.values.first {
        try await checkBackgroundParity(editor, frames: frames, clock: clock, root: w.root)
    }

    section("video export: cancel")
    let listed = w.store.list().count
    editor.openExport()
    editor.startExport()
    let midway = await waitUntil(10) { if case .exporting(let f) = editor.state.export { return f > 0.2 } else { return false } }
    content.layoutSubtreeIfNeeded()
    _ = click("video.export.cancel", in: content)
    let stopped = await waitUntil(10) { editor.state.export == .choosing }
    check(midway && stopped, "Cancel during the export stops it and returns to the choices")
    _ = await waitUntil(1) { false }
    check(w.store.list().count == listed, "a cancelled export lists nothing")
    let left = (try? FileManager.default.contentsOfDirectory(atPath: w.store.incomingDirectory.path)) ?? []
    check(left.isEmpty, "a cancelled export leaves no file, partial or whole", detail: "\(left)")

    section("video export: closing the window")
    editor.startExport()
    _ = await waitUntil(10) { if case .exporting(let f) = editor.state.export { return f > 0.1 } else { return false } }
    window.close()
    _ = await waitUntil(5) { (try? FileManager.default.contentsOfDirectory(atPath: w.store.incomingDirectory.path))?.isEmpty ?? true }
    _ = await waitUntil(1) { false }
    check(w.store.list().count == listed && ((try? FileManager.default.contentsOfDirectory(atPath: w.store.incomingDirectory.path)) ?? []).isEmpty,
          "closing the editor stops its export and leaves no file")

    section("video export: by link")
    let link = URL(string: "\(URLCommand.scheme)://edit-recording?path=\(folder.path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!)&export=1")!
    if case .success(.exportRecording) = URLCommand.parse(link) { check(true, "an edit-recording link with export=1 asks for an export") } else {
        check(false, "an edit-recording link with export=1 asks for an export", detail: "\(URLCommand.parse(link))")
    }
    let count = w.store.list().count
    check(c.handle(url: link), "the export link is handled")
    check(await waitUntil(30) { w.store.list().count == count + 1 }, "the link opens the editor and exports with the default choices")
}

@MainActor
private func checkTrimmedExport(_ editor: VideoEditorWindowController, frames: StillFrames, clock: ScriptedClock, root: URL) async throws {
    section("video export: a trimmed project")
    editor.seek(to: 0.5)
    editor.splitAtPlayhead()
    editor.seek(to: 1)
    editor.splitAtPlayhead()
    editor.selectClip(1)
    editor.deleteClip()
    let project = editor.state.project
    check(project.edits.clips == [Clip(start: 0, end: 0.5), Clip(start: 1, end: 2)] && editor.state.transport.duration == 1.5,
          "two splits and a delete leave 0 to 0.5 s and 1 to 2 s of the recording", detail: "\(project.edits.clips)")
    let out = root.appendingPathComponent("trimmed.mp4")
    let report = try await VideoExporter.export(project: project, video: editor.videoURL, settings: ExportSettings(), to: out)
    let facts = await fileFacts(out)
    print(String(format: "TRIMMED frames=%d seconds=%.4f planFrames=%d clips=0-0.5,1-2 renderSeconds=%.3f", facts?.frames ?? 0, report.duration,
                 report.plan.frameCount, report.renderSeconds))
    check(facts?.frames == 90 && abs(report.duration - 1.5) < 1.0 / 60, "the file is 90 frames, 1.5 s: what the clips keep",
          detail: "\(String(describing: facts)) \(report.duration) s")
    var ok = true
    let renderer = ExportFrameRenderer(plan: report.plan, project: project, folder: nil)
    let cases: [(output: Double, source: Double, skipped: Double)] = [(29.0 / 60, 29.0 / 60, 59.0 / 60), (0.5, 1.0, 0.5), (31.0 / 60, 61.0 / 60, 31.0 / 60)]
    for (output, source, skipped) in cases {
        let state = frameState(project, outputTime: output)
        guard let file = await decodedFrame(out, at: output), let right = await decodedFrame(editor.videoURL, at: source).flatMap({ renderer.image(state, source: $0) }),
              let wrong = await decodedFrame(editor.videoURL, at: skipped).flatMap({ renderer.image(state, source: $0) }),
              let a = PixelDifference(file, right, edge: 4), let b = PixelDifference(file, wrong, edge: 4) else { ok = false; continue }
        print(String(format: "CUTFRAME output=%.4f source=%.4f vs-source %@ | vs-%.4f %@", output, source, a.description, skipped, b.description))
        for (kind, image) in [("file", file), ("source", right)] {
            if let png = AssetStore.pngData(from: image) { try? png.write(to: URL(fileURLWithPath: scratch + String(format: "cut-%.4f-%@.png", output, kind))) }
        }
        ok = ok && a.psnr > 35 && b.psnr < a.psnr - 10
    }
    check(ok, "each side of the cut is its own source frame: frame 29 before it, frame 60 at it, frame 61 after it, and not the frames the cut removed")
    let rows = await measureParity(editor, frames: frames, clock: clock, export: out, plan: report.plan, project: project, times: [0.25, 0.49, 0.5, 1.2],
                                   name: "parity-trimmed")
    for r in rows { print(String(format: "PARITY trimmed t=%.2f preview-vs-drawn %@ | preview-vs-file %@", r.time, r.drawn.description, r.encoded.description)) }
    check(rows.count == 4 && rows.allSatisfy { $0.drawn.mean < 0.5 && $0.drawn.over16 < 0.001 }, "trimmed: the export draws what the preview shows at and around the cut",
          detail: rows.map { $0.drawn.description }.joined(separator: "; "))
    check(rows.count == 4 && rows.allSatisfy { $0.encoded.psnr > 35 }, "trimmed: the file's frames match the preview within compression loss",
          detail: rows.map { $0.encoded.description }.joined(separator: "; "))
    editor.undo()
    editor.undo()
    editor.undo()
    check(editor.state.project.edits.clips.count == 1, "undo puts the project back to one clip")
}
