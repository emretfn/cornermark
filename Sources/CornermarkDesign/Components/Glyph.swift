import AppKit

/// The one public way to draw a symbol the way the components do, for custom views outside this module.
public enum Glyph {
    /// Draws the SF Symbol `name` optically centred in `rect` in the current graphics context.
    public static func draw(_ name: String, in rect: CGRect, pointSize: CGFloat = DS.Size.icon, _ color: NSColor) {
        Paint.symbol(name, in: rect, pointSize: pointSize, color)
    }
}
