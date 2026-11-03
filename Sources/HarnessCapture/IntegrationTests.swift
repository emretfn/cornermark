import AppKit
import CornermarkCapture
import CornermarkCore

@MainActor
func expectPixels(_ out: CaptureOutput?, from source: DisplaySnapshot, topLeftRect px: CGRect, _ name: String) {
    guard let out else { return check(false, "\(name): no output") }
    let size = CGSize(width: out.image.width, height: out.image.height)
    guard size == px.size else { return check(false, "\(name): size \(size) != \(px.size)") }
    let got = Pixels.rgba(out.image)
    let all = Pixels.rgba(source.image)
    let want = Pixels.sub(all, width: source.image.width, rect: px)
    let firstDiff = zip(got, want).enumerated().first { $0.element.0 != $0.element.1 }?.offset
    check(got == want, "\(name): \(Int(px.width))x\(Int(px.height)) pixels equal the fixture at (\(Int(px.minX)),\(Int(px.minY)))",
          detail: "first differing byte \(String(describing: firstDiff))")
}

@MainActor
func noOverlayWindowsLeft(_ c: CaptureController, held: [NSWindow], _ name: String) {
    let visible = NSApp.windows.filter { $0.level == .screenSaver && $0.isVisible }
    let closed = held.allSatisfy { closedWindows.contains(ObjectIdentifier($0)) && !$0.isVisible }
    check(c.overlayWindows.isEmpty && visible.isEmpty && closed, "\(name): all overlay windows closed", detail: "visible=\(visible.count) closed=\(closed)")
}

@MainActor
func runIntegrationTests() async {
    let s1 = Fixtures.display(id: 1, frame: d1.frame, scale: 1, windows: [winB, winA], seed: 1)
    let s2 = Fixtures.display(id: 2, frame: d2.frame, scale: 2, windows: [], seed: 2)
    let source = FixtureScreenSource(displays: [s1, s2], windows: [winB, winA])

    section("area capture")
    let c = makeController(source)
    var out = await start(c, .area)
    let held = c.overlayWindows
    check(held.count == 2, "one overlay window per display", detail: "\(held.count)")
    let w1 = overlay(c, frame: d1.frame)!
    check(held.allSatisfy { $0.level == .screenSaver && $0.styleMask.contains(.nonactivatingPanel) && $0.styleMask.contains(.borderless) },
          "overlays are borderless non-activating panels at .screenSaver level")
    check(held.allSatisfy { $0.canBecomeKey && !$0.hasShadow && ($0.contentView?.subviews.count ?? 0) == 2 }, "overlays can become key and hold backdrop plus chrome")
    Synth.drag(w1, from: CGPoint(x: 100, y: 80), to: CGPoint(x: 300, y: 200))
    _ = await waitUntil { out.value != nil }
    expectPixels(out.output, from: s1, topLeftRect: CGRect(x: 100, y: 200, width: 200, height: 120), "area drag at scale 1")
    check(out.output?.kind == .area && out.output?.pointScale == 1, "area output is kind .area at pointScale 1")
    noOverlayWindowsLeft(c, held: held, "after area capture")
    check(c.lastSelection == PreviousSelection(rect: CGRect(x: 100, y: 80, width: 200, height: 120)), "lastSelection remembers the rect")
    let firstArea = out.output

    out = await start(c, .previousArea)
    _ = await waitUntil { out.value != nil }
    check(c.overlayWindows.isEmpty, "previousArea shows no UI")
    expectPixels(out.output, from: s1, topLeftRect: CGRect(x: 100, y: 200, width: 200, height: 120), "previousArea")
    check(out.output.map { Pixels.rgba($0.image) } == firstArea.map { Pixels.rgba($0.image) }, "previousArea returns the same pixels as the original capture")

    out = await start(c, .area)
    let w2 = overlay(c, frame: d2.frame)!
    Synth.drag(w2, from: CGPoint(x: 650.5, y: 40), to: CGPoint(x: 850.5, y: 160))
    _ = await waitUntil { out.value != nil }
    expectPixels(out.output, from: s2, topLeftRect: CGRect(x: 101, y: 280, width: 400, height: 240), "area drag at scale 2 (half-point coordinates)")
    check(out.output?.pointScale == 2, "scale-2 output reports pointScale 2")

    out = await start(c, .area)
    let w1b = overlay(c, frame: d1.frame)!
    Synth.drag(w1b, from: CGPoint(x: 550, y: 350), to: CGPoint(x: 700, y: 100))
    _ = await waitUntil { out.value != nil }
    if let o = out.output {
        let canvas = Pixels.rgba(o.image)
        let fromD2 = Pixels.sub(canvas, width: o.image.width, rect: CGRect(x: 100, y: 100, width: 200, height: 400))
        let want = Pixels.sub(Pixels.rgba(s2.image), width: s2.image.width, rect: CGRect(x: 0, y: 0, width: 200, height: 400))
        let gap = Pixels.sub(canvas, width: o.image.width, rect: CGRect(x: 100, y: 0, width: 200, height: 100))
        check(o.image.width == 300 && o.image.height == 500 && o.pointScale == 2, "drag from display 1 into display 2 gives a 300x500 canvas at scale 2", detail: "\(o.image.width)x\(o.image.height) @\(o.pointScale)")
        check(fromD2 == want, "the part on the 2x display is its exact fixture pixels")
        check(gap.allSatisfy { $0 == 0 }, "the region above the shorter 2x display is transparent")
    } else { check(false, "drag spanning displays produces an output") }

    out = await start(c, .area)
    let w1c = overlay(c, frame: d1.frame)!
    Synth.drag(w1c, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 300, y: 160), modifiers: [.shift])
    _ = await waitUntil { out.value != nil }
    expectPixels(out.output, from: s1, topLeftRect: CGRect(x: 100, y: 100, width: 200, height: 200), "shift constrains the real drag to a square")

    out = await start(c, .area)
    let w1d = overlay(c, frame: d1.frame)!
    Synth.drag(w1d, from: CGPoint(x: 120, y: 90), to: CGPoint(x: 260, y: 230), release: false)
    check(c.overlayState.map { if case .dragging = $0 { return true } else { return false } } ?? false, "mid-drag the overlay is in .dragging")
    snapshot(w1d, name: "01-area-mid-drag-loupe")
    Synth.escape(w1d)
    check(out.isCancelled, "escape mid-drag cancels")
    noOverlayWindowsLeft(c, held: [w1d], "after escape mid-drag")

    out = await start(c, .area)
    let w1e = overlay(c, frame: d1.frame)!
    let heldE = c.overlayWindows
    Synth.escape(w1e)
    check(out.isCancelled, "escape cancels while armed")
    noOverlayWindowsLeft(c, held: heldE, "after escape while armed")

    out = await start(c, .area)
    c.cancel()
    check(out.isCancelled && c.overlayWindows.isEmpty, "cancel() tears the overlay down")

    let first = await start(c, .area)
    let second = await start(c, .area)
    check(first.isCancelled && second.value == nil && c.overlayWindows.count == 2, "a new begin cancels the previous capture")
    c.cancel()

    section("area capture on a second display, mid-drag snapshot")
    out = await start(c, .area)
    let w2b = overlay(c, frame: d2.frame)!
    Synth.drag(w2b, from: CGPoint(x: 660, y: 60), to: CGPoint(x: 820, y: 170), release: false)
    snapshot(w2b, name: "02-area-mid-drag-scale2")
    c.cancel()

    print("NOT VERIFIED (headless): ordered-in windows, key-window status, activation, AppKit-dispatched mouse events, real screen levels")

    section("all-in-one")
    let a = makeController(source)
    out = await start(a, .allInOne)
    let wa = overlay(a, frame: d1.frame)!
    check(findView("cornermark.toolbar.capture", in: a.overlayWindows) != nil, "toolbar is visible before any selection")
    Synth.drag(wa, from: CGPoint(x: 100, y: 160), to: CGPoint(x: 300, y: 260))
    func rect() -> CGRect? { if case .adjusting(let s, _)? = a.overlayState { return s.rect } else { return nil } }
    check(rect() == CGRect(x: 100, y: 160, width: 200, height: 100) && out.value == nil, "mouse-up leaves an adjustable selection", detail: "\(String(describing: rect()))")
    let toolbarIDs = ["mode.area", "mode.window", "mode.fullscreen", "mode.scrolling", "mode.timer"].map { "cornermark.toolbar." + $0 }
        + ["cornermark.toolbar.aspect", "cornermark.toolbar.width", "cornermark.toolbar.height", "cornermark.toolbar.capture"]
    check(toolbarIDs.allSatisfy { findView($0, in: a.overlayWindows) != nil }, "toolbar offers modes, aspect menu, size fields and Capture")
    snapshot(wa, name: "03-all-in-one-toolbar")

    Synth.drag(wa, from: CGPoint(x: 300, y: 160), to: CGPoint(x: 350, y: 120))
    check(rect() == CGRect(x: 100, y: 120, width: 250, height: 140), "dragging the bottom-right handle resizes", detail: "\(String(describing: rect()))")
    Synth.arrow(wa, 124)
    check(rect()?.minX == 101, "right arrow nudges by 1pt", detail: "\(String(describing: rect()))")
    Synth.arrow(wa, 126, shift: true)
    check(rect()?.minY == 130, "shift+up nudges by 10pt", detail: "\(String(describing: rect()))")
    Synth.drag(wa, from: CGPoint(x: 200, y: 200), to: CGPoint(x: 240, y: 220))
    check(rect() == CGRect(x: 141, y: 150, width: 250, height: 140), "dragging inside moves the selection", detail: "\(String(describing: rect()))")

    if let popup = findView("cornermark.toolbar.aspect", in: a.overlayWindows) as? NSPopUpButton {
        popup.selectItem(at: 3)
        popup.sendAction(popup.action, to: popup.target)
    }
    if let r = rect() { check(abs(r.width / r.height - 16.0 / 9.0) < 0.01, "toolbar aspect menu locks 16:9", detail: "\(r)") }
    if let field = findView("cornermark.toolbar.width", in: a.overlayWindows) as? NSTextField {
        field.stringValue = "320"
        field.sendAction(field.action, to: field.target)
    }
    check(rect()?.size == CGSize(width: 320, height: 180), "typing 320 in the width field gives 320x180 under 16:9", detail: "\(String(describing: rect()))")
    Synth.drag(wa, from: CGPoint(x: rect()!.maxX, y: rect()!.minY), to: CGPoint(x: 500, y: 40))
    if let r = rect() { check(abs(r.width / r.height - 16.0 / 9.0) < 0.01 && r.minX == 141 && r.maxY == 290, "handle resize keeps 16:9 under the lock", detail: "\(r)") }
    snapshot(wa, name: "04-all-in-one-aspect-locked")

    if let popup = findView("cornermark.toolbar.aspect", in: a.overlayWindows) as? NSPopUpButton {
        popup.selectItem(at: 0)
        popup.sendAction(popup.action, to: popup.target)
    }
    if let field = findView("cornermark.toolbar.height", in: a.overlayWindows) as? NSTextField {
        field.stringValue = "100"
        field.sendAction(field.action, to: field.target)
    }
    let final = rect()!
    check(final.height == 100, "free lock accepts a typed height", detail: "\(final)")
    Synth.returnKey(wa)
    _ = await waitUntil { out.value != nil }
    expectPixels(out.output, from: s1, topLeftRect: CGRect(x: final.minX, y: 400 - final.maxY, width: final.width, height: final.height), "Return commits the adjusted rect")
    noOverlayWindowsLeft(a, held: [wa], "after all-in-one commit")

    out = await start(a, .allInOne)
    let wa2 = overlay(a, frame: d1.frame)!
    Synth.drag(wa2, from: CGPoint(x: 60, y: 160), to: CGPoint(x: 160, y: 240))
    (findView("cornermark.toolbar.capture", in: a.overlayWindows) as? NSButton)?.performClick(nil)
    _ = await waitUntil { out.value != nil }
    expectPixels(out.output, from: s1, topLeftRect: CGRect(x: 60, y: 160, width: 100, height: 80), "toolbar Capture button commits")

    out = await start(a, .allInOne)
    let wa3 = overlay(a, frame: d1.frame)!
    Synth.drag(wa3, from: CGPoint(x: 60, y: 160), to: CGPoint(x: 160, y: 240))
    Synth.escape(wa3)
    check(out.isCancelled, "escape cancels while adjusting")
    noOverlayWindowsLeft(a, held: [wa3], "after escape while adjusting")

    section("window capture")
    let wc = makeController(source, pointer: CGPoint(x: 250, y: 150))
    out = await start(wc, .window)
    let ww = overlay(wc, frame: d1.frame)!
    check(wc.overlayState == .windowHover(winB), "window mode starts on the window under the pointer", detail: "\(String(describing: wc.overlayState))")
    Synth.move(ww, to: CGPoint(x: 60, y: 80))
    check(wc.overlayState == .windowHover(winA), "hovering the back-only region highlights the back window")
    Synth.move(ww, to: CGPoint(x: 250, y: 150))
    check(wc.overlayState == .windowHover(winB), "hovering where windows overlap highlights the front one")
    snapshot(ww, name: "05-window-hover")
    Synth.key(ww, 49, " ")
    check(wc.overlayState == .armed, "space toggles window mode to area")
    Synth.key(ww, 49, " ")
    check(wc.overlayState == .windowHover(winB), "space toggles back to window")
    Synth.down(ww, at: CGPoint(x: 250, y: 150))
    Synth.up(ww, at: CGPoint(x: 250, y: 150))
    _ = await waitUntil { out.value != nil }
    check(out.output?.kind == .window && out.output?.image.width == 348 && out.output?.image.height == 248, "click captures the hovered window with its shadow margin",
          detail: "\(String(describing: out.output?.image.width))x\(String(describing: out.output?.image.height))")
    if let o = out.output, o.image.width == 348, let body = o.image.cropping(to: CGRect(x: 24, y: 24, width: 300, height: 200)) {
        expectPixels(CaptureOutput(image: body, kind: .window, pointScale: 1), from: s1, topLeftRect: CGRect(x: 200, y: 80, width: 300, height: 200), "window body inside the shadow canvas")
    }
    noOverlayWindowsLeft(wc, held: [ww], "after window capture")

    out = await start(wc, .window)
    let ww2 = overlay(wc, frame: d1.frame)!
    Synth.move(ww2, to: CGPoint(x: 60, y: 80))
    Synth.down(ww2, at: CGPoint(x: 60, y: 80), modifiers: [.option])
    _ = await waitUntil { out.value != nil }
    expectPixels(out.output, from: s1, topLeftRect: CGRect(x: 40, y: 140, width: 260, height: 200), "option-click captures window A without shadow")

    out = await start(wc, .window)
    let ww3 = overlay(wc, frame: d1.frame)!
    Synth.move(ww3, to: CGPoint(x: 550, y: 380))
    Synth.down(ww3, at: CGPoint(x: 550, y: 380))
    check(out.value == nil && wc.overlayState == .windowHover(nil), "clicking bare desktop in window mode does nothing")
    Synth.escape(ww3)
    check(out.isCancelled, "escape cancels window mode")

    section("fullscreen")
    let fc = makeController(source, pointer: CGPoint(x: 700, y: 100))
    out = await start(fc, .fullscreen)
    _ = await waitUntil { out.value != nil }
    expectPixels(out.output, from: s2, topLeftRect: CGRect(x: 0, y: 0, width: 800, height: 600), "fullscreen captures the display under the pointer")
    check(out.output?.kind == .fullscreen && out.output?.pointScale == 2 && fc.overlayWindows.isEmpty, "fullscreen is kind .fullscreen, scale 2, with no overlay")

    section("timer")
    let tc = makeController(source, pointer: CGPoint(x: 10, y: 10))
    tc.countdownTickInterval = 5
    out = await start(tc, .timed(seconds: 3))
    let hud = tc.overlayWindows
    check(hud.count == 1 && tc.overlayState == .countdown(remaining: 3, then: .fullscreen(d1)), "timer shows one countdown HUD", detail: "\(String(describing: tc.overlayState))")
    snapshot(hud[0], name: "06-countdown")
    Synth.escape(hud[0])
    check(out.isCancelled, "escape cancels the countdown")
    noOverlayWindowsLeft(tc, held: hud, "after timer cancel")

    let tc2 = makeController(source, pointer: CGPoint(x: 10, y: 10))
    out = await start(tc2, .timed(seconds: 2))
    _ = await waitUntil { out.value != nil }
    expectPixels(out.output, from: s1, topLeftRect: CGRect(x: 0, y: 0, width: 600, height: 400), "timer expires into a fullscreen capture")
    check(out.output?.kind == .timed && tc2.overlayWindows.isEmpty, "timed output has kind .timed and the HUD is gone")

    let tc3 = makeController(source)
    tc3.timerSeconds = 2
    out = await start(tc3, .allInOne)
    let wt = overlay(tc3, frame: d1.frame)!
    Synth.drag(wt, from: CGPoint(x: 100, y: 160), to: CGPoint(x: 300, y: 260))
    (findView("cornermark.toolbar.mode.timer", in: tc3.overlayWindows) as? NSButton)?.performClick(nil)
    _ = await waitUntil { out.value != nil }
    expectPixels(out.output, from: s1, topLeftRect: CGRect(x: 100, y: 140, width: 200, height: 100), "toolbar Timer captures the selection after the countdown")
    check(out.output?.kind == .timed, "toolbar timer output has kind .timed")

    section("scrolling capture")
    let s3 = Fixtures.display(id: 3, frame: CGRect(x: 0, y: 0, width: 600, height: 500), scale: 1, windows: [], seed: 3)
    let scrollSource = FixtureScreenSource(displays: [s3])
    let page = Fixtures.page(width: 300, height: 1500, seed: 5)
    let offsets = [0, 80, 160, 700, 240, 320, 400]
    scrollSource.liveFrame = { _, call in
        let ctx = Pixels.context(600, 500)
        ctx.draw(s3.image, in: CGRect(x: 0, y: 0, width: 600, height: 500))
        let off = offsets[min(call, offsets.count - 1)]
        ctx.draw(page.cropping(to: CGRect(x: 0, y: off, width: 300, height: 300))!, in: CGRect(x: 50, y: 100, width: 300, height: 300))
        return ctx.makeImage()
    }
    let sc = makeController(scrollSource)
    sc.scrollPollInterval = 0.12
    out = await start(sc, .scrolling)
    let wsc = overlay(sc, frame: s3.frame)!
    Synth.drag(wsc, from: CGPoint(x: 50, y: 100), to: CGPoint(x: 350, y: 400))
    check(sc.overlayWindows.count == 2 && !sc.overlayWindows.contains { $0.frame == s3.frame }, "after the area is picked the overlay is replaced by a frame and a HUD")
    let frameWindow = sc.overlayWindows.first { $0.ignoresMouseEvents }
    check(frameWindow != nil && frameWindow!.frame == CGRect(x: 46, y: 96, width: 308, height: 308), "the border window is click-through around the area", detail: "\(String(describing: frameWindow?.frame))")
    var sawSlower = false
    var shotHUD = false
    let reached = await waitUntil(6) {
        if case .scrollingCapture(_, let p)? = sc.overlayState {
            if p.hint == .scrollSlower { sawSlower = true }
            if p.lines >= 500, !shotHUD, let hudWindow = sc.overlayWindows.first(where: { !$0.ignoresMouseEvents }) {
                shotHUD = true
                snapshot(hudWindow, name: "07-scroll-hud")
            }
            return p.lines == 700
        }
        return false
    }
    check(reached, "stitched height reaches 700 px as the fixture scrolls", detail: "\(String(describing: sc.overlayState))")
    check(sawSlower, "a jump past the overlap raises the scroll-slower hint")
    let scrollWindows = sc.overlayWindows
    (findView("cornermark.scroll.done", in: sc.overlayWindows) as? NSButton)?.performClick(nil)
    _ = await waitUntil { out.value != nil }
    check(out.output?.kind == .scrolling && out.output?.image.width == 300 && out.output?.image.height == 700, "Done returns the stitched 300x700 image with kind .scrolling",
          detail: "\(String(describing: out.output?.image.width))x\(String(describing: out.output?.image.height))")
    if let img = out.output?.image, img.height == 700 {
        let want = Pixels.sub(Pixels.rgba(page), width: 300, rect: CGRect(x: 0, y: 0, width: 300, height: 700))
        check(Pixels.rgba(img) == want, "stitched pixels equal rows 0..<700 of the page")
    }
    noOverlayWindowsLeft(sc, held: scrollWindows, "after scrolling Done")
    let pollsAfter = scrollSource.liveCaptureCount
    try? await Task.sleep(nanoseconds: 400_000_000)
    check(scrollSource.liveCaptureCount == pollsAfter, "polling stops once capture ends")

    let sc2 = makeController(scrollSource)
    sc2.scrollPollInterval = 0.05
    out = await start(sc2, .scrolling)
    Synth.drag(overlay(sc2, frame: s3.frame)!, from: CGPoint(x: 50, y: 100), to: CGPoint(x: 350, y: 400))
    let scrollWindows2 = sc2.overlayWindows
    let hudWin = scrollWindows2.first { !$0.ignoresMouseEvents }!
    Synth.escape(hudWin)
    check(out.isCancelled, "escape cancels scrolling capture")
    noOverlayWindowsLeft(sc2, held: scrollWindows2, "after scrolling escape")

    out = await start(sc2, .scrolling)
    Synth.drag(overlay(sc2, frame: s3.frame)!, from: CGPoint(x: 50, y: 100), to: CGPoint(x: 350, y: 400))
    let scrollWindows3 = sc2.overlayWindows
    (findView("cornermark.scroll.cancel", in: sc2.overlayWindows) as? NSButton)?.performClick(nil)
    check(out.isCancelled, "the HUD Cancel button cancels scrolling capture")
    noOverlayWindowsLeft(sc2, held: scrollWindows3, "after scrolling Cancel")

    section("failures")
    let denied = FixtureScreenSource(displays: [s1])
    denied.failure = .permissionDenied
    for mode in [CaptureMode.area, .fullscreen, .window, .allInOne, .previousArea, .timed(seconds: 2), .scrolling] {
        let dc = makeController(denied)
        let o = Outcome()
        dc.begin(mode) { o.value = $0 }
        _ = await waitUntil { o.value != nil }
        check(o.failure == .permissionDenied && dc.overlayWindows.isEmpty, "permission denied surfaces .failed(.permissionDenied) for \(mode)")
    }
    let empty = FixtureScreenSource(displays: [])
    let ec = makeController(empty)
    let eo = Outcome()
    ec.begin(.area) { eo.value = $0 }
    _ = await waitUntil { eo.value != nil }
    check(eo.failure == .noDisplay, "no displays surfaces .failed(.noDisplay)")
}
