import AppKit
import KadrajCapture
import KadrajCore
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
        let store = try CaptureStore(root: support.appendingPathComponent("Kadraj/History", isDirectory: true))
        let drag = fm.temporaryDirectory.appendingPathComponent("KadrajDrag", isDirectory: true)
        try? fm.createDirectory(at: drag, withIntermediateDirectories: true)
        return AppEnvironment(
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
            loginItem: MainAppLoginItem(),
            defaultSaveFolder: fm.urls(for: .desktopDirectory, in: .userDomainMask).first ?? fm.homeDirectoryForCurrentUser,
            dragDirectory: drag,
            quit: { NSApp.terminate(nil) })
    }
}
