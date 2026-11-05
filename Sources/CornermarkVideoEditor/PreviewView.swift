import AppKit
import CornermarkCore
import CornermarkDesign
import QuartzCore

/// The finished video at the playhead: the background, the source frame `frameState` names, and the pointer it places, in the look
/// export draws. All are layers, so a new frame costs the main thread a property change and Core Animation composites it.
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
    var state: FrameState? { didSet { if oldValue != state { placeCursor() } } }
    /// Where the recording sits on the finished video.
    var canvas: VideoCanvas? { didSet { if oldValue != canvas { needsLayout = true } } }
    /// The picture the background shows when its fill is an added image.
    var backgroundPicture: CGImage? { didSet { if backgroundPicture !== oldValue { drawnBackdrop = nil; needsLayout = true } } }
    /// Room around the picture. None in preview-only mode, where the picture fills the window.
    var inset: CGFloat = DS.Space.s16 { didSet { needsLayout = true } }

    /// The whole finished video. As the backing layer's first sublayer it is what a harness renders as the preview's frame.
    private let stage = CALayer()
    private let picture = CALayer()
    private let pointer = CAShapeLayer()
    private var pointerStyle = CursorStyle.white
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
        stage.borderWidth = 1
        stage.masksToBounds = true
        stage.addSublayer(picture)
        pointer.lineJoin = .round
        dress(.white)
        pointer.isHidden = true
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
        }
        drawBackdrop(canvas)
        placeCursor()
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

    /// Pointer samples count from the recorded area's top-left corner with y down; the picture layer counts from its bottom-left.
    private func placeCursor() {
        withoutAnimation {
            guard let cursor = state?.cursor, pointSize.width > 0, pointSize.height > 0 else {
                pointer.isHidden = true
                return
            }
            let size = picture.bounds.size
            let kx = size.width / pointSize.width, ky = size.height / pointSize.height
            if cursor.style != pointerStyle { dress(cursor.style) }
            pointer.isHidden = false
            pointer.opacity = Float(cursor.opacity)
            pointer.position = CGPoint(x: cursor.x * kx, y: size.height - cursor.y * ky)
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

    private func withoutAnimation(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }
}
