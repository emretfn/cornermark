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
