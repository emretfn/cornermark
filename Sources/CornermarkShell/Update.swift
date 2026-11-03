import Foundation

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

    /// The notes cut at a line break so a long changelog still fits in an alert.
    func notesSummary(maxCharacters: Int = 600) -> String {
        let text = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count > maxCharacters else { return text }
        let head = String(text.prefix(maxCharacters))
        let cut = head.lastIndex(of: "\n") ?? head.lastIndex(of: " ") ?? head.endIndex
        return head[..<cut].trimmingCharacters(in: .whitespacesAndNewlines) + "\u{2026}"
    }
}

enum UpdateState: Equatable {
    case idle
    case checking(manual: Bool)
    case available(AppRelease)
    case installing(AppRelease)

    var menuTitle: String {
        switch self {
        case .idle: return "Check for Updates\u{2026}"
        case .checking: return "Checking for Updates\u{2026}"
        case .available(let r): return "Install Cornermark \(r.version)\u{2026}"
        case .installing(let r): return "Installing Cornermark \(r.version)\u{2026}"
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
            return "This copy of Cornermark was not signed by a release, so it cannot check that an update is genuine."
        case .signatureMismatch:
            return "The downloaded app is not signed by the same certificate as this one, so it was not installed."
        case .versionMismatch:
            return "The downloaded app is not the newer version the release announced, so it was not installed."
        case .bundleMissing:
            return "The download does not contain Cornermark.app."
        case .noDownload:
            return "This release has no download yet."
        case .cannotReplace(let path):
            return "Cornermark cannot replace itself at \(path). Move it to the Applications folder, or install the update by hand."
        case .relaunchFailed:
            return "The update is installed, but Cornermark could not reopen itself. Open it again from Applications."
        case .badResponse:
            return "GitHub sent an answer Cornermark could not read."
        case .network(let detail):
            return "Cornermark could not reach GitHub. \(detail)"
        case .process(let detail):
            return "Unpacking the download failed. \(detail)"
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
