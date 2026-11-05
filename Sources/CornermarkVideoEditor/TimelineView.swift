import AppKit
import CornermarkDesign

/// The ruler, the zoom lane and the clip lane under one playhead. A click or a drag anywhere on it moves the playhead.
final class TimelineView: NSView {
    enum Metrics {
        static let gutter: CGFloat = 36
        static let trailing: CGFloat = DS.Space.s16
        static let top: CGFloat = DS.Space.s8
        static let ruler: CGFloat = 24
        static let gap: CGFloat = DS.Space.s6
        static let zoomLane: CGFloat = 28
        static let clipLane: CGFloat = 52
        static let bottom: CGFloat = DS.Space.s12
        static var height: CGFloat { top + ruler + gap + zoomLane + gap + clipLane + bottom }
        static let labelSpacing: CGFloat = 72
    }

    enum Scrub { case began, moved, ended }

    var duration: Double = 0 { didSet { needsDisplay = true } }
    /// Moving the playhead moves its own view, so the lanes and their pictures are not drawn again on every frame.
    var time: Double = 0 { didSet { if oldValue != time { placePlayhead() } } }
    /// Pictures of the recording at even times from start to end, for the clip lane.
    var thumbnails: [CGImage] = [] { didSet { needsDisplay = true } }
    /// The recording's width over its height.
    var aspect: CGFloat = 16 / 9 { didSet { needsDisplay = true } }
    var onScrub: (Double, Scrub) -> Void = { _, _ in }
    /// One arrow key press moves the playhead this far; Shift moves it a second.
    var frameStep: Double = 1.0 / 60
    private let playhead = PlayheadView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        addSubview(playhead)
        setAccessibilityElement(true)
        setAccessibilityRole(.slider)
        setAccessibilityLabel("Timeline")
        setAccessibilityIdentifier("video.timeline")
    }

    required init?(coder: NSCoder) { fatalError("TimelineView is created in code") }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: Metrics.height) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }

    // MARK: Keyboard

    /// Left and right step a frame, a second with Shift; Home and End jump to the ends. The pointer's click and drag do the same.
    override func keyDown(with event: NSEvent) {
        let second = event.modifierFlags.contains(.shift)
        switch event.keyCode {
        case 123: step(second ? -1 : -frameStep)
        case 124: step(second ? 1 : frameStep)
        case 115: jump(to: 0)
        case 119: jump(to: duration)
        default: super.keyDown(with: event)
        }
    }

    override func accessibilityPerformIncrement() -> Bool { step(1); return true }
    override func accessibilityPerformDecrement() -> Bool { step(-1); return true }

    private func step(_ seconds: Double) { jump(to: time + seconds) }

    private func jump(to t: Double) {
        onScrub(min(max(t, 0), duration), .began)
        onScrub(min(max(t, 0), duration), .ended)
    }

    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() { NSBezierPath.continuous(bounds.insetBy(dx: 2, dy: 2), radius: DS.Radius.sm).fill() }

    var scale: TimelineScale {
        TimelineScale(duration: duration, start: Double(Metrics.gutter), end: Double(bounds.width - Metrics.trailing))
    }

    var rulerRect: CGRect { CGRect(x: 0, y: Metrics.top, width: bounds.width, height: Metrics.ruler) }
    var zoomLaneRect: CGRect { lane(y: rulerRect.maxY + Metrics.gap, height: Metrics.zoomLane) }
    var clipLaneRect: CGRect { lane(y: zoomLaneRect.maxY + Metrics.gap, height: Metrics.clipLane) }

    private func lane(y: CGFloat, height: CGFloat) -> CGRect {
        CGRect(x: Metrics.gutter, y: y, width: max(bounds.width - Metrics.gutter - Metrics.trailing, 0), height: height)
    }

    override func accessibilityValue() -> Any? { Timecode.text(time) }

    override func layout() {
        super.layout()
        placePlayhead()
    }

    private func placePlayhead() {
        let x = CGFloat(scale.x(time)).rounded()
        playhead.frame = CGRect(x: x - PlayheadView.width / 2, y: rulerRect.minY, width: PlayheadView.width, height: clipLaneRect.maxY - rulerRect.minY)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        DS.Color.bgWindow.setFill()
        bounds.fill()
        drawRuler()
        drawLaneGlyph("plus.magnifyingglass", in: zoomLaneRect)
        drawLaneGlyph("film", in: clipLaneRect)
        NSBezierPath.continuous(zoomLaneRect, radius: DS.Radius.sm).fill(with: DS.Color.bgSunken)
        drawClip()
    }

    private func drawRuler() {
        let s = scale
        let step = s.majorStep(minSpacing: Double(Metrics.labelSpacing))
        let minor = step / (step * s.pointsPerSecond >= 60 ? 5 : 2)
        let r = rulerRect
        DS.Color.border.setFill()
        if minor * s.pointsPerSecond >= 6 {
            var t = 0.0
            while t <= duration + 1e-9 {
                CGRect(x: CGFloat(s.x(t)).rounded() - 0.5, y: r.maxY - 4, width: 1, height: 4).fill()
                t += minor
            }
        }
        let attrs = DS.Text.readout.attributes(color: DS.Color.textSecondary)
        var labelEnd = -CGFloat.infinity
        for t in s.ticks(minSpacing: Double(Metrics.labelSpacing)) {
            let x = CGFloat(s.x(t)).rounded()
            DS.Color.borderStrong.setFill()
            CGRect(x: x - 0.5, y: r.maxY - 8, width: 1, height: 8).fill()
            let label = Timecode.label(t, step: step) as NSString
            let size = label.size(withAttributes: attrs)
            // Clear of the playhead's head when it rests on the tick.
            let lx = min(x + DS.Space.s8, bounds.width - Metrics.trailing - size.width)
            // The last label is pushed in from the edge; it keeps its tick but not its text when it would run into the one before.
            guard lx >= labelEnd + DS.Space.s8 else { continue }
            label.draw(at: CGPoint(x: lx, y: r.minY + 1), withAttributes: attrs)
            labelEnd = lx + size.width
        }
    }

    private func drawLaneGlyph(_ symbol: String, in lane: CGRect) {
        let box = CGRect(x: 0, y: lane.minY, width: Metrics.gutter, height: lane.height)
        Glyph.draw(symbol, in: box, pointSize: DS.Size.icon, DS.Color.textSecondary)
    }

    private func drawClip() {
        let lane = clipLaneRect
        guard duration > 0, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let clip = CGRect(x: CGFloat(scale.x(0)), y: lane.minY, width: CGFloat(scale.x(duration) - scale.x(0)), height: lane.height)
        let shape = NSBezierPath.continuous(clip, radius: DS.Radius.sm)
        shape.fill(with: DS.Color.bgControl)
        if !thumbnails.isEmpty {
            NSGraphicsContext.saveGraphicsState()
            shape.addClip()
            let slot = max((lane.height * aspect).rounded(), 1)
            var x = clip.minX
            while x < clip.maxX {
                let t = scale.time(Double(x + slot / 2))
                let i = min(Int((t / duration * Double(thumbnails.count)).rounded(.down)), thumbnails.count - 1)
                let image = thumbnails[max(i, 0)]
                ctx.saveGState()
                ctx.translateBy(x: x, y: clip.maxY)
                ctx.scaleBy(x: 1, y: -1)
                ctx.interpolationQuality = .medium
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: slot, height: clip.height))
                ctx.restoreGState()
                x += slot
            }
            NSGraphicsContext.restoreGraphicsState()
        }
        DS.Color.border.setStroke()
        let edge = NSBezierPath.continuous(clip.insetBy(dx: 0.5, dy: 0.5), radius: DS.Radius.sm - 0.5)
        edge.lineWidth = 1
        edge.stroke()
    }


    // MARK: Scrubbing

    override func mouseDown(with event: NSEvent) { scrub(event, .began) }
    override func mouseDragged(with event: NSEvent) { scrub(event, .moved) }
    override func mouseUp(with event: NSEvent) { scrub(event, .ended) }

    private func scrub(_ event: NSEvent, _ phase: Scrub) {
        let x = convert(event.locationInWindow, from: nil).x
        onScrub(scale.time(Double(x)), phase)
    }
}

extension NSBezierPath {
    func fill(with color: NSColor) {
        color.setFill()
        fill()
    }
}

/// The playhead: a strong neutral line with a head in the ruler. It marks a moment, not a selection, so it takes no accent.
final class PlayheadView: NSView {
    static let width: CGFloat = 12

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let mid = bounds.midX
        DS.Color.bgInverse.setFill()
        CGRect(x: mid - 1, y: 6, width: 2, height: bounds.height - 6).fill()
        let head = NSBezierPath()
        head.move(to: CGPoint(x: mid - 6, y: 0))
        head.line(to: CGPoint(x: mid + 6, y: 0))
        head.line(to: CGPoint(x: mid + 6, y: 7))
        head.line(to: CGPoint(x: mid, y: 13))
        head.line(to: CGPoint(x: mid - 6, y: 7))
        head.close()
        head.fill()
    }
}
