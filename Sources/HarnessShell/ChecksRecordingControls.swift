import AppKit
import AVFoundation
import CornermarkCapture
import CornermarkCore
import CornermarkDesign
import IOKit.pwr_mgt
@testable import CornermarkShell

/// A world whose recordings come from a manual fixture display: frames arrive only when a check calls `advance`.
@MainActor
final class ManualRecordingWorld {
    let world: World
    private(set) var sources: [FixtureFrameSource] = []
    var source: FixtureFrameSource? { sources.last }

    init(windows: [FixtureWindow] = []) throws {
        world = try World(after: [.showOverlay])
        let box = WeakBox(self)
        world.env.frameSource = { target, options in
            let area: CGRect? = { if case .display(_, let a) = target { return a } else { return nil } }()
            let source = FixtureFrameSource(area: area, options: options, windows: windows, pacing: .manual)
            box.value?.sources.append(source)
            return source
        }
        world.env.recordingJournal = RecordingJournal(folder: world.root.appendingPathComponent("unfinished", isDirectory: true))
        world.coordinator.recording.countdownTick = 0.05
    }

    func link(_ q: String) -> Bool { world.coordinator.handle(url: URL(string: "\(URLCommand.scheme)://\(q)")!) }
    var phase: RecordingController.Phase { world.coordinator.recording.phase }
}

private final class WeakBox<T: AnyObject> { weak var value: T?; init(_ v: T) { value = v } }

/// The kinds of power assertion this process holds right now, read from the power manager itself.
func ownPowerAssertions() -> [String] {
    var raw: Unmanaged<CFDictionary>?
    guard IOPMCopyAssertionsByProcess(&raw) == kIOReturnSuccess, let all = raw?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else { return [] }
    return (all[NSNumber(value: ProcessInfo.processInfo.processIdentifier)] ?? []).compactMap { $0[kIOPMAssertionTypeKey] as? String }
}

@MainActor
func checkRecordingControls() async throws {
    section("recording controls settings")
    let d = RecordingPreferences()
    check(d.countdown == 0 && d.dimOutside && !d.hideDesktopIcons && d.hideNotifications,
          "defaults: no countdown, dim outside the area, desktop icons shown, notifications hidden")
    let older = try JSONDecoder().decode(RecordingPreferences.self, from: Data(#"{"fps":30,"quality":"low"}"#.utf8))
    check(older.fps == 30 && older.countdown == 0 && older.hideNotifications && older.dimOutside, "settings saved before the controls existed read as the defaults")
    var p = RecordingPreferences()
    p.countdown = 4
    check(p.normalized().countdown == 3, "a countdown that is not offered becomes the nearest one that is")
    p.hideDesktopIcons = true
    p.hideNotifications = false
    let o = p.options(for: .editing)
    check(o.exclusion == ContentExclusion(hidesNotifications: false, hidesDesktopIcons: true), "the two hide settings reach the source as its exclusion")
    check(RecordingPreferences().options(for: .video).exclusion == ContentExclusion(), "by default the source hides notifications and not desktop icons")

    section("recording controls")
    let m = try ManualRecordingWorld()
    let w = m.world, c = w.coordinator
    defer { w.cleanup() }
    let before = ownPowerAssertions().filter { $0 == (kIOPMAssertionTypePreventUserIdleDisplaySleep as String) }.count
    check(m.link("record?display=1&x=100&y=80&width=400&height=300"), "an area link is accepted")
    check(await waitUntil { m.phase == .recording }, "and the recording starts")
    let journal = w.env.recordingJournal!
    check(journal.entries().count == 1, "a recording in progress is noted in the journal", detail: "\(journal.entries())")
    let held = ownPowerAssertions().filter { $0 == (kIOPMAssertionTypePreventUserIdleDisplaySleep as String) }.count
    check(held == before + 1, "while it records the app holds one PreventUserIdleDisplaySleep assertion", detail: "\(ownPowerAssertions())")
    guard let bar = c.controls.bar, let view = c.controls.barView else { return check(false, "the control bar exists") }
    check(bar.sharingType == .none, "the control bar is never shared, so no recording or screenshot shows it")
    check(bar.isMovableByWindowBackground && !bar.canBecomeKey && bar.level == .statusBar, "it can be dragged by its background and never takes focus")
    check(w.presented.contains { $0 === bar } && !bar.isVisible && nothingOnScreen(), "it is presented through the environment, so the harness shows nothing")
    guard let dim = c.controls.dim, let dimView = c.controls.dimView else { return check(false, "an area recording dims outside the area") }
    check(dim.sharingType == .none && dim.ignoresMouseEvents, "the dimming is never shared and takes no clicks")
    check(dim.level.rawValue == NSWindow.Level.mainMenu.rawValue - 1, "it sits under the menu bar, so the time there stays readable")
    let screen = RecordingControls.screen(for: CGRect(x: 100, y: 80, width: 400, height: 300))
    check(dimView.hole == CGRect(x: 100 - screen.frame.minX, y: 80 - screen.frame.minY, width: 400, height: 300), "and its hole is the recorded area", detail: "\(dimView.hole)")

    try m.source?.advance(90)
    c.controls.update()
    check(view.time.stringValue == "0:01" && view.look == RecordingBarLook.of(.recording), "after 90 frames at 60 fps the bar reads 0:01", detail: view.time.stringValue)
    check(view.look.indicator == "record.circle.fill" && view.look.indicatorIsDanger && view.stop.title == "Stop", "the indicator is the danger-coloured record symbol")
    let item = NSStatusBarButton()
    applyStatusLabel(c.updates.state, recording: c.controls.status, to: item)
    check(item.title.hasSuffix("0:01") && item.imagePosition == .imageLeading && item.accessibilityLabel()?.contains("Recording, 0:01") == true,
          "the menu bar shows the length beside the record symbol", detail: "\(item.title) \(String(describing: item.accessibilityLabel()))")

    view.pause.performClick(nil)
    check(m.phase == .paused && view.look.showsResume && !view.resume.isHidden && view.pause.isHidden, "Pause pauses, and the button becomes Resume")
    try m.source?.advance(60)
    check(abs(c.recording.seconds - 1.5) < 1e-6, "frames while paused are not recorded", detail: "\(c.recording.seconds)")
    applyStatusLabel(c.updates.state, recording: c.controls.status, to: item)
    check(item.accessibilityLabel()?.contains("paused") == true, "the menu bar says it is paused", detail: "\(String(describing: item.accessibilityLabel()))")
    check(m.link("record/resume") && m.phase == .recording, "the resume link resumes")
    try m.source?.advance(30)
    check(m.link("record/pause") && m.phase == .paused && m.link("record/resume") && m.phase == .recording, "the pause link pauses")
    try m.source?.advance(30)
    view.stop.performClick(nil)
    check(await waitUntil { m.phase == .idle && w.store.list().count == 1 }, "Stop finishes the recording")
    if let record = w.store.list().first, let video = record.video, let facts = await fileFacts(video.file) {
        check(facts.frames == 150, "the file holds the 150 recorded frames and none from the pause", detail: "\(facts)")
        check(abs(video.duration - 2.5) < 0.02, "and lasts 2.5 s", detail: "\(video.duration)")
    } else { check(false, "the paused recording is listed") }
    check(c.controls.bar == nil && c.controls.dim == nil, "the bar and the dimming close when it ends")
    check(journal.entries().isEmpty, "and the journal is empty again")
    let after = ownPowerAssertions().filter { $0 == (kIOPMAssertionTypePreventUserIdleDisplaySleep as String) }.count
    check(after == before, "and the display sleep assertion is released", detail: "\(ownPowerAssertions())")
    let dragged = CGPoint(x: 300, y: 200)

    section("restart")
    check(m.link("record?display=1&x=0&y=0&width=320&height=180"), "a second recording starts")
    check(await waitUntil { m.phase == .recording }, "and runs")
    try m.source?.advance(40)
    let firstSource = m.source
    c.controls.bar?.setFrameOrigin(dragged)
    c.controls.barView?.restart.performClick(nil)
    let armed = c.controls.barView?.isRestartArmed == true && c.controls.barView?.confirmRestart.isHidden == false && c.controls.barView?.restart.isHidden == true
    check(armed && m.phase == .recording, "a first click on Restart only asks: Discard take takes its place and nothing is discarded")
    check((c.controls.bar?.frame.width ?? 0) == (c.controls.barView?.frame.width ?? -1), "and the bar grows to hold it", detail: "\(String(describing: c.controls.bar?.frame.width)) \(String(describing: c.controls.barView?.frame.width))")
    c.controls.barView?.confirmRestart.performClick(nil)
    check(await waitUntil { m.phase == .recording && m.source !== firstSource }, "Restart begins again with a fresh source")
    check(c.recording.seconds == 0, "with nothing recorded yet", detail: "\(c.recording.seconds)")
    try m.source?.advance(12)
    check(m.link("record/stop"), "stop")
    check(await waitUntil { m.phase == .idle && w.store.list().count == 2 }, "finishes the restarted take")
    if let video = w.store.list().compactMap(\.video).first(where: { RecordingProjectFile.displayName(of: $0.location).hasSuffix(" 2") }), let facts = await fileFacts(video.file) {
        check(facts.frames == 12 && facts.width == 320, "the file holds only the 12 frames after the restart", detail: "\(facts)")
    } else { check(false, "the restarted take is listed") }
    check(c.controls.rememberedOrigin == dragged, "the place the bar was dragged to is kept for the next recording", detail: "\(String(describing: c.controls.rememberedOrigin))")

    section("countdown")
    w.settings.update { $0.recording.countdown = 3 }
    check(m.link("record?display=1"), "a link with a 3 second countdown is accepted")
    check(await waitUntil { m.phase == .countingDown(3) }, "the countdown starts at 3")
    check(c.controls.countdownView?.remaining == 3 && c.controls.countdown?.sharingType == RecordingPanel.SharingType.none, "the countdown panel shows 3 and is never shared")
    check(c.controls.barView?.stop.title == "Cancel" && c.controls.barView?.restart.isEnabled == false, "during the countdown the bar offers Cancel only")
    check(c.controls.dim == nil, "a whole display is not dimmed")
    let one = await waitUntil { m.phase == .countingDown(1) }
    check(one && c.controls.countdownView?.remaining == 1, "it counts down to 1")
    let began = await waitUntil { m.phase == .recording }
    check(began && c.controls.countdown == nil, "then records, and the countdown closes")
    try m.source?.advance(6)
    _ = m.link("record/stop")
    check(await waitUntil { m.phase == .idle && w.store.list().count == 3 }, "and stops as usual")
    let folders = Set((try? FileManager.default.contentsOfDirectory(atPath: w.saveDir.path)) ?? [])
    _ = m.link("record?display=1")
    check(await waitUntil { m.phase == .countingDown(3) }, "another countdown starts")
    _ = m.link("record/stop")
    check(await waitUntil { m.phase == .idle }, "stop during the countdown cancels it")
    check(Set((try? FileManager.default.contentsOfDirectory(atPath: w.saveDir.path)) ?? []) == folders && w.store.list().count == 3,
          "and leaves no file and no folder behind")
    w.settings.update { $0.recording.countdown = 0; $0.recording.dimOutside = false }
    _ = m.link("record?display=1&x=0&y=0&width=320&height=180")
    check(await waitUntil { m.phase == .recording }, "with dimming off an area records")
    check(c.controls.dim == nil && c.controls.bar != nil, "without the dimming")
    try m.source?.advance(3)
    _ = m.link("record/stop")
    check(await waitUntil { m.phase == .idle && w.store.list().count == 4 }, "and stops")
    check(nothingOnScreen(), "the controls put nothing on screen in the harness")

    section("control bar placement")
    let visible = CGRect(x: 0, y: 0, width: 1440, height: 875)
    let size = CGSize(width: 260, height: 36)
    check(RecordingBarLayout.origin(size: size, area: CGRect(x: 200, y: 300, width: 600, height: 400), visible: visible, remembered: nil) == CGPoint(x: 370, y: 248),
          "centred 16 pt under an area with room below")
    check(RecordingBarLayout.origin(size: size, area: CGRect(x: 200, y: 20, width: 600, height: 400), visible: visible, remembered: nil) == CGPoint(x: 370, y: 436),
          "over an area that reaches the bottom")
    check(RecordingBarLayout.origin(size: size, area: CGRect(x: 0, y: 0, width: 1440, height: 900), visible: visible, remembered: nil) == CGPoint(x: 590, y: 16),
          "inside the bottom edge of a whole display, above the Dock")
    check(RecordingBarLayout.origin(size: size, area: CGRect(x: 1300, y: 300, width: 100, height: 100), visible: visible, remembered: nil).x == 1440 - 16 - 260,
          "never past the edge of the screen")
    check(RecordingBarLayout.origin(size: size, area: .zero, visible: visible, remembered: CGPoint(x: 50, y: 60)) == CGPoint(x: 50, y: 60), "where the user dragged it, while it fits")
    check(RecordingBarLayout.origin(size: size, area: CGRect(x: 200, y: 300, width: 600, height: 400), visible: visible, remembered: CGPoint(x: 1400, y: 60)) == CGPoint(x: 370, y: 248),
          "and back to the default when it no longer fits")

    section("bar looks")
    let phases: [RecordingController.Phase] = [.idle, .starting, .countingDown(2), .recording, .paused, .stopping]
    check(phases.filter { RecordingBarLook.of($0).indicatorIsDanger } == [.recording], "only a running recording is shown in the danger colour")
    check(phases.filter { RecordingBarLook.of($0).canRestart } == [.recording, .paused], "restart is offered only once frames are being kept")
    check(RecordingBarLook.of(.paused).indicator == "pause.fill" && RecordingBarLook.of(.paused).timeIsMuted, "a pause changes the symbol and mutes the time, not only the colour")
}

@MainActor
func checkRecordingRecovery() async throws {
    section("recovery after a crash")
    let m = try ManualRecordingWorld()
    let w = m.world, c = w.coordinator
    defer { w.cleanup() }
    w.settings.update { $0.recording.showQuickAccess = false }
    check(m.link("record?display=1&x=0&y=0&width=320&height=180"), "a recording starts")
    check(await waitUntil { m.phase == .recording }, "and runs")
    guard let entry = w.env.recordingJournal?.entries().first else { return check(false, "the journal names the recording") }
    // A crash leaves the bytes on disk as they are. Copying them mid-recording keeps exactly that, with no help from the writer.
    try m.source?.advance(180)
    let box = Data("moof".utf8)
    _ = await waitUntil(5) { (try? Data(contentsOf: entry.video.file))?.range(of: box) != nil }
    let cutOff = try Data(contentsOf: entry.video.file)
    c.recording.restart()
    _ = await waitUntil { m.phase == .recording }
    c.recording.stop()
    _ = await waitUntil { m.phase == .idle && w.store.list().count == 1 }
    let crashed = w.root.appendingPathComponent("crashed project", isDirectory: true)
    try FileManager.default.createDirectory(at: crashed, withIntermediateDirectories: true)
    try cutOff.write(to: crashed.appendingPathComponent(RecordingProjectFile.videoName))
    let journal = w.env.recordingJournal!
    let left = journal.open(location: crashed, format: .project, kind: .area, area: CGRect(x: 0, y: 0, width: 320, height: 180))
    check(left != nil && journal.entries().count == 1, "a journal entry is left for the cut-off recording")
    let fragmented = cutOff.range(of: Data("mvex".utf8)) != nil && cutOff.range(of: box) != nil
    check(fragmented, "the cut-off file is fragmented, so it is readable without its end", detail: "\(cutOff.count) bytes")
    let listed = w.store.list().count
    await c.recoverRecordings()
    check(journal.entries().isEmpty, "the next launch finishes it and clears the journal")
    check(w.store.list().count == listed + 1 && w.store.list().first?.video?.location.standardizedFileURL == crashed.standardizedFileURL,
          "and lists it in history", detail: "\(w.store.list().map { $0.video?.location.lastPathComponent ?? "-" })")
    check(c.hud.lastMessage == "Recovered a recording that was cut off", "and says so", detail: c.hud.lastMessage ?? "nil")
    if let facts = await fileFacts(crashed.appendingPathComponent(RecordingProjectFile.videoName)), let project = try? RecordingProjectFile.read(from: crashed) {
        check(facts.frames >= 60 && facts.width == 320, "the recovered file plays its whole seconds", detail: "\(facts)")
        check(project.source.pointWidth == 320 && project.source.duration > 0.9, "and its project is written again", detail: "\(project.source)")
        let rewritten = (try? Data(contentsOf: crashed.appendingPathComponent(RecordingProjectFile.videoName))) ?? Data()
        check(!rewritten.isEmpty && rewritten.range(of: box) == nil, "as a plain file with no fragments, which any player reads")
    } else { check(false, "the recovered recording can be read") }
    _ = journal.open(location: crashed, format: .project, kind: .area, area: CGRect(x: 0, y: 0, width: 320, height: 180))
    await c.recoverRecordings()
    check(w.store.list().count == listed + 1 && journal.entries().isEmpty, "recovering the same recording again lists it once")
    let gone = journal.open(location: w.root.appendingPathComponent("missing.mp4"), format: .video, kind: .area, area: .zero)
    check(gone != nil, "a journal entry for a file that is gone")
    await c.recoverRecordings()
    check(journal.entries().isEmpty && w.store.list().count == listed + 1, "is dropped without listing anything")
}
