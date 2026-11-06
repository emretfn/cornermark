import AppKit
import AVFoundation
import CornermarkCore
import CornermarkDesign
import CornermarkL10n

/// Where a Manual zoom aims: a picture of the recording at the zoom's moment with the zoom's view drawn over it as a frame. Dragging
/// the frame, or clicking where it should go, moves the view; on the focused picture the arrow keys move it a hundredth of the picture,
/// Shift a tenth. The frame follows the pointer without animation, since it is direct manipulation.
final class ZoomTargetView: NSView, KeepsLeftToRight {
    enum Phase { case began, changed, ended, key }

    /// The new center, held where the view stays inside the picture.
    var onChange: (ZoomPoint, Phase) -> Void = { _, _ in }

    var picture: CGImage? { didSet { if picture !== oldValue { needsDisplay = true } } }
    /// The recording's width over its height.
    var aspect: CGFloat = 16 / 9 {
        didSet { if aspect != oldValue { invalidateIntrinsicContentSize(); needsDisplay = true } }
    }
    var zoom: Zoom? {
        didSet {
            guard zoom != oldValue else { return }
            needsDisplay = true
            if let zoom {
                let c = ZoomCamera.reachable(zoom.center, scale: zoom.scale)
                setAccessibilityValue(tr("Center {x}% across, {y}% down, {level}", ["x": Digits.text(Int((c.x * 100).rounded())), "y": Digits.text(Int((c.y * 100).rounded())),
                                                              "level": Digits.percent(zoom.scale)]))
            }
        }
    }

    static let maxHeight: CGFloat = 150
    static let minHeight: CGFloat = 56
    static let step = 0.01
    private var grab: (dx: Double, dy: Double)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        focusRingType = .exterior
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(tr("Zoom target"))
        setAccessibilityHelp(tr("Drag the frame to where the zoom should look, or use the arrow keys. Shift moves it further."))
        setAccessibilityIdentifier("video.zoom.target")
        // VoiceOver's actions menu moves the frame a tenth of the picture, the same as Shift with an arrow key.
        setAccessibilityCustomActions([(tr("Move frame left"), -1.0, 0.0), (tr("Move frame right"), 1, 0), (tr("Move frame up"), 0, -1), (tr("Move frame down"), 0, 1)].map { name, dx, dy in
            NSAccessibilityCustomAction(name: name) { [weak self] in
                guard let self, let zoom else { return false }
                let c = ZoomCamera.reachable(zoom.center, scale: zoom.scale)
                send(c.x + dx * 10 * Self.step, c.y + dy * 10 * Self.step, .key)
                return true
            }
        })
        // In a short window the picture gives up height before any control is pushed out of the column, and narrows to keep its shape.
        setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        heightAnchor.constraint(greaterThanOrEqualToConstant: Self.minHeight).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("ZoomTargetView is created in code") }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }
    /// As tall as the panel's width shows the recording, up to `maxHeight` for a tall one, which then narrows instead.
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: min(Self.maxHeight, (SettingsPanel.inner / max(aspect, 0.01)).rounded()))
    }

    /// The picture fitted inside the view, keeping the recording's shape, on the panel's leading edge like every other row.
    var pictureRect: CGRect {
        let w = min(bounds.width, bounds.height * aspect)
        let h = w / max(aspect, 0.01)
        return CGRect(x: 0, y: ((bounds.height - h) / 2).rounded(), width: w.rounded(), height: h.rounded())
    }

    /// The zoom's view inside `pictureRect`.
    var frameRect: CGRect? {
        guard let zoom else { return nil }
        let r = ZoomCamera.target(zoom), p = pictureRect
        return CGRect(x: p.minX + p.width * r.x, y: p.minY + p.height * r.y, width: p.width * r.width, height: p.height * r.height)
    }

    /// The source moment the picture shows, and the job reading that frame.
    private var shown: (time: Double?, job: Task<Void, Never>?) = (nil, nil)

    /// Shows the frame of `video` at `t` seconds, `standIn` until it is read. Asking again for the moment shown does nothing.
    func showFrame(of video: URL, at t: Double, fps: Double, standIn: CGImage?) {
        guard t != shown.time else { return }
        shown.time = t
        if let standIn { picture = standIn }
        shown.job?.cancel()
        shown.job = Task { [weak self] in
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: video))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 640, height: 640)
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5 / fps, preferredTimescale: 6000)
            let image = try? await generator.image(at: CMTime(seconds: t, preferredTimescale: 6000)).image
            guard !Task.isCancelled, let self, shown.time == t, let image else { return }
            picture = image
        }
    }

    /// Returns once the frame asked for last is shown, or was given up.
    func pictureSettled() async { await shown.job?.value }

    override var focusRingMaskBounds: NSRect { pictureRect }
    override func drawFocusRingMask() { NSBezierPath.continuous(pictureRect, radius: DS.Radius.sm).fill() }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let p = pictureRect
        let clip = NSBezierPath.continuous(p, radius: DS.Radius.sm)
        NSGraphicsContext.saveGraphicsState()
        clip.addClip()
        DS.Color.bgSunken.setFill()
        p.fill()
        if let picture {
            // The view is flipped, so the picture is drawn upside down into an unflipped space of its own.
            ctx.saveGState()
            ctx.translateBy(x: 0, y: p.maxY + p.minY)
            ctx.scaleBy(x: 1, y: -1)
            ctx.interpolationQuality = .high
            ctx.draw(picture, in: p)
            ctx.restoreGState()
        }
        if let f = frameRect {
            // Outside the view is dimmed the way capture dims outside a selection, so the frame reads on any recording.
            let shade = NSBezierPath(rect: p)
            shade.append(NSBezierPath(rect: f))
            shade.windingRule = .evenOdd
            DS.Color.bgScrim.setFill()
            shade.fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        DS.Color.imageOutline.setStroke()
        let outline = NSBezierPath.continuous(p.insetBy(dx: 0.5, dy: 0.5), radius: DS.Radius.sm)
        outline.lineWidth = 1
        outline.stroke()
        guard let f = frameRect else { return }
        let ring = f.insetBy(dx: 0.75, dy: 0.75)
        DS.Color.selectionHalo.setStroke()
        let halo = NSBezierPath(rect: ring.insetBy(dx: -1, dy: -1))
        halo.lineWidth = 1.5
        halo.stroke()
        DS.Color.selectionStroke.setStroke()
        let stroke = NSBezierPath(rect: ring)
        stroke.lineWidth = 1.5
        stroke.stroke()
    }

    override func resetCursorRects() {
        addCursorRect(pictureRect, cursor: grab == nil ? .openHand : .closedHand)
    }

    /// `point` in the view as a fraction of the picture, from its top-left corner.
    private func fraction(_ point: CGPoint) -> (x: Double, y: Double) {
        let p = pictureRect
        return (Double((point.x - p.minX) / max(p.width, 1)), Double((point.y - p.minY) / max(p.height, 1)))
    }

    private func send(_ x: Double, _ y: Double, _ phase: Phase) {
        guard let zoom else { return }
        let next = ZoomCamera.reachable(ZoomPoint(x: x, y: y), scale: zoom.scale)
        // Shown at once, before the edit comes back through the editor, so the frame never trails the pointer.
        self.zoom?.center = next
        onChange(next, phase)
    }

    override func mouseDown(with event: NSEvent) {
        guard let zoom else { return }
        window?.makeFirstResponder(self)
        let at = fraction(convert(event.locationInWindow, from: nil))
        let shown = ZoomCamera.target(zoom), c = (x: shown.x + shown.width / 2, y: shown.y + shown.height / 2)
        let inside = abs(at.x - c.x) <= shown.width / 2 && abs(at.y - c.y) <= shown.height / 2
        // Grabbing the frame keeps the spot under the pointer; a click elsewhere puts the frame's centre there.
        grab = inside ? (c.x - at.x, c.y - at.y) : (0, 0)
        window?.invalidateCursorRects(for: self)
        send(at.x + (grab?.dx ?? 0), at.y + (grab?.dy ?? 0), .began)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let grab else { return }
        let at = fraction(convert(event.locationInWindow, from: nil))
        send(at.x + grab.dx, at.y + grab.dy, .changed)
    }

    override func mouseUp(with event: NSEvent) {
        guard grab != nil, let zoom else { return }
        grab = nil
        window?.invalidateCursorRects(for: self)
        onChange(zoom.center, .ended)
    }

    /// The arrows move the target 1% of the picture a press, 10% with Shift. The keys come from `EditorShortcuts`.
    override func keyDown(with event: NSEvent) {
        guard let zoom, let press = EditorShortcuts.match(event, in: .zoomTarget), press.command == .moveTarget else { return super.keyDown(with: event) }
        let step = press.enlarged ? 10 * Self.step : Self.step
        // Starting from the centre the frame shows, so a press always moves the frame it can see.
        let c = ZoomCamera.reachable(zoom.center, scale: zoom.scale)
        switch press.keyIndex {
        case 0: send(c.x - step, c.y, .key)
        case 1: send(c.x + step, c.y, .key)
        case 2: send(c.x, c.y - step, .key)
        default: send(c.x, c.y + step, .key)
        }
    }
}
