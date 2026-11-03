import CoreGraphics

/// Where a selection may live: the bounding union of its displays' frames, in global AppKit points.
/// A selection confined to one display is a space with one display, so clamping never special-cases it.
public struct SelectionSpace: Hashable {
    public let displays: [DisplayGeometry]
    public let bounds: CGRect

    public init(displays: [DisplayGeometry]) {
        self.displays = displays
        bounds = displays.dropFirst().reduce(displays.first?.frame ?? .zero) { $0.union($1.frame) }
    }

    public func confined(to display: DisplayGeometry) -> SelectionSpace { SelectionSpace(displays: [display]) }

    /// The display holding `p`, else the nearest one.
    public func display(at p: CGPoint) -> DisplayGeometry? {
        displays.first { $0.frame.contains(p) }
            ?? displays.min { distance(p, to: $0.frame) < distance(p, to: $1.frame) }
    }

    /// The display the selection mostly lies on; `cursor` breaks an exact tie. This is the one place that decides
    /// which display carries single-instance chrome (size badge, toolbar) for a selection that spans several.
    public func dominant(for rect: CGRect, preferring cursor: CGPoint? = nil) -> DisplayGeometry? {
        func key(_ d: DisplayGeometry) -> (CGFloat, Bool) {
            let o = d.frame.intersection(rect)
            return (o.isEmpty ? 0 : o.width * o.height, cursor.map { d.frame.contains($0) } ?? false)
        }
        let best = displays.max { a, b in
            let ka = key(a), kb = key(b)
            return ka.0 != kb.0 ? ka.0 < kb.0 : (!ka.1 && kb.1)
        }
        guard let best, key(best).0 > 0 else { return display(at: CGPoint(x: rect.midX, y: rect.midY)) }
        return best
    }

    func scale(at p: CGPoint) -> CGFloat { CGFloat(display(at: RectMath.clamp(p, bounds))?.scale ?? 1) }

    /// Finest scale among the displays `rect` covers; a selection snaps to what its sharpest part can resolve.
    func maxScale(intersecting rect: CGRect) -> CGFloat {
        let covered = displays.filter { !$0.frame.intersection(rect).isEmpty }.map(\.scale)
        return CGFloat(covered.max() ?? display(at: CGPoint(x: rect.midX, y: rect.midY))?.scale ?? 1)
    }

    /// Clamped into the space, then snapped to the pixel grid of the display it lands on.
    func snap(_ p: CGPoint) -> CGPoint {
        RectMath.snap(p, scale: scale(at: p), in: bounds)
    }

    private func distance(_ p: CGPoint, to r: CGRect) -> CGFloat {
        let q = RectMath.clamp(p, r)
        return hypot(p.x - q.x, p.y - q.y)
    }
}
