import AppKit
import KadrajDesign

/// Immediate-mode helpers for the specimen. Every call assumes a flipped context, so y grows downward.
enum Draw {
    static func attributed(_ string: String, _ style: TextStyle, _ color: NSColor, align: NSTextAlignment = .left) -> NSAttributedString {
        var attributes = style.attributes(color: color)
        let paragraph = (attributes[.paragraphStyle] as! NSParagraphStyle).mutableCopy() as! NSMutableParagraphStyle
        paragraph.alignment = align
        paragraph.lineBreakMode = .byTruncatingTail
        attributes[.paragraphStyle] = paragraph
        return NSAttributedString(string: string, attributes: attributes)
    }

    static func width(_ string: String, _ style: TextStyle) -> CGFloat {
        ceil(NSAttributedString(string: string, attributes: style.attributes(color: .black)).size().width)
    }

    @discardableResult
    static func text(_ string: String, _ style: TextStyle, _ color: NSColor, at origin: CGPoint, width: CGFloat? = nil,
                     align: NSTextAlignment = .left) -> CGFloat {
        let w = width ?? self.width(string, style) + 2
        attributed(string, style, color, align: align)
            .draw(with: CGRect(x: origin.x, y: origin.y, width: w, height: style.lineHeight), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        return origin.y + style.lineHeight
    }

    static func text(_ string: String, _ style: TextStyle, _ color: NSColor, centeredIn rect: CGRect) {
        text(string, style, color, at: CGPoint(x: rect.minX, y: rect.midY - style.lineHeight / 2), width: rect.width, align: .center)
    }

    static func text(_ string: String, _ style: TextStyle, _ color: NSColor, trailingAt x: CGFloat, y: CGFloat) {
        let w = width(string, style) + 2
        text(string, style, color, at: CGPoint(x: x - w, y: y), width: w, align: .right)
    }

    static func fill(_ path: NSBezierPath, _ color: NSColor) {
        color.setFill()
        path.fill()
    }

    /// Strokes inside the path edge, so a 1pt line never grows the shape.
    static func stroke(_ path: NSBezierPath, _ color: NSColor, width: CGFloat = 1) {
        NSGraphicsContext.current?.saveGraphicsState()
        path.addClip()
        color.setStroke()
        path.lineWidth = width * 2
        path.stroke()
        NSGraphicsContext.current?.restoreGraphicsState()
    }

    static func line(from a: CGPoint, to b: CGPoint, _ color: NSColor, width: CGFloat = 1) {
        let path = NSBezierPath()
        path.move(to: a)
        path.line(to: b)
        path.lineWidth = width
        color.setStroke()
        path.stroke()
    }

    static func hairline(x0: CGFloat, x1: CGFloat, y: CGFloat, _ color: NSColor) {
        fill(NSBezierPath(rect: CGRect(x: x0, y: y, width: x1 - x0, height: 1)), color)
    }

    static func rounded(_ rect: CGRect, _ radius: CGFloat) -> NSBezierPath { .continuous(rect, radius: radius) }

    static func circle(_ rect: CGRect) -> NSBezierPath { NSBezierPath(ovalIn: rect) }

    static func symbol(_ name: String, in rect: CGRect, size: CGFloat = DS.Size.icon, weight: NSFont.Weight = .medium, _ color: NSColor) {
        let tint = color.usingColorSpace(.sRGB) ?? color
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: weight).applying(.init(paletteColors: [tint]))
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) else {
            print("missing SF Symbol \(name)")
            return
        }
        let s = image.size
        image.draw(in: CGRect(x: rect.midX - s.width / 2, y: rect.midY - s.height / 2, width: s.width, height: s.height),
                   from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    static func srgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}
