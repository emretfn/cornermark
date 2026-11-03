import AppKit
import KadrajDesign
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

    private var isCropDragging: Bool {
        if case .cropping = gesture { return true }
        return false
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
        ctx.setFillColor(DS.Color.bgScrim.cgColor)
        ctx.fillPath(using: .evenOdd)

        // The thirds only help while the box is being shaped; at rest they would sit over the content being judged.
        if isCropDragging {
            ctx.setStrokeColor(DS.Color.selectionStroke.withAlphaComponent(0.35).cgColor)
            ctx.setLineWidth(1 / mag)
            for i in 1...2 {
                let f = CGFloat(i) / 3
                ctx.move(to: CGPoint(x: box.minX + box.width * f, y: box.minY)); ctx.addLine(to: CGPoint(x: box.minX + box.width * f, y: box.maxY))
                ctx.move(to: CGPoint(x: box.minX, y: box.minY + box.height * f)); ctx.addLine(to: CGPoint(x: box.maxX, y: box.minY + box.height * f))
            }
            ctx.strokePath()
        }

        ctx.strokeWithHalo(box, color: DS.Color.selectionStroke, width: 1 / mag)
        drawViewfinderMarks(ctx, box: box, mag: mag)
        if let draft = model.cropDraft { drawCropReadout(draft, box: box, page: page, mag: mag) }
        ctx.restoreGState()
    }

    private static let bracketArm: CGFloat = 18
    private static let edgeBar: CGFloat = 14
    private static let markWidth: CGFloat = 3
    private static let markHalo: CGFloat = 5

    /// An L at each corner and a bar at each edge midpoint, centred on the frame line like the marks on a viewfinder.
    private func drawViewfinderMarks(_ ctx: CGContext, box: CGRect, mag: CGFloat) {
        // A quarter of the side is the most a mark may take, so on a small box the arms and bars shrink together instead of fusing.
        let bar = min(Self.edgeBar / mag, min(box.width, box.height) / 4)
        let armX = min(Self.bracketArm / mag, box.width / 4)
        let armY = min(Self.bracketArm / mag, box.height / 4)

        var paths: [CGPath] = []
        for (cx, dx) in [(box.minX, CGFloat(1)), (box.maxX, -1)] {
            for (cy, dy) in [(box.minY, CGFloat(1)), (box.maxY, -1)] {
                let p = CGMutablePath()
                p.move(to: CGPoint(x: cx + dx * armX, y: cy))
                p.addLine(to: CGPoint(x: cx, y: cy))
                p.addLine(to: CGPoint(x: cx, y: cy + dy * armY))
                paths.append(p)
            }
        }
        for y in [box.minY, box.maxY] {
            let p = CGMutablePath()
            p.move(to: CGPoint(x: box.midX - bar / 2, y: y)); p.addLine(to: CGPoint(x: box.midX + bar / 2, y: y))
            paths.append(p)
        }
        for x in [box.minX, box.maxX] {
            let p = CGMutablePath()
            p.move(to: CGPoint(x: x, y: box.midY - bar / 2)); p.addLine(to: CGPoint(x: x, y: box.midY + bar / 2))
            paths.append(p)
        }

        ctx.setLineCap(.butt)
        ctx.setLineJoin(.miter)
        for (color, width) in [(DS.Color.selectionHalo, Self.markHalo), (DS.Color.selectionStroke, Self.markWidth)] {
            ctx.setStrokeColor(color.cgColor)
            ctx.setLineWidth(width / mag)
            for p in paths { ctx.addPath(p); ctx.strokePath() }
        }
    }

    /// The size chip sits inside the box's top-left corner when the box has room for it clear of the marks, else just outside.
    private func drawCropReadout(_ draft: CropDraft, box: CGRect, page: CGRect, mag: CGFloat) {
        let label = "\(Int(draft.rect.width.rounded())) × \(Int(draft.rect.height.rounded()))" as NSString
        let base = DS.Text.readout.font
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont(descriptor: base.fontDescriptor, size: base.pointSize / mag) ?? base,
            .foregroundColor: DS.Color.selectionStroke,
        ]
        let textSize = label.size(withAttributes: attrs)
        let chipSize = CGSize(width: textSize.width + 2 * DS.Space.s8 / mag, height: textSize.height + 2 * DS.Space.s2 / mag)
        let room = 2 * DS.Space.s16 / mag

        var chip: CGRect
        if box.width >= chipSize.width + room && box.height >= chipSize.height + room {
            let inset = (DS.Space.s8 + Self.markWidth / 2) / mag
            chip = CGRect(origin: CGPoint(x: box.minX + inset, y: box.minY + inset), size: chipSize)
        } else {
            chip = CGRect(origin: CGPoint(x: box.midX - chipSize.width / 2, y: box.maxY + DS.Space.s8 / mag), size: chipSize)
            if chip.maxY > page.maxY {
                let above = chip.offsetBy(dx: 0, dy: -(box.height + chipSize.height + 2 * DS.Space.s8 / mag))
                if above.minY >= page.minY { chip = above }
            }
        }
        DS.Color.bgHud.setFill()
        NSBezierPath.continuous(chip, radius: DS.Radius.sm / mag).fill()
        label.draw(at: CGPoint(x: chip.minX + DS.Space.s8 / mag, y: chip.minY + DS.Space.s2 / mag), withAttributes: attrs)
    }
}

extension CGContext {
    /// Strokes `rect` (or its inscribed ellipse) over arbitrary content: a wider `selectionHalo` line goes down first so the
    /// stroke still reads on white. `fill` is painted between the two, which leaves the halo as an outline around the shape.
    func strokeWithHalo(_ rect: CGRect, color: NSColor, width: CGFloat, fill: NSColor? = nil, oval: Bool = false) {
        func trace() { if oval { addEllipse(in: rect) } else { addRect(rect) } }
        setStrokeColor(DS.Color.selectionHalo.cgColor)
        setLineWidth(width * 2.5)
        trace(); strokePath()
        if let fill {
            setFillColor(fill.cgColor)
            trace(); fillPath()
        }
        setStrokeColor(color.cgColor)
        setLineWidth(width)
        trace(); strokePath()
    }
}
