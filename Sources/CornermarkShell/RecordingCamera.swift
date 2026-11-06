import AppKit
import CornermarkCapture
import CornermarkCore
import CornermarkDesign
import QuartzCore
import VideoToolbox

/// A change to the camera's look during a recording. A field left nil stays as it is.
struct CameraChange: Equatable {
    enum FullScreen: String, Equatable { case on, off, toggle }
    var shape: CameraBubble.Shape?
    var size: CameraBubble.Size?
    var corner: GridPosition?
    var mirrored: Bool?
    var fullScreen: FullScreen?

    static let toggleFullScreen = CameraChange(fullScreen: .toggle)

    /// `record/camera` alone toggles full screen, as a click on the bubble does. `shape`, `size`, `corner`, `mirror` (`0` or `1`) and
    /// `full-screen` (`on`, `off` or `toggle`) change the rest.
    static func parse(_ query: [String: String]) -> Result<CameraChange, URLCommandError> {
        var change = CameraChange()
        func value<T: RawRepresentable>(_ key: String) -> Result<T?, URLCommandError> where T.RawValue == String {
            guard let raw = query[key] else { return .success(nil) }
            guard let v = T(rawValue: raw) else { return .failure(.invalidRecording("camera \(key)")) }
            return .success(v)
        }
        do {
            change.shape = try value("shape").get()
            change.size = try value("size").get()
            change.corner = try value("corner").get()
            // A recording starts and snaps in a corner; the other cells of the grid are the video editor's.
            if let corner = change.corner, !GridPosition.corners.contains(corner) { return .failure(.invalidRecording("camera corner")) }
            change.fullScreen = try value("full-screen").get()
        } catch {
            return .failure(error)
        }
        if let raw = query["mirror"] {
            guard raw == "0" || raw == "1" else { return .failure(.invalidRecording("camera mirror")) }
            change.mirrored = raw == "1"
        }
        if change == CameraChange() { change.fullScreen = .toggle }
        return .success(change)
    }
}

/// Hands camera pictures from the camera's queue to whoever shows them on screen, as images made off the main thread.
final class CameraFeed: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: ((CGImage) -> Void)?
    private var busy = false

    func onPicture(_ handler: ((CGImage) -> Void)?) { lock.withLock { self.handler = handler } }

    /// A picture that arrives while the last one is still on its way to the screen is skipped, so a slow main thread never queues them.
    func send(_ pixels: CVPixelBuffer) {
        guard lock.withLock({ handler != nil && !busy }) else { return }
        var image: CGImage?
        VTCreateCGImageFromCVPixelBuffer(pixels, options: nil, imageOut: &image)
        guard let image else { return }
        lock.withLock { busy = true }
        DispatchQueue.main.async { [self] in
            let handler = lock.withLock { () -> ((CGImage) -> Void)? in
                busy = false
                return self.handler
            }
            handler?(image)
        }
    }
}

/// The camera on screen: its picture in the bubble's shape, mirrored when asked. A click fills the recorded area with the camera and
/// a second click brings the bubble back. A drag moves it, and it settles in the nearest corner.
final class CameraBubbleView: NSView {
    var onToggle: () -> Void = {}
    /// The bubble's centre where the drag ended, in window-relative screen points.
    var onDrop: (CGPoint) -> Void = { _ in }
    var image: CGImage? {
        didSet { withoutAnimation { picture.contents = image } }
    }
    var cornerRadius: CGFloat = 0 { didSet { needsLayout = true } }
    var isMirrored = true { didSet { needsLayout = true } }
    var isFullScreen = false {
        didSet {
            guard isFullScreen != oldValue else { return }
            hint.symbol = isFullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right"
            setAccessibilityHelp(isFullScreen ? "Shrinks the camera back to a bubble" : "Fills the recording with the camera")
            setAccessibilityValue(isFullScreen ? "Full screen" : "Bubble")
        }
    }

    private let picture = CALayer()
    private let hint = HintBadge()
    private var pressAt: NSPoint?
    private var dragged = false
    private var tracking: NSTrackingArea?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        picture.contentsGravity = .resizeAspectFill
        picture.masksToBounds = true
        picture.backgroundColor = CGColor(gray: 0.1, alpha: 1)
        picture.borderColor = CameraBubblePainter.edge
        picture.borderWidth = 1
        layer?.addSublayer(picture)
        hint.alphaValue = 0
        addSubview(hint)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Camera")
        setAccessibilityHelp("Fills the recording with the camera")
        setAccessibilityValue("Bubble")
        setAccessibilityIdentifier("recording.camera")
    }

    required init?(coder: NSCoder) { fatalError("CameraBubbleView is created in code") }

    override func layout() {
        super.layout()
        withoutAnimation {
            picture.frame = bounds
            picture.cornerRadius = min(cornerRadius, min(bounds.width, bounds.height) / 2)
            // The picture turns across its own middle, so mirroring never moves it.
            picture.setAffineTransform(isMirrored ? CGAffineTransform(scaleX: -1, y: 1) : .identity)
        }
        let s = HintBadge.side
        // The badge stays inside a circle's edge: on the diagonal at the bubble's radius, minus its own size.
        let inset = max(DS.Space.s8, (min(cornerRadius, bounds.height / 2)) * (1 - 1 / 2.squareRoot()) - s / 4)
        hint.frame = CGRect(x: bounds.maxX - inset - s, y: inset, width: s, height: s)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseEntered(with event: NSEvent) { showHint(true) }
    override func mouseExited(with event: NSEvent) { showHint(false) }

    override func mouseDown(with event: NSEvent) {
        pressAt = NSEvent.mouseLocation
        dragged = false
        if !DS.Motion.isReduced { setPressed(true) }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = pressAt, let window, !isFullScreen else { return }
        let now = NSEvent.mouseLocation
        if !dragged, hypot(now.x - start.x, now.y - start.y) < 3 { return }
        dragged = true
        setPressed(false)
        window.setFrameOrigin(NSPoint(x: window.frame.minX + now.x - start.x, y: window.frame.minY + now.y - start.y))
        pressAt = now
    }

    override func mouseUp(with event: NSEvent) {
        setPressed(false)
        defer { pressAt = nil }
        guard pressAt != nil else { return }
        if dragged, let window { onDrop(CGPoint(x: window.frame.midX, y: window.frame.midY)) } else { onToggle() }
    }

    override func accessibilityPerformPress() -> Bool {
        onToggle()
        return true
    }

    private func setPressed(_ pressed: Bool) {
        let k = pressed ? DS.Motion.pressScale : 1
        let b = bounds
        var t = CATransform3DMakeTranslation(b.midX, b.midY, 0)
        t = CATransform3DScale(t, k, k, 1)
        t = CATransform3DTranslate(t, -b.midX, -b.midY, 0)
        CATransaction.begin()
        CATransaction.setAnimationDuration(DS.Motion.Duration.press)
        CATransaction.setAnimationTimingFunction(DS.Motion.Curve.easeOut)
        layer?.sublayerTransform = t
        CATransaction.commit()
    }

    private func showHint(_ shown: Bool) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = DS.Motion.Duration.fast
            ctx.timingFunction = DS.Motion.Curve.easeOut
            hint.animator().alphaValue = shown ? 1 : 0
        }
    }

    private func withoutAnimation(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }

    /// Says what a click does, on hover only, so the bubble stays clean while someone talks.
    private final class HintBadge: NSView {
        static let side = DS.Size.control
        var symbol = "arrow.up.left.and.arrow.down.right" { didSet { needsDisplay = true } }
        override init(frame: NSRect) {
            super.init(frame: frame)
            appearance = NSAppearance(named: .darkAqua)
            setAccessibilityElement(false)
        }
        required init?(coder: NSCoder) { fatalError() }
        override func draw(_ dirtyRect: NSRect) {
            DS.Color.bgHud.setFill()
            NSBezierPath(ovalIn: bounds).fill()
            Glyph.draw(symbol, in: bounds, pointSize: DS.Size.iconSmall, DS.Color.textPrimary)
        }
    }
}

/// The camera's own window while a recording with the camera runs. It sits over the recorded area where the camera is in the picture,
/// never takes focus, and like the control bar never appears in a recording or a screenshot: the picture gets the camera from the
/// recorder, which draws it the same way.
@MainActor
final class CameraBubbleWindow {
    private let env: AppEnvironment
    private let recording: RecordingController
    private(set) var panel: RecordingPanel?
    private(set) var view: CameraBubbleView?
    private var area: CGRect?
    /// Called with the corner a drag settled in, so the next recording starts there.
    var onCorner: (GridPosition) -> Void = { _ in }

    init(env: AppEnvironment, recording: RecordingController) {
        self.env = env
        self.recording = recording
    }

    /// The bubble's place on screen: the area's points have y down, the screen's y up.
    static func screenRect(_ frame: CameraFrame, area: CGRect) -> CGRect {
        CGRect(x: area.minX + frame.rect.minX, y: area.maxY - frame.rect.maxY, width: frame.rect.width, height: frame.rect.height)
    }

    /// Shows, moves or closes the bubble to match the recording.
    func update(animated: Bool = true) {
        guard let look = recording.cameraLook, recording.phase.isRunning, let area = recording.area else { return close() }
        let bubble = look.current
        let full = look.isFullScreen
        var resting = bubble
        resting.fullScreen = full ? [CameraSpan(from: -1, to: .infinity)] : []
        guard let placed = CameraLayout.frame(resting, area: area.size, at: 0) else { return close() }
        let frame = Self.screenRect(placed, area: area)
        self.area = area
        guard let panel, let view else { return show(frame, placed: placed, full: full) }
        view.isMirrored = placed.isMirrored
        view.isFullScreen = full
        guard panel.frame != frame else {
            view.cornerRadius = placed.cornerRadius
            return
        }
        guard animated, env.isOnscreen, !DS.Motion.isReduced else {
            panel.setFrame(frame, display: true)
            view.cornerRadius = placed.cornerRadius
            return
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = DS.Motion.Duration.slow
            ctx.timingFunction = DS.Motion.Curve.easeInOut
            ctx.allowsImplicitAnimation = true
            panel.animator().setFrame(frame, display: true)
            view.cornerRadius = placed.cornerRadius
        }
    }

    private func show(_ frame: CGRect, placed: CameraFrame, full: Bool) {
        let view = CameraBubbleView(frame: CGRect(origin: .zero, size: frame.size))
        view.autoresizingMask = [.width, .height]
        view.cornerRadius = placed.cornerRadius
        view.isMirrored = placed.isMirrored
        view.isFullScreen = full
        view.onToggle = { [weak self] in self?.recording.changeCamera(.toggleFullScreen) }
        view.onDrop = { [weak self] center in self?.settle(at: center) }
        // Over the darkening and under the control bar, so Stop stays in reach while the camera fills the screen.
        let panel = RecordingPanel(frame: frame, level: NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue - 1), title: "Recording Camera")
        panel.hasShadow = true
        panel.contentView = view
        self.panel = panel
        self.view = view
        recording.cameraFeed.onPicture { [weak view] image in view?.image = image }
        enter(panel)
    }

    private func settle(at center: CGPoint) {
        guard let area else { return }
        let corner = GridPosition.corner(nearest: CGPoint(x: center.x - area.minX, y: area.maxY - center.y), area: area.size)
        recording.changeCamera(CameraChange(corner: corner))
        onCorner(corner)
    }

    func close() {
        recording.cameraFeed.onPicture(nil)
        guard let panel else { return }
        self.panel = nil
        view = nil
        area = nil
        guard env.isOnscreen, panel.isVisible else { return panel.close() }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = DS.Motion.Duration.fast
            ctx.timingFunction = DS.Motion.Curve.easeOut
            panel.animator().alphaValue = 0
        }, completionHandler: { panel.close() })
    }

    /// The same entrance as the control bar: a short fade and a grow from 96%, or only the fade when motion is reduced.
    private func enter(_ panel: RecordingPanel) {
        panel.contentView?.wantsLayer = true
        env.present(panel, activate: false)
        guard env.isOnscreen, let layer = panel.contentView?.layer else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0; fade.toValue = 1
        fade.duration = DS.Motion.Duration.base
        fade.timingFunction = DS.Motion.Curve.easeOut
        layer.add(fade, forKey: "enter")
        guard !DS.Motion.isReduced else { return }
        let grow = CABasicAnimation(keyPath: "transform")
        let b = layer.bounds
        var from = CATransform3DMakeTranslation(b.midX, b.midY, 0)
        from = CATransform3DScale(from, DS.Motion.enterScale, DS.Motion.enterScale, 1)
        from = CATransform3DTranslate(from, -b.midX, -b.midY, 0)
        grow.fromValue = NSValue(caTransform3D: from)
        grow.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        grow.duration = DS.Motion.Duration.base
        grow.timingFunction = DS.Motion.Curve.easeOut
        layer.add(grow, forKey: "grow")
    }
}
