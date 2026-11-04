import AppKit
import Carbon.HIToolbox
import CornermarkCore
import CornermarkDesign
@testable import CornermarkShell

// MARK: Helpers shared with the other checks

extension MenuPanelModel {
    var banner: UpdateBanner? {
        for case .update(let banner) in sections { return banner }
        return nil
    }

    var tiles: [Tile] { sections.flatMap { section -> [Tile] in if case .captures(let t) = section { return t } else { return [] } } }

    var recents: [Recent] { sections.flatMap { section -> [Recent] in if case .recent(_, _, let r) = section { return r } else { return [] } } }

    var overlayRows: [Row] { sections.flatMap { section -> [Row] in if case .rows(let r) = section { return r } else { return [] } } }

    var footerRows: [Row] { sections.flatMap { section -> [Row] in if case .footer(let r) = section { return r } else { return [] } } }

    var pinSection: (header: String, pins: [Pin], bulk: [Row])? {
        for case .pins(let header, let pins, let bulk) in sections { return (header, pins, bulk) }
        return nil
    }

    func row(_ id: ActionID) -> Row? { (overlayRows + footerRows).first { $0.item == .action(id) } }

    /// Everything that can be pressed, enabled or not.
    var allItems: [PanelItem] {
        sections.flatMap { section -> [PanelItem] in
            switch section {
            case .update(let b): return b.button.map { [$0] } ?? []
            case .captures(let t): return t.map(\.item)
            case .recent(_, let all, let r): return [all] + r.map(\.item)
            case .rows(let r), .footer(let r): return r.map(\.item)
            case .pins(_, let pins, let bulk): return pins.flatMap { [$0.lock, $0.close] } + bulk.map(\.item)
            }
        }
    }
}

@MainActor
func panelModel(_ w: World) -> MenuPanelModel { MenuPanelController(coordinator: w.coordinator).currentModel() }

/// The panel for the world's current state, with the real host, not shown anywhere.
@MainActor
private var keptControllers: [MenuPanelController] = []

@MainActor
func panelView(_ w: World, controller: MenuPanelController? = nil) -> (controller: MenuPanelController, view: MenuPanelView) {
    let controller = controller ?? MenuPanelController(coordinator: w.coordinator)
    // The panel's host holds its controller weakly, so a press only works while someone keeps the controller.
    keptControllers.append(controller)
    return (controller, MenuPanelView(model: controller.currentModel(), host: controller.host))
}

/// Presses a part the way a click does: the row, tile or thumbnail itself, or the design system button inside the panel.
@MainActor
@discardableResult
func pressMenu(_ item: PanelItem, in view: MenuPanelView) -> Bool {
    switch view.part(for: item) {
    case let part as MenuPressableView: part.press(); return true
    case let control as NSControl: control.performClick(nil); return true
    default: return false
    }
}

private let screenFrame = CGRect(x: 0, y: 0, width: 1280, height: 775)
private let buttonFrame = CGRect(x: 1100, y: 775, width: 28, height: 25)

private func textFits(_ text: String, _ style: CornermarkDesign.TextStyle, in width: CGFloat) -> Bool {
    NSAttributedString(string: text, attributes: style.attributes(color: .black)).size().width <= width
}

@MainActor
private func key(_ code: Int, in view: MenuPanelView) -> Bool {
    view.handleKey(Synth.keyEvent(nil, UInt16(code)))
}

@MainActor
func checkMenuPanel() async throws {
    try await checkMenuPanelModel()
    try await checkMenuPanelFocus()
    try await checkMenuPanelBehaviour()
    try await checkMenuPanelViews()
    try await checkMenuPanelSnapshots()
}

// MARK: Model

@MainActor
private func checkMenuPanelModel() async throws {
    section("menu panel: what it shows")
    let released = AppRelease(version: AppVersion(0, 3, 0), notes: "Notes", pageURL: URL(string: "https://github.com/emretfn/cornermark/releases/tag/v0.3.0")!,
                              dmgURL: URL(string: "https://github.com/emretfn/cornermark/releases/download/v0.3.0/Cornermark.dmg"))
    func model(_ s: Settings = Settings(), update: UpdateState = .idle, hidden: Bool = false, restore: Bool = false,
               pins: [PinSummary] = [], recent: [CaptureRecord] = []) -> MenuPanelModel {
        MenuPanelModel.make(settings: s, update: update, overlaysHidden: hidden, canRestoreOverlay: restore, pins: pins, recent: recent, dateText: { "on \($0.timeIntervalSince1970)" })
    }
    func records(_ n: Int) -> [CaptureRecord] {
        (0..<n).map { CaptureRecord(createdAt: Date(timeIntervalSince1970: Double($0) * 60), kind: .area, pixelSize: CGSize(width: 10, height: 10), directoryName: "d\($0)") }
    }

    let base = model()
    check(base.tiles.map(\.title) == ["All-in-One", "Area", "Window", "Screen", "Previous", "Scroll", "Text", "Timer"], "the grid lists the eight captures by their short names",
          detail: "\(base.tiles.map(\.title))")
    check(base.tiles.map(\.item) == ActionTable.specs.filter { $0.menuGroup == 0 }.map { .action($0.id) }, "in the action table's order")
    check(base.tiles.allSatisfy { ActionTable.spec(($0.item.actionID)!).symbol == $0.symbol }, "each tile takes its symbol from the table")

    for state: UpdateState in [.idle, .checking(manual: true), .checking(manual: false), .available(released)] {
        for hasRecent in [false, true] {
            let m = model(update: state, recent: hasRecent ? records(2) : [])
            let reachable = Set(m.allItems)
            let missing = ActionTable.specs.filter { $0.menuGroup != nil && !reachable.contains(.action($0.id)) }.map(\.id)
            check(missing.isEmpty, "every action with a menu group is reachable (\(state), recents: \(hasRecent))", detail: "\(missing)")
        }
    }
    check(ActionTable.specs.filter { $0.menuGroup == nil }.allSatisfy { !Set(base.allItems).contains(.action($0.id)) }, "actions without a menu group stay out of the panel")

    let noRecent = model()
    check(noRecent.recents.isEmpty && !noRecent.sections.contains { if case .recent = $0 { return true } else { return false } }, "no recents section while the history is empty")
    check(noRecent.row(.history) != nil, "the history stays reachable from the footer then")
    let twoRecent = model(recent: records(2))
    check(twoRecent.recents.count == 2 && twoRecent.row(.history) == nil, "with recents the All control opens the history and the footer drops its row")
    check(Set(twoRecent.allItems).contains(.action(.history)), "the All control is the history action")
    let many = model(recent: records(5))
    check(many.recents.count == 3, "recents are capped at three", detail: "\(many.recents.count)")
    check(many.recents.map(\.record.createdAt) == [240, 180, 120].map { Date(timeIntervalSince1970: $0) }, "newest first", detail: "\(many.recents.map(\.record.createdAt))")
    check(many.recents.allSatisfy { $0.accessibilityLabel.contains("on ") && $0.accessibilityLabel.hasPrefix("Area capture") }, "a thumbnail is labelled with its kind and date", detail: "\(many.recents.map(\.accessibilityLabel))")

    check(base.tiles.first { $0.item == .action(.area) }?.shortcut == "\u{2303}\u{21E7}2", "a tile shows the shortcut in Mac order", detail: "\(String(describing: base.tiles.map(\.shortcut)))")
    check(base.tiles.first { $0.item == .action(.area) }?.accessibilityLabel == "Capture Area, Control Shift 2", "and speaks it with the long title",
          detail: base.tiles.first { $0.item == .action(.area) }?.accessibilityLabel ?? "nil")
    check(base.tiles.compactMap(\.shortcut).count == 8, "all eight captures show one by default")
    var custom = Settings()
    custom.customShortcuts["area"] = HotKey(keyCode: 40, modifiers: UInt32(controlKey | optionKey))
    custom.disabledShortcuts.insert("window")
    let changed = model(custom)
    check(changed.tiles.first { $0.item == .action(.area) }?.shortcut == "\u{2303}\u{2325}K"
          && changed.tiles.first { $0.item == .action(.area) }?.accessibilityLabel == "Capture Area, Control Option K", "a custom shortcut replaces the default")
    check(changed.tiles.first { $0.item == .action(.window) }?.shortcut == nil
          && changed.tiles.first { $0.item == .action(.window) }?.accessibilityLabel == "Capture Window", "a disabled shortcut shows nothing and is not spoken")

    check(base.row(.restoreOverlay)?.isEnabled == false, "Restore Last Overlay is disabled while nothing was closed")
    check(model(restore: true).row(.restoreOverlay)?.isEnabled == true, "and enabled once something was")
    check(base.row(.hideOverlays)?.title == "Hide Overlays" && base.row(.hideOverlays)?.symbol == "eye.slash", "Hide Overlays while they show")
    check(model(hidden: true).row(.hideOverlays)?.title == "Show Overlays" && model(hidden: true).row(.hideOverlays)?.symbol == "eye", "Show Overlays while they are hidden")
    check(base.footerRows.map(\.title) == ["Capture History\u{2026}", "What's New\u{2026}", "Check for Updates\u{2026}", "Settings\u{2026}", "Quit Cornermark"],
          "without recents the footer starts with the history", detail: "\(base.footerRows.map(\.title))")
    check(twoRecent.footerRows.map(\.title) == ["What's New\u{2026}", "Check for Updates\u{2026}", "Settings\u{2026}", "Quit Cornermark"], "with titles from the action table", detail: "\(twoRecent.footerRows.map(\.title))")

    check(base.banner == nil && base.row(.checkForUpdates)?.isEnabled == true && base.row(.checkForUpdates)?.title == "Check for Updates\u{2026}", "idle: no update row, Check for updates is enabled")
    let checking = model(update: .checking(manual: true))
    check(checking.banner == nil && checking.row(.checkForUpdates)?.title == "Checking for Updates\u{2026}" && checking.row(.checkForUpdates)?.isEnabled == false,
          "checking: no update row, Check for updates reads Checking and is disabled")
    let available = model(update: .available(released))
    check(available.banner?.title == "Cornermark 0.3.0" && available.banner?.detail == "Ready to install" && available.banner?.button == .action(.checkForUpdates),
          "available: an update row with the version and an Update button", detail: "\(String(describing: available.banner))")
    check(available.row(.checkForUpdates) == nil, "and Check for updates hides while it shows")
    check({ if case .update? = available.sections.first { return true } else { return false } }(), "the update row comes first")
    let installing = model(update: .installing(released))
    check(installing.banner?.detail == "Installing\u{2026}" && installing.banner?.button == nil && installing.row(.checkForUpdates) == nil,
          "installing: the row says so, has no button, and Check for updates stays hidden")
    check(!Set(installing.focusRows.joined()).contains(.action(.checkForUpdates)), "so nothing can press it")

    let pin1 = PinSummary(id: UUID(), title: "Pin 1 \u{2013} 800 \u{00D7} 600", isLocked: false)
    let pin2 = PinSummary(id: UUID(), title: "Pin 2 \u{2013} 400 \u{00D7} 300", isLocked: true)
    check(base.pinSection == nil, "no pins, no Pinned screenshots section")
    let one = model(pins: [pin1]).pinSection
    check(one?.header == "Pinned screenshots" && one?.pins.map(\.title) == [pin1.title] && one?.bulk.isEmpty == true, "one pin: its row, no Unlock all or Close all")
    let two = model(pins: [pin1, pin2]).pinSection
    check(two?.pins.map(\.isLocked) == [false, true] && two?.bulk.map(\.title) == ["Unlock all", "Close all"], "two pins: both rows, and Unlock all and Close all")
    let pinned = Set(model(pins: [pin1, pin2]).allItems)
    check([PanelItem.togglePinLock(pin1.id), .closePin(pin1.id), .togglePinLock(pin2.id), .closePin(pin2.id), .unlockAllPins, .closeAllPins].allSatisfy(pinned.contains),
          "each pin can be locked and closed, and all of them at once")

    check(base.sections.last.map { if case .footer = $0 { return true } else { return false } } == true, "the footer closes the panel")
    let symbols = ActionTable.specs.map(\.symbol) + ["eye", "lock.fill", "lock.open", "xmark", "pin", "arrow.down.circle"]
    check(symbols.allSatisfy { NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil }, "every symbol exists on this system",
          detail: "\(symbols.filter { NSImage(systemSymbolName: $0, accessibilityDescription: nil) == nil })")

    let w = try World(after: [.showOverlay])
    defer { w.cleanup() }
    let seeded = seedHistory(w)
    let live = panelModel(w)
    let newest = seeded.sorted { $0.createdAt > $1.createdAt }.prefix(3).map(\.id)
    check(live.recents.map(\.record.id) == Array(newest), "the live panel lists the store's three newest captures", detail: "\(live.recents.count)")
    let card = addCard(w, "gone")
    check(panelModel(w).row(.restoreOverlay)?.isEnabled == false, "a card that is still open is not restorable")
    w.coordinator.overlay.close(card)
    check(panelModel(w).row(.restoreOverlay)?.isEnabled == true, "a closed card can be restored")
    w.coordinator.overlay.toggleHidden()
    check(panelModel(w).row(.hideOverlays)?.title == "Show Overlays", "the live panel follows the overlays being hidden")
    w.coordinator.overlay.toggleHidden()
    let image = Pix.flat(200, 100, r: 0.2, g: 0.4, b: 0.6)
    let p1 = w.coordinator.pins.pin(image), p2 = w.coordinator.pins.pin(image)
    p2.setLocked(true)
    let livePins = panelModel(w).pinSection
    check(livePins?.pins.map(\.id) == [p1.id, p2.id] && livePins?.pins.map(\.isLocked) == [false, true]
          && livePins?.pins.first?.title == "Pin 1 \u{2013} 200 \u{00D7} 100", "the live panel lists the pins in order", detail: "\(String(describing: livePins?.pins.map(\.title)))")

    let (_, view) = panelView(w)
    check(pressMenu(.togglePinLock(p1.id), in: view), "the lock button of a pin exists")
    check(await waitUntil { p1.isLocked }, "pressing it locks the pin")
    check(pressMenu(.unlockAllPins, in: view), "Unlock all exists")
    check(await waitUntil { !w.coordinator.pins.hasLocked }, "and unlocks every pin")
    check(pressMenu(.closePin(p1.id), in: view), "the close button of a pin exists")
    check(await waitUntil { w.coordinator.pins.pins.count == 1 }, "and closes that pin only")
    p2.close()
    check(nothingOnScreen(), "building the panel ordered nothing on screen")
}

private extension PanelItem {
    var actionID: ActionID? { if case .action(let id) = self { return id } else { return nil } }
}

// MARK: Focus

@MainActor
private func checkMenuPanelFocus() async throws {
    section("menu panel: keyboard focus")
    let records = (0..<3).map { CaptureRecord(createdAt: Date(timeIntervalSince1970: Double($0)), kind: .area, pixelSize: CGSize(width: 10, height: 10), directoryName: "d\($0)") }
    let m = MenuPanelModel.make(settings: Settings(), update: .idle, overlaysHidden: false, canRestoreOverlay: false, pins: [], recent: records)
    let rows = m.focusRows
    func tile(_ id: ActionID) -> PanelItem { .action(id) }
    let all = tile(.history)
    let recent = m.recents.map(\.item)
    check(rows.map(\.count) == [4, 4, 1, 3, 1, 1, 1, 1, 1], "the layout is two grid rows, All, the recents, then one row each; disabled Restore is skipped",
          detail: "\(rows.map(\.count))")

    var f = MenuFocus(rows: rows)
    check(f.current == nil, "focus starts on nothing")
    f.move(.down)
    check(f.current == tile(.allInOne), "the first arrow goes to the first item")
    for dir: MenuFocus.Direction in [.up, .left, .right] {
        var g = MenuFocus(rows: rows)
        g.move(dir)
        check(g.current == tile(.allInOne), "so does the first \(dir)")
    }
    f.move(.right); f.move(.right)
    check(f.current == tile(.window), "right moves along the grid row")
    f.move(.right); f.move(.right)
    check(f.current == tile(.fullscreen), "and stops at its end")
    f.move(.down)
    check(f.current == tile(.timer), "down from a grid column goes to the same column of the next grid row")
    f.move(.right)
    check(f.current == tile(.timer), "right does nothing past the last column")
    f.move(.left); f.move(.left)
    check(f.current == tile(.scrolling), "left walks back along the second row", detail: "\(String(describing: f.current))")
    f.move(.left); f.move(.left)
    check(f.current == tile(.previousArea), "and stops at its start")
    f.move(.up)
    check(f.current == tile(.allInOne), "up goes to the same column of the row above", detail: "\(String(describing: f.current))")
    f.move(.down)
    check(f.current == tile(.previousArea), "and down comes back")
    f.move(.down)
    check(f.current == all, "down from the last grid row goes to the next section")
    f.move(.left); f.move(.right)
    check(f.current == all, "left and right do nothing on a row of one")
    f.move(.down)
    check(f.current == recent[0], "down enters the recents row")
    f.move(.right); f.move(.right); f.move(.right)
    check(f.current == recent[2], "right walks the recents and stops at the last")
    f.move(.left)
    check(f.current == recent[1], "left walks back")
    f.move(.up)
    check(f.current == all, "up from the recents goes to All")
    f.move(.down); f.move(.right); f.move(.right); f.move(.down)
    check(f.current == tile(.hideOverlays), "down from a thumbnail goes to the next row's only item, skipping the disabled one")
    f.move(.down); f.move(.down); f.move(.down); f.move(.down)
    check(f.current == tile(.quit), "down reaches the last row")
    f.move(.down)
    check(f.current == tile(.allInOne), "and wraps to the first")
    f.move(.up)
    check(f.current == tile(.quit), "up from the first wraps to the last")
    for _ in 0..<(rows.count) { f.move(.down) }
    check(f.current == tile(.quit), "a full lap returns to the start")

    var h = MenuFocus(rows: rows, current: recent[1])
    h.rebase(onto: Array(rows.dropFirst(3)))
    check(h.current == recent[1], "a rebuilt panel keeps the focus when the item remains")
    h.rebase(onto: Array(rows.dropFirst(4)))
    check(h.current == nil, "and drops it when the item is gone")
    var empty = MenuFocus(rows: [])
    empty.move(.down)
    check(empty.current == nil, "an empty panel has nothing to focus")

    let pins = [PinSummary(id: UUID(), title: "Pin 1", isLocked: false), PinSummary(id: UUID(), title: "Pin 2", isLocked: false)]
    let withPins = MenuPanelModel.make(settings: Settings(), update: .idle, overlaysHidden: false, canRestoreOverlay: true, pins: pins, recent: [])
    let items = Array(withPins.focusRows.joined())
    check(withPins.focusRows.allSatisfy { $0.count == 1 || withPins.tiles.map(\.item).contains($0[0]) }, "outside the grid and the recents every row is a single item")
    let at = items.firstIndex(of: .togglePinLock(pins[0].id))
    check(at != nil && items[at! + 1] == .closePin(pins[0].id) && items[at! + 2] == .togglePinLock(pins[1].id), "each pin's lock and close are two stops in order")
    check(items.contains(.unlockAllPins) && items.contains(.closeAllPins), "and the bulk rows are stops")
    let update = MenuPanelModel.make(settings: Settings(), update: .installing(AppRelease(version: AppVersion(0, 3, 0), notes: "", pageURL: URL(string: "https://example.com")!, dmgURL: nil)),
                                     overlaysHidden: false, canRestoreOverlay: false, pins: [], recent: [])
    check(update.focusRows.first == update.tiles.prefix(4).map(\.item), "an update row without a button is not a stop")
}

// MARK: Behaviour

@MainActor
private func checkMenuPanelBehaviour() async throws {
    section("menu panel: placement, opening, closing")
    let size = CGSize(width: 300, height: 420)
    var f = MenuPlacement.frame(size: size, button: buttonFrame, visible: screenFrame)
    check(f.maxX == buttonFrame.maxX && f.maxY == buttonFrame.minY - MenuPlacement.gap, "the panel sits under the button with its right edge level", detail: "\(f)")
    f = MenuPlacement.frame(size: size, button: CGRect(x: 1270, y: 775, width: 28, height: 25), visible: screenFrame)
    check(f.maxX <= screenFrame.maxX - MenuPlacement.margin, "near the right edge it stays on the display", detail: "\(f)")
    f = MenuPlacement.frame(size: size, button: CGRect(x: 4, y: 775, width: 28, height: 25), visible: screenFrame)
    check(f.minX >= MenuPlacement.margin, "near the left edge it stays on the display", detail: "\(f)")
    f = MenuPlacement.frame(size: CGSize(width: 300, height: 900), button: buttonFrame, visible: screenFrame)
    check(f.minY >= screenFrame.minY, "a panel taller than the display is not pushed below it", detail: "\(f)")
    let second = CGRect(x: 1280, y: 0, width: 1920, height: 1055)
    f = MenuPlacement.frame(size: size, button: CGRect(x: 2000, y: 1055, width: 28, height: 25), visible: second)
    check(second.contains(f) && f.maxX == 2028, "on a second display it follows that display", detail: "\(f)")

    let w = try World(after: [])
    defer { w.cleanup() }
    let c = w.coordinator
    let controller = MenuPanelController(coordinator: c)
    var events: [String] = []
    controller.onOpenChange = { events.append("open \($0)") }
    controller.run = { events.append("run \($0.identifier)") }
    let anchor = MenuAnchor(button: buttonFrame, visible: screenFrame)

    controller.toggle(anchor: anchor)
    let panel = controller.panel
    check(controller.isOpen && panel != nil, "toggling opens it")
    check(panel.map { w.presented.contains($0) } == true, "the environment is told about the window")
    check(panel?.isVisible == false && nothingOnScreen(), "an offscreen environment never orders the panel in")
    check(panel?.frame == MenuPlacement.frame(size: panel!.frame.size, button: buttonFrame, visible: screenFrame), "at the place computed for the button", detail: "\(String(describing: panel?.frame))")
    check((panel?.sharingType).map { $0 == .none } == true && panel?.level == .popUpMenu && panel?.canBecomeKey == true && panel?.canBecomeMain == false, "it hides from screen capture, sits with menus and takes keys")
    check(panel?.styleMask.contains(.nonactivatingPanel) == true && panel?.styleMask.contains(.borderless) == true && panel?.isOpaque == false && panel?.hasShadow == true,
          "it is a borderless non-activating panel with a system shadow")
    let behaviour = panel?.collectionBehavior ?? []
    check([.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle].allSatisfy(behaviour.contains), "it joins every Space and full screen apps")
    check(panel?.animationBehavior == NSWindow.AnimationBehavior.none, "it opens without animation")
    check(panel?.appearance == nil && panel?.backgroundColor == .clear, "it follows the system appearance")
    check(panel?.frame.width == 300, "it is 300 points wide", detail: "\(String(describing: panel?.frame.width))")

    controller.toggle(anchor: anchor)
    check(!controller.isOpen && controller.panel == nil, "toggling again closes it")
    check(events == ["open true", "open false"], "and reports both", detail: "\(events)")

    events = []
    controller.open(anchor: anchor)
    controller.activate(.action(.area))
    check(!controller.isOpen && events == ["open true", "open false"], "choosing an item closes the panel before it runs anything", detail: "\(events)")
    check(await waitUntil { events.count == 3 }, "then runs it on the next turn")
    check(events.last == "run menu.action.area", "and runs the one that was chosen", detail: "\(events)")

    events = []
    controller.open(anchor: anchor)
    let panelView = controller.panel!.contentView as! MenuPanelView
    check(pressMenu(.action(.timer), in: panelView), "a tile in the open panel can be pressed")
    check(!controller.isOpen && events == ["open true", "open false"], "pressing it closes the panel first", detail: "\(events)")
    check(await waitUntil { events.count == 3 } && events.last == "run menu.action.timer", "and then runs it", detail: "\(events)")

    events = []
    controller.open(anchor: anchor)
    Synth.key(controller.panel!, 53, "\u{1b}")
    check(!controller.isOpen && events == ["open true", "open false"], "Escape closes it without running anything", detail: "\(events)")
    try? await Task.sleep(nanoseconds: 50_000_000)
    check(events.count == 2, "and nothing runs later")

    controller.open(anchor: anchor)
    controller.open(anchor: anchor)
    controller.close()
    controller.close()
    check(!controller.isOpen, "opening and closing twice is harmless")

    let real = MenuPanelController(coordinator: c)
    real.open(anchor: anchor)
    real.activate(.action(.history))
    check(await waitUntil { c.history != nil } && w.presented.contains { $0 === c.history?.window }, "choosing All opens the history window")
    real.open(anchor: anchor)
    real.activate(.action(.fullscreen))
    check(await waitUntil { w.store.list().count == 1 }, "choosing Screen reaches the capture store")
    real.open(anchor: anchor)
    real.activate(.action(.quit))
    check(await waitUntil { w.quits == 1 }, "choosing Quit calls the injected quit")

    let live = MenuPanelController(coordinator: c)
    live.open(anchor: anchor)
    let before = live.panel!.frame
    let release = AppRelease(version: AppVersion(0, 3, 0), notes: "", pageURL: URL(string: "https://example.com")!, dmgURL: URL(string: "https://example.com/Cornermark.dmg"))
    w.updateService.latest = .success(release)
    await c.updates.checkAutomatically()
    live.refresh()
    let after = live.panel!.frame
    check((live.panel?.contentView as? MenuPanelView)?.model.banner != nil, "an update arriving while it is open adds the update row")
    check(after.height > before.height && after.maxX == before.maxX && after.maxY == before.maxY, "the panel grows downward from the same corner", detail: "\(before) -> \(after)")
    live.close()
    check(nothingOnScreen(), "nothing of this was ever visible")
}

// MARK: Views

@MainActor
private func checkMenuPanelViews() async throws {
    section("menu panel: views, keys, accessibility")
    let w = try World(after: [.showOverlay])
    defer { w.cleanup() }
    let c = w.coordinator
    let seeded = seedHistory(w)
    var activated: [PanelItem] = []
    var closed = 0
    let controller = MenuPanelController(coordinator: c)
    var host = controller.host
    host.activate = { activated.append($0) }
    host.close = { closed += 1 }
    let image = Pix.flat(200, 100, r: 0.2, g: 0.4, b: 0.6)
    let p1 = c.pins.pin(image), p2 = c.pins.pin(image)
    p2.setLocked(true)
    _ = addCard(w, "closed")
    c.overlay.close(c.overlay.stack[0])
    let release = AppRelease(version: AppVersion(0, 3, 0), notes: "", pageURL: URL(string: "https://example.com")!, dmgURL: URL(string: "https://example.com/Cornermark.dmg"))
    w.updateService.latest = .success(release)
    await c.updates.checkAutomatically()

    let view = MenuPanelView(model: controller.currentModel(), host: host)
    _ = hostOffscreen(view, size: view.frame.size)
    view.layoutSubtreeIfNeeded()
    let model = view.model
    check(view.frame.width == 300 && view.frame.height > 0, "the panel is 300 wide", detail: "\(view.frame)")

    let tileViews = model.tiles.compactMap { view.part(for: $0.item) as? MenuTileView }
    check(tileViews.count == 8, "eight tiles are drawn")
    let frames = tileViews.map(\.frame)
    check(Set(frames.map(\.width)).count == 1 && Set(frames.map(\.height)).count == 1, "tiles share one size")
    check(Set(frames[0..<4].map(\.minY)).count == 1 && Set(frames[4..<8].map(\.minY)).count == 1, "each grid row shares one top")
    check((0..<4).allSatisfy { frames[$0].minX == frames[$0 + 4].minX }, "the two rows share their columns")
    check(zip(frames[0..<3], frames[1..<4]).allSatisfy { $1.minX - $0.maxX == MenuMetrics.tileGap }, "columns are an even gap apart")
    check(frames[0].minX == MenuMetrics.padding && frames[3].maxX == MenuMetrics.width - MenuMetrics.padding, "the grid fills the panel's inner width")
    check(frames.allSatisfy { $0.width == $0.width.rounded() }, "tiles land on whole points", detail: "\(frames[0].width)")
    check(tileViews.allSatisfy { tile in textFits(tile.tile.title, DS.Text.caption, in: tile.bounds.width - 8) && (tile.tile.shortcut.map { textFits($0, DS.Text.readout, in: tile.bounds.width - 8) } ?? true) },
          "tile titles and shortcuts fit their tile")

    let rowViews = (model.overlayRows + model.footerRows).compactMap { view.part(for: $0.item) as? MenuRowView }
    let textX = MenuMetrics.rowInset + DS.Size.icon + MenuMetrics.rowGap
    check(rowViews.count == model.overlayRows.count + model.footerRows.count, "every row is drawn")
    check(rowViews.allSatisfy { textFits($0.row.title, DS.Text.body, in: $0.bounds.width - textX - MenuMetrics.rowInset) }, "row titles fit")
    check(rowViews.allSatisfy { $0.frame.minX == MenuMetrics.padding && $0.frame.width == MenuMetrics.innerWidth && $0.frame.height == MenuMetrics.rowHeight }, "rows span the inner width")
    let allFrames = (frames + rowViews.map(\.frame))
    check(allFrames.allSatisfy { view.bounds.insetBy(dx: MenuMetrics.padding, dy: MenuMetrics.padding).contains($0) }, "nothing leaves the panel's padding")
    let thumbs = model.recents.compactMap { view.part(for: $0.item) as? MenuThumbView }
    check(thumbs.count == 3 && Set(thumbs.map(\.frame.width)).count == 1 && Set(thumbs.map(\.frame.height)).count == 1 && thumbs.last!.frame.maxX <= view.bounds.width - MenuMetrics.padding, "three equal thumbnails fit in the row")

    check(view.model.banner != nil, "the update row is drawn")
    let primaries = Controls.buttons(in: view).filter { $0.variant == .primary }
    check(primaries.count == 1 && primaries[0].title == "Update", "the Update button is the one accent in the panel", detail: "\(primaries.map(\.title))")
    check(primaries.first?.accessibilityLabel() == "Update to Cornermark 0.3.0", "and says which version it installs")
    check(pressMenu(.action(.checkForUpdates), in: view) && activated == [.action(.checkForUpdates)], "pressing Update runs the update action")
    activated = []

    for pinRow in view.subviews.compactMap({ $0 as? MenuPinRowView }) {
        let textStart = MenuMetrics.rowInset + DS.Size.icon + MenuMetrics.rowGap
        check(textFits(pinRow.pin.title, DS.Text.body, in: pinRow.lock.frame.minX - textStart - DS.Space.s4), "\(pinRow.pin.title) fits beside its buttons")
        check(pinRow.close.frame.maxX <= pinRow.bounds.width && pinRow.lock.frame.maxX < pinRow.close.frame.minX, "and the buttons sit inside the row")
    }
    check(pressMenu(.togglePinLock(p1.id), in: view) && pressMenu(.closePin(p2.id), in: view) && pressMenu(.closeAllPins, in: view),
          "lock, close and Close all are buttons in the row")
    check(activated == [.togglePinLock(p1.id), .closePin(p2.id), .closeAllPins], "and report themselves", detail: "\(activated)")
    activated = []
    check((view.part(for: .togglePinLock(p2.id)) as? IconButton)?.symbol == "lock.fill" && (view.part(for: .togglePinLock(p1.id)) as? IconButton)?.symbol == "lock.open",
          "a locked pin shows a closed lock")
    check((view.part(for: .togglePinLock(p2.id)) as? IconButton)?.accessibilityLabel()?.hasPrefix("Unlock Pin 2") == true, "and offers to unlock it")

    check(view.focusRingFrame == nil, "no ring until a key is pressed")
    check(!key(kVK_ANSI_A, in: view) && !key(kVK_Tab, in: view), "other keys are not the panel's")
    _ = key(kVK_Return, in: view)
    check(activated.isEmpty, "Return with nothing focused does nothing")
    check(key(kVK_DownArrow, in: view) && view.focus.current == .action(.checkForUpdates), "the first arrow focuses the first item, the Update button")
    check(view.focusRingFrame != nil, "and shows the ring")
    if let ring = view.focusRingFrame, let target = view.part(for: .action(.checkForUpdates)) {
        let expected = view.convert(target.bounds, from: target).insetBy(dx: -2, dy: -2)
        check(ring == expected, "around that item", detail: "\(ring) vs \(expected)")
    }
    _ = key(kVK_DownArrow, in: view)
    check(view.focus.current == .action(.allInOne), "down goes to the grid")
    _ = key(kVK_RightArrow, in: view)
    check(view.focus.current == .action(.area), "right goes along it")
    _ = key(kVK_Return, in: view)
    check(activated == [.action(.area)], "Return presses it")
    _ = key(kVK_Space, in: view)
    check(activated == [.action(.area), .action(.area)], "so does Space")
    _ = key(kVK_Escape, in: view)
    check(closed == 1, "Escape asks to close")
    activated = []

    let buttons = view.targets.values.compactMap { $0 as? MenuPressableView }
    check(buttons.allSatisfy { $0.accessibilityRole() == .button && !($0.accessibilityLabel() ?? "").isEmpty && $0.isAccessibilityElement() }, "tiles, rows and thumbnails are accessibility buttons with labels")
    check((view.part(for: .action(.area)) as? MenuTileView)?.accessibilityLabel() == "Capture Area, Control Shift 2", "a tile's label has the long title and the spoken shortcut")
    check((view.part(for: .action(.restoreOverlay)) as? MenuRowView)?.isAccessibilityEnabled() == true, "Restore is enabled once something was closed")
    check(thumbs.allSatisfy { $0.accessibilityLabel()?.contains("capture,") == true }, "thumbnails are labelled with their capture date", detail: "\(thumbs.map { $0.accessibilityLabel() ?? "nil" })")

    check(thumbs.allSatisfy { $0.image == nil } || c.thumbnails.generationsOffMainThread > 0, "a thumbnail starts as a placeholder until it is decoded")
    check(await waitUntil { thumbs.allSatisfy { $0.image != nil } }, "then every thumbnail fills in")
    check(c.thumbnails.generationsOnMainThread == 0, "no thumbnail was decoded on the main thread")
    _ = seeded

    let real = MenuPanelView(model: controller.currentModel(), host: controller.host)
    let newest = real.model.recents[0].record
    pressMenu(.recent(newest.id), in: real)
    check(await waitUntil { c.editors[newest.id] != nil }, "pressing a thumbnail opens that capture in the editor")

    c.pins.closeAll()
    check(nothingOnScreen(), "no view ordered anything on screen")
}

private enum Controls {
    @MainActor
    static func buttons(in view: NSView) -> [CornermarkDesign.Button] {
        view.subviews.flatMap { sub -> [CornermarkDesign.Button] in
            (sub as? CornermarkDesign.Button).map { [$0] } ?? buttons(in: sub)
        }
    }
}

// MARK: Snapshots

@MainActor
private func checkMenuPanelSnapshots() async throws {
    section("menu panel: snapshots")
    let w = try World(after: [.showOverlay])
    defer { w.cleanup() }
    let c = w.coordinator
    _ = seedHistory(w)
    let controller = MenuPanelController(coordinator: c)

    func render(_ name: String, lightName: String? = nil, hover: PanelItem? = nil, focus: [MenuFocus.Direction] = []) async {
        let view = MenuPanelView(model: controller.currentModel(), host: controller.host)
        let window = hostOffscreen(view, size: view.frame.size)
        let thumbs = view.model.recents.compactMap { view.part(for: $0.item) as? MenuThumbView }
        _ = await waitUntil { thumbs.allSatisfy { $0.image != nil } }
        focus.forEach(view.move)
        if let hover, let part = view.part(for: hover) { part.mouseEntered(with: Synth.enterExit(.mouseEntered, in: window)) }
        let urls = [snapshot(view, name: lightName ?? name + "-light"), snapshot(view, name: name + "-dark", dark: true)]
        check(urls.allSatisfy { $0 != nil }, "\(name) snapshots written (light, dark)")
    }

    await render("menu", lightName: "menu-light")
    await render("menu-hover", hover: .action(.settings))
    await render("menu-focus", focus: [.down, .right])
    await render("menu-hover-tile", hover: .action(.area))

    let release = AppRelease(version: AppVersion(0, 3, 0), notes: "", pageURL: URL(string: "https://example.com")!, dmgURL: URL(string: "https://example.com/Cornermark.dmg"))
    w.updateService.latest = .success(release)
    await c.updates.checkAutomatically()
    await render("menu-update", lightName: "menu-update")

    let image = Pix.flat(800, 600, r: 0.2, g: 0.4, b: 0.6)
    let p1 = c.pins.pin(image), p2 = c.pins.pin(Pix.flat(400, 300, r: 0.5, g: 0.3, b: 0.2))
    p2.setLocked(true)
    c.overlay.toggleHidden()
    await render("menu-full", hover: .closePin(p1.id))
    c.pins.closeAll()
    check(nothingOnScreen(), "snapshots ordered nothing on screen")
}
