import AppKit
import CornermarkDesign

/// Keeps a document view that is smaller than the viewport centred.
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposed: NSRect) -> NSRect {
        var r = super.constrainBoundsRect(proposed)
        guard let doc = documentView else { return r }
        if r.width > doc.frame.width { r.origin.x = (doc.frame.width - r.width) / 2 }
        if r.height > doc.frame.height { r.origin.y = (doc.frame.height - r.height) / 2 }
        return r
    }
}

/// Zoom below 100% re-renders the canvas smaller (`CanvasView.renderScale`) so the renderer's
/// smooth resampling applies. Zoom above 100% magnifies the scroll view, which keeps pixels crisp.
/// Either way one `zoom` number is what the user sees.
final class CanvasScrollView: NSScrollView, KeepsLeftToRight {
    enum ZoomMode { case fit, fixed }
    private(set) var zoomMode: ZoomMode = .fit
    var onZoomChange: (() -> Void)?
    private(set) var zoom: CGFloat = 1
    weak var canvas: CanvasView?

    static let zoomRange: ClosedRange<CGFloat> = 0.05...32

    override init(frame: NSRect) {
        super.init(frame: frame)
        contentView = CenteringClipView()
        hasHorizontalScroller = true
        hasVerticalScroller = true
        autohidesScrollers = true
        allowsMagnification = true
        minMagnification = 1
        maxMagnification = Self.zoomRange.upperBound
        drawsBackground = true
        backgroundColor = DS.Color.bgCanvas
    }

    required init?(coder: NSCoder) { fatalError() }

    func setZoom(_ value: CGFloat, mode: ZoomMode = .fixed) {
        zoomMode = mode
        let clamped = min(max(value, Self.zoomRange.lowerBound), Self.zoomRange.upperBound)
        guard clamped != zoom || canvas?.renderScale != min(clamped, 1) else { return }
        zoom = clamped
        canvas?.renderScale = min(clamped, 1)
        magnification = max(clamped, 1)
        onZoomChange?()
    }

    func fit() {
        zoomMode = .fit
        applyFit()
    }

    func zoomBy(_ factor: CGFloat) { setZoom(zoom * factor) }

    var fitZoom: CGFloat {
        guard let canvas else { return 1 }
        let base = canvas.baseCanvasSize
        let margin = CanvasView.margin * 2
        guard base.width > 0, base.height > 0 else { return 1 }
        let avail = contentSize
        return min((avail.width - margin) / base.width, (avail.height - margin) / base.height, 1)
    }

    func applyFit() {
        guard zoomMode == .fit else { return }
        let fit = fitZoom
        if abs(fit - zoom) > 0.0001 || canvas?.renderScale != min(fit, 1) { setZoom(fit, mode: .fit) }
    }

    override func magnify(with event: NSEvent) {
        zoomMode = .fixed
        setZoom(zoom * (1 + event.magnification))
    }

    override func layout() {
        super.layout()
        applyFit()
    }
}
