import CoreGraphics
import KadrajCore

extension CGPoint {
    static func + (l: CGPoint, r: CGPoint) -> CGPoint { CGPoint(x: l.x + r.x, y: l.y + r.y) }
    static func - (l: CGPoint, r: CGPoint) -> CGPoint { CGPoint(x: l.x - r.x, y: l.y - r.y) }
    static func * (l: CGPoint, r: CGFloat) -> CGPoint { CGPoint(x: l.x * r, y: l.y * r) }
    var length: CGFloat { hypot(x, y) }
    var perpendicular: CGPoint { CGPoint(x: -y, y: x) }
    func distance(to o: CGPoint) -> CGFloat { (self - o).length }
    func normalized() -> CGPoint { let l = length; return l > 1e-9 ? CGPoint(x: x / l, y: y / l) : .zero }
    func lerp(to o: CGPoint, _ t: CGFloat) -> CGPoint { CGPoint(x: x + (o.x - x) * t, y: y + (o.y - y) * t) }
}

extension CGRect {
    func inflated(_ d: CGFloat) -> CGRect { insetBy(dx: -d, dy: -d) }

    /// Smallest integral rect containing self, clamped to `bounds`; `.null` when empty.
    func integralClamped(to bounds: CGRect) -> CGRect {
        let r = standardized.intersection(bounds)
        guard !r.isNull, r.width > 0, r.height > 0 else { return .null }
        let x0 = floor(r.minX), y0 = floor(r.minY), x1 = ceil(r.maxX), y1 = ceil(r.maxY)
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0).intersection(bounds)
    }
}

extension RGBA {
    init(hex: UInt32) {
        self.init(Double((hex >> 16) & 0xFF) / 255, Double((hex >> 8) & 0xFF) / 255, Double(hex & 0xFF) / 255, 1)
    }
    var luminance: Double { 0.299 * r + 0.587 * g + 0.114 * b }
    /// Black or white, whichever reads better on top of this colour; matches what the renderer picks.
    var contrasting: RGBA { luminance > 0.6 ? RGBA(0, 0, 0) : RGBA(1, 1, 1) }
}
