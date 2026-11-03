import CoreGraphics
import Foundation

enum Smoothing {
    /// Catmull-Rom through `points`, expressed as cubic Béziers so the painter and nothing else
    /// has to care about the spline.
    static func path(through raw: [CGPoint]) -> CGPath {
        let pts = dedupe(raw)
        let path = CGMutablePath()
        guard let first = pts.first else { return path }
        path.move(to: first)
        if pts.count == 1 {
            path.addLine(to: first)
        } else if pts.count == 2 {
            path.addLine(to: pts[1])
        } else {
            for i in 0..<(pts.count - 1) {
                let p0 = pts[max(i - 1, 0)], p1 = pts[i], p2 = pts[i + 1], p3 = pts[min(i + 2, pts.count - 1)]
                let c1 = p1 + (p2 - p0) * (1.0 / 6.0)
                let c2 = p2 - (p3 - p1) * (1.0 / 6.0)
                path.addCurve(to: p2, control1: c1, control2: c2)
            }
        }
        return path
    }

    static func dedupe(_ pts: [CGPoint]) -> [CGPoint] {
        var out: [CGPoint] = []
        for p in pts where out.last.map({ $0.distance(to: p) >= 0.5 }) ?? true { out.append(p) }
        if out.isEmpty, let f = pts.first { out = [f] }
        return out
    }
}

extension Annotation {
    private var halfWidth: CGFloat { CGFloat(max(stroke.width, 1)) / 2 }

    /// Visual bounds in source pixels, stroke and arrow head included.
    public var bounds: CGRect {
        switch kind {
        case .arrow(let from, let to, let control, let style):
            let shape = ArrowShape(from: from, to: to, control: control, style: style, width: stroke.width)
            return Self.boundingBox(shape.allPoints).inflated(halfWidth + 1)
        case .line(let a, let b):
            return Self.boundingBox([a, b]).inflated(halfWidth)
        case .rect(let r, _, _), .ellipse(let r, _):
            return r.standardized.inflated(halfWidth)
        case .blur(let r, _), .pixelate(let r, _, _), .spotlight(let r), .image(let r, _):
            return r.standardized
        case .text(let origin, let string, let fontSize, let style):
            return CGRect(origin: origin, size: TextLayout(string: string, fontSize: fontSize, style: style).size)
        case .counter(let c, _, let radius):
            let r = CGFloat(max(radius, 1))
            return CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
        case .pencil(let pts), .highlighter(let pts):
            return Self.boundingBox(pts).inflated(halfWidth)
        }
    }

    public func hitTest(_ point: CGPoint, tolerance: CGFloat) -> Bool {
        let reach = tolerance + halfWidth
        switch kind {
        case .arrow(let from, let to, let control, let style):
            let shape = ArrowShape(from: from, to: to, control: control, style: style, width: stroke.width)
            if pointInPolygon(point, shape.headTriangle) || distance(from: point, toPolyline: shape.headTriangle, closed: true) <= tolerance {
                return true
            }
            if style == .tapered || style == .outline {
                let poly = shape.polygon
                if style == .tapered, pointInPolygon(point, poly) { return true }
                return distance(from: point, toPolyline: poly, closed: true) <= reach
            }
            return distance(from: point, toPolyline: shape.shaftPolyline) <= reach
        case .line(let a, let b):
            return distance(from: point, toSegment: a, b) <= reach
        case .rect(let r, let filled, _):
            let r = r.standardized
            if filled { return r.inflated(tolerance).contains(point) }
            let outline = [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                           CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)]
            return distance(from: point, toPolyline: outline, closed: true) <= reach
        case .ellipse(let r, let filled):
            let r = r.standardized
            if filled, Self.normalizedEllipseRadius(point, r, grow: tolerance) <= 1 { return true }
            let ring = (0..<96).map { i -> CGPoint in
                let a = CGFloat(i) / 96 * 2 * .pi
                return CGPoint(x: r.midX + cos(a) * r.width / 2, y: r.midY + sin(a) * r.height / 2)
            }
            return distance(from: point, toPolyline: ring, closed: true) <= reach
        case .blur(let r, _), .pixelate(let r, _, _), .spotlight(let r), .image(let r, _):
            return r.standardized.inflated(tolerance).contains(point)
        case .text:
            return bounds.inflated(tolerance).contains(point)
        case .counter(let c, _, let radius):
            return point.distance(to: c) <= CGFloat(max(radius, 1)) + tolerance
        case .pencil(let pts), .highlighter(let pts):
            return distance(from: point, toPolyline: pts) <= reach
        }
    }

    public func translated(by v: CGVector) -> Annotation {
        let d = CGPoint(x: v.dx, y: v.dy)
        var copy = self
        switch kind {
        case .arrow(let from, let to, let control, let style):
            copy.kind = .arrow(from: from + d, to: to + d, control: control.map { $0 + d }, style: style)
        case .line(let a, let b):
            copy.kind = .line(from: a + d, to: b + d)
        case .rect(let r, let filled, let radius):
            copy.kind = .rect(r.offsetBy(dx: v.dx, dy: v.dy), filled: filled, cornerRadius: radius)
        case .ellipse(let r, let filled):
            copy.kind = .ellipse(r.offsetBy(dx: v.dx, dy: v.dy), filled: filled)
        case .text(let origin, let string, let size, let style):
            copy.kind = .text(origin: origin + d, string: string, fontSize: size, style: style)
        case .counter(let c, let n, let radius):
            copy.kind = .counter(center: c + d, number: n, radius: radius)
        case .pencil(let pts):
            copy.kind = .pencil(points: pts.map { $0 + d })
        case .highlighter(let pts):
            copy.kind = .highlighter(points: pts.map { $0 + d })
        case .blur(let r, let mode):
            copy.kind = .blur(r.offsetBy(dx: v.dx, dy: v.dy), mode: mode)
        case .pixelate(let r, let block, let seed):
            copy.kind = .pixelate(r.offsetBy(dx: v.dx, dy: v.dy), blockSize: block, seed: seed)
        case .spotlight(let r):
            copy.kind = .spotlight(r.offsetBy(dx: v.dx, dy: v.dy))
        case .image(let r, let asset):
            copy.kind = .image(r.offsetBy(dx: v.dx, dy: v.dy), asset: asset)
        }
        return copy
    }

    private static func boundingBox(_ pts: [CGPoint]) -> CGRect {
        guard let first = pts.first else { return .zero }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for p in pts { minX = min(minX, p.x); maxX = max(maxX, p.x); minY = min(minY, p.y); maxY = max(maxY, p.y) }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private static func normalizedEllipseRadius(_ p: CGPoint, _ r: CGRect, grow: CGFloat) -> CGFloat {
        let rx = r.width / 2 + grow, ry = r.height / 2 + grow
        guard rx > 0, ry > 0 else { return .infinity }
        let dx = (p.x - r.midX) / rx, dy = (p.y - r.midY) / ry
        return dx * dx + dy * dy
    }
}

extension Document {
    /// Topmost annotation under `point`, or nil. Annotations later in the array paint on top.
    public func annotationID(at point: CGPoint, tolerance: CGFloat) -> UUID? {
        annotations.last { $0.hitTest(point, tolerance: tolerance) }?.id
    }
}
