import AppKit
import AVFoundation
import CornermarkCapture
import CornermarkCore

@MainActor
func runRecordingControlTests() async {
    section("pause and resume")
    do {
        try? FileManager.default.createDirectory(atPath: recordingScratch, withIntermediateDirectories: true)
        let url = URL(fileURLWithPath: recordingScratch + "paused.mp4")
        let source = FixtureFrameSource(options: RecordingOptions(fps: 60), pacing: .manual)
        let recorder = Recorder(source: source, output: url)
        try await recorder.start()
        try source.advance(30)
        check(abs(recorder.seconds - 0.5) < 1e-6, "30 frames at 60 fps make half a second of video", detail: "\(recorder.seconds)")
        recorder.pause()
        try source.advance(30)
        check(abs(recorder.seconds - 0.5) < 1e-6, "frames while paused do not grow the video", detail: "\(recorder.seconds)")
        recorder.resume()
        try source.advance(30)
        let report = try await recorder.stop()
        let facts = try await inspectVideo(url)
        check(report.framesWritten == 60 && facts.frames == 60, "the file holds the 60 frames from before and after the pause", detail: "\(report.framesWritten) \(facts.frames)")
        check(report.framesDropped == 0 && abs(facts.duration - 1.0) < 0.02, "with no gap: one second, nothing counted as dropped", detail: "\(report.framesDropped) \(facts.duration)")
        check(report.pauses == [RecordingPause(from: 0.5, to: 1.0)], "the pause is noted on the source clock", detail: "\(report.pauses)")
    } catch {
        check(false, "a paused recording finishes", detail: "\(error)")
    }
    let pauses = [RecordingPause(from: 1, to: 3), RecordingPause(from: 4, to: 5)]
    check(RecordingPause.videoTime(0.5, skipping: pauses) == 0.5 && RecordingPause.videoTime(3.5, skipping: pauses) == 1.5
          && RecordingPause.videoTime(6, skipping: pauses) == 3, "a time after a pause moves back by the pauses before it")
    check(RecordingPause.videoTime(2, skipping: pauses) == nil && RecordingPause.videoTime(4.5, skipping: pauses) == nil, "a time inside a pause has no place in the video")

    section("restart discards the take")
    do {
        let url = URL(fileURLWithPath: recordingScratch + "restarted.mp4")
        let source = FixtureFrameSource(options: RecordingOptions(fps: 60), pacing: .manual)
        let recorder = Recorder(source: source, output: url)
        try await recorder.start()
        try source.advance(20)
        await recorder.cancel()
        check(!FileManager.default.fileExists(atPath: url.path), "a cancelled recording leaves no file")
    } catch {
        check(false, "a recording can be cancelled", detail: "\(error)")
    }

    section("what a display recording leaves out")
    let me = ProcessInfo.processInfo.processIdentifier
    let apps = [ContentExclusion.App(pid: 10, bundleID: ContentExclusion.notificationCenter), ContentExclusion.App(pid: 11, bundleID: ContentExclusion.finder),
                ContentExclusion.App(pid: 12, bundleID: "local.test.editor"), ContentExclusion.App(pid: me, bundleID: "local.test.self")]
    let windows = [ContentExclusion.Window(id: 1, ownerPID: 10, layer: 23), ContentExclusion.Window(id: 2, ownerPID: 11, layer: -2_147_483_603),
                   ContentExclusion.Window(id: 3, ownerPID: 11, layer: 0), ContentExclusion.Window(id: 4, ownerPID: 12, layer: 0)]
    let byDefault = ContentExclusion().plan(apps: apps, windows: windows, ownPID: me)
    check(ContentExclusion() == ContentExclusion(hidesNotifications: true, hidesDesktopIcons: false), "by default notifications are hidden and desktop icons are not")
    check(byDefault.excludedApps == [me, 10] && byDefault.exceptedWindows.isEmpty, "by default Cornermark and Notification Center are excluded", detail: "\(byDefault)")
    let icons = ContentExclusion(hidesNotifications: true, hidesDesktopIcons: true).plan(apps: apps, windows: windows, ownPID: me)
    check(icons.excludedApps == [me, 10, 11] && icons.exceptedWindows == [3], "hiding desktop icons excludes Finder but keeps its normal windows", detail: "\(icons)")
    check(!icons.films(windows[1]) && icons.films(windows[2]) && icons.films(windows[3]) && !icons.films(windows[0]), "so the icon is out, the Finder window and the editor are in, the banner is out")
    let none = ContentExclusion(hidesNotifications: false, hidesDesktopIcons: false).plan(apps: apps, windows: windows, ownPID: me)
    check(none.excludedApps == [me], "with both off only Cornermark's own windows are left out", detail: "\(none)")

    func filmed(_ exclusion: ContentExclusion) async throws -> CGImage? {
        try? FileManager.default.createDirectory(atPath: recordingScratch, withIntermediateDirectories: true)
        let url = URL(fileURLWithPath: recordingScratch + "excluded.mp4")
        let windows = SyntheticScene.otherWindows(on: FixtureFrameSource.displayFrame.size)
        let source = FixtureFrameSource(options: RecordingOptions(fps: 30, exclusion: exclusion), windows: windows, pacing: .scripted(frames: 3))
        let recorder = Recorder(source: source, output: url)
        try await recorder.start()
        _ = try await recorder.stop()
        return try await inspectVideo(url).firstFrame
    }
    do {
        let size = FixtureFrameSource.displayFrame.size
        let banner = (Double(size.width - 200) / Double(size.width), 48.0 / Double(size.height))
        let icon = (Double(size.width - 62) / Double(size.width), 124.0 / Double(size.height))
        let finder = (360.0 / Double(size.width), 228.0 / Double(size.height))
        func isBackground(_ c: [Int]) -> Bool { c.allSatisfy { $0 < 60 } }
        if let shot = try await filmed(ContentExclusion()) {
            check(isBackground(color(shot, banner.0, banner.1)), "the fake banner is not in the default video", detail: "\(color(shot, banner.0, banner.1))")
            check(dominant(color(shot, icon.0, icon.1), is: 2), "the fake desktop icon is", detail: "\(color(shot, icon.0, icon.1))")
        } else { check(false, "the default video has a frame") }
        if let shot = try await filmed(ContentExclusion(hidesNotifications: false)) {
            check(color(shot, banner.0, banner.1).allSatisfy { $0 > 200 }, "with notifications shown the banner is in the video", detail: "\(color(shot, banner.0, banner.1))")
        } else { check(false, "the video with notifications has a frame") }
        if let shot = try await filmed(ContentExclusion(hidesNotifications: true, hidesDesktopIcons: true)) {
            check(isBackground(color(shot, icon.0, icon.1)), "with desktop icons hidden the icon is not in the video", detail: "\(color(shot, icon.0, icon.1))")
            check(color(shot, finder.0, finder.1).allSatisfy { $0 > 200 }, "and the Finder window still is", detail: "\(color(shot, finder.0, finder.1))")
        } else { check(false, "the video with icons hidden has a frame") }
    } catch {
        check(false, "the fixture display records its windows", detail: "\(error)")
    }
}
