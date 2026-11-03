import AppKit
import KadrajDesign
import KadrajCore

/// Draws the document through `Renderer.draw` and owns pointer interaction. View coordinates are
/// flipped (y-down) and the canvas sits `margin` points in from the top-left, so a view point
/// minus the margin is a canvas pixel at any zoom: the scroll view magnifies, this view never scales.
final class CanvasView: NSView, NSTextViewDelegate {
    static let margin: CGFloat = 40

    let model: EditorModel
    var gesture: Gesture = .idle
    var lastLiveDirty: CGRect?
    var compositeBuilds = 0

    private var planCache: (revision: Int, cropEditing: Bool, scale: CGFloat, plan: RenderPlan)?

    /// Canvas pixels per output pixel while zoomed out; the scroll view magnifies beyond 1.
    var renderScale: CGFloat = 1 {
        didSet {
            guard renderScale != oldValue else { return }
            syncFrame()
            invalidateAll()
        }
    }
    private var compositeCache: (revision: Int, excluded: UUID?, image: CGImage)?

    init(model: EditorModel) {
        self.model = model
        super.init(frame: .zero)
        registerForDraggedTypes([.fileURL, .tiff, .png])
        syncFrame()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var scrollView: CanvasScrollView? { enclosingScrollView as? CanvasScrollView }
    var magnification: CGFloat { max(scrollView?.magnification ?? 1, 1) }

    // MARK: Geometry

    var cropEditing: Bool { model.tool == .crop }

    /// While the crop tool is open the whole image shows, so the crop can be widened again.
    func displayDocument(scale: CGFloat) -> Document {
        var doc = model.document
        if cropEditing { doc.crop = nil; doc.background = nil; doc.outputScale = 1 }
        doc.outputScale *= Double(scale)
        return doc
    }

    var displayDocument: Document { displayDocument(scale: renderScale) }

    var plan: RenderPlan {
        if let c = planCache, c.revision == model.revision, c.cropEditing == cropEditing, c.scale == renderScale { return c.plan }
        let p = Renderer.plan(displayDocument, assets: model.assets)
        planCache = (model.revision, cropEditing, renderScale, p)
        return p
    }

    /// The canvas at 100% zoom, which "fit" divides the viewport by.
    var baseCanvasSize: CGSize { Renderer.canvasSize(displayDocument(scale: 1), assets: model.assets) }

    /// Canvas pixels per source pixel along the content axes.
    var canvasScale: CGFloat { let t = plan.sourceToCanvas; return hypot(t.a, t.b) }
    /// Screen points per source pixel.
    var screenScale: CGFloat { canvasScale * magnification }

    func canvasPoint(_ view: CGPoint) -> CGPoint { CGPoint(x: view.x - Self.margin, y: view.y - Self.margin) }
    func viewPoint(canvas: CGPoint) -> CGPoint { CGPoint(x: canvas.x + Self.margin, y: canvas.y + Self.margin) }
    func sourcePoint(_ view: CGPoint) -> CGPoint { canvasPoint(view).applying(plan.canvasToSource) }
    func viewPoint(source: CGPoint) -> CGPoint { viewPoint(canvas: source.applying(plan.sourceToCanvas)) }

    func viewRect(source rect: CGRect) -> CGRect {
        rect.applying(plan.sourceToCanvas).offsetBy(dx: Self.margin, dy: Self.margin)
    }

    func syncFrame() {
        let size = plan.canvasSize
        let want = NSSize(width: size.width + Self.margin * 2, height: size.height + Self.margin * 2)
        if frame.size != want { setFrameSize(want) }
        scrollView?.applyFit()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        syncFrame()
    }

    // MARK: Composite cache

    func composite(excluding id: UUID?) -> CGImage? {
        if let c = compositeCache, c.revision == model.revision, c.excluded == id { return c.image }
        guard let image = Renderer.sourceComposite(model.document, assets: model.assets, excluding: id) else { return nil }
        compositeCache = (model.revision, id, image)
        compositeBuilds += 1
        return image
    }

    // MARK: Live state

    /// The annotation being previewed in place of the committed one, and the committed one to leave out.
    var liveState: (live: Annotation?, hidden: UUID?) {
        switch gesture {
        case .drawing(let d): return (d.engaged ? d.provisional : nil, nil)
        case .moving(let m): return m.engaged ? (m.current, m.original.id) : (nil, nil)
        case .resizing(let r): return (r.current, r.original.id)
        case .editingText(let t): return (nil, t.existing?.id)
        case .idle, .cropping: return (nil, nil)
        }
    }

    // MARK: Painting

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        DS.Color.bgCanvas.setFill()
        dirtyRect.fill()

        let m = Self.margin
        let canvas = CGRect(origin: .zero, size: plan.canvasSize)
        ctx.saveGState()
        ctx.translateBy(x: m, y: m)
        ctx.clip(to: canvas)
        let dirty = dirtyRect.offsetBy(dx: -m, dy: -m).intersection(canvas)
        paintDocument(in: ctx, dirty: dirty)
        ctx.restoreGState()

        DS.Color.imageOutline.setStroke()
        NSBezierPath.defaultLineWidth = 1 / max(magnification, 0.01)
        NSBezierPath.stroke(canvas.offsetBy(dx: m, dy: m).insetBy(dx: -0.5, dy: -0.5))

        drawSelection(ctx)
        drawCrop(ctx)
    }

    /// Everything inside the canvas. Goes through `Renderer.draw`, so on-screen pixels are the exported pixels.
    func paintDocument(in ctx: CGContext, dirty: CGRect) {
        var doc = displayDocument
        let (live, hidden) = liveState
        let originalIndex = hidden.flatMap { id in doc.annotations.firstIndex { $0.id == id } }
        let wasTopmost = originalIndex.map { $0 == doc.annotations.count - 1 } ?? true
        if let hidden { doc.annotations.removeAll { $0.id == hidden } }

        guard let live else {
            Renderer.draw(doc, assets: model.assets, in: ctx, composite: composite(excluding: hidden))
            return
        }

        let strategy = PreviewStrategy.of(live.kind, imageArea: model.document.pixelSize.width * model.document.pixelSize.height)
        var rebuild = !wasTopmost
        if case .rebuild = strategy { rebuild = true }
        if rebuild {
            doc.annotations.insert(live, at: min(originalIndex ?? doc.annotations.count, doc.annotations.count))
            Renderer.draw(doc, assets: model.assets, in: ctx)
        } else {
            Renderer.draw(doc, assets: model.assets, in: ctx, composite: composite(excluding: hidden))
            paintOverlay(live, strategy, in: ctx, dirty: dirty)
        }
    }

    private func paintOverlay(_ live: Annotation, _ strategy: PreviewStrategy, in ctx: CGContext, dirty: CGRect) {
        let p = plan
        let source = model.document.sourceBounds
        ctx.saveGState()
        ctx.addRect(p.contentRect)
        ctx.clip()
        ctx.concatenate(p.sourceToCanvas)

        switch strategy {
        case .spotlight:
            if case .spotlight(let r) = live.kind {
                ctx.addRect(source)
                ctx.addRect(r.standardized)
                ctx.setFillColor(CGColor(gray: 0, alpha: 0.55))
                ctx.fillPath(using: .evenOdd)
            }
        case .overlay(let multiply):
            let region = live.bounds.inflated(8)
                .intersection(dirty.applying(p.canvasToSource).inflated(2))
                .integralClamped(to: source)
            if !region.isNull {
                var tmp = Document(base: "", pixelSize: region.size, pointScale: 1)
                tmp.annotations = [live.translated(by: CGVector(dx: -region.minX, dy: -region.minY))]
                if let image = Renderer.sourceComposite(tmp, assets: model.assets) {
                    if multiply { ctx.setBlendMode(.multiply) }
                    ctx.interpolationQuality = .high
                    ctx.translateBy(x: region.minX, y: region.maxY)
                    ctx.scaleBy(x: 1, y: -1)
                    ctx.draw(image, in: CGRect(x: 0, y: 0, width: region.width, height: region.height))
                }
            }
        case .frosted:
            let r = live.bounds
            ctx.setFillColor(CGColor(gray: 1, alpha: 0.28))
            ctx.fill(r)
            ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.9))
            ctx.setLineWidth(2 / max(screenScale, 0.0001))
            ctx.setLineDash(phase: 0, lengths: [6 / max(screenScale, 0.0001), 4 / max(screenScale, 0.0001)])
            ctx.stroke(r)
        case .rebuild:
            break
        }
        ctx.restoreGState()
    }

    // MARK: Chrome

    var displayedSelection: Annotation? {
        guard model.tool == .select else { return nil }
        switch gesture {
        case .moving(let m): return m.current
        case .resizing(let r): return r.current
        case .editingText: return nil
        default: return model.selectedAnnotation
        }
    }

    private func drawSelection(_ ctx: CGContext) {
        guard let ann = displayedSelection else { return }
        let mag = max(magnification, 0.01)
        let frame = viewRect(source: ann.bounds)
        ctx.saveGState()
        let line = 1.5 / mag
        ctx.strokeWithHalo(frame, color: DS.Color.selectionStroke, width: line)

        let size = 9 / mag
        for h in ann.handles {
            let c = viewPoint(source: h.position)
            let box = CGRect(x: c.x - size / 2, y: c.y - size / 2, width: size, height: size)
            switch h.kind {
            case .edge:
                ctx.strokeWithHalo(box, color: DS.Color.selectionStroke, width: line, fill: DS.Color.selectionStroke)
            case .endpoint, .radius:
                ctx.strokeWithHalo(box, color: DS.Color.selectionStroke, width: line, fill: DS.Color.selectionStroke, oval: true)
            case .control:
                ctx.strokeWithHalo(box.insetBy(dx: -1 / mag, dy: -1 / mag), color: DS.Color.selectionStroke, width: line, fill: DS.Color.accentSolid, oval: true)
            }
        }
        ctx.restoreGState()
    }

    func invalidateAll() { setNeedsDisplay(bounds) }

    /// Repaints the screen area covering source-space `rects`, plus room for selection handles.
    func invalidate(source rects: [CGRect]) {
        guard var union = rects.first else { return }
        for r in rects.dropFirst() { union = union.union(r) }
        let pad = 14 / max(magnification, 0.01)
        setNeedsDisplay(viewRect(source: union).insetBy(dx: -pad, dy: -pad))
    }

    func dirtyRegion(for live: Annotation) -> CGRect {
        switch live.kind {
        case .pencil(let pts), .highlighter(let pts):
            let tail = pts.suffix(5)
            guard let first = tail.first else { return live.bounds }
            var r = CGRect(origin: first, size: .zero)
            for p in tail { r = r.union(CGRect(origin: p, size: .zero)) }
            return r.inflated(CGFloat(live.stroke.width) / 2 + 6)
        default:
            return live.bounds.inflated(8)
        }
    }

    func updateLive(_ live: Annotation?, original: Annotation? = nil) {
        var rects: [CGRect] = []
        if let last = lastLiveDirty { rects.append(last) }
        if let original { rects.append(original.bounds.inflated(8)) }
        if let live { let d = dirtyRegion(for: live); rects.append(d); lastLiveDirty = d } else { lastLiveDirty = nil }
        invalidate(source: rects)
    }

    // MARK: Cursor

    override func resetCursorRects() {
        let cursor: NSCursor
        switch model.tool.spec.input {
        case .select, .inert: cursor = .arrow
        case .text: cursor = .iBeam
        default: cursor = .crosshair
        }
        addCursorRect(visibleRect, cursor: cursor)
    }

    // MARK: Model changes

    func modelChanged(_ change: Change) {
        if change.contains(.tool) || change.contains(.document) {
            if !change.contains(.document), case .editingText = gesture { commitText() }
            cancelGestureIfStale(change)
            syncFrame()
            window?.invalidateCursorRects(for: self)
        }
        if change.contains(.style) { restyleTextView() }
        invalidateAll()
    }

    private func cancelGestureIfStale(_ change: Change) {
        switch gesture {
        case .drawing, .moving, .resizing, .cropping:
            gesture = .idle
            lastLiveDirty = nil
        default: break
        }
    }

    func cancelGesture() {
        if case .editingText = gesture { commitText() }
        gesture = .idle
        lastLiveDirty = nil
        invalidateAll()
    }
}
