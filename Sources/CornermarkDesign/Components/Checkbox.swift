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

    private static let boxSide = DS.Size.iconLarge
    private static let style = DS.Text.label

    public override var intrinsicContentSize: NSSize {
        NSSize(width: title.isEmpty ? Self.boxSide : Self.boxSide + DS.Space.s8 + Paint.width(of: title, Self.style), height: size.height)
    }

    /// The box leads the label, so it sits at the left edge, or the right edge in a right-to-left language.
    var box: CGRect {
        mirrored(CGRect(x: 0, y: (bounds.height - Self.boxSide) / 2, width: Self.boxSide, height: Self.boxSide))
    }

    var labelRect: CGRect {
        let textX = Self.boxSide + DS.Space.s8
        return mirrored(CGRect(x: textX, y: 0, width: bounds.width - textX, height: bounds.height))
    }

    override func shape(in rect: CGRect) -> NSBezierPath { .continuous(box, radius: DS.Radius.xs) }

    override func paint(_ state: InteractionState) {
        let look = Self.look(on: self.state == .on, state)
        let path = shape(in: bounds)
        if let fill = look.fill { Paint.fill(path, fill) }
        if let border = look.border { Paint.strokeInside(path, border) }
        if self.state == .on { drawMark(look.mark) }
        Paint.text(title, Self.style, look.text, in: labelRect, rtl: isRightToLeft)
    }

    /// Drawn as a path because the SF Symbol's own weight and corners look heavy and uneven at this size.
    private func drawMark(_ color: NSColor) {
        let side = box.width
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: box.minX + side * x, y: isFlipped ? box.maxY - side * y : box.minY + side * y)
        }
        let mark = NSBezierPath()
        mark.move(to: point(0.24, 0.52))
        mark.line(to: point(0.43, 0.32))
        mark.line(to: point(0.76, 0.70))
        mark.lineWidth = 2
        mark.lineCapStyle = .round
        mark.lineJoinStyle = .round
        color.setStroke()
        mark.stroke()
    }

    struct Look {
        var fill: NSColor?
        var border: NSColor?
        var mark: NSColor
        var text: NSColor
    }

    static func look(on: Bool, _ state: InteractionState) -> Look {
        let c = DS.Color.self
        switch (on, state) {
        case (true, .disabled): return Look(fill: c.bgControlActive, border: nil, mark: c.textDisabled, text: c.textDisabled)
        case (false, .disabled): return Look(fill: nil, border: c.border, mark: c.textDisabled, text: c.textDisabled)
        case (true, .hover), (true, .pressed): return Look(fill: c.bgInverseHover, border: nil, mark: c.onInverse, text: c.textPrimary)
        case (true, .normal): return Look(fill: c.bgInverse, border: nil, mark: c.onInverse, text: c.textPrimary)
        case (false, .normal): return Look(fill: c.bgControl, border: c.borderStrong, mark: c.onInverse, text: c.textPrimary)
        case (false, .hover): return Look(fill: c.bgControlHover, border: c.borderStrong, mark: c.onInverse, text: c.textPrimary)
        case (false, .pressed): return Look(fill: c.bgControlActive, border: c.borderStrong, mark: c.onInverse, text: c.textPrimary)
        }
    }
}
