import AppKit
import ObjectiveC

private final class ClosureTarget: NSObject {
    let fn: (NSControl) -> Void
    init(_ fn: @escaping (NSControl) -> Void) { self.fn = fn }
    @objc func fire(_ sender: NSControl) { fn(sender) }
}

private nonisolated(unsafe) var targetKey: UInt8 = 0

extension NSControl {
    func onAction(_ fn: @escaping (NSControl) -> Void) {
        let t = ClosureTarget(fn)
        target = t
        action = #selector(ClosureTarget.fire(_:))
        objc_setAssociatedObject(self, &targetKey, t, .OBJC_ASSOCIATION_RETAIN)
    }
}

/// Click, then press the new shortcut. Escape cancels, Delete switches the shortcut off.
final class ShortcutRecorderView: NSView {
    var hotKey: HotKey? { didSet { needsDisplay = true } }
    var onChange: (HotKey?) -> Void = { _ in }
    private(set) var isRecording = false { didSet { needsDisplay = true } }

    override var acceptsFirstResponder: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 150, height: 24) }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        isRecording = true
    }

    override func resignFirstResponder() -> Bool {
        isRecording = false
        return super.resignFirstResponder()
    }

    func beginRecording() { isRecording = true }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording else { return false }
        keyDown(with: event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else { return super.keyDown(with: event) }
        switch event.keyCode {
        case 53:
            isRecording = false
        case 51, 117:
            isRecording = false
            onChange(nil)
        default:
            guard let key = HotKey(event: event) else { return NSSound.beep() }
            isRecording = false
            onChange(key)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6)
        (isRecording ? NSColor.controlAccentColor.withAlphaComponent(0.12) : NSColor.controlBackgroundColor).setFill()
        path.fill()
        (isRecording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.lineWidth = isRecording ? 2 : 1
        path.stroke()
        let text: String, color: NSColor
        if isRecording { text = "Type shortcut\u{2026}"; color = .secondaryLabelColor }
        else if let hotKey { text = hotKey.displayString; color = .labelColor }
        else { text = "Not set"; color = .tertiaryLabelColor }
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: color]
        let size = (text as NSString).size(withAttributes: attrs)
        (text as NSString).draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2), withAttributes: attrs)
    }
}

enum Form {
    /// Labels right-aligned in the first column, controls left-aligned in the second.
    static func grid(_ rows: [(String?, NSView)], width: CGFloat = 560) -> NSView {
        let grid = NSGridView(views: rows.map { label, control in
            let l = NSTextField(labelWithString: label.map { $0 + ":" } ?? "")
            l.alignment = .right
            return [l, control]
        })
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .leading
        grid.rowSpacing = 12
        grid.columnSpacing = 12
        grid.translatesAutoresizingMaskIntoConstraints = false
        let root = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 100))
        root.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: root.topAnchor, constant: 24),
            grid.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            grid.leadingAnchor.constraint(greaterThanOrEqualTo: root.leadingAnchor, constant: 20),
            grid.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -24),
        ])
        root.layoutSubtreeIfNeeded()
        root.setFrameSize(NSSize(width: width, height: root.fittingSize.height))
        return root
    }

    static func stack(_ views: [NSView], spacing: CGFloat = 6) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = .vertical
        s.alignment = .leading
        s.spacing = spacing
        return s
    }

    static func caption(_ text: String, width: CGFloat = 340) -> NSTextField {
        let t = NSTextField(wrappingLabelWithString: text)
        t.font = .systemFont(ofSize: 11)
        t.textColor = .secondaryLabelColor
        t.preferredMaxLayoutWidth = width
        return t
    }

    static func checkbox(_ title: String, id: String) -> NSButton {
        let b = NSButton(checkboxWithTitle: title, target: nil, action: nil)
        b.setAccessibilityIdentifier(id)
        return b
    }

    static func popup(_ titles: [String], id: String) -> NSPopUpButton {
        let p = NSPopUpButton(frame: .zero, pullsDown: false)
        p.addItems(withTitles: titles)
        p.setAccessibilityIdentifier(id)
        return p
    }

    static func stepper(range: ClosedRange<Int>, id: String, suffix: String) -> (view: NSView, stepper: NSStepper, label: NSTextField) {
        let st = NSStepper()
        st.minValue = Double(range.lowerBound); st.maxValue = Double(range.upperBound); st.increment = 1
        st.valueWraps = false
        st.setAccessibilityIdentifier(id)
        let label = NSTextField(labelWithString: "")
        label.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        label.setAccessibilityIdentifier(id + ".value")
        let row = NSStackView(views: [label, st])
        row.spacing = 6
        return (row, st, label)
    }
}
