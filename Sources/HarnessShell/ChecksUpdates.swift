import Foundation
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
