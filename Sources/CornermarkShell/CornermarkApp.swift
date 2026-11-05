import AppKit
import CornermarkCapture

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var coordinator: AppCoordinator?
    private var statusItem: NSStatusItem?
    private var menuPanel: MenuPanelController?
    private var pendingURLs: [URL] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        let env: AppEnvironment
        do { env = try AppEnvironment.live() } catch {
            Log.shell.fault("cannot open capture history: \(error.localizedDescription, privacy: .public)")
            #if DEBUG
            if AppEnvironment.isolatedRoot != nil { return NSApp.terminate(nil) }
            #endif
            let alert = NSAlert()
            alert.messageText = "Cornermark cannot open its capture history"
            alert.informativeText = error.localizedDescription
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        let coordinator = AppCoordinator(env: env)
        self.coordinator = coordinator
        #if DEBUG
        Log.shell.notice("launch pid=\(ProcessInfo.processInfo.processIdentifier, privacy: .public) isolated=\(!env.isOnscreen, privacy: .public) screenPermission=\(CaptureController.hasPermission, privacy: .public)")
        #endif
        if env.isOnscreen { coordinator.installHotKeys(backend: CarbonHotKeyBackend()) }
        coordinator.startMaintenance()
        if env.isOnscreen { installStatusItem(coordinator) }
        installMainMenu()
        pendingURLs.forEach(open)
        pendingURLs = []
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard coordinator != nil else { pendingURLs += urls; return }
        urls.forEach(open)
    }

    private func open(_ url: URL) {
        if url.isFileURL { coordinator?.perform(.openFile(url)) } else { coordinator?.handle(url: url) }
    }

    private func installStatusItem(_ coordinator: AppCoordinator) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let panel = MenuPanelController(coordinator: coordinator)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "viewfinder", accessibilityDescription: AppVariant.current.name)
            button.target = self
            button.action = #selector(toggleMenuPanel)
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])
            panel.onOpenChange = { [weak button] open in button?.highlight(open) }
            // An image-only variable-length item is 10pt wider than the square one, so the length follows the label.
            let apply: (UpdateState) -> Void = { [weak item] state in
                guard let item, let button = item.button else { return }
                applyStatusLabel(state, to: button)
                item.length = statusTitle(state) == nil ? NSStatusItem.squareLength : NSStatusItem.variableLength
                panel.refresh()
            }
            apply(coordinator.updates.state)
            coordinator.updates.onStateChange = apply
        }
        statusItem = item
        menuPanel = panel
        #if DEBUG
        if ProcessInfo.processInfo.environment["CORNERMARK_OPEN_MENU"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.toggleMenuPanel()
                if let frame = self?.menuPanel?.panel?.frame { Log.shell.info("menu panel frame \(NSStringFromRect(frame), privacy: .public)") }
            }
        }
        #endif
    }

    @objc private func toggleMenuPanel() {
        guard let button = statusItem?.button, let anchor = MenuAnchor(button: button) else { return }
        menuPanel?.toggle(anchor: anchor)
    }

    /// Accessory apps still need an Edit menu for Cmd+C/V in text fields and Cmd+W in windows.
    private func installMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Cornermark", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        let windowItem = NSMenuItem()
        main.addItem(windowItem)
        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = window
        NSApp.mainMenu = main
        NSApp.windowsMenu = window
    }
}

public enum CornermarkApp {
    @MainActor private static var delegate: AppDelegate?

    /// Runs the menu bar app until it quits. Call from the main thread.
    public static func run() {
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            let d = AppDelegate()
            delegate = d
            app.delegate = d
            app.run()
        }
    }
}

/// The text next to the menu bar icon: the development badge and the update label, when there are any.
func statusTitle(_ state: UpdateState) -> String? {
    let parts = [AppVariant.current.statusBadge, state.statusLabel].compactMap { $0 }
    return parts.isEmpty ? nil : parts.joined(separator: " ")
}

/// Shows the update label next to the icon, or the bare icon when there is none.
@MainActor
func applyStatusLabel(_ state: UpdateState, to button: NSStatusBarButton) {
    let label = statusTitle(state)
    button.title = label ?? ""
    button.imagePosition = label == nil ? .imageOnly : .imageLeading
    button.setAccessibilityLabel(state.statusLabel == nil ? AppVariant.current.name : "\(AppVariant.current.name), update available")
}
