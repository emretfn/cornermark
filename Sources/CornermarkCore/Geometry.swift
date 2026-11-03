import CoreGraphics

extension CGPoint {
    static func + (l: CGPoint, r: CGPoint) -> CGPoint { CGPoint(x: l.x + r.x, y: l.y + r.y) }
    static func - (l: CGPoint, r: CGPoint) -> CGPoint { CGPoint(x: l.x - r.x, y: l.y - r.y) }
    static func * (l: CGPoint, r: CGFloat) -> CGPoint { CGPoint(x: l.x * r, y: l.y * r) }

    var length: CGFloat { hypot(x, y) }
    var perpendicular: CGPoint { CGPoint(x: -y, y: x) }

    func distance(to other: CGPoint) -> CGFloat { (self - other).length }

    func normalized() -> CGPoint {
        let l = length
        return l > 1e-9 ? CGPoint(x: x / l, y: y / l) : .zero
    }

    func lerp(to other: CGPoint, _ t: CGFloat) -> CGPoint {
        CGPoint(x: x + (other.x - x) * t, y: y + (other.y - y) * t)
    }
}

func distance(from p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
    let ab = b - a
    let lenSq = ab.x * ab.x + ab.y * ab.y
    guard lenSq > 1e-12 else { return p.distance(to: a) }
    let t = max(0, min(1, ((p.x - a.x) * ab.x + (p.y - a.y) * ab.y) / lenSq))
    return p.distance(to: a + ab * t)
}

func distance(from p: CGPoint, toPolyline pts: [CGPoint], closed: Bool = false) -> CGFloat {
    guard let first = pts.first else { return .infinity }
    guard pts.count > 1 else { return p.distance(to: first) }
    var best = CGFloat.infinity
    for i in 0..<(pts.count - 1) { best = min(best, distance(from: p, toSegment: pts[i], pts[i + 1])) }
    if closed, let last = pts.last { best = min(best, distance(from: p, toSegment: last, first)) }
    return best
}

func pointInPolygon(_ p: CGPoint, _ poly: [CGPoint]) -> Bool {
    var inside = false
    var j = poly.count - 1
    for i in 0..<poly.count {
        let a = poly[i], b = poly[j]
        if (a.y > p.y) != (b.y > p.y), p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
        j = i
    }
    return inside
}

extension RGBA {
    var luminance: Double { 0.299 * r + 0.587 * g + 0.114 * b }
    /// Black or white, whichever reads better on top of this color.
    var contrasting: RGBA { luminance > 0.6 ? RGBA(0, 0, 0) : RGBA(1, 1, 1) }

    init(hex: UInt32, alpha: Double = 1) {
        self.init(Double((hex >> 16) & 0xFF) / 255, Double((hex >> 8) & 0xFF) / 255, Double(hex & 0xFF) / 255, alpha)
    }
}

extension CGRect {
    func inflated(_ d: CGFloat) -> CGRect { insetBy(dx: -d, dy: -d) }

    /// Smallest integral rect containing self, clamped to `bounds`.
    func integralClamped(to bounds: CGRect) -> CGRect {
        let r = standardized.intersection(bounds)
        guard !r.isNull, r.width > 0, r.height > 0 else { return .null }
        let x0 = floor(r.minX), y0 = floor(r.minY)
        let x1 = ceil(r.maxX), y1 = ceil(r.maxY)
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0).intersection(bounds)
    }
}
