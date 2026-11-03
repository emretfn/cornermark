import AppKit

/// A switch-type NSButton: `state` holds the value and `performClick` toggles it. The box is drawn from the same
/// `InteractionState` table as the other controls.
public final class Checkbox: Pressable {
    public let size: ComponentSize

    public init(title: String, size: ComponentSize = .regular) {
        self.size = size
        super.init(frame: .zero)
        setButtonType(.switch)
        setAccessibilityRole(.checkBox)
        self.title = title
        setAccessibilityLabel(title)
        frame.size = intrinsicContentSize
    }

    public required init?(coder: NSCoder) { fatalError("Checkbox is created in code") }

    public override var title: String {
        didSet {
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    public override var state: NSControl.StateValue {
        didSet { needsDisplay = true }
    }

    private static let boxSide = DS.Size.icon
    private static let markSize = DS.Size.iconSmall - 2
    private static let style = DS.Text.label

    public override var intrinsicContentSize: NSSize {
        NSSize(width: title.isEmpty ? Self.boxSide : Self.boxSide + DS.Space.s8 + Paint.width(of: title, Self.style), height: size.height)
    }

    private var box: CGRect {
        CGRect(x: 0, y: (bounds.height - Self.boxSide) / 2, width: Self.boxSide, height: Self.boxSide)
    }

    override func shape(in rect: CGRect) -> NSBezierPath { .continuous(box, radius: DS.Radius.xs) }

    override func paint(_ state: InteractionState) {
        let look = Self.look(on: self.state == .on, state)
        let path = shape(in: bounds)
        if let fill = look.fill { Paint.fill(path, fill) }
        Paint.strokeInside(path, look.border)
        if self.state == .on { Paint.symbol("checkmark", in: box, pointSize: Self.markSize, look.mark) }
        let textX = Self.boxSide + DS.Space.s8
        Paint.text(title, Self.style, look.text, in: CGRect(x: textX, y: 0, width: bounds.width - textX, height: bounds.height))
    }

    struct Look {
        var fill: NSColor?
        var border: NSColor
        var mark: NSColor
        var text: NSColor
    }

    static func look(on: Bool, _ state: InteractionState) -> Look {
        let c = DS.Color.self
        switch (on, state) {
        case (true, .disabled): return Look(fill: c.bgControlActive, border: c.border, mark: c.textDisabled, text: c.textDisabled)
        case (false, .disabled): return Look(fill: nil, border: c.border, mark: c.textDisabled, text: c.textDisabled)
        case (true, .hover), (true, .pressed): return Look(fill: c.accentSolidHover, border: c.accentMark, mark: c.onAccent, text: c.textPrimary)
        case (true, .normal): return Look(fill: c.accentSolid, border: c.accentMark, mark: c.onAccent, text: c.textPrimary)
        case (false, .normal): return Look(fill: nil, border: c.borderStrong, mark: c.onAccent, text: c.textPrimary)
        case (false, .hover): return Look(fill: c.bgControlHover, border: c.borderStrong, mark: c.onAccent, text: c.textPrimary)
        case (false, .pressed): return Look(fill: c.bgControlActive, border: c.borderStrong, mark: c.onAccent, text: c.textPrimary)
        }
    }
}
