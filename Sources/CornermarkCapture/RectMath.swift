import CoreGraphics

/// Geometry for selections. Everything is global AppKit points (y up) and snaps to the owning
/// display's pixel grid, so a selection always maps to whole pixels of the frozen image.
enum RectMath {
    static func snap(_ v: CGFloat, _ scale: CGFloat) -> CGFloat { (v * scale).rounded() / scale }

    static func clamp(_ p: CGPoint, _ b: CGRect) -> CGPoint {
        CGPoint(x: min(max(p.x, b.minX), b.maxX), y: min(max(p.y, b.minY), b.maxY))
    }

    static func snap(_ p: CGPoint, scale: CGFloat, in b: CGRect) -> CGPoint {
        clamp(CGPoint(x: snap(p.x, scale), y: snap(p.y, scale)), b)
    }

    /// Rect spanned by `anchor` and `point`; with `ratio` (width / height) the larger demand wins
    /// and the result is shrunk until it fits `bounds`.
    static func make(anchor: CGPoint, to point: CGPoint, ratio: CGFloat?, bounds: CGRect, scale: CGFloat) -> CGRect {
        let dx = point.x - anchor.x, dy = point.y - anchor.y
        let sx: CGFloat = dx < 0 ? -1 : 1, sy: CGFloat = dy < 0 ? -1 : 1
        let maxW = sx > 0 ? bounds.maxX - anchor.x : anchor.x - bounds.minX
        let maxH = sy > 0 ? bounds.maxY - anchor.y : anchor.y - bounds.minY
        var w = abs(dx), h = abs(dy)
        if let ratio {
            w = max(w, h * ratio)
            h = w / ratio
            if w > maxW { w = maxW; h = w / ratio }
            if h > maxH { h = maxH; w = h * ratio }
        } else {
            w = min(w, maxW); h = min(h, maxH)
        }
        w = min(snap(w, scale), maxW); h = min(snap(h, scale), maxH)
        return CGRect(x: sx > 0 ? anchor.x : anchor.x - w, y: sy > 0 ? anchor.y : anchor.y - h, width: w, height: h)
    }

    /// Rect centred on `c` that reaches `point`, so it grows both ways. With `ratio` the larger demand wins, and it shrinks
    /// until it fits `bounds` without moving its centre.
    static func centered(on c: CGPoint, to point: CGPoint, ratio: CGFloat?, bounds: CGRect, scale: CGFloat) -> CGRect {
        let maxW = 2 * max(0, min(c.x - bounds.minX, bounds.maxX - c.x))
        let maxH = 2 * max(0, min(c.y - bounds.minY, bounds.maxY - c.y))
        var w = 2 * abs(point.x - c.x), h = 2 * abs(point.y - c.y)
        if let ratio {
            w = max(w, h * ratio)
            h = w / ratio
            if w > maxW { w = maxW; h = w / ratio }
            if h > maxH { h = maxH; w = h * ratio }
        } else {
            w = min(w, maxW); h = min(h, maxH)
        }
        w = snap(w, scale); h = snap(h, scale)
        return fit(CGRect(x: snap(c.x - w / 2, scale), y: snap(c.y - h / 2, scale), width: w, height: h), in: bounds)
    }

    /// A handle dragged with Option: the opposite side moves the same amount, so the centre stays put.
    static func resizeCentered(_ o: CGRect, handle: Handle, to raw: CGPoint, ratio: CGFloat?, bounds: CGRect, scale: CGFloat) -> CGRect {
        let c = CGPoint(x: o.midX, y: o.midY)
        let (hx, hy) = handle.axes
        var p = clamp(raw, bounds)
        // An edge handle drives one axis. The other keeps its size, or follows the ratio.
        if hx == 0 { p.x = ratio.map { c.x + abs(p.y - c.y) * $0 } ?? o.maxX }
        if hy == 0 { p.y = ratio.map { c.y + abs(p.x - c.x) / $0 } ?? o.maxY }
        let r = centered(on: c, to: p, ratio: ratio, bounds: bounds, scale: scale)
        let minSide = 1 / scale
        return CGRect(x: r.minX, y: r.minY, width: max(minSide, r.width), height: max(minSide, r.height))
    }

    static func resize(_ o: CGRect, handle: Handle, to raw: CGPoint, ratio: CGFloat?, bounds: CGRect, scale: CGFloat) -> CGRect {
        let p = clamp(raw, bounds)
        let (hx, hy) = handle.axes
        let minSide = 1 / scale

        if hx != 0 && hy != 0 {
            let anchor = CGPoint(x: hx > 0 ? o.minX : o.maxX, y: hy > 0 ? o.minY : o.maxY)
            return ensureMin(make(anchor: anchor, to: p, ratio: ratio, bounds: bounds, scale: scale), minSide, anchor: anchor)
        }

        guard let ratio else {
            var x0 = o.minX, x1 = o.maxX, y0 = o.minY, y1 = o.maxY
            if hx > 0 { x1 = p.x } else if hx < 0 { x0 = p.x }
            if hy > 0 { y1 = p.y } else if hy < 0 { y0 = p.y }
            let r = CGRect(x: min(x0, x1), y: min(y0, y1), width: abs(x1 - x0), height: abs(y1 - y0))
            return CGRect(x: snap(r.minX, scale), y: snap(r.minY, scale),
                          width: max(minSide, snap(r.width, scale)), height: max(minSide, snap(r.height, scale)))
        }

        var w: CGFloat, h: CGFloat
        if hx != 0 {
            let fixed = hx > 0 ? o.minX : o.maxX
            w = min(abs(p.x - fixed), hx > 0 ? bounds.maxX - fixed : fixed - bounds.minX)
            h = w / ratio
            let maxH = 2 * min(o.midY - bounds.minY, bounds.maxY - o.midY)
            if h > maxH { h = maxH; w = h * ratio }
            w = max(minSide, snap(w, scale)); h = max(minSide, snap(h, scale))
            return CGRect(x: hx > 0 ? fixed : fixed - w, y: snap(o.midY - h / 2, scale), width: w, height: h)
        }
        let fixed = hy > 0 ? o.minY : o.maxY
        h = min(abs(p.y - fixed), hy > 0 ? bounds.maxY - fixed : fixed - bounds.minY)
        w = h * ratio
        let maxW = 2 * min(o.midX - bounds.minX, bounds.maxX - o.midX)
        if w > maxW { w = maxW; h = w / ratio }
        w = max(minSide, snap(w, scale)); h = max(minSide, snap(h, scale))
        return CGRect(x: snap(o.midX - w / 2, scale), y: hy > 0 ? fixed : fixed - h, width: w, height: h)
    }

    private static func ensureMin(_ r: CGRect, _ minSide: CGFloat, anchor: CGPoint) -> CGRect {
        let w = max(r.width, minSide), h = max(r.height, minSide)
        return CGRect(x: abs(r.minX - anchor.x) < 1e-6 ? anchor.x : anchor.x - w,
                      y: abs(r.minY - anchor.y) < 1e-6 ? anchor.y : anchor.y - h,
                      width: w, height: h)
    }

    /// Translated (and, if larger than `bounds`, shrunk keeping its aspect) to lie inside `bounds`.
    static func fit(_ r: CGRect, in b: CGRect) -> CGRect {
        var out = r
        if out.width > b.width || out.height > b.height {
            let k = min(b.width / out.width, b.height / out.height)
            out.size = CGSize(width: out.width * k, height: out.height * k)
        }
        out.origin.x = min(max(out.minX, b.minX), b.maxX - out.width)
        out.origin.y = min(max(out.minY, b.minY), b.maxY - out.height)
        return out
    }

    /// New size with the top-left corner pinned, as a typed size field implies.
    static func sized(_ r: CGRect, width: CGFloat?, height: CGFloat?, ratio: CGFloat?, bounds: CGRect, scale: CGFloat) -> CGRect {
        var w = width ?? r.width, h = height ?? r.height
        if let ratio {
            if width != nil { h = w / ratio } else if height != nil { w = h * ratio }
        }
        w = max(1 / scale, w); h = max(1 / scale, h)
        if ratio != nil {
            let k = min(1, bounds.width / w, bounds.height / h)
            w *= k; h *= k
        } else {
            w = min(w, bounds.width); h = min(h, bounds.height)
        }
        return fit(CGRect(x: r.minX, y: r.maxY - snap(h, scale), width: snap(w, scale), height: snap(h, scale)), in: bounds)
    }
}
