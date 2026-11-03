import CoreGraphics
import CoreText
import Foundation

/// Measured text block. `origin` of a text annotation is the top-left of the whole box,
/// padding included, so bounds and hit-testing match what is painted.
struct TextLayout {
    let lines: [CTLine]
    let font: CTFont
    let fontSize: CGFloat
    let style: TextStylePreset
    let padding: CGSize
    let lineHeight: CGFloat
    let ascent: CGFloat
    let textSize: CGSize
    var size: CGSize { CGSize(width: textSize.width + padding.width * 2, height: textSize.height + padding.height * 2) }

    init(string: String, fontSize: Double, style: TextStylePreset) {
        let size = CGFloat(max(fontSize, 1))
        let font = Self.font(style: style, size: size)
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorFromContextAttributeName: true,
        ]
        var lines: [CTLine] = []
        var maxWidth: CGFloat = 0
        for part in string.components(separatedBy: "\n") {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: part, attributes: attributes as [NSAttributedString.Key: Any]))
            maxWidth = max(maxWidth, CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)))
            lines.append(line)
        }
        let ascent = CTFontGetAscent(font)
        let lineHeight = ascent + CTFontGetDescent(font) + CTFontGetLeading(font)
        self.lines = lines
        self.font = font
        self.fontSize = size
        self.style = style
        self.lineHeight = lineHeight
        self.ascent = ascent
        self.textSize = CGSize(width: max(maxWidth, size * 0.5), height: lineHeight * CGFloat(lines.count))
        switch style {
        case .pill: padding = CGSize(width: size * 0.55, height: size * 0.28)
        case .banner: padding = CGSize(width: size * 0.7, height: size * 0.4)
        default: padding = .zero
        }
    }

    static func font(style: TextStylePreset, size: CGFloat) -> CTFont {
        switch style {
        case .mono:
            return CTFontCreateWithName("Menlo-Regular" as CFString, size, nil)
        case .plain:
            return CTFontCreateUIFontForLanguage(.system, size, nil) ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
        default:
            return CTFontCreateUIFontForLanguage(.emphasizedSystem, size, nil) ?? CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil)
        }
    }

    /// Draws into a y-down context. CoreText glyphs are y-up, so the text matrix flips them back.
    func draw(at origin: CGPoint, color: RGBA, in ctx: CGContext) {
        let box = CGRect(origin: origin, size: size)
        let textColor: RGBA

        ctx.saveGState()
        switch style {
        case .pill:
            ctx.setFillColor(color.cgColor)
            ctx.addPath(CGPath(roundedRect: box, cornerWidth: box.height / 2, cornerHeight: box.height / 2, transform: nil))
            ctx.fillPath()
            textColor = color.contrasting
        case .banner:
            ctx.setFillColor(color.cgColor)
            ctx.fill(box)
            textColor = color.contrasting
        default:
            textColor = color
        }

        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        let textOrigin = CGPoint(x: origin.x + padding.width, y: origin.y + padding.height)

        func drawLines() {
            for (i, line) in lines.enumerated() {
                ctx.textPosition = CGPoint(x: textOrigin.x, y: textOrigin.y + CGFloat(i) * lineHeight + ascent)
                CTLineDraw(line, ctx)
            }
        }

        if style == .outlined {
            ctx.setLineJoin(.round)
            ctx.setLineWidth(fontSize * 0.16)
            ctx.setStrokeColor(color.contrasting.cgColor)
            ctx.setTextDrawingMode(.stroke)
            drawLines()
        }
        if style == .shadowed {
            ctx.setShadow(offset: CGSize(width: fontSize * 0.05, height: -fontSize * 0.07),
                          blur: fontSize * 0.18, color: CGColor(gray: 0, alpha: 0.55))
        }
        ctx.setFillColor(textColor.cgColor)
        ctx.setTextDrawingMode(.fill)
        drawLines()
        ctx.restoreGState()
    }

    /// Visual center of the glyph ink of a single line, relative to the line origin, y-up.
    func inkBounds(ofLine index: Int = 0) -> CGRect {
        CTLineGetBoundsWithOptions(lines[index], .useGlyphPathBounds)
    }
}
