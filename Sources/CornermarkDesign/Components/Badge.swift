import AppKit

public final class Badge: NSView {
    public enum Tone: CaseIterable { case neutral, accent, danger, warning, success }

    public let text: String
    public let symbol: String
    public let tone: Tone

    /// The symbol is not optional: a badge never says its state by colour alone.
    public init(text: String, symbol: String, tone: Tone = .neutral) {
        self.text = text
        self.symbol = symbol
        self.tone = tone
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(text)
        frame.size = intrinsicContentSize
    }

    public required init?(coder: NSCoder) { fatalError("Badge is created in code") }

    private static let style = DS.Text.caption

    public override var userInterfaceLayoutDirection: NSUserInterfaceLayoutDirection {
        didSet { if oldValue != userInterfaceLayoutDirection { needsDisplay = true } }
    }

    public override var intrinsicContentSize: NSSize {
        NSSize(width: DS.Space.s8 + DS.Size.iconSmall + DS.Space.s4 + Paint.width(of: text, Self.style) + DS.Space.s8, height: DS.Size.controlSmall)
    }

    public override func draw(_ dirtyRect: NSRect) {
        let look = tone.appearance
        let path = NSBezierPath.continuous(bounds, radius: DS.Radius.sm)
        Paint.fill(path, look.fill)
        Paint.strokeInside(path, look.border)
        Paint.symbol(symbol, in: symbolRect, pointSize: DS.Size.iconSmall, look.text)
        Paint.text(text, Self.style, look.text, in: textRect, rtl: isRightToLeft)
    }

    var symbolRect: CGRect { mirrored(CGRect(x: DS.Space.s8, y: 0, width: DS.Size.iconSmall, height: bounds.height)) }

    var textRect: CGRect {
        let textX = DS.Space.s8 + DS.Size.iconSmall + DS.Space.s4
        return mirrored(CGRect(x: textX, y: 0, width: bounds.width - textX - DS.Space.s8, height: bounds.height))
    }
}

struct BadgeAppearance {
    var fill: NSColor
    var border: NSColor
    var text: NSColor
}

extension Badge.Tone {
    var appearance: BadgeAppearance {
        let c = DS.Color.self
        switch self {
        case .neutral: return BadgeAppearance(fill: c.bgControl, border: c.border, text: c.textSecondary)
        case .accent: return BadgeAppearance(fill: c.accentSubtle, border: c.accentBorder, text: c.accentText)
        case .danger: return BadgeAppearance(fill: c.dangerSubtle, border: c.dangerBorder, text: c.dangerText)
        case .warning: return BadgeAppearance(fill: c.warningSubtle, border: c.warningBorder, text: c.warningText)
        case .success: return BadgeAppearance(fill: c.successSubtle, border: c.successBorder, text: c.successText)
        }
    }
}
