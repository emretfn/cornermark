import AppKit
import KadrajCapture
import KadrajCore
@testable import KadrajShell

@MainActor
func addCard(_ w: World, _ label: String, _ r: Double = 0.2) -> QuickAccessCard {
    let image = Pix.flat(640, 400, r: r, g: 0.5, b: 0.7, label: label)
    let record = try! w.store.add(image, kind: .area, now: w.now)
    return w.coordinator.overlay.add(record: record, image: image)
}

@MainActor
func checkOverlayLifecycle() async throws {
    section("Quick Access lifecycle (injected clock)")
    let w = try World(after: [.showOverlay])
    defer { w.cleanup() }
    let o = w.coordinator.overlay
    let t0 = w.now
    let card = addCard(w, "one")
    check(card.remaining == 8, "new card gets the configured auto-close delay", detail: "\(String(describing: card.remaining))")

    w.now = t0.addingTimeInterval(5)
    o.tick()
    check(card.remaining == 3 && o.stack.count == 1, "5 s idle: 3 s left, still open")

    let panel = o.panel(for: card)!
    let view = o.cardView(for: card)!
    view.mouseEntered(with: Synth.enterExit(.mouseEntered, in: panel))
    w.now = t0.addingTimeInterval(105)
    o.tick()
    check(card.state == .hovering && card.remaining == 3 && o.stack.count == 1, "100 s of hovering: the countdown is paused")
    view.mouseExited(with: Synth.enterExit(.mouseExited, in: panel))
    w.now = t0.addingTimeInterval(107)
    o.tick()
    check(card.remaining == 1 && card.state == .visible, "after the pointer leaves, the countdown resumes where it stopped")
    w.now = t0.addingTimeInterval(109)
    o.tick()
    check(o.stack.isEmpty && card.state == .closing, "countdown reaching zero closes the card (.closing)")
    check(o.recentlyClosed.last === card, "auto-closed card is kept for restore")

    w.coordinator.perform(.restoreLastOverlay)
    check(o.stack.first === card && card.state == .visible && card.remaining == 8, "restore-last brings it back, visible, with a fresh delay")
    check(o.panel(for: card) != nil && o.panel(for: card) !== panel, "restore builds a fresh panel")
    w.coordinator.perform(.restoreLastOverlay)
    check(o.stack.count == 1 && w.coordinator.hud.lastMessage == "No closed overlay to restore", "restore with nothing closed says so")

    w.now = t0.addingTimeInterval(1000)
    o.tick()
    check(o.stack.isEmpty, "a long idle gap closes the card on the next tick")
    _ = o.restoreLast()
    w.settings.update { $0.overlayAutoClose = nil }
    let never = addCard(w, "never")
    check(never.remaining == nil, "auto-close Never: no countdown")
    w.now = t0.addingTimeInterval(100_000)
    o.tick()
    check(o.stack.contains { $0 === never }, "auto-close Never: card survives any idle time")
    o.closeAll()
    w.settings.update { $0.overlayAutoClose = 8 }

    section("hide all, drag pause, stack order")
    w.now = t0
    let a = addCard(w, "a", 0.1), b = addCard(w, "b", 0.4), c3 = addCard(w, "c", 0.7)
    check(o.stack.map { $0.record.id } == [c3, b, a].map { $0.record.id }, "stack is newest first")
    w.coordinator.perform(.hideOverlays)
    check(o.isHidden, "hideOverlays hides all")
    w.now = t0.addingTimeInterval(500)
    o.tick()
    check(o.stack.count == 3, "hidden overlays do not count down")
    w.coordinator.perform(.hideOverlays)
    check(!o.isHidden, "hideOverlays toggles back")
    w.coordinator.perform(.hideOverlays)
    let d = addCard(w, "d")
    check(!o.isHidden && o.stack.count == 4, "a new capture reveals hidden overlays")

    o.beginDrag(d)
    check(d.state == .dragging, "beginDrag: .dragging")
    w.now = t0.addingTimeInterval(520)
    o.tick()
    check(d.remaining == 8, "dragging pauses the countdown")
    o.endDrag(d, dropped: false)

    let bounds = w.cursorFrame
    let size = QuickAccessLayout.cardSize(width: OverlaySize.medium.cardWidth)
    var expected = QuickAccessLayout.frames(count: 4, cardSize: size, corner: .bottomRight, in: bounds)
    check(o.stack.enumerated().allSatisfy { o.panel(for: $1)?.frame == expected[$0] }, "panels sit at the layout frames, index 0 in the corner")
    check(expected[0].maxX == bounds.maxX - 16 && expected[0].minY == bounds.minY + 16 && expected[1].minY == expected[0].maxY + 10, "bottom right: 16 pt margin, 10 pt gap, stack grows upward")
    check(expected.allSatisfy { bounds.contains($0) }, "all four cards fit the display's visible frame")

    w.settings.update { $0.overlayCorner = .topLeft; $0.overlaySize = .large }
    let large = QuickAccessLayout.cardSize(width: 300)
    expected = QuickAccessLayout.frames(count: 4, cardSize: large, corner: .topLeft, in: bounds)
    check(o.stack.enumerated().allSatisfy { o.panel(for: $1)?.frame == expected[$0] }, "corner and size changes re-layout live cards")
    check(expected[0].minX == bounds.minX + 16 && expected[0].maxY == bounds.maxY - 16 && expected[1].maxY == expected[0].minY - 10, "top left: stack grows downward")
    check(o.cardView(for: d)?.frame.size == large, "card view resized to the large size")
    w.settings.update { $0.overlayCorner = .bottomRight; $0.overlaySize = .medium }

    o.close(b)
    expected = QuickAccessLayout.frames(count: 3, cardSize: size, corner: .bottomRight, in: bounds)
    check(o.stack.enumerated().allSatisfy { o.panel(for: $1)?.frame == expected[$0] }, "closing a middle card closes the gap")

    let second = CGRect(x: 1280, y: 0, width: 1920, height: 1055)
    w.cursorFrame = second
    let onOther = addCard(w, "other display")
    check(second.contains(o.panel(for: onOther)!.frame), "a new card appears on the display with the cursor")
    w.cursorFrame = bounds

    section("card panels never take focus")
    let p = o.panel(for: onOther)!
    check(p.styleMask.contains(.nonactivatingPanel) && p.styleMask.contains(.borderless), "panel is a borderless non-activating panel")
    check(!p.canBecomeKey && !p.canBecomeMain && p.level == .floating && p.hidesOnDeactivate == false, "panel cannot become key or main and floats")
    check(p.collectionBehavior.contains(.canJoinAllSpaces) && !p.isVisible, "panel joins all spaces; harness never ordered it in")

    section("swipe to dismiss")
    let sv = o.cardView(for: onOther)!
    let startOrigin = p.frame.origin
    sv.swipe(dx: 30, dy: 2, ended: false)
    check(p.frame.origin.x == startOrigin.x + 30, "swiping toward the edge drags the card along")
    sv.swipe(dx: 0, dy: 0, ended: true)
    check(p.frame.origin == startOrigin && o.stack.contains { $0 === onOther }, "a short swipe springs back and keeps the card")
    sv.swipe(dx: 40, dy: 1, ended: false)
    sv.swipe(dx: 120, dy: 0, ended: true)
    check(onOther.state == .closing && !o.stack.contains { $0 === onOther }, "a long swipe toward the edge dismisses the card")
    let s2 = addCard(w, "vertical")
    let p2 = o.panel(for: s2)!, v2 = o.cardView(for: s2)!
    v2.swipe(dx: 4, dy: 60, ended: false)
    check(p2.frame.origin.x == QuickAccessLayout.frames(count: 1, cardSize: size, corner: .bottomRight, in: bounds)[0].origin.x, "vertical scrolling does not start a swipe")
    v2.swipe(dx: -200, dy: 0, ended: true)
    check(o.stack.contains { $0 === s2 }, "a swipe away from the edge never dismisses")
    let home = p2.frame.origin
    if let right = Synth.scroll(dx: 80, phase: 2), let left = Synth.scroll(dx: -80, phase: 2), let end = Synth.scroll(phase: 4) {
        v2.scrollWheel(with: right)
        let movedRight = p2.frame.origin != home
        v2.swipe(dx: 0, dy: 0, ended: true)
        v2.scrollWheel(with: left)
        let movedLeft = p2.frame.origin != home
        v2.scrollWheel(with: end)
        check(movedRight != movedLeft, "a real NSEvent scroll wheel reaches the swipe handler (moves for exactly one direction)", detail: "right \(movedRight) left \(movedLeft)")
    } else {
        print("INFO could not synthesize a scroll NSEvent")
    }
    check(nothingOnScreen(), "overlay checks ordered nothing on screen")
}

@MainActor
func checkPins() async throws {
    section("Pin windows")
    let w = try World(after: [])
    defer { w.cleanup() }
    let pins = w.coordinator.pins
    let image = Pix.flat(400, 300, r: 0.3, g: 0.6, b: 0.9, label: "pinned")
    let pin = pins.pin(image, pointScale: 1)
    let win = pin.window
    check(pins.pins.count == 1 && win.frame.size == CGSize(width: 400, height: 300), "pin opens at the image's point size", detail: "\(win.frame)")
    check(abs(win.frame.midX - w.cursorFrame.midX) <= 1 && abs(win.frame.midY - w.cursorFrame.midY) <= 1, "pin opens centered on the cursor display")
    check(win.styleMask.contains(.borderless) && win.styleMask.contains(.resizable) && win.styleMask.contains(.nonactivatingPanel), "borderless, resizable, non-activating")
    check(win.level == .floating && win.isMovableByWindowBackground && !win.isVisible, "always on top, draggable by background, not ordered in")

    let big = pins.pin(Pix.flat(4000, 3000, r: 0.1, g: 0.1, b: 0.1), pointScale: 1)
    check(big.window.frame.width <= w.cursorFrame.width * 0.8 + 1 && big.window.frame.height <= w.cursorFrame.height * 0.8 + 1, "a huge image is scaled to fit the display")
    check(abs(big.window.frame.width / big.window.frame.height - 4.0 / 3.0) < 0.01, "scaled-down pin keeps the aspect ratio")
    let retina = pins.pin(Pix.flat(800, 600, r: 0.5, g: 0.5, b: 0.5), pointScale: 2)
    check(retina.window.frame.size == CGSize(width: 400, height: 300), "a 2x capture opens at half the pixel size in points")
    big.close(); retina.close()
    check(pins.pins.count == 1, "close removes the pin from the manager")

    let o = win.frame.origin
    Synth.key(win, 124); check(win.frame.origin == CGPoint(x: o.x + 1, y: o.y), "right arrow nudges 1 pt")
    Synth.key(win, 123); check(win.frame.origin == o, "left arrow nudges back 1 pt")
    Synth.key(win, 126); check(win.frame.origin == CGPoint(x: o.x, y: o.y + 1), "up arrow nudges 1 pt up")
    Synth.key(win, 125); check(win.frame.origin == o, "down arrow nudges 1 pt down")
    Synth.key(win, 124, modifiers: .shift); check(win.frame.origin == CGPoint(x: o.x + 10, y: o.y), "shift+right nudges 10 pt")
    Synth.key(win, 126, modifiers: .shift); check(win.frame.origin == CGPoint(x: o.x + 10, y: o.y + 10), "shift+up nudges 10 pt up")
    Synth.key(win, 123, modifiers: .shift); Synth.key(win, 125, modifiers: .shift)
    check(win.frame.origin == o, "shift+left and shift+down return to the start")
    Synth.key(win, 0, "a")
    check(win.frame.origin == o && pins.pins.count == 1, "other keys do nothing")

    pin.opacity = 0.5
    check(win.alphaValue == 0.5, "opacity sets the window alpha")
    pin.opacity = 0
    check(win.alphaValue == 0.1, "opacity never goes fully invisible (clamped to 0.1)")
    pin.opacity = 2
    check(win.alphaValue == 1, "opacity clamps at 1")
    let menu = pin.makeMenu()
    check(menu.items.map(\.title) == ["Copy", "Opacity", "Size", "", "Lock Mode (click-through)", "Close"], "right-click menu items", detail: "\(menu.items.map(\.title))")
    let q = menu.items[1].submenu!.items.first { $0.title == "25%" }!
    _ = q.target?.perform(q.action, with: q)
    check(abs(win.alphaValue - 0.25) < 0.001, "menu opacity 25% applies")
    pin.opacity = 1

    var f = win.frame.size
    var proposed = win.windowWillResize(to: NSSize(width: 600, height: 100))
    check(proposed == NSSize(width: 600, height: 450), "drag wider: width leads, height follows at 4:3", detail: "\(proposed)")
    proposed = win.windowWillResize(to: NSSize(width: 400, height: 600))
    check(proposed == NSSize(width: 800, height: 600), "drag taller: height leads, width follows at 4:3", detail: "\(proposed)")
    proposed = win.windowWillResize(to: NSSize(width: 5, height: 5))
    check(proposed.width >= PinController.minWidth && abs(proposed.width / proposed.height - 4.0 / 3.0) < 0.01, "tiny resize stops at the minimum size, same ratio", detail: "\(proposed)")
    f = win.frame.size
    let center = CGPoint(x: win.frame.midX, y: win.frame.midY)
    pin.zoom(by: 2)
    check(win.frame.size == CGSize(width: f.width * 2, height: f.height * 2) && abs(win.frame.midX - center.x) <= 1 && abs(win.frame.midY - center.y) <= 1, "zoom doubles the size about the center")
    pin.zoom(by: 100)
    check(win.frame.width == 1600, "zoom is capped at 4x the opening size")
    pin.zoom(by: 0.0001)
    check(win.frame.width == PinController.minWidth, "zoom is floored at the minimum width")
    pin.resetSize()
    check(win.frame.size == CGSize(width: 400, height: 300), "Actual Size restores the opening size")
    if let up = Synth.scroll(dy: 40), let content = win.contentView {
        let wBefore = win.frame.width
        content.scrollWheel(with: up)
        check(win.frame.width != wBefore, "a scroll event over the pin zooms it", detail: "\(wBefore) -> \(win.frame.width)")
        pin.resetSize()
    } else { print("INFO could not synthesize a scroll NSEvent") }

    pin.setLocked(true)
    check(win.ignoresMouseEvents && pin.isLocked, "Lock Mode sets ignoresMouseEvents (click-through)")
    check(pins.hasLocked, "manager knows a pin is locked")
    let builder = StatusMenuBuilder(coordinator: w.coordinator)
    let status = NSMenu()
    builder.populate(status)
    let pinned = status.items.first { $0.title.hasPrefix("Pin 1") }
    check(status.items.contains { $0.title == "Pinned Screenshots" } && pinned != nil, "menu bar menu lists pinned items")
    check(pinned?.image != nil, "locked pin shows a lock icon in the menu")
    let unlock = pinned?.submenu?.items.first { $0.title == "Unlock" }
    check(unlock != nil, "the pinned item offers Unlock")
    if let unlock { _ = unlock.target?.perform(unlock.action, with: unlock) }
    check(!win.ignoresMouseEvents && !pin.isLocked, "Unlock from the menu bar restores mouse events")

    pin.setLocked(true)
    pins.unlockAll()
    check(!win.ignoresMouseEvents, "Unlock All clears every lock")

    let content = win.contentView as! PinContentView
    content.setHovering(true)
    let closeBtn = findView("card.close", in: content) as? NSButton
    check(closeBtn?.isHidden == false, "hover shows the close button")
    pasteClear(w)
    let copyItem = pin.makeMenu().items[0]
    _ = copyItem.target?.perform(copyItem.action, with: copyItem)
    check(w.pasteboardImage()?.width == 400, "menu Copy puts the pin's image on the pasteboard")
    closeBtn?.performClick(nil)
    check(pins.pins.isEmpty, "the close button removes the pin")

    let pin2 = pins.pin(image)
    Synth.key(pin2.window, 53, "\u{1b}")
    check(pins.pins.isEmpty, "Escape removes the pin")

    let pin3 = pins.pin(image), pin4 = pins.pin(image)
    pin3.setLocked(true)
    builder.populate(status)
    check(status.items.contains { $0.title == "Close All Pins" } && status.items.contains { $0.title == "Unlock All" }, "with two pins the menu offers Unlock All and Close All Pins")
    _ = pin4
    pins.closeAll()
    check(pins.pins.isEmpty && nothingOnScreen(), "pins closed; nothing ever on screen")
}

@MainActor
func pasteClear(_ w: World) { w.pasteboard.clearContents() }

extension PinWindow {
    @MainActor
    func windowWillResize(to size: NSSize) -> NSSize { controller!.windowWillResize(self, to: size) }
}
