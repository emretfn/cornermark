import CoreGraphics
import CornermarkCapture
import CornermarkCore

let d1 = DisplayGeometry(id: 1, frame: CGRect(x: 0, y: 0, width: 600, height: 400), scale: 1)
let d2 = DisplayGeometry(id: 2, frame: CGRect(x: 600, y: 0, width: 400, height: 300), scale: 2)
let winA = WindowSnapshot(id: 11, title: "Notes", appName: "Notes", frame: CGRect(x: 40, y: 60, width: 260, height: 200))
let winB = WindowSnapshot(id: 12, title: "Terminal", appName: "Terminal", frame: CGRect(x: 200, y: 120, width: 300, height: 200))

func machine(_ flow: Flow, intent: Intent = .area, cursor: CGPoint = CGPoint(x: 10, y: 10)) -> SelectionMachine {
    var m = SelectionMachine(config: MachineConfig(flow: flow, intent: intent, displays: [d1, d2], windows: [winB, winA]))
    m.send(.begin(cursor: cursor))
    return m
}

func finishedCapture(_ m: SelectionMachine) -> (Target, CaptureKind)? {
    if case .finished(.capture(let t, let k)) = m.state { return (t, k) }
    return nil
}

func areaRect(_ m: SelectionMachine) -> CGRect? {
    if case .finished(.capture(.area(let s), _)) = m.state { return s.rect }
    return nil
}

func adjustingRect(_ m: SelectionMachine) -> CGRect? {
    if case .adjusting(let s, _) = m.state { return s.rect }
    return nil
}

@MainActor
func runMachineTests() {
    section("state machine (no window)")

    var m = machine(.immediate)
    check(m.state == .armed, "begin arms the overlay")
    m.send(.down(CGPoint(x: 100, y: 80), []))
    m.send(.drag(CGPoint(x: 200, y: 150), []))
    check(m.liveRect == CGRect(x: 100, y: 80, width: 100, height: 70), "dragging exposes the live rect", detail: "\(String(describing: m.liveRect))")
    m.send(.up(CGPoint(x: 300, y: 200), []))
    check(areaRect(m) == CGRect(x: 100, y: 80, width: 200, height: 120), "area mouse-up commits the dragged rect", detail: "\(String(describing: areaRect(m)))")

    m = machine(.immediate)
    m.send(.down(CGPoint(x: 100, y: 100), []))
    m.send(.drag(CGPoint(x: 300, y: 160), [.shift]))
    check(m.liveRect == CGRect(x: 100, y: 100, width: 200, height: 200), "shift constrains the drag to 1:1", detail: "\(String(describing: m.liveRect))")
    m.send(.modifiers([]))
    check(m.liveRect == CGRect(x: 100, y: 100, width: 200, height: 60), "releasing shift frees the drag again", detail: "\(String(describing: m.liveRect))")

    m = machine(.immediate)
    m.send(.down(CGPoint(x: 100, y: 100), []))
    m.send(.drag(CGPoint(x: 200, y: 180), []))
    m.send(.keyDown(.space, []))
    m.send(.drag(CGPoint(x: 250, y: 230), []))
    check(m.liveRect == CGRect(x: 150, y: 150, width: 100, height: 80), "space-drag moves the rect without resizing", detail: "\(String(describing: m.liveRect))")
    m.send(.keyUp(.space))
    m.send(.drag(CGPoint(x: 300, y: 250), []))
    check(m.liveRect == CGRect(x: 150, y: 150, width: 150, height: 100), "releasing space resumes sizing from the moved anchor", detail: "\(String(describing: m.liveRect))")

    m = machine(.immediate)
    m.send(.down(CGPoint(x: 550, y: 350), []))
    m.send(.drag(CGPoint(x: 700, y: 100), []))
    check(m.liveRect == CGRect(x: 550, y: 100, width: 150, height: 250), "a drag leaving the start display continues onto the next one", detail: "\(String(describing: m.liveRect))")
    m.send(.drag(CGPoint(x: 900, y: 900), []))
    check(m.liveRect == CGRect(x: 550, y: 350, width: 350, height: 50), "the drag clamps to the union of the display frames on the top edge", detail: "\(String(describing: m.liveRect))")
    m.send(.drag(CGPoint(x: 2000, y: -50), []))
    check(m.liveRect == CGRect(x: 550, y: 0, width: 450, height: 350), "the drag clamps to the union of the display frames on the other corner", detail: "\(String(describing: m.liveRect))")
    m.send(.up(CGPoint(x: 2000, y: -50), []))
    check(areaRect(m) == CGRect(x: 550, y: 0, width: 450, height: 350), "mouse-up commits a rect spanning both displays", detail: "\(String(describing: areaRect(m)))")

    m = machine(.immediate)
    m.send(.down(CGPoint(x: 550, y: 100), []))
    m.send(.drag(CGPoint(x: 700.5, y: 150.5), []))
    check(m.liveRect == CGRect(x: 550, y: 100, width: 150.5, height: 50.5), "a spanning drag snaps its far end to the 2x display's half points", detail: "\(String(describing: m.liveRect))")
    m = machine(.immediate)
    m.send(.down(CGPoint(x: 700.5, y: 150.5), []))
    m.send(.drag(CGPoint(x: 550, y: 100), []))
    check(m.liveRect == CGRect(x: 550, y: 100, width: 150.5, height: 50.5), "a right-to-left spanning drag gives the same rect", detail: "\(String(describing: m.liveRect))")
    check(m.cursorDisplay == d1 && machine(.immediate, cursor: CGPoint(x: 600, y: 10)).cursorDisplay == d2, "the cursor belongs to exactly one display, even on the shared edge")

    m = machine(.immediate, intent: .scrolling)
    m.send(.down(CGPoint(x: 550, y: 350), []))
    m.send(.drag(CGPoint(x: 700, y: 100), []))
    check(m.liveRect == CGRect(x: 550, y: 100, width: 50, height: 250), "scrolling drag onto another display clamps to the display it began on", detail: "\(String(describing: m.liveRect))")
    m.send(.drag(CGPoint(x: 900, y: 900), []))
    check(m.liveRect == CGRect(x: 550, y: 350, width: 50, height: 50), "scrolling drag clamps on both axes", detail: "\(String(describing: m.liveRect))")
    m = machine(.immediate, intent: .scrolling)
    m.send(.down(CGPoint(x: 700, y: 200), []))
    m.send(.drag(CGPoint(x: 100, y: 20), []))
    check(m.liveRect == CGRect(x: 600, y: 20, width: 100, height: 180), "scrolling drag begun on the 2x display stays on it", detail: "\(String(describing: m.liveRect))")

    m = machine(.immediate)
    m.send(.down(CGPoint(x: 700, y: 50), []))
    m.send(.drag(CGPoint(x: 700.5, y: 50.5), []))
    m.send(.drag(CGPoint(x: 800.5, y: 150.5), []))
    check(m.liveRect == CGRect(x: 700, y: 50, width: 100.5, height: 100.5), "selection on a 2x display snaps to half points", detail: "\(String(describing: m.liveRect))")

    m = machine(.immediate)
    m.send(.down(CGPoint(x: 100, y: 100), []))
    m.send(.up(CGPoint(x: 101, y: 101), []))
    check(m.state == .armed, "a click without a drag does not commit")

    for (label, steps) in [("armed", [Input]()),
                           ("dragging", [.down(CGPoint(x: 5, y: 5), []), .drag(CGPoint(x: 50, y: 50), [])])] {
        var e = machine(.immediate)
        for s in steps { e.send(s) }
        e.send(.keyDown(.escape, []))
        check(e.state == .finished(.cancelled), "escape cancels while \(label)")
    }

    var aio = machine(.adjustable)
    aio.send(.down(CGPoint(x: 100, y: 100), []))
    aio.send(.drag(CGPoint(x: 300, y: 200), []))
    aio.send(.up(CGPoint(x: 300, y: 200), []))
    check(adjustingRect(aio) == CGRect(x: 100, y: 100, width: 200, height: 100), "all-in-one stays adjustable after mouse-up")
    aio.send(.keyDown(.escape, []))
    check(aio.state == .finished(.cancelled), "escape cancels while adjusting")

    func adjustable() -> SelectionMachine {
        var a = machine(.adjustable)
        a.send(.down(CGPoint(x: 100, y: 100), []))
        a.send(.drag(CGPoint(x: 300, y: 200), []))
        a.send(.up(CGPoint(x: 300, y: 200), []))
        return a
    }

    aio = adjustable()
    check(aio.hitZone(at: CGPoint(x: 300, y: 100)) == .handle(.bottomRight), "bottom-right corner hits its handle")
    check(aio.hitZone(at: CGPoint(x: 200, y: 200)) == .handle(.top), "top edge hits its handle")
    check(aio.hitZone(at: CGPoint(x: 200, y: 150)) == .inside, "centre is inside")
    check(aio.hitZone(at: CGPoint(x: 50, y: 50)) == .outside, "far point is outside")
    aio.send(.down(CGPoint(x: 300, y: 100), []))
    aio.send(.drag(CGPoint(x: 350, y: 60), []))
    aio.send(.up(CGPoint(x: 350, y: 60), []))
    check(adjustingRect(aio) == CGRect(x: 100, y: 60, width: 250, height: 140), "bottom-right handle resizes", detail: "\(String(describing: adjustingRect(aio)))")
    aio.send(.down(CGPoint(x: 100, y: 130), []))
    aio.send(.drag(CGPoint(x: 70, y: 130), []))
    aio.send(.up(CGPoint(x: 70, y: 130), []))
    check(adjustingRect(aio) == CGRect(x: 70, y: 60, width: 280, height: 140), "left edge handle resizes one axis", detail: "\(String(describing: adjustingRect(aio)))")
    aio.send(.down(CGPoint(x: 70, y: 130), []))
    aio.send(.drag(CGPoint(x: 400, y: 130), []))
    aio.send(.up(CGPoint(x: 400, y: 130), []))
    check(adjustingRect(aio) == CGRect(x: 350, y: 60, width: 50, height: 140), "dragging an edge past the opposite edge flips", detail: "\(String(describing: adjustingRect(aio)))")

    aio = adjustable()
    aio.send(.down(CGPoint(x: 200, y: 150), []))
    aio.send(.drag(CGPoint(x: 230, y: 170), []))
    aio.send(.up(CGPoint(x: 230, y: 170), []))
    check(adjustingRect(aio) == CGRect(x: 130, y: 120, width: 200, height: 100), "dragging inside moves the selection", detail: "\(String(describing: adjustingRect(aio)))")
    aio.send(.down(CGPoint(x: 200, y: 150), []))
    aio.send(.drag(CGPoint(x: 5000, y: 5000), []))
    aio.send(.up(CGPoint(x: 5000, y: 5000), []))
    check(adjustingRect(aio) == CGRect(x: 800, y: 300, width: 200, height: 100), "moving is clamped to the union of the displays", detail: "\(String(describing: adjustingRect(aio)))")

    aio = adjustable()
    aio.send(.down(CGPoint(x: 300, y: 150), []))
    aio.send(.drag(CGPoint(x: 750, y: 150), []))
    aio.send(.up(CGPoint(x: 750, y: 150), []))
    check(adjustingRect(aio) == CGRect(x: 100, y: 100, width: 650, height: 100), "an edge handle resizes across the display boundary", detail: "\(String(describing: adjustingRect(aio)))")
    aio.send(.down(CGPoint(x: 750, y: 100), []))
    aio.send(.drag(CGPoint(x: 900.5, y: 20.5), []))
    aio.send(.up(CGPoint(x: 900.5, y: 20.5), []))
    check(adjustingRect(aio) == CGRect(x: 100, y: 20.5, width: 800.5, height: 179.5), "a corner handle resizes across the boundary and snaps to half points", detail: "\(String(describing: adjustingRect(aio)))")
    aio.send(.down(CGPoint(x: 900.5, y: 100), []))
    aio.send(.drag(CGPoint(x: 5000, y: 100), []))
    aio.send(.up(CGPoint(x: 5000, y: 100), []))
    check(adjustingRect(aio)?.maxX == 1000, "dragging a handle past the last display clamps to its far edge", detail: "\(String(describing: adjustingRect(aio)))")

    aio = adjustable()
    for _ in 0..<25 { aio.send(.keyDown(.arrow(.right), [.shift])) }
    check(adjustingRect(aio) == CGRect(x: 350, y: 100, width: 200, height: 100), "shift+arrow nudges walk the selection toward the next display", detail: "\(String(describing: adjustingRect(aio)))")
    for _ in 0..<12 { aio.send(.keyDown(.arrow(.right), [.shift])) }
    check(adjustingRect(aio) == CGRect(x: 470, y: 100, width: 200, height: 100), "a nudge carries the selection across the boundary", detail: "\(String(describing: adjustingRect(aio)))")
    for _ in 0..<80 { aio.send(.keyDown(.arrow(.right), [.shift])) }
    check(adjustingRect(aio)?.maxX == 1000, "nudging stops at the union's far edge", detail: "\(String(describing: adjustingRect(aio)))")

    aio = adjustable()
    aio.send(.toolbar(.size(width: 700, height: 150)))
    check(adjustingRect(aio) == CGRect(x: 100, y: 50, width: 700, height: 150), "a typed size can reach across displays", detail: "\(String(describing: adjustingRect(aio)))")
    aio.send(.toolbar(.size(width: 5000, height: nil)))
    check(adjustingRect(aio)?.width == 1000, "a typed size is limited to the union of the displays", detail: "\(String(describing: adjustingRect(aio)))")

    var span = machine(.adjustable)
    span.send(.down(CGPoint(x: 500, y: 100), []))
    span.send(.drag(CGPoint(x: 800, y: 250), []))
    span.send(.up(CGPoint(x: 800, y: 250), []))
    check(adjustingRect(span) == CGRect(x: 500, y: 100, width: 300, height: 150), "an all-in-one selection can start on one display and end on another")
    check(span.chromeDisplay(for: adjustingRect(span)!) == d2, "the display holding most of the selection carries the badge and toolbar", detail: "\(String(describing: span.chromeDisplay(for: adjustingRect(span)!)))")
    span.send(.toolbar(.mode(.scrolling)))
    if case .scrollingCapture(let area, _) = span.state {
        check(area.rect == CGRect(x: 600, y: 100, width: 200, height: 150) && area.display == d2, "scrolling started from a spanning selection is clipped to its dominant display", detail: "\(area)")
    } else { check(false, "scrolling started from a spanning selection is clipped to its dominant display", detail: "\(span.state)") }
    span = machine(.adjustable)
    span.send(.down(CGPoint(x: 500, y: 100), []))
    span.send(.drag(CGPoint(x: 800, y: 250), []))
    span.send(.up(CGPoint(x: 800, y: 250), []))
    span.send(.toolbar(.mode(.fullscreen)))
    check(finishedCapture(span)?.0 == .fullscreen(d2), "toolbar Fullscreen on a spanning selection captures its dominant display")

    func picked(from a: CGPoint, to b: CGPoint) -> DisplayGeometry? {
        var t = machine(.adjustable)
        t.send(.down(a, [])); t.send(.drag(b, [])); t.send(.up(b, []))
        return adjustingRect(t).flatMap { t.chromeDisplay(for: $0) }
    }
    check(picked(from: CGPoint(x: 800, y: 250), to: CGPoint(x: 500, y: 200)) == d2, "an unequal split picks the larger share even with the cursor on the other display")
    check(picked(from: CGPoint(x: 700, y: 250), to: CGPoint(x: 500, y: 200)) == d1, "an exact tie goes to the display under the cursor (ending in the first)")
    check(picked(from: CGPoint(x: 500, y: 200), to: CGPoint(x: 700, y: 250)) == d2, "an exact tie goes to the display under the cursor (ending in the second)")

    aio = adjustable()
    aio.send(.keyDown(.arrow(.right), []))
    check(adjustingRect(aio) == CGRect(x: 101, y: 100, width: 200, height: 100), "arrow nudges 1pt")
    aio.send(.keyDown(.arrow(.up), [.shift]))
    check(adjustingRect(aio) == CGRect(x: 101, y: 110, width: 200, height: 100), "shift+arrow nudges 10pt")
    aio.send(.keyDown(.arrow(.left), [.shift]))
    aio.send(.keyDown(.arrow(.down), []))
    check(adjustingRect(aio) == CGRect(x: 91, y: 109, width: 200, height: 100), "left and down nudge the other way")
    for _ in 0..<20 { aio.send(.keyDown(.arrow(.left), [.shift])) }
    check(adjustingRect(aio)?.minX == 0, "nudging stops at the display edge")

    aio = adjustable()
    aio.send(.toolbar(.aspect(.ratio(16, 9))))
    if let r = adjustingRect(aio) {
        check(abs(r.width / r.height - 16.0 / 9.0) < 0.01 && r.minX == 100 && r.maxY == 200, "choosing 16:9 reshapes the selection with the top-left pinned", detail: "\(r)")
    } else { check(false, "choosing 16:9 reshapes the selection") }
    aio.send(.toolbar(.size(width: 320, height: nil)))
    check(adjustingRect(aio)?.size == CGSize(width: 320, height: 180), "typed width drives height under the lock", detail: "\(String(describing: adjustingRect(aio)))")
    aio.send(.toolbar(.size(width: nil, height: 90)))
    check(adjustingRect(aio)?.size == CGSize(width: 160, height: 90), "typed height drives width under the lock", detail: "\(String(describing: adjustingRect(aio)))")
    aio.send(.down(CGPoint(x: adjustingRect(aio)!.maxX, y: adjustingRect(aio)!.minY), []))
    aio.send(.drag(CGPoint(x: 340, y: 10), []))
    aio.send(.up(CGPoint(x: 340, y: 10), []))
    if let r = adjustingRect(aio) {
        check(abs(r.width / r.height - 16.0 / 9.0) < 0.01 && r.minX == 100 && r.maxY == 200, "corner resize holds 16:9 from the opposite corner", detail: "\(r)")
    } else { check(false, "corner resize holds 16:9") }
    aio.send(.toolbar(.aspect(.free)))
    aio.send(.toolbar(.size(width: 300, height: 77)))
    check(adjustingRect(aio)?.size == CGSize(width: 300, height: 77), "free lock accepts any typed size")

    aio = adjustable()
    aio.send(.keyDown(.confirm, []))
    check(areaRect(aio) == CGRect(x: 100, y: 100, width: 200, height: 100), "return commits the adjusted selection")
    aio = adjustable()
    aio.send(.toolbar(.capture))
    check(areaRect(aio) != nil, "toolbar Capture commits")
    aio = adjustable()
    aio.send(.toolbar(.mode(.timer)))
    if case .countdown(3, .area(let s)) = aio.state { check(s.rect == CGRect(x: 100, y: 100, width: 200, height: 100), "toolbar Timer counts down on the selection") }
    else { check(false, "toolbar Timer counts down on the selection", detail: "\(aio.state)") }
    aio = adjustable()
    aio.send(.toolbar(.mode(.scrolling)))
    if case .scrollingCapture = aio.state { check(true, "toolbar Scrolling starts scrolling capture on the selection") }
    else { check(false, "toolbar Scrolling starts scrolling capture on the selection", detail: "\(aio.state)") }
    aio = adjustable()
    aio.send(.toolbar(.mode(.fullscreen)))
    check(finishedCapture(aio)?.1 == .fullscreen, "toolbar Fullscreen captures the display")
    aio = adjustable()
    aio.send(.toolbar(.mode(.window)))
    check(aio.state == .windowHover(winB), "toolbar Window switches to window hover on the window under the cursor", detail: "\(aio.state)")

    var w = machine(.window, cursor: CGPoint(x: 250, y: 150))
    check(w.state == .windowHover(winB), "window flow starts hovering the front window", detail: "\(w.state)")
    w.send(.move(CGPoint(x: 60, y: 80)))
    check(w.state == .windowHover(winA), "hover follows the cursor to the window underneath")
    w.send(.move(CGPoint(x: 550, y: 380)))
    check(w.state == .windowHover(nil), "hover over bare desktop highlights nothing")
    w.send(.keyDown(.space, []))
    check(w.state == .armed, "space switches window mode to area")
    w.send(.keyDown(.space, []))
    w.send(.move(CGPoint(x: 250, y: 150)))
    w.send(.down(CGPoint(x: 250, y: 150), [.option]))
    check(finishedCapture(w)?.0 == .window(winB, toggleShadow: true), "option-click on a window asks for the inverted shadow")
    var a = machine(.immediate, cursor: CGPoint(x: 250, y: 150))
    a.send(.keyDown(.space, []))
    check(a.state == .windowHover(winB), "space switches area mode to window")
    a.send(.down(CGPoint(x: 250, y: 150), []))
    check(finishedCapture(a)?.0 == .window(winB, toggleShadow: false) && finishedCapture(a)?.1 == .window, "clicking picks the hovered window")

    var t = machine(.timedFullscreen(seconds: 3), cursor: CGPoint(x: 800, y: 100))
    check(t.state == .countdown(remaining: 3, then: .fullscreen(d2)), "timer counts from the requested seconds on the display under the cursor")
    t.send(.tick); t.send(.tick)
    check(t.state == .countdown(remaining: 1, then: .fullscreen(d2)), "ticks count down")
    t.send(.tick)
    check(finishedCapture(t)?.0 == .fullscreen(d2) && finishedCapture(t)?.1 == .timed, "countdown ends in a timed fullscreen capture")
    t = machine(.timedFullscreen(seconds: 3))
    t.send(.keyDown(.escape, []))
    check(t.state == .finished(.cancelled), "escape cancels the countdown")
    t.send(.tick)
    check(t.state == .finished(.cancelled), "a finished machine ignores late input")

    var s = machine(.immediate, intent: .scrolling)
    s.send(.down(CGPoint(x: 50, y: 100), []))
    s.send(.drag(CGPoint(x: 350, y: 400), []))
    s.send(.up(CGPoint(x: 350, y: 400), []))
    if case .scrollingCapture(let sel, let p) = s.state {
        check(sel.rect == CGRect(x: 50, y: 100, width: 300, height: 300) && p == ScrollProgress(), "scrolling area pick enters scrollingCapture")
    } else { check(false, "scrolling area pick enters scrollingCapture", detail: "\(s.state)") }
    s.send(.scroll(.started, lines: 300))
    s.send(.scroll(.appended(lines: 80), lines: 380))
    s.send(.scroll(.noOverlap, lines: 380))
    if case .scrollingCapture(_, let p) = s.state { check(p.hint == .scrollSlower && p.lines == 380, "noOverlap raises the scroll-slower hint") }
    s.send(.scroll(.noMovement, lines: 380))
    if case .scrollingCapture(_, let p) = s.state { check(p.hint == .scrollSlower, "noMovement keeps the hint") }
    s.send(.scroll(.appended(lines: 40), lines: 420))
    if case .scrollingCapture(_, let p) = s.state { check(p.hint == .clear && p.lines == 420, "appending clears the hint and updates the height") }
    s.send(.toolbar(.done))
    check(s.state == .finished(.scrolled), "Done finishes scrolling capture")
}
