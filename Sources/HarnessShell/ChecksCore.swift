import AppKit
import Carbon.HIToolbox
import CornermarkCapture
import CornermarkCore
@testable import CornermarkShell

@MainActor
func checkActionTable() async throws {
    section("action table")
    let specs = ActionTable.specs
    let hotKeys = specs.compactMap(\.hotKey)
    check(Set(hotKeys).count == hotKeys.count, "no two actions share a default hotkey", detail: "\(hotKeys.count) hotkeys")
    let paths = specs.compactMap(\.urlPath)
    check(Set(paths).count == paths.count, "no two actions share a URL path", detail: "\(paths)")
    check(Set(specs.map(\.id)) == Set(ActionID.allCases) && specs.count == ActionID.allCases.count, "every ActionID has exactly one table row")

    let captureIDs: [ActionID] = [.allInOne, .area, .window, .fullscreen, .previousArea, .scrolling, .ocr, .timer]
    let codes = captureIDs.map { ActionTable.spec($0).hotKey?.keyCode }
    check(codes == [18, 19, 20, 21, 23, 22, 26, 28], "default hotkeys are Ctrl+Shift+1 to 8 in order", detail: "\(codes)")
    check(captureIDs.allSatisfy { ActionTable.spec($0).hotKey?.modifiers == HotKey.controlShift }, "all default hotkeys use Control and Shift only")
    check(ActionTable.spec(.allInOne).hotKey?.displayString == "\u{2303}\u{21E7}1", "hotkey display string is Mac ordered (control, shift, key)",
          detail: ActionTable.spec(.allInOne).hotKey?.displayString ?? "nil")

    for id in ActionID.allCases where id != .openFile && id != .record {
        let action = AppAction.make(id, timerSeconds: 5)
        check(action?.id == id, "AppAction.make(\(id.rawValue)) maps back to its own id")
    }
    check(AppAction.make(.openFile, timerSeconds: 5) == nil, "openFile needs a URL, so make() returns nil")
    check(AppAction.make(.record, timerSeconds: 5) == nil, "record needs a target, so make() returns nil")
    check(AppAction.make(.timer, timerSeconds: 9) == .capture(.timed(seconds: 9)), "timer action carries the configured seconds")

    let w = try World(after: [])
    defer { w.cleanup() }
    let (_, view) = panelView(w)
    check(pressMenu(.action(.history), in: view), "the panel has a way to the history")
    check(await waitUntil { w.coordinator.history != nil }, "panel item History dispatches through AppAction (history window built)")
    check(w.presented.contains { $0 === w.coordinator.history?.window }, "history window was asked to present")
    check(nothingOnScreen(), "panel dispatch ordered nothing on screen")

    check(pressMenu(.action(.fullscreen), in: view), "the panel has Screen")
    check(await waitUntil { w.store.list().count == 1 }, "panel item Screen reaches the capture store")

    check(pressMenu(.action(.quit), in: view), "the panel has Quit")
    check(await waitUntil { w.quits == 1 }, "panel Quit calls the injected quit")
}

@MainActor
func checkURLScheme() async throws {
    section("URL scheme")
    let w = try World(after: [])
    defer { w.cleanup() }
    func parse(_ s: String) -> Result<AppAction, URLCommandError> { URLCommand.parse(URL(string: s)!, timerSeconds: 5) }
    let expect: [(String, AppAction)] = [
        ("cornermark://capture-area", .capture(.area)), ("cornermark://capture-window", .capture(.window)),
        ("cornermark://capture-fullscreen", .capture(.fullscreen)), ("cornermark://all-in-one", .capture(.allInOne)),
        ("cornermark://previous-area", .capture(.previousArea)), ("cornermark://scrolling", .capture(.scrolling)),
        ("cornermark://ocr", .captureOCR), ("cornermark://history", .openHistory), ("cornermark://settings", .openSettings),
        ("cornermark:///capture-area", .capture(.area)), ("CORNERMARK://Capture-Area", .capture(.area)),
        ("cornermark://timer?seconds=7", .capture(.timed(seconds: 7))), ("cornermark://timer", .capture(.timed(seconds: 5))),
        ("cornermark://timer?seconds=999", .capture(.timed(seconds: 60))),
    ]
    for (s, action) in expect {
        check((try? parse(s).get()) == action, "accepts \(s)", detail: "\(parse(s))")
    }

    let png = w.root.appendingPathComponent("valid image.png")
    try AssetStore.pngData(from: Pix.flat(40, 30, r: 0.2, g: 0.5, b: 0.8))!.write(to: png)
    let encoded = png.path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!
    check((try? parse("cornermark://open?path=\(encoded)").get()) == .openFile(png.standardizedFileURL.resolvingSymlinksInPath()),
          "accepts open?path= for an existing image file (percent-encoded path)", detail: "\(parse("cornermark://open?path=\(encoded)"))")

    let text = w.root.appendingPathComponent("notes.txt")
    try "hello".write(to: text, atomically: true, encoding: .utf8)
    let rejects: [(String, URLCommandError)] = [
        ("cornermark://bogus", .unknownPath("bogus")), ("cornermark://quit", .unknownPath("quit")), ("cornermark://", .missingPath),
        ("cornermark://open", .missingPath), ("cornermark://open?path=", .missingPath), ("https://example.com/capture-area", .wrongScheme),
    ]
    for (s, err) in rejects {
        if case .failure(let e) = parse(s) { check(e == err, "rejects \(s) as \(err)", detail: "\(e)") } else { check(false, "rejects \(s)") }
    }
    for path in ["/definitely/not/here.png", text.path, w.root.path, "relative/path.png", "../etc/passwd"] {
        let q = path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!
        if case .failure(.invalidFile) = parse("cornermark://open?path=\(q)") { check(true, "open rejects \(path)") } else { check(false, "open rejects \(path)") }
    }

    let before = w.store.list().count
    check(w.coordinator.handle(url: URL(string: "cornermark://bogus")!) == false, "handle(url:) ignores an unknown path")
    check(w.coordinator.handle(url: URL(string: "cornermark://open")!) == false, "handle(url:) ignores open without path")
    check(w.coordinator.handle(url: URL(string: "cornermark://capture-fullscreen")!), "handle(url:) performs a known path")
    check(await waitUntil { w.store.list().count == before + 1 }, "cornermark://capture-fullscreen captured through the fixture source")
}

@MainActor
func checkSettingsModel() async throws {
    section("settings model")
    let defaults = MemoryDefaults()

    let store = SettingsStore(defaults: defaults)
    check(store.value == Settings(), "a fresh store holds the defaults")
    check(Settings().afterCapture == [.showOverlay, .copy] && Settings().overlayCorner == .bottomRight && Settings().retentionDays == 30
          && Settings().imageFormat == .png && Settings().overlayAutoClose == 8, "default values: overlay+copy, bottom right, 30 days, PNG, 8 s")

    var custom = Settings()
    custom.afterCapture = [.save, .openEditor]
    custom.saveFolder = "/tmp/shots"
    custom.imageFormat = .jpeg
    custom.playSound = false
    custom.launchAtLogin = true
    custom.customShortcuts = ["area": HotKey(keyCode: 40, modifiers: HotKey.controlShift)]
    custom.disabledShortcuts = ["ocr"]
    custom.overlayCorner = .topLeft
    custom.overlaySize = .large
    custom.overlayAutoClose = nil
    custom.windowShadow = false
    custom.timerSeconds = 12
    custom.retentionDays = 90
    let data = try JSONEncoder().encode(custom)
    check(try JSONDecoder().decode(Settings.self, from: data) == custom, "settings JSON round trip keeps every field, including auto-close Never")
    check(try JSONDecoder().decode(Settings.self, from: data).overlayAutoClose == nil, "auto-close Never survives the round trip as nil")

    store.update { $0 = custom }
    check(SettingsStore(defaults: defaults).value == custom, "a second store on the same defaults reads the saved value")
    check(defaults.data(forKey: SettingsStore.key) != nil && defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("cornermark.") }.count == 1,
          "settings persist as exactly one value under one key")

    let partial = try JSONDecoder().decode(Settings.self, from: Data(#"{"timerSeconds": 9, "unknownFutureKey": 1}"#.utf8))
    check(partial.timerSeconds == 9 && partial.retentionDays == 30 && partial.afterCapture == [.showOverlay, .copy], "missing and extra keys decode with defaults")
    let broken = try JSONDecoder().decode(Settings.self, from: Data(#"{"timerSeconds": "soon", "overlayCorner": "middle"}"#.utf8))
    check(broken.timerSeconds == 5 && broken.overlayCorner == .bottomRight, "wrongly typed values fall back to defaults instead of failing")

    defaults.set(Data("not json".utf8), forKey: SettingsStore.key)
    check(SettingsStore(defaults: defaults).value == Settings(), "an unreadable stored value falls back to defaults")

    var clamped = Settings()
    clamped.timerSeconds = 0; clamped.retentionDays = 99999; clamped.autoCloseSeconds = 0.2
    let n = clamped.normalized()
    check(n.timerSeconds == 1 && n.retentionDays == 3650 && n.autoCloseSeconds == 1, "normalized() clamps timer, retention and auto-close")

    var seen = 0
    let observed = SettingsStore(defaults: defaults)
    observed.observe { _, _ in seen += 1 }
    observed.update { $0.timerSeconds = observed.value.timerSeconds }
    check(seen == 0, "an update that changes nothing does not notify")
    observed.update { $0.timerSeconds = 20 }
    check(seen == 1 && observed.value.timerSeconds == 20, "an update notifies once")

    check(Settings().hotKey(for: .area) == ActionTable.spec(.area).hotKey, "hotKey(for:) falls back to the table default")
    check(custom.hotKey(for: .area)?.keyCode == 40 && custom.hotKey(for: .ocr) == nil, "hotKey(for:) honors custom and disabled")
}

@MainActor
func checkHotKeys() async throws {
    section("global hotkeys (fake backend, nothing registered with the system)")
    let backend = FakeHotKeyBackend()
    var fired: [ActionID] = []
    let manager = HotKeyManager(backend: backend) { fired.append($0) }
    manager.apply(Settings())
    let captureCount = ActionTable.specs.filter { $0.hotKey != nil }.count
    check(backend.registered.count == captureCount && captureCount == 8, "all eight default hotkeys are registered")
    check(manager.status[.area] == .registered && manager.status[.history] == .unassigned, "status distinguishes registered and unassigned")
    check(manager.failures.isEmpty, "no failures with defaults")

    if let areaNumber = backend.registered.first(where: { $0.value == ActionTable.spec(.area).hotKey })?.key {
        backend.press(areaNumber)
        check(fired == [.area], "pressing the area hotkey fires the area action")
    } else { check(false, "area hotkey registered under a number") }

    backend.failing[ActionTable.spec(.window).hotKey!] = Int32(eventHotKeyExistsErr)
    manager.apply(Settings())
    check(manager.failures[.window]?.contains("Taken by") == true, "a taken key surfaces a readable failure", detail: "\(manager.failures)")
    check(backend.registered.count == 7 && backend.unregisterCalls >= 2, "re-applying unregisters first, then registers what still works")

    backend.failing = [:]
    var dup = Settings()
    dup.customShortcuts["ocr"] = ActionTable.spec(.area).hotKey!
    manager.apply(dup)
    check(manager.failures[.ocr]?.contains("Same shortcut as Capture Area") == true, "two actions on one key: the second reports the conflict", detail: "\(manager.failures)")
    check(manager.status[.area] == .registered, "the first holder keeps the key")

    backend.failing[HotKey(keyCode: 40, modifiers: HotKey.controlShift)] = -50
    var odd = Settings()
    odd.customShortcuts["timer"] = HotKey(keyCode: 40, modifiers: HotKey.controlShift)
    manager.apply(odd)
    check(manager.failures[.timer]?.contains("error -50") == true, "an unknown OSStatus is reported with its code")

    var off = Settings()
    off.disabledShortcuts = Set(ActionID.allCases.map(\.rawValue))
    manager.apply(off)
    check(backend.registered.isEmpty && manager.status.values.allSatisfy { $0 == .unassigned }, "disabling every shortcut registers nothing")

    let synth = Synth.keyEvent(nil, 40, "k", modifiers: [.control, .option])
    check(HotKey(event: synth) == HotKey(keyCode: 40, modifiers: UInt32(controlKey | optionKey)), "HotKey(event:) converts an NSEvent to Carbon modifiers")
    check(HotKey(event: Synth.keyEvent(nil, 40, "k")) == nil, "a key without modifiers is not a valid global hotkey")
    check(HotKey(keyCode: 40, modifiers: UInt32(cmdKey | shiftKey)).displayString == "\u{21E7}\u{2318}K", "command shortcuts display as shift, command, key")
}

@MainActor
func checkImageOutput() async throws {
    section("file naming and output")
    let date = Fixture.timestamp(2026, 11, 3, 14, 5, 9)
    check(ImageOutput.fileName(for: date, format: .png) == "Cornermark 2026-11-03 at 14.05.09.png", "file name follows Cornermark YYYY-MM-DD at HH.MM.SS.png",
          detail: ImageOutput.fileName(for: date, format: .png))
    check(ImageOutput.fileName(for: Fixture.timestamp(2026, 1, 2, 3, 4, 5), format: .jpeg) == "Cornermark 2026-01-02 at 03.04.05.jpg", "single digits are zero padded, JPEG uses .jpg")

    let w = try World(after: [])
    defer { w.cleanup() }
    let img = Pix.flat(120, 80, r: 0.9, g: 0.4, b: 0.1)
    let a = try ImageOutput.save(img, format: .png, folder: w.saveDir, date: date)
    let b = try ImageOutput.save(img, format: .png, folder: w.saveDir, date: date)
    check(a.lastPathComponent == "Cornermark 2026-11-03 at 14.05.09.png" && b.lastPathComponent == "Cornermark 2026-11-03 at 14.05.09 2.png",
          "a second save in the same second gets a numeric suffix instead of overwriting", detail: b.lastPathComponent)
    check(Pix.decode(a).map { $0.width == 120 && $0.height == 80 } == true, "saved PNG decodes at the original size")
    let j = try ImageOutput.save(img, format: .jpeg, folder: w.saveDir, date: date)
    check(j.pathExtension == "jpg" && Pix.decode(j)?.width == 120, "saved JPEG decodes")

    check(ImageOutput.copy(img, to: w.pasteboard), "copy reports success")
    check(w.pasteboardImage().map { $0.width == 120 && $0.height == 80 } == true, "private pasteboard holds the PNG")
    check(w.pasteboard.data(forType: .tiff) != nil, "private pasteboard also offers TIFF for older apps")
    check(NSPasteboard.general.name != w.pasteboard.name, "the harness pasteboard is not the general pasteboard")
    ImageOutput.copy(text: "a\nb", to: w.pasteboard)
    check(w.pasteboard.string(forType: .string) == "a\nb" && w.pasteboard.data(forType: .png) == nil, "copying text replaces the image")
}
