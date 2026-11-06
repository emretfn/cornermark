import AppKit
import CornermarkCore
import CornermarkDesign
import QuartzCore

/// The finished video at the playhead: the background, the source frame `frameState` names cropped to its zoom, the camera, the click rings and
/// keystroke badge, and the pointer it places, in the look export draws. All are layers, so a new frame costs the main thread a property change and Core Animation composites it.
/// The video is content, so only the area around it follows the appearance.
final class PreviewView: NSView {
    /// The recorded area in points, the unit of pointer positions.
    var pointSize = CGSize(width: 16, height: 9) { didSet { needsLayout = true } }
    var image: CGImage? {
        didSet {
            guard image !== oldValue else { return }
            withoutAnimation { picture.contents = image }
        }
    }
    var state: FrameState? { didSet { if oldValue != state { placeCrop(); placeCursor(); placeCamera(); placeRings(); badge.show(state?.input.badge, crop: state?.crop ?? .full) } } }
    var highlight = ClickHighlight() { didSet { if oldValue != highlight { placeRings() } } }
    /// How the keystroke badge looks, from the project's edits.
    var keystrokes = KeystrokeDisplay() { didSet { if oldValue != keystrokes { badge.look = keystrokes } } }
    /// Where the recording sits on the finished video.
    var canvas: VideoCanvas? { didSet { if oldValue != canvas { needsLayout = true } } }
    /// The picture the background shows when its fill is an added image.
    var backgroundPicture: CGImage? { didSet { if backgroundPicture !== oldValue { drawnBackdrop = nil; needsLayout = true } } }
    /// The camera file's picture at the playhead. Shown only where `state` places the camera.
    var cameraImage: CGImage? {
        didSet {
            guard cameraImage !== oldValue else { return }
            withoutAnimation { cameraPicture.contents = cameraImage }
            placeCamera()
        }
    }
    /// Room around the picture. None in preview-only mode, where the picture fills the window.
    var inset: CGFloat = DS.Space.s16 { didSet { needsLayout = true } }

    /// The whole finished video. As the backing layer's first sublayer it is what a harness renders as the preview's frame.
    private let stage = CALayer()
    private let picture = CALayer()
    private let pointer = CAShapeLayer()
    private var pointerStyle = CursorStyle.white
    private var rings: [RingLayer] = []
    /// The camera's shadow, and inside it the clipped picture, drawn as `CameraBubblePainter` draws it in export.
    private let cameraHolder = CALayer()
    private let cameraPicture = CALayer()
    private let badge = BadgeLayer()
    /// What the stage shows now, so a layout that changes nothing draws nothing.
    private var drawnBackdrop: (canvas: VideoCanvas, width: Int, height: Int)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        picture.contentsGravity = .resize
        picture.backgroundColor = CGColor(gray: 0, alpha: 1)
        picture.masksToBounds = true
        picture.cornerCurve = .circular
        stage.contentsGravity = .resize
        // Without a background a ratio leaves bars around the recording, black as export draws them.
        stage.backgroundColor = CGColor(gray: 0, alpha: 1)
        stage.borderWidth = 1
        stage.masksToBounds = true
        stage.addSublayer(picture)
        pointer.lineJoin = .round
        dress(.white)
        pointer.isHidden = true
        cameraPicture.contentsGravity = .resizeAspectFill
        cameraPicture.masksToBounds = true
        cameraPicture.borderColor = CameraBubblePainter.edge
        cameraHolder.shadowColor = CameraBubblePainter.shadow
        cameraHolder.isHidden = true
        cameraHolder.addSublayer(cameraPicture)
        picture.addSublayer(cameraHolder)
        picture.addSublayer(badge)
        picture.addSublayer(pointer)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Preview")
        setAccessibilityIdentifier("video.preview")
    }

    required init?(coder: NSCoder) { fatalError("PreviewView is created in code") }

    override var wantsUpdateLayer: Bool { true }

    override func makeBackingLayer() -> CALayer {
        let layer = CALayer()
        layer.addSublayer(stage)
        return layer
    }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = DS.Color.bgCanvas.cgColor
            stage.borderColor = DS.Color.imageOutline.cgColor
        }
    }

    override func layout() {
        super.layout()
        let canvas = canvas ?? VideoCanvas(source: RecordingProject.Source(pointWidth: pointSize.width, pointHeight: pointSize.height), background: VideoBackground())
        let stageRect = fitted(canvas.size)
        // Each axis scales on its own, as export's does, so the recording lands where the file puts it after the stage's rounding.
        let kx = stageRect.width / canvas.size.width, ky = stageRect.height / canvas.size.height
        let f = canvas.frame
        withoutAnimation {
            stage.frame = stageRect
            picture.frame = CGRect(x: f.minX * kx, y: stageRect.height - f.maxY * ky, width: f.width * kx, height: f.height * ky)
            picture.cornerRadius = canvas.cornerRadius * min(kx, ky)
            badge.frame = picture.bounds
            badge.pointSize = pointSize
            badge.contentsScale = window?.backingScaleFactor ?? 2
        }
        drawBackdrop(canvas)
        placeCrop()
        placeCursor()
        placeCamera()
        placeRings()
    }

    /// Where the recording sits in the view, in the view's bottom-left coordinates, after the last layout.
    var pictureRect: CGRect {
        let p = picture.frame
        return p.offsetBy(dx: stage.frame.minX, dy: stage.frame.minY)
    }

    /// The video fitted into the view, in the view's bottom-left coordinates.
    private func fitted(_ size: CGSize) -> CGRect {
        let box = bounds.insetBy(dx: inset, dy: inset)
        guard size.width > 0, size.height > 0, box.width > 0, box.height > 0 else { return .zero }
        let k = min(box.width / size.width, box.height / size.height)
        let w = (size.width * k).rounded(), h = (size.height * k).rounded()
        return CGRect(x: (box.midX - w / 2).rounded(), y: (box.midY - h / 2).rounded(), width: w, height: h)
    }

    /// Draws the background at the stage's own pixel size, through the painter export uses.
    private func drawBackdrop(_ canvas: VideoCanvas) {
        let scale = window?.backingScaleFactor ?? 2
        let w = Int((stage.bounds.width * scale).rounded()), h = Int((stage.bounds.height * scale).rounded())
        if let drawn = drawnBackdrop, drawn.canvas == canvas, drawn.width == w, drawn.height == h { return }
        drawnBackdrop = (canvas, w, h)
        let image = w > 0 && h > 0 ? VideoBackdrop.image(canvas, width: w, height: h, picture: backgroundPicture) : nil
        withoutAnimation { stage.contents = image }
    }

    /// The crop picks the part of the recording the frame shows; `contentsRect` counts from the picture's bottom-left, the crop from its
    /// top-left. The frame's rounded clip and the picture layer's bounds stay put, so the zoom happens inside the frame.
    private func placeCrop() {
        let crop = state?.crop ?? .full
        withoutAnimation { picture.contentsRect = CGRect(x: crop.x, y: 1 - crop.y - crop.height, width: crop.width, height: crop.height) }
    }

    /// Pointer samples count from the recorded area's top-left corner with y down and sit in recording coordinates, so the crop moves
    /// them. The picture layer counts from its bottom-left. The camera bubble does not follow the crop: it is a separate overlay.
    private func placeCursor() {
        withoutAnimation {
            guard let cursor = state?.cursor, pointSize.width > 0, pointSize.height > 0 else {
                pointer.isHidden = true
                return
            }
            let size = picture.bounds.size
            let crop = state?.crop ?? .full
            let kx = size.width / (pointSize.width * crop.width), ky = size.height / (pointSize.height * crop.height)
            if cursor.style != pointerStyle { dress(cursor.style) }
            pointer.isHidden = false
            pointer.opacity = Float(cursor.opacity)
            pointer.position = CGPoint(x: (cursor.x - crop.x * pointSize.width) * kx,
                                     y: size.height - (cursor.y - crop.y * pointSize.height) * ky)
            pointer.setAffineTransform(CGAffineTransform(scaleX: cursor.scale * kx, y: -cursor.scale * ky))
        }
    }

    private func dress(_ style: CursorStyle) {
        let look = PointerShape.look(style)
        pointer.path = look.path
        pointer.fillColor = look.fill
        pointer.strokeColor = look.stroke
        pointer.lineWidth = look.lineWidth
        pointerStyle = style
    }

    /// How many ring layers show a ring now. The badge layer never paints one.
    var visibleRingCount: Int { rings.filter { !$0.isHidden }.count }

    private func placeRings() {
        withoutAnimation {
            let placed = pointSize.width > 0 && pointSize.height > 0 ? state?.input.rings ?? [] : []
            while rings.count < placed.count {
                let ring = RingLayer()
                picture.insertSublayer(ring, below: pointer)
                rings.append(ring)
            }
            let size = picture.bounds.size
            let crop = state?.crop ?? .full
            let kx = size.width / (pointSize.width * crop.width), ky = size.height / (pointSize.height * crop.height)
            for (i, layer) in rings.enumerated() {
                guard i < placed.count else { layer.isHidden = true; continue }
                layer.isHidden = false
                layer.show(placed[i], highlight)
                layer.position = CGPoint(x: (placed[i].x - crop.x * pointSize.width) * kx, y: size.height - (placed[i].y - crop.y * pointSize.height) * ky)
                layer.setAffineTransform(CGAffineTransform(scaleX: kx, y: ky))
            }
        }
    }

    /// Camera rects count from the area's top-left corner with y down, like pointer samples.
    private func placeCamera() {
        withoutAnimation {
            guard let placed = state?.camera, cameraImage != nil, pointSize.width > 0, pointSize.height > 0 else {
                cameraHolder.isHidden = true
                return
            }
            let size = picture.bounds.size
            let kx = size.width / pointSize.width, ky = size.height / pointSize.height
            let r = placed.rect
            let frame = CGRect(x: r.minX * kx, y: size.height - r.maxY * ky, width: r.width * kx, height: r.height * ky)
            let bubble = CGFloat(1 - placed.fill)
            cameraHolder.isHidden = false
            cameraHolder.frame = frame
            cameraHolder.shadowOpacity = Float(0.35 * bubble)
            cameraHolder.shadowRadius = frame.height * 0.04
            cameraHolder.shadowOffset = CGSize(width: 0, height: -frame.height * 0.02)
            cameraHolder.shadowPath = CGPath(roundedRect: CGRect(origin: .zero, size: frame.size), cornerWidth: min(placed.cornerRadius * kx, frame.height / 2),
                                             cornerHeight: min(placed.cornerRadius * kx, frame.height / 2), transform: nil)
            cameraPicture.frame = CGRect(origin: .zero, size: frame.size)
            cameraPicture.cornerRadius = min(placed.cornerRadius * kx, min(frame.width, frame.height) / 2)
            cameraPicture.borderWidth = bubble > 0 ? 1 : 0
            cameraPicture.setAffineTransform(placed.isMirrored ? CGAffineTransform(scaleX: -1, y: 1) : .identity)
        }
    }

    private func withoutAnimation(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }
}

private final class RingLayer: CALayer {
    private let halo = CAShapeLayer()
    private let line = CAShapeLayer()

    override init() {
        super.init()
        allowsGroupOpacity = true
        for l in [halo, line] { addSublayer(l) }
        line.fillColor = nil
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError("RingLayer is created in code") }

    func show(_ ring: ClickRing, _ h: ClickHighlight) {
        let width = InputOverlayPainter.ringLineWidth(h)
        let path = CGPath(ellipseIn: CGRect(x: -ring.radius, y: -ring.radius, width: ring.radius * 2, height: ring.radius * 2), transform: nil)
        let color = InputOverlayInk.design.click(h.color)
        opacity = Float(ring.opacity)
        halo.path = path
        halo.fillColor = h.style == .filled ? color.copy(alpha: InputOverlayPainter.ringFillAlpha) : nil
        halo.strokeColor = InputOverlayInk.design.halo
        halo.lineWidth = InputOverlayPainter.ringHaloWidth(h)
        line.path = path
        line.strokeColor = color
        line.lineWidth = width
    }
}

/// The keystroke badge, drawn by the painter export uses into a layer over the picture, through the zoom's crop. Click rings are not its
/// business: `RingLayer`s draw them, so a ring is drawn once. It redraws only when the badge or the crop change while a badge is on screen.
private final class BadgeLayer: CALayer {
    var pointSize = CGSize(width: 16, height: 9) { didSet { if oldValue != pointSize { setNeedsDisplay() } } }
    var look = KeystrokeDisplay() { didSet { setNeedsDisplay() } }
    private var badge: KeyBadge?
    /// The part of the recorded area the picture shows. The badge sits in the recording's points, so the crop moves it like the pointer.
    private var crop = ZoomRect.full

    override init() {
        super.init()
        needsDisplayOnBoundsChange = true
        actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
    }

    override init(layer: Any) {
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) { fatalError("BadgeLayer is created in code") }

    func show(_ next: KeyBadge?, crop nextCrop: ZoomRect) {
        guard next != badge || nextCrop != crop else { return }
        let drawsSomething = badge != nil || next != nil
        badge = next
        crop = nextCrop
        if drawsSomething { setNeedsDisplay() }
    }

    override func draw(in ctx: CGContext) {
        guard let badge, pointSize.width > 0, pointSize.height > 0 else { return }
        // The layer counts from its bottom-left, the painter in the recording's points from the top-left.
        ctx.translateBy(x: 0, y: bounds.height)
        ctx.scaleBy(x: bounds.width / (pointSize.width * crop.width), y: -bounds.height / (pointSize.height * crop.height))
        ctx.translateBy(x: -crop.x * pointSize.width, y: -crop.y * pointSize.height)
        InputOverlayPainter.draw(InputOverlayState(badge: badge), area: pointSize, highlight: ClickHighlight(), keystrokes: look, ink: .design, in: ctx)
    }
}
