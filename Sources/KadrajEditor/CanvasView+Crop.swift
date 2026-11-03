import AppKit
import KadrajCore

extension CanvasView {
    private var cropBounds: CGRect { CGRect(origin: .zero, size: plan.canvasSize) }

    /// The draft in display canvas pixels.
    var cropDisplayRect: CGRect? {
        model.cropDraft.map { $0.rect.applying(plan.sourceToCanvas).standardized }
    }

    private var cropRatio: CGFloat? {
        model.cropDraft?.aspect.ratio(original: plan.canvasSize)
    }

    private func cropHandlePoints(_ r: CGRect) -> [(x: Int, y: Int, p: CGPoint)] {
        (-1...1).flatMap { y in (-1...1).compactMap { x -> (Int, Int, CGPoint)? in
            guard x != 0 || y != 0 else { return nil }
            return (x, y, CGPoint(x: r.midX + CGFloat(x) * r.width / 2, y: r.midY + CGFloat(y) * r.height / 2))
        } }
    }

    func pressCrop(_ v: CGPoint) {
        guard let rect = cropDisplayRect else { return }
        let c = canvasPoint(v)
        let reach = 10 / max(magnification, 0.01)
        if let h = cropHandlePoints(rect).first(where: { $0.p.distance(to: c) <= reach }) {
            gesture = .cropping(.resize(x: h.x, y: h.y, original: rect))
        } else if rect.contains(c) {
            gesture = .cropping(.move(grab: c, original: rect))
        } else {
            gesture = .cropping(.fresh(anchor: CGPoint(x: min(max(c.x, 0), cropBounds.maxX), y: min(max(c.y, 0), cropBounds.maxY))))
        }
    }

    func dragCrop(_ drag: Gesture.CropDrag, to v: CGPoint, shift: Bool) {
        let c = canvasPoint(v)
        let snap = 8 / max(magnification, 0.01)
        var ratio = cropRatio
        if shift, ratio == nil { ratio = 1 }

        let display: CGRect
        switch drag {
        case .resize(let x, let y, let original):
            display = CropGeometry.resized(original, x: x, y: y, to: c, ratio: ratio, in: cropBounds, snap: snap)
        case .move(let grab, let original):
            display = CropGeometry.moved(original, by: c - grab, in: cropBounds, snap: snap)
        case .fresh(let anchor):
            let zero = CGRect(origin: anchor, size: .zero)
            display = CropGeometry.resized(zero, x: c.x >= anchor.x ? 1 : -1, y: c.y >= anchor.y ? 1 : -1,
                                           to: c, ratio: ratio, in: cropBounds, snap: snap)
        }
        guard var draft = model.cropDraft else { return }
        draft.rect = display.applying(plan.canvasToSource).standardized
        model.setCropDraft(draft)
    }

    /// Re-shapes the draft to `aspect`, shrinking it around its centre.
    func setCropAspect(_ aspect: CropAspect) {
        guard var draft = model.cropDraft, let display = cropDisplayRect else { return }
        draft.aspect = aspect
        if let ratio = aspect.ratio(original: plan.canvasSize) {
            draft.rect = CropGeometry.conformed(display, to: ratio).applying(plan.canvasToSource).standardized
        }
        model.setCropDraft(draft)
    }

    func drawCrop(_ ctx: CGContext) {
        guard cropEditing, let rect = cropDisplayRect else { return }
        let mag = max(magnification, 0.01)
        let m = Self.margin
        let page = cropBounds.offsetBy(dx: m, dy: m)
        let box = rect.offsetBy(dx: m, dy: m)

        ctx.saveGState()
        ctx.addRect(page)
        ctx.addRect(box)
        ctx.setFillColor(CGColor(gray: 0, alpha: 0.55))
        ctx.fillPath(using: .evenOdd)

        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.35))
        ctx.setLineWidth(1 / mag)
        for i in 1...2 {
            let f = CGFloat(i) / 3
            ctx.move(to: CGPoint(x: box.minX + box.width * f, y: box.minY)); ctx.addLine(to: CGPoint(x: box.minX + box.width * f, y: box.maxY))
            ctx.move(to: CGPoint(x: box.minX, y: box.minY + box.height * f)); ctx.addLine(to: CGPoint(x: box.maxX, y: box.minY + box.height * f))
        }
        ctx.strokePath()

        ctx.setStrokeColor(CGColor(gray: 1, alpha: 1))
        ctx.setLineWidth(1.5 / mag)
        ctx.stroke(box)

        let size = 10 / mag
        for h in cropHandlePoints(box) {
            let handle = CGRect(x: h.p.x - size / 2, y: h.p.y - size / 2, width: size, height: size)
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fill(handle)
            ctx.setStrokeColor(CGColor(gray: 0.25, alpha: 1))
            ctx.setLineWidth(1 / mag)
            ctx.stroke(handle)
        }

        if let draft = model.cropDraft {
            let label = "\(Int(draft.rect.width.rounded())) × \(Int(draft.rect.height.rounded()))" as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11 / mag, weight: .medium),
                .foregroundColor: NSColor.white,
            ]
            let textSize = label.size(withAttributes: attrs)
            let pill = CGRect(x: box.midX - textSize.width / 2 - 6 / mag, y: box.maxY + 8 / mag,
                              width: textSize.width + 12 / mag, height: textSize.height + 4 / mag)
            let pillRect = pill.maxY > page.maxY + 30 / mag ? pill.offsetBy(dx: 0, dy: -(pill.height + 16 / mag)) : pill
            NSColor.black.withAlphaComponent(0.7).setFill()
            NSBezierPath(roundedRect: pillRect, xRadius: pillRect.height / 2, yRadius: pillRect.height / 2).fill()
            label.draw(at: CGPoint(x: pillRect.minX + 6 / mag, y: pillRect.minY + 2 / mag), withAttributes: attrs)
        }
        ctx.restoreGState()
    }
}
