import CoreGraphics

/// The edges a recording's selection pulls towards: every display edge and every window edge. A window edge pulls only
/// alongside the window, so a selection far above it never jumps to its line.
struct EdgeSnap {
    static let reach: CGFloat = 8

    let frames: [CGRect]

    /// `p` with each coordinate moved onto the nearest edge within reach.
    func snapped(_ p: CGPoint) -> CGPoint {
        var x = p.x, y = p.y
        var bestX = Self.reach, bestY = Self.reach
        for f in frames {
            if p.y >= f.minY - Self.reach && p.y <= f.maxY + Self.reach {
                for line in [f.minX, f.maxX] where abs(line - p.x) <= bestX { bestX = abs(line - p.x); x = line }
            }
            if p.x >= f.minX - Self.reach && p.x <= f.maxX + Self.reach {
                for line in [f.minY, f.maxY] where abs(line - p.y) <= bestY { bestY = abs(line - p.y); y = line }
            }
        }
        return CGPoint(x: x, y: y)
    }

    /// The smallest shift that lands one of a moved rect's edges on an edge within reach, per axis.
    func offset(for r: CGRect) -> CGVector {
        var dx: CGFloat = 0, dy: CGFloat = 0
        var bestX = Self.reach + 1, bestY = Self.reach + 1
        for f in frames {
            if r.maxY >= f.minY - Self.reach && r.minY <= f.maxY + Self.reach {
                for line in [f.minX, f.maxX] {
                    for edge in [r.minX, r.maxX] where abs(line - edge) <= Self.reach && abs(line - edge) < bestX {
                        bestX = abs(line - edge); dx = line - edge
                    }
                }
            }
            if r.maxX >= f.minX - Self.reach && r.minX <= f.maxX + Self.reach {
                for line in [f.minY, f.maxY] {
                    for edge in [r.minY, r.maxY] where abs(line - edge) <= Self.reach && abs(line - edge) < bestY {
                        bestY = abs(line - edge); dy = line - edge
                    }
                }
            }
        }
        return CGVector(dx: dx, dy: dy)
    }
}
