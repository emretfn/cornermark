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

    /// Draws one line of text centred vertically in `rect`. `.left` means the start of the line, so in a right-to-left view (`rtl`) it
    /// sits against the rect's right edge and the line runs right to left.
    static func text(_ string: String, _ style: TextStyle, _ color: NSColor, in rect: CGRect, alignment: NSTextAlignment = .left, rtl: Bool = false) {
        var attributes = style.attributes(color: color)
        let paragraph = (attributes[.paragraphStyle] as! NSParagraphStyle).mutableCopy() as! NSMutableParagraphStyle
        paragraph.alignment = rtl && alignment == .left ? .right : alignment
        if rtl { paragraph.baseWritingDirection = .rightToLeft }
        paragraph.lineBreakMode = .byTruncatingTail
        attributes[.paragraphStyle] = paragraph
        let line = CGRect(x: rect.minX, y: rect.midY - style.lineHeight / 2, width: rect.width, height: style.lineHeight)
        NSAttributedString(string: string, attributes: attributes)
            .draw(with: line, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    /// Renders the symbol as a palette-tinted template at draw time, which is what lets a dynamic colour follow appearance changes.
    /// Centres the glyph optically, because an SF Symbol's image box carries uneven padding that leaves some glyphs up to 1pt off.
    static func symbol(_ name: String, in rect: CGRect, pointSize: CGFloat, _ color: NSColor) {
        let tint = color.usingColorSpace(.sRGB) ?? color
        let weight = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(weight.applying(.init(paletteColors: [tint]))) else { return }
        let size = image.size
        let offset = inkOffset(name, pointSize: pointSize, image: image)
        let flipped = NSGraphicsContext.current?.isFlipped ?? false
        let x = rect.midX - size.width / 2 - offset.dx
        let y = rect.midY - size.height / 2 - (flipped ? offset.dy : -offset.dy)
        // Snaps to device pixels, so an odd-sized glyph in an even-sized button stays sharp and every neighbour lands alike.
        let pixels = max(abs(NSGraphicsContext.current?.cgContext.ctm.a ?? 1), 1)
        image.draw(in: CGRect(x: (x * pixels).rounded() / pixels, y: (y * pixels).rounded() / pixels, width: size.width, height: size.height),
                   from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    private static var inkOffsets: [String: CGVector] = [:]

    /// How far the optical centre sits from the image's centre, x to the right and y downward. Measured once per symbol and size.
    /// It is halfway between the ink's bounds and its mass: bounds alone leaves a tray with a tall arrow looking low, mass alone
    /// pushes a pin's long needle out of the button.
    private static func inkOffset(_ name: String, pointSize: CGFloat, image: NSImage) -> CGVector {
        let key = "\(name)@\(pointSize)"
        if let known = inkOffsets[key] { return known }
        let scale = 4, size = image.size
        let w = Int(ceil(size.width)) * scale, h = Int(ceil(size.height)) * scale
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return .zero }
        // The context takes its scale from the rep's size, so the size has to be set before the context exists.
        rep.size = NSSize(width: w / scale, height: h / scale)
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return .zero }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: CGRect(x: 0, y: CGFloat(h / scale) - size.height, width: size.width, height: size.height))
        NSGraphicsContext.restoreGraphicsState()

        var minX = w, maxX = -1, minY = h, maxY = -1
        var mass: CGFloat = 0, massX: CGFloat = 0, massY: CGFloat = 0
        for y in 0..<h {
            for x in 0..<w {
                let alpha = rep.colorAt(x: x, y: y)?.alphaComponent ?? 0
                mass += alpha; massX += alpha * (CGFloat(x) + 0.5); massY += alpha * (CGFloat(y) + 0.5)
                if alpha > 0.3 { minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y) }
            }
        }
        guard maxX >= 0 else { return .zero }
        let offset = CGVector(dx: (CGFloat(minX + maxX + 1) / 2 + massX / mass) / 2 / CGFloat(scale) - size.width / 2,
                              dy: (CGFloat(minY + maxY + 1) / 2 + massY / mass) / 2 / CGFloat(scale) - size.height / 2)
        inkOffsets[key] = offset
        return offset
    }
}
