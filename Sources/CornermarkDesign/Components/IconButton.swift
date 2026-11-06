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

    /// Shows a small check over the bottom-right corner while selected, so a toggle that is on shows it in shape as well as in fill.
    /// The check overflows the corner like a badge, so the glyph stays centred in both states. Leave room for it beside the button.
    public var marksSelection = false {
        didSet { updateMark() }
    }

    /// The colour behind the button, drawn as a ring around the check so it reads apart from the tile.
    public var markBackdrop = DS.Color.bgWindow {
        didSet { mark?.backdrop = markBackdrop }
    }

    public var isSelected = false {
        didSet {
            setAccessibilityValue(isSelected ? "Selected" : "Not selected")
            needsDisplay = true
            updateMark()
        }
    }

    public override var isEnabled: Bool {
        didSet { updateMark() }
    }

    private var mark: CheckBadge?

    public init(symbol: String, label: String, size: ComponentSize = .regular, tone: Tone = .plain) {
        self.symbol = symbol
        self.size = size
        self.tone = tone
        super.init(frame: .zero)
        toolTip = label
        setAccessibilityLabel(label)
        setAccessibilityValue("Not selected")
        if tone == .overlay { appearance = NSAppearance(named: .darkAqua) }
        // The check overflows the corner, so the button must not clip its own subviews.
        clipsToBounds = false
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
        Paint.symbol(symbol, in: bounds, pointSize: pointSize, look.text)
    }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        mark?.frame = markFrame
    }

    private func updateMark() {
        if marksSelection, mark == nil {
            let badge = CheckBadge(frame: markFrame)
            badge.backdrop = markBackdrop
            addSubview(badge)
            mark = badge
        }
        mark?.isHidden = !(marksSelection && isSelected && isEnabled)
    }

    /// The check's frame, on whole points, centred on the corner's curve so it overflows the tile by `markOverflow` on both sides.
    var markFrame: CGRect {
        let d = Self.markDiameter
        let inside = d - Self.markOverflow
        return CGRect(x: bounds.maxX - inside, y: isFlipped ? bounds.maxY - inside : bounds.minY - Self.markOverflow, width: d, height: d)
    }

    /// The check's outer size, its ring included.
    static let markDiameter: CGFloat = 12
    /// How far the check reaches past the tile's right and bottom edges. A row of checkable toggles needs a wider gap than this.
    public static let markOverflow: CGFloat = 4

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

/// The check a selected toggle shows over its corner. A ring in the backdrop colour cuts it out of the tile. It never takes clicks,
/// so a click on its overflow reaches whatever lies under it, and the button alone speaks to VoiceOver.
private final class CheckBadge: NSView {
    var backdrop = DS.Color.bgWindow {
        didSet { needsDisplay = true }
    }

    static let ring: CGFloat = 1.5
    static let glyph: CGFloat = 6

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("CheckBadge is created in code") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        Paint.fill(NSBezierPath(ovalIn: bounds), backdrop)
        let dot = bounds.insetBy(dx: Self.ring, dy: Self.ring)
        Paint.fill(NSBezierPath(ovalIn: dot), DS.Color.bgInverse)
        Paint.symbol("checkmark", in: dot, pointSize: Self.glyph, DS.Color.onInverse)
    }
}
