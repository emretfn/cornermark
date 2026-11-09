import AppKit
import CornermarkCore
import CornermarkDesign
import CornermarkL10n

/// The zoom lane. A click on empty lane adds a zoom of the default length, a drag adds one over the dragged stretch. A zoom's
/// body moves it, its edges resize it, and a right click opens its menu. It only reports gestures; the editor applies them.
final class ZoomLaneView: NSView, KeepsLeftToRight {
    enum Gesture: Equatable {
        case move(UUID, start: Double)
        case resize(UUID, ZoomLane.Edge, to: Double)
    }

    /// The focused lane's keys: arrows pick the zoom before or after, Option-arrows move the picked zoom, Option-Command-arrows move
    /// its end. Shift makes a step a second instead of a tenth.
    enum KeyCommand: Equatable {
        case pick(Int)
        case move(by: Double)
        case resizeEnd(by: Double)
    }

    var zooms: [Zoom] = [] { didSet { if oldValue != zooms { changed() } } }
    var selection: UUID? { didSet { if oldValue != selection { changed() } } }
    /// The timeline's own scale, so the lane lines up with the ruler and the clips, also while a trim holds the zoom still.
    var timelineScale: () -> TimelineScale = { TimelineScale(duration: 0, start: 0, end: 0) }
    var duration: Double { scale.duration }

    /// `to` is nil for a click.
    var onAdd: (_ from: Double, _ to: Double?) -> Void = { _, _ in }
    var onSelect: (UUID?) -> Void = { _ in }
    var onGesture: (Gesture, TimelineView.Scrub) -> Void = { _, _ in }
    var menuForZoom: (UUID) -> NSMenu? = { _ in nil }
    var onKey: (KeyCommand) -> Void = { _ in }

    static var hint: String { tr("Click or drag to add a zoom") }
    /// Points of a zoom's edge that resize it instead of moving it.
    static let edgeGrab: CGFloat = 6
    /// A press that moves less than this is a click.
    static let dragSlop: CGFloat = 3

    /// What the pointer is doing in the lane. One value, so a drag and a hover never disagree.
    private enum Interaction: Equatable {
        case idle
        case hovering(x: CGFloat)
        case adding(from: CGFloat, to: CGFloat)
        case moving(UUID, grab: Double, downX: CGFloat, moved: Bool)
        /// `offset` is the edge's time less the pressed time, so the edge stays where it was under the pointer.
        case resizing(UUID, ZoomLane.Edge, offset: Double, moved: Bool)
    }

    private enum Hit: Equatable {
        case empty
        case body(UUID)
        case edge(UUID, ZoomLane.Edge)
    }

    private var interaction = Interaction.idle { didSet { if oldValue != interaction { needsDisplay = true } } }
    private var tracking: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        relocalize()
        setAccessibilityIdentifier("video.zoomLane")
    }

    /// Reads the accessibility texts again in the current language.
    func relocalize() {
        setAccessibilityLabel(tr("Zooms"))
        setAccessibilityHelp(Self.hint)
        needsDisplay = true
    }

    required init?(coder: NSCoder) { fatalError("ZoomLaneView is created in code") }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() { NSBezierPath.continuous(bounds, radius: DS.Radius.sm).fill() }

    /// The arrows pick the previous or next zoom; with Option they move the picked zoom, with Option-Command its end, 0.1 s a press or a
    /// second with Shift. The keys come from `EditorShortcuts`.
    override func keyDown(with event: NSEvent) {
        guard let press = EditorShortcuts.match(event, in: .zoomLane) else { return super.keyDown(with: event) }
        let step = (press.enlarged ? 1.0 : 0.1) * (press.forward ? 1 : -1)
        switch press.command {
        case .pickZoom: onKey(.pick(press.forward ? 1 : -1))
        case .moveZoom: onKey(.move(by: step))
        case .resizeZoom: onKey(.resizeEnd(by: step))
        default: super.keyDown(with: event)
        }
    }

    /// The timeline's scale in the lane's own points.
    var scale: TimelineScale {
        let s = timelineScale()
        return TimelineScale(duration: s.duration, start: s.start - Double(frame.minX), end: s.end - Double(frame.minX))
    }

    func rect(of zoom: Zoom) -> CGRect {
        let s = scale
        let x0 = CGFloat(s.x(zoom.start)).rounded(), x1 = CGFloat(s.x(zoom.end)).rounded()
        return CGRect(x: x0, y: 2, width: max(x1 - x0, 2), height: bounds.height - 4)
    }

    private func changed() {
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
        NSAccessibility.post(element: self, notification: .layoutChanged)
    }

    /// The pointer rests on empty lane where a zoom fits, so the lane shows where a click puts one and says what a click or drag does.
    var showsHint: Bool {
        guard case .hovering(let x) = interaction, case .empty = hit(CGPoint(x: x, y: bounds.midY)) else { return false }
        return clickGhost(at: x) != nil
    }

    // MARK: Drawing

    /// A lane with no zoom yet says what it is for across its whole width, so adding the first zoom does not wait on a hover.
    var showsEmptyHint: Bool {
        guard zooms.isEmpty, duration > 0 else { return false }
        switch interaction {
        case .adding: return false
        case .hovering: return !showsHint
        default: return true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        for zoom in zooms { drawBlock(zoom) }
        if showsEmptyHint { drawEmptyHint() }
        switch interaction {
        case .adding(let a, let b):
            drawGhost(CGRect(x: min(a, b), y: 2, width: max(abs(b - a), 2), height: bounds.height - 4), hint: false)
        case .hovering(let x):
            if showsHint, let ghost = clickGhost(at: x) { drawGhost(ghost, hint: true) }
        default: break
        }
    }

    private func drawBlock(_ zoom: Zoom) {
        let r = rect(of: zoom)
        let picked = zoom.id == selection
        let c = DS.Color.self
        let radius = DS.Radius.sm
        NSBezierPath.continuous(r, radius: radius).fill(with: picked ? c.accentSubtle : c.bgControlActive)

        // The strong border keeps 3:1 against the lane, so a zoom too short for its label still reads as one.
        (picked ? c.accentBorder : c.borderStrong).setStroke()
        let edge = NSBezierPath.continuous(r.insetBy(dx: 0.5, dy: 0.5), radius: radius - 0.5)
        edge.lineWidth = 1
        edge.stroke()

        // Level and mode sit between the handles; what does not fit is left out, the level last.
        let ink = picked ? c.accentText : c.textPrimary
        let quiet = picked ? c.accentText : c.textSecondary
        let level = Digits.percent(zoom.scale) as NSString, mode = zoom.mode.localizedTitle as NSString
        let levelAttrs = DS.Text.readout.attributes(color: ink), modeAttrs = DS.Text.caption.attributes(color: quiet)
        let levelSize = level.size(withAttributes: levelAttrs), modeSize = mode.size(withAttributes: modeAttrs)
        let icon = DS.Size.iconSmall
        let grip = Self.edgeGrab
        let left = r.minX + grip + DS.Space.s6, right = r.maxX - grip - DS.Space.s6
        let room = right - left
        let full = icon + DS.Space.s4 + levelSize.width
        func line(_ size: CGSize) -> CGFloat { (r.midY - size.height / 2).rounded() }
        if room >= full {
            let x = left.rounded()
            Glyph.draw("plus.magnifyingglass", in: CGRect(x: x, y: r.minY, width: icon, height: r.height), pointSize: icon, ink)
            level.draw(at: CGPoint(x: x + icon + DS.Space.s4, y: line(levelSize)), withAttributes: levelAttrs)
            if room >= full + DS.Space.s6 + modeSize.width {
                mode.draw(at: CGPoint(x: (x + full + DS.Space.s6).rounded(.up), y: line(modeSize)), withAttributes: modeAttrs)
            }
        } else if r.width - 2 * grip >= levelSize.width {
            level.draw(at: CGPoint(x: (r.midX - levelSize.width / 2).rounded(), y: line(levelSize)), withAttributes: levelAttrs)
        }

        // Handles at both ends, as tall as the lane allows, so the edges read as grabbable.
        if r.width > 3 * grip {
            let height = min(DS.Space.s16, r.height - 2 * DS.Space.s6)
            (picked ? c.accentText : c.textSecondary).setFill()
            for x in [r.minX + 2, r.maxX - 5] {
                NSBezierPath.continuous(CGRect(x: x, y: (r.midY - height / 2).rounded(), width: 3, height: height), radius: 1.5).fill()
            }
        }
    }

    private func drawEmptyHint() {
        let r = bounds.insetBy(dx: 2, dy: 2)
        let shape = NSBezierPath.continuous(r.insetBy(dx: 0.5, dy: 0.5), radius: DS.Radius.xs - 0.5)
        DS.Color.borderSubtle.setStroke()
        shape.lineWidth = 1
        shape.setLineDash([3, 2], count: 2, phase: 0)
        shape.stroke()
        let text = Self.hint as NSString
        let attrs = DS.Text.caption.attributes(color: DS.Color.textSecondary)
        let size = text.size(withAttributes: attrs)
        let icon = DS.Size.iconSmall
        let width = icon + DS.Space.s4 + size.width
        guard width <= r.width - 2 * DS.Space.s8 else { return }
        let x = (r.midX - width / 2).rounded()
        Glyph.draw("plus", in: CGRect(x: x, y: r.minY, width: icon, height: r.height), pointSize: icon, DS.Color.textSecondary)
        text.draw(at: CGPoint(x: x + icon + DS.Space.s4, y: (r.midY - size.height / 2).rounded()), withAttributes: attrs)
    }

    /// Where a click at `x` would put a zoom.
    private func clickGhost(at x: CGFloat) -> CGRect? {
        let lane = ZoomLane(zooms, duration: duration)
        guard let added = lane.adding(from: scale.time(Double(x))) else { return nil }
        return rect(of: added.zoom)
    }

    private func drawGhost(_ r: CGRect, hint: Bool) {
        let shape = NSBezierPath.continuous(r.insetBy(dx: 0.5, dy: 0.5), radius: DS.Radius.xs - 0.5)
        shape.fill(with: DS.Color.bgControlHover)
        DS.Color.borderStrong.setStroke()
        shape.lineWidth = 1
        shape.setLineDash([3, 2], count: 2, phase: 0)
        shape.stroke()
        Glyph.draw("plus", in: CGRect(x: r.minX, y: r.minY, width: min(r.width, 24), height: r.height), pointSize: DS.Size.iconSmall, DS.Color.textSecondary)
        guard hint else { return }
        let text = Self.hint as NSString
        let attrs = DS.Text.caption.attributes(color: DS.Color.textSecondary)
        let size = text.size(withAttributes: attrs)
        let y = (r.midY - size.height / 2).rounded()
        if r.maxX + DS.Space.s8 + size.width <= bounds.maxX {
            text.draw(at: CGPoint(x: r.maxX + DS.Space.s8, y: y), withAttributes: attrs)
        } else if r.minX - DS.Space.s8 - size.width >= bounds.minX {
            text.draw(at: CGPoint(x: r.minX - DS.Space.s8 - size.width, y: y), withAttributes: attrs)
        }
    }

    // MARK: Pointer

    private func hit(_ p: CGPoint) -> Hit {
        for zoom in zooms {
            let r = rect(of: zoom)
            guard p.x >= r.minX - 2, p.x <= r.maxX + 2 else { continue }
            let grab = min(Self.edgeGrab, r.width / 3)
            if p.x <= r.minX + grab { return .edge(zoom.id, .start) }
            if p.x >= r.maxX - grab { return .edge(zoom.id, .end) }
            return .body(zoom.id)
        }
        return .empty
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func resetCursorRects() {
        for zoom in zooms {
            let r = rect(of: zoom)
            let grab = min(Self.edgeGrab, r.width / 3)
            addCursorRect(CGRect(x: r.minX - 2, y: 0, width: grab + 2, height: bounds.height), cursor: .resizeLeftRight)
            addCursorRect(CGRect(x: r.maxX - grab, y: 0, width: grab + 2, height: bounds.height), cursor: .resizeLeftRight)
        }
    }

    override func mouseMoved(with event: NSEvent) { hover(event) }
    override func mouseEntered(with event: NSEvent) { hover(event) }
    override func mouseExited(with event: NSEvent) { if case .hovering = interaction { interaction = .idle } }

    private func hover(_ event: NSEvent) {
        switch interaction {
        case .idle, .hovering: interaction = .hovering(x: point(event).x)
        default: break
        }
    }

    private func point(_ event: NSEvent) -> CGPoint { convert(event.locationInWindow, from: nil) }
    private func time(_ x: CGFloat) -> Double { scale.time(Double(x)) }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = point(event)
        switch hit(p) {
        case .empty:
            interaction = .adding(from: p.x, to: p.x)
        case .body(let id):
            onSelect(id)
            guard let zoom = zooms.first(where: { $0.id == id }) else { return }
            interaction = .moving(id, grab: time(p.x) - zoom.start, downX: p.x, moved: false)
        case .edge(let id, let edge):
            onSelect(id)
            guard let zoom = zooms.first(where: { $0.id == id }) else { return }
            interaction = .resizing(id, edge, offset: (edge == .start ? zoom.start : zoom.end) - time(p.x), moved: false)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let p = point(event)
        switch interaction {
        case .adding(let from, _):
            interaction = .adding(from: from, to: min(max(p.x, 0), bounds.width))
        case .moving(let id, let grab, let downX, let moved):
            guard moved || abs(p.x - downX) >= Self.dragSlop else { return }
            interaction = .moving(id, grab: grab, downX: downX, moved: true)
            onGesture(.move(id, start: time(p.x) - grab), moved ? .moved : .began)
        case .resizing(let id, let edge, let offset, let moved):
            interaction = .resizing(id, edge, offset: offset, moved: true)
            onGesture(.resize(id, edge, to: time(p.x) + offset), moved ? .moved : .began)
        default: break
        }
    }

    override func mouseUp(with event: NSEvent) {
        let p = point(event)
        let ended = interaction
        interaction = .hovering(x: p.x)
        switch ended {
        case .adding(let from, let to):
            abs(to - from) < Self.dragSlop ? onAdd(time(from), nil) : onAdd(time(from), time(to))
        case .moving(let id, let grab, _, true):
            onGesture(.move(id, start: time(p.x) - grab), .ended)
        case .resizing(let id, let edge, let offset, true):
            onGesture(.resize(id, edge, to: time(p.x) + offset), .ended)
        default: break
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let id: UUID
        switch hit(point(event)) {
        case .body(let z), .edge(let z, _): id = z
        case .empty: return nil
        }
        onSelect(id)
        return menuForZoom(id)
    }

    // MARK: Accessibility

    override func accessibilityChildren() -> [Any]? {
        zooms.map { zoom in
            let element = ZoomAccessibilityElement()
            element.setAccessibilityParent(self)
            element.setAccessibilityRole(.button)
            element.setAccessibilityLabel(tr("Zoom {level}, {start} to {end}", ["level": Digits.percent(zoom.scale), "start": Timecode.text(zoom.start), "end": Timecode.text(zoom.end)]))
            element.setAccessibilitySelected(zoom.id == selection)
            element.setAccessibilityFrameInParentSpace(rect(of: zoom))
            element.setAccessibilityIdentifier("video.zoom.\(zoom.id.uuidString)")
            element.press = { [weak self] in self?.onSelect(zoom.id) }
            return element
        }
    }
}

private final class ZoomAccessibilityElement: NSAccessibilityElement {
    var press: () -> Void = {}
    override func accessibilityPerformPress() -> Bool { press(); return true }
}
