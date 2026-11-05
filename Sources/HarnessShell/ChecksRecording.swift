import AppKit
import AVFoundation
import CornermarkCapture
import CornermarkCore
@testable import CornermarkShell

@MainActor
private final class StubTestWindow: RecordingTestWindowHosting {
    var windowID: CGWindowID?
    func show() -> CGWindowID? { windowID }
    func close() {}
}

private struct VideoSummary {
    var width = 0, height = 0, frames = 0
    var isH264 = false
}

private func summarize(_ url: URL) async -> VideoSummary? {
    let asset = AVURLAsset(url: url)
    guard let track = try? await asset.loadTracks(withMediaType: .video).first,
          let size = try? await track.load(.naturalSize),
          let formats = try? await track.load(.formatDescriptions),
          let reader = try? AVAssetReader(asset: asset) else { return nil }
    let out = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
    reader.add(out)
    reader.startReading()
    var frames = 0
    while out.copyNextSampleBuffer() != nil { frames += 1 }
    return VideoSummary(width: Int(size.width), height: Int(size.height), frames: frames,
                        isH264: formats.contains { CMFormatDescriptionGetMediaSubType($0) == kCMVideoCodecType_H264 })
}

/// Every recording is a folder with its video inside, so these are the videos.
private func recordings(in folder: URL) -> [URL] {
    let folders = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []).filter { $0.hasDirectoryPath }.sorted { $0.path < $1.path }
    return folders.map { $0.appendingPathComponent(RecordingProjectFile.videoName) }.filter { FileManager.default.fileExists(atPath: $0.path) }
}

private func projects(in folder: URL) -> [URL] { recordings(in: folder).map { $0.deletingLastPathComponent() } }

@MainActor
func checkRecording() async throws {
    section("recording links")
    func parse(_ s: String) -> Result<AppAction, URLCommandError> { URLCommand.parse(URL(string: s)!, timerSeconds: 5) }
    let accepted: [(String, AppAction)] = [
        ("cornermark://record?window=42", .startRecording(.window(42))),
        ("cornermark://record?display=1", .startRecording(.display(1, area: nil))),
        ("cornermark://record?display=3&x=10&y=20&width=300&height=200", .startRecording(.display(3, area: CGRect(x: 10, y: 20, width: 300, height: 200)))),
        ("cornermark://record?x=10.5&y=-20&width=300&height=200", .startRecording(.display(nil, area: CGRect(x: 10.5, y: -20, width: 300, height: 200)))),
        ("cornermark://record/stop", .stopRecording), ("cornermark:///record/stop", .stopRecording), ("cornermark://record/stop/", .stopRecording),
        ("cornermark://record/test-window", .openRecordingTestWindow),
    ]
    for (s, action) in accepted { check((try? parse(s).get()) == action, "accepts \(s)", detail: "\(parse(s))") }
    let rejected = [
        "cornermark://record", "cornermark://record?window=abc", "cornermark://record?window=0", "cornermark://record?window=-4",
        "cornermark://record?window=4&display=1", "cornermark://record?window=4&x=1&y=1&width=5&height=5",
        "cornermark://record?display=0", "cornermark://record?display=main",
        "cornermark://record?x=1&y=2", "cornermark://record?x=1&y=2&width=0&height=5", "cornermark://record?x=1&y=2&width=5&height=-1",
        "cornermark://record?x=a&y=2&width=5&height=5", "cornermark://record?x=nan&y=2&width=5&height=5",
    ]
    for s in rejected {
        if case .failure(.invalidRecording) = parse(s) { check(true, "rejects \(s)") } else { check(false, "rejects \(s)", detail: "\(parse(s))") }
    }
    if case .failure(.unknownPath) = parse("cornermark://record/bogus") { check(true, "rejects an unknown record sub-path") } else { check(false, "rejects an unknown record sub-path") }
    check(AppAction.make(.record, timerSeconds: 5) == nil, "record needs a target, so make() returns nil")
    check(AppAction.make(.stopRecording, timerSeconds: 5) == .stopRecording, "stop needs nothing")
    check(ActionTable.specs.filter { $0.urlPath?.hasPrefix("record") == true }.allSatisfy { $0.hotKey == nil && $0.menuGroup == nil },
          "recording links have no hotkey and no menu row yet")

    section("recording policy of an isolated instance")
    let host = StubTestWindow()
    func source(_ target: RecordingTarget) throws -> FrameSource { try AppEnvironment.isolatedFrameSource(target, .standard, testWindow: host) }
    func refusal(_ target: RecordingTarget) -> RecordingRefusal? {
        do { _ = try source(target); return nil } catch { return error as? RecordingRefusal }
    }
    check(refusal(.window(7)) == .noTestWindow, "with no test window every window is refused")
    host.windowID = 7
    check(refusal(.window(8)) == .notTestWindow(8), "a window that is not the test window is refused")
    check((try? source(.window(7))) is StreamFrameSource, "the test window gets the live stream source")
    for target: RecordingTarget in [.display(nil, area: nil), .display(1, area: nil), .display(1, area: CGRect(x: 0, y: 0, width: 100, height: 100)),
                                    .display(nil, area: CGRect(x: -500, y: -500, width: 9000, height: 9000))] {
        let made = try? source(target)
        check(made is FixtureFrameSource && !(made is StreamFrameSource), "\(target) is the synthetic display, never the live stream")
    }
    check(refusal(.display(2, area: nil)) == .unknownDisplay(2), "a display id other than the fixture's is refused")
    check(refusal(.display(CGMainDisplayID(), area: nil)) == (CGMainDisplayID() == FixtureFrameSource.displayID ? nil : .unknownDisplay(CGMainDisplayID())),
          "the real main display's id is refused unless it is the fixture's own id")

    section("recording flow")
    let w = try World(after: [])
    defer { w.cleanup() }
    func link(_ q: String) -> Bool { w.coordinator.handle(url: URL(string: "\(URLCommand.scheme)://\(q)")!) }

    check(link("record?display=1") && w.coordinator.recording.phase == .idle && w.coordinator.hud.lastMessage == "Recording not allowed",
          "an environment with no frame source refuses a recording link")
    check(link("record/test-window") && w.presented.isEmpty && nothingOnScreen(), "the test window link does nothing where there is no test window")
    check(link("record/stop") && w.coordinator.recording.phase == .idle, "stop with nothing recording is harmless")

    w.permission = false
    w.env.frameSource = { _, _ in FixtureFrameSource(pacing: .scripted(frames: 3)) }
    check(link("record?display=1") && w.coordinator.recording.phase == .idle && w.presented.contains { $0 === w.coordinator.permissionWindow?.window },
          "without screen permission the permission window opens and nothing records")
    w.permission = true

    var made: [(RecordingTarget, RecordingOptions)] = []
    w.env.frameSource = { target, options in
        made.append((target, options))
        return FixtureFrameSource(area: { if case .display(_, let a) = target { return a } else { return nil } }(), fps: options.fps, pacing: .scripted(frames: 30))
    }
    let area = "display=1&x=100&y=50&width=401&height=301"
    check(link("record?\(area)"), "a display area link is accepted")
    check(await waitUntil { w.coordinator.recording.phase == .recording }, "and the recording starts")
    check(made.count == 1 && made[0].0 == .display(1, area: CGRect(x: 100, y: 50, width: 401, height: 301)) && made[0].1.fps == 60,
          "with the target from the link at 60 fps", detail: "\(made)")
    check(link("record?display=1") && made.count == 1, "a second start while recording is refused before any source is made")
    check(link("record/stop"), "stop is accepted")
    check(await waitUntil { w.coordinator.recording.phase == .idle && w.coordinator.hud.lastMessage?.hasPrefix("Saved ") == true }, "the recording finishes and says so", detail: "\(w.coordinator.hud.lastMessage ?? "nil")")
    let folder = w.saveDir
    let files = recordings(in: folder)
    check(projects(in: folder).map(\.lastPathComponent) == ["Cornermark Recording 2026-11-03 at 14.05.09"], "it lands in the save folder as a project folder with a dated name", detail: "\(projects(in: folder).map(\.lastPathComponent))")
    check(w.coordinator.hud.lastMessage == "Saved Cornermark Recording 2026-11-03 at 14.05.09", "and the message names the project", detail: "\(w.coordinator.hud.lastMessage ?? "nil")")
    if let project = projects(in: folder).first, let saved = try? RecordingProjectFile.read(from: project) {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: project.path)) ?? []).sorted()
        check(names == ["project.json", "screen.mp4"], "the folder holds the video and the project file and nothing else", detail: "\(names)")
        check(saved.source.video == "screen.mp4" && saved.source.pixelWidth == 400 && saved.source.pixelHeight == 300 && saved.source.fps == 60,
              "the project names the video and its size", detail: "\(saved.source)")
        check(saved.source.pointWidth == 401 && saved.source.pointHeight == 301, "and the filmed area in points, which pointer samples are measured in", detail: "\(saved.source)")
        check(abs(saved.source.duration - 0.5) < 1e-9, "and it lasts as long as the 30 frames at 60 fps", detail: "\(saved.source.duration)")
        check(saved.events.pointer.isEmpty && saved.edits.cursor == CursorSettings(), "an environment with no pointer source stores an empty track and the default cursor")
    } else {
        check(false, "the project file can be read back")
    }
    if let file = files.first, let video = await summarize(file) {
        check(video.isH264 && video.width == 400 && video.height == 300 && video.frames == 30, "as 30 H.264 frames of 400x300, the area rounded to even sides", detail: "\(video)")
    } else {
        check(false, "the file can be read back")
    }

    check(link("record?display=1") && link("record/stop"), "a second recording in the same second starts and stops")
    check(await waitUntil { recordings(in: folder).count == 2 && w.coordinator.recording.phase == .idle }, "and gets its own name", detail: "\(projects(in: folder).map(\.lastPathComponent))")
    check(projects(in: folder).map(\.lastPathComponent).contains("Cornermark Recording 2026-11-03 at 14.05.09 2"), "with a number appended", detail: "\(projects(in: folder).map(\.lastPathComponent))")

    w.env.frameSource = { _, _ in throw RecordingRefusal.notTestWindow(9) }
    check(link("record?window=9") && w.coordinator.recording.phase == .idle && recordings(in: folder).count == 2 && w.coordinator.hud.lastMessage == "Recording not allowed",
          "a refused target starts nothing and writes nothing")
    check(((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).count == 2, "not even an empty folder")

    section("recording in a scripted instance")
    let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent("CornermarkHarness-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let env = try AppEnvironment.isolated(root: rootURL, defaults: MemoryDefaults())
    env.hasScreenPermission = { true }
    let c = AppCoordinator(env: env)
    func isoLink(_ q: String) -> Bool { c.handle(url: URL(string: "\(URLCommand.scheme)://\(q)")!) }
    check(env.recordingTestWindow != nil, "a scripted instance has a test window")
    check(isoLink("record?window=12345") && c.recording.phase == .idle && c.hud.lastMessage == "Recording not allowed", "a window link is refused until the test window exists")
    check(isoLink("record?display=1&x=0&y=0&width=320&height=180"), "a display link is accepted")
    check(await waitUntil { c.recording.phase == .recording }, "and films the synthetic display")
    try? await Task.sleep(nanoseconds: 700_000_000)
    check(isoLink("record/stop"), "stop is accepted")
    check(await waitUntil(10) { c.recording.phase == .idle && c.hud.lastMessage?.hasPrefix("Saved ") == true }, "and the file is saved")
    let saved = recordings(in: env.defaultSaveFolder)
    check(saved.count == 1 && saved[0].resolvingSymlinksInPath().path.hasPrefix(rootURL.resolvingSymlinksInPath().path + "/"), "inside the instance's own root", detail: "\(saved)")
    if let project = saved.first.map({ $0.deletingLastPathComponent() }), let stored = try? RecordingProjectFile.read(from: project) {
        let track = stored.events.pointer
        check(track.count > 8 && Set(track.map(\.x)).count > 4, "a scripted instance stores a moving pointer track from its own script", detail: "\(track.count) samples")
        check(track.first.map { $0.t <= 0 } == true && track.last.map { $0.t >= stored.source.duration - 1.0 / 30 } == true, "that spans the whole video", detail: "\(track.first?.t ?? 9) ... \(track.last?.t ?? 9) of \(stored.source.duration)")
        let box = CGRect(x: 0, y: 0, width: stored.source.pointWidth, height: stored.source.pointHeight)
        check(stored.source.pointWidth == 320 && stored.source.pointHeight == 180 && track.allSatisfy { box.contains(CGPoint(x: $0.x, y: $0.y)) }, "and every sample lies inside the filmed 320x180 area", detail: "\(stored.source)")
    } else {
        check(false, "the scripted project can be read back")
    }
    if let file = saved.first, let video = await summarize(file) {
        check(video.isH264 && video.width == 320 && video.height == 180 && video.frames > 20, "as an H.264 video of the area", detail: "\(video)")
    } else {
        check(false, "the scripted file can be read back")
    }
    check(nothingOnScreen(), "recording ordered no window in and never activated the app")
}
