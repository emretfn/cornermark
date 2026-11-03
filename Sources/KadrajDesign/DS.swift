import AppKit

public enum DS {}

extension DS {
    public enum Space {
        public static let s2: CGFloat = 2
        public static let s4: CGFloat = 4
        public static let s6: CGFloat = 6
        public static let s8: CGFloat = 8
        public static let s12: CGFloat = 12
        public static let s16: CGFloat = 16
        public static let s24: CGFloat = 24
        public static let s32: CGFloat = 32
        public static let all = [s2, s4, s6, s8, s12, s16, s24, s32]
    }

    public enum Size {
        public static let controlSmall: CGFloat = 22
        public static let control: CGFloat = 28
        public static let controlLarge: CGFloat = 36
        public static let iconSmall: CGFloat = 12
        public static let icon: CGFloat = 14
        public static let iconLarge: CGFloat = 16
    }

    public enum Radius {
        public static let xs: CGFloat = 4
        public static let sm: CGFloat = 6
        public static let md: CGFloat = 8
        public static let lg: CGFloat = 12
        public static let xl: CGFloat = 16

        public static func concentric(inner: CGFloat, padding: CGFloat) -> CGFloat { inner + padding }
    }
}

extension NSBezierPath {
    /// A rounded rect with Apple-style continuous corners. Each corner starts 1.528665 * radius away from the vertex
    /// along the edge, which is what lets the curvature ease in instead of jumping from straight to circular.
    public static func continuous(_ rect: CGRect, radius: CGFloat) -> NSBezierPath {
        let limit = min(rect.width, rect.height) / 2 / 1.52866483
        let r = min(max(radius, 0), limit)
        let path = NSBezierPath()
        guard r > 0 else {
            path.appendRect(rect)
            return path
        }

        func point(_ vertex: CGPoint, _ a: CGVector, _ x: CGFloat, _ b: CGVector, _ y: CGFloat) -> CGPoint {
            CGPoint(x: vertex.x + a.dx * x * r + b.dx * y * r, y: vertex.y + a.dy * x * r + b.dy * y * r)
        }
        // Walks from the point on `from` to the point on `to`, both unit vectors pointing from the vertex along an edge.
        func corner(_ vertex: CGPoint, from: CGVector, to: CGVector) {
            func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { point(vertex, to, x, from, y) }
            path.curve(to: p(0.07491139, 0.63149379), controlPoint1: p(0, 1.08849296), controlPoint2: p(0, 0.86840694))
            path.curve(to: p(0.63149379, 0.07491139), controlPoint1: p(0.16905956, 0.37282383), controlPoint2: p(0.37282383, 0.16905956))
            path.curve(to: p(1.52866483, 0), controlPoint1: p(0.86840694, 0), controlPoint2: p(1.08849296, 0))
        }

        let right = CGVector(dx: 1, dy: 0), left = CGVector(dx: -1, dy: 0)
        let up = CGVector(dx: 0, dy: 1), down = CGVector(dx: 0, dy: -1)
        let k: CGFloat = 1.52866483 * r
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + k))
        corner(CGPoint(x: rect.minX, y: rect.minY), from: up, to: right)
        path.line(to: CGPoint(x: rect.maxX - k, y: rect.minY))
        corner(CGPoint(x: rect.maxX, y: rect.minY), from: left, to: up)
        path.line(to: CGPoint(x: rect.maxX, y: rect.maxY - k))
        corner(CGPoint(x: rect.maxX, y: rect.maxY), from: down, to: left)
        path.line(to: CGPoint(x: rect.minX + k, y: rect.maxY))
        corner(CGPoint(x: rect.minX, y: rect.maxY), from: right, to: down)
        path.close()
        return path
    }
}
