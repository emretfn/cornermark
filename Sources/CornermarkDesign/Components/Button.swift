import AppKit

public final class Button: Pressable {
    public enum Variant: CaseIterable { case primary, secondary, ghost, dangerGhost, danger }

    public var variant: Variant {
        didSet { if variant != oldValue { needsDisplay = true } }
    }
    public let size: ComponentSize
    public let symbol: String?
    /// The key that does the same thing, drawn after the title, such as "\u{21A9}".
    public let shortcut: String?

    public init(title: String, variant: Variant = .secondary, size: ComponentSize = .regular, symbol: String? = nil, shortcut: String? = nil) {
        self.variant = variant
        self.size = size
        self.symbol = symbol
        self.shortcut = shortcut
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
    private var shortcutGap: CGFloat { DS.Space.s8 }
    private var shortcutWidth: CGFloat { shortcut.map { shortcutGap + Paint.width(of: $0, DS.Text.readout) } ?? 0 }
    private var contentWidth: CGFloat { Paint.width(of: title, textStyle) + (symbol == nil ? 0 : size.iconSize + iconGap) + shortcutWidth }

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
        let content = contentRects
        if let symbol, let rect = content.symbol { Paint.symbol(symbol, in: rect, pointSize: size.iconSize, look.text) }
        Paint.text(title, textStyle, look.text, in: content.title, rtl: isRightToLeft)
        if let shortcut, let rect = content.shortcut { Paint.text(shortcut, DS.Text.readout, look.text, in: rect, rtl: isRightToLeft) }
    }

    /// Where the symbol, title and shortcut go. They run in reading order from the leading edge, so in a right-to-left language the
    /// symbol leads on the right and the shortcut trails on the left.
    var contentRects: (symbol: CGRect?, title: CGRect, shortcut: CGRect?) {
        var x = leadingPadding + (bounds.width - intrinsicContentSize.width) / 2
        var symbolRect: CGRect?
        if symbol != nil {
            symbolRect = mirrored(CGRect(x: x, y: 0, width: size.iconSize, height: bounds.height))
            x += size.iconSize + iconGap
        }
        let titleWidth = Paint.width(of: title, textStyle)
        let titleRect = mirrored(CGRect(x: x, y: 0, width: titleWidth, height: bounds.height))
        var shortcutRect: CGRect?
        if let shortcut {
            x += titleWidth + shortcutGap
            shortcutRect = mirrored(CGRect(x: x, y: 0, width: Paint.width(of: shortcut, DS.Text.readout), height: bounds.height))
        }
        return (symbolRect, titleRect, shortcutRect)
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
        case (.dangerGhost, .normal): return ButtonAppearance(fill: nil, text: c.dangerText)
        case (.dangerGhost, .hover), (.dangerGhost, .pressed): return ButtonAppearance(fill: c.dangerSubtle, text: c.dangerText)
        case (.danger, .normal), (.danger, .hover), (.danger, .pressed): return ButtonAppearance(fill: c.dangerSolid, text: c.onDanger)
        case (.ghost, .disabled), (.dangerGhost, .disabled): return ButtonAppearance(fill: nil, text: c.textDisabled)
        case (_, .disabled): return ButtonAppearance(fill: c.bgControl, text: c.textDisabled)
        }
    }
}
