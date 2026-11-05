import AppKit
import CornermarkCapture
import CornermarkCore
import ServiceManagement

final class MainAppLoginItem: LoginItemControlling {
    var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    func setEnabled(_ enabled: Bool) throws {
        if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
}

extension AppEnvironment {
    static let screenCapturePaneURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
    static let inputMonitoringPaneURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!

    static func live() throws -> AppEnvironment {
        #if DEBUG
        if let root = isolatedRoot {
            let defaults = UserDefaults(suiteName: isolatedName)!
            defaults.removePersistentDomain(forName: isolatedName)
            // No link changes settings, so a verification run that needs some, such as shown clicks, starts from this file.
            if let seeded = try? Data(contentsOf: root.appendingPathComponent("settings.json")) { defaults.set(seeded, forKey: SettingsStore.key) }
            return try isolated(root: root, defaults: defaults)
        }
        #endif
        let fm = FileManager.default
        let support = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let store = try CaptureStore(root: support.appendingPathComponent("\(AppVariant.current.name)/History", isDirectory: true))
        let drag = fm.temporaryDirectory.appendingPathComponent(AppVariant.current.dragFolder, isDirectory: true)
        try? fm.createDirectory(at: drag, withIntermediateDirectories: true)
        let env = AppEnvironment(
            screen: ScreenCaptureKitSource(), store: store, defaults: .standard, pasteboard: .general,
            presentation: .onscreen, clock: { Date() },
            cursorScreenFrame: {
                let p = NSEvent.mouseLocation
                return (NSScreen.screens.first { NSMouseInRect(p, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]).visibleFrame
            },
            hasScreenPermission: { CaptureController.hasPermission },
            requestScreenPermission: { CaptureController.requestPermission() },
            openURL: { NSWorkspace.shared.open($0) },
            revealInFinder: { NSWorkspace.shared.activateFileViewerSelecting([$0]) },
            playSound: { if let grab = NSSound(named: "Grab") { grab.play() } else { NSSound.beep() } },
            pickFolder: { done in
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                panel.canCreateDirectories = true
                panel.prompt = "Choose"
                NSApp.activate(ignoringOtherApps: true)
                done(panel.runModal() == .OK ? panel.url : nil)
            },
            loginItem: MainAppLoginItem(), updateService: AppVariant.current == .development ? NoUpdates() : UpdateInstaller(),
            defaultSaveFolder: fm.urls(for: .desktopDirectory, in: .userDomainMask).first ?? fm.homeDirectoryForCurrentUser,
            dragDirectory: drag,
            quit: { NSApp.terminate(nil) })
        env.confirmUpdate = confirmUpdate
        env.presentUpdateAlert = presentUpdateAlert
        env.frameSource = { target, options in StreamFrameSource(target: target, options: options) }
        env.pointerSource = { LivePointerSource() }
        env.inputSource = { LiveInputSource(capture: $0) }
        env.hasInputPermission = { LiveInputSource.isPermitted }
        env.cameraSource = { LiveCameraSource() }
        env.cameraAccess = { CameraAccess.current }
        env.requestCameraAccess = { CameraAccess.request($0) }
        env.recordingJournal = RecordingJournal(folder: support.appendingPathComponent("\(AppVariant.current.name)/Unfinished Recordings", isDirectory: true))
        return env
    }

    #if DEBUG
    /// One fixed name, because each new suite leaves a file in ~/Library/Preferences for good.
    private static let isolatedName = "local.emretufan.cornermark.dev.isolated"

    /// Set by the verification skill, so a scripted instance shares nothing with one the developer has open.
    static var isolatedRoot: URL? {
        ProcessInfo.processInfo.environment["CORNERMARK_ISOLATED_ROOT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// `.offscreen` keeps every window out and the app inactive, so a scripted link cannot take the developer's focus.
    /// No displays, so a capture link fails instead of imaging the developer's screen.
    static func isolated(root: URL, defaults: UserDefaults) throws -> AppEnvironment {
        let fm = FileManager.default
        let drag = root.appendingPathComponent("drag", isDirectory: true)
        let saved = root.appendingPathComponent("saved", isDirectory: true)
        try fm.createDirectory(at: drag, withIntermediateDirectories: true)
        try fm.createDirectory(at: saved, withIntermediateDirectories: true)
        let env = AppEnvironment(
            screen: FixtureScreenSource(displays: []), store: try CaptureStore(root: root.appendingPathComponent("History", isDirectory: true)),
            defaults: defaults, pasteboard: NSPasteboard(name: NSPasteboard.Name(isolatedName)),
            presentation: .offscreen, clock: { Date() }, cursorScreenFrame: { NSScreen.main?.visibleFrame ?? .zero },
            hasScreenPermission: { CaptureController.hasPermission }, requestScreenPermission: {},
            openURL: { _ in }, revealInFinder: { _ in }, playSound: {}, pickFolder: { $0(nil) },
            loginItem: IsolatedLoginItem(), updateService: NoUpdates(), defaultSaveFolder: saved, dragDirectory: drag,
            quit: { NSApp.terminate(nil) })
        let testWindow = RecordingTestWindow()
        env.recordingTestWindow = testWindow
        env.frameSource = { target, options in try isolatedFrameSource(target, options, testWindow: testWindow) }
        env.pointerSource = { ScriptedPointerSource() }
        env.inputSource = { ScriptedInputSource(capture: $0) }
        env.hasInputPermission = { true }
        env.cameraSource = { ScriptedCameraSource() }
        env.cameraAccess = { .allowed }
        env.requestCameraAccess = { done in
            Log.shell.error("camera access request refused: a scripted instance never asks")
            done(false)
        }
        env.recordingJournal = RecordingJournal(folder: root.appendingPathComponent("unfinished", isDirectory: true))
        env.willPresent = { window in
            Log.shell.notice("present window=\(window.title, privacy: .public) visible=\(window.isVisible, privacy: .public) appActive=\(NSApp.isActive, privacy: .public)")
        }
        return env
    }

    /// The only screen pixels a scripted instance may film are those of its own test window. A display is a synthetic one,
    /// so no content filter on a real display is ever built here.
    static func isolatedFrameSource(_ target: RecordingTarget, _ options: RecordingOptions, testWindow: RecordingTestWindowHosting) throws -> FrameSource {
        switch target {
        case .window(let id):
            guard let own = testWindow.windowID else { throw RecordingRefusal.noTestWindow }
            guard id == own else { throw RecordingRefusal.notTestWindow(id) }
            return StreamFrameSource(target: target, options: options)
        case .display(let id, let area):
            if let id, id != FixtureFrameSource.displayID { throw RecordingRefusal.unknownDisplay(id) }
            // The scripted pointer is the one a project's track records, so a video shows the same path in its picture.
            return FixtureFrameSource(area: area, options: options, cursor: .tour,
                                      windows: SyntheticScene.otherWindows(on: FixtureFrameSource.displayFrame.size), pacing: .realtime)
        }
    }

    private final class IsolatedLoginItem: LoginItemControlling {
        var isEnabled: Bool { false }
        func setEnabled(_ enabled: Bool) throws {}
    }
    #endif

    private static func confirmUpdate(_ release: AppRelease) -> Bool {
        #if DEBUG
        if ProcessInfo.processInfo.environment["CORNERMARK_UPDATE_ASSUME_YES"] == "1" { return true }
        #endif
        let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "an unknown version"
        let alert = NSAlert()
        alert.messageText = "Cornermark \(release.version) is available"
        let notes = release.notesSummary()
        alert.informativeText = "You have \(current)." + (notes.isEmpty ? "" : "\n\n\(notes)")
        alert.addButton(withTitle: "Install and Relaunch")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    private static func presentUpdateAlert(_ update: UpdateAlert) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = update.title
        alert.informativeText = update.message
        alert.addButton(withTitle: update.offersReleasePage ? "Open Release Page" : "OK")
        if update.offersReleasePage { alert.addButton(withTitle: "Cancel") }
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn && update.offersReleasePage
    }
}
