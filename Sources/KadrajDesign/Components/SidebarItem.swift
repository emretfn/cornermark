import AppKit

/// A row of a sidebar: a symbol and a title, left-aligned, as wide as the sidebar lets it be. The selected row is a neutral
/// fill, not the accent, because a sidebar is navigation and the accent belongs to what the page itself asks of you.
public final class SidebarItem: Pressable {
    public let symbol: String

    public var isSelected = false {
        didSet {
            setAccessibilityValue(isSelected ? "Selected" : "Not selected")
            needsDisplay = true
        }
    }

    public init(symbol: String, title: String) {
        self.symbol = symbol
        super.init(frame: .zero)
        self.title = title
        setAccessibilityLabel(title)
        setAccessibilityValue("Not selected")
        frame.size = intrinsicContentSize
    }

    public required init?(coder: NSCoder) { fatalError("SidebarItem is created in code") }

    public override var title: String {
        didSet {
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    static let padding = DS.Space.s8
    static let gap = DS.Space.s8
    private static let style = DS.Text.body

    public override var intrinsicContentSize: NSSize {
        NSSize(width: Self.padding + DS.Size.icon + Self.gap + Paint.width(of: title, Self.style) + Self.padding, height: DS.Size.control)
    }

    override func shape(in rect: CGRect) -> NSBezierPath { .continuous(rect, radius: DS.Radius.md) }

    override func paint(_ state: InteractionState) {
        let look = Self.look(selected: isSelected, state)
        if let fill = look.fill { Paint.fill(shape(in: bounds), fill) }
        Paint.symbol(symbol, in: CGRect(x: Self.padding, y: 0, width: DS.Size.icon, height: bounds.height), pointSize: DS.Size.icon, look.symbol)
        let textX = Self.padding + DS.Size.icon + Self.gap
        Paint.text(title, Self.style, look.title, in: CGRect(x: textX, y: 0, width: max(bounds.width - textX - Self.padding, 0), height: bounds.height))
    }

    struct Look {
        var fill: NSColor?
        var symbol: NSColor
        var title: NSColor
    }

    static func look(selected: Bool, _ state: InteractionState) -> Look {
        let c = DS.Color.self
        if state == .disabled { return Look(fill: nil, symbol: c.textDisabled, title: c.textDisabled) }
        if selected { return Look(fill: c.bgControlActive, symbol: c.textPrimary, title: c.textPrimary) }
        switch state {
        case .normal: return Look(fill: nil, symbol: c.textSecondary, title: c.textPrimary)
        case .hover: return Look(fill: c.bgControlHover, symbol: c.textPrimary, title: c.textPrimary)
        default: return Look(fill: c.bgControlActive, symbol: c.textPrimary, title: c.textPrimary)
        }
    }
}
