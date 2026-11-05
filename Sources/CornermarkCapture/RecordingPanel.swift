import AppKit
import CornermarkDesign

/// The panel of a recording overlay: what to film, its size, and the buttons that start it. It sits in the middle of the
/// selection. Mouse events stop here so clicking its background never starts a new selection underneath it.
final class RecordingPanel: Surface {
    var onAction: ((ToolbarAction) -> Void)?

    /// Holds the `hud` elevation's ambient shadow (blur 24 at y 8) with room to spare.
    private static let inset = DS.Space.s32
    private static let fieldWidth: CGFloat = 52
    private static let aspectWidth: CGFloat = 72
    private static let keyNames: [RecordingStyle: String] = [.video: "Return", .editing: "Shift-Return", .gif: "Option-Return"]

    private let targets: [(mode: ToolbarMode, button: IconButton)]
    private let aspect = NSPopUpButton(frame: .zero, pullsDown: false)
    private let widthField = TextInput(placeholder: "W", monospaced: true, centered: true)
    private let heightField = TextInput(placeholder: "H", monospaced: true, centered: true)
    private let starts: [(style: RecordingStyle, button: Button)]

    init() {
        targets = [
            (.area, IconButton(symbol: "rectangle.dashed", label: "Area", size: .large)),
            (.window, IconButton(symbol: "macwindow", label: "Window", size: .large)),
            (.fullscreen, IconButton(symbol: "display", label: "Fullscreen", size: .large)),
        ]
        starts = [
            (.video, Button(title: "Record Video", variant: .primary, size: .large, symbol: "record.circle", shortcut: "\u{21A9}")),
            (.editing, Button(title: "Record for Editing", variant: .secondary, size: .large, shortcut: "\u{21E7}\u{21A9}")),
            (.gif, Button(title: "Record GIF", variant: .secondary, size: .large, shortcut: "\u{2325}\u{21A9}")),
        ]
        super.init(style: .hud, shadowInset: Self.inset)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Recording")

        let pad = DS.Space.s4
        let row = DS.Size.controlLarge
        let left = Self.inset + pad

        // The top row, laid out first to learn the panel's width.
        var x = left
        let top = Self.inset + pad + row + 2 * pad
        func centred(_ height: CGFloat) -> CGFloat { top + (row - height) / 2 }
        func divider() {
            x += DS.Space.s8
            let line = Separator(axis: .vertical)
            let height = DS.Size.control - DS.Space.s8
            line.frame = CGRect(x: x, y: centred(height), width: 1, height: height)
            addSubview(line)
            x += 1 + DS.Space.s8
        }

        for (i, item) in targets.enumerated() {
            item.button.frame.origin = CGPoint(x: x, y: top)
            item.button.target = self
            item.button.action = #selector(targetClicked(_:))
            item.button.setAccessibilityIdentifier("cornermark.record.target.\(item.mode)")
            addSubview(item.button)
            x += row + (i < targets.count - 1 ? DS.Space.s4 : 0)
        }
        divider()

        for (field, id, label, action) in [(widthField, "cornermark.record.width", "Width", #selector(widthChanged)),
                                           (heightField, "cornermark.record.height", "Height", #selector(heightChanged))] {
            field.frame = CGRect(x: x, y: centred(DS.Size.control), width: Self.fieldWidth, height: DS.Size.control)
            field.cell?.sendsActionOnEndEditing = true
            field.setAccessibilityIdentifier(id)
            field.setAccessibilityLabel(label)
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
        aspect.controlSize = .small
        aspect.font = DS.Text.label.font
        aspect.isBordered = false
        aspect.toolTip = "Aspect ratio"
        aspect.setAccessibilityLabel("Aspect ratio")
        aspect.setAccessibilityIdentifier("cornermark.record.aspect")
        aspect.frame = CGRect(x: x, y: centred(DS.Size.control), width: Self.aspectWidth, height: DS.Size.control)
        aspect.target = self
        aspect.action = #selector(aspectChanged)
        addSubview(aspect)
        x += Self.aspectWidth

        let inner = x - left

        // The bottom row shares the width between the start buttons, the one primary action first. Each keeps its title's width, so the
        // panel stays narrow enough to sit inside a modest selection.
        let gap = DS.Space.s4
        let natural = starts.map(\.button.frame.width).reduce(0, +) + gap * CGFloat(starts.count - 1)
        let width = max(inner, natural)
        var bx = left
        for (i, item) in starts.enumerated() {
            let share = (item.button.frame.width + (width - natural) / CGFloat(starts.count)).rounded()
            item.button.frame = CGRect(x: bx, y: Self.inset + pad, width: share, height: row)
            item.button.target = self
            item.button.action = #selector(startClicked(_:))
            item.button.setAccessibilityIdentifier("cornermark.record.start.\(item.style.rawValue)")
            let key = Self.keyNames[item.style] ?? "Return"
            item.button.toolTip = "\(item.button.title) (\(key))"
            item.button.setAccessibilityLabel("\(item.button.title), \(key)")
            addSubview(item.button)
            bx += share + (i < starts.count - 1 ? gap : 0)
        }

        setFrameSize(NSSize(width: max(x, bx) + pad + Self.inset, height: top + row + pad + Self.inset))
    }

    required init?(coder: NSCoder) { fatalError() }

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
            if widthField.currentEditor() == nil { widthField.stringValue = String(Int(size.width.rounded())) }
            if heightField.currentEditor() == nil { heightField.stringValue = String(Int(size.height.rounded())) }
        } else {
            widthField.stringValue = ""; heightField.stringValue = ""
        }
    }

    @objc private func targetClicked(_ sender: IconButton) {
        if let item = targets.first(where: { $0.button === sender }) { onAction?(.mode(item.mode)) }
    }

    @objc private func startClicked(_ sender: Button) {
        if let item = starts.first(where: { $0.button === sender }) { onAction?(.record(item.style)) }
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
}
