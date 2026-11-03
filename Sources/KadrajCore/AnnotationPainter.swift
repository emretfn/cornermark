import CoreGraphics
import CoreText
import Foundation

/// Paints one annotation into a y-down bitmap context whose user space is source pixels.
enum AnnotationPainter {
    static func paint(_ annotation: Annotation, in ctx: CGContext, assets: AssetStore, sourceBounds: CGRect) {
        let color = annotation.stroke.color
        let width = CGFloat(max(annotation.stroke.width, 0.5))
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.setStrokeColor(color.cgColor)
        ctx.setFillColor(color.cgColor)
        ctx.setLineWidth(width)

        switch annotation.kind {
        case .arrow(let from, let to, let control, let style):
            paintArrow(ArrowShape(from: from, to: to, control: control, style: style, width: annotation.stroke.width), in: ctx)

        case .line(let a, let b):
            ctx.move(to: a)
            ctx.addLine(to: b)
            ctx.strokePath()

        case .rect(let rect, let filled, let radius):
            let r = rect.standardized
            let rr = min(CGFloat(max(radius, 0)), min(r.width, r.height) / 2)
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: rr, cornerHeight: rr, transform: nil))
            if filled { ctx.fillPath() } else { ctx.strokePath() }

        case .ellipse(let rect, let filled):
            ctx.addPath(CGPath(ellipseIn: rect.standardized, transform: nil))
            if filled { ctx.fillPath() } else { ctx.strokePath() }

        case .text(let origin, let string, let fontSize, let style):
            TextLayout(string: string, fontSize: fontSize, style: style).draw(at: origin, color: color, in: ctx)

        case .counter(let center, let number, let radius):
            paintCounter(center: center, number: number, radius: CGFloat(max(radius, 1)), color: color, in: ctx)

        case .pencil(let points):
            ctx.addPath(Smoothing.path(through: points))
            ctx.strokePath()

        case .highlighter(let points):
            ctx.setBlendMode(.multiply)
            ctx.setLineCap(.butt)
            ctx.setStrokeColor(RGBA(color.r, color.g, color.b, min(color.a, 0.5)).cgColor)
            ctx.addPath(Smoothing.path(through: points))
            ctx.strokePath()

        case .blur(let rect, let mode):
            PixelEffects.blur(rect, mode: mode, in: ctx)

        case .pixelate(let rect, let block, let seed):
            PixelEffects.pixelate(rect, blockSize: block, seed: seed, in: ctx)

        case .spotlight(let rect):
            ctx.addRect(sourceBounds)
            ctx.addRect(rect.standardized)
            ctx.setFillColor(CGColor(gray: 0, alpha: 0.55))
            ctx.fillPath(using: .evenOdd)

        case .image(let rect, let asset):
            if let image = assets.image(for: asset) { ctx.drawImageYDown(image, in: rect.standardized) }
        }
    }

    private static func paintArrow(_ shape: ArrowShape, in ctx: CGContext) {
        func polygon(_ pts: [CGPoint]) -> CGPath {
            let p = CGMutablePath()
            p.addLines(between: pts)
            p.closeSubpath()
            return p
        }

        switch shape.style {
        case .classic, .curved:
            if let q = shape.quad {
                ctx.move(to: q.p0)
                ctx.addQuadCurve(to: q.p1, control: q.control)
                ctx.strokePath()
            } else if shape.style == .classic {
                ctx.move(to: shape.from)
                ctx.addLine(to: shape.headBase)
                ctx.strokePath()
            }
            ctx.addPath(polygon(shape.headTriangle))
            ctx.fillPath()

        case .tapered:
            ctx.addPath(polygon(shape.polygon))
            ctx.fillPath()
            let r = max(shape.width * 0.12, 0.5)
            ctx.fillEllipse(in: CGRect(x: shape.from.x - r, y: shape.from.y - r, width: r * 2, height: r * 2))

        case .outline:
            ctx.setLineWidth(max(shape.width * 0.45, 1.5))
            ctx.addPath(polygon(shape.polygon))
            ctx.strokePath()
        }
    }

    private static func paintCounter(center: CGPoint, number: Int, radius: CGFloat, color: RGBA, in ctx: CGContext) {
        ctx.setFillColor(color.cgColor)
        ctx.fillEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))

        let digits = max(String(number).count, 1)
        let fontSize = radius * (digits > 2 ? 0.95 : digits == 2 ? 1.1 : 1.25)
        let layout = TextLayout(string: String(number), fontSize: Double(fontSize), style: .bold)
        let ink = layout.inkBounds()
        ctx.saveGState()
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        ctx.setFillColor(color.contrasting.cgColor)
        // Ink bounds are y-up relative to the baseline; center them on the circle.
        ctx.textPosition = CGPoint(x: center.x - ink.midX, y: center.y + ink.midY)
        CTLineDraw(layout.lines[0], ctx)
        ctx.restoreGState()
    }
}
