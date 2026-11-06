import AppKit
import CornermarkCapture
import CornermarkCore
import CornermarkDesign
import CornermarkL10n
import CornermarkVideoEditor
@testable import CornermarkShell

@MainActor
func checkLocalization() async throws {
    defer { L10n.setLanguage(.en) }
    try checkLanguageSetting()
    try checkLanguageAtLaunch()
    try await checkSettingsLanguageSwitch()
}

@MainActor
private func checkLanguageSetting() throws {
    section("Language setting")
    var s = Settings()
    check(s.interfaceLanguage(preferences: ["xx", "tr-TR"]) == .tr, "an unset language follows the first preferred language Cornermark speaks")
    check(s.interfaceLanguage(preferences: ["xx"]) == .en, "an unset language with no preferred language Cornermark speaks is English")
    s.language = .de
    check(s.interfaceLanguage(preferences: ["tr-TR"]) == .de, "a picked language wins over the preferred languages")
    let old = try JSONDecoder().decode(Settings.self, from: Data(#"{"playSound":false,"timerSeconds":7}"#.utf8))
    check(old.language == nil && old.timerSeconds == 7 && !old.playSound, "settings saved before the language setting existed decode with the language unset")
    let unknown = try JSONDecoder().decode(Settings.self, from: Data(#"{"language":"xx","timerSeconds":7}"#.utf8))
    check(unknown.language == nil && unknown.timerSeconds == 7, "an unknown saved language decodes as unset and keeps the rest")
    let saved = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(s))
    check(saved.language == .de, "a picked language survives a save and load")
}

@MainActor
private func checkLanguageAtLaunch() throws {
    section("Language at launch")
    func launch(settings json: String?, preferences: [String]) throws -> Language {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CornermarkHarness-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = MemoryDefaults()
        if let json { defaults.set(Data(json.utf8), forKey: SettingsStore.key) }
        let env = try AppEnvironment.isolated(root: root, defaults: defaults)
        env.preferredLanguages = { preferences }
        _ = AppCoordinator(env: env)
        return L10n.language
    }
    check(try launch(settings: #"{"language":"de"}"#, preferences: ["en"]) == .de, "a saved language is applied at launch")
    check(try launch(settings: nil, preferences: ["xx", "tr-TR"]) == .tr, "with no saved language, launch follows the preferred languages")
    check(try launch(settings: nil, preferences: ["en"]) == .en && !L10n.isRightToLeft, "and a launch that prefers English is back in English")
}

/// Every string a person can read in `view`: labels, button and menu item titles, tooltips and accessibility labels.
@MainActor
private func readableStrings(in view: NSView) -> [(text: String, view: NSView)] {
    guard !view.isHidden else { return [] }
    var out: [(String, NSView)] = []
    func add(_ s: String?) { if let s, !s.isEmpty { out.append((s, view)) } }
    if let field = view as? NSTextField { add(field.stringValue) }
    if let popup = view as? NSPopUpButton {
        for item in popup.itemArray where !item.isSeparatorItem { add(item.title) }
    } else if let button = view as? NSButton, !(button is IconButton) {
        add(button.title)
    }
    if let segments = view as? NSSegmentedControl {
        for i in 0..<segments.segmentCount { add(segments.label(forSegment: i)); add(segments.toolTip(forSegment: i)) }
    }
    add(view.toolTip)
    add(view.accessibilityLabel())
    return out + view.subviews.flatMap(readableStrings(in:))
}

@MainActor
private func allViews(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(allViews) }

@MainActor
private func rows(in view: NSView) -> [FormRow] { allViews(view).compactMap { $0 as? FormRow } }

@MainActor
private func checkSettingsLanguageSwitch() async throws {
    let w = try World()
    defer { w.cleanup() }
    let c = w.coordinator
    check(L10n.language == .en, "a harness world launches in English, because its environment prefers English", detail: L10n.language.rawValue)

    section("Settings: language popup")
    c.perform(.openSettings)
    let sw = c.settingsWindow!
    let win = sw.window!
    guard let popup = findView("general.language", in: sw.panes[0].view) as? NSPopUpButton else { return check(false, "General has a language popup") }
    check(popup.itemTitles.first == "System" && popup.item(at: 1)?.isSeparatorItem == true
          && Array(popup.itemTitles.dropFirst(2)) == Language.allCases.map(\.nativeName) && popup.indexOfSelectedItem == 0,
          "the language popup offers System, a separator, then every language by its own name, with System chosen")
    popup.selectItem(at: 2 + Language.allCases.firstIndex(of: .tr)!)
    fire(popup)
    check(c.settings.value.language == .tr && L10n.language == .tr, "picking Türkçe stores it and switches the interface to Turkish", detail: L10n.language.rawValue)
    let again = findView("general.language", in: sw.panes[0].view) as? NSPopUpButton
    check(again === popup && again?.titleOfSelectedItem == "Türkçe", "the rebuilt General pane keeps the same popup with Türkçe chosen", detail: again?.titleOfSelectedItem ?? "nil")
    popup.selectItem(at: 0)
    fire(popup)
    check(c.settings.value.language == nil && L10n.language == .en, "picking System clears it and follows the preferred language, English here", detail: L10n.language.rawValue)

    section("Settings: live language switch")
    let content = win.contentView!
    let scroll = findView("settings.scroll", in: content) as! NSScrollView
    let recording = sw.panes.first { $0 is RecordingPane }!
    sw.select(pane: recording)
    content.layoutSubtreeIfNeeded()
    scroll.contentView.scroll(to: NSPoint(x: 0, y: 400))
    scroll.reflectScrolledClipView(scroll.contentView)
    let offset = scroll.contentView.bounds.origin
    let sidebarItems = sw.panes.compactMap { findView("settings.sidebar.\($0.paneID)", in: content) as? SidebarItem }
    let englishTitles = sidebarItems.map(\.title)
    check(offset.y == 400 && sidebarItems.count == sw.panes.count, "the Recording pane is open and scrolled 400pt down", detail: "\(offset)")

    L10n.setPseudoLanguage(.ar) { "‹\($0)›" }
    content.layoutSubtreeIfNeeded()
    func wrapped(_ s: String) -> Bool { s.hasPrefix("‹") && s.hasSuffix("›") }
    check(sw.selectedPane === recording && scroll.documentView === recording.view && sidebarItems.filter(\.isSelected).map(\.title) == [recording.paneTitle],
          "under the new language the Recording pane is still the one selected and shown")
    check(scroll.contentView.bounds.origin == offset, "and its page is still scrolled to the same place", detail: "\(scroll.contentView.bounds.origin)")
    check(wrapped(win.title) && sidebarItems.allSatisfy { wrapped($0.title) && wrapped($0.accessibilityLabel() ?? "") },
          "the window title and every sidebar item follow the language", detail: "\(win.title) \(sidebarItems.map(\.title))")
    check(findView("settings.sidebar.recording", in: content) != nil && findView("settings.sidebar.quick-access", in: content) != nil,
          "sidebar identifiers stay English while the titles change")

    // Strings that other parts of the app own and translate, and what a person typed or plugged in, are not this window's to wrap.
    var foreign = Set(VideoQuality.allCases.map(\.title) + GridPosition.allCases.map(\.title) + EditorCommand.Group.allCases.map(\.title))
    for shortcut in EditorShortcuts.all {
        foreign.insert(shortcut.command.title)
        if let note = shortcut.note { foreign.insert(note) }
    }
    let userContent = Set(Language.allCases.map(\.nativeName) + SaveFormat.allCases.map(\.title) + w.env.microphones().map(\.name))
    var unwrapped: [String] = []
    for pane in sw.panes {
        let page = pane.view
        let owned = allViews(page).filter { $0 is ShortcutRecorderView || $0 is KeyCaps }.compactMap { $0.accessibilityLabel() }
        for (text, view) in readableStrings(in: page) {
            if wrapped(text) || foreign.contains(text) || owned.contains(text) || userContent.contains(text) { continue }
            if view.accessibilityIdentifier() == "general.folder" || !text.contains(where: \.isLetter) { continue }
            unwrapped.append("\(pane.paneID): \(text)")
        }
    }
    check(unwrapped.isEmpty, "every pane re-renders every string it owns in the new language", detail: unwrapped.joined(separator: " | "))

    check(content.userInterfaceLayoutDirection == .rightToLeft && sw.panes.allSatisfy { $0.view.userInterfaceLayoutDirection == .rightToLeft },
          "the window and every pane are right to left")
    let sidebar = sidebarItems[0].superview?.superview
    check(sidebar?.frame.minX == 560 && scroll.frame.maxX == 560, "the sidebar moves to the right edge and the page to its left",
          detail: "\(String(describing: sidebar?.frame)) \(scroll.frame)")
    let page = recording.view
    page.layoutSubtreeIfNeeded()
    let laidOut = rows(in: page).filter { $0.titleField != nil && $0.control.map { !$0.isHidden } == true }
    check(!laidOut.isEmpty && laidOut.allSatisfy { $0.titleField!.frame.minX > $0.control!.frame.maxX },
          "every Recording row puts its title right of its control", detail: laidOut.map { "\($0.titleField!.frame.minX) vs \($0.control!.frame.maxX)" }.joined(separator: ", "))
    check(sidebar.map(hairlineIsOnLeft) == true, "the sidebar's hairline is on its left edge, facing the page")
    snapshotWindow(win, name: "settings-window-rtl-pseudo")

    L10n.setLanguage(.en)
    content.layoutSubtreeIfNeeded()
    page.layoutSubtreeIfNeeded()
    check(win.title == "Cornermark Settings" && sidebarItems.map(\.title) == englishTitles && sw.panes.map(\.paneTitle) == englishTitles,
          "switching back restores the English window title and sidebar")
    let english = sw.panes.flatMap { readableStrings(in: $0.view) }.map(\.text)
    check(!english.contains { $0.contains("‹") } && english.contains("Frame rate") && english.contains("Language"), "and every pane is English again")
    check(content.userInterfaceLayoutDirection == .leftToRight && sw.panes.allSatisfy { $0.view.userInterfaceLayoutDirection == .leftToRight }
          && sidebar?.frame.minX == 0, "the window is left to right again with the sidebar on the left")
    let ltrRows = rows(in: recording.view).filter { $0.titleField != nil && $0.control.map { !$0.isHidden } == true }
    check(!ltrRows.isEmpty && ltrRows.allSatisfy { $0.titleField!.frame.maxX < $0.control!.frame.minX }, "every Recording row puts its title left of its control again")
    check(sw.selectedPane === recording && scroll.contentView.bounds.origin == offset, "the Recording pane is still selected at the same scroll offset",
          detail: "\(scroll.contentView.bounds.origin)")
    check(sidebar.map(hairlineIsOnLeft) == false, "the sidebar's hairline is back on its right edge")
    check(nothingOnScreen(), "switching languages put nothing on screen")
}

/// Whether the 1pt hairline is drawn on the view's left edge rather than its right.
@MainActor
private func hairlineIsOnLeft(_ view: NSView) -> Bool {
    view.appearance = NSAppearance(named: .aqua)
    guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
    view.cacheDisplay(in: view.bounds, to: rep)
    let y = rep.pixelsHigh - 4
    func color(_ x: Int) -> NSColor? { rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) }
    let inside = color(rep.pixelsWide / 2)
    return color(0) != inside && color(rep.pixelsWide - 1) == inside
}
