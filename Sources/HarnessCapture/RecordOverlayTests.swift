import AppKit
import CornermarkCapture
import CornermarkCore
import CornermarkDesign

private func recordMachine(remembered: CGRect? = nil, cursor: CGPoint = CGPoint(x: 10, y: 10)) -> SelectionMachine {
    var m = SelectionMachine(config: MachineConfig(flow: .adjustable, intent: .record, displays: [d1, d2], windows: [winB, winA], remembered: remembered))
    m.send(.begin(cursor: cursor))
    return m
}

private func recorded(_ m: SelectionMachine) -> (Target, RecordingStyle)? {
    if case .finished(.record(let t, let s)) = m.state { return (t, s) }
    return nil
}

extension Outcome {
    var recording: (RecordingTarget, RecordingStyle)? { if case .record(let t, let s)? = value { return (t, s) } else { return nil } }
}

@MainActor
func runRecordOverlayTests() async {
    section("recording overlay: state machine")

    var m = recordMachine()
    check(m.state == .armed && m.recordingMode == .area, "a recording opens armed, on the Area target")
    m.send(.down(CGPoint(x: 100, y: 100), []))
    m.send(.up(CGPoint(x: 300, y: 220), []))
    check(adjustingRect(m) == CGRect(x: 100, y: 100, width: 200, height: 120), "mouse-up leaves an adjustable selection, never a capture")
    m.send(.keyDown(.confirm, []))
    check(recorded(m).map { $0.0 == .area(Selection(rect: CGRect(x: 100, y: 100, width: 200, height: 120))) && $0.1 == .video } == true,
          "Return records the area as a video", detail: "\(m.state)")

    m = recordMachine(remembered: CGRect(x: 100, y: 100, width: 200, height: 120))
    m.send(.keyDown(.confirm, [.shift]))
    check(recorded(m)?.1 == .editing, "Shift-Return records it for editing")

    m = recordMachine(remembered: CGRect(x: 100, y: 100, width: 200, height: 120))
    m.send(.keyDown(.confirm, [.option]))
    check(recorded(m)?.1 == .gif, "Option-Return records it as a GIF")
    m = recordMachine(remembered: CGRect(x: 100, y: 100, width: 200, height: 120))
    m.send(.toolbar(.record(.gif)))
    check(recorded(m)?.1 == .gif, "the Record GIF button records it as a GIF")

    m = recordMachine(remembered: CGRect(x: 100, y: 100, width: 200, height: 120))
    check(adjustingRect(m) == CGRect(x: 100, y: 100, width: 200, height: 120), "a remembered area opens already selected")
    m.send(.toolbar(.record(.editing)))
    check(recorded(m)?.1 == .editing, "the Record Project button records it as a project")
    m = recordMachine(remembered: CGRect(x: 500, y: 100, width: 200, height: 100))
    check(adjustingRect(m) == CGRect(x: 500, y: 100, width: 100, height: 100), "a remembered area across two displays keeps only the part on one display",
          detail: "\(String(describing: adjustingRect(m)))")
    m = recordMachine(remembered: CGRect(x: 5000, y: 5000, width: 100, height: 100))
    check(m.state == .armed, "a remembered area on no display opens armed")
    var still = SelectionMachine(config: MachineConfig(flow: .adjustable, intent: .area, displays: [d1, d2]))
    still.send(.toolbar(.record(.video)))
    check(still.state == .idle, "the record action does nothing outside a recording")

    m = recordMachine()
    m.send(.down(CGPoint(x: 500, y: 100), []))
    m.send(.up(CGPoint(x: 700, y: 200), []))
    check(adjustingRect(m)?.maxX == 600, "a recording's drag stays on the display it began on", detail: "\(String(describing: adjustingRect(m)))")

    m = recordMachine(cursor: CGPoint(x: 300, y: 200))
    m.send(.toolbar(.mode(.fullscreen)))
    check(adjustingRect(m) == d1.frame && m.recordingMode == .fullscreen, "Fullscreen selects the whole display under the pointer and waits")
    var back = m
    back.send(.toolbar(.mode(.area)))
    check(back.state == .armed && back.recordingMode == .area, "Area after Fullscreen goes back to drawing an area")
    m.send(.keyDown(.confirm, []))
    check(recorded(m).map { $0.0 == .fullscreen(d1) } == true, "a selection that fills a display records that display", detail: "\(m.state)")
    m = recordMachine(remembered: CGRect(x: 650, y: 50, width: 100, height: 100))
    m.send(.toolbar(.mode(.fullscreen)))
    check(adjustingRect(m) == d2.frame, "Fullscreen from a selection picks the selection's display")

    m = recordMachine(cursor: CGPoint(x: 100, y: 100))
    m.send(.toolbar(.mode(.window)))
    check(m.state == .windowHover(winA) && m.recordingMode == .window, "Window hovers the window under the pointer")
    m.send(.down(CGPoint(x: 100, y: 100), []))
    check(m.state == .windowPicked(winA), "a click picks it and waits, so a start button can be chosen")
    m.send(.move(CGPoint(x: 400, y: 300)))
    check(m.state == .windowPicked(winA), "moving the pointer keeps the pick")
    m.send(.down(CGPoint(x: 450, y: 250), []))
    check(m.state == .windowPicked(winB), "clicking another window picks that one")
    m.send(.toolbar(.record(.video)))
    check(recorded(m).map { $0.0 == .window(winB, toggleShadow: false) && $0.1 == .video } == true, "Record MP4 records just that window")
    m = recordMachine(cursor: CGPoint(x: 100, y: 100))
    m.send(.toolbar(.mode(.window)))
    m.send(.down(CGPoint(x: 100, y: 100), []))
    m.send(.down(CGPoint(x: 580, y: 380), []))
    check(m.state == .windowHover(nil), "clicking past every window drops the pick")
    m.send(.move(CGPoint(x: 100, y: 100)))
    m.send(.keyDown(.confirm, [.shift]))
    check(recorded(m).map { $0.0 == .window(winA, toggleShadow: false) && $0.1 == .editing } == true, "Shift-Return on a hovered window records it for editing")
    m = recordMachine(cursor: CGPoint(x: 100, y: 100))
    m.send(.toolbar(.mode(.window)))
    m.send(.down(CGPoint(x: 100, y: 100), []))
    m.send(.toolbar(.mode(.area)))
    check(m.state == .armed && m.config.intent == .record, "Area from a picked window goes back to drawing, still recording")

    section("recording overlay: aspect lock, Option, edge snapping")
    m = recordMachine()
    m.send(.toolbar(.aspect(.ratio(16, 9))))
    m.send(.down(CGPoint(x: 100, y: 100), []))
    m.send(.up(CGPoint(x: 260, y: 120), []))
    if let r = adjustingRect(m) { check(abs(r.width / r.height - 16.0 / 9.0) < 0.02, "the aspect lock holds the drag to 16:9", detail: "\(r)") }
    m.send(.toolbar(.size(width: 320, height: nil)))
    check(adjustingRect(m)?.size == CGSize(width: 320, height: 180), "a typed width keeps the ratio", detail: "\(String(describing: adjustingRect(m)))")

    var c = machine(.immediate)
    c.send(.down(CGPoint(x: 200, y: 200), [.option]))
    c.send(.drag(CGPoint(x: 260, y: 240), [.option]))
    check(c.liveRect == CGRect(x: 140, y: 160, width: 120, height: 80), "Option grows the drag from its centre", detail: "\(String(describing: c.liveRect))")
    c.send(.modifiers([]))
    check(c.liveRect == CGRect(x: 200, y: 200, width: 60, height: 40), "releasing Option grows it from the corner again", detail: "\(String(describing: c.liveRect))")
    c = machine(.immediate)
    c.send(.down(CGPoint(x: 50, y: 50), [.option]))
    c.send(.drag(CGPoint(x: 200, y: 120), [.option]))
    check(c.liveRect == CGRect(x: 0, y: 0, width: 100, height: 100), "a centred drag stops at the nearest display edge without moving its centre",
          detail: "\(String(describing: c.liveRect))")
    c = machine(.adjustable)
    c.send(.down(CGPoint(x: 100, y: 100), []))
    c.send(.up(CGPoint(x: 300, y: 200), []))
    c.send(.down(CGPoint(x: 300, y: 200), [.option]))
    c.send(.up(CGPoint(x: 320, y: 210), [.option]))
    check(adjustingRect(c) == CGRect(x: 80, y: 90, width: 240, height: 120), "an Option handle drag moves the opposite edges too", detail: "\(String(describing: adjustingRect(c)))")
    c.send(.down(CGPoint(x: 320, y: 150), [.option]))
    c.send(.up(CGPoint(x: 330, y: 170), [.option]))
    check(adjustingRect(c) == CGRect(x: 70, y: 90, width: 260, height: 120), "and an Option edge drag keeps the other side's size", detail: "\(String(describing: adjustingRect(c)))")

    m = recordMachine()
    m.send(.down(CGPoint(x: 45, y: 120), []))
    m.send(.up(CGPoint(x: 205, y: 254), []))
    check(adjustingRect(m) == CGRect(x: 40, y: 120, width: 160, height: 140), "a recording's drag snaps onto window edges within 8 points",
          detail: "\(String(describing: adjustingRect(m)))")
    m = recordMachine()
    m.send(.down(CGPoint(x: 45, y: 120), [.command]))
    m.send(.up(CGPoint(x: 205, y: 254), [.command]))
    check(adjustingRect(m) == CGRect(x: 45, y: 120, width: 160, height: 134), "Command holds the snapping off", detail: "\(String(describing: adjustingRect(m)))")
    c = machine(.adjustable)
    c.send(.down(CGPoint(x: 45, y: 120), []))
    c.send(.up(CGPoint(x: 205, y: 254), []))
    check(adjustingRect(c) == CGRect(x: 45, y: 120, width: 160, height: 134), "a still capture never snaps", detail: "\(String(describing: adjustingRect(c)))")
    m = recordMachine()
    m.send(.down(CGPoint(x: 330, y: 340), []))
    m.send(.up(CGPoint(x: 360, y: 395), []))
    check(adjustingRect(m)?.maxY == 400, "the top edge snaps to the display edge", detail: "\(String(describing: adjustingRect(m)))")
    m = recordMachine(remembered: CGRect(x: 520, y: 20, width: 40, height: 40))
    m.send(.down(CGPoint(x: 540, y: 40), []))
    m.send(.up(CGPoint(x: 575, y: 40), []))
    check(adjustingRect(m)?.maxX == 600, "moving a selection snaps its edge to the display edge", detail: "\(String(describing: adjustingRect(m)))")
    m = recordMachine()
    m.send(.down(CGPoint(x: 100, y: 10), []))
    m.send(.up(CGPoint(x: 204, y: 30), []))
    check(adjustingRect(m) == CGRect(x: 100, y: 10, width: 104, height: 20), "a window edge does not pull a pointer far above or below the window",
          detail: "\(String(describing: adjustingRect(m)))")

    section("recording overlay: the all-in-one Record mode")
    var a = machine(.adjustable)
    a.send(.down(CGPoint(x: 450, y: 100), []))
    a.send(.up(CGPoint(x: 650, y: 200), []))
    a.send(.toolbar(.mode(.record)))
    check(a.config.intent == .record && adjustingRect(a) == CGRect(x: 450, y: 100, width: 150, height: 100), "Record keeps the selection, cut to the display holding most of it",
          detail: "\(String(describing: adjustingRect(a)))")
    a.send(.toolbar(.mode(.area)))
    check(a.config.intent == .record, "Area inside a recording changes the target, not the mode")
    a.send(.keyDown(.confirm, []))
    check(recorded(a)?.1 == .video, "and Return records")

    section("recording overlay: real views, offscreen")
    let s1 = Fixtures.display(id: 1, frame: d1.frame, scale: 1, windows: [winB, winA], seed: 1)
    let s2 = Fixtures.display(id: 2, frame: d2.frame, scale: 2, windows: [], seed: 2)
    let source = FixtureScreenSource(displays: [s1, s2], windows: [winB, winA])
    let rc = makeController(source, pointer: CGPoint(x: 300, y: 200))
    var out = await start(rc, .recording)
    guard let w1 = overlay(rc, frame: d1.frame) else { return check(false, "the recording overlay opens") }
    let ids = ["target.area", "target.window", "target.fullscreen", "width", "height", "aspect", "start.video", "start.editing", "start.gif"].map { "cornermark.record." + $0 }
    check(ids.allSatisfy { findView($0, in: rc.overlayWindows) != nil }, "the panel offers targets, size fields, the aspect lock and three start buttons")
    check(findView("cornermark.toolbar.capture", in: rc.overlayWindows) == nil, "and no Capture button")
    func button(_ id: String) -> NSButton? { findView("cornermark.record." + id, in: rc.overlayWindows) as? NSButton }
    check(button("start.video")?.isEnabled == false && button("start.editing")?.isEnabled == false && button("start.gif")?.isEnabled == false,
          "the start buttons wait for a target")
    check(button("start.video")?.title == "Record MP4" && button("start.editing")?.title == "Record Project" && button("start.gif")?.title == "Record GIF",
          "they are Record MP4, Record Project and Record GIF")
    check(button("start.gif")?.toolTip == "Saves one animated GIF, without sound (Option-Return)", "Record GIF says what it saves and names its shortcut",
          detail: button("start.gif")?.toolTip ?? "nil")
    check(button("start.editing")?.accessibilityHelp() == "Saves a project you can edit: pointer, clicks, keys, camera and sound stay separate until you export."
          && button("start.video")?.accessibilityLabel() == "Record MP4, Return", "VoiceOver hears each button's name, shortcut and what it saves")
    let sourceIDs = ["microphone", "systemAudio", "camera", "input"]
    let toggles = sourceIDs.compactMap { button("source." + $0) as? IconButton }
    check(toggles.count == 4 && toggles.map { $0.accessibilityLabel() ?? "" } == ["Microphone", "System audio", "Camera", "Clicks and keys"]
          && toggles.allSatisfy { $0.accessibilityRole() == .checkBox && ($0.accessibilityValue() as? Int) == 0 && !$0.isSelected && $0.symbol.hasSuffix("slash") },
          "four source toggles, each named for VoiceOver, start off with a slashed glyph", detail: "\(toggles.map { ($0.accessibilityLabel() ?? "", $0.symbol) })")
    check(toggles.allSatisfy { $0.toolTip?.contains(": off.") == true } && toggles.first?.toolTip?.contains("Record GIF never records sound") == true,
          "their tooltips say the state, and the sound ones say a GIF has none", detail: toggles.first?.toolTip ?? "nil")
    var toggled: [RecordingSource] = []
    var sourcesOn: Set<RecordingSource> = []
    rc.toggleRecordingSource = { toggled.append($0); sourcesOn.formSymmetricDifference([$0]); rc.refreshOverlay() }
    rc.recordingSources = { RecordingSources(on: sourcesOn, note: sourcesOn.contains(.microphone) ? .hint("Record GIF never records sound.") : nil) }
    toggles.first?.performClick(nil)
    let mic = toggles.first
    check(toggled == [.microphone] && mic?.isSelected == true && mic?.symbol == "mic.fill" && (mic?.accessibilityValue() as? Int) == 1
          && mic?.toolTip?.hasPrefix("Microphone: on.") == true, "a click hands the source to the app, and the panel shows what it answers",
          detail: "\(toggled) \(mic?.symbol ?? "nil")")
    let note = findView("cornermark.record.sources.note", in: rc.overlayWindows) as? NSTextField
    check(note.map { !$0.isHidden && $0.stringValue == "Record GIF never records sound." } == true, "and its note")
    mic?.performClick(nil)
    check(mic?.isSelected == false && note?.isHidden == true, "a second click turns it off and the note goes")
    let longest = "Turn on Cornermark in System Settings > Privacy & Security > Input Monitoring, then reopen it."
    rc.recordingSources = { RecordingSources(note: .blocked(longest)) }
    rc.refreshOverlay()
    if let note, let panel = note.superview {
        let probe = NSTextField(wrappingLabelWithString: longest)
        probe.font = note.font
        probe.preferredMaxLayoutWidth = note.frame.width
        let fit = (probe.fittingSize.height / NSLayoutManager().defaultLineHeight(for: note.font ?? .systemFont(ofSize: 11))).rounded()
        let row = toggles[0].frame
        check(!note.isHidden && fit <= 2 && note.frame.minY >= row.minY && note.frame.maxY <= row.maxY && note.frame.maxX <= panel.bounds.maxX - 36,
              "the longest note wraps to two lines beside the toggles, inside the panel", detail: "fit=\(fit) note=\(note.frame) row=\(row) panel=\(panel.bounds)")
        let pill = panel.bounds.insetBy(dx: 32, dy: 32)
        check(pill.width <= 480 - 24, "the panel is narrow enough to sit inside a 480 pt selection", detail: "\(pill.size)")
    }
    rc.recordingSources = { RecordingSources(on: sourcesOn) }
    rc.refreshOverlay()
    if let a = button("start.video"), let b = button("start.editing"), let g = button("start.gif") {
        check(a.frame.minY == b.frame.minY && b.frame.minY == g.frame.minY && a.frame.maxX < b.frame.minX && b.frame.maxX < g.frame.minX,
              "the three share the bottom row, primary first", detail: "\([a, b, g].map(\.frame))")
    }
    Synth.drag(w1, from: CGPoint(x: 60, y: 60), to: CGPoint(x: 540, y: 340))
    check(button("start.video")?.isEnabled == true, "a selection enables them")
    if let panel = findView("cornermark.record.start.video", in: rc.overlayWindows)?.superview {
        let frame = panel.convert(panel.bounds, to: nil)
        let visible = frame.insetBy(dx: 32, dy: 32)
        check(abs(visible.midX - 300) <= 1 && abs(visible.midY - 200) <= 1, "the panel sits in the middle of the selection", detail: "\(visible)")
    }
    snapshot(w1, name: "10-recording-panel")
    if let field = findView("cornermark.record.width", in: rc.overlayWindows) as? NSTextField {
        field.stringValue = "400"
        field.sendAction(field.action, to: field.target)
    }
    check(rc.overlayState.map { if case .adjusting(let s, _) = $0 { return s.rect.width == 400 } else { return false } } ?? false, "the width field resizes the selection")
    button("start.video")?.performClick(nil)
    _ = await waitUntil { out.value != nil }
    check(out.recording.map { $0.0 == .display(1, area: CGRect(x: 60, y: 60, width: 400, height: 280)) && $0.1 == .video } == true,
          "Record MP4 ends the overlay with the area on its display", detail: "\(String(describing: out.value))")
    noOverlayWindowsLeft(rc, held: [w1], "after Record MP4")
    check(rc.lastSelection?.rect == CGRect(x: 60, y: 60, width: 400, height: 280), "and remembers the area")

    out = await start(rc, .recording)
    check(rc.overlayState.map { if case .adjusting(let s, _) = $0 { return s.rect == CGRect(x: 60, y: 60, width: 400, height: 280) } else { return false } } ?? false,
          "the next recording opens on the remembered area")
    button("target.fullscreen")?.performClick(nil)
    button("start.editing")?.performClick(nil)
    _ = await waitUntil { out.value != nil }
    check(out.recording.map { $0.0 == .display(1, area: nil) && $0.1 == .editing } == true, "Fullscreen then Record Project records the whole display",
          detail: "\(String(describing: out.value))")

    out = await start(rc, .recording)
    guard let w1b = overlay(rc, frame: d1.frame) else { return check(false, "the overlay opens again") }
    button("target.window")?.performClick(nil)
    // Above the panel, which spans most of this 600 pt display.
    Synth.move(w1b, to: CGPoint(x: 100, y: 220))
    Synth.down(w1b, at: CGPoint(x: 100, y: 220)); Synth.up(w1b, at: CGPoint(x: 100, y: 220))
    check(rc.overlayState == .windowPicked(winA) && button("start.video")?.isEnabled == true, "a clicked window is picked and the start buttons wake")
    check((findView("cornermark.record.width", in: rc.overlayWindows) as? NSTextField).map { $0.stringValue == "260" && !$0.isEnabled } == true,
          "the size fields show the window's size and stay read-only")
    snapshot(w1b, name: "11-recording-window-picked")
    Synth.returnKey(w1b)
    _ = await waitUntil { out.value != nil }
    check(out.recording.map { $0.0 == .window(winA.id) && $0.1 == .video } == true, "Return records just that window", detail: "\(String(describing: out.value))")

    section("recording overlay: keyboard")
    rc.lastSelection = PreviousSelection(rect: CGRect(x: 60, y: 60, width: 480, height: 280))
    out = await start(rc, .recording)
    if let w = overlay(rc, frame: d1.frame), let chrome = w.contentView?.subviews.first(where: { $0.acceptsFirstResponder }) {
        w.makeFirstResponder(chrome)
        Synth.key(w, 48, "\t")
        let width = findView("cornermark.record.width", in: rc.overlayWindows) as? NSTextField
        check(width?.currentEditor() != nil, "Tab moves from the overlay into the width field", detail: "\(String(describing: w.firstResponder))")
        Synth.key(w, 48, "\t")
        check((findView("cornermark.record.height", in: rc.overlayWindows) as? NSTextField)?.currentEditor() != nil, "and on to the height field")
        if let camera = button("source.camera"), w.makeFirstResponder(camera) {
            var toggled: [RecordingSource] = []
            rc.toggleRecordingSource = { toggled.append($0) }
            Synth.key(w, 49, " ")
            check(toggled == [.camera], "Space toggles a focused source", detail: "\(toggled)")
        } else {
            print("NOT VERIFIED: a source toggle could not take keyboard focus here")
        }
        if let fullscreen = button("target.fullscreen"), w.makeFirstResponder(fullscreen) {
            Synth.key(w, 49, " ")
            check(rc.overlayState.map { if case .adjusting(let s, _) = $0 { return s.rect == d1.frame } else { return false } } ?? false,
                  "Space presses a focused target button instead of reaching the overlay", detail: "\(String(describing: rc.overlayState))")
        } else {
            print("NOT VERIFIED: a target button could not take keyboard focus here")
        }
        Synth.escape(w)
    }
    check(out.isCancelled, "Escape leaves from any focus")

    out = await start(rc, .recording)
    if let w = overlay(rc, frame: d1.frame) { Synth.escape(w) }
    check(out.isCancelled && rc.overlayWindows.isEmpty, "Escape leaves without recording")
}

