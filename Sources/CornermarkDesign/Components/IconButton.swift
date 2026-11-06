import AppKit

public final class IconButton: Pressable {
    public enum Tone: CaseIterable {
        /// Sits on a surface of the shell.
        case plain
        /// Circular and always dark, for buttons laid over a screenshot.
        case overlay
    }

    public var symbol: String {
        didSet { needsDisplay = true }
    }
    public let size: ComponentSize
    public let tone: Tone

    /// Replaces the size's own glyph, for a button whose frame is set by its context, such as a card that grows with a setting.
    public var glyphSize: CGFloat? {
        didSet { needsDisplay = true }
    }

    /// How the selected state looks. A tool picks with the accent; a button that only switches what a panel shows stays neutral,
    /// because navigation never takes the accent.
    public enum Selection: CaseIterable { case accent, neutral }

    public var selection = Selection.accent {
        didSet { needsDisplay = true }
    }

    public var isSelected = false {
        didSet {
            setAccessibilityValue(isSelected ? "Selected" : "Not selected")
            needsDisplay = true
        }
    }

    public init(symbol: String, label: String, size: ComponentSize = .regular, tone: Tone = .plain) {
        self.symbol = symbol
        self.size = size
        self.tone = tone
        super.init(frame: .zero)
        toolTip = label
        setAccessibilityLabel(label)
        setAccessibilityValue("Not selected")
        if tone == .overlay { appearance = NSAppearance(named: .darkAqua) }
        frame.size = intrinsicContentSize
    }

    public required init?(coder: NSCoder) { fatalError("IconButton is created in code") }

    public override var intrinsicContentSize: NSSize { NSSize(width: size.height, height: size.height) }

    override func shape(in rect: CGRect) -> NSBezierPath {
        tone == .overlay ? NSBezierPath(ovalIn: rect) : .continuous(rect, radius: size == .small ? DS.Radius.sm : DS.Radius.md)
    }

    override func paint(_ state: InteractionState) {
        let look = self.look(state)
        let path = shape(in: bounds)
        if let fill = look.fill { Paint.fill(path, fill) }
        if let border = look.border { Paint.strokeInside(path, border) }
        // A circle has less room than a rounded square, so the same glyph needs a smaller size to keep clear of its edge.
        Paint.symbol(symbol, in: bounds, pointSize: glyphSize ?? (tone == .overlay ? DS.Size.iconSmall : size.iconSize), look.text)
    }

    func look(_ state: InteractionState) -> ButtonAppearance { Self.look(tone: tone, selected: isSelected, selection: selection, state) }

    static func look(tone: Tone, selected: Bool, selection: Selection = .accent, _ state: InteractionState) -> ButtonAppearance {
        let c = DS.Color.self
        if selected && state != .disabled {
            switch selection {
            case .accent: return ButtonAppearance(fill: c.accentSubtle, text: c.accentText, border: c.accentBorder)
            case .neutral: return ButtonAppearance(fill: c.bgControlActive, text: c.textPrimary)
            }
        }
        switch (tone, state) {
        case (.plain, .normal): return ButtonAppearance(fill: nil, text: c.textSecondary)
        case (.plain, .hover): return ButtonAppearance(fill: c.bgControlHover, text: c.textPrimary)
        case (.plain, .pressed): return ButtonAppearance(fill: c.bgControlActive, text: c.textPrimary)
        case (.plain, .disabled): return ButtonAppearance(fill: nil, text: c.textDisabled)
        case (.overlay, .normal): return ButtonAppearance(fill: c.bgHud, text: c.textPrimary)
        case (.overlay, .hover): return ButtonAppearance(fill: c.bgControlHover, text: c.textPrimary)
        case (.overlay, .pressed): return ButtonAppearance(fill: c.bgControlActive, text: c.textPrimary)
        case (.overlay, .disabled): return ButtonAppearance(fill: c.bgHud, text: c.textDisabled)
        }
    }
}
