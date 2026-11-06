import AppKit
import CornermarkCapture
import CornermarkCore
import CornermarkDesign
import CornermarkVideoEditor

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
    func buildForm() -> FormPage { Form.page(title: paneTitle, groups: []) }
    /// Writes the current settings into the controls.
    func update() {}

    override func loadView() {
        view = buildForm()
        refresh()
    }

    /// Updates the controls, then re-measures the page, because a caption that changed can change a row's height.
    func refresh() {
        guard isViewLoaded else { return }
        update()
        (view as? FormPage)?.reflow()
    }

    /// The pane is on show, or no longer is. Called again while it stays on show, so it must be safe to repeat.
    func paneDidShow() {}
    func paneDidHide() {}

    func change(_ mutate: @escaping (inout Settings) -> Void) {
        ctx.store.update(mutate)
        refresh()
    }
}

final class GeneralPane: SettingsPane {
    override var paneTitle: String { "General" }
    override var symbol: String { "gearshape" }
    private let login = Form.checkbox("Launch Cornermark at login", id: "general.launchAtLogin")
    private let loginNote = Form.caption("", color: DS.Color.dangerText)
    private let afterBoxes: [(AfterCapture, String, Checkbox)] = [
        (.showOverlay, "Show Quick Access overlay", Form.checkbox("Show Quick Access overlay", id: "general.after.showOverlay")),
        (.copy, "Copy to clipboard", Form.checkbox("Copy to clipboard", id: "general.after.copy")),
        (.save, "Save to folder", Form.checkbox("Save to folder", id: "general.after.save")),
        (.openEditor, "Open in editor", Form.checkbox("Open in editor", id: "general.after.openEditor")),
    ]
    private let folderLabel = NSTextField.label("", style: DS.Text.caption, color: DS.Color.textSecondary)
    private let format = Form.popup(SaveFormat.allCases.map(\.title), id: "general.format")
    private let sound = Form.checkbox("Play a sound after capture", id: "general.sound")
    private let updates = Form.checkbox("Check for updates automatically", id: "general.checkForUpdates")
    private let versionNote = Form.caption("")

    override func buildForm() -> FormPage {
        login.onAction { [unowned self] c in change { $0.launchAtLogin = (c as! NSButton).state == .on } }
        for (flag, _, box) in afterBoxes {
            box.onAction { [unowned self] c in
                let on = (c as! NSButton).state == .on
                change { if on { $0.afterCapture.insert(flag) } else { $0.afterCapture.remove(flag) } }
            }
        }
        let choose = Button(title: "Choose\u{2026}", variant: .secondary, size: .small)
        choose.setAccessibilityIdentifier("general.chooseFolder")
        choose.onAction { [unowned self] _ in
            ctx.env.pickFolder { url in
                if let url { self.change { $0.saveFolder = url.path } }
            }
        }
        let reset = Button(title: "Use Desktop", variant: .ghost, size: .small)
        reset.setAccessibilityIdentifier("general.resetFolder")
        reset.onAction { [unowned self] _ in change { $0.saveFolder = nil } }
        folderLabel.lineBreakMode = .byTruncatingMiddle
        folderLabel.setAccessibilityIdentifier("general.folder")
        format.onAction { [unowned self] c in
            let i = (c as! NSPopUpButton).indexOfSelectedItem
            change { $0.imageFormat = SaveFormat.allCases[i] }
        }
        sound.onAction { [unowned self] c in change { $0.playSound = (c as! NSButton).state == .on } }
        updates.onAction { [unowned self] c in change { $0.checkForUpdatesAutomatically = (c as! NSButton).state == .on } }
        loginNote.isHidden = true

        return Form.page(title: paneTitle, groups: [
            .init("Startup", rows: [Form.row(title: "Launch Cornermark at login", caption: loginNote, control: login)]),
            .init("After capture", rows: afterBoxes.map { Form.row(title: $0.1, control: $0.2) }),
            .init("Save", rows: [
                Form.row(title: "Save folder", caption: folderLabel, control: Form.hstack([reset, choose])),
                Form.row(title: "Format", control: format),
            ], footer: "Files are named Cornermark YYYY-MM-DD at HH.MM.SS.png"),
            .init("Feedback", rows: [Form.row(title: "Play a sound after capture", control: sound)]),
            .init("Updates", rows: [Form.row(title: "Check for updates automatically", caption: versionNote, control: updates)]),
        ])
    }

    override func update() {
        login.state = settings.launchAtLogin ? .on : .off
        let err = ctx.loginError()
        loginNote.stringValue = err ?? ""
        loginNote.isHidden = err == nil
        for (flag, _, box) in afterBoxes { box.state = settings.afterCapture.contains(flag) ? .on : .off }
        folderLabel.stringValue = settings.resolvedSaveFolder(default: ctx.env.defaultSaveFolder).path
        format.selectItem(at: SaveFormat.allCases.firstIndex(of: settings.imageFormat) ?? 0)
        sound.state = settings.playSound ? .on : .off
        updates.state = settings.checkForUpdatesAutomatically ? .on : .off
        let version = ctx.env.updateService.currentVersion.map { "Version \($0). " } ?? ""
        versionNote.stringValue = version + "Checks GitHub at launch and once a day, and sends no personal data."
    }
}

final class ShortcutsPane: SettingsPane {
    override var paneTitle: String { "Shortcuts" }
    override var symbol: String { "command" }
    private var recorders: [ActionID: ShortcutRecorderView] = [:]
    private var statusLabels: [ActionID: NSTextField] = [:]

    static var editableActions: [ActionSpec] { ActionTable.specs.filter { $0.menuGroup != nil && $0.id != .quit } }

    override func buildForm() -> FormPage {
        var rows: [FormRow] = []
        for spec in Self.editableActions {
            let rec = ShortcutRecorderView()
            rec.setAccessibilityIdentifier("shortcut.\(spec.id.rawValue)")
            rec.setAccessibilityLabel(spec.title)
            rec.onChange = { [unowned self] key in
                change { s in
                    s.disabledShortcuts.remove(spec.id.rawValue)
                    if let key { s.customShortcuts[spec.id.rawValue] = key } else {
                        s.customShortcuts[spec.id.rawValue] = nil
                        s.disabledShortcuts.insert(spec.id.rawValue)
                    }
                }
            }
            let reset = IconButton(symbol: "arrow.counterclockwise", label: "Reset", size: .small, tone: .plain)
            reset.setAccessibilityIdentifier("shortcutReset.\(spec.id.rawValue)")
            reset.onAction { [unowned self] _ in
                change { $0.customShortcuts[spec.id.rawValue] = nil; $0.disabledShortcuts.remove(spec.id.rawValue) }
            }
            let status = Form.caption("")
            status.setAccessibilityIdentifier("shortcutStatus.\(spec.id.rawValue)")
            recorders[spec.id] = rec
            statusLabels[spec.id] = status
            rows.append(Form.row(title: spec.title, caption: status, control: Form.hstack([reset, rec])))
        }
        return Form.page(title: paneTitle, groups: [.init("Anywhere on your Mac", rows: rows)] + Self.editorGroups())
    }

    /// The video editor's keys, read from the table the editor answers from. They work only while an editor is in front, so they
    /// are listed, not recorded.
    static func editorGroups() -> [Form.Group] {
        EditorCommand.Group.allCases.map { group in
            let rows = EditorShortcuts.all.filter { $0.command.group == group }.map { shortcut in
                let caps = KeyCaps(shortcut.keys.map(\.display), spoken: shortcut.keys.map(\.spoken))
                caps.setAccessibilityIdentifier("editorShortcut.\(shortcut.command.rawValue)")
                return Form.row(title: shortcut.command.title, caption: shortcut.note.map { Form.caption($0) }, control: caps)
            }
            return Form.Group(group.title, rows: rows, footer: group == .file ? "These keys work while a video editor window is in front." : nil)
        }
    }

    override func update() {
        let status = ctx.hotKeyStatus()
        for spec in Self.editableActions {
            recorders[spec.id]?.hotKey = settings.hotKey(for: spec.id)
            guard let label = statusLabels[spec.id] else { continue }
            switch status[spec.id] ?? .unassigned {
            case .registered: label.stringValue = "Active"; label.textColor = DS.Color.textSecondary
            case .unassigned: label.stringValue = "Off"; label.textColor = DS.Color.textSecondary
            case .failed(let why): label.stringValue = "Not working: \(why)"; label.textColor = DS.Color.dangerText
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

    override func buildForm() -> FormPage {
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
        return Form.page(title: paneTitle, groups: [.init(rows: [
            Form.row(title: "Screen corner", control: corner),
            Form.row(title: "Card size", control: size),
            Form.row(title: "Close automatically", caption: Form.caption("The countdown pauses while the pointer is over a card."), control: autoClose),
        ])])
    }

    override func update() {
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

    override func buildForm() -> FormPage {
        shadow.onAction { [unowned self] c in change { $0.windowShadow = (c as! NSButton).state == .on } }
        timer.stepper.onAction { [unowned self] c in change { $0.timerSeconds = Int((c as! NSStepper).intValue) } }
        retention.stepper.onAction { [unowned self] c in change { $0.retentionDays = Int((c as! NSStepper).intValue) } }
        return Form.page(title: paneTitle, groups: [.init(rows: [
            Form.row(title: "Include window shadow", caption: Form.caption("Hold Option while clicking a window to flip this once."), control: shadow),
            Form.row(title: "Timer", control: timer.view),
            Form.row(title: "Keep history", caption: Form.caption("Older captures are deleted when Cornermark starts and once a day."), control: retention.view),
        ])])
    }

    override func update() {
        shadow.state = settings.windowShadow ? .on : .off
        timer.stepper.integerValue = settings.timerSeconds
        timer.label.stringValue = "\(settings.timerSeconds) seconds"
        retention.stepper.integerValue = settings.retentionDays
        retention.label.stringValue = "\(settings.retentionDays) days"
    }
}

extension VideoQuality {
    var title: String { rawValue.capitalized }
}

extension PixelDensity {
    var title: String { self == .retina ? "Retina" : "Standard" }
}

extension SizeLimit {
    var title: String {
        switch self {
        case .none: return "No limit"
        case .uhd: return "4K (3840 \u{00D7} 2160)"
        case .qhd: return "1440p (2560 \u{00D7} 1440)"
        case .fullHD: return "1080p (1920 \u{00D7} 1080)"
        case .hd: return "720p (1280 \u{00D7} 720)"
        }
    }
}

final class RecordingPane: SettingsPane {
    override var paneTitle: String { "Recording" }
    override var symbol: String { "record.circle" }
    private let fps = Form.popup(RecordingPreferences.fpsChoices.map { "\($0) fps" }, id: "recording.fps")
    private let quality = Form.popup(VideoQuality.allCases.map(\.title), id: "recording.quality")
    private let density = Form.popup(PixelDensity.allCases.map(\.title), id: "recording.resolution")
    private let limit = Form.popup(SizeLimit.allCases.map(\.title), id: "recording.limit")
    private let cursor = Form.checkbox("Show cursor", id: "recording.cursor")
    private let quickAccess = Form.checkbox("Show Quick Access overlay", id: "recording.quickAccess")
    private let countdown = Form.popup(RecordingPreferences.countdownChoices.map { $0 == 0 ? "Off" : "\($0) seconds" }, id: "recording.countdown")
    private let dim = Form.checkbox("Dim outside the area", id: "recording.dim")
    private let desktopIcons = Form.checkbox("Keep desktop icons out of the video", id: "recording.desktopIcons")
    private let notifications = Form.checkbox("Keep notifications out of the video", id: "recording.notifications")
    private let inputStatus = NSTextField.label("", style: DS.Text.bodyStrong, color: DS.Color.textPrimary)
    private let inputDot = StatusDot()
    private let inputNote = Form.caption("")
    private let inputOpen = Button(title: "Open System Settings", variant: .secondary, size: .small)
    private let clicks = Form.checkbox("Highlight clicks", id: "recording.clicks")
    private let clickColor = Form.popup(ClickHighlight.Color.allCases.map(\.title), id: "recording.clickColor")
    private let clickStyle = Form.popup(ClickHighlight.Style.allCases.map(\.title), id: "recording.clickStyle")
    private let clickSize = Form.popup(ClickHighlight.Size.allCases.map(\.title), id: "recording.clickSize")
    private let clickAnimation = Form.checkbox("Animate clicks", id: "recording.clickAnimation")
    private let keys = Form.checkbox("Show keystrokes", id: "recording.keys")
    private let keyMode = Form.popup(KeystrokeDisplay.Keys.allCases.map(\.title), id: "recording.keyMode")
    private let keyPosition = Form.popup(KeystrokeDisplay.panePositions.map(\.title), id: "recording.keyPosition")
    private let keySize = Form.popup(KeystrokeDisplay.Size.allCases.map(\.title), id: "recording.keySize")
    private let keyStyle = Form.popup(KeystrokeDisplay.Theme.allCases.map(\.title), id: "recording.keyStyle")

    override func buildForm() -> FormPage {
        fps.onAction { [unowned self] c in
            let i = (c as! NSPopUpButton).indexOfSelectedItem
            change { $0.recording.fps = RecordingPreferences.fpsChoices[i] }
        }
        quality.onAction { [unowned self] c in
            let i = (c as! NSPopUpButton).indexOfSelectedItem
            change { $0.recording.quality = VideoQuality.allCases[i] }
        }
        density.onAction { [unowned self] c in
            let i = (c as! NSPopUpButton).indexOfSelectedItem
            change { $0.recording.density = PixelDensity.allCases[i] }
        }
        limit.onAction { [unowned self] c in
            let i = (c as! NSPopUpButton).indexOfSelectedItem
            change { $0.recording.limit = SizeLimit.allCases[i] }
        }
        cursor.onAction { [unowned self] c in change { $0.recording.showCursor = (c as! NSButton).state == .on } }
        quickAccess.onAction { [unowned self] c in change { $0.recording.showQuickAccess = (c as! NSButton).state == .on } }
        countdown.onAction { [unowned self] c in
            let i = (c as! NSPopUpButton).indexOfSelectedItem
            change { $0.recording.countdown = RecordingPreferences.countdownChoices[i] }
        }
        dim.onAction { [unowned self] c in change { $0.recording.dimOutside = (c as! NSButton).state == .on } }
        desktopIcons.onAction { [unowned self] c in change { $0.recording.hideDesktopIcons = (c as! NSButton).state == .on } }
        notifications.onAction { [unowned self] c in change { $0.recording.hideNotifications = (c as! NSButton).state == .on } }
        buildInputControls()
        return Form.page(title: paneTitle, groups: [
            .init("Video", rows: [
                Form.row(title: "Frame rate", control: fps),
                Form.row(title: "Quality", caption: Form.caption("Lower quality makes smaller files."), control: quality),
                Form.row(title: "Resolution", caption: Form.caption("Standard records one pixel per point, a quarter of the pixels on a Retina display."), control: density),
                Form.row(title: "Largest size", caption: Form.caption("A larger recording is scaled down to fit."), control: limit),
            ], footer: "Recordings are saved to the save folder set in General."),
            .init("Cursor", rows: [
                Form.row(title: "Show cursor", caption: Form.caption("Record MP4 draws the cursor into the video. Record Project keeps it separate, so you can still hide it later."),
                         control: cursor),
            ]),
            .init("While recording", rows: [
                Form.row(title: "Countdown", caption: Form.caption("Time to get ready before the first frame."), control: countdown),
                Form.row(title: "Dim outside the area", caption: Form.caption("Darkens the rest of the screen while an area records. The video never shows it."), control: dim),
                Form.row(title: "Keep desktop icons out of the video", caption: Form.caption("Finder windows are still recorded."), control: desktopIcons),
                Form.row(title: "Keep notifications out of the video", caption: Form.caption("Notifications still appear on your screen."), control: notifications),
            ], footer: "The display stays awake while recording."),
            .init("Clicks", rows: [
                Form.row(title: "Highlight clicks", caption: Form.caption("Draws a ring where you click. Record Project keeps every click, so you can add rings later."),
                         control: clicks),
                Form.row(title: "Ring", control: Form.hstack([clickColor, clickStyle, clickSize], spacing: DS.Space.s6)),
                Form.row(title: "Animate clicks", control: clickAnimation),
            ]),
            .init("Keystrokes", rows: [
                Form.row(title: "Show keystrokes", caption: Form.caption("Keys typed in password fields are never shown or saved."), control: keys),
                Form.row(title: "Keys", caption: Form.caption("Shortcuts only shows keys pressed with Command or Control."), control: keyMode),
                Form.row(title: "Badge", control: Form.hstack([keyPosition, keySize, keyStyle], spacing: DS.Space.s6)),
            ]),
            .init(rows: [
                Form.row(title: "Input Monitoring", caption: inputNote, control: Form.hstack([inputDot, inputStatus, inputOpen], spacing: DS.Space.s6)),
            ]),
            .init("After recording", rows: [Form.row(title: "Show Quick Access overlay", control: quickAccess)]),
        ])
    }

    override func update() {
        let r = settings.recording
        fps.selectItem(at: RecordingPreferences.fpsChoices.firstIndex(of: r.fps) ?? 0)
        quality.selectItem(at: VideoQuality.allCases.firstIndex(of: r.quality) ?? 0)
        density.selectItem(at: PixelDensity.allCases.firstIndex(of: r.density) ?? 0)
        limit.selectItem(at: SizeLimit.allCases.firstIndex(of: r.limit) ?? 0)
        cursor.state = r.showCursor ? .on : .off
        quickAccess.state = r.showQuickAccess ? .on : .off
        countdown.selectItem(at: RecordingPreferences.countdownChoices.firstIndex(of: r.countdown) ?? 0)
        dim.state = r.dimOutside ? .on : .off
        desktopIcons.state = r.hideDesktopIcons ? .on : .off
        notifications.state = r.hideNotifications ? .on : .off
        updateInputControls(r)
    }

    private func buildInputControls() {
        inputStatus.setAccessibilityIdentifier("recording.inputPermission")
        inputOpen.setAccessibilityIdentifier("recording.inputPermission.open")
        inputOpen.onAction { [unowned self] _ in ctx.env.openURL(AppEnvironment.inputMonitoringPaneURL) }
        for (popup, name) in [(clickColor, "Ring color"), (clickStyle, "Ring style"), (clickSize, "Ring size"), (keyMode, "Keys"),
                              (keyPosition, "Badge position"), (keySize, "Badge size"), (keyStyle, "Badge style")] {
            popup.setAccessibilityLabel(name)
        }
        for (i, color) in ClickHighlight.Color.allCases.enumerated() { clickColor.item(at: i)?.image = Self.swatch(color) }
        func pick<T>(_ popup: NSPopUpButton, _ all: [T], _ set: @escaping (inout RecordingPreferences, T) -> Void) {
            popup.onAction { [unowned self] c in
                let value = all[(c as! NSPopUpButton).indexOfSelectedItem]
                change { set(&$0.recording, value) }
            }
        }
        clicks.onAction { [unowned self] c in change { $0.recording.clicks.isVisible = (c as! NSButton).state == .on } }
        pick(clickColor, ClickHighlight.Color.allCases) { $0.clicks.color = $1 }
        pick(clickStyle, ClickHighlight.Style.allCases) { $0.clicks.style = $1 }
        pick(clickSize, ClickHighlight.Size.allCases) { $0.clicks.size = $1 }
        clickAnimation.onAction { [unowned self] c in change { $0.recording.clicks.animates = (c as! NSButton).state == .on } }
        keys.onAction { [unowned self] c in change { $0.recording.keystrokes.isVisible = (c as! NSButton).state == .on } }
        pick(keyMode, KeystrokeDisplay.Keys.allCases) { $0.keystrokes.keys = $1 }
        pick(keyPosition, KeystrokeDisplay.panePositions) { $0.keystrokes.position = $1 }
        pick(keySize, KeystrokeDisplay.Size.allCases) { $0.keystrokes.size = $1 }
        pick(keyStyle, KeystrokeDisplay.Theme.allCases) { $0.keystrokes.theme = $1 }
    }

    private func updateInputControls(_ r: RecordingPreferences) {
        clicks.state = r.clicks.isVisible ? .on : .off
        clickColor.selectItem(at: ClickHighlight.Color.allCases.firstIndex(of: r.clicks.color) ?? 0)
        clickStyle.selectItem(at: ClickHighlight.Style.allCases.firstIndex(of: r.clicks.style) ?? 0)
        clickSize.selectItem(at: ClickHighlight.Size.allCases.firstIndex(of: r.clicks.size) ?? 0)
        clickAnimation.state = r.clicks.animates ? .on : .off
        ([clickColor, clickStyle, clickSize, clickAnimation] as [NSControl]).forEach { $0.isEnabled = r.clicks.isVisible }
        keys.state = r.keystrokes.isVisible ? .on : .off
        keyMode.selectItem(at: KeystrokeDisplay.Keys.allCases.firstIndex(of: r.keystrokes.keys) ?? 0)
        keyPosition.selectItem(at: KeystrokeDisplay.panePositions.firstIndex(of: r.keystrokes.position) ?? 0)
        keySize.selectItem(at: KeystrokeDisplay.Size.allCases.firstIndex(of: r.keystrokes.size) ?? 0)
        keyStyle.selectItem(at: KeystrokeDisplay.Theme.allCases.firstIndex(of: r.keystrokes.theme) ?? 0)
        [keyMode, keyPosition, keySize, keyStyle].forEach { $0.isEnabled = r.keystrokes.isVisible }
        let allowed = ctx.env.hasInputPermission()
        inputStatus.stringValue = allowed ? "Allowed" : "Not allowed"
        let blocking = !allowed && r.showsInput
        inputStatus.textColor = allowed ? DS.Color.successText : blocking ? DS.Color.dangerText : DS.Color.textSecondary
        inputDot.color = inputStatus.textColor ?? DS.Color.textSecondary
        inputNote.textColor = blocking ? DS.Color.dangerText : DS.Color.textSecondary
        inputNote.stringValue = allowed
            ? "Cornermark sees clicks and keys only while it records."
            : blocking
            ? "Clicks and keystrokes are not recorded. Turn on Cornermark in System Settings > Privacy & Security > Input Monitoring, then quit and open Cornermark again."
            : "Clicks and keystrokes need it. Recording works without it."
        inputOpen.variant = blocking ? .primary : .secondary
        inputOpen.isHidden = allowed
    }

    private static func swatch(_ color: ClickHighlight.Color) -> NSImage {
        let fill = InputOverlayInk.design.click(color)
        return NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.setFillColor(fill)
            ctx.fillEllipse(in: rect.insetBy(dx: 1, dy: 1))
            ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.25))
            ctx.setLineWidth(1)
            ctx.strokeEllipse(in: rect.insetBy(dx: 1.5, dy: 1.5))
            return true
        }
    }
}

extension ClickHighlight.Color {
    var title: String { rawValue.capitalized }
}

extension ClickHighlight.Style {
    var title: String { rawValue.capitalized }
}

extension ClickHighlight.Size {
    var title: String { rawValue.capitalized }
}

extension KeystrokeDisplay.Keys {
    var title: String { self == .all ? "All keys" : "Shortcuts only" }
}

extension KeystrokeDisplay {
    /// The places the Recording pane offers. The video editor can move the badge to any cell of the grid later.
    static let panePositions: [GridPosition] = [.bottomCenter, .bottomLeft, .bottomRight, .topCenter]
}

extension KeystrokeDisplay.Size {
    var title: String { rawValue.capitalized }
}

extension KeystrokeDisplay.Theme {
    var title: String { rawValue.capitalized }
}

/// A dot in a status colour. Drawn at draw time through `Glyph`, so the colour follows light and dark.
final class StatusDot: NSView {
    var color: NSColor = DS.Color.textSecondary { didSet { needsDisplay = true } }
    override var intrinsicContentSize: NSSize { NSSize(width: DS.Size.icon, height: DS.Size.icon) }
    override func draw(_ dirtyRect: NSRect) { Glyph.draw("circle.fill", in: bounds, pointSize: DS.Size.iconSmall - 4, color) }
}

final class PermissionsPane: SettingsPane {
    override var paneTitle: String { "Permissions" }
    override var symbol: String { "lock.shield" }
    private let status = NSTextField.label("", style: DS.Text.bodyStrong, color: DS.Color.textPrimary)
    private let dot = StatusDot()
    private let shortcuts = NSTextField.label("", style: DS.Text.body, color: DS.Color.textSecondary)
    private let request = Button(title: "Request Access", variant: .secondary, size: .small)
    private let open = Button(title: "Open System Settings", variant: .secondary, size: .small)

    override func buildForm() -> FormPage {
        status.setAccessibilityIdentifier("permissions.status")
        shortcuts.setAccessibilityIdentifier("permissions.shortcuts")
        shortcuts.alignment = .right
        open.setAccessibilityIdentifier("permissions.open")
        open.onAction { [unowned self] _ in ctx.env.openURL(AppEnvironment.screenCapturePaneURL) }
        request.setAccessibilityIdentifier("permissions.request")
        request.onAction { [unowned self] _ in ctx.env.requestScreenPermission(); refresh() }
        let buttons = Form.hstack([request, open])
        return Form.page(title: paneTitle, groups: [.init(rows: [
            Form.row(title: "Screen recording", caption: Form.caption("macOS applies a newly granted permission only after Cornermark is quit and opened again."),
                     control: Form.hstack([dot, status], spacing: DS.Space.s6)),
            Form.row(title: "Global shortcuts", control: shortcuts),
            Form.row(title: "", control: buttons),
        ])])
    }

    override func update() {
        let granted = ctx.env.hasScreenPermission()
        status.stringValue = granted ? "Allowed" : "Not allowed yet"
        status.textColor = granted ? DS.Color.successText : DS.Color.warningText
        dot.color = status.textColor ?? DS.Color.textSecondary
        // Once access is granted the buttons are shortcuts to a settled thing, so the primary action goes away.
        open.variant = granted ? .secondary : .primary
        let all = ctx.hotKeyStatus()
        let failed = all.filter { if case .failed = $0.value { return true } else { return false } }
        let active = all.values.filter { $0 == .registered }.count
        shortcuts.stringValue = failed.isEmpty
            ? "\(active) shortcuts active"
            : "\(active) active, \(failed.count) not working. See the Shortcuts pane."
        shortcuts.textColor = failed.isEmpty ? DS.Color.textSecondary : DS.Color.dangerText
    }
}

/// The left column: fills the window's full height under the traffic lights, on the surface colour, with one hairline on its right.
private final class SidebarView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        DS.Color.bgSurface.setFill()
        bounds.fill()
        DS.Color.separator.setFill()
        NSRect(x: bounds.width - 1, y: 0, width: 1, height: bounds.height).fill()
    }
}

@MainActor
final class SettingsWindowController: NSWindowController {
    static let size = NSSize(width: 760, height: 560)
    /// The traffic lights sit in the top 44pt of the sidebar; the first item starts below them.
    private static let sidebarTop: CGFloat = 44

    let panes: [SettingsPane]
    private(set) var selectedPane: SettingsPane
    private let items: [SidebarItem]
    private let scroll = NSScrollView()

    init(ctx: SettingsContext) {
        let panes = [GeneralPane(ctx), ShortcutsPane(ctx), QuickAccessPane(ctx), CapturePane(ctx), RecordingPane(ctx), AudioPane(ctx), CameraPane(ctx), PermissionsPane(ctx)]
        self.panes = panes
        selectedPane = panes[0]
        items = panes.map { SidebarItem(symbol: $0.symbol, title: $0.paneTitle) }

        let window = NSWindow(contentRect: NSRect(origin: .zero, size: Self.size), styleMask: [.titled, .closable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "Cornermark Settings"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.backgroundColor = DS.Color.bgWindow
        window.isReleasedWhenClosed = false
        // With the title bar over the content, the content rect is the whole frame.
        window.setFrame(NSRect(origin: .zero, size: Self.size), display: false)
        super.init(window: window)
        build(in: window)
        select(pane: panes[0])
        window.center()
        // A pane that listens to the microphone stops when the window closes.
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.selectedPane.paneDidHide() }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    private func build(in window: NSWindow) {
        let sidebar = SidebarView()
        let stack = NSStackView(views: items)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = DS.Space.s2
        stack.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(stack)
        for (i, item) in items.enumerated() {
            item.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            item.setAccessibilityIdentifier("settings.sidebar.\(panes[i].paneTitle.lowercased().replacingOccurrences(of: " ", with: "-"))")
            item.onAction { [unowned self] _ in select(pane: panes[i]) }
        }
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: Self.sidebarTop),
            stack.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: DS.Space.s12),
            stack.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -DS.Space.s12),
        ])

        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        // The title bar floats over the content, so nothing may push the page down to clear it.
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets()
        scroll.setAccessibilityIdentifier("settings.scroll")

        let root = NSView()
        window.contentView = root
        for v in [sidebar, scroll] { v.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(v) }
        NSLayoutConstraint.activate([
            sidebar.topAnchor.constraint(equalTo: root.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: Form.sidebarWidth),
            scroll.topAnchor.constraint(equalTo: root.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
        ])
    }

    /// Shows `pane` in place. The window keeps its size and nothing animates.
    func select(pane: SettingsPane) {
        if selectedPane !== pane { selectedPane.paneDidHide() }
        selectedPane = pane
        for (item, candidate) in zip(items, panes) { item.isSelected = candidate === pane }
        pane.refresh()
        scroll.documentView = pane.view
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        pane.paneDidShow()
    }

    func refreshAll() {
        panes.forEach { $0.refresh() }
        selectedPane.paneDidShow()
    }
}
