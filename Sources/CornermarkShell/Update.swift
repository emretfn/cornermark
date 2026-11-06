import Foundation
import CornermarkL10n

/// A release number such as `0.2.1`. Anything other than three numeric parts is not a version.
struct AppVersion: Comparable, Equatable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int

    init(_ major: Int, _ minor: Int, _ patch: Int) {
        self.major = major; self.minor = minor; self.patch = patch
    }

    /// Accepts `0.2.1` and `v0.2.1`.
    init?(_ string: String) {
        let body = string.hasPrefix("v") ? String(string.dropFirst()) : string
        let parts = body.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        let numbers = parts.compactMap { part in
            part.isEmpty || !part.allSatisfy({ $0.isASCII && $0.isNumber }) ? nil : Int(part)
        }
        guard numbers.count == 3 else { return nil }
        self.init(numbers[0], numbers[1], numbers[2])
    }

    static func < (a: AppVersion, b: AppVersion) -> Bool {
        (a.major, a.minor, a.patch) < (b.major, b.minor, b.patch)
    }

    var description: String { "\(major).\(minor).\(patch)" }
}

/// What the GitHub releases feed says about one release, already checked.
struct AppRelease: Equatable {
    static let assetName = "Cornermark.dmg"

    let version: AppVersion
    let notes: String
    let pageURL: URL
    /// Nil while the release exists but its DMG has not been uploaded yet.
    let dmgURL: URL?

    /// The only URLs the updater follows or opens. Debug builds also allow a local server for end-to-end runs.
    static func isTrusted(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), let host = url.host, !host.isEmpty else { return false }
        if scheme == "https" { return true }
        #if DEBUG
        return scheme == "http" && host == "127.0.0.1"
        #else
        return false
        #endif
    }

    private struct Payload: Decodable {
        struct Asset: Decodable {
            let name: String?
            let browser_download_url: String?
        }
        let tag_name: String?
        let body: String?
        let html_url: String?
        let assets: [Asset]?
    }

    static func parse(json: Data) throws -> AppRelease {
        guard let payload = try? JSONDecoder().decode(Payload.self, from: json),
              let tag = payload.tag_name, let version = AppVersion(tag),
              let page = payload.html_url.flatMap(URL.init(string:)), isTrusted(page) else {
            throw UpdateError.badResponse
        }
        let dmg = (payload.assets ?? [])
            .first { $0.name == assetName }?
            .browser_download_url.flatMap(URL.init(string:))
            .flatMap { isTrusted($0) ? $0 : nil }
        return AppRelease(version: version, notes: payload.body ?? "", pageURL: page, dmgURL: dmg)
    }

    /// The notes as readable text, cut at a line break so a long changelog still fits in an alert.
    func notesSummary(maxCharacters: Int = 600) -> String {
        let text = ReleaseNotes(markdown: notes).plainText
        guard text.count > maxCharacters else { return text }
        let head = String(text.prefix(maxCharacters))
        let cut = head.lastIndex(of: "\n") ?? head.lastIndex(of: " ") ?? head.endIndex
        return head[..<cut].trimmingCharacters(in: .whitespacesAndNewlines) + "\u{2026}"
    }
}

/// The notes of one release as people read them: the markdown of a GitHub release body with its links, scopes and markup removed.
struct ReleaseNotes: Equatable {
    struct Section: Equatable {
        /// Empty for bullets that come before any heading.
        let title: String
        let items: [String]

        /// The title as a reader sees it. The two names this app gives the changelog's groups follow the language; any other
        /// heading is the release's own text.
        var displayTitle: String {
            switch title {
            case "New": return tr("New")
            case "Fixed": return tr("Fixed")
            default: return title
            }
        }
    }

    let sections: [Section]

    /// Release-please titles for the section names that predate the changelog-sections setting.
    private static let titles = ["Features": "New", "Bug Fixes": "Fixed"]

    init(markdown: String) {
        var sections: [(title: String, items: [String])] = []
        var paragraphs: [String] = []
        var paragraph: [String] = []
        var sawBullet = false
        var current: Int?

        func endParagraph() {
            if !paragraph.isEmpty { paragraphs.append(paragraph.joined(separator: " ")) }
            paragraph = []
        }
        func section(titled title: String) -> Int {
            if let found = sections.firstIndex(where: { $0.title == title }) { return found }
            sections.append((title, []))
            return sections.count - 1
        }

        for raw in markdown.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { endParagraph(); continue }
            if let heading = Self.heading(line) {
                endParagraph()
                if Self.isVersionHeading(heading) { continue }
                let title = Self.plain(heading)
                current = section(titled: Self.titles[title] ?? title)
            } else if line.hasPrefix("* ") || line.hasPrefix("- ") {
                endParagraph()
                sawBullet = true
                let item = Self.item(String(line.dropFirst(2)))
                let index = current ?? section(titled: "")
                current = index
                if !item.isEmpty { sections[index].items.append(item) }
            } else {
                paragraph.append(line)
            }
        }
        endParagraph()

        if !sawBullet { sections = [("", paragraphs.map(Self.item).filter { !$0.isEmpty })] }
        self.sections = sections.filter { !$0.items.isEmpty }.map { Section(title: $0.title, items: $0.items) }
    }

    /// Each section title on its own line, then one `\u{2022}` line per item.
    var plainText: String {
        sections.map { section in
            (section.title.isEmpty ? [] : [section.displayTitle]) + section.items.map { "\u{2022} \($0)" }
        }
        .map { $0.joined(separator: "\n") }
        .joined(separator: "\n\n")
    }

    private static func heading(_ line: String) -> String? {
        let marks = line.prefix { $0 == "#" }.count
        guard (1...6).contains(marks), line.dropFirst(marks).first == " " else { return nil }
        return line.dropFirst(marks).trimmingCharacters(in: CharacterSet(charactersIn: "# "))
    }

    /// `[0.2.1](compare-url) (2026-11-03)`, the line release-please puts above every release.
    private static func isVersionHeading(_ heading: String) -> Bool {
        heading.range(of: #"^\[?v?\d+\.\d+"#, options: .regularExpression) != nil
    }

    private static func plain(_ text: String) -> String {
        text.replacingOccurrences(of: #"\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: "**", with: "")
            .trimmingCharacters(in: .whitespaces)
    }

    /// Drops the `**scope:** ` lead and the trailing issue and commit links, which mean nothing to a reader.
    private static func item(_ markdown: String) -> String {
        let text = plain(markdown
            .replacingOccurrences(of: #"^\*\*[^*]+:\*\*\s*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(\s*\(\[(#[0-9]+|[0-9a-f]{7,40})\]\([^)]*\)\))+\s*$"#, with: "", options: .regularExpression))
        return text.prefix(1).uppercased() + text.dropFirst()
    }
}

/// One published release in the history list.
struct ReleaseEntry: Equatable {
    let version: AppVersion
    let publishedAt: Date?
    let notes: ReleaseNotes

    private struct Payload: Decodable {
        let tag_name: String?
        let body: String?
        let published_at: String?
        let draft: Bool?
        let prerelease: Bool?
    }

    /// The GitHub list endpoint, newest version first. Drafts, pre-releases and tags that are not versions are skipped.
    static func parseList(json: Data) throws -> [ReleaseEntry] {
        guard let payloads = try? JSONDecoder().decode([Payload].self, from: json) else { throw UpdateError.badResponse }
        let dates = ISO8601DateFormatter()
        return payloads.compactMap { payload in
            guard payload.draft != true, payload.prerelease != true, let version = payload.tag_name.flatMap(AppVersion.init) else { return nil }
            return ReleaseEntry(version: version, publishedAt: payload.published_at.flatMap(dates.date(from:)), notes: ReleaseNotes(markdown: payload.body ?? ""))
        }
        .sorted { $0.version > $1.version }
    }
}

enum UpdateState: Equatable {
    case idle
    case checking(manual: Bool)
    case available(AppRelease)
    case installing(AppRelease)

    var menuTitle: String {
        switch self {
        case .idle: return tr("Check for Updates\u{2026}")
        case .checking: return tr("Checking for Updates\u{2026}")
        case .available(let r): return tr("Install Cornermark {version}\u{2026}", ["version": "\(r.version)"])
        case .installing(let r): return tr("Installing Cornermark {version}\u{2026}", ["version": "\(r.version)"])
        }
    }

    /// The short text beside the menu bar icon, nil when there is nothing to point out.
    var statusLabel: String? {
        switch self {
        case .available: return tr("Update")
        case .installing: return tr("Updating\u{2026}")
        case .idle, .checking: return nil
        }
    }

    var menuEnabled: Bool {
        switch self {
        case .idle, .available: return true
        case .checking, .installing: return false
        }
    }
}

/// An update that was downloaded, unpacked and verified, waiting to replace the running app.
struct StagedUpdate: Equatable {
    let release: AppRelease
    let directory: URL
    let app: URL
}

enum UpdateError: Error, Equatable {
    case selfNotReleaseSigned
    case signatureMismatch
    case versionMismatch
    case bundleMissing
    case noDownload
    case cannotReplace(path: String)
    case relaunchFailed
    case badResponse
    case network(String)
    case process(String)

    var message: String {
        switch self {
        case .selfNotReleaseSigned:
            return tr("This copy of Cornermark was not signed by a release, so it cannot check that an update is genuine.")
        case .signatureMismatch:
            return tr("The downloaded app is not signed by the same certificate as this one, so it was not installed.")
        case .versionMismatch:
            return tr("The downloaded app is not the newer version the release announced, so it was not installed.")
        case .bundleMissing:
            return tr("The download does not contain Cornermark.app.")
        case .noDownload:
            return tr("This release has no download yet.")
        case .cannotReplace(let path):
            return tr("Cornermark cannot replace itself at {path}. Move it to the Applications folder, or install the update by hand.", ["path": path])
        case .relaunchFailed:
            return tr("The update is installed, but Cornermark could not reopen itself. Open it again from Applications.")
        case .badResponse:
            return tr("GitHub sent an answer Cornermark could not read.")
        case .network(let detail):
            return tr("Cornermark could not reach GitHub. {detail}", ["detail": detail])
        case .process(let detail):
            return tr("Unpacking the download failed. {detail}", ["detail": detail])
        }
    }
}

/// What the app tells the user when an update step fails.
struct UpdateAlert: Equatable {
    let title: String
    let message: String
    /// Whether the alert has a button that opens the release page.
    let offersReleasePage: Bool
}
