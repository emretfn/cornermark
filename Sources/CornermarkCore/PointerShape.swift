import CoreGraphics

/// The pointer drawn over a recording, in points at scale 1 with the hot spot at the origin and y growing downward.
/// The editor's preview and the export draw these same looks, so the pointer cannot differ between them.
public enum PointerShape {
    public static let outline: [CGPoint] = [
        CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 16), CGPoint(x: 4, y: 12.5), CGPoint(x: 7, y: 19),
        CGPoint(x: 9.5, y: 18), CGPoint(x: 6.6, y: 11.6), CGPoint(x: 11.5, y: 11.6),
    ]
    /// The dot is centred on the hot spot, the way a touch lands where it is drawn.
    public static let dotRadius: CGFloat = 9

    public struct Look {
        public let path: CGPath
        public let fill: CGColor
        public let stroke: CGColor
        public let lineWidth: CGFloat
    }

    public static func look(_ style: CursorStyle) -> Look {
        switch style {
        case .white: return white
        case .black: return black
        case .dot: return dot
        }
    }

    private static let arrow: CGPath = {
        let p = CGMutablePath()
        p.addLines(between: outline)
        p.closeSubpath()
        return p
    }()
    private static let white = Look(path: arrow, fill: CGColor(gray: 1, alpha: 1), stroke: CGColor(gray: 0, alpha: 1), lineWidth: 1.2)
    private static let black = Look(path: arrow, fill: CGColor(gray: 0.08, alpha: 1), stroke: CGColor(gray: 1, alpha: 1), lineWidth: 1.4)
    private static let dot = Look(path: CGPath(ellipseIn: CGRect(x: -dotRadius, y: -dotRadius, width: 2 * dotRadius, height: 2 * dotRadius), transform: nil),
                                  fill: CGColor(gray: 0.1, alpha: 0.4), stroke: CGColor(gray: 1, alpha: 0.85), lineWidth: 1.5)

    /// Draws the pointer at `cursor` in a context whose units are the recording's points, y down. A faded pointer fades as one
    /// shape, so its outline does not show through its fill.
    public static func draw(_ cursor: CursorFrame, in ctx: CGContext) {
        let look = look(cursor.style)
        ctx.saveGState()
        ctx.translateBy(x: cursor.x, y: cursor.y)
        ctx.scaleBy(x: cursor.scale, y: cursor.scale)
        let faded = cursor.opacity < 1
        if faded {
            ctx.setAlpha(cursor.opacity)
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        }
        ctx.addPath(look.path)
        ctx.setFillColor(look.fill)
        ctx.setStrokeColor(look.stroke)
        ctx.setLineWidth(look.lineWidth)
        ctx.setLineJoin(.round)
        ctx.drawPath(using: .fillStroke)
        if faded { ctx.endTransparencyLayer() }
        ctx.restoreGState()
    }
}
