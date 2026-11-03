import AppKit

extension NSTextField {
    /// A static, non-selectable label. The style fixes the font and the colour role; change `stringValue` later without losing either.
    public static func label(_ text: String, style: TextStyle, color: NSColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = style.font
        field.textColor = color
        field.maximumNumberOfLines = 1
        field.lineBreakMode = .byTruncatingTail
        return field
    }
}
