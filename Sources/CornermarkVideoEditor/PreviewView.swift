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
    var state: FrameState? { didSet { if oldValue != state { placeCursor() } } }
    /// Room around the picture. None in preview-only mode, where the picture fills the window.
    var inset: CGFloat = DS.Space.s16 { didSet { needsLayout = true } }

    private let picture = CALayer()
    private let pointer = CAShapeLayer()

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

    private func withoutAnimation(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }
}
