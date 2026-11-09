import AppKit

/// A picker for one of nine places in a picture: a small well shaped like the frame, holding a 3×3 grid of cells. Each cell is a
/// radio-button `NSButton`, so a click, Space on the focused cell, `performClick` and VoiceOver all pick it the same way.
/// The picked cell shows a block where the thing will sit, in the selection colours `Segments` uses. The grid is a picture of the frame,
/// so its first cell is the top left of the picture in every language.
public final class PositionGrid: NSView, KeepsLeftToRight {
    public static let cellSize = CGSize(width: 28, height: 20)
    public static let gap = DS.Space.s4
    public static let inset = DS.Space.s4

    public var onPick: (Int) -> Void = { _ in }
    public private(set) var cells: [Cell] = []

    public var selectedIndex = 0 {
        didSet { for (i, cell) in cells.enumerated() { cell.state = i == selectedIndex ? .on : .off } }
    }

    public var isEnabled = true {
        didSet {
            cells.forEach { $0.isEnabled = isEnabled }
            needsDisplay = true
        }
    }

    /// `labels` name the nine cells row by row from the top left. Each cell's identifier is `identifier` and its index.
    public init(labels: [String], identifier: String) {
        precondition(labels.count == 9, "one label per cell")
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.radioGroup)
        setAccessibilityIdentifier(identifier)
        for (i, label) in labels.enumerated() {
            let cell = Cell(label: label)
            cell.setAccessibilityIdentifier("\(identifier).\(i)")
            cell.target = self
            cell.action = #selector(picked(_:))
            cell.tag = i
            cell.frame = Self.frame(ofCell: i)
            cells.append(cell)
            addSubview(cell)
        }
        selectedIndex = 0
    }

    public required init?(coder: NSCoder) { fatalError("PositionGrid is created in code") }

    public override var isFlipped: Bool { true }

    public override var intrinsicContentSize: NSSize {
        NSSize(width: 3 * Self.cellSize.width + 2 * Self.gap + 2 * Self.inset, height: 3 * Self.cellSize.height + 2 * Self.gap + 2 * Self.inset)
    }

    static func frame(ofCell i: Int) -> CGRect {
        CGRect(x: inset + CGFloat(i % 3) * (cellSize.width + gap), y: inset + CGFloat(i / 3) * (cellSize.height + gap),
               width: cellSize.width, height: cellSize.height)
    }

    public override func draw(_ dirtyRect: NSRect) {
        let well = NSBezierPath.continuous(bounds, radius: DS.Radius.concentric(inner: DS.Radius.xs, padding: Self.inset))
        Paint.fill(well, DS.Color.bgSunken)
        Paint.strokeInside(well, isEnabled ? DS.Color.border : DS.Color.borderSubtle)
    }

    @objc private func picked(_ sender: Cell) {
        selectedIndex = sender.tag
        onPick(sender.tag)
    }

    /// One place in the grid. At rest it shows a dot, so every place reads as a target before it is hovered.
    public final class Cell: Pressable {
        init(label: String) {
            super.init(frame: .zero)
            setButtonType(.onOff)
            setAccessibilityRole(.radioButton)
            setAccessibilityLabel(label)
            toolTip = label
            title = ""
        }

        required init?(coder: NSCoder) { fatalError("PositionGrid.Cell is created in code") }

        public override var state: NSControl.StateValue { didSet { needsDisplay = true } }

        override func shape(in rect: CGRect) -> NSBezierPath { .continuous(rect, radius: DS.Radius.xs) }

        override func paint(_ interaction: InteractionState) {
            let c = DS.Color.self
            let path = shape(in: bounds)
            let on = state == .on
            switch (on, interaction) {
            case (true, .disabled):
                Paint.fill(path, c.bgControl)
            case (true, _):
                Paint.fill(path, c.accentSubtle)
                Paint.strokeInside(path, c.accentBorder)
            case (false, .hover):
                Paint.fill(path, c.bgControlHover)
            case (false, .pressed):
                Paint.fill(path, c.bgControlActive)
            default:
                break
            }
            if on {
                let block = bounds.insetBy(dx: bounds.width * 0.25, dy: bounds.height * 0.25)
                Paint.fill(.continuous(block, radius: DS.Radius.xs / 2), interaction == .disabled ? c.textDisabled : c.accentMark)
            } else {
                let dot = CGRect(x: bounds.midX - 1.5, y: bounds.midY - 1.5, width: 3, height: 3)
                Paint.fill(NSBezierPath(ovalIn: dot), interaction == .disabled ? c.textDisabled : c.textSecondary)
            }
        }

        public override func accessibilityValue() -> Any? { state == .on ? 1 : 0 }
    }
}
