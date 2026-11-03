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

    static func live() throws -> AppEnvironment {
        let fm = FileManager.default
        let support = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let store = try CaptureStore(root: support.appendingPathComponent("Cornermark/History", isDirectory: true))
        let drag = fm.temporaryDirectory.appendingPathComponent("CornermarkDrag", isDirectory: true)
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
            loginItem: MainAppLoginItem(), updateService: UpdateInstaller(),
            defaultSaveFolder: fm.urls(for: .desktopDirectory, in: .userDomainMask).first ?? fm.homeDirectoryForCurrentUser,
            dragDirectory: drag,
            quit: { NSApp.terminate(nil) })
        env.confirmUpdate = confirmUpdate
        env.presentUpdateAlert = presentUpdateAlert
        return env
    }

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
