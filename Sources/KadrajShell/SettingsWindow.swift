import AppKit

@MainActor
struct SettingsContext {
    let env: AppEnvironment
    let store: SettingsStore
    let hotKeyStatus: () -> [ActionID: HotKeyStatus]
    let loginError: () -> String?
}

@MainActor
class SettingsPane: NSViewController {
    let ctx: SettingsContext
    var paneTitle: String { "" }
    var symbol: String { "gearshape" }

    init(_ ctx: SettingsContext) {
        self.ctx = ctx
        super.init(nibName: nil, bundle: nil)
        title = paneTitle
    }

    required init?(coder: NSCoder) { fatalError() }

    var settings: Settings { ctx.store.value }
    func buildForm() -> NSView { NSView() }
    func refresh() {}

    override func loadView() {
        view = buildForm()
        preferredContentSize = view.frame.size
        refresh()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        refresh()
    }

    func change(_ mutate: @escaping (inout Settings) -> Void) {
        ctx.store.update(mutate)
        refresh()
    }
}

final class GeneralPane: SettingsPane {
    override var paneTitle: String { "General" }
    override var symbol: String { "gearshape" }
    private let login = Form.checkbox("Launch Kadraj at login", id: "general.launchAtLogin")
    private let loginNote = Form.caption("")
    private let afterBoxes: [(AfterCapture, NSButton)] = [
        (.showOverlay, Form.checkbox("Show Quick Access overlay", id: "general.after.showOverlay")),
        (.copy, Form.checkbox("Copy to clipboard", id: "general.after.copy")),
        (.save, Form.checkbox("Save to folder", id: "general.after.save")),
        (.openEditor, Form.checkbox("Open in editor", id: "general.after.openEditor")),
    ]
    private let folderLabel = NSTextField(labelWithString: "")
    private let format = Form.popup(SaveFormat.allCases.map(\.title), id: "general.format")
    private let sound = Form.checkbox("Play a sound after capture", id: "general.sound")

    override func buildForm() -> NSView {
        login.onAction { [unowned self] c in change { $0.launchAtLogin = (c as! NSButton).state == .on } }
        for (flag, box) in afterBoxes {
            box.onAction { [unowned self] c in
                let on = (c as! NSButton).state == .on
                change { if on { $0.afterCapture.insert(flag) } else { $0.afterCapture.remove(flag) } }
            }
        }
        let choose = NSButton(title: "Choose\u{2026}", target: nil, action: nil)
        choose.setAccessibilityIdentifier("general.chooseFolder")
        choose.onAction { [unowned self] _ in
            ctx.env.pickFolder { url in
                if let url { self.change { $0.saveFolder = url.path } }
            }
        }
        let reset = NSButton(title: "Use Desktop", target: nil, action: nil)
        reset.setAccessibilityIdentifier("general.resetFolder")
        reset.onAction { [unowned self] _ in change { $0.saveFolder = nil } }
        folderLabel.lineBreakMode = .byTruncatingMiddle
        folderLabel.setAccessibilityIdentifier("general.folder")
        folderLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 300).isActive = true
        format.onAction { [unowned self] c in
            let i = (c as! NSPopUpButton).indexOfSelectedItem
            change { $0.imageFormat = SaveFormat.allCases[i] }
        }
        sound.onAction { [unowned self] c in change { $0.playSound = (c as! NSButton).state == .on } }
        loginNote.textColor = .systemRed
        loginNote.isHidden = true

        let folderRow = NSStackView(views: [folderLabel, choose, reset])
        folderRow.spacing = 8
        let pattern = Form.caption("Files are named Kadraj YYYY-MM-DD at HH.MM.SS.png")
        return Form.grid([
            ("Startup", Form.stack([login, loginNote])),
            ("After capture", Form.stack(afterBoxes.map(\.1))),
            ("Save folder", Form.stack([folderRow, pattern])),
            ("Format", format),
            ("Sound", sound),
        ])
    }

    override func refresh() {
        guard isViewLoaded else { return }
        login.state = settings.launchAtLogin ? .on : .off
        let err = ctx.loginError()
        loginNote.stringValue = err ?? ""
        loginNote.isHidden = err == nil
        for (flag, box) in afterBoxes { box.state = settings.afterCapture.contains(flag) ? .on : .off }
        folderLabel.stringValue = settings.resolvedSaveFolder(default: ctx.env.defaultSaveFolder).path
        format.selectItem(at: SaveFormat.allCases.firstIndex(of: settings.imageFormat) ?? 0)
        sound.state = settings.playSound ? .on : .off
    }
}

final class ShortcutsPane: SettingsPane {
    override var paneTitle: String { "Shortcuts" }
    override var symbol: String { "command" }
    private var recorders: [ActionID: ShortcutRecorderView] = [:]
    private var statusLabels: [ActionID: NSTextField] = [:]

    static var editableActions: [ActionSpec] { ActionTable.specs.filter { $0.menuGroup != nil && $0.id != .quit } }

    override func buildForm() -> NSView {
        var rows: [(String?, NSView)] = []
        for spec in Self.editableActions {
            let rec = ShortcutRecorderView()
            rec.setAccessibilityIdentifier("shortcut.\(spec.id.rawValue)")
            rec.setAccessibilityLabel(spec.title)
            rec.widthAnchor.constraint(equalToConstant: 150).isActive = true
            rec.heightAnchor.constraint(equalToConstant: 24).isActive = true
            rec.onChange = { [unowned self] key in
                change { s in
                    s.disabledShortcuts.remove(spec.id.rawValue)
                    if let key { s.customShortcuts[spec.id.rawValue] = key } else {
                        s.customShortcuts[spec.id.rawValue] = nil
                        s.disabledShortcuts.insert(spec.id.rawValue)
                    }
                }
            }
            let reset = NSButton(title: "Reset", target: nil, action: nil)
            reset.controlSize = .small
            reset.bezelStyle = .inline
            reset.setAccessibilityIdentifier("shortcutReset.\(spec.id.rawValue)")
            reset.onAction { [unowned self] _ in
                change { $0.customShortcuts[spec.id.rawValue] = nil; $0.disabledShortcuts.remove(spec.id.rawValue) }
            }
            let status = NSTextField(labelWithString: "")
            status.font = .systemFont(ofSize: 11)
            status.setAccessibilityIdentifier("shortcutStatus.\(spec.id.rawValue)")
            status.lineBreakMode = .byTruncatingTail
            status.widthAnchor.constraint(equalToConstant: 260).isActive = true
            recorders[spec.id] = rec
            statusLabels[spec.id] = status
            let row = NSStackView(views: [rec, reset, status])
            row.spacing = 8
            rows.append((spec.title, row))
        }
        return Form.grid(rows, width: 720)
    }

    override func refresh() {
        guard isViewLoaded else { return }
        let status = ctx.hotKeyStatus()
        for spec in Self.editableActions {
            recorders[spec.id]?.hotKey = settings.hotKey(for: spec.id)
            guard let label = statusLabels[spec.id] else { continue }
            switch status[spec.id] ?? .unassigned {
            case .registered: label.stringValue = "Active"; label.textColor = .systemGreen
            case .unassigned: label.stringValue = "Off"; label.textColor = .tertiaryLabelColor
            case .failed(let why): label.stringValue = "Not working: \(why)"; label.textColor = .systemRed
            }
        }
    }
}

final class QuickAccessPane: SettingsPane {
    override var paneTitle: String { "Quick Access" }
    override var symbol: String { "rectangle.stack" }
    private let corner = Form.popup(ScreenCorner.allCases.map(\.title), id: "quick.corner")
    private let size = Form.popup(OverlaySize.allCases.map(\.title), id: "quick.size")
    private let autoClose = Form.popup(Settings.autoCloseChoices.map { $0.map { "After \(Int($0)) seconds" } ?? "Never" }, id: "quick.autoClose")

    override func buildForm() -> NSView {
        corner.onAction { [unowned self] c in
            let i = (c as! NSPopUpButton).indexOfSelectedItem
            change { $0.overlayCorner = ScreenCorner.allCases[i] }
        }
        size.onAction { [unowned self] c in
            let i = (c as! NSPopUpButton).indexOfSelectedItem
            change { $0.overlaySize = OverlaySize.allCases[i] }
        }
        autoClose.onAction { [unowned self] c in
            let i = (c as! NSPopUpButton).indexOfSelectedItem
            change { $0.overlayAutoClose = Settings.autoCloseChoices[i] }
        }
        return Form.grid([
            ("Screen corner", corner),
            ("Card size", size),
            ("Close automatically", Form.stack([autoClose, Form.caption("The countdown pauses while the pointer is over a card.")])),
        ])
    }

    override func refresh() {
        guard isViewLoaded else { return }
        corner.selectItem(at: ScreenCorner.allCases.firstIndex(of: settings.overlayCorner) ?? 0)
        size.selectItem(at: OverlaySize.allCases.firstIndex(of: settings.overlaySize) ?? 0)
        autoClose.selectItem(at: Settings.autoCloseChoices.firstIndex { $0 == settings.overlayAutoClose } ?? 0)
    }
}

final class CapturePane: SettingsPane {
    override var paneTitle: String { "Capture" }
    override var symbol: String { "camera.viewfinder" }
    private let shadow = Form.checkbox("Include window shadow", id: "capture.shadow")
    private let timer = Form.stepper(range: 1...60, id: "capture.timer", suffix: "s")
    private let retention = Form.stepper(range: 1...365, id: "capture.retention", suffix: "days")

    override func buildForm() -> NSView {
        shadow.onAction { [unowned self] c in change { $0.windowShadow = (c as! NSButton).state == .on } }
        timer.stepper.onAction { [unowned self] c in change { $0.timerSeconds = Int((c as! NSStepper).intValue) } }
        retention.stepper.onAction { [unowned self] c in change { $0.retentionDays = Int((c as! NSStepper).intValue) } }
        return Form.grid([
            ("Windows", Form.stack([shadow, Form.caption("Hold Option while clicking a window to flip this once.")])),
            ("Timer", timer.view),
            ("Keep history", Form.stack([retention.view, Form.caption("Older captures are deleted when Kadraj starts and once a day.")])),
        ])
    }

    override func refresh() {
        guard isViewLoaded else { return }
        shadow.state = settings.windowShadow ? .on : .off
        timer.stepper.integerValue = settings.timerSeconds
        timer.label.stringValue = "\(settings.timerSeconds) seconds"
        retention.stepper.integerValue = settings.retentionDays
        retention.label.stringValue = "\(settings.retentionDays) days"
    }
}

final class PermissionsPane: SettingsPane {
    override var paneTitle: String { "Permissions" }
    override var symbol: String { "lock.shield" }
    private let status = NSTextField(labelWithString: "")
    private let shortcuts = NSTextField(wrappingLabelWithString: "")

    override func buildForm() -> NSView {
        status.font = .systemFont(ofSize: 13, weight: .medium)
        status.setAccessibilityIdentifier("permissions.status")
        shortcuts.setAccessibilityIdentifier("permissions.shortcuts")
        shortcuts.preferredMaxLayoutWidth = 340
        let open = NSButton(title: "Open System Settings", target: nil, action: nil)
        open.setAccessibilityIdentifier("permissions.open")
        open.onAction { [unowned self] _ in ctx.env.openURL(AppEnvironment.screenCapturePaneURL) }
        let request = NSButton(title: "Request Access", target: nil, action: nil)
        request.setAccessibilityIdentifier("permissions.request")
        request.onAction { [unowned self] _ in ctx.env.requestScreenPermission(); refresh() }
        let buttons = NSStackView(views: [open, request])
        buttons.spacing = 8
        return Form.grid([
            ("Screen recording", Form.stack([status, Form.caption("macOS applies a newly granted permission only after Kadraj is quit and opened again."), buttons], spacing: 10)),
            ("Global shortcuts", shortcuts),
        ])
    }

    override func refresh() {
        guard isViewLoaded else { return }
        let granted = ctx.env.hasScreenPermission()
        status.stringValue = granted ? "\u{25CF} Allowed" : "\u{25CF} Not allowed yet"
        status.textColor = granted ? .systemGreen : .systemOrange
        let all = ctx.hotKeyStatus()
        let failed = all.filter { if case .failed = $0.value { return true } else { return false } }
        let active = all.values.filter { $0 == .registered }.count
        shortcuts.stringValue = failed.isEmpty
            ? "\(active) shortcuts active"
            : "\(active) active, \(failed.count) not working. See the Shortcuts tab."
        shortcuts.textColor = failed.isEmpty ? .secondaryLabelColor : .systemRed
    }
}

@MainActor
final class SettingsWindowController: NSWindowController {
    let panes: [SettingsPane]
    let tabs = NSTabViewController()

    init(ctx: SettingsContext) {
        panes = [GeneralPane(ctx), ShortcutsPane(ctx), QuickAccessPane(ctx), CapturePane(ctx), PermissionsPane(ctx)]
        tabs.tabStyle = .toolbar
        for pane in panes {
            let item = NSTabViewItem(viewController: pane)
            item.label = pane.paneTitle
            item.image = NSImage(systemSymbolName: pane.symbol, accessibilityDescription: pane.paneTitle)
            tabs.addTabViewItem(item)
        }
        let window = NSWindow(contentViewController: tabs)
        window.title = "Kadraj Settings"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.center()
    }

    required init?(coder: NSCoder) { fatalError() }

    func refreshAll() { panes.forEach { $0.refresh() } }
}
