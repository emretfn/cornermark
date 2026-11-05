#if DEBUG
import AppKit
import CornermarkCapture
import QuartzCore

/// A small window with a synthetic moving scene, owned by a scripted instance so verification films it instead of anything real.
/// It is ordered in at the back, in the bottom-left corner of the main display, without activating the app. It never takes key or main,
/// ignores the mouse, and is closed when the recording ends. A window parked beyond the last display was captured too, but its
/// frames arrived unevenly (7% missing at 60 fps), so it stays on screen behind the others.
/// Core Animation moves the bar, so the picture changes on every compositor frame whatever the app is doing.
@MainActor
final class RecordingTestWindow: RecordingTestWindowHosting {
    static let size = CGSize(width: 480, height: 270)

    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    private var panel: Panel?
    private var clock: Timer?
    private var timecode: CATextLayer?
    private var startedAt = CACurrentMediaTime()
    private(set) var windowID: CGWindowID?

    @discardableResult
    func show() -> CGWindowID? {
        close()
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            Log.shell.error("test window: there is no display to place it on")
            return nil
        }
        let origin = CGPoint(x: screen.visibleFrame.minX + 24, y: screen.visibleFrame.minY + 24)
        let panel = Panel(contentRect: CGRect(origin: origin, size: Self.size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Cornermark Test Scene"
        panel.level = .normal
        panel.isFloatingPanel = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.hasShadow = false
        panel.isOpaque = true
        panel.backgroundColor = SyntheticScene.background
        panel.ignoresMouseEvents = true
        panel.animationBehavior = .none
        panel.collectionBehavior = [.ignoresCycle, .stationary]
        let view = NSView(frame: CGRect(origin: .zero, size: Self.size))
        view.wantsLayer = true
        panel.contentView = view
        buildScene(in: view.layer!, scale: screen.backingScaleFactor)
        panel.setFrame(CGRect(origin: origin, size: Self.size), display: false)
        panel.orderBack(nil)
        self.panel = panel
        windowID = CGWindowID(panel.windowNumber)
        startedAt = CACurrentMediaTime()
        clock = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(clock!, forMode: .common)
        Log.shell.notice("test window id=\(panel.windowNumber, privacy: .public) frame=\(NSStringFromRect(panel.frame), privacy: .public) visible=\(panel.isVisible, privacy: .public) appActive=\(NSApp.isActive, privacy: .public)")
        return windowID
    }

    func close() {
        clock?.invalidate()
        clock = nil
        guard let panel else { return }
        Log.shell.notice("test window closed id=\(panel.windowNumber, privacy: .public)")
        panel.orderOut(nil)
        panel.close()
        self.panel = nil
        windowID = nil
        timecode = nil
    }

    private func tick() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        timecode?.string = SyntheticScene.timecode(CACurrentMediaTime() - startedAt)
        CATransaction.commit()
    }

    private func buildScene(in root: CALayer, scale: CGFloat) {
        let w = Self.size.width, h = Self.size.height
        root.backgroundColor = SyntheticScene.background.cgColor
        root.contentsScale = scale

        let barW = w * SyntheticScene.barWidthFraction
        let bar = CALayer()
        bar.backgroundColor = NSColor(white: 0.93, alpha: 1).cgColor
        bar.bounds = CGRect(x: 0, y: 0, width: barW, height: h * 0.52)
        bar.position = CGPoint(x: barW / 2, y: h * 0.5)
        let sweep = CABasicAnimation(keyPath: "position.x")
        sweep.fromValue = barW / 2
        sweep.toValue = w - barW / 2
        sweep.duration = SyntheticScene.barPeriod
        sweep.autoreverses = true
        sweep.repeatCount = .infinity
        sweep.timingFunction = CAMediaTimingFunction(name: .linear)
        bar.add(sweep, forKey: "sweep")
        root.addSublayer(bar)

        let c = min(w, h) * SyntheticScene.cornerFraction
        let origins = [CGPoint(x: 0, y: h - c), CGPoint(x: w - c, y: h - c), CGPoint(x: 0, y: 0), CGPoint(x: w - c, y: 0)]
        for (color, origin) in zip(SyntheticScene.corners, origins) {
            let corner = CALayer()
            corner.backgroundColor = color.cgColor
            corner.frame = CGRect(origin: origin, size: CGSize(width: c, height: c))
            root.addSublayer(corner)
        }

        let clockLayer = text(SyntheticScene.timecode(0), size: h * 0.15, weight: .bold, white: 1, frame: CGRect(x: 0, y: h * 0.40, width: w, height: h * 0.2), scale: scale)
        clockLayer.font = NSFont.monospacedDigitSystemFont(ofSize: h * 0.15, weight: .bold)
        timecode = clockLayer
        root.addSublayer(clockLayer)
        root.addSublayer(text(SyntheticScene.caption, size: h * 0.05, weight: .semibold, white: 0.85, frame: CGRect(x: 0, y: h - h * 0.04 - h * 0.08, width: w, height: h * 0.08), scale: scale))
        root.addSublayer(text(SyntheticScene.note, size: h * 0.04, weight: .regular, white: 0.6, frame: CGRect(x: 0, y: h * 0.04, width: w, height: h * 0.07), scale: scale))
    }

    private func text(_ string: String, size: CGFloat, weight: NSFont.Weight, white: CGFloat, frame: CGRect, scale: CGFloat) -> CATextLayer {
        let layer = CATextLayer()
        layer.string = string
        layer.font = NSFont.systemFont(ofSize: size, weight: weight)
        layer.fontSize = size
        layer.foregroundColor = NSColor(white: white, alpha: 1).cgColor
        layer.alignmentMode = .center
        layer.contentsScale = scale
        layer.frame = frame
        return layer
    }
}
#endif
