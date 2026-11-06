import AppKit
import CornermarkDesign
import CornermarkL10n

/// The panel of a recording overlay: quick options, what to film, its size, what the recording takes besides the picture, and the buttons
/// that start it. It sits in the middle of the selection. Mouse events stop here so clicking its background never starts a new selection
/// underneath it.
final class RecordingPanel: Surface {
    var onAction: ((ToolbarAction) -> Void)?
    var onToggle: ((RecordingSource) -> Void)?
    /// The options menu changed a value. The whole value comes back, so the menu and the settings never disagree on a field.
    var onOptions: ((RecordingQuickOptions) -> Void)?
    var onHelp: (() -> Void)?

    /// Holds the `hud` elevation's ambient shadow (blur 24 at y 8) with room to spare.
    private static let inset = DS.Space.s32
    /// The check on a source toggle overflows its corner, so the toggles sit far enough apart that it keeps clear of the next one.
    private static let sourceGap = IconButton.markOverflow + DS.Space.s4
    private static let fieldWidth: CGFloat = 52
    private static let aspectWidth: CGFloat = 72
    /// Holds the longest note, Input Monitoring's, in two caption lines beside the toggles. HarnessShell measures every note against it.
    private static let noteWidth: CGFloat = 264
    private static func keyName(_ style: RecordingStyle) -> String {
        switch style {
        case .video: return tr("Return")
        case .editing: return tr("Shift-Return")
        case .gif: return tr("Option-Return")
        }
    }

    /// What each start button leaves behind, for its tooltip and VoiceOver.
    static func outcome(_ style: RecordingStyle) -> String {
        switch style {
        case .video: return tr("Saves one MP4 to share right away, with the pointer drawn in")
        case .editing: return tr("Saves a project you can edit: pointer, clicks, keys, camera and sound stay separate until you export")
        case .gif: return tr("Saves one animated GIF, without sound")
        }
    }

    /// A source's toggle: the filled glyph and a check while it is on, the slashed one while it is off, so the state never rests on
    /// colour alone. The keyboard has no slashed symbol, so the toggle draws the slash over the outlined one. `action` names what turning it on does, for the tooltip.
    static func look(_ source: RecordingSource) -> (on: String, off: String, action: String, help: String) {
        switch source {
        case .microphone: return ("mic.fill", "mic.slash", tr("Record microphone"), tr("Records your voice. Record GIF never records sound."))
        case .systemAudio: return ("speaker.wave.2.fill", "speaker.slash", tr("Record system audio"), tr("Records what your Mac plays. Record GIF never records sound."))
        case .camera: return ("video.fill", "video.slash", tr("Show camera"), tr("Shows your camera in a bubble."))
        case .clicks: return ("cursorarrow.click.2", "cursorarrow.slash", tr("Highlight clicks"), tr("Draws a ring where you click."))
        case .keystrokes: return ("keyboard.fill", "keyboard", tr("Show keystrokes"), tr("Shows the keys you press. Keys typed in password fields never show."))
        }
    }

    private let optionsButton = IconButton(symbol: "slider.horizontal.3", label: tr("Recording options"), size: .large)
    private var leftToRight = LeftToRightFrames()
    private var options: RecordingQuickOptions?
    private let help = IconButton(symbol: "questionmark.circle", label: RecordingHelpWindow.title, size: .large)
    private let targets: [(mode: ToolbarMode, button: IconButton)]
    private let aspect = Select()
    private let widthField = TextInput(placeholder: tr("W"), monospaced: true, centered: true)
    private let heightField = TextInput(placeholder: tr("H"), monospaced: true, centered: true)
    private let starts: [(style: RecordingStyle, button: Button)]
    private let sources: [(source: RecordingSource, button: IconButton)]
    private let note = NSTextField.label("", style: DS.Text.caption, color: DS.Color.textSecondary)

    init() {
        targets = [
            (.area, IconButton(symbol: "rectangle.dashed", label: tr("Area"), size: .large)),
            (.window, IconButton(symbol: "macwindow", label: tr("Window"), size: .large)),
            (.fullscreen, IconButton(symbol: "display", label: tr("Fullscreen"), size: .large)),
        ]
        starts = [
            (.video, Button(title: tr("Record MP4"), variant: .primary, size: .large, symbol: "record.circle", shortcut: "\u{21A9}")),
            (.gif, Button(title: tr("Record GIF"), variant: .secondary, size: .large, shortcut: "\u{2325}\u{21A9}")),
            (.editing, Button(title: tr("Record Project"), variant: .secondary, size: .large, shortcut: "\u{21E7}\u{21A9}")),
        ]
        sources = RecordingSource.allCases.map { ($0, IconButton(symbol: Self.look($0).off, label: $0.name, size: .regular)) }
        super.init(style: .hud, shadowInset: Self.inset)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(tr("Recording"))

        let pad = DS.Space.s4
        let row = DS.Size.controlLarge
        let left = Self.inset + pad

        // Rows from the bottom: Record Project on its own, set apart from the two that share at once, then the sources, then the top row.
        let project = Self.inset + pad
        let rule = project + row + pad
        let quickRow = rule + 1 + pad
        let middle = quickRow + row + 2 * pad
        let top = middle + DS.Size.control + 2 * pad
        func centred(_ height: CGFloat) -> CGFloat { top + (row - height) / 2 }
        var x = left
        func divider() {
            x += DS.Space.s8
            let line = Separator(axis: .vertical)
            let height = DS.Size.control - DS.Space.s8
            line.frame = CGRect(x: x, y: centred(height), width: 1, height: height)
            addSubview(line)
            x += 1 + DS.Space.s8
        }

        optionsButton.frame.origin = CGPoint(x: x, y: top)
        optionsButton.target = self
        optionsButton.action = #selector(optionsClicked)
        optionsButton.setAccessibilityIdentifier("cornermark.record.options")
        optionsButton.setAccessibilityRole(.menuButton)
        optionsButton.setAccessibilityHelp(tr("Quality, frame rate, countdown and what the recording shows or leaves out."))
        addSubview(optionsButton)
        x += row
        divider()

        for (i, item) in targets.enumerated() {
            item.button.frame.origin = CGPoint(x: x, y: top)
            item.button.target = self
            item.button.action = #selector(targetClicked(_:))
            item.button.setAccessibilityIdentifier("cornermark.record.target.\(item.mode)")
            addSubview(item.button)
            x += row + (i < targets.count - 1 ? DS.Space.s4 : 0)
        }
        divider()

        for (field, id, label, hint, action) in [(widthField, "cornermark.record.width", tr("Width"), tr("Width in points"), #selector(widthChanged)),
                                                 (heightField, "cornermark.record.height", tr("Height"), tr("Height in points"), #selector(heightChanged))] {
            field.frame = CGRect(x: x, y: centred(DS.Size.control), width: Self.fieldWidth, height: DS.Size.control)
            field.cell?.sendsActionOnEndEditing = true
            field.setAccessibilityIdentifier(id)
            field.setAccessibilityLabel(label)
            field.toolTip = hint
            field.target = self
            field.action = action
            addSubview(field)
            x += Self.fieldWidth
            if field === widthField {
                let times = NSTextField.label("×", style: DS.Text.caption, color: DS.Color.textSecondary)
                times.alignment = .center
                times.frame = CGRect(x: x, y: centred(DS.Text.caption.lineHeight), width: DS.Space.s16, height: DS.Text.caption.lineHeight)
                addSubview(times)
                x += DS.Space.s16
            }
        }
        divider()

        for lock in AspectLock.presets { aspect.addItem(withTitle: lock.title) }
        aspect.toolTip = tr("Aspect ratio")
        aspect.setAccessibilityLabel(tr("Aspect ratio"))
        aspect.setAccessibilityIdentifier("cornermark.record.aspect")
        // The toggles and their note set the narrowest the panel can be. Any width they need past the top row goes to the aspect menu,
        // so the top row still ends at the panel's edge.
        let sourcesWidth = CGFloat(sources.count) * (DS.Size.control + Self.sourceGap) - Self.sourceGap + DS.Space.s12 + Self.noteWidth
        let aspectWidth = max(Self.aspectWidth, left + sourcesWidth - x)
        aspect.frame = CGRect(x: x, y: centred(DS.Size.control), width: aspectWidth, height: DS.Size.control)
        aspect.target = self
        aspect.action = #selector(aspectChanged)
        addSubview(aspect)
        x += aspectWidth

        // Each start button keeps its title's width and the room left over is shared, so the panel stays narrow enough to sit inside a
        // modest selection. Record Project gives up a button's width to its help.
        let gap = DS.Space.s4
        let quick = starts.filter { $0.style != .editing }
        let natural = quick.map(\.button.frame.width).reduce(0, +) + gap * CGFloat(quick.count - 1)
        let projectButton = starts.first { $0.style == .editing }!.button
        let width = max(x - left, natural, projectButton.frame.width + gap + row)
        var bx = left
        for (i, item) in quick.enumerated() {
            let w = i == quick.count - 1 ? left + width - bx : (item.button.frame.width + (width - natural) / CGFloat(quick.count)).rounded()
            item.button.frame = CGRect(x: bx, y: quickRow, width: w, height: row)
            bx += w + gap
        }
        projectButton.frame = CGRect(x: left, y: project, width: width - gap - row, height: row)
        for item in starts {
            item.button.target = self
            item.button.action = #selector(startClicked(_:))
            item.button.setAccessibilityIdentifier("cornermark.record.start.\(item.style.rawValue)")
            let key = Self.keyName(item.style)
            let outcome = Self.outcome(item.style)
            item.button.toolTip = tr("{outcome} ({key})", ["outcome": outcome, "key": key])
            item.button.setAccessibilityLabel(tr("{title}, {key}", ["title": item.button.title, "key": key]))
            item.button.setAccessibilityHelp(tr("{outcome}.", ["outcome": outcome]))
            addSubview(item.button)
        }
        let line = Separator(axis: .horizontal)
        line.frame = CGRect(x: left, y: rule, width: width, height: 1)
        addSubview(line)
        help.frame.origin = CGPoint(x: left + width - row, y: project)
        help.target = self
        help.action = #selector(helpClicked)
        help.setAccessibilityIdentifier("cornermark.record.help")
        help.setAccessibilityHelp(tr("Opens a short explanation of project recordings."))
        addSubview(help)

        var sx = left
        for item in sources {
            item.button.frame.origin = CGPoint(x: sx, y: middle)
            // Both states keep the tile, so off reads as the same control: plain with a slashed glyph, and on a step lighter,
            // bordered, with the filled glyph and the check.
            item.button.selection = .tile
            item.button.marksSelection = true
            item.button.markBackdrop = DS.Color.bgHud.withAlphaComponent(1)
            item.button.target = self
            item.button.action = #selector(sourceClicked(_:))
            item.button.setAccessibilityIdentifier("cornermark.record.source.\(item.source.rawValue)")
            item.button.setAccessibilityRole(.checkBox)
            item.button.setAccessibilityHelp(Self.look(item.source).help)
            addSubview(item.button)
            sx += DS.Size.control + Self.sourceGap
        }
        let noteX = sx - Self.sourceGap + DS.Space.s12
        note.frame = CGRect(x: noteX, y: middle, width: left + width - noteX, height: DS.Size.control)
        note.maximumNumberOfLines = 2
        note.lineBreakMode = .byWordWrapping
        note.cell?.wraps = true
        note.cell?.truncatesLastVisibleLine = true
        note.setAccessibilityIdentifier("cornermark.record.sources.note")
        addSubview(note)
        show(RecordingSources())

        setFrameSize(NSSize(width: left + width + pad + Self.inset, height: top + row + pad + Self.inset))
        leftToRight.record(in: self)
        applyLanguageDirection()
        leftToRight.apply(to: self)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The controls were placed left to right. A right-to-left panel writes the same frames mirrored.
    override var userInterfaceLayoutDirection: NSUserInterfaceLayoutDirection {
        didSet { leftToRight.apply(to: self) }
    }

    override var isFlipped: Bool { false }

    /// It sits over the very content being filmed, so like the loupe it must not let that content show through.
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath.continuous(contentRect, radius: DS.Radius.lg)
        DS.Elevation.hud.draw(path, fill: DS.Color.bgHud.withAlphaComponent(1))
        let rim = NSBezierPath.continuous(contentRect.insetBy(dx: 0.5, dy: 0.5), radius: DS.Radius.lg - 0.5)
        rim.lineWidth = 1
        DS.Color.border.setStroke()
        rim.stroke()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {}
    override func mouseDragged(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {}

    /// The visible panel, inside the transparent margin that holds its shadow.
    var pillRect: CGRect { contentRect }

    /// The toggles follow what the next recording takes. The note is set to its text's height and centred on the toggles.
    func show(_ state: RecordingSources) {
        for item in sources {
            let on = state.on.contains(item.source)
            let waiting = state.pending.contains(item.source)
            let look = Self.look(item.source)
            item.button.isSelected = on
            item.button.isEnabled = !waiting
            item.button.symbol = on ? look.on : look.off
            item.button.slashesGlyph = !on && !look.off.contains("slash")
            item.button.toolTip = waiting ? tr("{action} (waiting for permission)", ["action": look.action])
                : on ? tr("{action} (on)", ["action": look.action]) : tr("{action} (off)", ["action": look.action])
            item.button.setAccessibilityValue(on ? 1 : 0)
            item.button.setAccessibilityHelp(waiting ? tr("Waiting for permission. {help}", ["help": look.help]) : look.help)
        }
        let text = state.note?.text ?? ""
        guard note.stringValue != text || note.isHidden != text.isEmpty else { return }
        note.stringValue = text
        note.isHidden = text.isEmpty
        switch state.note {
        case .blocked, .waiting: note.textColor = DS.Color.textPrimary
        default: note.textColor = DS.Color.textSecondary
        }
        let row = sources[0].button.frame
        let fit = note.cell?.cellSize(forBounds: CGRect(x: 0, y: 0, width: note.frame.width, height: .greatestFiniteMagnitude)).height ?? 0
        let height = min(fit.rounded(.up), row.height)
        note.frame = CGRect(x: note.frame.minX, y: row.midY - height / 2, width: note.frame.width, height: height)
        leftToRight.record(note, in: self)
        if !text.isEmpty { NSAccessibility.post(element: note, notification: .announcementRequested, userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue]) }
    }

    func update(_ machine: SelectionMachine) {
        let mode = machine.recordingMode
        for item in targets { item.button.isSelected = item.mode == mode }
        if let idx = AspectLock.presets.firstIndex(of: machine.config.aspect), aspect.indexOfSelectedItem != idx { aspect.selectItem(at: idx) }

        var size: CGSize?
        var editable = false
        var ready = false
        switch machine.state {
        case .adjusting(let sel, let gesture):
            size = sel.rect.size
            editable = true
            ready = gesture == nil
        case .windowPicked(let w):
            size = w.frame.size
            ready = true
        default: break
        }
        for f in [widthField, heightField] { f.isEnabled = editable }
        aspect.isEnabled = mode != .window
        for item in starts { item.button.isEnabled = ready }
        if let size {
            if widthField.currentEditor() == nil { widthField.stringValue = Readout.number(Int(size.width.rounded())) }
            if heightField.currentEditor() == nil { heightField.stringValue = Readout.number(Int(size.height.rounded())) }
        } else {
            widthField.stringValue = ""; heightField.stringValue = ""
        }
    }

    /// The options menu's items follow `options`. It is also the button's context menu, so a right click opens it too.
    func show(_ options: RecordingQuickOptions) {
        guard options != self.options else { return }
        self.options = options
        optionsButton.menu = Self.menu(for: options, target: self)
    }

    private final class OptionItem: NSMenuItem {
        var change: (inout RecordingQuickOptions) -> Void = { _ in }
    }

    /// Pickers under headings, then the switches, so every choice is one click from the open menu.
    private static func menu(for o: RecordingQuickOptions, target: RecordingPanel) -> NSMenu {
        let menu = NSMenu(title: tr("Recording options"))
        menu.autoenablesItems = false
        func item(_ title: String, on: Bool, id: String, _ change: @escaping (inout RecordingQuickOptions) -> Void) {
            let i = OptionItem(title: title, action: #selector(optionPicked(_:)), keyEquivalent: "")
            i.target = target
            i.state = on ? .on : .off
            i.change = change
            i.identifier = NSUserInterfaceItemIdentifier("cornermark.record.option.\(id)")
            menu.addItem(i)
        }
        menu.addItem(.sectionHeader(title: tr("Quality")))
        for q in VideoQuality.allCases { item(q.title, on: o.quality == q, id: "quality.\(q.rawValue)") { $0.quality = q } }
        menu.addItem(.sectionHeader(title: tr("Frame Rate")))
        for f in RecordingQuickOptions.fpsChoices { item(tr("{fps} fps", ["fps": f]), on: o.fps == f, id: "fps.\(f)") { $0.fps = f } }
        menu.addItem(.sectionHeader(title: tr("Countdown")))
        for c in RecordingQuickOptions.countdownChoices {
            item(c == 0 ? tr("Off") : trPlural(one: "{count} second", other: "{count} seconds", count: c), on: o.countdown == c, id: "countdown.\(c)") { $0.countdown = c }
        }
        menu.addItem(.separator())
        item(tr("Show Cursor"), on: o.showCursor, id: "cursor") { $0.showCursor.toggle() }
        item(tr("Dim Outside the Area"), on: o.dimOutside, id: "dim") { $0.dimOutside.toggle() }
        item(tr("Keep Notifications Out of the Video"), on: o.hideNotifications, id: "notifications") { $0.hideNotifications.toggle() }
        item(tr("Keep Desktop Icons Out of the Video"), on: o.hideDesktopIcons, id: "desktopIcons") { $0.hideDesktopIcons.toggle() }
        return menu
    }

    @objc private func optionPicked(_ sender: NSMenuItem) {
        guard var next = options, let item = sender as? OptionItem else { return }
        item.change(&next)
        onOptions?(next)
    }

    /// Opens under the button. An overlay that was never ordered in, as in a test, does not run the menu's modal loop.
    @objc private func optionsClicked() {
        guard let menu = optionsButton.menu, window?.isVisible == true else { return }
        let x = optionsButton.isRightToLeft ? optionsButton.bounds.width - menu.size.width : 0
        menu.popUp(positioning: nil, at: CGPoint(x: x, y: isFlipped ? optionsButton.frame.height + DS.Space.s4 : -DS.Space.s4), in: optionsButton)
    }

    @objc private func helpClicked() { onHelp?() }

    @objc private func targetClicked(_ sender: IconButton) {
        if let item = targets.first(where: { $0.button === sender }) { onAction?(.mode(item.mode)) }
    }

    @objc private func sourceClicked(_ sender: IconButton) {
        if let item = sources.first(where: { $0.button === sender }) { onToggle?(item.source) }
    }

    @objc private func startClicked(_ sender: Button) {
        if let item = starts.first(where: { $0.button === sender }) { onAction?(.record(item.style)) }
    }

    @objc private func aspectChanged() {
        let i = aspect.indexOfSelectedItem
        guard AspectLock.presets.indices.contains(i) else { return }
        onAction?(.aspect(AspectLock.presets[i]))
    }

    @objc private func widthChanged() { sizeEdited(width: Readout.parse(widthField.stringValue), height: nil) }
    @objc private func heightChanged() { sizeEdited(width: nil, height: Readout.parse(heightField.stringValue)) }

    private func sizeEdited(width: Double?, height: Double?) {
        window?.makeFirstResponder(nil)
        guard width != nil || height != nil else { return }
        onAction?(.size(width: width, height: height))
    }
}
