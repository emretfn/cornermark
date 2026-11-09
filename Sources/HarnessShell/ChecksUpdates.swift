import AppKit
import CornermarkCore
import CornermarkDesign
import CornermarkL10n
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
    checkReleaseNotes()
    checkReleaseList()
    try await checkWhatsNew()
    try await checkUpdatedHUD()
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
    check(lines.allSatisfy { $0.hasPrefix("\u{2022} Change number ") && Int($0.dropFirst(16)) != nil }, "notes are cut at a line break, not mid-line", detail: summary)
    check(good?.notesSummary() == "\u{2022} Notes", "short notes stay as they are")
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
private func checkRow(_ w: World) -> MenuPanelModel.Row? { panelModel(w).row(.checkForUpdates) }

@MainActor
private func banner(_ w: World) -> MenuPanelModel.UpdateBanner? { panelModel(w).banner }

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
        check(banner(w)?.title == "Cornermark 0.3.0" && banner(w)?.button == .action(.checkForUpdates) && checkRow(w) == nil, "the panel offers the install")
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
        check(checkRow(w)?.title == "Checking for Updates\u{2026}" && checkRow(w)?.isEnabled == false && banner(w) == nil, "while checking, the panel row is disabled")
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
        check(banner(w)?.detail == "Installing\u{2026}" && banner(w)?.button == nil && checkRow(w) == nil, "the panel shows the install in progress, with nothing to press")
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
        check(banner(w)?.button == .action(.checkForUpdates), "the install can be tried again from the panel")
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
        let titles = panelModel(w).footerRows.map(\.title)
        check(titles.firstIndex(of: "What's New\u{2026}").map { titles[$0 + 1] } == "Check for Updates\u{2026}", "the panel lists it right after What's New", detail: "\(titles)")
        check(titles.firstIndex(of: "Check for Updates\u{2026}").map { titles[$0 + 1] } == "Settings\u{2026}", "and Settings after it", detail: "\(titles)")
        check(checkRow(w)?.isEnabled == true, "idle, it is enabled")
        w.updateService.latest = .success(nil)
        let (_, view) = panelView(w)
        check(pressMenu(.action(.checkForUpdates), in: view), "the panel has it")
        check(await waitUntil { w.coordinator.hud.lastMessage == "Cornermark is up to date" }, "choosing the panel row runs a check")
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

    let defaults = MemoryDefaults()
    let store = SettingsStore(defaults: defaults)
    store.update { $0.checkForUpdatesAutomatically = false }
    check(!SettingsStore(defaults: defaults).value.checkForUpdatesAutomatically, "turning it off survives a relaunch")
    let decoded = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(store.value))
    check(decoded == store.value, "settings with the new key round trip through JSON")

    check(Settings().lastRunVersion == nil, "no version has run by default")
    check(old.lastRunVersion == nil, "settings saved before lastRunVersion existed decode with none")
    let ran = try JSONDecoder().decode(Settings.self, from: Data(#"{"lastRunVersion": "0.2.1"}"#.utf8))
    check(ran.lastRunVersion == "0.2.1", "a stored version is read")
    let wrong = try JSONDecoder().decode(Settings.self, from: Data(#"{"lastRunVersion": 3}"#.utf8))
    check(wrong.lastRunVersion == nil, "a wrongly typed version falls back to none")
    store.update { $0.lastRunVersion = "0.3.0" }
    check(SettingsStore(defaults: defaults).value.lastRunVersion == "0.3.0", "the last run version survives a relaunch")
    check(try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(store.value)) == store.value, "settings with a last run version round trip through JSON")
}

private let realBody = """
## [0.2.1](https://github.com/emretfn/cornermark/compare/v0.2.0...v0.2.1) (2026-11-03)


### Bug Fixes

* **settings:** show refused keys and held modifiers in ShortcutRecorderView ([#4](https://github.com/emretfn/cornermark/issues/4)) ([28cff43](https://github.com/emretfn/cornermark/commit/28cff436fd27128861701118d137af89))
"""

@MainActor
private func checkReleaseNotes() {
    section("release notes parsing")
    let real = ReleaseNotes(markdown: realBody)
    check(real.sections == [.init(title: "Fixed", items: ["Show refused keys and held modifiers in ShortcutRecorderView"])],
          "a release-please body reads as one Fixed item without version line, scope, issue or commit links", detail: "\(real.sections)")

    let mixed = ReleaseNotes(markdown: """
    ## [0.3.0](https://github.com/emretfn/cornermark/compare/v0.2.1...v0.3.0) (2026-11-10)

    ### Features

    * **editor:** add a **blur** tool ([#9](https://github.com/emretfn/cornermark/issues/9)) ([abcdef0](https://github.com/emretfn/cornermark/commit/abcdef0))
    - see [the guide](https://example.com/guide) for more

    ### Bug Fixes

    * stop the crop handle from jumping

    ### Performance Improvements

    * open History faster
    """)
    check(mixed.sections.map(\.title) == ["New", "Fixed", "Performance Improvements"], "Features becomes New, Bug Fixes becomes Fixed, other titles stay", detail: "\(mixed.sections.map(\.title))")
    check(mixed.sections.first?.items == ["Add a blur tool", "See the guide for more"], "stray ** go, links keep their text, the first letter is capitalized, - bullets count", detail: "\(mixed.sections.first?.items ?? [])")
    check(mixed.sections[1].items == ["Stop the crop handle from jumping"], "an item with no scope or links only gets its first letter raised")

    let already = ReleaseNotes(markdown: "### New\n* a\n### Fixed\n* b\n### Fixed\n* c")
    check(already.sections == [.init(title: "New", items: ["A"]), .init(title: "Fixed", items: ["B", "C"])], "New and Fixed stay, and a repeated title shares one section", detail: "\(already.sections)")

    let loose = ReleaseNotes(markdown: "* before any heading\n\n### Fixed\n* after")
    check(loose.sections.first == .init(title: "", items: ["Before any heading"]) && loose.sections.count == 2, "bullets before a heading go in a section with no title", detail: "\(loose.sections)")
    check(ReleaseNotes(markdown: "### Fixed\n\n### New\n* kept").sections == [.init(title: "New", items: ["Kept"])], "a heading with no bullets is dropped")

    let prose = ReleaseNotes(markdown: "## Heads up\n\nThis one rewrites the **editor**.\nIt is faster.\n\nSee [notes](https://example.com).\n")
    check(prose.sections == [.init(title: "", items: ["This one rewrites the editor. It is faster.", "See notes."])], "hand-written prose becomes one item per paragraph", detail: "\(prose.sections)")
    check(ReleaseNotes(markdown: "").sections.isEmpty && ReleaseNotes(markdown: " \n\n\t\n").sections.isEmpty, "an empty body has no sections")
    check(ReleaseNotes(markdown: "## [0.1.0](https://example.com) (2026-01-01)").sections.isEmpty, "a body that is only the version line has no sections")
    let crlf = ReleaseNotes(markdown: "### Features\r\n\r\n* one\r\n* two\r\n")
    check(crlf.sections == [.init(title: "New", items: ["One", "Two"])], "Windows line endings read the same", detail: "\(crlf.sections)")

    check(real.plainText == "Fixed\n\u{2022} Show refused keys and held modifiers in ShortcutRecorderView", "plain text is the title, then bullet lines", detail: real.plainText)
    check(ReleaseNotes(markdown: "### New\n* a\n* b\n### Fixed\n* c").plainText == "New\n\u{2022} A\n\u{2022} B\n\nFixed\n\u{2022} C", "sections are separated by a blank line")
    check(loose.plainText.hasPrefix("\u{2022} Before any heading\n\nFixed"), "a section with no title prints no title line", detail: loose.plainText)

    let alert = AppRelease(version: AppVersion(0, 2, 1), notes: realBody, pageURL: URL(string: pageURL)!, dmgURL: nil).notesSummary()
    check(alert == real.plainText && !alert.contains("http") && !alert.contains("](") && !alert.contains("**") && !alert.contains("#"),
          "the update alert text has no URL, link markup or **", detail: alert)
}

private func entryJSON(_ tag: String?, body: String = "### Bug Fixes\n* fix\n", published: String? = "2026-11-03T10:15:00Z", draft: Bool? = nil, prerelease: Bool? = nil) -> [String: Any] {
    var o: [String: Any] = ["body": body]
    if let tag { o["tag_name"] = tag }
    if let published { o["published_at"] = published }
    if let draft { o["draft"] = draft }
    if let prerelease { o["prerelease"] = prerelease }
    return o
}

@MainActor
private func checkReleaseList() {
    section("release history parsing")
    let list: [[String: Any]] = [
        entryJSON("v0.2.0"), entryJSON("v0.3.0", draft: true), entryJSON("v0.10.0"), entryJSON("v0.4.0-beta.1", prerelease: false),
        entryJSON("v0.5.0", prerelease: true), entryJSON("v0.2.1", draft: false, prerelease: false), entryJSON(nil), entryJSON("nightly"),
    ]
    let parsed = try? ReleaseEntry.parseList(json: JSONSerialization.data(withJSONObject: list))
    check(parsed?.map(\.version) == [AppVersion(0, 10, 0), AppVersion(0, 2, 1), AppVersion(0, 2, 0)],
          "drafts, pre-releases and tags that are not versions are skipped, newest version first", detail: "\(String(describing: parsed?.map(\.version)))")
    check(parsed?.first?.notes.sections == [.init(title: "Fixed", items: ["Fix"])], "each entry carries its parsed notes")
    check(parsed?.first?.publishedAt == ISO8601DateFormatter().date(from: "2026-11-03T10:15:00Z"), "and its publish date")

    let undated = try? ReleaseEntry.parseList(json: JSONSerialization.data(withJSONObject: [entryJSON("v1.0.0", published: nil), entryJSON("v1.0.1", published: "yesterday")]))
    check(undated?.count == 2 && undated?.allSatisfy { $0.publishedAt == nil } == true, "a missing or unreadable date leaves the entry without one")
    let bodyless = try? ReleaseEntry.parseList(json: Data(#"[{"tag_name": "v1.0.0"}]"#.utf8))
    check(bodyless?.first?.notes.sections.isEmpty == true, "a missing body is empty notes")
    check((try? ReleaseEntry.parseList(json: Data("[]".utf8)))?.isEmpty == true, "an empty list is an empty history")
    for (name, data) in [("text that is not JSON", Data("<html>".utf8)), ("an object", Data("{}".utf8)), ("an array of numbers", Data("[1]".utf8))] {
        var thrown: UpdateError?
        do { _ = try ReleaseEntry.parseList(json: data) } catch { thrown = error as? UpdateError }
        check(thrown == .badResponse, "rejects \(name)", detail: "\(String(describing: thrown))")
    }
}

private func entry(_ version: AppVersion, body: String = "### Bug Fixes\n* **editor:** fix \(UUID().uuidString.prefix(4)) thing", date: Date? = Date(timeIntervalSince1970: 1_793_700_000)) -> ReleaseEntry {
    ReleaseEntry(version: version, publishedAt: date, notes: ReleaseNotes(markdown: body))
}

@MainActor
private func labels(in view: NSView?) -> [NSTextField] {
    guard let view else { return [] }
    return ((view as? NSTextField).map { [$0] } ?? []) + view.subviews.flatMap { labels(in: $0) }
}

@MainActor
private func views<T: NSView>(_ type: T.Type, in view: NSView?) -> [T] {
    guard let view else { return [] }
    return ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { views(type, in: $0) }
}

@MainActor
private func checkWhatsNew() async throws {
    section("what's new")
    let spec = ActionTable.spec(.whatsNew)
    check(spec.title == "What's New\u{2026}" && spec.hotKey == nil && spec.urlPath == "whats-new" && spec.menuGroup == 2, "What's New is a menu action in the windows group with no hotkey")
    check(AppAction.make(.whatsNew, timerSeconds: 5) == .whatsNew && AppAction.whatsNew.id == .whatsNew, "the action maps to its own id")
    check((try? URLCommand.parse(URL(string: "cornermark://whats-new")!).get()) == .whatsNew, "cornermark://whats-new parses")

    let history = [entry(AppVersion(0, 3, 0), body: "### Features\n* Not yet"),
                   entry(AppVersion(0, 2, 1), body: realBody),
                   entry(AppVersion(0, 2, 0), body: "### Features\n* Added a thing\n* Another thing\n\n### Bug Fixes\n* Fixed one"),
                   entry(AppVersion(0, 1, 0), body: "")]
    check(WhatsNewContent(history: history, running: AppVersion(0, 2, 1)) == .loaded(Array(history.dropFirst())), "versions above the running one are hidden, the rest stay in order")
    check(WhatsNewContent(history: history, running: nil) == .loaded(history), "with no known running version everything is shown")
    check(WhatsNewContent(history: [], running: AppVersion(0, 2, 1)) == .failed, "an empty history is a failure")
    check(WhatsNewContent(history: history, running: AppVersion(0, 0, 9)) == .failed, "a history with nothing at or below the running version is a failure")

    do {
        let w = try World(after: [])
        defer { w.cleanup() }
        let c = w.coordinator
        w.updateService.history = .success(history)
        w.updateService.historyDelay = 0.15
        check(c.whatsNewWindow == nil && w.updateService.historyCalls == 0, "nothing is created or fetched until it is asked for")
        c.perform(.whatsNew)
        let controller = c.whatsNewWindow
        check(controller?.content == .loading && w.presented.contains { $0 === controller?.window }, "opening presents the window straight away, loading")
        check(collectText(controller?.window?.contentView) == ["Loading release notes\u{2026}"], "and says so", detail: "\(collectText(controller?.window?.contentView))")
        check(await waitUntil { controller?.content != .loading }, "the history arrives")
        check(controller?.content == .loaded(Array(history.dropFirst())), "versions above the running 0.2.1 are not shown", detail: "\(String(describing: controller?.content))")

        let view = controller?.window?.contentView
        view?.layoutSubtreeIfNeeded()
        let texts = collectText(view)
        check(texts.filter { $0.hasPrefix("Version ") } == ["Version 0.2.1", "Version 0.2.0", "Version 0.1.0"], "versions are listed newest first", detail: "\(texts)")
        check(!texts.contains("Version 0.3.0"), "a newer release is absent")
        let dateText = Date(timeIntervalSince1970: 1_793_700_000).formatted(Date.FormatStyle(date: .long, time: .omitted).locale(L10n.locale))
        check(texts.filter { $0 == dateText }.count == 3, "each version has its date in the user's format", detail: "\(texts)")
        check(texts.contains("Fixed") && texts.contains("New") && texts.contains("Show refused keys and held modifiers in ShortcutRecorderView")
              && texts.contains("Added a thing") && texts.contains("Another thing") && texts.contains("Fixed one"), "section titles and items are shown", detail: "\(texts)")
        check(!texts.contains { $0.contains("**") || $0.contains("http") }, "no markup or URL reaches the screen")
        check(texts.filter { $0 == WhatsNewWindowController.emptyVersionNote }.count == 1, "a version with no items says Small fixes and improvements.")
        let fields = labels(in: view)
        check(fields.first { $0.stringValue == "Version 0.2.1" }?.font == DS.Text.heading.font, "version headings use the heading style")
        check(fields.first { $0.stringValue == dateText }?.font == DS.Text.caption.font && fields.first { $0.stringValue == dateText }?.textColor == DS.Color.textSecondary, "the date is a secondary caption")
        check(fields.filter { ["New", "Fixed"].contains($0.stringValue) }.allSatisfy { $0.font == DS.Text.captionStrong.font }, "section titles use captionStrong")
        check(fields.first { $0.stringValue == "Another thing" }?.font == DS.Text.body.font, "items use the body style")
        let badges = views(Badge.self, in: view)
        check(badges.count == 1 && badges[0].text == "Installed", "only the installed version carries a badge", detail: "\(badges.map(\.text))")
        if let badge = badges.first, let heading = fields.first(where: { $0.stringValue == "Version 0.2.1" }) {
            let b = badge.convert(badge.bounds, to: view), h = heading.convert(heading.bounds, to: view)
            check(abs(b.midY - h.midY) <= 2 && b.minX > h.maxX, "the badge sits beside the 0.2.1 heading", detail: "\(b) \(h)")
        }
        if let badge = badges.first, let scroll = findView("whatsnew.scroll", in: view) {
            let top = badge.convert(badge.bounds, to: scroll)
            let fromTop = scroll.isFlipped ? top.minY : scroll.bounds.height - top.maxY
            check(abs(fromTop - DS.Space.s24) <= 1, "the first version starts s24 below the top edge, not at the bottom of the window", detail: "\(fromTop)")
        }
        snapshotWindow(controller!.window!, name: "whatsnew-light")
        snapshotWindow(controller!.window!, name: "whatsnew-dark", dark: true)
        check(findView("whatsnew.openReleases", in: view) == nil, "the loaded state has no button")
        check(views(Button.self, in: view).isEmpty, "and the window holds no accent button")

        let window = controller?.window
        c.perform(.whatsNew)
        check(c.whatsNewWindow === controller && controller?.window === window, "opening again reuses the window")
        check(controller?.content == .loading, "and shows loading until the new answer arrives")
        check(await waitUntil { controller?.content != .loading } && w.updateService.historyCalls == 2, "which comes from a second fetch")
    }
    do {
        let w = try World(after: [])
        defer { w.cleanup() }
        let c = w.coordinator
        w.updateService.history = .failure(UpdateError.network("offline"))
        c.showWhatsNew()
        let controller = c.whatsNewWindow!
        check(await waitUntil { controller.content != .loading }, "a failed fetch ends loading")
        check(controller.content == .failed, "and shows the failed state")
        let view = controller.window?.contentView
        view?.layoutSubtreeIfNeeded()
        snapshotWindow(controller.window!, name: "whatsnew-failed")
        check(collectText(view) == [WhatsNewWindowController.failureNote, "Open Releases Page"] && WhatsNewWindowController.failureNote == "Cornermark could not load the release notes.",
              "it is one line and one button", detail: "\(collectText(view))")
        let button = findView("whatsnew.openReleases", in: view) as? Button
        check(button?.variant == .secondary, "the button is neutral, since the window has no primary action")
        check(click("whatsnew.openReleases", in: view) && w.opened == [URL(string: "https://github.com/emretfn/cornermark/releases")!], "the button opens the releases page", detail: "\(w.opened)")

        w.updateService.history = .success([entry(AppVersion(0, 2, 1))])
        c.showWhatsNew()
        check(await waitUntil { controller.content != .loading }, "reopening fetches again")
        check(controller.content != .failed && findView("whatsnew.openReleases", in: controller.window?.contentView) == nil, "and recovers once GitHub answers")
        w.updateService.history = .success([])
        c.showWhatsNew()
        check(await waitUntil { controller.content != .loading } && controller.content == .failed, "an empty answer behaves like a failure")
        check(findView("whatsnew.openReleases", in: controller.window?.contentView) != nil, "with the same button")
    }
    do {
        let w = try World(after: [])
        defer { w.cleanup() }
        let c = w.coordinator
        w.updateService.history = .success((0...12).reversed().map { entry(AppVersion(0, 1, $0), body: "### New\n* \(String(repeating: "A long line that has to wrap. ", count: 6))") })
        w.updateService.currentVersion = AppVersion(0, 1, 12)
        c.showWhatsNew()
        let controller = c.whatsNewWindow!
        check(await waitUntil { controller.content != .loading }, "a long history loads")
        let scroll = findView("whatsnew.scroll", in: controller.window?.contentView) as? NSScrollView
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        check((scroll?.documentView?.frame.height ?? 0) > (scroll?.contentView.bounds.height ?? .infinity), "it scrolls when it does not fit", detail: "\(String(describing: scroll?.documentView?.frame.height)) in \(String(describing: scroll?.contentView.bounds.height))")
        check(scroll?.documentView?.frame.width == scroll?.contentView.bounds.width, "and never scrolls sideways")
        let wrapped = labels(in: scroll?.documentView).first { $0.stringValue.hasPrefix("A long line") }
        check((wrapped?.frame.height ?? 0) > DS.Text.body.lineHeight * 2, "long items wrap onto more lines", detail: "\(String(describing: wrapped?.frame))")
    }
    do {
        let w = try World(after: [])
        defer { w.cleanup() }
        let c = w.coordinator
        w.updateService.history = .success([entry(AppVersion(0, 2, 1)), entry(AppVersion(0, 2, 0))])
        let row = panelModel(w).row(.whatsNew)
        check(row?.title == "What's New\u{2026}" && row?.isEnabled == true, "the panel row is enabled")
        let (_, view) = panelView(w)
        check(pressMenu(.action(.whatsNew), in: view), "the panel has it")
        check(await waitUntil { c.whatsNewWindow != nil } && w.presented.contains { $0 === c.whatsNewWindow?.window }, "choosing the panel row opens the window")
        check(await waitUntil { w.updateService.historyCalls == 1 }, "and fetches")
        check(c.handle(url: URL(string: "cornermark://whats-new")!), "the URL scheme accepts it")
        check(await waitUntil { w.updateService.historyCalls == 2 }, "and fetches again")
        check(c.whatsNewWindow?.window?.isVisible == false, "offscreen, nothing was ordered in")
    }
    do {
        let w = try World(after: [])
        defer { w.cleanup() }
        w.updateService.history = .success([entry(AppVersion(0, 2, 1))])
        w.settings.update { $0.lastRunVersion = "0.2.0" }
        w.coordinator.startMaintenance()
        try? await Task.sleep(nanoseconds: 100_000_000)
        check(w.coordinator.whatsNewWindow == nil && w.updateService.historyCalls == 0 && !w.presented.contains { $0.title == "What's New" },
              "an update never opens What's New by itself")
    }
}

@MainActor
private func checkUpdatedHUD() async throws {
    section("update confirmation after launch")
    func launch(stored: String?, running: AppVersion?) throws -> (hud: String?, stored: String?) {
        let w = try World(after: [])
        defer { w.cleanup() }
        w.updateService.currentVersion = running
        w.settings.update { $0.lastRunVersion = stored }
        w.coordinator.startMaintenance()
        return (w.coordinator.hud.lastMessage, w.settings.value.lastRunVersion)
    }
    let updated = try launch(stored: "0.2.1", running: AppVersion(0, 3, 0))
    check(updated.hud == "Updated to Cornermark 0.3.0" && updated.stored == "0.3.0", "0.2.1 to 0.3.0 shows the HUD and remembers 0.3.0", detail: "\(updated)")
    let first = try launch(stored: nil, running: AppVersion(0, 2, 1))
    check(first.hud == nil && first.stored == "0.2.1", "a first run shows nothing and remembers the version", detail: "\(first)")
    let same = try launch(stored: "0.2.1", running: AppVersion(0, 2, 1))
    check(same.hud == nil && same.stored == "0.2.1", "the same version shows nothing", detail: "\(same)")
    let older = try launch(stored: "0.3.0", running: AppVersion(0, 2, 1))
    check(older.hud == nil && older.stored == "0.2.1", "an older version shows nothing and is remembered", detail: "\(older)")
    let junk = try launch(stored: "next", running: AppVersion(0, 2, 1))
    check(junk.hud == nil && junk.stored == "0.2.1", "an unreadable stored version shows nothing and is replaced", detail: "\(junk)")
    let unknown = try launch(stored: "0.2.1", running: nil)
    check(unknown.hud == nil && unknown.stored == "0.2.1", "an app with no known version changes nothing", detail: "\(unknown)")

    let w = try World(after: [])
    defer { w.cleanup() }
    w.settings.update { $0.lastRunVersion = "0.2.0" }
    w.coordinator.startMaintenance()
    w.coordinator.hud.show("later message")
    w.coordinator.announceUpdateIfNeeded()
    check(w.coordinator.hud.lastMessage == "later message", "once remembered, the next launch does not repeat it")
}
