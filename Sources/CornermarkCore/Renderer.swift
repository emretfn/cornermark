import CoreGraphics
import Foundation

/// Where everything lands. One value drives both display and export, so a click mapped through
/// `canvasToSource` hits the exact source pixel that `render` painted at that spot.
public struct RenderPlan: Sendable {
    /// Effective crop in source pixels: integral, inside the image, with auto-balance applied.
    public let cropRect: CGRect
    /// Size of the cropped, flipped and rotated content before background and output scale.
    public let contentSize: CGSize
    public let canvasSize: CGSize
    /// Source pixel (y-down) to canvas pixel (y-down).
    public let sourceToCanvas: CGAffineTransform
    public let canvasToSource: CGAffineTransform
    /// Where the content, background excluded, sits on the canvas.
    public let contentRect: CGRect
    /// Corner radius and shadow metrics in canvas pixels.
    let cornerRadius: CGFloat
    let canvasScale: CGSize
}

public enum Renderer {
    // MARK: Layout

    /// `assets` is only needed for `BackgroundStyle.autoBalance`, which has to look at pixels.
    /// Without it, auto-balance is skipped.
    public static func plan(_ doc: Document, assets: AssetStore? = nil) -> RenderPlan {
        let source = doc.sourceBounds
        var crop = doc.crop.map { $0.integralClamped(to: source) } ?? source
        if crop.isNull || crop.width < 1 || crop.height < 1 { crop = source }

        if let style = doc.background, style.autoBalance, let assets, let base = assets.image(for: doc.base) {
            let key = "\(doc.base)|\(crop.minX),\(crop.minY),\(crop.width),\(crop.height)"
            crop = assets.cachedMargin(key: key) { AutoBalance.balancedCrop(of: base, crop: crop) }
        }

        let w = crop.width, h = crop.height
        let turns = ((doc.geometry.quarterTurns % 4) + 4) % 4

        var t = CGAffineTransform(translationX: -crop.minX, y: -crop.minY)
        if doc.geometry.flipH { t = t.concatenating(CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: w, ty: 0)) }
        if doc.geometry.flipV { t = t.concatenating(CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: h)) }
        switch turns {
        case 1: t = t.concatenating(CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: h, ty: 0))
        case 2: t = t.concatenating(CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: w, ty: h))
        case 3: t = t.concatenating(CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: w))
        default: break
        }
        let content = turns % 2 == 1 ? CGSize(width: h, height: w) : CGSize(width: w, height: h)

        var layout = content
        var origin = CGPoint.zero
        var radius: CGFloat = 0
        if let style = doc.background {
            let pad = CGFloat(max(style.padding, 0))
            var lw = content.width + pad * 2, lh = content.height + pad * 2
            if let ratio = style.aspectRatio, ratio.isFinite, ratio > 0 {
                if lw / lh < ratio { lw = lh * ratio } else { lh = lw / ratio }
            }
            lw = ceil(lw); lh = ceil(lh)
            layout = CGSize(width: lw, height: lh)
            let cx = ((lw - content.width) / 2).rounded(), cy = ((lh - content.height) / 2).rounded()
            switch style.alignment {
            case .center: origin = CGPoint(x: cx, y: cy)
            case .top: origin = CGPoint(x: cx, y: pad.rounded())
            case .bottom: origin = CGPoint(x: cx, y: lh - pad.rounded() - content.height)
            case .left: origin = CGPoint(x: pad.rounded(), y: cy)
            case .right: origin = CGPoint(x: lw - pad.rounded() - content.width, y: cy)
            }
            radius = CGFloat(max(style.cornerRadius, 0))
        }

        let scale = CGFloat(min(max(doc.outputScale.isFinite ? doc.outputScale : 1, Document.outputScaleRange.lowerBound), Document.outputScaleRange.upperBound))
        let canvas = CGSize(width: max(1, (layout.width * scale).rounded()), height: max(1, (layout.height * scale).rounded()))
        // Rounding the canvas can leave a sub-pixel gap; stretch by the exact ratio so content fills it.
        let sx = canvas.width / layout.width, sy = canvas.height / layout.height

        let full = t
            .concatenating(CGAffineTransform(translationX: origin.x, y: origin.y))
            .concatenating(CGAffineTransform(scaleX: sx, y: sy))
        let contentRect = CGRect(origin: origin, size: content).applying(CGAffineTransform(scaleX: sx, y: sy))

        return RenderPlan(cropRect: crop, contentSize: content, canvasSize: canvas,
                          sourceToCanvas: full, canvasToSource: full.inverted(),
                          contentRect: contentRect, cornerRadius: radius * min(sx, sy), canvasScale: CGSize(width: sx, height: sy))
    }

    public static func canvasSize(_ doc: Document, assets: AssetStore? = nil) -> CGSize {
        plan(doc, assets: assets).canvasSize
    }

    public static func sourceToCanvas(_ doc: Document, assets: AssetStore? = nil) -> CGAffineTransform {
        plan(doc, assets: assets).sourceToCanvas
    }

    public static func canvasToSource(_ doc: Document, assets: AssetStore? = nil) -> CGAffineTransform {
        plan(doc, assets: assets).canvasToSource
    }

    // MARK: Rendering

    /// Base image plus annotations in source pixel space (y-down), nothing else applied.
    /// Redaction annotations read the pixels composited before them.
    public static func sourceComposite(_ doc: Document, assets: AssetStore, excluding: UUID? = nil) -> CGImage? {
        let w = Int(doc.pixelSize.width.rounded()), h = Int(doc.pixelSize.height.rounded())
        guard let ctx = Bitmap.makeContext(width: w, height: h, yDown: true) else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: w, height: h)
        ctx.interpolationQuality = .none
        if let base = assets.image(for: doc.base) { ctx.drawImageYDown(base, in: bounds) }
        ctx.interpolationQuality = .high
        for annotation in doc.annotations where annotation.id != excluding {
            AnnotationPainter.paint(annotation, in: ctx, assets: assets, sourceBounds: bounds)
        }
        return ctx.makeImage()
    }

    public static func render(_ doc: Document, assets: AssetStore) -> CGImage {
        let plan = plan(doc, assets: assets)
        guard let ctx = Bitmap.makeContext(width: Int(plan.canvasSize.width), height: Int(plan.canvasSize.height), yDown: true) else {
            return Bitmap.blankImage()
        }
        paint(doc, assets: assets, plan: plan, composite: nil, excluding: nil, in: ctx)
        return ctx.makeImage() ?? Bitmap.blankImage()
    }

    /// Paints the finished canvas into `ctx`, which must span `canvasSize(doc)` canvas pixels
    /// from its origin (apply any zoom to the CTM first). `render` goes through the same code.
    /// Pass a `composite` from `sourceComposite` to reuse it across frames while only the
    /// geometry, crop or background changes.
    public static func draw(_ doc: Document, assets: AssetStore, in ctx: CGContext, excluding: UUID? = nil,
                            yDown: Bool = true, composite: CGImage? = nil) {
        let plan = plan(doc, assets: assets)
        ctx.saveGState()
        if !yDown {
            ctx.translateBy(x: 0, y: plan.canvasSize.height)
            ctx.scaleBy(x: 1, y: -1)
        }
        paint(doc, assets: assets, plan: plan, composite: composite, excluding: excluding, in: ctx)
        ctx.restoreGState()
    }

    private static func paint(_ doc: Document, assets: AssetStore, plan: RenderPlan, composite: CGImage?,
                              excluding: UUID?, in ctx: CGContext) {
        let canvas = CGRect(origin: .zero, size: plan.canvasSize)
        if let style = doc.background {
            BackgroundPainter.fill(style.fill, rect: canvas, in: ctx, assets: assets)
        }
        guard let composite = composite ?? sourceComposite(doc, assets: assets, excluding: excluding) else { return }

        let rect = plan.contentRect
        let radius = min(plan.cornerRadius, min(rect.width, rect.height) / 2)
        let t = plan.sourceToCanvas
        let unity = abs(t.a) + abs(t.d) + abs(t.b) + abs(t.c)
        let exact = abs(unity - 2) < 1e-9 && t.tx.rounded() == t.tx && t.ty.rounded() == t.ty
            && abs(abs(t.a * t.d - t.b * t.c) - 1) < 1e-9

        func drawContent() {
            ctx.saveGState()
            ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
            ctx.clip()
            ctx.concatenate(t)
            ctx.interpolationQuality = exact ? .none : .high
            ctx.drawImageYDown(composite, in: CGRect(origin: .zero, size: doc.pixelSize))
            ctx.restoreGState()
        }

        if doc.background?.shadow == true {
            let k = min(plan.canvasScale.width, plan.canvasScale.height)
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -14 * k), blur: 28 * k, color: CGColor(gray: 0, alpha: 0.38))
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            drawContent()
            ctx.endTransparencyLayer()
            ctx.restoreGState()
        } else {
            drawContent()
        }
    }
}
