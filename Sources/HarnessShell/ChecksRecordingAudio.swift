import AppKit
import AVFoundation
import CornermarkCapture
import CornermarkCore
import CornermarkDesign
import CornermarkVideoEditor
@testable import CornermarkShell

struct SoundFacts: Equatable {
    var tracks = 0
    var channels = 0
    var duration = 0.0
    var isAAC = false
}

func soundFacts(_ url: URL) async -> SoundFacts {
    let asset = AVURLAsset(url: url)
    let tracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
    guard let track = tracks.first, let format = (try? await track.load(.formatDescriptions))?.first,
          let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee else { return SoundFacts() }
    let range = (try? await track.load(.timeRange)) ?? .zero
    return SoundFacts(tracks: tracks.count, channels: Int(asbd.mChannelsPerFrame), duration: range.duration.seconds, isAAC: asbd.mFormatID == kAudioFormatMPEG4AAC)
}

/// A world whose microphones and system sound are scripts with fixed pacing, lined up with the scripted frames, and whose access answer
/// is set by the check. `asked` counts the sources each recording built, and `requests` the access requests.
@MainActor
final class SoundWorld {
    let world: World
    var access = MicrophoneAccess.allowed
    var requests = 0
    var micsMade: [String?] = []
    var systemsMade = 0

    init(frames: Int = 120, realtime: Bool = false, mic: AudioPattern? = nil) throws {
        let (w, _) = try recordingWorld(frames: frames)
        world = w
        if realtime {
            w.env.frameSource = { target, options in
                let area: CGRect? = { if case .display(_, let a) = target { return a } else { return nil } }()
                return FixtureFrameSource(area: area, options: options, cursor: .tour, pacing: .realtime)
            }
        }
        w.env.microphones = { ScriptedAudioSource.microphones }
        w.env.microphoneAccess = { [unowned self] in access }
        w.env.requestMicrophoneAccess = { [unowned self] done in requests += 1; done(false) }
        w.env.microphoneSource = { [unowned self] id in
            micsMade.append(id)
            // A live check needs sound whatever the clock says, so it uses the voice without the tour's muted stretch.
            if realtime { return ScriptedAudioSource(pattern: mic ?? .voice(leftOnly: id == ScriptedAudioSource.microphones[1].id)) }
            return ScriptedAudioSource.microphone(id, pacing: .fixed(origin: 0, seconds: 10))
        }
        w.env.systemAudioSource = { [unowned self] _ in
            systemsMade += 1
            return ScriptedAudioSource(pattern: .systemTour, pacing: realtime ? .realtime : .fixed(origin: 0, seconds: 10))
        }
    }
}

@MainActor
func checkRecordingAudio() async throws {
    section("audio settings model")
    let d = RecordingPreferences()
    check(!d.audio.microphone && !d.audio.systemAudio && d.audio.mono && d.audio.microphoneID == nil,
          "defaults: no microphone, no system audio, mono on, the system's default input")
    var on = d
    on.audio.microphone = true
    on.audio.systemAudio = true
    check(on.options(for: .video).capturesSystemAudio && on.options(for: .editing).capturesSystemAudio && !on.options(for: .gif).capturesSystemAudio
          && on.audio(for: .gif).isEmpty, "a video and a project ask the stream for system sound, a GIF never records sound")
    let old = try JSONDecoder().decode(Settings.self, from: Data(#"{"recording":{"fps":30,"audio":{"systemAudio":true}}}"#.utf8))
    check(old.recording.fps == 30 && old.recording.audio.systemAudio && old.recording.audio.mono && !old.recording.audio.microphone,
          "settings with part of the audio decode and keep the rest at defaults")
    var s = Settings()
    s.recording = on
    s.recording.audio.microphoneID = "scripted.interface"
    check(try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(s)) == s, "the audio settings round-trip through JSON")

    section("Audio settings pane")
    let sound = try SoundWorld(realtime: true)
    let w = sound.world
    defer { w.cleanup() }
    let c = w.coordinator
    sound.access = .notAsked
    c.perform(.openSettings)
    guard let sw = c.settingsWindow, let pane = sw.panes.first(where: { $0 is AudioPane }) as? AudioPane else { return check(false, "the Audio pane exists") }
    sw.select(pane: pane)
    let page = pane.view
    let device = findView("audio.device", in: page) as? NSPopUpButton
    let status = findView("audio.access", in: page) as? NSTextField, open = findView("audio.access.open", in: page) as? Button
    check(device?.itemTitles == ["System default", "Test Microphone", "Test Interface, input 1 of 2"] && device?.indexOfSelectedItem == 0,
          "the device menu lists the system default, chosen, then each microphone")
    check(device?.isEnabled == false && (findView("audio.mono", in: page) as? NSControl)?.isEnabled == false && !pane.isListening,
          "while the microphone is off its options are dimmed and nothing listens")
    check(status?.stringValue == "Not asked yet" && status?.textColor == DS.Color.textSecondary, "access reads Not asked yet, not as a problem")
    check(click("audio.microphone", in: page), "Record microphone clicked on")
    check(sound.requests == 1 && c.settings.value.recording.audio.microphone, "turning it on asks for access once, through the environment",
          detail: "\(sound.requests)")
    check(status?.stringValue == "Not asked yet" && !pane.isListening, "with no answer nothing listens")
    let request = findView("audio.access.request", in: page) as? Button
    check(request?.isHidden == false && request?.variant == .primary && open?.isHidden == true,
          "while it is not asked yet, Request Access is the main action, because System Settings lists the app only after it asked")
    request?.performClick(nil)
    check(sound.requests == 2, "and asks once more when pressed")
    sound.access = .allowed
    pane.refresh()
    check(status?.stringValue == "Allowed" && open?.isHidden == true && pane.isListening && sound.micsMade.last == .some(nil),
          "once allowed, the pane listens to the default microphone to show its level")
    _ = await waitUntil(1) { pane.meter.shown > 0.2 }
    check(pane.meter.shown > 0.2, "and the meter fills with the voice", detail: "\(pane.meter.shown)")
    device?.selectItem(at: 2)
    if let device { fire(device) }
    check(c.settings.value.recording.audio.microphoneID == "scripted.interface" && sound.micsMade.last == "scripted.interface" && pane.isListening,
          "choosing a device saves it and listens to that device instead")
    check(click("audio.mono", in: page) && !c.settings.value.recording.audio.mono, "Record in mono clicked off")
    check(click("audio.system", in: page) && c.settings.value.recording.audio.systemAudio, "Record system audio clicked on")
    sw.select(pane: sw.panes[0])
    check(!pane.isListening && pane.meter.shown == 0, "leaving the pane stops listening and empties the meter")
    sound.access = .denied
    sw.select(pane: pane)
    check(status?.stringValue == "Not allowed" && status?.textColor == DS.Color.dangerText && open?.isHidden == false && open?.variant == .primary
          && !pane.isListening, "denied access is shown as the problem, with Open System Settings as the main action")
    open?.performClick(nil)
    check(w.opened.last == AppEnvironment.microphonePaneURL, "which opens Privacy & Security > Microphone", detail: w.opened.last?.absoluteString ?? "nil")
    check(sound.requests == 2 && request?.isHidden == true, "and nothing asked for access again, with Request Access gone")
    sound.access = .allowed
    pane.refresh()
    device?.selectItem(at: 2)
    w.settings.update { $0.recording.audio.microphoneID = "unplugged.usb.mic" }
    pane.refresh()
    check(device?.titleOfSelectedItem == "Disconnected microphone" && collectAudioText(page).contains("This microphone is not connected. Recordings use System default until it is back."),
          "a chosen microphone that is not connected stays chosen and the row says what records instead")
    sw.window?.close()

    section("microphone and system sound while recording")
    let rec = try SoundWorld()
    let rw = rec.world
    defer { rw.cleanup() }
    rw.settings.update { $0.recording.audio.microphone = true; $0.recording.audio.systemAudio = true }
    let area = "display=1&x=0&y=0&width=640&height=360"
    var record = await recordOnce(rw, area + "&style=video")
    if let file = record?.video?.file {
        let facts = await soundFacts(file)
        let video = (try? await AVURLAsset(url: file).load(.duration).seconds) ?? 0
        check(facts.tracks == 1 && facts.channels == 2 && facts.isAAC && abs(facts.duration - video) < 0.05,
              "a video has one AAC stereo track, the mix, as long as its pictures", detail: "\(facts) video \(video)")
        let left = (try? FileManager.default.contentsOfDirectory(atPath: rw.saveDir.path)) ?? []
        check(left == [file.lastPathComponent], "and the saved folder holds only the video, no hidden sound file", detail: "\(left)")
    } else { check(false, "the video with sound is listed") }
    record = await recordOnce(rw, area)
    if let folder = record?.video?.location, let project = try? RecordingProjectFile.read(from: folder) {
        let files = Set((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
        check(files == ["screen.mp4", "mic.m4a", "system.m4a", "project.json"] && project.source.microphone == "mic.m4a" && project.source.systemAudio == "system.m4a",
              "a project keeps mic.m4a and system.m4a beside screen.mp4 and names them", detail: "\(files)")
        let mic = await soundFacts(folder.appendingPathComponent("mic.m4a")), system = await soundFacts(folder.appendingPathComponent("system.m4a"))
        check(mic.channels == 1 && system.channels == 2 && abs(mic.duration - project.source.duration) < 0.05 && abs(system.duration - project.source.duration) < 0.05,
              "the microphone is mono by default and both tracks last as long as the video", detail: "mic \(mic) system \(system) video \(project.source.duration)")
    } else { check(false, "the project with sound is read") }
    let made = (rec.micsMade.count, rec.systemsMade)
    record = await recordOnce(rw, area + "&style=gif")
    check(record?.video?.format == .gif && rec.micsMade.count == made.0 && rec.systemsMade == made.1, "a GIF builds no sound source at all")

    rec.access = .denied
    rw.coordinator.hud.show("waiting")
    record = await recordOnce(rw, area + "&style=video")
    if let file = record?.video?.file {
        let facts = await soundFacts(file)
        check(facts.tracks == 1 && rec.micsMade.count == made.0, "without microphone access the video still has system sound and no microphone was built")
        check(rw.coordinator.hud.lastMessage == "Turn on microphone access in System Settings to record your voice", "and a notice says why",
              detail: rw.coordinator.hud.lastMessage ?? "nil")
    } else { check(false, "the video without microphone access is listed") }
    check(rec.requests == 0, "a recording never asks for access")

    section("export keeps the sound")
    rec.access = .allowed
    record = await recordOnce(rw, area)
    if let folder = record?.video?.location, let project = try? RecordingProjectFile.read(from: folder) {
        let out = rw.root.appendingPathComponent("exported.mp4")
        let report = try await VideoExporter.export(project: project, video: folder.appendingPathComponent(project.source.video), settings: ExportSettings(), to: out)
        let facts = await soundFacts(out)
        check(report.hasAudio && facts.tracks == 1 && facts.channels == 2 && abs(facts.duration - report.duration) < 0.05,
              "an exported project carries its microphone and system sound mixed into one track", detail: "\(facts) video \(report.duration)")
    } else { check(false, "the project to export is read") }

    section("a silent microphone while recording")
    let quiet = try SoundWorld(realtime: true, mic: .voice(silent: 0..<3.6))
    let qw = quiet.world
    defer { qw.cleanup() }
    qw.settings.update { $0.recording.audio.microphone = true }
    let q = qw.coordinator
    guard q.handle(url: URL(string: "\(URLCommand.scheme)://record?\(area)&style=video")!), await waitUntil(3, { q.recording.phase == .recording }) else {
        return check(false, "a live recording with a silent microphone starts")
    }
    let bar = q.controls.barView
    check(bar?.showsMicrophone == true && bar?.microphone.silent.isHidden == true, "the control bar shows the microphone's level, with no warning yet")
    let turnedSilent = await waitUntil(4) { q.recording.microphone?.isSilent == true }
    let at = q.recording.seconds
    check(turnedSilent && at >= 2.9 && at < 3.6, "after 3 s with no sound the microphone counts as silent", detail: "\(at)")
    let menu = MenuPanelModel.make(settings: qw.settings.value, update: .idle, overlaysHidden: false, canRestoreOverlay: false, pins: [],
                                   recording: q.recording.phase, microphoneSilent: true, recent: [])
    check("\(menu.sections)".contains("No sound from the microphone. Check that it is not muted."),
          "the menu panel, the keyboard path while recording, says what to check")
    check(bar?.microphone.silent.isHidden == false && bar?.microphone.meter.isHidden == true && bar?.microphone.silent.text == "No sound",
          "and the bar swaps the meter for a No sound warning in the same place")
    let width = bar?.frame.width
    let back = await waitUntil(3) { q.recording.microphone?.isSilent == false }
    check(back && bar?.microphone.silent.isHidden == true && bar?.frame.width == width, "sound coming back clears it without moving the buttons")
    q.recording.pause()
    _ = await waitUntil(0.2) { false }
    check(q.recording.microphone?.isSilent == false, "a pause never counts as silence")
    q.recording.resume()
    q.recording.stop()
    _ = await waitUntil(10) { q.recording.phase == .idle }
    check(q.controls.barView == nil && q.recording.microphone == nil, "the meter goes with the bar")

    section("sound of an isolated instance")
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("CornermarkHarness-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let env = try AppEnvironment.isolated(root: root, defaults: MemoryDefaults())
    check(env.microphoneSource(nil) is ScriptedAudioSource && env.systemAudioSource(FixtureFrameSource(pacing: .manual)) is ScriptedAudioSource
          && env.microphoneAccess() == .allowed && env.microphones() == ScriptedAudioSource.microphones,
          "a scripted instance records scripted sound and lists only scripted microphones")
    var refused: Bool?
    env.requestMicrophoneAccess { refused = !$0 }
    check(refused == true && MicrophoneAccess.requests == 0, "and refuses to ask for access")
    var options = RecordingOptions()
    options.capturesSystemAudio = true
    if let source = try? AppEnvironment.isolatedFrameSource(.display(1, area: nil), options, testWindow: env.recordingTestWindow!) {
        check(source is FixtureFrameSource, "its display recording films the synthetic display")
    }
    env.recordingTestWindow?.close()
}

func collectAudioText(_ view: NSView) -> [String] {
    ((view as? NSTextField).map { [$0.stringValue] } ?? []) + view.subviews.flatMap(collectAudioText)
}
