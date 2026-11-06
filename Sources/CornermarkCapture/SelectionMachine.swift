import CoreGraphics
import CornermarkCore

public struct DisplayGeometry: Hashable {
    public var id: CGDirectDisplayID
    public var frame: CGRect
    public var scale: Double
    public init(id: CGDirectDisplayID, frame: CGRect, scale: Double) { self.id = id; self.frame = frame; self.scale = scale }
}

/// A rect in global AppKit points. It may span displays, so it names none.
public struct Selection: Hashable {
    public var rect: CGRect
    public init(rect: CGRect) { self.rect = rect }
}

/// The only selection a scrolling capture accepts: the stitcher polls one display, so the rect is
/// clipped to the display that holds most of it and both travel together.
public struct ScrollArea: Hashable {
    public let rect: CGRect
    public let display: DisplayGeometry

    /// Nil when the selection lies on no display.
    init?(clipping selection: Selection, to displays: [DisplayGeometry], preferring cursor: CGPoint? = nil) {
        guard let display = SelectionSpace(displays: displays).dominant(for: selection.rect, preferring: cursor) else { return nil }
        let clipped = selection.rect.intersection(display.frame)
        guard !clipped.isEmpty else { return nil }
        self.rect = clipped
        self.display = display
    }
}

/// Whether a selection may run across displays. Scrolling cannot: its stitcher polls a single display.
public enum DisplaySpan: Hashable { case acrossDisplays, withinOneDisplay }

public enum Handle: CaseIterable, Hashable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

    /// -1 / 0 / +1 on each axis, in AppKit orientation (y up).
    var axes: (x: Int, y: Int) {
        switch self {
        case .topLeft: return (-1, 1)
        case .top: return (0, 1)
        case .topRight: return (1, 1)
        case .right: return (1, 0)
        case .bottomRight: return (1, -1)
        case .bottom: return (0, -1)
        case .bottomLeft: return (-1, -1)
        case .left: return (-1, 0)
        }
    }

    func position(on r: CGRect) -> CGPoint {
        let (x, y) = axes
        return CGPoint(x: x < 0 ? r.minX : (x > 0 ? r.maxX : r.midX), y: y < 0 ? r.minY : (y > 0 ? r.maxY : r.midY))
    }
}

public enum AspectLock: Hashable {
    case free
    case ratio(Int, Int)

    public static let presets: [AspectLock] = [.free, .ratio(1, 1), .ratio(4, 3), .ratio(16, 9), .ratio(3, 2)]

    public var value: CGFloat? {
        if case .ratio(let w, let h) = self, h > 0 { return CGFloat(w) / CGFloat(h) }
        return nil
    }

    public var title: String {
        if case .ratio(let w, let h) = self { return "\(w):\(h)" }
        return "Free"
    }
}

/// What a finished selection turns into: the toolbar's Scrolling, Timer and Record modes decide it.
public enum Intent: Hashable { case area, scrolling, timer, record }

public enum ToolbarMode: Hashable, CaseIterable { case area, window, fullscreen, scrolling, timer, record }

/// What a recording becomes.
public enum RecordingStyle: String, Hashable, CaseIterable {
    /// One finished video with the pointer in the picture.
    case video
    /// A project whose pointer and edits stay changeable.
    case editing
    /// One animated GIF with the pointer in the picture, made from the video once the recording ends.
    case gif
}

/// What a recording takes besides the picture. The recording panel has one toggle for each.
public enum RecordingSource: String, Hashable, CaseIterable, Sendable {
    case microphone, systemAudio, camera, input

    public var name: String {
        switch self {
        case .microphone: return "Microphone"
        case .systemAudio: return "System audio"
        case .camera: return "Camera"
        case .input: return "Clicks and keys"
        }
    }
}

/// What the recording panel shows of the sources: the ones the next recording takes, and one line about a source that needs attention.
public struct RecordingSources: Equatable, Sendable {
    public enum Note: Equatable, Sendable {
        /// A source someone wants but cannot have yet, and how to allow it.
        case blocked(String)
        /// Worth knowing before a start button is pressed.
        case hint(String)

        public var text: String {
            switch self {
            case .blocked(let text), .hint(let text): return text
            }
        }
    }

    public var on: Set<RecordingSource>
    public var note: Note?

    public init(on: Set<RecordingSource> = [], note: Note? = nil) {
        self.on = on
        self.note = note
    }
}

public enum Flow: Hashable {
    /// Releasing the mouse commits (area, scrolling).
    case immediate
    /// Releasing the mouse leaves an adjustable selection (all-in-one).
    case adjustable
    case window
    case timedFullscreen(seconds: Int)
}

public struct MachineConfig {
    public var flow: Flow
    public var intent: Intent
    public var aspect: AspectLock
    public var timerSeconds: Int
    public var displays: [DisplayGeometry]
    /// Front to back.
    public var windows: [WindowSnapshot]
    /// An adjustable overlay opens with this area already selected, when any of it lies on a display.
    public var remembered: CGRect?

    public init(flow: Flow, intent: Intent = .area, aspect: AspectLock = .free, timerSeconds: Int = 3,
                displays: [DisplayGeometry], windows: [WindowSnapshot] = [], remembered: CGRect? = nil) {
        self.flow = flow; self.intent = intent; self.aspect = aspect; self.timerSeconds = timerSeconds
        self.displays = displays; self.windows = windows; self.remembered = remembered
    }

    /// Derived from `intent` so the two cannot disagree when the toolbar switches modes mid-session.
    /// A recording films one display, like the scrolling stitcher polls one.
    public var span: DisplaySpan { intent == .scrolling || intent == .record ? .withinOneDisplay : .acrossDisplays }

    /// A recording lines up with what it films, so its edges pull towards display and window edges.
    public var snapsToEdges: Bool { intent == .record }
}

public enum Target: Hashable {
    case area(Selection)
    /// `toggleShadow` is Option held at the click: it inverts the controller's shadow default.
    case window(WindowSnapshot, toggleShadow: Bool)
    case fullscreen(DisplayGeometry)
}

public enum Finish: Hashable {
    case capture(Target, CaptureKind)
    case record(Target, RecordingStyle)
    case scrolled
    case cancelled
}

public enum ScrollHint: Hashable { case clear, scrollSlower }

public struct ScrollProgress: Hashable {
    public var lines = 0
    public var hint = ScrollHint.clear
    public init() {}
}

public enum Gesture: Hashable {
    case resize(Handle, original: CGRect)
    case move(grab: CGPoint)
}

public struct Drag: Hashable {
    /// Fixed when the drag begins: every display, or just the one it began on.
    public var space: SelectionSpace
    public var start: CGPoint
    public var current: CGPoint
    public var aspect: AspectLock
    /// Set while space is held: pointer motion translates the rect instead of resizing it.
    public var movingFrom: CGPoint?
    /// Set while Option is held: `start` is the centre and the rect grows both ways.
    public var fromCenter = false

    public var rect: CGRect {
        let scale = max(space.scale(at: start), space.scale(at: current))
        if fromCenter { return RectMath.centered(on: start, to: current, ratio: aspect.value, bounds: space.bounds, scale: scale) }
        return RectMath.make(anchor: start, to: current, ratio: aspect.value, bounds: space.bounds, scale: scale)
    }
}

public enum OverlayState: Hashable {
    case idle
    case armed
    case dragging(Drag)
    case adjusting(Selection, Gesture?)
    case windowHover(WindowSnapshot?)
    /// A recording's window, clicked and held until a start button or a key says how to record it.
    case windowPicked(WindowSnapshot)
    case countdown(remaining: Int, then: Target)
    case scrollingCapture(ScrollArea, ScrollProgress)
    case finished(Finish)
}

public struct Modifiers: OptionSet, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let shift = Modifiers(rawValue: 1)
    public static let option = Modifiers(rawValue: 2)
    public static let command = Modifiers(rawValue: 4)
}

public enum Arrow: Hashable { case left, right, up, down }

public enum Key: Hashable {
    case escape, confirm, space
    case arrow(Arrow)
}

public enum ToolbarAction: Hashable {
    case mode(ToolbarMode)
    case aspect(AspectLock)
    case size(width: Double?, height: Double?)
    case capture
    case record(RecordingStyle)
    case done
}

public enum Input {
    case begin(cursor: CGPoint)
    case move(CGPoint)
    case down(CGPoint, Modifiers)
    case drag(CGPoint, Modifiers)
    case up(CGPoint, Modifiers)
    case keyDown(Key, Modifiers)
    case keyUp(Key)
    case modifiers(Modifiers)
    case toolbar(ToolbarAction)
    case tick
    case scroll(ScrollStitcher.Outcome, lines: Int)
}

public enum HitZone: Hashable {
    case handle(Handle)
    case inside
    case outside
}

/// The whole overlay lifecycle as one reducer: no window, no AppKit, so it can be driven by tests.
public struct SelectionMachine {
    public private(set) var state: OverlayState = .idle
    public private(set) var config: MachineConfig
    public private(set) var cursor: CGPoint = .zero

    public init(config: MachineConfig) { self.config = config }

    public mutating func send(_ input: Input) {
        if case .finished = state { return }
        switch input {
        case .begin(let at): cursor = at; begin()
        case .move(let p): cursor = p; pointerMoved(p)
        case .down(let p, let m): cursor = p; pointerDown(p, m)
        case .drag(let p, let m): cursor = p; pointerDragged(p, m)
        case .up(let p, let m): cursor = p; pointerDragged(p, m); pointerUp()
        case .keyDown(let k, let m): keyDown(k, m)
        case .keyUp(let k): keyUp(k)
        case .modifiers(let m): modifiersChanged(m)
        case .toolbar(let a): toolbar(a)
        case .tick: tick()
        case .scroll(let o, let lines): scrolled(o, lines)
        }
    }

    // MARK: Queries

    public func display(at p: CGPoint) -> DisplayGeometry? {
        SelectionSpace(displays: config.displays).display(at: p)
    }

    /// The display under the pointer, for the crosshair and loupe. Nil in a gap between displays.
    public var cursorDisplay: DisplayGeometry? {
        config.displays.first { $0.frame.contains(cursor) }
            ?? config.displays.first { $0.frame.insetBy(dx: -0.5, dy: -0.5).contains(cursor) }
    }

    /// The display that carries a selection's single-instance chrome (size badge, toolbar).
    public func chromeDisplay(for rect: CGRect) -> DisplayGeometry? {
        SelectionSpace(displays: config.displays).dominant(for: rect, preferring: cursor)
    }

    public func window(at p: CGPoint) -> WindowSnapshot? {
        config.windows.first { $0.frame.contains(p) }
    }

    public func hitZone(at p: CGPoint) -> HitZone {
        guard case .adjusting(let sel, _) = state else { return .outside }
        if let h = handle(at: p, in: sel.rect) { return .handle(h) }
        return sel.rect.contains(p) ? .inside : .outside
    }

    /// The target the recording panel shows as chosen: a selection that fills a display records that display.
    public var recordingMode: ToolbarMode {
        switch state {
        case .windowHover, .windowPicked: return .window
        case .adjusting(let sel, _): return fullscreenDisplay(for: sel.rect) == nil ? .area : .fullscreen
        default: return .area
        }
    }

    /// The selection rect currently on screen, whatever state it is in.
    public var liveRect: CGRect? {
        switch state {
        case .dragging(let d): return d.rect
        case .adjusting(let s, _): return s.rect
        case .scrollingCapture(let a, _): return a.rect
        default: return nil
        }
    }

    // MARK: Transitions

    private mutating func begin() {
        guard case .idle = state else { return }
        switch config.flow {
        case .adjustable:
            state = config.remembered.flatMap(rememberedSelection).map { .adjusting($0, nil) } ?? .armed
        case .immediate: state = .armed
        case .window: state = .windowHover(window(at: cursor))
        case .timedFullscreen(let seconds):
            guard let d = display(at: cursor) else { state = .finished(.cancelled); return }
            state = .countdown(remaining: max(1, seconds), then: .fullscreen(d))
        }
    }

    private mutating func pointerMoved(_ p: CGPoint) {
        if case .windowHover = state { state = .windowHover(window(at: p)) }
    }

    private mutating func pointerDown(_ p: CGPoint, _ m: Modifiers) {
        switch state {
        case .armed:
            beginDrag(at: p, m)
        case .windowHover(let w):
            guard let w else { break }
            state = config.intent == .record ? .windowPicked(w) : .finished(.capture(.window(w, toggleShadow: m.contains(.option)), .window))
        case .windowPicked:
            state = window(at: p).map { .windowPicked($0) } ?? .windowHover(nil)
        case .adjusting(let sel, nil):
            if let h = handle(at: p, in: sel.rect) {
                state = .adjusting(sel, .resize(h, original: sel.rect))
            } else if sel.rect.contains(p) {
                state = .adjusting(sel, .move(grab: CGPoint(x: p.x - sel.rect.minX, y: p.y - sel.rect.minY)))
            } else {
                beginDrag(at: p, m)
            }
        default: break
        }
    }

    private mutating func beginDrag(at p: CGPoint, _ m: Modifiers) {
        let space = selectionSpace(confinedTo: { $0.display(at: p) })
        guard !space.displays.isEmpty else { return }
        let start = space.snap(edgeSnapped(p, m))
        state = .dragging(Drag(space: space, start: start, current: start, aspect: effectiveAspect(m), movingFrom: nil, fromCenter: m.contains(.option)))
    }

    private mutating func pointerDragged(_ p: CGPoint, _ m: Modifiers) {
        switch state {
        case .dragging(var d):
            if let from = d.movingFrom {
                let r = d.rect
                let b = d.space.bounds
                let dx = min(max(p.x - from.x, b.minX - r.minX), b.maxX - r.maxX)
                let dy = min(max(p.y - from.y, b.minY - r.minY), b.maxY - r.maxY)
                d.start.x += dx; d.start.y += dy; d.current.x += dx; d.current.y += dy
                d.movingFrom = p
            } else {
                d.current = d.space.snap(edgeSnapped(p, m))
                d.aspect = effectiveAspect(m)
                d.fromCenter = m.contains(.option)
            }
            state = .dragging(d)
        case .adjusting(let sel, let gesture?):
            let space = spaceAround(sel.rect)
            var rect = sel.rect
            switch gesture {
            case .resize(let h, let original):
                let scale = max(space.maxScale(intersecting: original), space.scale(at: p))
                let to = edgeSnapped(p, m), ratio = effectiveAspect(m).value
                rect = m.contains(.option)
                    ? RectMath.resizeCentered(original, handle: h, to: to, ratio: ratio, bounds: space.bounds, scale: scale)
                    : RectMath.resize(original, handle: h, to: to, ratio: ratio, bounds: space.bounds, scale: scale)
            case .move(let grab):
                var origin = CGPoint(x: p.x - grab.x, y: p.y - grab.y)
                if snapsEdges(m) {
                    let shift = edges.offset(for: CGRect(origin: origin, size: sel.rect.size))
                    origin.x += shift.dx; origin.y += shift.dy
                }
                rect = placed(size: sel.rect.size, at: origin, in: space)
            }
            state = .adjusting(Selection(rect: rect), gesture)
        default: break
        }
    }

    private mutating func pointerUp() {
        switch state {
        case .dragging(let d):
            let r = d.rect
            guard r.width >= 3, r.height >= 3 else { state = .armed; return }
            let sel = Selection(rect: r)
            if config.flow == .adjustable { state = .adjusting(sel, nil) } else { state = committed(sel) ?? .armed }
        case .adjusting(let sel, _?):
            state = .adjusting(sel, nil)
        default: break
        }
    }

    private mutating func keyDown(_ key: Key, _ m: Modifiers) {
        if key == .escape { state = .finished(.cancelled); return }
        switch (state, key) {
        case (.adjusting(let sel, nil), .confirm): commit(sel, style: style(m))
        case (.windowHover(let w?), .confirm) where config.intent == .record, (.windowPicked(let w), .confirm):
            state = .finished(.record(.window(w, toggleShadow: false), style(m)))
        case (.windowHover(let w?), .confirm):
            state = .finished(.capture(.window(w, toggleShadow: m.contains(.option)), .window))
        case (.scrollingCapture, .confirm): state = .finished(.scrolled)
        case (.armed, .space): state = .windowHover(window(at: cursor))
        case (.windowHover, .space), (.windowPicked, .space): state = .armed
        case (.dragging(var d), .space):
            let r = d.rect
            d.current = CGPoint(x: abs(r.minX - d.start.x) < 1e-6 ? r.maxX : r.minX,
                                y: abs(r.minY - d.start.y) < 1e-6 ? r.maxY : r.minY)
            d.movingFrom = cursor
            state = .dragging(d)
        case (.adjusting(let sel, nil), .arrow(let a)):
            let step: CGFloat = m.contains(.shift) ? 10 : 1
            let delta: CGPoint
            switch a {
            case .left: delta = CGPoint(x: -step, y: 0)
            case .right: delta = CGPoint(x: step, y: 0)
            case .up: delta = CGPoint(x: 0, y: step)
            case .down: delta = CGPoint(x: 0, y: -step)
            }
            let moved = sel.rect.offsetBy(dx: delta.x, dy: delta.y)
            state = .adjusting(Selection(rect: RectMath.fit(moved, in: spaceAround(sel.rect).bounds)), nil)
        default: break
        }
    }

    private mutating func keyUp(_ key: Key) {
        guard key == .space, case .dragging(var d) = state, d.movingFrom != nil else { return }
        d.movingFrom = nil
        state = .dragging(d)
    }

    private mutating func modifiersChanged(_ m: Modifiers) {
        guard case .dragging(var d) = state, d.movingFrom == nil else { return }
        d.aspect = effectiveAspect(m)
        d.fromCenter = m.contains(.option)
        state = .dragging(d)
    }

    private mutating func toolbar(_ action: ToolbarAction) {
        switch action {
        case .mode(let mode): selectMode(mode)
        case .aspect(let lock):
            config.aspect = lock
            if case .adjusting(let sel, nil) = state, let ratio = lock.value {
                let space = spaceAround(sel.rect)
                let r = RectMath.sized(sel.rect, width: sel.rect.width, height: nil, ratio: ratio, bounds: space.bounds,
                                       scale: space.maxScale(intersecting: sel.rect))
                state = .adjusting(Selection(rect: r), nil)
            }
        case .size(let w, let h):
            guard case .adjusting(let sel, nil) = state else { return }
            let space = spaceAround(sel.rect)
            let r = RectMath.sized(sel.rect, width: w.map { CGFloat($0) }, height: h.map { CGFloat($0) }, ratio: config.aspect.value,
                                   bounds: space.bounds, scale: space.maxScale(intersecting: sel.rect))
            state = .adjusting(Selection(rect: r), nil)
        case .capture:
            if case .adjusting(let sel, nil) = state { commit(sel) }
        case .record(let style):
            guard config.intent == .record else { return }
            switch state {
            case .adjusting(let sel, nil): commit(sel, style: style)
            case .windowPicked(let w): state = .finished(.record(.window(w, toggleShadow: false), style))
            default: break
            }
        case .done:
            if case .scrollingCapture = state { state = .finished(.scrolled) }
        }
    }

    private mutating func selectMode(_ mode: ToolbarMode) {
        switch mode {
        case .area:
            // In a recording the target buttons choose what to film and never leave the recording.
            if config.intent != .record { config.intent = .area }
            switch state {
            case .windowHover, .windowPicked: state = .armed
            // A whole display is the Fullscreen target, so Area asks for a new drag.
            case .adjusting(let sel, nil) where config.intent == .record && fullscreenDisplay(for: sel.rect) != nil: state = .armed
            default: break
            }
        case .window:
            switch state {
            case .adjusting, .armed: state = .windowHover(window(at: cursor))
            default: break
            }
        case .fullscreen:
            var display = display(at: cursor)
            if case .adjusting(let sel, _) = state { display = chromeDisplay(for: sel.rect) }
            if case .windowPicked(let w) = state { display = chromeDisplay(for: w.frame) }
            guard let display else { return }
            state = config.intent == .record ? .adjusting(Selection(rect: display.frame), nil) : .finished(.capture(.fullscreen(display), .fullscreen))
        case .record:
            config.intent = .record
            if case .adjusting(let sel, nil) = state {
                state = ScrollArea(clipping: sel, to: config.displays, preferring: cursor).map { .adjusting(Selection(rect: $0.rect), nil) } ?? .armed
            }
        case .scrolling, .timer:
            config.intent = mode == .scrolling ? .scrolling : .timer
            if case .adjusting(let sel, nil) = state { commit(sel) }
            else if case .windowHover = state { state = .armed }
        }
    }

    private mutating func commit(_ sel: Selection, style: RecordingStyle = .video) {
        if let next = committed(sel, style: style) { state = next }
    }

    /// Nil only for a scrolling pick that lies on no display.
    private func committed(_ sel: Selection, style: RecordingStyle = .video) -> OverlayState? {
        switch config.intent {
        case .area: return .finished(.capture(.area(sel), .area))
        case .record:
            return .finished(.record(fullscreenDisplay(for: sel.rect).map { .fullscreen($0) } ?? .area(sel), style))
        case .scrolling:
            return ScrollArea(clipping: sel, to: config.displays, preferring: cursor).map { .scrollingCapture($0, ScrollProgress()) }
        case .timer: return .countdown(remaining: max(1, config.timerSeconds), then: .area(sel))
        }
    }

    private mutating func tick() {
        guard case .countdown(let remaining, let then) = state else { return }
        state = remaining <= 1 ? .finished(.capture(then, .timed)) : .countdown(remaining: remaining - 1, then: then)
    }

    private mutating func scrolled(_ outcome: ScrollStitcher.Outcome, _ lines: Int) {
        guard case .scrollingCapture(let sel, var progress) = state else { return }
        progress.lines = lines
        switch outcome {
        case .noOverlap: progress.hint = .scrollSlower
        case .appended, .started, .scrolledBackward: progress.hint = .clear
        case .noMovement, .sizeMismatch, .unreadable: break
        }
        state = .scrollingCapture(sel, progress)
    }

    // MARK: Helpers

    private func effectiveAspect(_ m: Modifiers) -> AspectLock { m.contains(.shift) ? .ratio(1, 1) : config.aspect }

    /// Return records a video, Shift-Return a project for editing, Option-Return a GIF.
    private func style(_ m: Modifiers) -> RecordingStyle { m.contains(.option) ? .gif : m.contains(.shift) ? .editing : .video }

    private func fullscreenDisplay(for rect: CGRect) -> DisplayGeometry? { config.displays.first { $0.frame == rect } }

    private var edges: EdgeSnap { EdgeSnap(frames: config.displays.map(\.frame) + config.windows.map(\.frame)) }

    /// Command holds snapping off, for an edge that must sit a few points away.
    private func snapsEdges(_ m: Modifiers) -> Bool { config.snapsToEdges && !m.contains(.command) }

    private func edgeSnapped(_ p: CGPoint, _ m: Modifiers) -> CGPoint { snapsEdges(m) ? edges.snapped(p) : p }

    /// The remembered area, kept inside the space it may live in. Nil when none of it is on a display.
    private func rememberedSelection(_ rect: CGRect) -> Selection? {
        guard config.displays.contains(where: { !$0.frame.intersection(rect).isEmpty }) else { return nil }
        let space = spaceAround(rect)
        let kept = rect.intersection(space.bounds)
        return kept.isEmpty ? nil : Selection(rect: kept)
    }

    /// All displays, or only the picked one when the config keeps a selection on a single display.
    private func selectionSpace(confinedTo pick: (SelectionSpace) -> DisplayGeometry?) -> SelectionSpace {
        let all = SelectionSpace(displays: config.displays)
        guard config.span == .withinOneDisplay, let display = pick(all) else { return all }
        return all.confined(to: display)
    }

    private func spaceAround(_ rect: CGRect) -> SelectionSpace {
        selectionSpace(confinedTo: { $0.dominant(for: rect, preferring: cursor) })
    }

    /// A rect of `size` near `origin`, snapped to the finest grid it touches and kept inside the space.
    private func placed(size: CGSize, at origin: CGPoint, in space: SelectionSpace) -> CGRect {
        var scale = space.maxScale(intersecting: CGRect(origin: origin, size: size))
        var out = CGRect(origin: origin, size: size)
        for _ in 0..<2 {
            let snapped = CGPoint(x: RectMath.snap(origin.x, scale), y: RectMath.snap(origin.y, scale))
            out = RectMath.fit(CGRect(origin: snapped, size: size), in: space.bounds)
            // Landing wholly on a coarser display re-snaps to that display's pixels.
            let settled = space.maxScale(intersecting: out)
            if settled >= scale { break }
            scale = settled
        }
        return out
    }

    private func handle(at p: CGPoint, in r: CGRect) -> Handle? {
        let corner = max(4, min(9, min(r.width, r.height) / 3))
        let edge: CGFloat = 5
        for h in Handle.allCases where h.axes.x != 0 && h.axes.y != 0 {
            let q = h.position(on: r)
            if abs(p.x - q.x) <= corner && abs(p.y - q.y) <= corner { return h }
        }
        for h in Handle.allCases where h.axes.x == 0 || h.axes.y == 0 {
            let (x, y) = h.axes
            if x != 0 {
                let line = x > 0 ? r.maxX : r.minX
                if abs(p.x - line) <= edge && p.y >= r.minY && p.y <= r.maxY { return h }
            } else {
                let line = y > 0 ? r.maxY : r.minY
                if abs(p.y - line) <= edge && p.x >= r.minX && p.x <= r.maxX { return h }
            }
        }
        return nil
    }
}
