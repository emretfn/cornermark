import AppKit

extension NSTextField {
    /// A static, non-selectable label. The style fixes the font and the colour role; change `stringValue` later without losing either.
    public static func label(_ text: String, style: TextStyle, color: NSColor) -> NSTextField {
        let field = StyledLabel(labelWithString: text)
        field.lineHeight = style.lineHeight
        field.font = style.font
        field.textColor = color
        field.alignment = .natural
        field.maximumNumberOfLines = 1
        field.lineBreakMode = .byTruncatingTail
        return field
    }
}

/// A one-line label asks Auto Layout for whole points at its style's line height. The text's own size is fractional (15 points for a
/// 16-point line, widths like 60.5), and a stack that centres it in an even row or lines up a neighbour after it lands that text on a
/// half point, which a 1x display draws across two pixels.
final class StyledLabel: NSTextField {
    var lineHeight: CGFloat = 0 { didSet { invalidateIntrinsicContentSize() } }

    override var intrinsicContentSize: NSSize {
        let size = super.intrinsicContentSize
        guard maximumNumberOfLines == 1 else { return size }
        let width = size.width == NSView.noIntrinsicMetric ? size.width : size.width.rounded(.up)
        let height = size.height == NSView.noIntrinsicMetric ? size.height : max(size.height, lineHeight).rounded(.up)
        return NSSize(width: width, height: height)
    }
}
