import Carbon.HIToolbox
import Foundation

/// The build's identity, read from its bundle. A development build keeps its own name, permission, data, link scheme and
/// default shortcuts, so it can run beside an installed release. Anything without a bundle, such as a harness, is production.
enum AppVariant {
    case production, development

    static let current = AppVariant(bundleIdentifier: Bundle.main.bundleIdentifier)

    init(bundleIdentifier: String?) {
        self = bundleIdentifier?.hasSuffix(".dev") == true ? .development : .production
    }

    var name: String { self == .development ? "Cornermark Dev" : "Cornermark" }
    var urlScheme: String { self == .development ? "cornermark-dev" : "cornermark" }
    var dragFolder: String { self == .development ? "CornermarkDevDrag" : "CornermarkDrag" }
    /// Shown next to the menu bar icon, the only part of the app that is always on screen.
    var statusBadge: String? { self == .development ? "DEV" : nil }
    /// Added to the default capture shortcuts so that they do not collide with a running release.
    var extraShortcutModifiers: UInt32 { self == .development ? UInt32(optionKey) : 0 }
}

/// Stands in for the updater in a development build, which must never replace itself with a release.
final class NoUpdates: UpdateServicing {
    let currentVersion = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String).flatMap(AppVersion.init)

    func latestRelease() async throws -> AppRelease? { nil }
    func releaseHistory() async throws -> [ReleaseEntry] { [] }
    func stage(_ release: AppRelease) async throws -> StagedUpdate { throw UpdateError.selfNotReleaseSigned }
    func installAndRelaunch(_ staged: StagedUpdate) throws { throw UpdateError.selfNotReleaseSigned }
    func discard(_ staged: StagedUpdate) {}
}
