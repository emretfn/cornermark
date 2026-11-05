import AppKit
import CornermarkCore
import CornermarkDesign

/// The ruler, the zoom lane and the clip lane under one playhead. A click or a drag anywhere on it moves the playhead; on the clip lane
/// it also picks the clip, and a drag that starts on a clip's edge trims it.
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
        /// How far from a clip's edge a press still takes the edge.
        static let edgeReach: CGFloat = 6
        /// The space a cut leaves between two clips.
        static let seam: CGFloat = 2
    }

    enum Scrub { case began, moved, ended }

    /// A trim under way: the clip and edge, the timeline before it, and the zoom it started at, kept until the drag ends so the
    /// edge stays under the pointer while the rest of the video makes room.
    struct Trim {
        var index: Int
        var edge: ClipTimeline.Edge
        var before: ClipTimeline
        var pointsPerSecond: Double
        var pressX: Double
    }

    var timeline = ClipTimeline(clips: [], source: .init()) {
        didSet {
            needsDisplay = true
            placePlayhead()
            window?.invalidateCursorRects(for: self)
        }
    }
    var duration: Double { timeline.duration }
    /// The clip the next Delete removes; nil when none was picked.
    var selection: Int? { didSet { if oldValue != selection { needsDisplay = true } } }
    /// Moving the playhead moves its own view, so the lanes and their pictures are not drawn again on every frame.
    var time: Double = 0 { didSet { if oldValue != time { placePlayhead() } } }
    /// Pictures of the recording at even source times from start to end, for the clip lane.
    var thumbnails: [CGImage] = [] { didSet { needsDisplay = true } }
    /// The recording's width over its height.
    var aspect: CGFloat = 16 / 9 { didSet { needsDisplay = true } }
    var onScrub: (Double, Scrub) -> Void = { _, _ in }
    var onSelect: (Int?) -> Void = { _ in }
    /// The trimmed timeline as the edge moves, then once more as the drag ends.
    var onTrim: (Trim, ClipTimeline, Scrub) -> Void = { _, _, _ in }
    /// A key moved an edge of the picked clip, or of the clip under the playhead, by this many seconds.
    var onNudge: (ClipTimeline.Edge, Double) -> Void = { _, _ in }
    /// One arrow key press moves the playhead this far; Shift moves it a second.
    var frameStep: Double = 1.0 / 60
    private let playhead = PlayheadView()
    private(set) var trim: Trim?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        addSubview(playhead)
        setAccessibilityElement(true)
        setAccessibilityRole(.slider)
        setAccessibilityLabel("Timeline")
        setAccessibilityIdentifier("video.timeline")
        setAccessibilityHelp(Self.keyHelp)
    }

    static let keyHelp = "Left and Right move the playhead a frame. Option with Left or Right moves the clip's start, Option-Command its end. Shift makes each step a second."


    required init?(coder: NSCoder) { fatalError("TimelineView is created in code") }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: Metrics.height) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }

    // MARK: Keyboard

    /// Left and right step a frame, a second with Shift; Home and End jump to the ends. The pointer's click and drag do the same.
    /// With Option the arrows trim instead: the clip's start, or with Command its end, so every drag on an edge has a key too.
    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags
        let second = flags.contains(.shift)
        let size = second ? 1 : frameStep
        if flags.contains(.option), event.keyCode == 123 || event.keyCode == 124 {
            return onNudge(flags.contains(.command) ? .end : .start, event.keyCode == 123 ? -size : size)
        }
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

    /// Where each second sits. While an edge is dragged the zoom stays as it was, and the side of the clip away from the edge stays put.
    var scale: TimelineScale {
        let start = Double(Metrics.gutter)
        guard let trim else { return TimelineScale(duration: duration, start: start, end: Double(bounds.width - Metrics.trailing)) }
        let shift: Double
        switch trim.edge {
        case .end: shift = 0
        case .start: shift = (end(of: trim.index, in: trim.before) - end(of: trim.index, in: timeline)) * trim.pointsPerSecond
        }
        return TimelineScale(duration: duration, start: start + shift, end: start + shift + duration * trim.pointsPerSecond)
    }

    private func end(of index: Int, in t: ClipTimeline) -> Double {
        t.starts[min(index, t.clips.count - 1)] + t.clips[min(index, t.clips.count - 1)].duration
    }

    var rulerRect: CGRect { CGRect(x: 0, y: Metrics.top, width: bounds.width, height: Metrics.ruler) }
    var zoomLaneRect: CGRect { lane(y: rulerRect.maxY + Metrics.gap, height: Metrics.zoomLane) }
    var clipLaneRect: CGRect { lane(y: zoomLaneRect.maxY + Metrics.gap, height: Metrics.clipLane) }

    private func lane(y: CGFloat, height: CGFloat) -> CGRect {
        CGRect(x: Metrics.gutter, y: y, width: max(bounds.width - Metrics.gutter - Metrics.trailing, 0), height: height)
    }

    /// Each clip's box on the clip lane, a seam apart at every cut.
    var clipRects: [CGRect] {
        let s = scale, lane = clipLaneRect, last = timeline.clips.count - 1
        return zip(timeline.clips, timeline.starts).enumerated().map { i, pair in
            let x0 = CGFloat(s.x(pair.1)) + (i > 0 ? Metrics.seam / 2 : 0)
            let x1 = CGFloat(s.x(pair.1 + pair.0.duration)) - (i < last ? Metrics.seam / 2 : 0)
            return CGRect(x: x0, y: lane.minY, width: max(x1 - x0, 1), height: lane.height)
        }
    }

    /// The x of every cut, where the clip lane draws its marks.
    var cutMarks: [CGFloat] { timeline.cuts.map { CGFloat(scale.x($0)).rounded() } }

    override func accessibilityValue() -> Any? {
        let n = timeline.clips.count
        guard n > 1 else { return Timecode.text(time) }
        let picked = selection.map { ", clip \($0 + 1) picked" } ?? ""
        return "\(Timecode.text(time)), clip \(timeline.clipIndex(at: time) + 1) of \(n)\(picked)"
    }

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
        drawClips()
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

    private func drawClips() {
        guard duration > 0, let ctx = NSGraphicsContext.current?.cgContext else { return }
        NSGraphicsContext.saveGraphicsState()
        CGRect(x: Metrics.gutter, y: 0, width: max(bounds.width - Metrics.gutter, 0), height: bounds.height).clip()
        let rects = clipRects
        for (i, rect) in rects.enumerated() { drawClip(i, in: rect, ctx) }
        drawCutMarks()
        if let i = selection, rects.indices.contains(i) { drawSelection(rects[i]) }
        NSGraphicsContext.restoreGraphicsState()
    }

    /// A clip's pictures come from its own stretch of the recording, so a cut shows where the picture jumps.
    private func drawClip(_ i: Int, in rect: CGRect, _ ctx: CGContext) {
        let shape = NSBezierPath.continuous(rect, radius: DS.Radius.sm)
        shape.fill(with: DS.Color.bgControl)
        if !thumbnails.isEmpty, timeline.sourceDuration > 0 {
            NSGraphicsContext.saveGraphicsState()
            shape.addClip()
            let s = scale, clip = timeline.clips[i], start = timeline.starts[i]
            let slot = max((rect.height * aspect).rounded(), 1)
            var x = rect.minX
            while x < rect.maxX {
                let source = clip.start + min(max(s.time(Double(x + slot / 2)) - start, 0), clip.duration)
                let n = min(Int((source / timeline.sourceDuration * Double(thumbnails.count)).rounded(.down)), thumbnails.count - 1)
                ctx.saveGState()
                ctx.translateBy(x: x, y: rect.maxY)
                ctx.scaleBy(x: 1, y: -1)
                ctx.interpolationQuality = .medium
                ctx.draw(thumbnails[max(n, 0)], in: CGRect(x: 0, y: 0, width: slot, height: rect.height))
                ctx.restoreGState()
                x += slot
            }
            NSGraphicsContext.restoreGraphicsState()
        }
        DS.Color.border.setStroke()
        let edge = NSBezierPath.continuous(rect.insetBy(dx: 0.5, dy: 0.5), radius: DS.Radius.sm - 0.5)
        edge.lineWidth = 1
        edge.stroke()
    }

    /// A notch above and below the clip lane at every cut, pointing at the seam.
    private func drawCutMarks() {
        let lane = clipLaneRect, w: CGFloat = 8, h: CGFloat = 5
        DS.Color.textSecondary.setFill()
        for x in cutMarks {
            for (base, tip) in [(lane.minY - h - 1, lane.minY - 1), (lane.maxY + h + 1, lane.maxY + 1)] {
                let notch = NSBezierPath()
                notch.move(to: CGPoint(x: x - w / 2, y: base))
                notch.line(to: CGPoint(x: x + w / 2, y: base))
                notch.line(to: CGPoint(x: x, y: tip))
                notch.close()
                notch.fill()
            }
        }
    }

    /// The picked clip: the selection frame of the picture editor, with a grip on each edge that can be dragged.
    private func drawSelection(_ rect: CGRect) {
        let frame = NSBezierPath.continuous(rect.insetBy(dx: 1, dy: 1), radius: DS.Radius.sm - 1)
        frame.lineWidth = 4
        DS.Color.selectionHalo.setStroke()
        frame.stroke()
        frame.lineWidth = 2
        DS.Color.selectionStroke.setStroke()
        frame.stroke()
        let grip = CGSize(width: 4, height: (rect.height * 0.45).rounded())
        for x in [rect.minX + 1, rect.maxX - 1] {
            let bar = NSBezierPath(roundedRect: CGRect(x: x - grip.width / 2, y: rect.midY - grip.height / 2, width: grip.width, height: grip.height),
                                   xRadius: grip.width / 2, yRadius: grip.width / 2)
            bar.lineWidth = 2
            DS.Color.selectionHalo.setStroke()
            bar.stroke()
            bar.fill(with: DS.Color.selectionStroke)
        }
    }

    // MARK: Pointer

    override func resetCursorRects() {
        let lane = clipLaneRect
        for rect in clipRects {
            for x in [rect.minX, rect.maxX] {
                addCursorRect(CGRect(x: x - Metrics.edgeReach, y: lane.minY, width: Metrics.edgeReach * 2, height: lane.height), cursor: .resizeLeftRight)
            }
        }
    }

    /// The clip edge a press at `p` takes, if any. Where two clips meet, the side of the seam the pointer is on decides.
    func edge(at p: CGPoint) -> (index: Int, edge: ClipTimeline.Edge)? {
        guard clipLaneRect.insetBy(dx: -Metrics.edgeReach, dy: 0).contains(p) else { return nil }
        var best: (index: Int, edge: ClipTimeline.Edge, score: CGFloat)?
        for (i, rect) in clipRects.enumerated() {
            for (edge, x) in [(ClipTimeline.Edge.start, rect.minX), (.end, rect.maxX)] {
                let away = abs(p.x - x)
                guard away <= Metrics.edgeReach else { continue }
                let wrongSide = (edge == .start && p.x < x) || (edge == .end && p.x > x)
                let score = away + (wrongSide ? Metrics.edgeReach : 0)
                if best == nil || score < best!.score { best = (i, edge, score) }
            }
        }
        return best.map { ($0.index, $0.edge) }
    }

    /// Ends a drag on an edge without another edit, when something else changed the clips under it or its mouse-up never came.
    func cancelTrim() {
        guard trim != nil else { return }
        trim = nil
        NSCursor.pop()
        needsDisplay = true
        placePlayhead()
        window?.invalidateCursorRects(for: self)
    }

    override func mouseDown(with event: NSEvent) {
        cancelTrim()
        let p = convert(event.locationInWindow, from: nil)
        if let hit = edge(at: p) {
            trim = Trim(index: hit.index, edge: hit.edge, before: timeline, pointsPerSecond: scale.pointsPerSecond, pressX: Double(p.x))
            onSelect(hit.index)
            NSCursor.resizeLeftRight.push()
            moveTrim(to: p, .began)
            return
        }
        if clipLaneRect.contains(p) {
            let t = scale.time(Double(p.x))
            onSelect(clipRects.contains { $0.minX <= p.x && p.x <= $0.maxX } ? timeline.clipIndex(at: t) : nil)
        }
        scrub(event, .began)
    }

    override func mouseDragged(with event: NSEvent) {
        if trim != nil { return moveTrim(to: convert(event.locationInWindow, from: nil), .moved) }
        scrub(event, .moved)
    }

    override func mouseUp(with event: NSEvent) {
        if trim != nil {
            moveTrim(to: convert(event.locationInWindow, from: nil), .ended)
            return cancelTrim()
        }
        scrub(event, .ended)
    }

    /// The edge follows the pointer from where it was pressed, frame by frame of the source.
    private func moveTrim(to p: CGPoint, _ phase: Scrub) {
        guard let trim else { return }
        let clip = trim.before.clips[trim.index]
        let was = trim.edge == .start ? clip.start : clip.end
        let moved = trim.before.trimming(trim.index, trim.edge, to: was + (Double(p.x) - trim.pressX) / max(trim.pointsPerSecond, 1e-9))
        onTrim(trim, moved, phase)
    }

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
