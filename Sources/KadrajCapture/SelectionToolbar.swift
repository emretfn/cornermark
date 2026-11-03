import AppKit

private final class ModeButton: NSButton {
    let mode: ToolbarMode

    init(mode: ToolbarMode, symbol: String, tip: String) {
        self.mode = mode
        super.init(frame: NSRect(x: 0, y: 0, width: 32, height: 30))
        isBordered = false
        imagePosition = .imageOnly
        setButtonType(.momentaryChange)
        toolTip = tip
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .medium))
        contentTintColor = NSColor.white.withAlphaComponent(0.92)
        setAccessibilityIdentifier("kadraj.toolbar.mode.\(mode)")
        setAccessibilityLabel(tip)
    }

    required init?(coder: NSCoder) { fatalError() }

    var isSelected = false { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        if isSelected {
            NSColor.white.withAlphaComponent(0.2).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 7, yRadius: 7).fill()
        }
        super.draw(dirtyRect)
    }
}

/// Drawn by hand: stock bezels turn grey whenever the panel is not key, which a non-activating overlay often is.
final class PillButton: NSButton {
    var isProminent = true

    init(title: String, prominent: Bool) {
        super.init(frame: .zero)
        isProminent = prominent
        isBordered = false
        setButtonType(.momentaryPushIn)
        attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor.white,
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        var fill = isProminent ? NSColor.controlAccentColor : NSColor.white.withAlphaComponent(0.16)
        if !isEnabled { fill = NSColor.white.withAlphaComponent(0.08) }
        else if isHighlighted { fill = fill.blended(withFraction: 0.25, of: .black) ?? fill }
        fill.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7).fill()
        let t = attributedTitle
        let size = t.size()
        let alpha: CGFloat = isEnabled ? 1 : 0.4
        let shown = NSMutableAttributedString(attributedString: t)
        shown.addAttribute(.foregroundColor, value: NSColor.white.withAlphaComponent(alpha), range: NSRange(location: 0, length: shown.length))
        shown.draw(at: CGPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2))
    }
}

private final class SizeField: NSTextField {
    init(id: String, placeholder: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: 48, height: 24))
        isBordered = false
        isBezeled = false
        drawsBackground = false
        focusRingType = .none
        alignment = .center
        font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        textColor = .white
        placeholderString = placeholder
        usesSingleLineMode = true
        cell?.sendsActionOnEndEditing = true
        setAccessibilityIdentifier(id)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.withAlphaComponent(isEnabled ? 0.13 : 0.06).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        super.draw(dirtyRect)
    }
}

/// The all-in-one toolbar. Mouse events stop here so clicking its background never starts a new
/// selection underneath it.
final class SelectionToolbar: NSView {
    var onAction: ((ToolbarAction) -> Void)?

    private static let inset: CGFloat = 16
    private let modeButtons: [ModeButton]
    private let aspect = NSPopUpButton(frame: .zero, pullsDown: false)
    private let widthField = SizeField(id: "kadraj.toolbar.width", placeholder: "W")
    private let heightField = SizeField(id: "kadraj.toolbar.height", placeholder: "H")
    private let times = NSTextField(labelWithString: "×")
    private let captureButton = PillButton(title: "Capture", prominent: true)
    private var dividers: [CGFloat] = []

    override init(frame frameRect: NSRect) {
        modeButtons = [
            ModeButton(mode: .area, symbol: "rectangle.dashed", tip: "Area"),
            ModeButton(mode: .window, symbol: "macwindow", tip: "Window"),
            ModeButton(mode: .fullscreen, symbol: "display", tip: "Fullscreen"),
            ModeButton(mode: .scrolling, symbol: "arrow.up.and.down.text.horizontal", tip: "Scrolling"),
            ModeButton(mode: .timer, symbol: "timer", tip: "Timer"),
        ]
        super.init(frame: frameRect)
        appearance = NSAppearance(named: .darkAqua)

        var x = Self.inset + 8
        let y = Self.inset
        for b in modeButtons {
            b.frame.origin = CGPoint(x: x, y: y + 7)
            b.target = self; b.action = #selector(modeClicked(_:))
            addSubview(b)
            x += 34
        }
        x += 6; dividers.append(x); x += 8

        for lock in AspectLock.presets { aspect.addItem(withTitle: lock.title) }
        aspect.controlSize = .small
        aspect.font = .systemFont(ofSize: 12)
        aspect.isBordered = false
        aspect.toolTip = "Aspect ratio"
        aspect.setAccessibilityIdentifier("kadraj.toolbar.aspect")
        aspect.frame = CGRect(x: x, y: y + 9, width: 68, height: 26)
        aspect.target = self; aspect.action = #selector(aspectChanged)
        addSubview(aspect)
        x += 72; dividers.append(x); x += 8

        widthField.frame.origin = CGPoint(x: x, y: y + 10)
        times.frame = CGRect(x: x + 48, y: y + 11, width: 14, height: 20)
        times.alignment = .center
        times.textColor = NSColor.white.withAlphaComponent(0.5)
        times.font = .systemFont(ofSize: 12)
        heightField.frame.origin = CGPoint(x: x + 62, y: y + 10)
        widthField.target = self; widthField.action = #selector(widthChanged)
        heightField.target = self; heightField.action = #selector(heightChanged)
        addSubview(widthField)
        addSubview(heightField)
        addSubview(times)
        x += 110; dividers.append(x); x += 8

        captureButton.frame = CGRect(x: x, y: y + 8, width: 84, height: 28)
        captureButton.target = self; captureButton.action = #selector(captureClicked)
        captureButton.setAccessibilityIdentifier("kadraj.toolbar.capture")
        addSubview(captureButton)
        x += 84 + 8

        setFrameSize(NSSize(width: x + Self.inset, height: 44 + 2 * Self.inset))
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The shadow margin is transparent and must not swallow clicks meant for the selection beneath.
    override func hitTest(_ point: NSPoint) -> NSView? {
        pillRect.contains(convert(point, from: superview)) ? super.hitTest(point) : nil
    }

    override func mouseDown(with event: NSEvent) {}
    override func mouseDragged(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {}

    /// The visible pill, inside the transparent margin that holds its shadow.
    var pillRect: CGRect { bounds.insetBy(dx: Self.inset, dy: Self.inset) }

    override func draw(_ dirtyRect: NSRect) {
        let pill = NSBezierPath(roundedRect: pillRect, xRadius: 13, yRadius: 13)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.4)
        shadow.shadowBlurRadius = 14
        shadow.shadowOffset = NSSize(width: 0, height: -4)
        shadow.set()
        NSColor(white: 0.12, alpha: 0.95).setFill()
        pill.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSColor.white.withAlphaComponent(0.14).setStroke()
        pill.lineWidth = 1
        pill.stroke()
        NSColor.white.withAlphaComponent(0.14).setFill()
        for x in dividers { CGRect(x: x, y: pillRect.minY + 10, width: 1, height: pillRect.height - 20).fill() }
    }

    func update(_ machine: SelectionMachine) {
        let selected: ToolbarMode
        if case .windowHover = machine.state { selected = .window } else {
            switch machine.config.intent {
            case .area: selected = .area
            case .scrolling: selected = .scrolling
            case .timer: selected = .timer
            }
        }
        for b in modeButtons { b.isSelected = b.mode == selected }

        if let idx = AspectLock.presets.firstIndex(of: machine.config.aspect), aspect.indexOfSelectedItem != idx { aspect.selectItem(at: idx) }

        var rect: CGRect?
        if case .adjusting(let sel, _) = machine.state { rect = sel.rect }
        for f in [widthField, heightField] { f.isEnabled = rect != nil }
        captureButton.isEnabled = rect != nil
        if let rect {
            if widthField.currentEditor() == nil { widthField.stringValue = String(Int(rect.width.rounded())) }
            if heightField.currentEditor() == nil { heightField.stringValue = String(Int(rect.height.rounded())) }
        } else {
            widthField.stringValue = ""; heightField.stringValue = ""
        }
    }

    @objc private func modeClicked(_ sender: ModeButton) { onAction?(.mode(sender.mode)) }

    @objc private func aspectChanged() {
        let i = aspect.indexOfSelectedItem
        guard AspectLock.presets.indices.contains(i) else { return }
        onAction?(.aspect(AspectLock.presets[i]))
    }

    @objc private func widthChanged() { sizeEdited(width: Double(widthField.stringValue.trimmingCharacters(in: .whitespaces)), height: nil) }
    @objc private func heightChanged() { sizeEdited(width: nil, height: Double(heightField.stringValue.trimmingCharacters(in: .whitespaces))) }

    private func sizeEdited(width: Double?, height: Double?) {
        window?.makeFirstResponder(nil)
        guard width != nil || height != nil else { return }
        onAction?(.size(width: width, height: height))
    }

    @objc private func captureClicked() { onAction?(.capture) }
}
