import AppKit
import AVFoundation
import CornermarkCapture
import CornermarkCore
import CornermarkDesign
@testable import CornermarkShell

func rgb(_ image: CGImage, _ x: Int, _ y: Int) -> [Int] {
    var px = [UInt8](repeating: 0, count: 4)
    guard let crop = image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)),
          let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return [0, 0, 0] }
    ctx.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
    return [Int(px[0]), Int(px[1]), Int(px[2])]
}

func ringShows(_ file: URL, at seconds: Double) async -> Bool {
    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: file))
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = .zero
    guard let image = try? await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image else { return false }
    let cx = Int(0.15 * 640 * 2), cy = Int(0.2 * 360 * 2)
    return (cx + 16...cx + 44).contains { x in
        let c = rgb(image, x, cy)
        return c[0] > 180 && c[1] > 180 && c[2] < 120
    }
}

@MainActor
func checkRecordingInput() async throws {
    section("clicks and keystrokes settings")
    let d = RecordingPreferences()
    check(!d.clicks.isVisible && !d.keystrokes.isVisible && d.keystrokes.keys == .shortcuts && d.clicks.animates && d.clicks.color == .lemon,
          "defaults: click rings and keystrokes off, Shortcuts only, animated lemon rings")
    check(d.inputCapture(for: .editing) == InputCapture(clicks: true) && d.inputCapture(for: .video).isEmpty && d.inputCapture(for: .gif).isEmpty,
          "by default a project keeps clicks for later and a video or GIF watches nothing")
    check(d.marks(for: .editing) == nil && d.marks(for: .video) != nil, "a project never draws marks into its picture")
    var on = d
    on.clicks.isVisible = true
    on.keystrokes = KeystrokeDisplay(isVisible: true, keys: .all, position: .topCenter, size: .large, theme: .light)
    check(on.inputCapture(for: .video) == InputCapture(clicks: true, keys: .all) && on.inputCapture(for: .gif) == InputCapture(clicks: true, keys: .all),
          "shown marks make a video and a GIF watch what they draw")
    let old = try JSONDecoder().decode(Settings.self, from: Data(#"{"recording":{"fps":30,"showCursor":false}}"#.utf8))
    check(old.recording.clicks == ClickHighlight() && old.recording.keystrokes == KeystrokeDisplay() && old.recording.fps == 30,
          "settings saved before this decode with the marks off and keep the rest")
    var s = Settings()
    s.recording = on
    check(try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(s)) == s, "the mark settings round-trip through JSON")

    section("clicks and keystrokes while recording")
    let (w, _) = try recordingWorld(frames: 200)
    defer { w.cleanup() }
    let c = w.coordinator
    var asked: [InputCapture] = []
    w.env.inputSource = { capture in
        asked.append(capture)
        return ScriptedInputSource(capture: capture, pacing: .fixed(origin: 0, seconds: 10))
    }
    let area = "display=1&x=0&y=0&width=640&height=360"

    var record = await recordOnce(w, area + "&style=video")
    check(asked.isEmpty, "with the defaults a video creates no input source at all")
    if let file = record?.video?.file { check(!(await ringShows(file, at: 0.35)), "and its picture has no ring") }
    record = await recordOnce(w, area)
    if let folder = record?.video?.location, let project = try? RecordingProjectFile.read(from: folder) {
        check(asked.last == InputCapture(clicks: true) && !project.events.clicks.isEmpty && project.events.keys.isEmpty,
              "a project keeps the clicks and no key", detail: "\(project.events.clicks.count) clicks, \(project.events.keys.count) keys")
        check(project.edits.clicks == ClickHighlight() && project.edits.keystrokes == KeystrokeDisplay(), "and starts with the marks as the settings had them, hidden")
    } else { check(false, "the default project can be read") }

    c.perform(.openSettings)
    guard let sw = c.settingsWindow, let pane = sw.panes.first(where: { $0 is RecordingPane }) else { return check(false, "the Recording pane exists") }
    sw.select(pane: pane)
    let page = pane.view
    func popup(_ id: String) -> NSPopUpButton? { findView(id, in: page) as? NSPopUpButton }
    func choose(_ id: String, _ index: Int) { if let p = popup(id) { p.selectItem(at: index); fire(p) } }
    let clickPopups = ["recording.clickColor", "recording.clickStyle", "recording.clickSize"], keyPopups = ["recording.keyMode", "recording.keyPosition", "recording.keySize", "recording.keyStyle"]
    check(popup("recording.clickColor")?.itemTitles == ["Lemon", "White", "Orange", "Red", "Green"] && popup("recording.clickColor")?.itemArray.allSatisfy { $0.image != nil } == true,
          "click color offers five colors, each with its swatch")
    check(popup("recording.clickStyle")?.itemTitles == ["Outline", "Filled"] && popup("recording.clickSize")?.itemTitles == ["Small", "Medium", "Large"],
          "click style offers outline and filled, size small to large")
    check(popup("recording.keyMode")?.itemTitles == ["Shortcuts only", "All keys"] && popup("recording.keyMode")?.titleOfSelectedItem == "Shortcuts only",
          "keys offers Shortcuts only, chosen, and All keys")
    check(popup("recording.keyPosition")?.itemTitles == ["Bottom center", "Bottom left", "Bottom right", "Top center"] && popup("recording.keyStyle")?.itemTitles == ["Dark", "Light"],
          "keystrokes offer four positions and a dark or light style")
    check((clickPopups + keyPopups).allSatisfy { popup($0)?.isEnabled == false } && (findView("recording.clickAnimation", in: page) as? NSControl)?.isEnabled == false,
          "while both are off, their options are dimmed")
    check((clickPopups + keyPopups).map { popup($0)?.accessibilityLabel() ?? "" }
          == ["Ring color", "Ring style", "Ring size", "Keys", "Badge position", "Badge size", "Badge style"],
          "each popup's VoiceOver name starts with its row title and says which choice it is")
    check((findView("recording.inputPermission", in: page) as? NSTextField)?.stringValue == "Allowed"
          && findView("recording.inputPermission.open", in: page)?.isHidden == true, "Input Monitoring reads Allowed, with no button")

    check(click("recording.clicks", in: page) && click("recording.keys", in: page), "Highlight clicks and Show keystrokes clicked on")
    check((clickPopups + keyPopups).allSatisfy { popup($0)?.isEnabled == true }, "and their options wake up")
    choose("recording.keyMode", 1)
    let r = c.settings.value.recording
    check(r.clicks.isVisible && r.keystrokes.isVisible && r.keystrokes.keys == .all, "the pane writes the mark settings", detail: "\(r.clicks) \(r.keystrokes)")
    check(SettingsStore(defaults: w.defaults).value.recording.keystrokes == r.keystrokes, "and they persist")

    record = await recordOnce(w, area + "&style=video")
    check(asked.last == InputCapture(clicks: true, keys: .all), "the next video watches clicks and all keys", detail: "\(String(describing: asked.last))")
    if let file = record?.video?.file {
        check(await ringShows(file, at: 0.35), "and draws a ring 0.05 s after the scripted click")
        check(!(await ringShows(file, at: 0.8)), "which is gone half a second later")
    } else { check(false, "the marked video can be read") }

    record = await recordOnce(w, area)
    if let folder = record?.video?.location, let project = try? RecordingProjectFile.read(from: folder) {
        check(project.events.keys.map(\.label).prefix(3) == ["\u{21E7}\u{2318}4", "h", "e"] && project.edits.keystrokes.keys == .all && project.edits.clicks.isVisible,
              "a project with marks on keeps every key and starts with the marks shown", detail: "\(project.events.keys.map(\.label))")
        if let file = record?.video?.file { check(!(await ringShows(file, at: 0.35)), "while its own video stays free of marks") }
    } else { check(false, "the marked project can be read") }

    choose("recording.keyMode", 0)
    record = await recordOnce(w, area)
    if let folder = record?.video?.location, let project = try? RecordingProjectFile.read(from: folder) {
        check(!project.events.keys.isEmpty && project.events.keys.allSatisfy(\.isCommand), "Shortcuts only stores shortcuts and no typed letter",
              detail: "\(project.events.keys.map(\.label))")
    } else { check(false, "the shortcuts project can be read") }

    section("clicks and keystrokes without Input Monitoring")
    w.env.hasInputPermission = { false }
    pane.refresh()
    let status = findView("recording.inputPermission", in: page) as? NSTextField, open = findView("recording.inputPermission.open", in: page) as? Button
    check(status?.stringValue == "Not allowed" && open?.isHidden == false && open?.variant == .primary, "the pane says Not allowed and offers Open System Settings as the main action")
    open?.performClick(nil)
    check(w.opened.last == AppEnvironment.inputMonitoringPaneURL, "which opens Privacy & Security > Input Monitoring and changes nothing", detail: "\(w.opened.last?.absoluteString ?? "nil")")
    let before = asked.count
    c.hud.show("waiting")
    record = await recordOnce(w, area + "&style=video")
    check(asked.count == before, "a recording then creates no input source")
    check(record?.video?.file != nil && c.hud.lastMessage == "Turn on Input Monitoring to show clicks and keys", "but still records, and says why the marks are missing",
          detail: c.hud.lastMessage ?? "nil")
    if let file = record?.video?.file { check(!(await ringShows(file, at: 0.35)), "with no ring in the picture") }
    check(click("recording.clicks", in: page) && click("recording.keys", in: page), "with both turned off again")
    check(status?.stringValue == "Not allowed" && status?.textColor == DS.Color.textSecondary, "a missing permission is no longer shown as a problem")

    section("input source of an isolated instance")
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("CornermarkHarness-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let env = try AppEnvironment.isolated(root: root, defaults: MemoryDefaults())
    check(env.inputSource(InputCapture(clicks: true, keys: .all)) is ScriptedInputSource && env.hasInputPermission(),
          "a scripted instance replays a script and never needs Input Monitoring")
    check(env.inputSource(InputCapture()) is ScriptedInputSource, "and builds no live source even for an empty capture")
    env.recordingTestWindow?.close()
}
