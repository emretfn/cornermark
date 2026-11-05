import CoreGraphics

/// The pointer drawn over a recording, in points at scale 1 with the hot spot at the origin and y growing downward.
/// The editor's preview and the export draw this same outline, so the pointer cannot differ between them.
public enum PointerShape {
    public static let outline: [CGPoint] = [
        CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 16), CGPoint(x: 4, y: 12.5), CGPoint(x: 7, y: 19),
        CGPoint(x: 9.5, y: 18), CGPoint(x: 6.6, y: 11.6), CGPoint(x: 11.5, y: 11.6),
    ]
    public static let fill = CGColor(gray: 1, alpha: 1)
    public static let stroke = CGColor(gray: 0, alpha: 1)
    public static let lineWidth: CGFloat = 1.2

    /// Draws the pointer at `cursor` in a context whose units are the recording's points, y down.
    public static func draw(_ cursor: CursorFrame, in ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: cursor.x, y: cursor.y)
        ctx.scaleBy(x: cursor.scale, y: cursor.scale)
        ctx.beginPath()
        ctx.addLines(between: outline)
        ctx.closePath()
        ctx.setFillColor(fill)
        ctx.setStrokeColor(stroke)
        ctx.setLineWidth(lineWidth)
        ctx.setLineJoin(.round)
        ctx.drawPath(using: .fillStroke)
        ctx.restoreGState()
    }
}
