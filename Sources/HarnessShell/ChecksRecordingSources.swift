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
    var requests: [RecordingSource: Int] = [:]

    func install(in env: AppEnvironment) {
        env.microphoneAccess = { [unowned self] in microphone }
        env.requestMicrophoneAccess = { [unowned self] done in
            requests[.microphone, default: 0] += 1
            let yes = grants.contains(.microphone)
            DispatchQueue.main.async { self.microphone = yes ? .allowed : .denied; done(yes) }
        }
        env.cameraAccess = { [unowned self] in camera }
        env.requestCameraAccess = { [unowned self] done in
            requests[.camera, default: 0] += 1
            let yes = grants.contains(.camera)
            DispatchQueue.main.async { self.camera = yes ? .allowed : .denied; done(yes) }
        }
        env.hasInputPermission = { [unowned self] in input }
        env.requestInputPermission = { [unowned self] in
            requests[.input, default: 0] += 1
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
            return t.isSelected == want && t.symbol.hasSuffix("slash") != want && (t.accessibilityValue() as? Int) == (want ? 1 : 0)
        }
    }
    func prefs() -> RecordingPreferences { w.settings.value.recording }
    func total() -> Int { p.requests.values.reduce(0, +) }

    check(shows([]) && note() == nil, "with the defaults every source is off and the panel has no note")

    toggle(.microphone)?.performClick(nil)
    check(p.requests[.microphone] == 1, "turning on the microphone before macOS asked asks once, right then")
    check(await waitUntil { prefs().audio.microphone && shows([.microphone]) }, "allowed, it is on in the settings and in the panel")
    check(note() == "Record GIF never records sound.", "and the panel says a GIF records no sound", detail: note() ?? "nil")
    toggle(.microphone)?.performClick(nil)
    check(!prefs().audio.microphone && shows([]) && note() == nil, "a second click turns it off")
    toggle(.microphone)?.performClick(nil)
    check(prefs().audio.microphone && shows([.microphone]) && p.requests[.microphone] == 1, "once allowed, turning it on asks nothing")

    toggle(.systemAudio)?.performClick(nil)
    check(prefs().audio.systemAudio && shows([.microphone, .systemAudio]) && total() == 1, "system audio needs no permission of its own and asks nothing")

    toggle(.camera)?.performClick(nil)
    check(p.requests[.camera] == 1, "turning on the camera before macOS asked asks once")
    _ = await waitUntil { p.camera == .denied && note() != nil }
    check(!prefs().camera.isVisible && shows([.microphone, .systemAudio]), "refused, the camera stays off in the settings and in the panel")
    check(note() == "Turn on Cornermark in System Settings > Privacy & Security > Camera.", "and the note says how to allow it",
          detail: note() ?? "nil")
    toggle(.camera)?.performClick(nil)
    check(p.requests[.camera] == 1 && !prefs().camera.isVisible && note()?.contains("Privacy & Security > Camera") == true,
          "once refused, another click asks nothing and repeats how to allow it")

    toggle(.input)?.performClick(nil)
    check(p.requests[.input] == 1 && w.defaults.bool(forKey: RecordingSourceToggles.inputAskedKey), "turning on clicks and keys asks for Input Monitoring once")
    check(!prefs().clicks.isVisible && !prefs().keystrokes.isVisible && !shows([]) && toggle(.input)?.isSelected == false,
          "refused, clicks and keys stay off")
    check(note() == "Turn on Cornermark in System Settings > Privacy & Security > Input Monitoring, then reopen it.", "and the note says how to allow it",
          detail: note() ?? "nil")
    toggle(.input)?.performClick(nil)
    check(p.requests[.input] == 1, "once asked, another click does not ask again")
    p.input = true
    toggle(.input)?.performClick(nil)
    check(prefs().clicks.isVisible && prefs().keystrokes.isVisible && toggle(.input)?.isSelected == true && p.requests[.input] == 1,
          "with Input Monitoring allowed, one click shows clicks and keys and asks nothing")
    check(p.requests == [.microphone: 1, .camera: 1, .input: 1], "three permissions, one request each, for the whole tour", detail: "\(p.requests)")

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
    check(!prefs().camera.isVisible && p.requests[.camera] == 1, "a click on it asks nothing and writes it off, so Settings agrees")
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
