import Foundation

/// Runs the update flow: check, ask, download, install. The menu reads `state`.
@MainActor
final class UpdateController {
    private let env: AppEnvironment
    private let hud: HUD
    /// Closes every editor so its edits reach the history folder before the app is replaced.
    var closeEditors: () -> Void = {}
    private(set) var state: UpdateState = .idle {
        didSet { if state != oldValue { onStateChange(state) } }
    }
    var onStateChange: (UpdateState) -> Void = { _ in }

    init(env: AppEnvironment, hud: HUD) {
        self.env = env
        self.hud = hud
    }

    /// The background check. Only starts from idle and never bothers the user with a failure.
    func checkAutomatically() async {
        guard state == .idle else { return }
        state = .checking(manual: false)
        do {
            if let release = try await newerRelease() {
                state = .available(release)
                hud.show("Cornermark \(release.version) is available. Install it from the menu.", symbol: "arrow.down.circle.fill")
            } else {
                state = .idle
            }
        } catch {
            state = .idle
            Log.shell.error("automatic update check failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// The menu and URL entry. Idle checks, an available update asks for confirmation, anything else is busy.
    func perform() async {
        switch state {
        case .idle: await checkManually()
        case .available(let release): await confirmAndInstall(release)
        case .checking, .installing: break
        }
    }

    private func checkManually() async {
        state = .checking(manual: true)
        let release: AppRelease?
        do {
            release = try await newerRelease()
        } catch {
            state = .idle
            Log.shell.error("update check failed: \(String(describing: error), privacy: .public)")
            _ = env.presentUpdateAlert(UpdateAlert(title: "Cornermark could not check for updates", message: Self.message(for: error), offersReleasePage: false))
            return
        }
        guard let release else {
            state = .idle
            return hud.show("Cornermark is up to date")
        }
        state = .available(release)
        await confirmAndInstall(release)
    }

    private func confirmAndInstall(_ release: AppRelease) async {
        guard env.confirmUpdate(release) else { return }
        state = .installing(release)
        hud.show("Downloading Cornermark \(release.version)", symbol: "arrow.down.circle.fill")
        var staged: StagedUpdate?
        do {
            let ready = try await env.updateService.stage(release)
            staged = ready
            closeEditors()
            try env.updateService.installAndRelaunch(ready)
            env.quit()
        } catch {
            if let staged { env.updateService.discard(staged) }
            state = .available(release)
            Log.shell.error("update failed: \(String(describing: error), privacy: .public)")
            let alert = UpdateAlert(title: "Cornermark could not install the update", message: Self.message(for: error), offersReleasePage: true)
            if env.presentUpdateAlert(alert) { env.openURL(release.pageURL) }
        }
    }

    /// A release counts only when it is newer than this app and its DMG is already uploaded.
    private func newerRelease() async throws -> AppRelease? {
        guard let current = env.updateService.currentVersion else { return nil }
        guard let release = try await env.updateService.latestRelease() else { return nil }
        return release.version > current && release.dmgURL != nil ? release : nil
    }

    private static func message(for error: Error) -> String {
        (error as? UpdateError)?.message ?? error.localizedDescription
    }
}
