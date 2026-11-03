import CoreGraphics
import Foundation
import CornermarkCore

/// A draggable control point on a selected annotation, in source pixels.
struct Handle: Equatable {
    enum Kind: Equatable {
        case edge(x: Int, y: Int)   // -1 / 0 / 1 per axis; (±1, ±1) is a corner
        case endpoint(Int)          // 0 = arrow/line start, 1 = end
        case control                // curved-arrow bend
        case radius                 // counter size
    }
    var kind: Kind
    var position: CGPoint
}

private func defaultControl(from: CGPoint, to: CGPoint) -> CGPoint {
    from.lerp(to: to, 0.5) + (to - from).perpendicular.normalized() * (from.distance(to: to) * 0.25)
}

extension Annotation {
    /// The rectangle that resize handles act on, for kinds that are a plain rect.
    var resizableRect: CGRect? {
        switch kind {
        case .rect(let r, _, _), .ellipse(let r, _), .blur(let r, _), .pixelate(let r, _, _), .spotlight(let r), .image(let r, _):
            return r.standardized
        default:
            return nil
        }
    }

    var handles: [Handle] {
        if let r = resizableRect {
            return (-1...1).flatMap { y in (-1...1).compactMap { x -> Handle? in
                guard x != 0 || y != 0 else { return nil }
                return Handle(kind: .edge(x: x, y: y),
                              position: CGPoint(x: r.midX + CGFloat(x) * r.width / 2, y: r.midY + CGFloat(y) * r.height / 2))
            } }
        }
        switch kind {
        case .line(let a, let b):
            return [Handle(kind: .endpoint(0), position: a), Handle(kind: .endpoint(1), position: b)]
        case .arrow(let a, let b, let control, let style):
            var out = [Handle(kind: .endpoint(0), position: a), Handle(kind: .endpoint(1), position: b)]
            if style == .curved { out.append(Handle(kind: .control, position: control ?? defaultControl(from: a, to: b))) }
            return out
        case .counter(let c, _, let radius):
            return [Handle(kind: .radius, position: CGPoint(x: c.x + CGFloat(radius), y: c.y))]
        default:
            return []
        }
    }

    /// The annotation after dragging `handle` to `p`. `constrain` is Shift: 45-degree steps for line
    /// ends, preserved aspect for rects. Images always keep their aspect when dragged by a corner.
    func dragging(_ handle: Handle.Kind, to p: CGPoint, constrain: Bool) -> Annotation {
        var copy = self
        switch (kind, handle) {
        case (.line(let a, let b), .endpoint(let i)):
            let moved = Self.constrained(anchor: i == 0 ? b : a, to: p, constrain)
            copy.kind = i == 0 ? .line(from: moved, to: b) : .line(from: a, to: moved)
        case (.arrow(let a, let b, let c, let s), .endpoint(let i)):
            let moved = Self.constrained(anchor: i == 0 ? b : a, to: p, constrain)
            copy.kind = i == 0 ? .arrow(from: moved, to: b, control: c, style: s) : .arrow(from: a, to: moved, control: c, style: s)
        case (.arrow(let a, let b, _, let s), .control):
            copy.kind = .arrow(from: a, to: b, control: p, style: s)
        case (.counter(let c, let n, _), .radius):
            copy.kind = .counter(center: c, number: n, radius: max(6, Double(c.distance(to: p))))
        case (_, .edge(let x, let y)):
            guard let r = resizableRect else { break }
            let isImage: Bool = { if case .image = kind { return true } else { return false } }()
            let resized = Self.resize(r, x: x, y: y, to: p, keepAspect: (constrain || isImage) && x != 0 && y != 0)
            copy.kind = Self.replacingRect(kind, with: resized)
        default:
            break
        }
        return copy
    }

    private static func constrained(anchor: CGPoint, to p: CGPoint, _ on: Bool) -> CGPoint {
        guard on else { return p }
        let d = p - anchor, len = d.length
        guard len > 0 else { return p }
        let step = CGFloat.pi / 4
        let angle = (atan2(d.y, d.x) / step).rounded() * step
        return CGPoint(x: anchor.x + cos(angle) * len, y: anchor.y + sin(angle) * len)
    }

    static func resize(_ r: CGRect, x: Int, y: Int, to p: CGPoint, keepAspect: Bool) -> CGRect {
        if keepAspect, r.width > 0, r.height > 0 {
            let anchor = CGPoint(x: x < 0 ? r.maxX : r.minX, y: y < 0 ? r.maxY : r.minY)
            let dx = p.x - anchor.x, dy = p.y - anchor.y
            let k = max(abs(dx) / r.width, abs(dy) / r.height)
            let end = CGPoint(x: anchor.x + (dx < 0 ? -1 : 1) * r.width * k, y: anchor.y + (dy < 0 ? -1 : 1) * r.height * k)
            return CGRect(x: min(anchor.x, end.x), y: min(anchor.y, end.y), width: abs(end.x - anchor.x), height: abs(end.y - anchor.y))
        }
        var x0 = r.minX, x1 = r.maxX, y0 = r.minY, y1 = r.maxY
        if x < 0 { x0 = p.x } else if x > 0 { x1 = p.x }
        if y < 0 { y0 = p.y } else if y > 0 { y1 = p.y }
        return CGRect(x: min(x0, x1), y: min(y0, y1), width: abs(x1 - x0), height: abs(y1 - y0))
    }

    private static func replacingRect(_ kind: AnnotationKind, with r: CGRect) -> AnnotationKind {
        switch kind {
        case .rect(_, let f, let c): return .rect(r, filled: f, cornerRadius: c)
        case .ellipse(_, let f): return .ellipse(r, filled: f)
        case .blur(_, let m): return .blur(r, mode: m)
        case .pixelate(_, let b, let s): return .pixelate(r, blockSize: b, seed: s)
        case .spotlight: return .spotlight(r)
        case .image(_, let a): return .image(r, asset: a)
        default: return kind
        }
    }

    /// Re-applies the style controls a tool exposes onto an existing annotation.
    func restyled(_ s: ToolStyle) -> Annotation {
        var copy = self
        copy.stroke = s.stroke
        switch kind {
        case .arrow(let a, let b, let c, _): copy.kind = .arrow(from: a, to: b, control: c, style: s.arrowStyle)
        case .text(let o, let str, _, _): copy.kind = .text(origin: o, string: str, fontSize: s.fontSize, style: s.textStyle)
        case .counter(let c, let n, _): copy.kind = .counter(center: c, number: n, radius: max(8, s.width * 2.5))
        case .blur(let r, _): copy.kind = .blur(r, mode: s.blurMode)
        case .pixelate(let r, _, let seed): copy.kind = .pixelate(r, blockSize: s.pixelBlock, seed: seed)
        default: break
        }
        return copy
    }

    /// The style a selected annotation reports back to the property bar.
    func style(base: ToolStyle) -> ToolStyle {
        var s = base
        s.color = stroke.color
        s.width = stroke.width
        switch kind {
        case .arrow(_, _, _, let st): s.arrowStyle = st
        case .text(_, _, let size, let st): s.fontSize = size; s.textStyle = st
        case .counter(_, _, let r): s.width = r / 2.5
        case .blur(_, let m): s.blurMode = m
        case .pixelate(_, let b, _): s.pixelBlock = b
        default: break
        }
        return s
    }
}
