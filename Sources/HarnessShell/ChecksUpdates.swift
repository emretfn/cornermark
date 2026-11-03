import AppKit
import CornermarkCore
import Foundation
import Security
@testable import CornermarkShell

private let pageURL = "https://github.com/emretfn/cornermark/releases/tag/v0.3.0"
private let dmgURL = "https://github.com/emretfn/cornermark/releases/download/v0.3.0/Cornermark.dmg"

private func releaseJSON(tag: String = "v0.3.0", body: String? = "Notes", page: String = pageURL,
                         assets: [(String, String)] = [("Cornermark.dmg", dmgURL)]) -> Data {
    var object: [String: Any] = ["tag_name": tag, "html_url": page,
                                 "assets": assets.map { ["name": $0.0, "browser_download_url": $0.1] }]
    if let body { object["body"] = body }
    return try! JSONSerialization.data(withJSONObject: object)
}

@MainActor
func checkUpdates() async throws {
    checkVersions()
    checkReleaseParsing()
    checkUpdateState()
    try checkVerification()
    try await checkUpdateFlow()
    try await checkUpdateWiring()
    try checkUpdateSettings()
}

@MainActor
private func checkVersions() {
    section("update versions")
    check(AppVersion("0.2.1") == AppVersion(0, 2, 1) && AppVersion("v0.2.1") == AppVersion(0, 2, 1), "parses 0.2.1 and v0.2.1")
    check(AppVersion("0.2.1")?.description == "0.2.1", "describes itself without the v")
    check(AppVersion(0, 10, 0) > AppVersion(0, 9, 9) && AppVersion(1, 0, 0) > AppVersion(0, 99, 99), "orders numerically, not as text")
    check(AppVersion(0, 2, 1) < AppVersion(0, 2, 2) && !(AppVersion(0, 2, 1) < AppVersion(0, 2, 1)), "orders patch releases")
    let junk = ["", "v", "1", "1.2", "1.2.3.4", "1.2.x", "a.b.c", "1..3", "-1.2.3", "1.2.3-beta", "V1.2.3", "vv1.2.3", " 1.2.3", "1.2.3\n",
                "\u{0661}.2.3", "99999999999999999999.0.0"]
    for s in junk { check(AppVersion(s) == nil, "rejects \(s.debugDescription) as a version") }
}

@MainActor
private func checkReleaseParsing() {
    section("update release parsing")
    let good = try? AppRelease.parse(json: releaseJSON())
    check(good?.version == AppVersion(0, 3, 0) && good?.notes == "Notes", "reads the tag and the notes")
    check(good?.pageURL.absoluteString == pageURL, "reads the release page")
    check(good?.dmgURL?.absoluteString == dmgURL, "takes the DMG from the Cornermark.dmg asset")

    let none = try? AppRelease.parse(json: releaseJSON(assets: []))
    check(none != nil && none?.dmgURL == nil, "a release without assets parses with no DMG")
    let wrongName = try? AppRelease.parse(json: releaseJSON(assets: [
        ("Cornermark.zip", "https://example.com/a.zip"), ("cornermark.dmg", "https://example.com/b.dmg"), ("Cornermark.dmg.sha256", "https://example.com/c"),
    ]))
    check(wrongName != nil && wrongName?.dmgURL == nil, "only an asset named exactly Cornermark.dmg counts")
    let plain = try? AppRelease.parse(json: releaseJSON(assets: [("Cornermark.dmg", "http://example.com/Cornermark.dmg")]))
    check(plain != nil && plain?.dmgURL == nil, "an http download URL is dropped")
    let local = try? AppRelease.parse(json: releaseJSON(assets: [("Cornermark.dmg", "file:///tmp/Cornermark.dmg")]))
    check(local != nil && local?.dmgURL == nil, "a file download URL is dropped")
    let among = try? AppRelease.parse(json: releaseJSON(assets: [("Cornermark.zip", "https://example.com/a.zip"), ("Cornermark.dmg", "https://example.com/b.dmg")]))
    check(among?.dmgURL?.lastPathComponent == "b.dmg", "finds the DMG among other assets")
    check((try? AppRelease.parse(json: releaseJSON(body: nil)))?.notes == "", "a missing body becomes empty notes")

    let bad: [(String, Data)] = [
        ("a non-version tag", releaseJSON(tag: "nightly")),
        ("an http release page", releaseJSON(page: "http://github.com/x")),
        ("text that is not JSON", Data("<html>".utf8)),
        ("an empty object", Data("{}".utf8)),
        ("an array", Data("[]".utf8)),
    ]
    for (name, data) in bad {
        var thrown: UpdateError?
        do { _ = try AppRelease.parse(json: data) } catch { thrown = error as? UpdateError }
        check(thrown == .badResponse, "rejects \(name)", detail: "\(String(describing: thrown))")
    }

    let notes = (1...200).map { "* change number \($0)" }.joined(separator: "\n")
    let long = AppRelease(version: AppVersion(1, 0, 0), notes: notes, pageURL: URL(string: pageURL)!, dmgURL: nil)
    let summary = long.notesSummary(maxCharacters: 100)
    let lines = summary.dropLast().split(separator: "\n")
    check(summary.count <= 101 && summary.hasSuffix("\u{2026}"), "long notes are cut with an ellipsis", detail: summary)
    check(lines.allSatisfy { $0.hasPrefix("* change number ") && Int($0.dropFirst(16)) != nil }, "notes are cut at a line break, not mid-line", detail: summary)
    check(good?.notesSummary() == "Notes", "short notes stay as they are")
}

@MainActor
private func checkUpdateState() {
    section("update menu states")
    let release = AppRelease(version: AppVersion(0, 3, 0), notes: "", pageURL: URL(string: pageURL)!, dmgURL: nil)
    let rows: [(UpdateState, String, Bool)] = [
        (.idle, "Check for Updates\u{2026}", true),
        (.checking(manual: true), "Checking for Updates\u{2026}", false),
        (.checking(manual: false), "Checking for Updates\u{2026}", false),
        (.available(release), "Install Cornermark 0.3.0\u{2026}", true),
        (.installing(release), "Installing Cornermark 0.3.0\u{2026}", false),
    ]
    for (state, title, enabled) in rows {
        check(state.menuTitle == title && state.menuEnabled == enabled, "\(title) is \(enabled ? "enabled" : "disabled")", detail: "\(state.menuTitle) \(state.menuEnabled)")
    }
    let labels: [(UpdateState, String?)] = [
        (.idle, nil), (.checking(manual: true), nil), (.checking(manual: false), nil),
        (.available(release), "Update"), (.installing(release), "Updating\u{2026}"),
    ]
    for (state, label) in labels {
        check(state.statusLabel == label, "\(state.menuTitle) shows \(label.map { "\"\($0)\"" } ?? "no label") in the menu bar", detail: "\(String(describing: state.statusLabel))")
    }
    let button = NSStatusBarButton()
    applyStatusLabel(.available(release), to: button)
    check(button.title == "Update" && button.imagePosition == .imageLeading && button.accessibilityLabel() == "Cornermark, update available",
          "an available update puts the label beside the icon and tells VoiceOver", detail: "\(button.title) \(button.imagePosition.rawValue) \(String(describing: button.accessibilityLabel()))")
    applyStatusLabel(.installing(release), to: button)
    check(button.title == "Updating\u{2026}" && button.imagePosition == .imageLeading, "installing changes the label")
    applyStatusLabel(.idle, to: button)
    check(button.title == "" && button.imagePosition == .imageOnly && button.accessibilityLabel() == "Cornermark", "idle goes back to the bare icon")
}

private func shell(_ tool: String, _ args: [String]) -> Bool {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: tool)
    p.arguments = args
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return false }
    p.waitUntilExit()
    return p.terminationStatus == 0
}

/// A real bundle with a copied system executable, ad-hoc signed unless `sign` is false.
private func makeBundle(in directory: URL, version: String, payload: String, sign: Bool = true) throws -> URL {
    let fm = FileManager.default
    let app = directory.appendingPathComponent("Tiny-\(UUID().uuidString).app", isDirectory: true)
    let contents = app.appendingPathComponent("Contents", isDirectory: true)
    try fm.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
    try fm.createDirectory(at: contents.appendingPathComponent("Resources"), withIntermediateDirectories: true)
    try fm.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: contents.appendingPathComponent("MacOS/Tiny"))
    try Data(payload.utf8).write(to: contents.appendingPathComponent("Resources/data.txt"))
    let plist: [String: Any] = ["CFBundleExecutable": "Tiny", "CFBundleIdentifier": "local.test.tiny", "CFBundlePackageType": "APPL",
                                "CFBundleShortVersionString": version, "CFBundleVersion": "1"]
    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
    if sign, !shell("/usr/bin/codesign", ["--force", "--sign", "-", app.path]) { throw CocoaError(.fileWriteUnknown) }
    return app
}

private func requirement(of bundle: URL) -> SecRequirement? {
    var code: SecStaticCode?
    var req: SecRequirement?
    guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &code) == errSecSuccess, let code,
          SecCodeCopyDesignatedRequirement(code, [], &req) == errSecSuccess else { return nil }
    return req
}

private func outcome(_ body: () throws -> Void) -> UpdateError? {
    do { try body() } catch { return error as? UpdateError }
    return nil
}

@MainActor
private func checkVerification() throws {
    section("update verification on real signed bundles")
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent("CornermarkUpdateVerify-\(UUID().uuidString)", isDirectory: true)
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: dir) }

    let v030 = AppVersion(0, 3, 0), v021 = AppVersion(0, 2, 1)
    let good = try makeBundle(in: dir, version: "0.3.0", payload: "original")
    guard let req = requirement(of: good) else { return check(false, "reads the designated requirement of a signed bundle") }
    check(outcome { try UpdateVerifier.verify(bundle: good, against: req, announced: v030, current: v021) } == nil, "a validly signed newer bundle passes")

    let other = try makeBundle(in: dir, version: "0.3.0", payload: "a different build")
    check(outcome { try UpdateVerifier.verify(bundle: other, against: req, announced: v030, current: v021) } == .signatureMismatch,
          "a bundle signed as something else is refused")
    var stranger: SecRequirement?
    if SecRequirementCreateWithString(#"identifier "local.test.someone-else""# as CFString, [], &stranger) == errSecSuccess, let stranger {
        check(outcome { try UpdateVerifier.verify(bundle: good, against: stranger, announced: v030, current: v021) } == .signatureMismatch,
              "a requirement the bundle does not satisfy is refused")
    } else { check(false, "builds a requirement the bundle cannot meet") }

    let unsigned = try makeBundle(in: dir, version: "0.3.0", payload: "original", sign: false)
    check(outcome { try UpdateVerifier.verify(bundle: unsigned, against: req, announced: v030, current: v021) } == .signatureMismatch, "an unsigned bundle is refused")

    let tampered = dir.appendingPathComponent("Tampered.app", isDirectory: true)
    try fm.copyItem(at: good, to: tampered)
    check(outcome { try UpdateVerifier.verify(bundle: tampered, against: req, announced: v030, current: v021) } == nil, "an untouched copy still passes")
    try Data("changed after signing".utf8).write(to: tampered.appendingPathComponent("Contents/Resources/data.txt"))
    check(outcome { try UpdateVerifier.verify(bundle: tampered, against: req, announced: v030, current: v021) } == .signatureMismatch, "changing a resource after signing is refused")
    let extra = dir.appendingPathComponent("Extra.app", isDirectory: true)
    try fm.copyItem(at: good, to: extra)
    try Data("new".utf8).write(to: extra.appendingPathComponent("Contents/Resources/added.txt"))
    check(outcome { try UpdateVerifier.verify(bundle: extra, against: req, announced: v030, current: v021) } == .signatureMismatch, "adding a file after signing is refused")
    let patched = dir.appendingPathComponent("Patched.app", isDirectory: true)
    try fm.copyItem(at: good, to: patched)
    let exe = patched.appendingPathComponent("Contents/MacOS/Tiny")
    var bytes = try Data(contentsOf: exe)
    bytes.append(0)
    try bytes.write(to: exe)
    check(outcome { try UpdateVerifier.verify(bundle: patched, against: req, announced: v030, current: v021) } == .signatureMismatch, "changing the executable after signing is refused")
    check(outcome { try UpdateVerifier.verify(bundle: dir.appendingPathComponent("missing.app"), against: req, announced: v030, current: v021) } == .signatureMismatch,
          "a path with no bundle is refused")

    check(outcome { try UpdateVerifier.verify(bundle: good, against: req, announced: AppVersion(0, 4, 0), current: v021) } == .versionMismatch,
          "a bundle whose version differs from the release is refused")
    check(outcome { try UpdateVerifier.verify(bundle: good, against: req, announced: v030, current: v030) } == .versionMismatch, "the same version is not an update")
    check(outcome { try UpdateVerifier.verify(bundle: good, against: req, announced: v030, current: AppVersion(0, 10, 0)) } == .versionMismatch, "an older version is not an update")
    check(outcome { try UpdateVerifier.verify(bundle: good, against: req, announced: v030, current: nil) } == .versionMismatch, "an unknown running version refuses to install")

    check(outcome { _ = try UpdateVerifier.runningRequirement() } == .selfNotReleaseSigned, "the ad-hoc harness binary is not release signed")

    section("update bundle swap")
    let a = dir.appendingPathComponent("A", isDirectory: true), b = dir.appendingPathComponent("B", isDirectory: true)
    for (d, text) in [(a, "old"), (b, "new")] {
        try fm.createDirectory(at: d, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: d.appendingPathComponent("id"))
    }
    try UpdateInstaller.swap(b, with: a)
    check((try? String(contentsOf: a.appendingPathComponent("id"), encoding: .utf8)) == "new"
          && (try? String(contentsOf: b.appendingPathComponent("id"), encoding: .utf8)) == "old", "swap exchanges the two folders in one step")
    check((try? UpdateInstaller.swap(dir.appendingPathComponent("nope"), with: a)) == nil
          && (try? String(contentsOf: a.appendingPathComponent("id"), encoding: .utf8)) == "new", "swap with a missing path fails and leaves the target alone")
}

private func release(_ version: AppVersion, dmg: Bool = true) -> AppRelease {
    AppRelease(version: version, notes: "Notes", pageURL: URL(string: "https://github.com/emretfn/cornermark/releases/tag/v\(version)")!,
               dmgURL: dmg ? URL(string: "https://github.com/emretfn/cornermark/releases/download/v\(version)/Cornermark.dmg") : nil)
}

private let newer = release(AppVersion(0, 3, 0))

@MainActor
private func menuItem(_ w: World) -> NSMenuItem? {
    let menu = NSMenu()
    StatusMenuBuilder(coordinator: w.coordinator).populate(menu)
    return menu.items.first { $0.identifier?.rawValue == "checkForUpdates" }
}

@MainActor
private func openEditedEditor(_ w: World) throws -> CaptureRecord {
    let c = w.coordinator
    c.handleCaptured(.init(image: Pix.flat(300, 200, r: 0.7, g: 0.3, b: 0.2), kind: .area, pointScale: 1))
    let record = w.store.list()[0]
    guard let editor = c.openEditor(record) else { throw CocoaError(.fileReadUnknown) }
    editor.perform(.add(Annotation(kind: .rect(CGRect(x: 20, y: 30, width: 100, height: 60), filled: false, cornerRadius: 4),
                                   stroke: Stroke(color: RGBA(1, 0, 0), width: 4))))
    return record
}

@MainActor
private func checkUpdateFlow() async throws {
    section("update flow: checking")
    do {
        let w = try World(after: [])
        defer { w.cleanup() }
        let c = w.coordinator
        w.updateService.latest = .success(release(AppVersion(0, 2, 1)))
        await c.updates.perform()
        check(c.updates.state == .idle && c.hud.lastMessage == "Cornermark is up to date" && w.confirmations.isEmpty, "a manual check on the latest version says it is up to date")
        c.hud.show("clear")
        w.updateService.latest = .success(release(AppVersion(0, 2, 0)))
        await c.updates.perform()
        check(c.updates.state == .idle && c.hud.lastMessage == "Cornermark is up to date" && w.confirmations.isEmpty, "an older release is not an update")
        c.hud.show("clear")
        w.updateService.latest = .success(nil)
        await c.updates.perform()
        check(c.updates.state == .idle && c.hud.lastMessage == "Cornermark is up to date", "no release at all counts as up to date")
        check(w.updateAlerts.isEmpty, "up to date raises no alert")
    }
    do {
        let w = try World(after: [])
        defer { w.cleanup() }
        let c = w.coordinator
        w.updateService.latest = .success(newer)
        var changes: [UpdateState] = []
        c.updates.onStateChange = { changes.append($0) }
        await c.updates.checkAutomatically()
        check(changes == [.checking(manual: false), .available(newer)], "state changes are reported once each, idle to checking to available", detail: "\(changes)")
        await c.updates.checkAutomatically()
        check(changes.count == 2, "a repeated state is not reported again")
        check(c.updates.state == .available(newer), "an automatic check finds a newer release")
        check(c.hud.lastMessage?.hasPrefix("Cornermark 0.3.0 is available") == true && c.hud.lastMessage?.contains("menu") == true, "and tells the user through the HUD", detail: c.hud.lastMessage ?? "nil")
        check(w.confirmations.isEmpty && w.updateAlerts.isEmpty, "an automatic find asks nothing")
        c.hud.show("something else")
        await c.updates.checkAutomatically()
        check(w.updateService.latestCalls == 1 && c.hud.lastMessage == "something else", "later automatic checks neither ask GitHub nor announce again")
        check(menuItem(w)?.title == "Install Cornermark 0.3.0\u{2026}" && menuItem(w)?.isEnabled == true, "the menu offers the install")
    }
    do {
        let w = try World(after: [])
        defer { w.cleanup() }
        let c = w.coordinator
        w.updateService.latest = .success(release(AppVersion(0, 3, 0), dmg: false))
        await c.updates.checkAutomatically()
        check(c.updates.state == .idle && c.hud.lastMessage == nil, "a release whose DMG is not uploaded yet is ignored silently")
        await c.updates.perform()
        check(c.updates.state == .idle && c.hud.lastMessage == "Cornermark is up to date" && w.confirmations.isEmpty, "and a manual check calls it up to date")
    }
    do {
        let w = try World(after: [])
        defer { w.cleanup() }
        let c = w.coordinator
        w.updateService.latest = .failure(UpdateError.network("offline"))
        await c.updates.checkAutomatically()
        check(c.updates.state == .idle && w.updateAlerts.isEmpty && c.hud.lastMessage == nil, "an automatic failure is silent")
        await c.updates.perform()
        check(c.updates.state == .idle && w.updateAlerts.count == 1 && w.updateAlerts[0].message.contains("offline") && !w.updateAlerts[0].offersReleasePage,
              "a manual failure raises an alert without a release page", detail: "\(w.updateAlerts)")
        w.updateService.currentVersion = nil
        w.updateService.latest = .success(newer)
        let calls = w.updateService.latestCalls
        await c.updates.checkAutomatically()
        check(w.updateService.latestCalls == calls && c.updates.state == .idle, "an app with no known version does not ask GitHub")
    }
    do {
        let w = try World(after: [])
        defer { w.cleanup() }
        let c = w.coordinator
        w.updateService.latest = .success(newer)
        w.confirmAnswer = false
        await c.updates.perform()
        check(w.confirmations == [newer] && c.updates.state == .available(newer), "a manual check that finds an update asks right away, and Later keeps it available")
        check(w.updateService.staged.isEmpty && w.quits == 0, "declining downloads nothing")
        await c.updates.perform()
        check(w.confirmations.count == 2 && c.updates.state == .available(newer) && w.updateService.latestCalls == 1, "choosing the menu item again asks again without a new check")
    }
    do {
        let w = try World(after: [])
        defer { w.cleanup() }
        let c = w.coordinator
        w.updateService.latest = .success(newer)
        w.updateService.latestDelay = 0.3
        let first = Task { await c.updates.perform() }
        check(await waitUntil { c.updates.state == .checking(manual: true) }, "a manual check shows as checking")
        check(menuItem(w)?.title == "Checking for Updates\u{2026}" && menuItem(w)?.isEnabled == false, "while checking, the menu item is disabled")
        w.confirmAnswer = false
        await c.updates.perform()
        await c.updates.checkAutomatically()
        check(w.updateService.latestCalls == 1, "choosing it again while checking does nothing")
        await first.value
    }

    section("update flow: installing")
    do {
        let w = try World(after: [])
        defer { w.cleanup() }
        let c = w.coordinator
        let record = try openEditedEditor(w)
        var editorsAtInstall: Int?
        var projectAtInstall: Bool?
        w.updateService.onInstall = { editorsAtInstall = c.editors.count; projectAtInstall = w.store.hasProject(record) }
        w.updateService.latest = .success(newer)
        await c.updates.checkAutomatically()
        await c.updates.perform()
        check(w.confirmations == [newer] && w.updateService.staged == [newer], "confirming stages the release")
        check(editorsAtInstall == 0 && projectAtInstall == true, "open editors are closed, and their edits saved, before the app is replaced",
              detail: "\(String(describing: editorsAtInstall)) \(String(describing: projectAtInstall))")
        check(w.updateService.installed.count == 1 && w.quits == 1, "the app swaps itself and then quits")
        check(c.updates.state == .installing(newer) && w.updateAlerts.isEmpty, "the state stays installing until the app exits")
        check(menuItem(w)?.title == "Installing Cornermark 0.3.0\u{2026}" && menuItem(w)?.isEnabled == false, "the menu shows the install in progress, disabled")
        await c.updates.perform()
        check(w.updateService.staged.count == 1 && w.quits == 1, "choosing it while installing does nothing")
    }
    do {
        let w = try World(after: [])
        defer { w.cleanup() }
        let c = w.coordinator
        _ = try openEditedEditor(w)
        w.updateService.latest = .success(newer)
        w.updateService.staging = .failure(UpdateError.signatureMismatch)
        await c.updates.checkAutomatically()
        var changes: [UpdateState] = []
        c.updates.onStateChange = { changes.append($0) }
        await c.updates.perform()
        check(changes == [.installing(newer), .available(newer)], "a failed install is reported as installing, then back to available", detail: "\(changes)")
        check(c.updates.state == .available(newer), "a failed download goes back to available")
        check(w.updateAlerts.count == 1 && w.updateAlerts[0].message == UpdateError.signatureMismatch.message && w.updateAlerts[0].offersReleasePage,
              "the user sees why, with a way to the release page", detail: "\(w.updateAlerts)")
        check(w.opened.isEmpty && w.quits == 0 && w.updateService.installed.isEmpty, "dismissing the alert opens nothing and quits nothing")
        check(c.editors.count == 1, "a failed download leaves editors open")
        w.alertOpensPage = true
        await c.updates.perform()
        check(w.opened == [newer.pageURL], "the alert's button opens the release page", detail: "\(w.opened)")
        check(menuItem(w)?.title == "Install Cornermark 0.3.0\u{2026}" && menuItem(w)?.isEnabled == true, "the install can be tried again from the menu")
    }
    do {
        let w = try World(after: [])
        defer { w.cleanup() }
        let c = w.coordinator
        w.updateService.latest = .success(newer)
        w.updateService.installing = .failure(UpdateError.cannotReplace(path: "/Volumes/Cornermark/Cornermark.app"))
        await c.updates.checkAutomatically()
        await c.updates.perform()
        check(c.updates.state == .available(newer) && w.quits == 0, "a failed swap goes back to available without quitting")
        check(w.updateService.discarded.count == 1, "and removes the staged copy")
        check(w.updateAlerts.first?.message.contains("/Volumes/Cornermark/Cornermark.app") == true && w.updateAlerts.first?.offersReleasePage == true,
              "the alert names where the app could not be replaced", detail: "\(w.updateAlerts)")
    }
}

@MainActor
private func checkUpdateWiring() async throws {
    section("update wiring: action, URL, menu, schedule")
    let spec = ActionTable.spec(.checkForUpdates)
    check(spec.hotKey == nil && spec.urlPath == "check-for-updates" && spec.menuGroup == 2, "Check for Updates is a menu action in the windows group with no hotkey")
    check(AppAction.make(.checkForUpdates, timerSeconds: 5) == .checkForUpdates && AppAction.checkForUpdates.id == .checkForUpdates, "the action maps to its own id")
    check((try? URLCommand.parse(URL(string: "cornermark://check-for-updates")!).get()) == .checkForUpdates, "cornermark://check-for-updates parses")

    do {
        let w = try World(after: [])
        defer { w.cleanup() }
        let menu = NSMenu()
        StatusMenuBuilder(coordinator: w.coordinator).populate(menu)
        let titles = menu.items.filter { !$0.isSeparatorItem }.map(\.title)
        check(titles.firstIndex(of: "Settings\u{2026}").map { titles[$0 + 1] } == "Check for Updates\u{2026}", "the menu lists it after Settings", detail: "\(titles)")
        check(menuItem(w)?.isEnabled == true && menuItem(w)?.keyEquivalent == "", "idle, it is enabled and shows no shortcut")
        w.updateService.latest = .success(nil)
        let item = menuItem(w)!
        _ = item.target?.perform(item.action, with: item)
        check(await waitUntil { w.coordinator.hud.lastMessage == "Cornermark is up to date" }, "choosing the menu item runs a check")
        check(w.coordinator.handle(url: URL(string: "cornermark://check-for-updates")!), "the URL scheme accepts it")
        check(await waitUntil { w.updateService.latestCalls == 2 }, "and runs a check")
    }
    do {
        let w = try World(after: [])
        defer { w.cleanup() }
        w.updateService.latest = .success(newer)
        w.coordinator.startMaintenance()
        check(await waitUntil { w.coordinator.updates.state == .available(newer) }, "starting up checks for updates by default")
    }
    do {
        let w = try World(after: [])
        defer { w.cleanup() }
        w.settings.update { $0.checkForUpdatesAutomatically = false }
        w.updateService.latest = .success(newer)
        w.coordinator.startMaintenance()
        w.coordinator.checkForUpdatesIfWanted()
        try? await Task.sleep(nanoseconds: 100_000_000)
        check(w.updateService.latestCalls == 0 && w.coordinator.updates.state == .idle, "with the setting off, nothing asks GitHub")
        w.coordinator.perform(.checkForUpdates)
        check(await waitUntil { w.updateService.latestCalls == 1 }, "a manual check still works with the setting off")
    }
}

@MainActor
private func checkUpdateSettings() throws {
    section("update setting")
    check(Settings().checkForUpdatesAutomatically, "automatic checks are on by default")
    let old = try JSONDecoder().decode(Settings.self, from: Data(#"{"timerSeconds": 9}"#.utf8))
    check(old.checkForUpdatesAutomatically && old.timerSeconds == 9, "settings saved before this key existed decode with checks on")
    let off = try JSONDecoder().decode(Settings.self, from: Data(#"{"checkForUpdatesAutomatically": false}"#.utf8))
    check(!off.checkForUpdatesAutomatically, "an explicit off is kept")
    let junk = try JSONDecoder().decode(Settings.self, from: Data(#"{"checkForUpdatesAutomatically": "no"}"#.utf8))
    check(junk.checkForUpdatesAutomatically, "a wrongly typed value falls back to on")

    let suite = "local.emretufan.cornermark.harness.updates.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = SettingsStore(defaults: defaults)
    store.update { $0.checkForUpdatesAutomatically = false }
    check(!SettingsStore(defaults: defaults).value.checkForUpdatesAutomatically, "turning it off survives a relaunch")
    let decoded = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(store.value))
    check(decoded == store.value, "settings with the new key round trip through JSON")
}
