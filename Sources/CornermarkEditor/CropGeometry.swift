import CoreGraphics
import Foundation

/// Crop rectangle maths in display canvas pixels, kept free of views so it reads as the rules it is.
enum CropGeometry {
    static let minimumSide: CGFloat = 8

    static func snap(_ value: CGFloat, to targets: [CGFloat], within threshold: CGFloat) -> CGFloat {
        var best = value, bestDistance = threshold
        for t in targets where abs(t - value) <= bestDistance {
            best = t
            bestDistance = abs(t - value)
        }
        return best
    }

    private static func clamp(_ p: CGPoint, to b: CGRect) -> CGPoint {
        CGPoint(x: min(max(p.x, b.minX), b.maxX), y: min(max(p.y, b.minY), b.maxY))
    }

    /// Drags the (x, y) handle of `r` to `p`. Edges snap to the canvas edges and centre lines
    /// within `snap`; with a `ratio` the rect keeps that width / height.
    static func resized(_ r: CGRect, x: Int, y: Int, to raw: CGPoint, ratio: CGFloat?, in bounds: CGRect, snap threshold: CGFloat) -> CGRect {
        var p = clamp(raw, to: bounds)
        if x != 0 { p.x = snap(p.x, to: [bounds.minX, bounds.midX, bounds.maxX], within: threshold) }
        if y != 0 { p.y = snap(p.y, to: [bounds.minY, bounds.midY, bounds.maxY], within: threshold) }

        guard let ratio, ratio > 0 else {
            var x0 = r.minX, x1 = r.maxX, y0 = r.minY, y1 = r.maxY
            if x < 0 { x0 = p.x } else if x > 0 { x1 = p.x }
            if y < 0 { y0 = p.y } else if y > 0 { y1 = p.y }
            return CGRect(x: min(x0, x1), y: min(y0, y1), width: max(abs(x1 - x0), minimumSide), height: max(abs(y1 - y0), minimumSide))
                .intersection(bounds)
        }

        let anchor = CGPoint(x: x < 0 ? r.maxX : r.minX, y: y < 0 ? r.maxY : r.minY)
        var w: CGFloat, h: CGFloat
        if x != 0, y != 0 {
            w = abs(p.x - anchor.x); h = abs(p.y - anchor.y)
            if w / max(h, 0.0001) > ratio { h = w / ratio } else { w = h * ratio }
            let sx: CGFloat = p.x < anchor.x ? -1 : 1, sy: CGFloat = p.y < anchor.y ? -1 : 1
            let room = CGSize(width: sx < 0 ? anchor.x - bounds.minX : bounds.maxX - anchor.x,
                              height: sy < 0 ? anchor.y - bounds.minY : bounds.maxY - anchor.y)
            let k = min(1, room.width / max(w, 0.0001), room.height / max(h, 0.0001))
            w = max(w * k, minimumSide); h = w / ratio
            let end = CGPoint(x: anchor.x + sx * w, y: anchor.y + sy * h)
            return CGRect(x: min(anchor.x, end.x), y: min(anchor.y, end.y), width: w, height: h)
        }
        if x != 0 {
            w = abs(p.x - anchor.x)
            let sx: CGFloat = p.x < anchor.x ? -1 : 1
            let roomW = sx < 0 ? anchor.x - bounds.minX : bounds.maxX - anchor.x
            let roomH = 2 * min(r.midY - bounds.minY, bounds.maxY - r.midY)
            w = max(min(w, roomW, roomH * ratio), minimumSide); h = w / ratio
            let end = anchor.x + sx * w
            return CGRect(x: min(anchor.x, end), y: r.midY - h / 2, width: w, height: h)
        }
        h = abs(p.y - anchor.y)
        let sy: CGFloat = p.y < anchor.y ? -1 : 1
        let roomH = sy < 0 ? anchor.y - bounds.minY : bounds.maxY - anchor.y
        let roomW = 2 * min(r.midX - bounds.minX, bounds.maxX - r.midX)
        h = max(min(h, roomH, roomW / ratio), minimumSide); w = h * ratio
        let end = anchor.y + sy * h
        return CGRect(x: r.midX - w / 2, y: min(anchor.y, end), width: w, height: h)
    }

    /// Slides `r` by `delta`, staying inside `bounds` and snapping its edges and centre to the canvas.
    static func moved(_ r: CGRect, by delta: CGPoint, in bounds: CGRect, snap threshold: CGFloat) -> CGRect {
        var o = CGPoint(x: r.minX + delta.x, y: r.minY + delta.y)
        o.x = min(max(o.x, bounds.minX), bounds.maxX - r.width)
        o.y = min(max(o.y, bounds.minY), bounds.maxY - r.height)
        let xs = [bounds.minX, bounds.midX - r.width / 2, bounds.maxX - r.width]
        let ys = [bounds.minY, bounds.midY - r.height / 2, bounds.maxY - r.height]
        o.x = snap(o.x, to: xs, within: threshold)
        o.y = snap(o.y, to: ys, within: threshold)
        return CGRect(origin: o, size: r.size)
    }

    /// The largest rect of `ratio` that fits inside `r`, centred on it.
    static func conformed(_ r: CGRect, to ratio: CGFloat) -> CGRect {
        guard ratio > 0, r.height > 0 else { return r }
        var w = r.width, h = r.height
        if w / h > ratio { w = h * ratio } else { h = w / ratio }
        return CGRect(x: r.midX - w / 2, y: r.midY - h / 2, width: w, height: h)
    }
}
