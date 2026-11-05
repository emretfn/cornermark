import AppKit
import CornermarkCore
import CornermarkDesign
import QuartzCore

/// The finished video at the playhead: the source frame `frameState` names, and the pointer it places, in the outline export draws.
/// Both are layers, so a new frame costs the main thread a property change and Core Animation composites it.
/// The picture is content, so only the backdrop around it follows the appearance.
final class PreviewView: NSView {
    /// The recorded area in points, the unit of pointer positions.
    var pointSize = CGSize(width: 16, height: 9) { didSet { needsLayout = true } }
    var image: CGImage? {
        didSet {
            guard image !== oldValue else { return }
            withoutAnimation { picture.contents = image }
        }
    }
    var state: FrameState? { didSet { if oldValue != state { placeCursor(); placeCamera() } } }
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

    private let picture = CALayer()
    private let pointer = CAShapeLayer()
    /// The camera's shadow, and inside it the clipped picture, drawn as `CameraBubblePainter` draws it in export.
    private let cameraHolder = CALayer()
    private let cameraPicture = CALayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        picture.contentsGravity = .resize
        picture.backgroundColor = CGColor(gray: 0, alpha: 1)
        picture.borderWidth = 1
        picture.masksToBounds = true
        let outline = CGMutablePath()
        outline.addLines(between: PointerShape.outline)
        outline.closeSubpath()
        pointer.path = outline
        pointer.fillColor = PointerShape.fill
        pointer.strokeColor = PointerShape.stroke
        pointer.lineWidth = PointerShape.lineWidth
        pointer.lineJoin = .round
        pointer.isHidden = true
        cameraPicture.contentsGravity = .resizeAspectFill
        cameraPicture.masksToBounds = true
        cameraPicture.borderColor = CameraBubblePainter.edge
        cameraHolder.shadowColor = CameraBubblePainter.shadow
        cameraHolder.isHidden = true
        cameraHolder.addSublayer(cameraPicture)
        picture.addSublayer(cameraHolder)
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
        layer.addSublayer(picture)
        return layer
    }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = DS.Color.bgCanvas.cgColor
            picture.borderColor = DS.Color.imageOutline.cgColor
        }
    }

    override func layout() {
        super.layout()
        withoutAnimation { picture.frame = pictureRect }
        placeCursor()
        placeCamera()
    }

    /// Where the picture sits: the recorded area fitted into the view, in the view's bottom-left coordinates.
    var pictureRect: CGRect {
        let box = bounds.insetBy(dx: inset, dy: inset)
        guard pointSize.width > 0, pointSize.height > 0, box.width > 0, box.height > 0 else { return .zero }
        let k = min(box.width / pointSize.width, box.height / pointSize.height)
        let w = (pointSize.width * k).rounded(), h = (pointSize.height * k).rounded()
        return CGRect(x: (box.midX - w / 2).rounded(), y: (box.midY - h / 2).rounded(), width: w, height: h)
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
            pointer.isHidden = false
            pointer.position = CGPoint(x: cursor.x * kx, y: size.height - cursor.y * ky)
            pointer.setAffineTransform(CGAffineTransform(scaleX: cursor.scale * kx, y: -cursor.scale * ky))
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
