import AppKit
import KadrajDesign

/// The all-in-one toolbar. Mouse events stop here so clicking its background never starts a new
/// selection underneath it.
final class SelectionToolbar: Surface {
    var onAction: ((ToolbarAction) -> Void)?

    /// Holds the `hud` elevation's ambient shadow (blur 24 at y 8) with room to spare.
    private static let inset = DS.Space.s32
    private static let fieldWidth: CGFloat = 48
    private static let aspectWidth: CGFloat = 72

    private let modeButtons: [(mode: ToolbarMode, button: IconButton)]
    private let aspect = NSPopUpButton(frame: .zero, pullsDown: false)
    private let widthField = TextInput(placeholder: "W", monospaced: true, centered: true)
    private let heightField = TextInput(placeholder: "H", monospaced: true, centered: true)
    private let captureButton = Button(title: "Capture", variant: .primary, size: .large)

    init(frame frameRect: NSRect) {
        modeButtons = [
            (.area, IconButton(symbol: "rectangle.dashed", label: "Area", size: .large)),
            (.window, IconButton(symbol: "macwindow", label: "Window", size: .large)),
            (.fullscreen, IconButton(symbol: "display", label: "Fullscreen", size: .large)),
            (.scrolling, IconButton(symbol: "arrow.up.and.down.text.horizontal", label: "Scrolling", size: .large)),
            (.timer, IconButton(symbol: "timer", label: "Timer", size: .large)),
        ]
        super.init(style: .hud, shadowInset: Self.inset)

        let pad = DS.Space.s4
        let rowHeight = DS.Size.controlLarge
        let top = Self.inset + pad
        var x = Self.inset + pad

        func centred(_ height: CGFloat) -> CGFloat { top + (rowHeight - height) / 2 }
        func divider() {
            x += DS.Space.s8
            let line = Separator(axis: .vertical)
            let height = DS.Size.control - DS.Space.s8
            line.frame = CGRect(x: x, y: centred(height), width: 1, height: height)
            addSubview(line)
            x += 1 + DS.Space.s8
        }

        for (i, item) in modeButtons.enumerated() {
            item.button.frame.origin = CGPoint(x: x, y: top)
            item.button.target = self
            item.button.action = #selector(modeClicked(_:))
            item.button.setAccessibilityIdentifier("kadraj.toolbar.mode.\(item.mode)")
            addSubview(item.button)
            x += rowHeight + (i < modeButtons.count - 1 ? DS.Space.s4 : 0)
        }
        divider()

        for lock in AspectLock.presets { aspect.addItem(withTitle: lock.title) }
        aspect.controlSize = .small
        aspect.font = DS.Text.label.font
        aspect.isBordered = false
        aspect.toolTip = "Aspect ratio"
        aspect.setAccessibilityIdentifier("kadraj.toolbar.aspect")
        aspect.frame = CGRect(x: x, y: centred(DS.Size.control), width: Self.aspectWidth, height: DS.Size.control)
        aspect.target = self
        aspect.action = #selector(aspectChanged)
        addSubview(aspect)
        x += Self.aspectWidth
        divider()

        for (field, id, action) in [(widthField, "kadraj.toolbar.width", #selector(widthChanged)), (heightField, "kadraj.toolbar.height", #selector(heightChanged))] {
            field.frame = CGRect(x: x, y: centred(DS.Size.control), width: Self.fieldWidth, height: DS.Size.control)
            field.cell?.sendsActionOnEndEditing = true
            field.setAccessibilityIdentifier(id)
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

        captureButton.frame.origin = CGPoint(x: x, y: top)
        captureButton.target = self
        captureButton.action = #selector(captureClicked)
        captureButton.setAccessibilityIdentifier("kadraj.toolbar.capture")
        addSubview(captureButton)
        x += captureButton.frame.width + pad

        setFrameSize(NSSize(width: x + Self.inset, height: rowHeight + 2 * pad + 2 * Self.inset))
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {}
    override func mouseDragged(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {}

    /// The visible bar, inside the transparent margin that holds its shadow.
    var pillRect: CGRect { contentRect }

    func update(_ machine: SelectionMachine) {
        let selected: ToolbarMode
        if case .windowHover = machine.state { selected = .window } else {
            switch machine.config.intent {
            case .area: selected = .area
            case .scrolling: selected = .scrolling
            case .timer: selected = .timer
            }
        }
        for item in modeButtons { item.button.isSelected = item.mode == selected }

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

    @objc private func modeClicked(_ sender: IconButton) {
        if let item = modeButtons.first(where: { $0.button === sender }) { onAction?(.mode(item.mode)) }
    }

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
