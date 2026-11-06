import Accelerate
import AppKit
import CornermarkCore
import CornermarkDesign
@testable import CornermarkVideoEditor
@testable import CornermarkShell

/// A project with something fast in each blur scope: a zoom closing in to 300%, a pan as it hands over to a second zoom, the
/// way out, and a pointer that sweeps the area while the camera holds still.
enum BlurScene {
    static let sweeps: [(t0: Double, t1: Double, a: (Double, Double), b: (Double, Double))] = [
        (6.0, 6.45, (0.1, 0.8), (0.9, 0.7)), (6.9, 7.3, (0.9, 0.7), (0.2, 0.4)),
    ]

    static func apply(_ project: inout RecordingProject) {
        let w = project.source.pointWidth, h = project.source.pointHeight
        var pointer = [PointerSample(t: 0, x: w * 0.1, y: h * 0.8)]
        for s in sweeps {
            for i in 0...60 {
                let u = Double(i) / 60, e = u * u * (3 - 2 * u)
                pointer.append(PointerSample(t: s.t0 + (s.t1 - s.t0) * u, x: w * (s.a.0 + (s.b.0 - s.a.0) * e), y: h * (s.a.1 + (s.b.1 - s.a.1) * e)))
            }
        }
        project.events.pointer = pointer
        project.edits.zooms = [Zoom(start: 1, end: 3, scale: 3, mode: .manual, center: ZoomPoint(x: 0.3, y: 0.35)),
                               Zoom(start: 3.3, end: 5.2, scale: 3, mode: .manual, center: ZoomPoint(x: 0.72, y: 0.62))]
    }

    /// The output frame, on the 60 fps grid, where the crop moves the most from one frame to the next inside `range`.
    static func fastestCrop(_ project: RecordingProject, in range: ClosedRange<Double>) -> Double {
        frames(range).max { cropStep(project, $0) < cropStep(project, $1) } ?? range.lowerBound
    }

    static func fastestPointer(_ project: RecordingProject, in range: ClosedRange<Double>) -> Double {
        func step(_ t: Double) -> Double {
            guard let a = frameState(project, outputTime: t).cursor, let b = frameState(project, outputTime: t + 1 / 60).cursor else { return 0 }
            return hypot(b.x - a.x, b.y - a.y)
        }
        return frames(range).max { step($0) < step($1) } ?? range.lowerBound
    }

    static func cropStep(_ project: RecordingProject, _ t: Double) -> Double {
        let a = frameState(project, outputTime: t).crop, b = frameState(project, outputTime: t + 1 / 60).crop
        return abs(a.x - b.x) + abs(a.y - b.y) + abs(a.width - b.width)
    }

    private static func frames(_ range: ClosedRange<Double>) -> [Double] {
        Array(Int((range.lowerBound * 60).rounded())...Int((range.upperBound * 60).rounded())).map { Double($0) / 60 }
    }
}

/// The samples export draws for the frame at `t`: the recording's width in the file turns movement into pixels.
func exportSamples(_ project: RecordingProject, at t: Double) -> [FrameState] {
    let plan = ExportPlan(project: project, settings: ExportSettings()), canvas = project.canvas
    return frameSamples(project, outputTime: t, fps: plan.fps, pixelsAcross: Double(plan.width) * canvas.frame.width / canvas.size.width)
}

/// Checks of other features compare the paused preview's layers with export's sharp drawing. With blur on, a paused preview on a moving
/// frame shows export's blurred drawing instead, which their measurements do not expect, so their projects start with blur off.
func turnOffBlur(in folder: URL) throws {
    var project = try RecordingProjectFile.read(from: folder)
    project.edits.motionBlur.scope = .off
    try RecordingProjectFile.write(project, to: folder)
}

/// The average of separate drawings in double precision, rounded per byte: the reference the accumulator and the file are measured against.
@MainActor
func averageOf(_ images: [CGImage]) -> CGImage? {
    guard let first = images.first else { return nil }
    let all = images.compactMap(Pix.bytes)
    guard all.count == images.count else { return nil }
    let ctx = Pix.context(first.width, first.height)
    guard let out = ctx.data?.assumingMemoryBound(to: UInt8.self), ctx.bytesPerRow == first.width * 4 else { return nil }
    let n = vDSP_Length(all[0].count)
    var sum = [Double](repeating: 0, count: all[0].count), one = sum
    for bytes in all {
        vDSP_vfltu8D(bytes, 1, &one, 1, n)
        vDSP_vaddD(one, 1, sum, 1, &sum, 1, n)
    }
    var k = 1 / Double(all.count)
    vDSP_vsmulD(sum, 1, &k, &sum, 1, n)
    vDSP_vfixru8D(sum, 1, out, 1, n)
    return ctx.makeImage()
}

@MainActor
func checkVideoMotionBlur() async throws {
    section("video editor: motion blur panel")
    let (w, _) = try recordingWorld(frames: 480)
    defer { w.cleanup() }
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
    var scripted = try RecordingProjectFile.read(from: folder)
    check(scripted.edits.motionBlur == MotionBlur(scope: .zoomsAndCursor, shutterAngle: 180), "a new recording blurs zooms and the pointer at 180°",
          detail: "\(scripted.edits.motionBlur)")
    BlurScene.apply(&scripted)
    try RecordingProjectFile.write(scripted, to: folder)
    guard let editor = w.coordinator.openVideoEditor(folder), let window = editor.window, let content = window.contentView else {
        return check(false, "the project opens")
    }
    defer { w.coordinator.closeAllEditors() }
    window.setContentSize(NSSize(width: 1200, height: 760))
    content.layoutSubtreeIfNeeded()
    await editor.ready()
    func show(_ t: Double) async {
        editor.seek(to: t)
        await decoder?.prepare(frameState(editor.state.project, outputTime: t).sourceTime)
        editor.tick()
        await editor.previewSettled()
    }

    (editor.view(identifier: "video.rail.motionBlur") as? NSButton)?.performClick(nil)
    content.layoutSubtreeIfNeeded()
    let scope = editor.view(identifier: "video.blur.scope") as? Segments
    let slider = editor.view(identifier: "video.blur.intensity") as? TrackingSlider
    let note = editor.view(identifier: "video.blur.note") as? NSTextField
    check(editor.view(identifier: "video.blur")?.isHiddenOrHasHiddenAncestor == false && scope != nil && slider != nil, "Motion Blur in the rail opens its panel")
    check((0..<(scope?.segmentCount ?? 0)).compactMap { scope?.label(forSegment: $0) } == ["Off", "Zooms", "Zooms + cursor"] && scope?.selectedSegment == 2,
          "the scope offers Off, Zooms and Zooms + cursor, with Zooms + cursor picked", detail: "\(scope?.selectedSegment ?? -1)")
    check(slider?.doubleValue == 180 && slider?.minValue == 30 && slider?.maxValue == 360 && slider?.valueText == "180°"
          && slider?.accessibilityValueDescription() == "180 degrees", "Intensity is the shutter angle, 30° to 360°, at 180°, read out in degrees",
          detail: slider?.valueText ?? "no value")
    check(note?.stringValue == MotionBlurPanel.explanation(.zoomsAndCursor), "the note says what blurs")
    let fast = BlurScene.fastestCrop(editor.state.project, in: 1.0...1.8)
    await show(fast)
    snapshotEditor(editor, name: "video-blur")
    snapshotEditor(editor, name: "video-blur-dark", dark: true)
    window.appearance = nil

    scope?.selectedSegment = 0
    if let scope { fire(scope) }
    check(editor.state.project.edits.motionBlur.scope == .off && slider?.isEnabled == false && note?.stringValue == MotionBlurPanel.explanation(.off)
          && editor.view(identifier: "video.blur.preview")?.isHidden == true, "Off turns blur off, greys Intensity and hides the note about the preview")
    snapshotEditor(editor, name: "video-blur-off")
    editor.undo()
    check(editor.state.project.edits.motionBlur.scope == .zoomsAndCursor && slider?.isEnabled == true, "Edit > Undo brings the scope back")
    for v in [200.0, 241, 272] {
        slider?.doubleValue = v
        if let slider { fire(slider) }
    }
    slider?.onTrackingEnd()
    check(editor.state.project.edits.motionBlur.shutterAngle == 270 && slider?.valueText == "270°", "a slider drag sets the angle in steps of 5°",
          detail: "\(editor.state.project.edits.motionBlur.shutterAngle)")
    editor.undo()
    check(editor.state.project.edits.motionBlur.shutterAngle == 180, "the whole drag undoes in one step")

    section("video editor: the paused preview shows motion blur")
    let pointerFast = BlurScene.fastestPointer(editor.state.project, in: 6.0...6.45)
    await show(fast)
    check(editor.previewStill != nil, String(format: "paused on the fast zoom at %.3f s the preview shows the blurred frame", fast))
    let stillSize = editor.previewStill.map { "\($0.width)x\($0.height)" } ?? "none"
    await show(pointerFast)
    check(editor.previewStill != nil, String(format: "paused on the fast pointer at %.3f s too", pointerFast))
    await show(0.5)
    check(editor.previewStill == nil, "a frame where nothing moves shows the sharp layers")
    if let timeline = editor.view(identifier: "video.timeline") as? TimelineView {
        timeline.onScrub(0.6, .began)
        await decoder?.prepare(frameState(editor.state.project, outputTime: fast).sourceTime)
        timeline.onScrub(fast, .moved)
        let during = editor.previewStill
        timeline.onScrub(fast, .ended)
        await editor.previewSettled()
        check(during == nil && editor.previewStill != nil, "dragging on the ruler shows sharp frames; letting go on a moving frame shows the blurred one")
    } else { check(false, "the timeline is found") }
    await show(fast)
    var timings: [Double] = [], mainThread: [Double] = []
    for angle in [185.0, 190, 195, 200, 180] {
        var b = editor.state.project.edits.motionBlur
        b.shutterAngle = angle
        let started = Date()
        editor.setMotionBlur(b)
        mainThread.append(Date().timeIntervalSince(started) * 1000)
        await editor.previewSettled()
        timings.append(editor.stillMilliseconds ?? -1)
    }
    print(String(format: "BLURPREVIEW still=%@ drawing ms median=%.1f max=%.1f, main thread per change ms median=%.1f max=%.1f", stillSize,
                 timings.sorted()[timings.count / 2], timings.max() ?? 0, mainThread.sorted()[mainThread.count / 2], mainThread.max() ?? 0))
    editor.togglePlayback()
    clock.now += 1 / 60
    editor.tick()
    check(editor.state.transport.isPlaying && editor.previewStill == nil, "playing shows the sharp frame")
    editor.togglePlayback()
    var off = editor.state.project.edits.motionBlur
    off.scope = .off
    editor.setMotionBlur(off)
    await show(fast)
    check(editor.previewStill == nil, "with blur off the paused preview is the sharp layers")

    section("video export: motion blur render time")
    let base = editor.state.project
    var files: [String: (URL, ExportReport, RecordingProject)] = [:]
    for (name, blur) in [("off", MotionBlur(scope: .off)), ("180", MotionBlur()), ("360", MotionBlur(shutterAngle: 360))] {
        var p = base
        p.edits.motionBlur = blur
        let out = w.root.appendingPathComponent("blur-\(name).mp4")
        let r = try await VideoExporter.export(project: p, video: editor.videoURL, settings: ExportSettings(), to: out)
        files[name] = (out, r, p)
        print(String(format: "BLURPERF %@ %dx%d frames=%d blurred=%d drawings=%d render=%.2fs per-frame=%.1fms hardware=%@", name, r.plan.width, r.plan.height,
                     r.framesWritten, r.blurredFrames, r.drawings, r.renderSeconds, r.renderSeconds / Double(r.framesWritten) * 1000, r.usesHardware ? "yes" : "no"))
    }
    if let a = files["off"]?.1, let b = files["180"]?.1, let c = files["360"]?.1 {
        check(a.blurredFrames == 0 && a.drawings == a.framesWritten, "blur off draws each frame once")
        check(b.blurredFrames > 0 && b.drawings >= b.framesWritten + b.blurredFrames * 7 && c.drawings >= c.framesWritten + c.blurredFrames * 15
              && b.drawings <= b.framesWritten + b.blurredFrames * (MotionBlur.maxSamples - 1),
              "180° draws at least 8 moments and 360° at least 16 for each moving frame, at most 64, still frames once",
              detail: "180: \(b.blurredFrames)/\(b.drawings), 360: \(c.blurredFrames)/\(c.drawings)")
        for (name, r) in [("180", b), ("360", c)] {
            print(String(format: "BLURSAMPLES %@ mean per moving frame=%.1f", name, Double(r.drawings - r.framesWritten + r.blurredFrames) / Double(max(r.blurredFrames, 1))))
        }
    }

    section("video export: blurred frames match the accumulation reference")
    for name in ["180", "360"] {
        guard let (out, report, p) = files[name] else { continue }
        let renderer = ExportFrameRenderer(plan: report.plan, project: p, folder: folder)
        for (kind, t) in [("zoom", fast), ("pan", BlurScene.fastestCrop(p, in: 2.9...3.6)), ("pointer", pointerFast), ("still", 0.5)] {
            let samples = frameSamples(p, outputTime: t, fps: report.plan.fps, pixelsAcross: renderer.frameRect.width)
            guard let source = await decodedFrame(editor.videoURL, at: samples[0].sourceTime),
                  let reference = averageOf(samples.compactMap { renderer.image($0, source: source) }),
                  let accumulated = renderer.image(samples, source: source), let sharp = renderer.image(samples[0], source: source),
                  let file = await decodedFrame(out, at: t),
                  let acc = PixelDifference(accumulated, reference, edge: 0), let enc = PixelDifference(file, reference, edge: 4),
                  let vsSharp = PixelDifference(file, sharp, edge: 4) else { check(false, "\(kind) frame at \(name)° could be measured"); continue }
            for (label, image) in [("reference", reference), ("file", file), ("sharp", sharp)] {
                if let png = AssetStore.pngData(from: image) { try? png.write(to: URL(fileURLWithPath: scratch + String(format: "blur-%@-%@-%@.png", name, kind, label))) }
            }
            print(String(format: "BLURPARITY %@° %@ t=%.3f samples=%d accumulator-vs-reference %@ | file-vs-reference %@ | file-vs-sharp %@", name, kind, t,
                         samples.count, acc.description, enc.description, vsSharp.description))
            // A frame whose crop moves is averaged on the GPU, whose sampler differs from Core Graphics by a few levels at sharp edges.
            check(acc.max <= 8 && acc.over16 == 0 && acc.psnr > 55, "\(name)° \(kind): the accumulator is the plain average of its drawings", detail: acc.description)
            check(enc.psnr > 35, "\(name)° \(kind): the file's frame is the reference within compression loss", detail: enc.description)
            if kind == "still" {
                check(samples.count == 1, "\(name)° still: a still frame is drawn once")
            } else {
                check(samples.count > 1 && vsSharp.mean > enc.mean, "\(name)° \(kind): the file is closer to the blurred reference than to the sharp frame",
                      detail: "sharp \(vsSharp.description) vs reference \(enc.description)")
            }
        }
    }

    section("video export: with blur off the file matches the preview")
    if let decoder, let (out, report, p) = files["off"] {
        editor.setMotionBlur(p.edits.motionBlur)
        let rows = await measureParity(editor, frames: decoder, clock: clock, export: out, plan: report.plan, project: p, times: [fast, pointerFast, 0.5],
                                       name: "parity-blur-off")
        for r in rows { print(String(format: "PARITY blur-off t=%.3f preview-vs-drawn %@ | preview-vs-file %@", r.time, r.drawn.description, r.encoded.description)) }
        check(rows.count == 3 && rows.allSatisfy { $0.drawn.mean < 0.5 && $0.drawn.over16 < 0.001 }, "with blur off the preview draws what export draws",
              detail: rows.map { $0.drawn.description }.joined(separator: "; "))
        check(rows.count == 3 && rows.allSatisfy { $0.encoded.psnr > 35 }, "with blur off the file matches the preview within compression loss",
              detail: rows.map { $0.encoded.description }.joined(separator: "; "))
    }
}
