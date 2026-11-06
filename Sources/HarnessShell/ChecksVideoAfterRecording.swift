import AppKit
import AVFoundation
import CornermarkCapture
import CornermarkCore
import CornermarkDesign
@testable import CornermarkVideoEditor
@testable import CornermarkShell

/// A project with everything the editor can change after recording: the synthetic camera in camera.mp4, the scripted microphone and
/// system sound in mic.m4a and system.m4a, and every key of the input tour. Frames, camera pictures and sound are all scripted, so
/// nothing real is opened and the files are the same on every run.
@MainActor
final class AfterRecordingWorld {
    static let area = "display=1&x=0&y=0&width=1280&height=720"
    let manual: ManualRecordingWorld
    var world: World { manual.world }
    private(set) var cameras: [ScriptedCameraSource] = []

    init() throws {
        manual = try ManualRecordingWorld()
        let w = manual.world
        w.env.cameraAccess = { .allowed }
        w.env.cameraSource = { [unowned self] in
            let camera = ScriptedCameraSource(pacing: .manual(origin: 0))
            cameras.append(camera)
            return camera
        }
        w.env.microphones = { ScriptedAudioSource.microphones }
        w.env.microphoneAccess = { .allowed }
        w.env.microphoneSource = { id in ScriptedAudioSource.microphone(id, pacing: .fixed(origin: 0, seconds: 10)) }
        w.env.systemAudioSource = { _ in ScriptedAudioSource(pattern: .systemTour, pacing: .fixed(origin: 0, seconds: 10)) }
        w.env.pointerSource = { ScriptedPointerSource(pacing: .fixed(origin: 0, count: 300)) }
        w.env.inputSource = { ScriptedInputSource(capture: $0, pacing: .fixed(origin: 0, seconds: 10)) }
        w.env.hasInputPermission = { true }
        w.settings.update {
            $0.recording.camera.isVisible = true
            $0.recording.keystrokes = KeystrokeDisplay(isVisible: true, keys: .all)
            $0.recording.audio.microphone = true
            $0.recording.audio.systemAudio = true
        }
    }

    /// Records `seconds` for editing, a frame of the display and a camera picture at a time, and returns the project folder.
    func record(seconds: Double = 5.2, step: () async -> Void = {}) async -> URL? {
        let before = Set(world.store.list().map(\.id))
        guard manual.link("record?\(Self.area)"), await waitUntil(5, { manual.phase == .recording }) else { return nil }
        for _ in 0..<Int(seconds * 30) {
            try? manual.source?.advance(2)
            cameras.last?.advance(1)
            try? await Task.sleep(nanoseconds: 4_000_000)
            await step()
        }
        _ = manual.link("record/stop")
        guard await waitUntil(15, { manual.phase == .idle && world.store.list().count > before.count }) else { return nil }
        return world.store.list().first { !before.contains($0.id) }?.video?.location
    }
}

/// The sound of a file as RMS over all its samples, decoded to 48 kHz float stereo. Nothing is played.
struct SoundLevel: CustomStringConvertible {
    var rms: Double
    var peak: Double
    var seconds: Double
    var dBFS: Double { rms > 0 ? 20 * log10(rms) : -.infinity }
    var description: String { String(format: "rms=%.5f (%.2f dBFS) peak=%.4f seconds=%.3f", rms, dBFS, peak, seconds) }

    static func read(_ url: URL, from: Double = 0, to: Double? = nil) async -> SoundLevel? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first, let reader = try? AVAssetReader(asset: asset) else { return nil }
        if let to { reader.timeRange = CMTimeRange(start: CMTime(seconds: from, preferredTimescale: 48_000), end: CMTime(seconds: to, preferredTimescale: 48_000)) }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false,
        ])
        reader.add(output)
        guard reader.startReading() else { return nil }
        var squares = 0.0, count = 0, peak = 0.0
        while let sample = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var floats = [Float](repeating: 0, count: length / 4)
            _ = floats.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
            for f in floats { squares += Double(f * f); peak = max(peak, Double(abs(f))) }
            count += floats.count
        }
        guard count > 0 else { return nil }
        return SoundLevel(rms: (squares / Double(count)).squareRoot(), peak: peak, seconds: Double(count / 2) / 48_000)
    }
}

/// Pixels of `a` that differ from `b` by more than 24 on any channel, inside `rect` (pixels, y down), as a share of the rect.
func changedShare(_ a: CGImage, _ b: CGImage, in rect: CGRect) -> Double {
    guard a.width == b.width, a.height == b.height, let pa = Pix.bytes(a), let pb = Pix.bytes(b) else { return -1 }
    let r = rect.integral.intersection(CGRect(x: 0, y: 0, width: a.width, height: a.height))
    var changed = 0, total = 0
    for y in Int(r.minY)..<Int(r.maxY) {
        for x in Int(r.minX)..<Int(r.maxX) {
            let i = (y * a.width + x) * 4
            total += 1
            if (0..<3).contains(where: { abs(Int(pa[i + $0]) - Int(pb[i + $0])) > 24 }) { changed += 1 }
        }
    }
    return total == 0 ? 0 : Double(changed) / Double(total)
}

/// One editor of the project with still frames for the picture and the camera, opened through the coordinator as the app does.
@MainActor
final class AfterRecordingEditor {
    let clock = ScriptedClock()
    var video: StillFrames?
    var camera: StillFrames?

    init(_ w: World) {
        w.coordinator.makeVideoEditor = { [unowned self] folder in
            let project = try RecordingProjectFile.read(from: folder)
            let decoder = StillFrames(url: folder.appendingPathComponent(project.source.video), hasAudio: !project.source.audioTracks.isEmpty)
            let editor = VideoEditorWindowController(folder: folder, project: project, frames: decoder, clock: { [unowned self] in clock.now })
            if let name = project.source.camera {
                let pictures = StillFrames(url: folder.appendingPathComponent(name))
                editor.cameraFrames = pictures
                camera = pictures
            }
            video = decoder
            return editor
        }
    }

    /// Decodes the frames at the playhead and ticks the editor.
    func settle(_ editor: VideoEditorWindowController) async {
        let t = frameState(editor.state.project, outputTime: editor.state.transport.time(at: clock.now)).sourceTime
        await video?.prepare(t)
        await camera?.prepare(t)
        editor.tick()
    }
}

@MainActor
func checkVideoAfterRecording() async throws {
    section("video editor: camera, keystrokes and sound after recording")
    let stage = try AfterRecordingWorld()
    let w = stage.world
    defer { w.cleanup() }
    let opener = AfterRecordingEditor(w)
    guard let folder = await stage.record(), let original = try? RecordingProjectFile.read(from: folder) else {
        return check(false, "a project with a camera, keystrokes and sound is recorded")
    }
    let files = Set((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
    check(files == ["screen.mp4", "camera.mp4", "mic.m4a", "system.m4a", "project.json"] && original.events.keys.count == 7,
          "the project holds the camera, both sound tracks and the seven keys of the tour", detail: "\(files.sorted()) keys \(original.events.keys.count)")
    let screenHash = sha256OrUnreadable(folder.appendingPathComponent("screen.mp4"))

    let live = try VideoEditorWindowController.open(folder: folder)
    await live.ready()
    live.setVolume(1)
    live.setMuted(false)
    let player = live.sourceFrames as? PlayerFrames
    check(player?.soundTrackCount == 2 && player?.hasAudio == true, "the live preview lays mic.m4a and system.m4a beside the picture, so it can play the project's sound",
          detail: "tracks \(player?.soundTrackCount ?? -1)")
    check(!live.playsSound && player?.player.isMuted == true && live.sourceFrames.isSilent, "an editor nobody turned sound on for keeps its player muted at full volume")
    check(player?.player.rate == 0, "and the harness never starts it")
    live.window?.close()

    guard let editor = w.coordinator.openVideoEditor(folder), let window = editor.window else { return check(false, "the project opens in the editor") }
    defer { w.coordinator.closeAllEditors() }
    check(!editor.playsSound, "the coordinator turns sound on only for an editor on screen, so an offscreen run is silent")
    window.setContentSize(NSSize(width: 1200, height: 760))
    window.contentView?.layoutSubtreeIfNeeded()
    await editor.ready()
    await opener.settle(editor)
    let note = editor.view(identifier: "video.panel.note")

    editor.select(.audio)
    check(note?.isHidden == true && editor.view(identifier: "video.audio")?.isHidden == false
          && editor.view(identifier: "video.audio.microphone")?.isHidden == false && editor.view(identifier: "video.audio.systemAudio")?.isHidden == false,
          "Audio no longer says there is no sound: it shows the microphone and system audio, each with a level")
    editor.select(.camera)
    check(note?.isHidden == true && editor.view(identifier: "video.camera")?.isHidden == false, "Camera shows its settings")
    editor.select(.keystrokes)
    check(note?.isHidden == true && editor.view(identifier: "video.keys")?.isHidden == false, "Keystrokes shows its settings")
    var tight: [String] = []
    for id in ["video.camera.size", "video.keys.mode", "video.keys.size", "video.keys.style"] {
        guard let seg = editor.view(identifier: id) as? NSSegmentedControl else { tight.append("no \(id)"); continue }
        if abs(seg.intrinsicContentSize.width - SettingsPanel.controlWidth) > 1 { tight.append("\(id) is \(seg.intrinsicContentSize.width) wide") }
        for i in 0..<seg.segmentCount {
            let text = NSAttributedString(string: seg.label(forSegment: i) ?? "", attributes: DS.Text.label.attributes(color: .black)).size().width
            let tile = seg.width(forSegment: i) - (i < seg.segmentCount - 1 ? DS.Space.s4 : 0)
            if tile < text + DS.Space.s8 { tight.append("\(id) \(seg.label(forSegment: i) ?? ""): tile \(tile) text \(text)") }
        }
    }
    check(tight.isEmpty, "every choice row ends on the panel's right edge and each label fits its tile with room to spare", detail: tight.joined(separator: "; "))
    snapshotEditor(editor, name: "video-after-keystrokes")
    snapshotEditor(editor, name: "video-after-keystrokes-dark", dark: true)

    // Camera.
    editor.select(.camera)
    snapshotEditor(editor, name: "video-after-camera")
    snapshotEditor(editor, name: "video-after-camera-dark", dark: true)
    var steps = 0
    func act(_ id: String, _ body: (NSView) -> Void) {
        guard let v = editor.view(identifier: id) else { return check(false, "\(id) exists") }
        body(v)
        steps += 1
    }
    let area = CGSize(width: original.source.pointWidth, height: original.source.pointHeight)
    act("video.camera.show") { ($0 as? NSButton)?.performClick(nil) }
    await opener.settle(editor)
    check(!editor.state.project.edits.camera.isVisible && editor.previewState?.camera == nil, "Show camera off takes the bubble out of the preview")
    act("video.camera.show") { ($0 as? NSButton)?.performClick(nil) }
    act("video.camera.shape") { if let s = $0 as? NSSegmentedControl { s.selectedSegment = 2; fire(s) } }
    act("video.camera.size") { if let s = $0 as? NSSegmentedControl { s.selectedSegment = 2; fire(s) } }
    act("video.camera.position.5") { ($0 as? NSButton)?.performClick(nil) }
    act("video.camera.mirror") { ($0 as? NSButton)?.performClick(nil) }
    await opener.settle(editor)
    let cam = editor.state.project.edits.camera
    check(cam.isVisible && cam.shape == .rectangle && cam.size == .large && cam.position == .middleRight && cam.isMirrored != original.edits.camera.isMirrored
          && cam.fullScreen == original.edits.camera.fullScreen, "shape, size, the grid's middle-right cell and mirroring reach the project, and its full-screen moments stay",
          detail: "\(cam)")
    let want = CameraLayout.bubbleRect(cam, area: area)
    check(editor.previewState?.camera?.rect == want && abs(want.midY - area.height / 2) < 1 && abs(area.width - want.maxX - CameraLayout.margin(area: area)) < 1,
          "the preview puts the bubble in that cell", detail: "\(String(describing: editor.previewState?.camera?.rect)) want \(want)")
    var placed: [GridPosition: CGRect] = [:]
    for (i, p) in GridPosition.allCases.enumerated() {
        let before = editor.state.project.edits.camera.position
        (editor.view(identifier: "video.camera.position.\(i)") as? NSButton)?.performClick(nil)
        placed[p] = frameState(editor.state.project, outputTime: 1).camera?.rect
        if before != p { steps += 1 }
    }
    check(Set(placed.values.map { "\($0.minX),\($0.minY)" }).count == 9 && placed.allSatisfy { $0.value == CameraLayout.bubbleRect(CameraBubble(shape: .rectangle, size: .large, position: $0.key), area: area) },
          "each of the nine cells puts the bubble in a different place")
    (editor.view(identifier: "video.camera.position") as? PositionGrid).map { grid in
        check(grid.accessibilityRole() == .radioGroup && grid.cells.count == 9 && grid.cells.filter { $0.state == .on }.count == 1
              && grid.cells[8].accessibilityLabel() == "Bottom right" && grid.cells[8].accessibilityRole() == .radioButton,
              "the grid is a radio group of nine named cells with one picked")
    }

    let corner: (String) -> Bool = { if case .success = CameraChange.parse(["corner": $0]) { return true } else { return false } }
    check(corner("topRight") && !corner("center") && !corner("topCenter"), "a recording's camera link still takes only the four corners; the other cells are the editor's")
    check(frameState(editor.state.project, outputTime: 0.35).input.rings.isEmpty, "the editor draws no click rings, which it has no control for yet")

    // Keystrokes.
    editor.select(.keystrokes)
    act("video.keys.mode") { if let s = $0 as? NSSegmentedControl { s.selectedSegment = 0; fire(s) } }
    act("video.keys.size") { if let s = $0 as? NSSegmentedControl { s.selectedSegment = 2; fire(s) } }
    act("video.keys.style") { if let s = $0 as? NSSegmentedControl { s.selectedSegment = 1; fire(s) } }
    act("video.keys.position.4") { ($0 as? NSButton)?.performClick(nil) }
    let keys = editor.state.project.edits.keystrokes
    check(keys.isVisible && keys.keys == .shortcuts && keys.size == .large && keys.theme == .light && keys.position == .center,
          "keys, size, style and the grid's centre reach the project", detail: "\(keys)")
    check(frameState(editor.state.project, outputTime: 2.95).input.badge == nil && frameState(editor.state.project, outputTime: 4.8).input.badge?.text == "\u{2318}S",
          "Shortcuts only leaves the typed hello out and keeps Command-S")
    act("video.keys.mode") { if let s = $0 as? NSSegmentedControl { s.selectedSegment = 1; fire(s) } }
    check(frameState(editor.state.project, outputTime: 3.2).input.badge?.text == "hello", "All keys shows what was typed")
    act("video.keys.show") { ($0 as? NSButton)?.performClick(nil) }
    check(frameState(editor.state.project, outputTime: 2.95).input.badge == nil && (editor.view(identifier: "video.keys.size") as? NSControl)?.isEnabled == false,
          "Show keystrokes off hides the badge and greys its settings")
    snapshotEditor(editor, name: "video-after-keystrokes-off")
    act("video.keys.show") { ($0 as? NSButton)?.performClick(nil) }

    // Sound.
    editor.select(.audio)
    act("video.audio.systemAudio") { ($0 as? NSButton)?.performClick(nil) }
    check(!editor.state.project.edits.audio.systemAudio.isOn && editor.state.project.audioMix.map(\.track) == [.microphone], "System audio off leaves only the microphone in the mix")
    if let level = editor.view(identifier: "video.audio.microphone.level") as? TrackingSlider {
        for v in stride(from: 1.0, through: 0.5, by: -0.05) { level.doubleValue = v; fire(level) }
        level.onTrackingEnd()
        steps += 1
    }
    check(abs(editor.state.project.edits.audio.microphone.level - 0.5) < 1e-9 && (editor.view(identifier: "video.audio.microphone.level") as? NSSlider)?.isEnabled == true
          && (editor.view(identifier: "video.audio.systemAudio.level") as? NSSlider)?.isEnabled == false,
          "the microphone's level follows the slider and a track that is off greys its level")
    snapshotEditor(editor, name: "video-after-audio")
    snapshotEditor(editor, name: "video-after-audio-dark", dark: true)

    // Undo and redo, one step per change and one per slider drag.
    let edited = editor.state.project.edits
    var undone = 0
    while editor.canUndo { editor.undo(); undone += 1 }
    check(editor.state.project.edits == original.edits && undone == steps, "Undo walks back every change one at a time, a level drag as one step", detail: "undone \(undone) of \(steps)")
    while editor.canRedo { editor.redo() }
    check(editor.state.project.edits == edited, "and Redo brings them all back")

    // Parity: the preview against export's own drawing and the file, with the camera and the badge on screen.
    var edits = original.edits
    edits.camera.shape = .square
    edits.camera.position = .topCenter
    edits.camera.size = .small
    edits.keystrokes = KeystrokeDisplay(isVisible: true, keys: .all, position: .middleLeft, size: .large, theme: .light)
    let parityEditor = editor
    parityEditor.setCamera(edits.camera)
    parityEditor.setKeystrokes(edits.keystrokes)
    let project = parityEditor.state.project
    let plan = ExportPlan(project: project, settings: ExportSettings(), video: parityEditor.videoURL)
    let out = w.root.appendingPathComponent("after-parity.mp4")
    _ = try await VideoExporter.export(project: project, video: parityEditor.videoURL, settings: ExportSettings(), to: out)
    guard let video = opener.video else { return check(false, "the editor's frames are the harness's") }
    let rows = await measureParity(parityEditor, frames: video, clock: opener.clock, export: out, plan: plan, project: project, times: [2.95, 4.8],
                                   name: "after-parity", camera: opener.camera)
    for r in rows { print(String(format: "PARITY after t=%.2f preview-vs-drawn %@ preview-vs-file %@", r.time, "\(r.drawn)", "\(r.encoded)")) }
    check(rows.count == 2 && rows.allSatisfy { $0.drawn.psnr >= 36 && $0.encoded.psnr >= 30 },
          "the preview matches export's drawing and the file with the camera at top centre and the badge middle left", detail: rows.map { "\($0.drawn) / \($0.encoded)" }.joined(separator: "; "))

    // Where the badge and the bubble land in the file, against the untouched source.
    let scale = Double(plan.width) / area.width
    if let file = await decodedFrame(out, at: 2.95), let source = await decodedFrame(parityEditor.videoURL, at: 2.95) {
        let badge = InputOverlayPainter.badgeFrame(text: "hello", area: area, project.edits.keystrokes)
        let bubble = CameraLayout.bubbleRect(project.edits.camera, area: area)
        func px(_ r: CGRect) -> CGRect { CGRect(x: r.minX * scale, y: r.minY * scale, width: r.width * scale, height: r.height * scale) }
        let inBadge = changedShare(file, source, in: px(badge).insetBy(dx: 6, dy: 6)), inBubble = changedShare(file, source, in: px(bubble).insetBy(dx: 6, dy: 6))
        let mirrorBadge = changedShare(file, source, in: px(GridPosition.middleRight.place(badge.size, in: area, margin: badge.minX)).insetBy(dx: 6, dy: 6))
        let otherCell = changedShare(file, source, in: px(GridPosition.bottomCenter.place(bubble.size, in: area, margin: bubble.minY)).insetBy(dx: 6, dy: 6))
        print(String(format: "PLACEMENT badge cell=middleLeft changed=%.3f opposite cell changed=%.3f; camera cell=topCenter changed=%.3f bottom centre changed=%.3f", inBadge, mirrorBadge, inBubble, otherCell))
        check(inBadge > 0.5 && inBubble > 0.5 && mirrorBadge < 0.05 && otherCell < 0.05, "the exported file has the badge and the bubble in their cells and nothing in the opposite ones",
              detail: "badge \(inBadge) bubble \(inBubble) opposite \(mirrorBadge) \(otherCell)")
    } else { check(false, "the parity frames decode") }

    // Sound levels in the exported mix, read back from each file without playing anything.
    let micSource = await SoundLevel.read(folder.appendingPathComponent("mic.m4a"))
    let systemSource = await SoundLevel.read(folder.appendingPathComponent("system.m4a"))
    print("RMS source mic.m4a \(micSource.map { "\($0)" } ?? "none") system.m4a \(systemSource.map { "\($0)" } ?? "none")")
    func exportLevel(_ name: String, mic: AudioTrackLevel, system: AudioTrackLevel) async throws -> (SoundLevel?, ExportReport) {
        var p = original
        p.edits.audio = AudioEdits(microphone: mic, systemAudio: system)
        let file = w.root.appendingPathComponent("after-audio-\(name).mp4")
        let report = try await VideoExporter.export(project: p, video: folder.appendingPathComponent(p.source.video), settings: ExportSettings(), to: file)
        let level = await SoundLevel.read(file)
        print("RMS export \(name) mic=\(mic.isOn ? String(format: "%.2f", mic.level) : "off") system=\(system.isOn ? String(format: "%.2f", system.level) : "off") \(level.map { "\($0)" } ?? "no sound track")")
        return (level, report)
    }
    let micFull = try await exportLevel("mic-100", mic: AudioTrackLevel(), system: AudioTrackLevel(isOn: false))
    let micHalf = try await exportLevel("mic-50", mic: AudioTrackLevel(level: 0.5), system: AudioTrackLevel(isOn: false))
    let systemFull = try await exportLevel("system-100", mic: AudioTrackLevel(isOn: false), system: AudioTrackLevel())
    let systemQuarter = try await exportLevel("system-25", mic: AudioTrackLevel(isOn: false), system: AudioTrackLevel(level: 0.25))
    let both = try await exportLevel("both-100", mic: AudioTrackLevel(), system: AudioTrackLevel())
    let none = try await exportLevel("none", mic: AudioTrackLevel(isOn: false), system: AudioTrackLevel(isOn: false))
    func ratio(_ a: SoundLevel?, _ b: SoundLevel?) -> Double { guard let a, let b, b.rms > 0 else { return .nan }; return a.rms / b.rms }
    let micRatio = ratio(micHalf.0, micFull.0), systemRatio = ratio(systemQuarter.0, systemFull.0)
    print(String(format: "RMS ratio mic 50%%/100%% = %.4f (%.2f dB, want -6.02) system 25%%/100%% = %.4f (%.2f dB, want -12.04)",
                 micRatio, 20 * log10(micRatio), systemRatio, 20 * log10(systemRatio)))
    check(abs(micRatio - 0.5) < 0.01 && abs(systemRatio - 0.25) < 0.01, "a track's level scales its RMS in the export by exactly that gain",
          detail: "mic \(micRatio) system \(systemRatio)")
    if let m = micFull.0, let s = systemFull.0, let b = both.0 {
        let sum = (m.rms * m.rms + s.rms * s.rms).squareRoot()
        print(String(format: "RMS both %.5f against sqrt(mic^2 + system^2) %.5f", b.rms, sum))
        check(abs(b.rms - sum) / sum < 0.1, "both tracks on sum in the mix", detail: "\(b.rms) vs \(sum)")
    }
    check(none.0 == nil && !none.1.hasAudio && micFull.1.hasAudio, "with both tracks off the export has no sound track at all")
    check(sha256OrUnreadable(folder.appendingPathComponent("screen.mp4")) == screenHash, "screen.mp4 is never rewritten")
}
