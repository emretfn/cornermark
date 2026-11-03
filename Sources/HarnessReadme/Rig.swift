import AppKit
import CornermarkCapture
import CornermarkCore
@testable import CornermarkShell

final class IdleLoginItem: LoginItemControlling {
    var isEnabled = false
    func setEnabled(_ enabled: Bool) throws { isEnabled = enabled }
}

/// Finds no release and touches no network.
final class IdleUpdates: UpdateServicing {
    var currentVersion: AppVersion? { AppVersion(1, 0, 0) }
    func latestRelease() async throws -> AppRelease? { nil }
    func stage(_ release: AppRelease) async throws -> StagedUpdate { throw UpdateError.noDownload }
    func installAndRelaunch(_ staged: StagedUpdate) throws {}
    func discard(_ staged: StagedUpdate) {}
}

/// Registers nothing with the system; every key reads as registered, so the Shortcuts pane shows "Active".
final class IdleHotKeys: HotKeyBackend {
    var onPressed: ((UInt32) -> Void)?
    func register(_ key: HotKey, id: UInt32) -> Int32 { 0 }
    func unregisterAll() {}
}

/// The real coordinator over a private defaults suite, a private pasteboard and a temporary history folder,
/// presenting nothing on screen.
@MainActor
final class Rig {
    static let now = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 3, hour: 14, minute: 5, second: 9))!
    /// Visible frame in AppKit points (bottom-left origin): above the Dock, below the menu bar.
    static let visibleFrame = CGRect(x: 0, y: SampleScene.desktopSize.height - SampleScene.dockTop, width: 1440, height: SampleScene.dockTop - SampleScene.menuBarHeight)

    let root: URL
    let suite: String
    let defaults: UserDefaults
    let pasteboard: NSPasteboard
    let env: AppEnvironment
    let coordinator: AppCoordinator

    var store: CaptureStore { env.store }

    init(desktop: CGImage? = nil) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("CornermarkReadme-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        suite = "local.emretufan.cornermark.readme.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        pasteboard = NSPasteboard(name: NSPasteboard.Name(suite))
        let frame = CGRect(origin: .zero, size: SampleScene.desktopSize)
        let display = DisplaySnapshot(displayID: 1, frame: frame, scale: 2, image: desktop ?? Wallpaper.image(width: 2880, height: 1800))
        let visible = Self.visibleFrame
        let history = try CaptureStore(root: root.appendingPathComponent("history", isDirectory: true))
        env = AppEnvironment(
            screen: FixtureScreenSource(displays: [display]), store: history, defaults: defaults, pasteboard: pasteboard, presentation: .offscreen,
            clock: { Rig.now }, cursorScreenFrame: { visible }, hasScreenPermission: { true }, requestScreenPermission: {},
            openURL: { _ in }, revealInFinder: { _ in }, playSound: {}, pickFolder: { $0(nil) }, loginItem: IdleLoginItem(), updateService: IdleUpdates(),
            defaultSaveFolder: root.appendingPathComponent("desktop", isDirectory: true),
            dragDirectory: root.appendingPathComponent("drag", isDirectory: true), quit: {})
        coordinator = AppCoordinator(env: env)
        coordinator.settings.update {
            $0.afterCapture = [.showOverlay]
            $0.saveFolder = root.appendingPathComponent("saved", isDirectory: true).path
            $0.playSound = false
        }
    }

    func cleanup() {
        coordinator.editors.values.forEach { $0.window?.close() }
        coordinator.pins.closeAll()
        coordinator.capture.cancel()
        coordinator.overlay.closeAll()
        pasteboard.releaseGlobally()
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor
func waitUntil(_ seconds: Double = 5, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return condition()
}

func settle(_ seconds: TimeInterval = 0.1) {
    RunLoop.current.run(until: Date().addingTimeInterval(seconds))
}

struct ShotError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
