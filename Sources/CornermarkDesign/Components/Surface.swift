import AppKit

/// A floating background that draws its own elevation. The view is larger than the visible shape by `shadowInset` on every
/// side, so the shadow has transparent room to fall in; subviews belong inside `contentRect`.
open class Surface: NSView {
    public enum Style: CaseIterable { case hud, raised, floating, panel }

    public let style: Style
    public let shadowInset: CGFloat

    public init(style: Style, shadowInset: CGFloat = 0) {
        self.style = style
        self.shadowInset = shadowInset
        super.init(frame: .zero)
    }

    public required init?(coder: NSCoder) { fatalError("Surface is created in code") }

    /// The visible shape, inside the transparent margin that holds the shadow.
    public var contentRect: CGRect { bounds.insetBy(dx: shadowInset, dy: shadowInset) }

    struct Look {
        var elevation: Elevation?
        var fill: NSColor
        var radius: CGFloat
        var border: NSColor
    }

    var look: Look { style.look }

    /// The margin is transparent and must not swallow clicks meant for what lies beneath.
    open override func hitTest(_ point: NSPoint) -> NSView? {
        contentRect.contains(convert(point, from: superview)) ? super.hitTest(point) : nil
    }

    open override func draw(_ dirtyRect: NSRect) {
        let look = self.look
        let path = NSBezierPath.continuous(contentRect, radius: look.radius)
        if let elevation = look.elevation { elevation.draw(path, fill: look.fill) } else { Paint.fill(path, look.fill) }
        Paint.strokeInside(path, look.border)
    }
}

extension Surface.Style {
    var look: Surface.Look {
        switch self {
        case .hud: return .init(elevation: DS.Elevation.hud, fill: DS.Color.bgHud, radius: DS.Radius.lg, border: DS.Color.border)
        case .raised: return .init(elevation: DS.Elevation.raised, fill: DS.Color.bgRaised, radius: DS.Radius.md, border: DS.Color.borderSubtle)
        case .floating: return .init(elevation: DS.Elevation.floating, fill: DS.Color.bgRaised, radius: DS.Radius.xl, border: DS.Color.borderSubtle)
        case .panel: return .init(elevation: nil, fill: DS.Color.bgSurface, radius: DS.Radius.xl, border: DS.Color.borderSubtle)
        }
    }
}
