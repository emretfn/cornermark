import AppKit
import CornermarkCapture
import CornermarkCore
import CornermarkDesign
import CornermarkL10n
@testable import CornermarkShell

// Each window the shell owns is opened, switched to a pseudo right-to-left language that wraps every translated string in ‹ ›,
// and walked. A string left hard-coded, or a window that did not draw itself again, shows up as text without the marks.

@MainActor
private func pseudoArabic() { L10n.setPseudoLanguage(.ar) { "\u{2039}\($0)\u{203A}" } }

@MainActor
private func english() { L10n.setLanguage(.en) }

private func isWrapped(_ s: String) -> Bool { s.hasPrefix("\u{2039}") && s.hasSuffix("\u{203A}") }

private func isChromeText(_ s: String, userContent: Set<String>) -> Bool {
    // Numbers, times and symbols carry no words, and a name or a brand is not translated.
    s.contains { $0.isLetter } && s != "Cornermark" && !userContent.contains(s) && !userContent.contains { s.contains($0) }
}

/// Every string a person reads in `root`: text fields, button titles, tooltips, segment labels, and the accessibility labels the shell's own
/// views set. Hidden views are skipped.
@MainActor
private func shownStrings(_ root: NSView?, userContent: Set<String> = []) -> [String] {
    guard let root else { return [] }
    var out: [String] = []
    func add(_ s: String?) { if let s, !s.isEmpty { out.append(s) } }
    func walk(_ v: NSView) {
        if v.isHidden { return }
        if let f = v as? NSTextField, !f.isEditable { add(f.stringValue) }
        if let b = v as? NSButton, !(b is NSPopUpButton), !(b is IconButton) { add(b.title) }
        if let s = v as? NSSegmentedControl {
            for i in 0..<s.segmentCount { add(s.label(forSegment: i)); add(s.toolTip(forSegment: i)) }
        }
        add(v.toolTip)
        if v.isAccessibilityElement(), String(reflecting: type(of: v)).hasPrefix("Cornermark") { add(v.accessibilityLabel()) }
        v.subviews.forEach(walk)
    }
    walk(root)
    return out.filter { isChromeText($0, userContent: userContent) }
}

@MainActor
private func menuStrings(_ menu: NSMenu?) -> [String] {
    guard let menu else { return [] }
    return menu.items.filter { !$0.isSeparatorItem }.flatMap { [$0.submenu == nil ? $0.title : ""] + menuStrings($0.submenu) + [$0.submenu?.title ?? ""] }.filter { $0.contains { $0.isLetter } }
}

private func unwrapped(_ strings: [String]) -> [String] { strings.filter { !isWrapped($0) } }

@MainActor
private func keepsLeftToRight(in root: NSView?) -> [NSView] {
    guard let root else { return [] }
    return (root is KeepsLeftToRight ? [root] : []) + root.subviews.flatMap { keepsLeftToRight(in: $0) }
}

@MainActor
func checkLocalizedWindows() async throws {
    defer { english() }
    try await checkLocalizedHistory()
    try await checkLocalizedMenuPanel()
    try await checkLocalizedCards()
    try await checkLocalizedPermission()
    try await checkLocalizedWhatsNew()
    try await checkLocalizedRecording()
    try await checkLocalizedCamera()
    try await checkLocalizedTexts()
}

// MARK: History

@MainActor
private func checkLocalizedHistory() async throws {
    section("localization: history window")
    let w = try World(after: [.showOverlay])
    defer { w.cleanup() }
    let c = w.coordinator
    _ = seedHistory(w)
    c.perform(.openHistory)
    guard let h = c.history, let window = h.window, let content = window.contentView else { return check(false, "the history window opens") }
    window.setContentSize(NSSize(width: 920, height: 420))
    content.layoutSubtreeIfNeeded()
    h.setFilter(.all)
    h.collectionView.layoutSubtreeIfNeeded()
    guard let scroll = h.collectionView.enclosingScrollView else { return check(false, "the history grid scrolls") }
    let picked = Array(h.records[1...2]).map(\.id)
    h.select(recordIDs: picked)
    scroll.contentView.scroll(to: NSPoint(x: 0, y: 60))
    scroll.reflectScrolledClipView(scroll.contentView)
    let frame = window.frame
    let inEnglish = shownStrings(content)

    pseudoArabic()
    window.contentView?.layoutSubtreeIfNeeded()
    h.collectionView.layoutSubtreeIfNeeded()
    let root = window.contentView
    let shown = shownStrings(root) + menuStrings(h.collectionView.menu) + [window.title]
    check(shown.count > 15 && unwrapped(shown).isEmpty, "history window re-renders in the new language", detail: "\(unwrapped(shown))")
    check(h.selectedRecords.map(\.id).sorted { $0.uuidString < $1.uuidString } == picked.sorted { $0.uuidString < $1.uuidString }
          && scroll.contentView.bounds.origin.y == 60 && window.frame == frame && h.filter == .all,
          "history window keeps its selection, scroll position, filter and frame when the language changes",
          detail: "\(h.selectedRecords.count) \(scroll.contentView.bounds.origin) \(window.frame) was \(frame)")
    check(root?.userInterfaceLayoutDirection == .rightToLeft && h.collectionView.userInterfaceLayoutDirection == .rightToLeft,
          "history window mirrors for a right-to-left language")
    let items = h.collectionView.visibleItems().map(\.view)
    check(!items.isEmpty && items.allSatisfy { $0 is KeepsLeftToRight && $0.userInterfaceLayoutDirection == .leftToRight },
          "history thumbnails stay left to right in a mirrored window")
    let filter = findView("history.filter", in: root) as? NSSegmentedControl
    let copy = findView("history.copy", in: root), delete = findView("history.delete", in: root)
    if let copy, let delete, let root {
        let a = copy.convert(copy.bounds, to: root), b = delete.convert(delete.bounds, to: root)
        check(a.minX > b.minX, "history action buttons run from the right edge, with Delete at the far left", detail: "\(a) \(b)")
    }
    if let filter, let root {
        check(filter.convert(filter.bounds, to: root).midX > root.bounds.midX, "history filters sit at the right in a right-to-left language")
    }

    english()
    window.contentView?.layoutSubtreeIfNeeded()
    h.collectionView.layoutSubtreeIfNeeded()
    let headings: Set<String> = ["Today", "Yesterday", "Previous 7 Days", "Earlier"]
    let back = shownStrings(window.contentView)
    check(!back.contains(where: isWrapped) && Set(back).subtracting(headings) == Set(inEnglish).subtracting(headings) && window.title == "Capture History"
          && window.contentView?.userInterfaceLayoutDirection == .leftToRight,
          "history window returns to English and left to right", detail: "\(Set(back).symmetricDifference(Set(inEnglish)))")
    check(h.selectedRecords.map(\.id).sorted { $0.uuidString < $1.uuidString } == picked.sorted { $0.uuidString < $1.uuidString }
          && scroll.contentView.bounds.origin.y == 60, "and still keeps the selection and the scroll position")
}

// MARK: Menu panel

@MainActor
private func checkLocalizedMenuPanel() async throws {
    section("localization: menu panel")
    let w = try World(after: [.showOverlay])
    defer { w.cleanup() }
    let c = w.coordinator
    _ = seedHistory(w)
    let image = Pix.flat(300, 200, r: 0.3, g: 0.5, b: 0.7)
    c.pins.pin(image)
    c.pins.pin(image)
    let controller = MenuPanelController(coordinator: c)
    let anchor = MenuAnchor(button: CGRect(x: 1100, y: 775, width: 28, height: 25), visible: CGRect(x: 0, y: 0, width: 1280, height: 775))
    controller.open(anchor: anchor)
    defer { controller.close() }
    guard let before = controller.panel?.contentView as? MenuPanelView else { return check(false, "the menu panel opens") }
    before.move(.down)
    let focused = before.focus.current
    let frame = controller.panel?.frame

    pseudoArabic()
    guard let view = controller.panel?.contentView as? MenuPanelView else { return check(false, "the open panel is still there") }
    let shown = shownStrings(view)
    check(shown.count > 20 && unwrapped(shown).isEmpty, "menu panel re-renders in the new language while it is open", detail: "\(unwrapped(shown))")
    check(view.focus.current == focused && focused != nil && controller.isOpen, "menu panel keeps its keyboard focus when the language changes")
    check(view.userInterfaceLayoutDirection == .rightToLeft, "menu panel mirrors for a right-to-left language")
    let first = view.part(for: .action(.allInOne)), second = view.part(for: .action(.area))
    check((first?.frame.minX ?? 0) > (second?.frame.minX ?? .infinity), "capture tiles fill from the right edge",
          detail: "\(String(describing: first?.frame)) \(String(describing: second?.frame))")
    let thumbs = view.model.recents.compactMap { view.part(for: $0.item) }
    check(!thumbs.isEmpty && thumbs.allSatisfy { $0 is KeepsLeftToRight && $0.userInterfaceLayoutDirection == .leftToRight },
          "menu panel thumbnails stay left to right in a mirrored panel")
    let row = view.part(for: .action(.settings))
    check(row.map { $0.convert($0.bounds, to: view).width } == MenuMetrics.innerWidth && (controller.panel?.frame.size).map { $0 == view.frame.size } == true,
          "menu panel keeps its width in every language")
    if let frame { check(controller.panel?.frame.maxX == frame.maxX, "and stays under the status button", detail: "\(frame) \(String(describing: controller.panel?.frame))") }

    english()
    guard let again = controller.panel?.contentView as? MenuPanelView else { return check(false, "the panel is still there in English") }
    check(!shownStrings(again).isEmpty && !shownStrings(again).contains(where: isWrapped)
          && again.userInterfaceLayoutDirection == .leftToRight && again.focus.current == focused,
          "menu panel returns to English and left to right, keeping its focus")
    controller.close()
}

// MARK: Quick Access cards and pins

@MainActor
private func checkLocalizedCards() async throws {
    section("localization: Quick Access cards and pins")
    let w = try World(after: [.showOverlay])
    defer { w.cleanup() }
    let c = w.coordinator
    let picture = Pix.fixtureDisplay().image.cropping(to: CGRect(x: 80, y: 80, width: 740, height: 260))!
    c.handleCaptured(.init(image: picture, kind: .area, pointScale: 1))
    c.handleCaptured(.init(image: picture, kind: .window, pointScale: 1))
    guard c.overlay.stack.count == 2, let top = c.overlay.cardView(for: c.overlay.stack[0]) else { return check(false, "two cards are stacked") }
    let ids = c.overlay.stack.map(\.id)
    top.setHovering(true)
    let pin = c.pins.pin(picture, pointScale: 2)
    (pin.window.contentView as? PinContentView)?.setHovering(true)
    pin.opacity = 0.5
    pin.zoom(by: 1.5)
    let pinFrame = pin.window.frame

    pseudoArabic()
    let cardStrings = shownStrings(top)
    check(cardStrings.count >= 6 && unwrapped(cardStrings).isEmpty, "Quick Access card re-renders in the new language", detail: "\(unwrapped(cardStrings))")
    check(c.overlay.stack.map(\.id) == ids && top.isHovering && c.overlay.cardView(for: c.overlay.stack[0]) === top,
          "the card queue and each card's state survive a language change")
    check(top.userInterfaceLayoutDirection == .rightToLeft, "Quick Access card mirrors for a right-to-left language")
    top.layoutSubtreeIfNeeded()
    if let close = top.buttons[.close], let pinButton = top.buttons[.pin] {
        check(close.frame.minX > pinButton.frame.minX, "the close button moves to the corner the language starts from", detail: "\(close.frame) \(pinButton.frame)")
    }

    let pinStrings = shownStrings(pin.window.contentView) + menuStrings(pin.makeMenu()) + [pin.window.title]
    check(pinStrings.count >= 8 && unwrapped(pinStrings).isEmpty, "a pinned screenshot's title, close button and menu follow the language", detail: "\(pinStrings)")
    check(pin.window.frame == pinFrame && abs(pin.opacity - 0.5) < 0.001, "a pin keeps its size, place and opacity when the language changes")
    check(pin.window.contentView is KeepsLeftToRight && pin.window.contentView?.userInterfaceLayoutDirection == .leftToRight,
          "a pinned screenshot's picture is never mirrored")
    let model = MenuPanelController(coordinator: c).currentModel()
    check(model.pinSection.map { unwrapped($0.pins.map(\.title)).isEmpty } == true, "pin rows in the menu name themselves in the new language")

    english()
    check(!shownStrings(top).isEmpty && !shownStrings(top).contains(where: isWrapped) && pin.window.title == "Pinned screenshot"
          && top.userInterfaceLayoutDirection == .leftToRight, "cards and pins return to English and left to right")
    pin.close()
    c.overlay.closeAll()
}

// MARK: Permission window

@MainActor
private func checkLocalizedPermission() async throws {
    section("localization: permission window")
    let w = try World(after: [])
    defer { w.cleanup() }
    let c = w.coordinator
    w.permission = false
    c.perform(.capture(.fullscreen))
    guard let controller = c.permissionWindow, let window = controller.window else { return check(false, "the permission window opens") }
    let before = window.frame
    let englishSteps = PermissionWindowController.steps
    check(englishSteps.count == 3 && englishSteps[0].hasPrefix("Open System Settings"), "the permission steps are English by default")

    pseudoArabic()
    let shown = shownStrings(window.contentView) + [window.title]
    check(shown.count >= 7 && unwrapped(shown).isEmpty, "permission window re-renders in the new language", detail: "\(unwrapped(shown))")
    check(PermissionWindowController.steps.allSatisfy(isWrapped) && window.frame.minX == before.minX && abs(window.frame.maxY - before.maxY) < 0.5
          && window.frame.width == before.width, "permission window keeps its place when its text changes", detail: "\(before) \(window.frame)")
    check(window.contentView?.userInterfaceLayoutDirection == .rightToLeft, "permission window mirrors for a right-to-left language")
    let open = findView("permission.open", in: window.contentView), quit = findView("permission.quit", in: window.contentView)
    if let open, let quit, let root = window.contentView {
        check(open.convert(open.bounds, to: root).minX < quit.convert(quit.bounds, to: root).minX, "its buttons run from the right edge", detail: "\(open.frame) \(quit.frame)")
    }

    english()
    check(!shownStrings(window.contentView).isEmpty && !shownStrings(window.contentView).contains(where: isWrapped) && PermissionWindowController.steps == englishSteps
          && window.contentView?.userInterfaceLayoutDirection == .leftToRight && window.title == "Screen Recording Permission",
          "permission window returns to English and left to right")
}

// MARK: What's New

@MainActor
private func checkLocalizedWhatsNew() async throws {
    section("localization: what's new")
    let w = try World(after: [])
    defer { w.cleanup() }
    let c = w.coordinator
    let notes = (1...12).map { "* **editor:** Change number \($0) of the long release" }.joined(separator: "\n")
    let body = "### Features\n\(notes)\n\n### Bug Fixes\n* Fixed one"
    let published = Date(timeIntervalSince1970: 1_793_700_000)
    func entry(_ v: AppVersion) -> ReleaseEntry { ReleaseEntry(version: v, publishedAt: published, notes: ReleaseNotes(markdown: body)) }
    w.updateService.history = .success([entry(AppVersion(0, 2, 1)), entry(AppVersion(0, 2, 0)), entry(AppVersion(0, 1, 0))])
    c.perform(.whatsNew)
    guard let controller = c.whatsNewWindow, let window = controller.window else { return check(false, "the What's New window opens") }
    check(await waitUntil { controller.content != .loading }, "release notes load")
    window.setContentSize(NSSize(width: 480, height: 300))
    window.contentView?.layoutSubtreeIfNeeded()
    guard let scroll = window.contentView?.subviews.compactMap({ $0 as? NSScrollView }).first else { return check(false, "the notes scroll") }
    scroll.contentView.scroll(to: NSPoint(x: 0, y: 120))
    scroll.reflectScrolledClipView(scroll.contentView)
    let frame = window.frame
    let released = Set((1...12).map { "Change number \($0) of the long release" } + ["Fixed one"])
    let englishDate = published.formatted(Date.FormatStyle(date: .long, time: .omitted).locale(L10n.locale))

    pseudoArabic()
    window.contentView?.layoutSubtreeIfNeeded()
    let localDate = published.formatted(Date.FormatStyle(date: .long, time: .omitted).locale(L10n.locale))
    let shown = shownStrings(window.contentView, userContent: released.union([localDate])) + [window.title]
    check(shown.count >= 9 && unwrapped(shown).isEmpty, "what's new re-renders in the new language, and leaves the release notes as published", detail: "\(unwrapped(shown))")
    check(shownStrings(window.contentView, userContent: [localDate]).contains { text in released.contains { text.contains($0) } && !isWrapped(text) },
          "the release's own text is not translated")
    check(scroll.contentView.bounds.origin.y == 120 && window.frame == frame && controller.content != .loading,
          "what's new keeps its scroll position and frame when the language changes", detail: "\(scroll.contentView.bounds.origin)")
    check(window.contentView?.userInterfaceLayoutDirection == .rightToLeft, "what's new mirrors for a right-to-left language")
    func firstField(_ v: NSView, _ prefix: String) -> NSTextField? {
        if let f = v as? NSTextField, f.stringValue.hasPrefix(prefix) { return f }
        return v.subviews.lazy.compactMap { firstField($0, prefix) }.first
    }
    if let root = window.contentView, let version = firstField(root, "\u{2039}Version") {
        let box = version.convert(version.bounds, to: root)
        check(box.midX > root.bounds.midX, "version headings start at the right edge", detail: "\(box) in \(root.bounds)")
    } else { check(false, "a version heading is on screen") }
    check(collectText(window.contentView).contains(localDate) && localDate != englishDate, "dates are written in the language's own format", detail: "\(localDate) \(englishDate)")

    english()
    window.contentView?.layoutSubtreeIfNeeded()
    check(!shownStrings(window.contentView, userContent: released).contains(where: isWrapped) && window.title == "What's New"
          && collectText(window.contentView).contains("Version 0.2.1") && window.contentView?.userInterfaceLayoutDirection == .leftToRight
          && scroll.contentView.bounds.origin.y == 120, "what's new returns to English and left to right at the same place")
}

/// The bar's parts sit inside it, none over another, and the bar is as wide as its parts need, in whatever language it is in.
@MainActor
private func barLayoutIsConsistent(_ bar: RecordingBarView) -> Bool {
    bar.layoutSubtreeIfNeeded()
    let parts = [bar.stop, bar.microphone, bar.pause, bar.resume, bar.restart, bar.confirmRestart, bar.delete, bar.confirmDelete, bar.grip].filter { !$0.isHidden }
    guard abs(bar.frame.width - bar.fittingWidth) < 0.5, parts.allSatisfy({ bar.bounds.insetBy(dx: -0.5, dy: -0.5).contains($0.frame) }) else { return false }
    if !bar.microphone.isHidden, abs(bar.microphone.frame.width - MicrophoneSlotView.width) > 0.5 { return false }
    for (i, a) in parts.enumerated() { for b in parts[(i + 1)...] where a.frame.intersection(b.frame).width > 0.5 { return false } }
    return true
}

// MARK: Recording bar and countdown

@MainActor
private func checkLocalizedRecording() async throws {
    section("localization: recording controls")
    let m = try ManualRecordingWorld()
    let w = m.world, c = w.coordinator
    defer { w.cleanup() }
    check(m.link("record?display=1&x=100&y=80&width=400&height=300"), "an area link is accepted")
    check(await waitUntil { m.phase == .recording }, "the recording starts")
    guard let bar = c.controls.bar, let view = c.controls.barView else { return check(false, "the control bar exists") }
    try m.source?.advance(90)
    c.controls.update()
    let origin = bar.frame.origin, time = view.time.stringValue

    pseudoArabic()
    let shown = shownStrings(view) + [bar.title]
    check(shown.count >= 6 && unwrapped(shown).isEmpty, "recording bar re-renders in the new language", detail: "\(unwrapped(shown))")
    check(c.controls.barView === view && c.controls.bar === bar && m.phase == .recording && bar.frame.origin == origin
          && view.time.stringValue == time, "the recording and its bar carry on when the language changes", detail: "\(bar.frame.origin) \(view.time.stringValue)")
    check(view.stop.accessibilityLabel()?.hasPrefix("\u{2039}") == true && view.stop.toolTip == "\u{2039}Stop recording\u{203A}", "the stop button speaks the new language")
    check(view.userInterfaceLayoutDirection == .rightToLeft, "recording bar mirrors for a right-to-left language")
    let order = [view.stop, view.pause, view.restart, view.delete, view.grip].map { $0.frame.minX }
    check(order == order.sorted(by: >) && view.grip.frame.minX >= view.bounds.minX, "its buttons run from the right edge, with the grip at the far left", detail: "\(order)")
    check(barLayoutIsConsistent(view), "the bar's parts fit without overlapping in the new language")
    view.showsMicrophone = true
    check(barLayoutIsConsistent(view) && view.microphone.frame.width == MicrophoneSlotView.width, "and so do they with the microphone's slot, which is as wide as its words")
    view.showsMicrophone = false
    view.pause.performClick(nil)
    check(m.phase == .paused && view.resume.isHidden == false, "and it still works: Pause pauses")
    view.resume.performClick(nil)

    english()
    check(!shownStrings(view).contains(where: isWrapped) && view.stop.toolTip == "Stop recording"
          && bar.title == "Recording Controls" && view.userInterfaceLayoutDirection == .leftToRight, "recording bar returns to English and left to right")
    view.showsMicrophone = true
    check(barLayoutIsConsistent(view), "the bar and its microphone slot fit again in English")
    view.showsMicrophone = false
    _ = m.link("record/stop")
    check(await waitUntil { m.phase == .idle }, "the recording stops as usual")

    w.settings.update { $0.recording.countdown = 3 }
    c.recording.countdownTick = 2
    _ = m.link("record?display=1")
    check(await waitUntil { m.phase == .countingDown(3) }, "a countdown starts at 3")
    guard let countdown = c.controls.countdown else { return check(false, "the countdown panel exists") }
    pseudoArabic()
    check(isWrapped(countdown.title) && c.controls.countdownView?.remaining == 3 && c.controls.barView?.stop.toolTip == "\u{2039}Cancel recording\u{203A}",
          "the countdown keeps counting from 3 and its bar offers Cancel in the new language")
    english()
    _ = m.link("record/stop")
    check(await waitUntil { m.phase == .idle }, "stopping cancels the countdown")
}

// MARK: Camera bubble

@MainActor
private func checkLocalizedCamera() async throws {
    section("localization: camera bubble")
    let m = try ManualRecordingWorld()
    let w = m.world, c = w.coordinator
    defer { w.cleanup() }
    w.env.cameraAccess = { .allowed }
    w.env.cameraSource = { ScriptedCameraSource(pacing: .manual(origin: recordingClockNow())) }
    w.settings.update { $0.recording.camera = CameraBubble(isVisible: true) }
    _ = m.link("record?display=1&x=0&y=0&width=640&height=360")
    check(await waitUntil { m.phase == .recording }, "a recording with the camera starts")
    guard let bubble = c.controls.camera.view, let panel = c.controls.camera.panel else { return check(false, "the camera bubble shows") }
    let frame = panel.frame

    pseudoArabic()
    let words = [bubble.accessibilityLabel(), bubble.accessibilityHelp(), bubble.accessibilityValue() as? String, panel.title].compactMap { $0 }
    check(words.count == 4 && unwrapped(words).isEmpty, "camera bubble speaks the new language", detail: "\(words)")
    check(panel.frame == frame && c.controls.camera.view === bubble, "and stays where it is")
    check(bubble is KeepsLeftToRight && bubble.userInterfaceLayoutDirection == .leftToRight, "the camera's picture is never mirrored")
    bubble.layoutSubtreeIfNeeded()
    let badge = bubble.subviews.first { String(describing: type(of: $0)).hasSuffix("HintBadge") }
    check((badge?.frame.midX ?? .infinity) < bubble.bounds.midX, "its hint badge moves to the corner the language starts from", detail: "\(String(describing: badge?.frame)) \(bubble.bounds)")

    english()
    check(bubble.accessibilityLabel() == "Camera" && panel.title == "Recording Camera", "camera bubble returns to English")
    _ = m.link("record/stop")
    check(await waitUntil { m.phase == .idle }, "the recording stops as usual")
}

// MARK: Texts that are not in a window

@MainActor
private func checkLocalizedTexts() async throws {
    section("localization: menus, messages and numbers")
    let w = try World(after: [])
    defer { w.cleanup() }
    let c = w.coordinator

    pseudoArabic()
    let menu = MainMenu.make(openVideo: #selector(NSObject.copy), target: NSObject())
    let menuTitles = menuStrings(menu).filter { $0.contains { $0.isLetter } }
    check(menuTitles.count >= 15 && unwrapped(menuTitles).isEmpty, "the menu bar is built in the current language", detail: "\(unwrapped(menuTitles))")

    c.hud.show(tr("Cornermark is up to date"))
    check(c.hud.lastMessage == "\u{2039}Cornermark is up to date\u{203A}" && (c.hud.panel?.contentView as? HUDView)?.userInterfaceLayoutDirection == .rightToLeft,
          "HUD messages and their direction follow the language")
    w.updateService.currentVersion = AppVersion(0, 2, 1)
    w.updateService.latest = .success(nil)
    await c.updates.perform()
    check(isWrapped(c.hud.lastMessage ?? ""), "the update flow's messages follow the language", detail: c.hud.lastMessage ?? "nil")
    let release = AppRelease(version: AppVersion(0, 3, 0), notes: "", pageURL: URL(string: "https://example.com/r")!, dmgURL: nil)
    check(unwrapped([UpdateState.available(release).menuTitle, UpdateState.installing(release).menuTitle, UpdateState.idle.menuTitle,
                     UpdateError.network("x").message, UpdateError.cannotReplace(path: "/Apps").message]).isEmpty
          && UpdateState.available(release).menuTitle.contains("0.3.0"), "update titles and errors follow the language and keep the version")
    check(ActionTable.specs.filter { $0.hotKey != nil }.allSatisfy { isWrapped($0.title) && isWrapped($0.tileTitle) },
          "the action table's titles are read in the current language")
    check(isWrapped(ImageOutput.dimensionText(CGSize(width: 1920, height: 1080))), "image sizes are written through the language")

    let backend = FakeHotKeyBackend()
    let manager = HotKeyManager(backend: backend) { _ in }
    var dup = Settings()
    dup.customShortcuts["ocr"] = ActionTable.spec(.area).hotKey!
    manager.apply(dup)
    check(manager.failures[.ocr].map(isWrapped) == true, "a shortcut conflict is described in the current language")
    english()
    check(manager.failures[.ocr] == "Same shortcut as Capture Area", "and again in English when the language changes back", detail: "\(manager.failures)")
    let hotkey = HotKey(keyCode: 49, modifiers: HotKey.controlShift)
    check(hotkey.keyName == "Space" && hotkey.spokenString == "Control Shift Space", "shortcut names are English by default", detail: hotkey.spokenString)
    check(ImageOutput.durationText(7) == "0:07" && ImageOutput.durationText(3723) == "1:02:03" && ImageOutput.dimensionText(CGSize(width: 1920, height: 1080)) == "1920 \u{00D7} 1080",
          "times and sizes read the same in English as they always did")
    L10n.setLanguage(.fa)
    check(ImageOutput.durationText(7) == "\u{06F0}:\u{06F0}\u{06F7}", "times use the language's own digits", detail: ImageOutput.durationText(7))
    english()
}
