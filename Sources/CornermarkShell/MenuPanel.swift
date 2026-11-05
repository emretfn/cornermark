import AppKit
import CornermarkCore

/// Where the status item button is, so the panel can open under it.
struct MenuAnchor {
    /// The button in global screen coordinates.
    let button: CGRect
    /// The visible frame (menu bar and Dock excluded) of the display the button is on.
    let visible: CGRect
    /// The button's own window. Its clicks reach the toggle, so the outside-click monitor leaves them alone.
    weak var window: NSWindow?

    @MainActor
    init?(button view: NSView) {
        guard let window = view.window else { return nil }
        button = window.convertToScreen(view.convert(view.bounds, to: nil))
        visible = (window.screen ?? NSScreen.main)?.visibleFrame ?? .zero
        self.window = window
    }

    init(button: CGRect, visible: CGRect, window: NSWindow? = nil) {
        self.button = button
        self.visible = visible
        self.window = window
    }
}

/// A panel that takes keys without making Cornermark the active app, so the app in front keeps its focus.
final class MenuPanel: NSPanel {
    init(contentSize: CGSize) {
        super.init(contentRect: CGRect(origin: .zero, size: contentSize), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        title = "Cornermark"
        isFloatingPanel = true
        level = .popUpMenu
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        animationBehavior = .none
        // Never part of a screenshot or a screen recording, whichever capture mode is running.
        sharingType = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func keyDown(with event: NSEvent) {
        if (contentView as? MenuPanelView)?.handleKey(event) != true { super.keyDown(with: event) }
    }
}

/// Owns the menu bar panel: builds it from the model, opens and closes it, and runs what the user picks.
@MainActor
final class MenuPanelController {
    private unowned let coordinator: AppCoordinator
    private(set) var panel: MenuPanel?
    /// True from open to close, whether or not a window was ordered in. An offscreen environment never orders one in.
    private(set) var isOpen = false
    private(set) var model: MenuPanelModel?
    private var anchor: MenuAnchor?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var resignObserver: NSObjectProtocol?
    private var resignedAt: TimeInterval?

    /// What a chosen item does. Tests swap it for a recorder.
    lazy var run: (PanelItem) -> Void = { [unowned self] item in coordinator.perform(menu: item) }
    var onOpenChange: (Bool) -> Void = { _ in }

    init(coordinator: AppCoordinator) { self.coordinator = coordinator }

    func currentModel() -> MenuPanelModel {
        let c = coordinator
        return MenuPanelModel.make(
            settings: c.settings.value,
            update: c.updates.state,
            overlaysHidden: c.overlay.isHidden,
            canRestoreOverlay: !c.overlay.recentlyClosed.isEmpty,
            pins: c.pins.summaries,
            isRecording: c.recording.phase != .idle,
            recent: c.env.store.list(filter: CaptureFilter(limit: MenuPanelModel.recentLimit)))
    }

    var host: MenuPanelHost {
        MenuPanelHost(
            activate: { [weak self] in self?.activate($0) },
            close: { [weak self] in self?.close() },
            thumbnail: { [coordinator] record, done in
                coordinator.thumbnails.load(id: record.id, file: coordinator.env.store.paths(for: record).image,
                                            maxPixel: HistoryWindowController.thumbnailPixels, completion: done)
            })
    }

    func toggle(anchor: MenuAnchor) {
        if isOpen { return close() }
        // A click on the button can take key from the panel a moment before it reaches the button; that click closes.
        if let resignedAt, ProcessInfo.processInfo.systemUptime - resignedAt < 0.2 {
            self.resignedAt = nil
            return
        }
        open(anchor: anchor)
    }

    func open(anchor: MenuAnchor) {
        guard !isOpen else { return }
        isOpen = true
        self.anchor = anchor
        let model = currentModel()
        self.model = model
        let view = MenuPanelView(model: model, host: host)
        let size = view.frame.size
        let panel = MenuPanel(contentSize: size)
        panel.contentView = view
        panel.setFrame(MenuPlacement.frame(size: size, button: anchor.button, visible: anchor.visible), display: false)
        self.panel = panel
        coordinator.env.willPresent(panel)
        onOpenChange(true)
        guard coordinator.env.isOnscreen else { return }
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(view)
        installMonitors(anchorWindow: anchor.window)
    }

    /// Closes first and runs the item on the next turn of the main queue, so the panel is gone before anything it starts
    /// can draw or capture.
    func activate(_ item: PanelItem) {
        close()
        let run = run
        DispatchQueue.main.async { run(item) }
    }

    func close() {
        guard isOpen else { return }
        isOpen = false
        removeMonitors()
        panel?.orderOut(nil)
        panel = nil
        model = nil
        anchor = nil
        onOpenChange(false)
    }

    /// Rebuilds the open panel when what it shows changed, such as an update becoming available. Keeps the keyboard focus.
    func refresh() {
        guard isOpen, let anchor, let panel, let old = panel.contentView as? MenuPanelView else { return }
        let model = currentModel()
        guard model != self.model else { return }
        self.model = model
        let view = MenuPanelView(model: model, host: host, focus: old.focus)
        // The window resizes its content view to its own size once it is assigned, so the wanted size is read first.
        let size = view.frame.size
        panel.contentView = view
        panel.setFrame(MenuPlacement.frame(size: size, button: anchor.button, visible: anchor.visible), display: coordinator.env.isOnscreen)
        if coordinator.env.isOnscreen {
            panel.makeFirstResponder(view)
            panel.invalidateShadow()
        }
    }

    private func installMonitors(anchorWindow: NSWindow?) {
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: clicks) { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.close() } }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: clicks) { [weak self] event in
            guard let self, let panel = self.panel else { return event }
            // The panel's own clicks are its business, and a click on the status button is the toggle.
            if event.window !== panel, event.window !== anchorWindow { self.close() }
            return event
        }
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.resignedAt = ProcessInfo.processInfo.systemUptime
                self?.close()
            }
        }
    }

    private func removeMonitors() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        globalMonitor = nil
        localMonitor = nil
        resignObserver = nil
    }
}

extension AppCoordinator {
    /// What choosing a panel item does. Everything in the action table goes through `perform(id:)`.
    func perform(menu item: PanelItem) {
        switch item {
        case .action(let id): perform(id: id)
        case .recent(let id): if let record = env.store.record(id: id) { openEditor(record) }
        case .togglePinLock(let id): pins.toggleLock(id)
        case .closePin(let id): pins.close(id)
        case .unlockAllPins: pins.unlockAll()
        case .closeAllPins: pins.closeAll()
        }
    }
}
