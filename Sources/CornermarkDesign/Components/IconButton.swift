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

    /// Draws a small check in the corner while selected, so a toggle that is on shows it in shape as well as in fill.
    public var marksSelection = false {
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
        let pointSize = glyphSize ?? (tone == .overlay ? DS.Size.iconSmall : size.iconSize)
        guard marksSelection else {
            Paint.symbol(symbol, in: bounds, pointSize: pointSize, look.text)
            return
        }
        // A toggle that can carry the check keeps its glyph up and away from the check's corner in both states, so turning it on
        // never moves the glyph, and the glyph is never drawn under the check or the gap around it.
        let mark = markRect
        let up = isFlipped ? -Self.markNudge : Self.markNudge
        NSGraphicsContext.saveGraphicsState()
        let clear = NSBezierPath(rect: bounds)
        clear.append(NSBezierPath(ovalIn: mark.insetBy(dx: -Self.markGap, dy: -Self.markGap)))
        clear.windingRule = .evenOdd
        clear.addClip()
        Paint.symbol(symbol, in: bounds.offsetBy(dx: -Self.markNudge, dy: up), pointSize: pointSize, look.text)
        NSGraphicsContext.restoreGraphicsState()
        guard isSelected, state != .disabled else { return }
        Paint.fill(NSBezierPath(ovalIn: mark), DS.Color.bgInverse)
        Paint.symbol("checkmark", in: mark, pointSize: Self.markGlyph, DS.Color.onInverse)
    }

    /// The check sits in the corner itself, on whole points, so it stays sharp and clear of the glyph.
    var markRect: CGRect {
        let d = Self.markDiameter
        return CGRect(x: bounds.maxX - d, y: isFlipped ? bounds.maxY - d : bounds.minY, width: d, height: d)
    }

    static let markDiameter: CGFloat = 9
    static let markGlyph: CGFloat = 6
    /// How far the glyph of a checkable toggle sits up and left of centre, so even the widest source glyph keeps `markGap` from the check.
    static let markNudge: CGFloat = 2
    /// The ring left empty around the check, in the button's own fill, so check and glyph never touch.
    static let markGap: CGFloat = 1.5

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
