import AppKit
import CornermarkL10n

/// A view whose content is a picture of something (a screenshot, the canvas) and must never be mirrored.
/// `applyLanguageDirection()` leaves it and its subviews left to right.
public protocol KeepsLeftToRight: NSView {}

extension L10n {
    public static var layoutDirection: NSUserInterfaceLayoutDirection { isRightToLeft ? .rightToLeft : .leftToRight }
}

extension NSView {
    /// Sets the current language's layout direction on this view and every subview, so leading and trailing
    /// constraints and stack views mirror. Call it after building a view tree and after adding subviews later.
    public func applyLanguageDirection(_ direction: NSUserInterfaceLayoutDirection = L10n.layoutDirection) {
        var flipped: [NSView] = []
        setDirection(direction, flipped: &flipped)
        // Inside a window, an active leading or trailing constraint keeps the side it resolved to when it was
        // activated, so flipping a view's direction moves nothing until its constraints are activated again.
        let sided: Set<NSLayoutConstraint.Attribute> = [.leading, .trailing]
        let owners = flipped + [superview].compactMap { $0 }
        let stale = Set(owners.flatMap(\.constraints)).filter { sided.contains($0.firstAttribute) || sided.contains($0.secondAttribute) }
        NSLayoutConstraint.deactivate(Array(stale))
        NSLayoutConstraint.activate(Array(stale))
    }

    private func setDirection(_ direction: NSUserInterfaceLayoutDirection, flipped: inout [NSView]) {
        let resolved: NSUserInterfaceLayoutDirection = self is KeepsLeftToRight ? .leftToRight : direction
        if userInterfaceLayoutDirection != resolved {
            userInterfaceLayoutDirection = resolved
            flipped.append(self)
            needsLayout = true
            needsDisplay = true
        }
        for sub in subviews { sub.setDirection(resolved, flipped: &flipped) }
    }

    public var isRightToLeft: Bool { userInterfaceLayoutDirection == .rightToLeft }

    /// `rect`, laid out as if left to right, flipped across this view's width when the view is right to left.
    /// Frame-based layout writes its frames through this.
    public func mirrored(_ rect: CGRect, within width: CGFloat? = nil) -> CGRect {
        guard isRightToLeft else { return rect }
        var r = rect
        r.origin.x = (width ?? bounds.width) - rect.maxX
        return r
    }
}

extension Glyph {
    /// The symbol that points the same way in reading order: in a right-to-left language `chevron.right`
    /// becomes `chevron.left` and `arrow.uturn.backward` becomes `arrow.uturn.forward`. A symbol that names
    /// both sides, such as `arrow.left.and.right`, is symmetric and stays as it is.
    public static func directional(_ name: String, _ direction: NSUserInterfaceLayoutDirection = L10n.layoutDirection) -> String {
        guard direction == .rightToLeft else { return name }
        let opposite = ["left": "right", "right": "left", "backward": "forward", "forward": "backward"]
        let parts = name.split(separator: ".").map(String.init)
        let sides = Set(parts.filter { opposite[$0] != nil })
        guard sides.count == 1 else { return name }
        let flipped = parts.map { opposite[$0] ?? $0 }.joined(separator: ".")
        return NSImage(systemSymbolName: flipped, accessibilityDescription: nil) == nil ? name : flipped
    }
}
