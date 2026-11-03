import AppKit

public final class Button: Pressable {
    public enum Variant: CaseIterable { case primary, secondary, ghost, danger }

    public let variant: Variant
    public let size: ComponentSize
    public let symbol: String?

    public init(title: String, variant: Variant = .secondary, size: ComponentSize = .regular, symbol: String? = nil) {
        self.variant = variant
        self.size = size
        self.symbol = symbol
        super.init(frame: .zero)
        self.title = title
        setAccessibilityLabel(title)
        frame.size = intrinsicContentSize
    }

    public required init?(coder: NSCoder) { fatalError("Button is created in code") }

    public override var title: String {
        didSet {
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    private var textStyle: TextStyle { size == .small ? DS.Text.label : DS.Text.bodyStrong }
    private var padding: CGFloat { size == .small ? DS.Space.s12 : DS.Space.s16 }
    private var leadingPadding: CGFloat { symbol == nil ? padding : padding - 2 }
    private var iconGap: CGFloat { size == .small ? DS.Space.s4 : DS.Space.s6 }
    private var contentWidth: CGFloat { Paint.width(of: title, textStyle) + (symbol == nil ? 0 : size.iconSize + iconGap) }

    public override var intrinsicContentSize: NSSize {
        NSSize(width: leadingPadding + contentWidth + padding, height: size.height)
    }

    override func shape(in rect: CGRect) -> NSBezierPath { .continuous(rect, radius: size == .small ? DS.Radius.sm : DS.Radius.md) }

    override func paint(_ state: InteractionState) {
        let look = variant.appearance(state)
        let path = shape(in: bounds)
        if let fill = look.fill { Paint.fill(path, fill) }
        if let border = look.border { Paint.strokeInside(path, border) }

        // The content block sits at its leading padding when the button is intrinsic-width and centres when it is wider.
        var x = leadingPadding + (bounds.width - intrinsicContentSize.width) / 2
        if let symbol {
            Paint.symbol(symbol, in: CGRect(x: x, y: 0, width: size.iconSize, height: bounds.height), pointSize: size.iconSize, look.text)
            x += size.iconSize + iconGap
        }
        Paint.text(title, textStyle, look.text, in: CGRect(x: x, y: 0, width: Paint.width(of: title, textStyle), height: bounds.height))
    }
}

extension Button.Variant {
    func appearance(_ state: InteractionState) -> ButtonAppearance {
        let c = DS.Color.self
        switch (self, state) {
        case (.primary, .normal): return ButtonAppearance(fill: c.accentSolid, text: c.onAccent)
        case (.primary, .hover), (.primary, .pressed): return ButtonAppearance(fill: c.accentSolidHover, text: c.onAccent)
        case (.secondary, .normal): return ButtonAppearance(fill: c.bgControl, text: c.textPrimary)
        case (.secondary, .hover): return ButtonAppearance(fill: c.bgControlHover, text: c.textPrimary)
        case (.secondary, .pressed): return ButtonAppearance(fill: c.bgControlActive, text: c.textPrimary)
        case (.ghost, .normal): return ButtonAppearance(fill: nil, text: c.textSecondary)
        case (.ghost, .hover): return ButtonAppearance(fill: c.bgControlHover, text: c.textPrimary)
        case (.ghost, .pressed): return ButtonAppearance(fill: c.bgControlActive, text: c.textPrimary)
        case (.danger, .normal), (.danger, .hover), (.danger, .pressed): return ButtonAppearance(fill: c.dangerSolid, text: c.onDanger)
        case (.ghost, .disabled): return ButtonAppearance(fill: nil, text: c.textDisabled)
        case (_, .disabled): return ButtonAppearance(fill: c.bgControl, text: c.textDisabled)
        }
    }
}
