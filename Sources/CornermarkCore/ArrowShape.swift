import CoreGraphics

/// Arrow geometry shared by the painter and hit-testing so they cannot drift apart.
struct ArrowShape {
    let style: ArrowStyle
    let from: CGPoint
    let tip: CGPoint
    let dir: CGPoint
    let headBase: CGPoint
    let headLength: CGFloat
    let headHalfWidth: CGFloat
    let width: CGFloat
    /// Curved shaft, already trimmed to end at the head.
    let quad: (p0: CGPoint, control: CGPoint, p1: CGPoint)?

    init(from: CGPoint, to: CGPoint, control: CGPoint?, style: ArrowStyle, width rawWidth: Double) {
        let w = CGFloat(max(rawWidth, 1))
        let length = from.distance(to: to)
        let headLength = min(max(w * 4.2, 14), max(length * 0.6, 3))
        self.style = style
        self.from = from
        self.tip = to
        self.width = w
        self.headLength = headLength
        self.headHalfWidth = headLength * (style == .tapered ? 0.6 : 0.5)

        if style == .curved, length > 1e-6 {
            let c = control ?? from.lerp(to: to, 0.5) + (to - from).perpendicular.normalized() * (length * 0.25)
            var d = (to - c).normalized()
            if d == .zero { d = (to - from).normalized() }
            dir = d
            headBase = to - d * headLength
            if length <= headLength {
                quad = nil
            } else {
                var lo: CGFloat = 0, hi: CGFloat = 1
                for _ in 0..<24 {
                    let mid = (lo + hi) / 2
                    let p = Self.quadPoint(from, c, to, mid)
                    if p.distance(to: to) > headLength * 0.9 { lo = mid } else { hi = mid }
                }
                let t = lo
                let c1 = from.lerp(to: c, t)
                let s = c1.lerp(to: c.lerp(to: to, t), t)
                quad = (from, c1, s)
            }
        } else {
            dir = (to - from).normalized()
            headBase = to - dir * headLength
            quad = nil
        }
    }

    static func quadPoint(_ p0: CGPoint, _ c: CGPoint, _ p1: CGPoint, _ t: CGFloat) -> CGPoint {
        p0.lerp(to: c, t).lerp(to: c.lerp(to: p1, t), t)
    }

    var normal: CGPoint { dir.perpendicular }

    var headTriangle: [CGPoint] {
        [tip, headBase + normal * headHalfWidth, headBase - normal * headHalfWidth]
    }

    /// Centerline of the shaft, tail to head base.
    var shaftPolyline: [CGPoint] {
        if let q = quad { return (0...24).map { Self.quadPoint(q.p0, q.control, q.p1, CGFloat($0) / 24) } }
        return [from, headBase]
    }

    /// Closed outline used by the tapered and outline styles.
    var polygon: [CGPoint] {
        let n = normal
        switch style {
        case .tapered:
            let tail = max(width * 0.12, 0.5), mid = max(width * 0.65, 2)
            return [from + n * tail, headBase + n * mid, headBase + n * headHalfWidth, tip,
                    headBase - n * headHalfWidth, headBase - n * mid, from - n * tail]
        default:
            let sw = max(width * 0.8, 3)
            return [from + n * sw, headBase + n * sw, headBase + n * headHalfWidth, tip,
                    headBase - n * headHalfWidth, headBase - n * sw, from - n * sw]
        }
    }

    var allPoints: [CGPoint] {
        var pts = [from, tip] + headTriangle
        if let q = quad { pts += [q.control] }
        if style == .tapered || style == .outline { pts += polygon }
        return pts
    }
}
