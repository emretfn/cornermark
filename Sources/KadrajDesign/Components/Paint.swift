import AppKit

/// Drawing helpers shared by the components. All of them draw into the current context and take the colour at call time,
/// so a dynamic colour resolves under whatever appearance the view is being drawn in.
enum Paint {
    static func fill(_ path: NSBezierPath, _ color: NSColor) {
        color.setFill()
        path.fill()
    }

    /// Strokes inside the path edge, so a 1pt line never grows the shape.
    static func strokeInside(_ path: NSBezierPath, _ color: NSColor, width: CGFloat = 1) {
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        color.setStroke()
        path.lineWidth = width * 2
        path.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }

    static func width(of string: String, _ style: TextStyle) -> CGFloat {
        ceil(NSAttributedString(string: string, attributes: style.attributes(color: DS.Color.textPrimary)).size().width)
    }

    /// Draws one line of text centred vertically in `rect`.
    static func text(_ string: String, _ style: TextStyle, _ color: NSColor, in rect: CGRect, alignment: NSTextAlignment = .left) {
        var attributes = style.attributes(color: color)
        let paragraph = (attributes[.paragraphStyle] as! NSParagraphStyle).mutableCopy() as! NSMutableParagraphStyle
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byTruncatingTail
        attributes[.paragraphStyle] = paragraph
        let line = CGRect(x: rect.minX, y: rect.midY - style.lineHeight / 2, width: rect.width, height: style.lineHeight)
        NSAttributedString(string: string, attributes: attributes)
            .draw(with: line, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    /// Renders the symbol as a palette-tinted template at draw time, which is what lets a dynamic colour follow appearance changes.
    static func symbol(_ name: String, in rect: CGRect, pointSize: CGFloat, _ color: NSColor) {
        let tint = color.usingColorSpace(.sRGB) ?? color
        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium).applying(.init(paletteColors: [tint]))
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration) else { return }
        let size = image.size
        image.draw(in: CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height),
                   from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
}
