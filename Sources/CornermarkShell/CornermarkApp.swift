import AppKit
import CornermarkCapture

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var coordinator: AppCoordinator?
    private var statusItem: NSStatusItem?
    private var menuBuilder: StatusMenuBuilder?
    private var pendingURLs: [URL] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        let env: AppEnvironment
        do { env = try AppEnvironment.live() } catch {
            Log.shell.fault("cannot open capture history: \(error.localizedDescription, privacy: .public)")
            let alert = NSAlert()
            alert.messageText = "Cornermark cannot open its capture history"
            alert.informativeText = error.localizedDescription
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        let coordinator = AppCoordinator(env: env)
        self.coordinator = coordinator
        coordinator.installHotKeys(backend: CarbonHotKeyBackend())
        coordinator.startMaintenance()
        installStatusItem(coordinator)
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
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "viewfinder", accessibilityDescription: "Cornermark")
            // An image-only variable-length item is 10pt wider than the square one, so the length follows the label.
            let apply: (UpdateState) -> Void = { [weak item] state in
                guard let item, let button = item.button else { return }
                applyStatusLabel(state, to: button)
                item.length = state.statusLabel == nil ? NSStatusItem.squareLength : NSStatusItem.variableLength
            }
            apply(coordinator.updates.state)
            coordinator.updates.onStateChange = apply
        }
        let builder = StatusMenuBuilder(coordinator: coordinator)
        item.menu = builder.build()
        statusItem = item
        menuBuilder = builder
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

/// Shows the update label next to the icon, or the bare icon when there is none.
@MainActor
func applyStatusLabel(_ state: UpdateState, to button: NSStatusBarButton) {
    let label = state.statusLabel
    button.title = label ?? ""
    button.imagePosition = label == nil ? .imageOnly : .imageLeading
    button.setAccessibilityLabel(label == nil ? "Cornermark" : "Cornermark, update available")
}
