import AppKit
import CornermarkCapture
import CornermarkDesign
@testable import CornermarkShell

/// Permission answers set by the check, given a turn later as macOS gives them, with every request counted.
@MainActor
private final class Permissions {
    var microphone = MicrophoneAccess.notAsked
    var camera = CameraAccess.notAsked
    var input = false
    var grants: Set<RecordingSource> = []
    /// While true, an answer waits in `held` until the check releases it, the way a prompt nobody has answered yet does.
    var holds = false
    var held: [() -> Void] = []
    /// Keyed by the permission, so clicks and keystrokes count against the one Input Monitoring request they share.
    var requests: [String: Int] = [:]

    func install(in env: AppEnvironment) {
        env.microphoneAccess = { [unowned self] in microphone }
        env.requestMicrophoneAccess = { [unowned self] done in
            requests["microphone", default: 0] += 1
            let yes = grants.contains(.microphone)
            let answer = { self.microphone = yes ? .allowed : .denied; done(yes) }
            if holds { held.append(answer) } else { DispatchQueue.main.async(execute: answer) }
        }
        env.cameraAccess = { [unowned self] in camera }
        env.requestCameraAccess = { [unowned self] done in
            requests["camera", default: 0] += 1
            let yes = grants.contains(.camera)
            let answer = { self.camera = yes ? .allowed : .denied; done(yes) }
            if holds { held.append(answer) } else { DispatchQueue.main.async(execute: answer) }
        }
        env.hasInputPermission = { [unowned self] in input }
        env.requestInputPermission = { [unowned self] in
            requests["inputMonitoring", default: 0] += 1
            return input
        }
    }
}

@MainActor
func checkRecordingSources() async throws {
    section("recording panel sources")
    let w = try World()
    defer { w.cleanup() }
    let c = w.coordinator
    let p = Permissions()
    p.install(in: w.env)
    p.grants = [.microphone]
    c.perform(.capture(.recording))
    guard await waitUntil(5, { !c.capture.overlayWindows.isEmpty }) else { return check(false, "the recording overlay opens") }
    func panelView(_ id: String) -> NSView? { c.capture.overlayWindows.lazy.compactMap { findView(id, in: $0.contentView) }.first }
    func toggle(_ s: RecordingSource) -> IconButton? { panelView("cornermark.record.source.\(s.rawValue)") as? IconButton }
    func note() -> String? {
        guard let field = panelView("cornermark.record.sources.note") as? NSTextField, !field.isHidden else { return nil }
        return field.stringValue
    }
    func shows(_ on: Set<RecordingSource>) -> Bool {
        RecordingSource.allCases.allSatisfy { s in
            guard let t = toggle(s) else { return false }
            let want = on.contains(s)
            let offGlyphs: Set = ["mic.slash", "speaker.slash", "video.slash", "cursorarrow.slash", "keyboard"]
            return t.isSelected == want && t.marksSelection && offGlyphs.contains(t.symbol) != want && (t.accessibilityValue() as? Int) == (want ? 1 : 0)
        }
    }
    func prefs() -> RecordingPreferences { w.settings.value.recording }
    func total() -> Int { p.requests.values.reduce(0, +) }

    check(shows([]) && note() == nil, "with the defaults every source is off and the panel has no note")

    p.holds = true
    toggle(.microphone)?.performClick(nil)
    check(p.requests["microphone"] == 1, "turning on the microphone before macOS asked asks once, right then")
    check(c.capture.isOverlayYielding && c.capture.overlayState != nil, "while the prompt waits, the overlay steps off the screen and keeps its selection")
    check(toggle(.microphone)?.isEnabled == false && toggle(.microphone)?.toolTip == "Record microphone (waiting for permission)"
          && toggle(.microphone)?.accessibilityHelp()?.hasPrefix("Waiting for permission.") == true && note() == RecordingSourceToggles.waitingNote,
          "the toggle shows it is waiting, for VoiceOver too, and the note says to answer the prompt", detail: note() ?? "nil")
    for _ in 0..<4 { toggle(.microphone)?.performClick(nil) }
    c.capture.toggleRecordingSource(.microphone)
    check(p.requests["microphone"] == 1 && p.held.count == 1, "more clicks while it waits, on the toggle or through the app, ask nothing more", detail: "\(p.requests)")
    p.holds = false
    p.held.forEach { $0() }
    p.held = []
    check(!c.capture.isOverlayYielding && !c.capture.overlayWindows.isEmpty, "the answer brings the overlay back")
    check(await waitUntil { prefs().audio.microphone && shows([.microphone]) }, "allowed, it is on in the settings and in the panel")
    check(note() == "Record GIF never records sound.", "and the panel says a GIF records no sound", detail: note() ?? "nil")
    toggle(.microphone)?.performClick(nil)
    check(!prefs().audio.microphone && shows([]) && note() == nil, "a second click turns it off")
    toggle(.microphone)?.performClick(nil)
    check(prefs().audio.microphone && shows([.microphone]) && p.requests["microphone"] == 1, "once allowed, turning it on asks nothing")

    toggle(.systemAudio)?.performClick(nil)
    check(prefs().audio.systemAudio && shows([.microphone, .systemAudio]) && total() == 1, "system audio needs no permission of its own and asks nothing")
    if let mic = toggle(.microphone), let next = toggle(.systemAudio), let panel = mic.superview, let host = panel.superview {
        let badges = mic.subviews.filter { !$0.isHidden }
        let badge = badges.first.map { panel.convert($0.frame, from: mic) } ?? .zero
        func hit(_ p: CGPoint) -> NSView? { panel.hitTest(host.convert(p, from: panel)) }
        check(badges.count == 1 && badge.maxX > mic.frame.maxX && badge.minY < mic.frame.minY && badge.minX < mic.frame.maxX,
              "a toggle that is on shows its check over the tile's bottom-right corner, partly outside it", detail: "\(badge) on \(mic.frame)")
        check(badge.origin.x == badge.origin.x.rounded() && badge.origin.y == badge.origin.y.rounded() && badge.maxX < next.frame.minX,
              "the check sits on whole points and keeps clear of the next toggle", detail: "\(badge) next \(next.frame)")
        check(hit(CGPoint(x: badge.maxX - 1, y: badge.midY)) === panel && hit(CGPoint(x: mic.frame.maxX - 2, y: mic.frame.minY + 2)) === mic,
              "the check takes no clicks: its overflow reaches the panel and its part on the tile reaches the toggle")
        check(mic.subviews.allSatisfy { !$0.isAccessibilityElement() }, "the check adds nothing for VoiceOver; the toggle's value says it is on")
        mic.isEnabled = false
        check(mic.subviews.allSatisfy(\.isHidden), "a toggle that takes no clicks shows no check")
        mic.isEnabled = true
    } else {
        check(false, "the microphone toggle sits in the panel")
    }

    toggle(.camera)?.performClick(nil)
    check(p.requests["camera"] == 1 && c.capture.isOverlayYielding, "turning on the camera before macOS asked asks once, with the overlay out of the way")
    _ = await waitUntil { p.camera == .denied && note() != nil }
    check(!prefs().camera.isVisible && shows([.microphone, .systemAudio]), "refused, the camera stays off in the settings and in the panel")
    check(note() == "Turn on Cornermark in System Settings > Privacy & Security > Camera.", "and the note says how to allow it",
          detail: note() ?? "nil")
    toggle(.camera)?.performClick(nil)
    check(p.requests["camera"] == 1 && !prefs().camera.isVisible && note()?.contains("Privacy & Security > Camera") == true,
          "once refused, another click asks nothing and repeats how to allow it")

    check(!c.capture.isOverlayYielding, "and comes back after the camera's answer")
    let inputNote = "Turn on Cornermark in System Settings > Privacy & Security > Input Monitoring, then reopen it."
    toggle(.clicks)?.performClick(nil)
    check(p.requests["inputMonitoring"] == 1 && w.defaults.bool(forKey: RecordingSourceToggles.inputAskedKey), "turning on click highlights asks for Input Monitoring once")
    check(await waitUntil { c.capture.overlayWindows.isEmpty },
          "the overlay closes before that prompt, since macOS sends no answer for it and it applies only after Cornermark reopens")
    check(!prefs().clicks.isVisible && !prefs().keystrokes.isVisible, "refused, click highlights stay off")
    c.perform(.capture(.recording))
    guard await waitUntil(5, { !c.capture.overlayWindows.isEmpty }) else { return check(false, "the recording overlay opens again") }
    check(toggle(.clicks)?.isSelected == false && toggle(.microphone)?.isSelected == true, "reopened, the panel shows clicks off and the rest as chosen")
    toggle(.keystrokes)?.performClick(nil)
    check(p.requests["inputMonitoring"] == 1 && !prefs().keystrokes.isVisible && note() == inputNote,
          "keystrokes share that request: a click on them asks nothing more, stays off and repeats the note")
    toggle(.clicks)?.performClick(nil)
    check(p.requests["inputMonitoring"] == 1, "once asked, another click does not ask again")
    p.input = true
    toggle(.clicks)?.performClick(nil)
    check(prefs().clicks.isVisible && !prefs().keystrokes.isVisible && toggle(.clicks)?.isSelected == true && toggle(.keystrokes)?.isSelected == false,
          "with Input Monitoring allowed, the clicks toggle writes clicks.isVisible alone")
    toggle(.keystrokes)?.performClick(nil)
    check(prefs().clicks.isVisible && prefs().keystrokes.isVisible && toggle(.keystrokes)?.isSelected == true, "and the keystrokes toggle writes keystrokes.isVisible")
    toggle(.clicks)?.performClick(nil)
    check(!prefs().clicks.isVisible && prefs().keystrokes.isVisible && shows([.microphone, .systemAudio, .keystrokes]),
          "turning clicks off leaves keystrokes on: two settings, two toggles")
    toggle(.clicks)?.performClick(nil)
    check(p.requests == ["microphone": 1, "camera": 1, "inputMonitoring": 1], "three permissions, one request each, for the whole tour", detail: "\(p.requests)")

    if let field = panelView("cornermark.record.sources.note") as? NSTextField {
        let notes = RecordingSource.allCases.map(\.deniedNote) + RecordingSource.allCases.map { "Turn on \($0.name) to allow access." } + ["Record GIF never records sound."]
        let lines = notes.map { text -> CGFloat in
            let probe = NSTextField(wrappingLabelWithString: text)
            probe.font = field.font
            probe.preferredMaxLayoutWidth = field.frame.width
            return (probe.fittingSize.height / (field.font.map { NSLayoutManager().defaultLineHeight(for: $0) } ?? 14)).rounded()
        }
        check(lines.allSatisfy { $0 <= 2 }, "every note the panel can show fits in two lines beside the toggles, so none is cut off",
              detail: "\(zip(lines, notes).filter { $0.0 > 2 }.map(\.1)) width=\(field.frame.width)")
    }
    if let host = toggle(.microphone)?.window { _ = snapshotWindow(host, name: "recording-panel-sources") }

    section("recording panel options")
    func optionsMenu() -> NSMenu? { panelView("cornermark.record.options")?.menu }
    func item(_ id: String) -> (NSMenu, Int)? {
        guard let menu = optionsMenu(), let i = menu.items.firstIndex(where: { $0.identifier?.rawValue == "cornermark.record.option." + id }) else { return nil }
        return (menu, i)
    }
    func pick(_ id: String) {
        guard let (menu, i) = item(id) else { return check(false, "the options menu has \(id)") }
        menu.performActionForItem(at: i)
    }
    func isOn(_ id: String) -> Bool { item(id).map { $0.0.items[$0.1].state == .on } ?? false }
    let headers = optionsMenu()?.items.filter(\.isSectionHeader).map(\.title) ?? []
    check(headers == ["Quality", "Frame Rate", "Countdown"], "the options menu groups quality, frame rate and countdown", detail: "\(headers)")
    check(isOn("quality.high") && isOn("fps.60") && isOn("countdown.0") && isOn("cursor") && isOn("dim") && isOn("notifications") && !isOn("desktopIcons"),
          "it checks what the settings hold")
    pick("quality.medium"); pick("fps.30"); pick("countdown.5"); pick("cursor"); pick("desktopIcons")
    let r = prefs()
    check(r.quality == .medium && r.fps == 30 && r.countdown == 5 && !r.showCursor && r.hideDesktopIcons && r.dimOutside && r.hideNotifications,
          "each pick writes the Recording settings and leaves the rest alone", detail: "\(r.quick)")
    check(isOn("quality.medium") && !isOn("quality.high") && isOn("fps.30") && isOn("countdown.5") && !isOn("cursor") && isOn("desktopIcons"),
          "and the menu follows at once")
    w.settings.update { $0.recording.quick = RecordingQuickOptions() }
    c.capture.refreshOverlay()
    check(isOn("quality.high") && isOn("countdown.0") && isOn("cursor"), "a change made in Settings shows in the menu too")

    section("recording panel help")
    check(panelView("cornermark.record.help.title") == nil, "the help window opens only when asked")
    (panelView("cornermark.record.help") as? NSButton)?.performClick(nil)
    let helpTitle = panelView("cornermark.record.help.title") as? NSTextField
    let helpWindow = helpTitle?.window
    let close = panelView("cornermark.record.help.close") as? CornermarkDesign.Button
    check(helpTitle?.stringValue == "What is a project recording?" && close?.title == "Close" && close?.variant == .primary && close?.keyEquivalent == "\r",
          "the help button opens a window with a title and one primary button that Return presses", detail: helpTitle?.stringValue ?? "nil")
    let overlayLevel = c.capture.overlayWindows.first?.level.rawValue ?? 0
    check((helpWindow?.level.rawValue ?? 0) > overlayLevel && helpWindow?.canBecomeKey == true && helpWindow?.isVisible == false,
          "it sits above the overlay, can take the keyboard, and the harness never shows it", detail: "\(helpWindow?.level.rawValue ?? -1) \(overlayLevel)")
    if let helpWindow { _ = snapshotWindow(helpWindow, name: "recording-help") }
    close?.performClick(nil)
    check(!c.capture.overlayWindows.isEmpty && prefs().quick == RecordingQuickOptions(), "closing it leaves the overlay open and changes nothing")
    (panelView("cornermark.record.help") as? NSButton)?.performClick(nil)
    (panelView("cornermark.record.help.title") as? NSTextField)?.window?.cancelOperation(nil)
    check(!c.capture.overlayWindows.isEmpty, "Escape in it closes it without leaving the overlay")
    c.capture.cancel()
    check(await waitUntil { c.capture.overlayWindows.isEmpty }, "the overlay closes")

    section("Settings shows what the recording panel chose")
    c.perform(.openSettings)
    guard let sw = c.settingsWindow else { return check(false, "the settings window opens") }
    func pane<T: SettingsPane>(_ type: T.Type) -> NSView? {
        guard let pane = sw.panes.first(where: { $0 is T }) else { return nil }
        sw.select(pane: pane)
        return pane.view
    }
    let audio = pane(AudioPane.self)
    check((findView("audio.microphone", in: audio) as? NSButton)?.state == .on && (findView("audio.system", in: audio) as? NSButton)?.state == .on
          && (findView("audio.access", in: audio) as? NSTextField)?.stringValue == "Allowed", "the Audio pane has the microphone and system audio on, allowed")
    let camera = pane(CameraPane.self)
    check((findView("camera.show", in: camera) as? NSButton)?.state == .off && (findView("camera.access", in: camera) as? NSTextField)?.stringValue == "Not allowed",
          "the Camera pane has the camera off and not allowed")
    let recording = pane(RecordingPane.self)
    check((findView("recording.clicks", in: recording) as? NSButton)?.state == .on && (findView("recording.keys", in: recording) as? NSButton)?.state == .on
          && (findView("recording.inputPermission", in: recording) as? NSTextField)?.stringValue == "Allowed", "the Recording pane shows clicks and keystrokes on")
    sw.window?.close()

    section("a source wanted in Settings but not allowed")
    p.camera = .denied
    w.settings.update { $0.recording.camera.isVisible = true }
    c.perform(.capture(.recording))
    guard await waitUntil(5, { !c.capture.overlayWindows.isEmpty }) else { return check(false, "the overlay opens again") }
    check(toggle(.camera)?.isSelected == false && note()?.contains("Privacy & Security > Camera") == true,
          "the panel shows the camera off, as the recording will be, and says how to allow it", detail: note() ?? "nil")
    toggle(.camera)?.performClick(nil)
    check(!prefs().camera.isVisible && p.requests["camera"] == 1, "a click on it asks nothing and writes it off, so Settings agrees")
    c.capture.cancel()
    _ = await waitUntil { c.capture.overlayWindows.isEmpty }
    check(nothingOnScreen(), "the panel put nothing on screen")

    section("recording panel sources in a scripted instance")
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("CornermarkHarness-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let env = try AppEnvironment.isolated(root: root, defaults: MemoryDefaults())
    let iso = AppCoordinator(env: env)
    for s in RecordingSource.allCases { iso.sources.toggle(s) }
    check(iso.sources.state.on == Set(RecordingSource.allCases) && iso.sources.state.note == .hint("Record GIF never records sound."),
          "every toggle turns on at once, because a scripted instance reads every source as allowed")
    check(!env.requestInputPermission(), "its Input Monitoring request is refused, never shown")
    check(MicrophoneAccess.requests == 0 && CameraAccess.requests == 0 && LiveInputSource.requests == 0,
          "the real microphone, camera and Input Monitoring prompts were never asked for",
          detail: "\(MicrophoneAccess.requests) \(CameraAccess.requests) \(LiveInputSource.requests)")
    check(LiveMicrophoneSource.sessionsOpened == 0 && LiveCameraSource.sessionsOpened == 0 && LiveInputSource.tapsCreated == 0,
          "and no real device or event tap was opened")
}
