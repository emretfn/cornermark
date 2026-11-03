import AppKit
import Carbon.HIToolbox
import KadrajCapture
import KadrajCore
import KadrajDesign
@testable import KadrajShell

@MainActor
func checkSettingsWindow() async throws {
    section("Settings window")
    let w = try World(after: [.showOverlay, .copy], hotKeys: true)
    defer { w.cleanup() }
    let c = w.coordinator
    c.perform(.openSettings)
    let sw = c.settingsWindow!
    check(w.presented.contains { $0 === sw.window } && sw.window?.isVisible == false, "settings window presented offscreen only")
    check(sw.panes.map(\.paneTitle) == ["General", "Shortcuts", "Quick Access", "Capture", "Permissions"], "five tabs: General, Shortcuts, Quick Access, Capture, Permissions")
    let views = sw.panes.map { $0.view }
    func pane(_ i: Int) -> NSView { views[i] }

    section("Settings: General")
    check((findView("general.after.copy", in: pane(0)) as? NSButton)?.state == .on && (findView("general.after.save", in: pane(0)) as? NSButton)?.state == .off, "checkboxes mirror after-capture settings")
    check(click("general.after.save", in: pane(0)) && c.settings.value.afterCapture.contains(.save), "ticking Save to folder updates settings")
    check(click("general.after.copy", in: pane(0)) && !c.settings.value.afterCapture.contains(.copy), "unticking Copy updates settings")
    check(click("general.after.openEditor", in: pane(0)) && c.settings.value.afterCapture.contains(.openEditor), "ticking Open in editor updates settings")
    let format = findView("general.format", in: pane(0)) as! NSPopUpButton
    format.selectItem(at: 1); fire(format)
    check(c.settings.value.imageFormat == .jpeg, "format popup switches to JPEG")
    format.selectItem(at: 0); fire(format)
    check(c.settings.value.imageFormat == .png, "and back to PNG")
    check(click("general.sound", in: pane(0)) && c.settings.value.playSound, "sound checkbox turns sound on")
    let picked = w.root.appendingPathComponent("picked", isDirectory: true)
    w.pickedFolder = picked
    check(click("general.chooseFolder", in: pane(0)) && c.settings.value.saveFolder == picked.path, "Choose folder stores the picked path")
    check((findView("general.folder", in: pane(0)) as? NSTextField)?.stringValue == picked.path, "folder label shows the path")
    check(click("general.resetFolder", in: pane(0)) && c.settings.value.saveFolder == nil
          && (findView("general.folder", in: pane(0)) as? NSTextField)?.stringValue == w.env.defaultSaveFolder.path, "Use Desktop resets to the default folder")
    check(collectText(pane(0)).contains { $0.contains("Kadraj YYYY-MM-DD at HH.MM.SS.png") }, "pane documents the file name pattern")

    check(click("general.launchAtLogin", in: pane(0)) && w.login.isEnabled && c.settings.value.launchAtLogin, "launch at login registers the login item")
    check(click("general.launchAtLogin", in: pane(0)) && !w.login.isEnabled && !c.settings.value.launchAtLogin, "and unregisters it")
    w.login.failure = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "not allowed"])
    check(click("general.launchAtLogin", in: pane(0)) && !c.settings.value.launchAtLogin, "a failing login item reverts the setting")
    check(c.loginError?.contains("not allowed") == true && collectText(pane(0)).contains { $0.contains("not allowed") }, "the failure is shown in the pane", detail: c.loginError ?? "nil")
    w.login.failure = nil

    section("Settings: Shortcuts")
    let rec = findView("shortcut.area", in: pane(1)) as! ShortcutRecorderView
    let status = findView("shortcutStatus.area", in: pane(1)) as! NSTextField
    check(rec.hotKey == ActionTable.spec(.area).hotKey && status.stringValue == "Active", "recorder shows the default and its status is Active")
    rec.beginRecording()
    rec.keyDown(with: Synth.keyEvent(nil, 40, "k", modifiers: [.control, .option]))
    let custom = HotKey(keyCode: 40, modifiers: UInt32(controlKey | optionKey))
    check(c.settings.value.customShortcuts["area"] == custom && rec.hotKey == custom, "recording Ctrl+Opt+K stores the shortcut")
    check(w.backend.registered.values.contains(custom) && !w.backend.registered.values.contains(ActionTable.spec(.area).hotKey!), "the global registration moved to the new key")
    rec.beginRecording()
    rec.keyDown(with: Synth.keyEvent(nil, 40, "k"))
    check(c.settings.value.customShortcuts["area"] == custom, "a key without modifiers is refused while recording")
    rec.beginRecording()
    rec.keyDown(with: Synth.keyEvent(nil, 53, "\u{1b}"))
    check(!rec.isRecording && c.settings.value.customShortcuts["area"] == custom, "Escape cancels recording")
    rec.beginRecording()
    rec.keyDown(with: Synth.keyEvent(nil, 51, "\u{8}"))
    check(c.settings.value.disabledShortcuts.contains("area") && rec.hotKey == nil && status.stringValue == "Off", "Delete switches the shortcut off")
    check(click("shortcutReset.area", in: pane(1)) && rec.hotKey == ActionTable.spec(.area).hotKey && status.stringValue == "Active", "Reset restores the default and re-registers it")

    let ocrRec = findView("shortcut.ocr", in: pane(1)) as! ShortcutRecorderView
    ocrRec.beginRecording()
    ocrRec.keyDown(with: Synth.keyEvent(nil, 19, "2", modifiers: [.control, .shift]))
    let ocrStatus = findView("shortcutStatus.ocr", in: pane(1)) as! NSTextField
    check(ocrStatus.stringValue.contains("Same shortcut as Capture Area") && ocrStatus.textColor == DS.Color.dangerText, "a conflicting shortcut shows a red failure in Settings", detail: ocrStatus.stringValue)
    ocrRec.beginRecording()
    ocrRec.keyDown(with: Synth.keyEvent(nil, 26, "7", modifiers: [.control, .shift]))
    check(click("shortcutReset.ocr", in: pane(1)), "reset OCR shortcut")

    w.backend.failing[ActionTable.spec(.window).hotKey!] = Int32(eventHotKeyExistsErr)
    w.coordinator.hotKeys?.apply(c.settings.value)
    sw.refreshAll()
    let winStatus = findView("shortcutStatus.window", in: pane(1)) as! NSTextField
    check(winStatus.stringValue.hasPrefix("Not working: Taken by") && winStatus.textColor == DS.Color.dangerText, "OS registration failure is visible in Settings", detail: winStatus.stringValue)
    check(collectText(pane(4)).contains { $0.contains("not working") }, "Permissions tab summarizes failed shortcuts")

    section("Settings: Quick Access, Capture, Permissions")
    let corner = findView("quick.corner", in: pane(2)) as! NSPopUpButton
    corner.selectItem(at: ScreenCorner.allCases.firstIndex(of: .topRight)!); fire(corner)
    check(c.settings.value.overlayCorner == .topRight, "corner popup")
    let size = findView("quick.size", in: pane(2)) as! NSPopUpButton
    size.selectItem(at: 2); fire(size)
    check(c.settings.value.overlaySize == .large, "size popup")
    let auto = findView("quick.autoClose", in: pane(2)) as! NSPopUpButton
    auto.selectItem(at: 0); fire(auto)
    check(c.settings.value.overlayAutoClose == nil, "auto-close popup: Never")
    auto.selectItem(at: 3); fire(auto)
    check(c.settings.value.overlayAutoClose == 8, "auto-close popup: 8 seconds")
    check(auto.itemTitles == ["Never", "After 3 seconds", "After 5 seconds", "After 8 seconds", "After 15 seconds", "After 30 seconds"], "auto-close choices", detail: "\(auto.itemTitles)")

    let timer = findView("capture.timer", in: pane(3)) as! NSStepper
    timer.integerValue = 9; fire(timer)
    check(c.settings.value.timerSeconds == 9 && c.capture.timerSeconds == 9, "timer stepper reaches the capture controller")
    let ret = findView("capture.retention", in: pane(3)) as! NSStepper
    ret.integerValue = 14; fire(ret)
    check(c.settings.value.retentionDays == 14, "retention stepper")
    check(click("capture.shadow", in: pane(3)) && !c.settings.value.windowShadow && !c.capture.includeWindowShadow, "window shadow toggle reaches the capture controller")
    check((findView("capture.retention.value", in: pane(3)) as? NSTextField)?.stringValue == "14 days", "retention label")

    w.permission = false
    sw.refreshAll()
    check((findView("permissions.status", in: pane(4)) as? NSTextField)?.stringValue.contains("Not allowed") == true, "permission status: not allowed")
    check(click("permissions.open", in: pane(4)) && w.opened.last == AppEnvironment.screenCapturePaneURL, "permission pane opens System Settings")
    w.permission = true
    sw.refreshAll()
    check((findView("permissions.status", in: pane(4)) as? NSTextField)?.stringValue.contains("Allowed") == true, "permission status: allowed")

    check((findView("permissions.open", in: pane(4)) as? Button)?.variant == .secondary, "granted: Open System Settings is a secondary button")
    w.permission = false
    sw.refreshAll()
    check((findView("permissions.open", in: pane(4)) as? Button)?.variant == .primary, "not granted: Open System Settings is the primary button")
    check((findView("permissions.status", in: pane(4)) as? NSTextField)?.textColor == DS.Color.warningText, "not granted: status text is warningText")
    w.permission = true
    sw.refreshAll()
    check((findView("permissions.status", in: pane(4)) as? NSTextField)?.textColor == DS.Color.successText, "granted: status text is successText")
    check((findView("permissions.shortcuts", in: pane(4)) as? NSTextField)?.textColor == DS.Color.dangerText, "failing shortcuts are summarised in dangerText")

    try checkSettingsLayout(w, sw)

    let reread = SettingsStore(defaults: w.defaults).value
    check(reread == c.settings.value, "every change made in the window is persisted in the settings suite")
    check(nothingOnScreen(), "settings checks ordered nothing on screen")
}

@MainActor
func takeSnapshots() async throws {
    section("snapshots")
    try? FileManager.default.createDirectory(atPath: scratch, withIntermediateDirectories: true)
    let w = try World(after: [.showOverlay], hotKeys: true)
    defer { w.cleanup() }
    let c = w.coordinator

    c.handleCaptured(.init(image: Pix.fixtureDisplay().image.cropping(to: CGRect(x: 80, y: 80, width: 740, height: 260))!, kind: .area, pointScale: 1))
    let card = c.overlay.stack[0]
    let view = c.overlay.cardView(for: card)!
    let host = hostOffscreen(view, size: view.frame.size)
    _ = host
    let urls = [
        snapshot(view, name: "card-light"),
        snapshot(view, name: "card-dark", dark: true),
    ]
    view.setHovering(true)
    let hover = [
        snapshot(view, name: "card-light-hover"),
        snapshot(view, name: "card-dark-hover", dark: true),
    ]
    check((urls + hover).allSatisfy { $0 != nil }, "card snapshots written (light, dark, hovering)")
    for overlay in OverlaySize.allCases {
        view.setCardSize(QuickAccessLayout.cardSize(width: overlay.cardWidth))
        view.layoutSubtreeIfNeeded()
        let inner = view.bounds.insetBy(dx: DS.Space.s8, dy: 0)
        let row = [CardAction.copy, .save, .annotate, .ocr].compactMap { view.buttons[$0]?.frame }
        check(row.count == 4 && row.allSatisfy { $0.minX >= inner.minX && $0.maxX <= inner.maxX }, "\(overlay.title) card keeps its action row inside the card")
        check(zip(row, row.dropFirst()).allSatisfy { $0.maxX < $1.minX }, "\(overlay.title) card buttons don't touch each other")
        snapshot(view, name: "card-\(overlay.title.lowercased())-hover")
    }
    check(CardButtonMetrics.forCard(width: 160).action < CardButtonMetrics.forCard(width: 220).action
          && CardButtonMetrics.forCard(width: 220).action < CardButtonMetrics.forCard(width: 300).action, "the action buttons grow with the card")
    view.setCardSize(QuickAccessLayout.cardSize(width: OverlaySize.medium.cardWidth))
    view.setHovering(false)

    let seeded = seedHistory(w)
    c.perform(.openHistory)
    let h = c.history!
    h.window?.setContentSize(NSSize(width: 920, height: 640))
    h.select(recordIDs: [seeded[1].id])
    h.window?.contentView?.layoutSubtreeIfNeeded()
    h.collectionView.layoutSubtreeIfNeeded()
    let px = HistoryWindowController.thumbnailPixels
    _ = await waitUntil { h.records.allSatisfy { h.thumbnails.cached($0.id, maxPixel: px) != nil } }
    h.collectionView.reloadData()
    h.window?.contentView?.layoutSubtreeIfNeeded()
    h.collectionView.layoutSubtreeIfNeeded()
    _ = await waitUntil { (0..<h.collectionView.numberOfSections).allSatisfy { s in
        (0..<h.collectionView.numberOfItems(inSection: s)).allSatisfy { h.collectionView.item(at: IndexPath(item: $0, section: s)) != nil } } }
    h.select(recordIDs: [seeded[1].id])
    snapshotWindow(h.window!, name: "history-light")
    snapshotWindow(h.window!, name: "history-dark", dark: true)
    if let hovered = h.collectionView.item(at: IndexPath(item: 0, section: 0))?.view {
        hovered.mouseEntered(with: Synth.enterExit(.mouseEntered, in: h.window!))
        snapshotWindow(h.window!, name: "history-light-hover")
        hovered.mouseExited(with: Synth.enterExit(.mouseExited, in: h.window!))
    }
    h.select(recordIDs: [])
    snapshotWindow(h.window!, name: "history-light-no-selection")
    h.setFilter(.area)
    h.window?.contentView?.layoutSubtreeIfNeeded()
    snapshotWindow(h.window!, name: "history-filtered-area")

    c.perform(.openSettings)
    let sw = c.settingsWindow!
    w.pickedFolder = nil
    w.backend.failing[ActionTable.spec(.window).hotKey!] = Int32(eventHotKeyExistsErr)
    c.hotKeys?.apply(c.settings.value)
    sw.refreshAll()
    // The whole window, traffic lights included, because the sidebar runs under them.
    check(sw.window!.contentView!.bounds.size == NSSize(width: 760, height: 560), "settings content fills the 760 x 560 window", detail: "\(sw.window!.contentView!.bounds.size)")
    for pane in sw.panes {
        sw.select(pane: pane)
        sw.window!.layoutIfNeeded()
        let name = "settings-window-" + pane.paneTitle.lowercased().replacingOccurrences(of: " ", with: "-")
        snapshotWindow(sw.window!, name: name)
        if pane is GeneralPane || pane is ShortcutsPane { snapshotWindow(sw.window!, name: name + "-dark", dark: true) }
    }
    w.permission = false
    sw.refreshAll()
    snapshotWindow(sw.window!, name: "settings-window-permissions-denied")
    sw.window?.appearance = nil

    w.permission = false
    c.perform(.capture(.fullscreen))
    let pw = c.permissionWindow!.window!
    snapshot(pw.contentView!, name: "permission-window", in: pw)
    snapshot(pw.contentView!, name: "permission-window-dark", dark: true, in: pw)

    let pin = c.pins.pin(Pix.fixtureDisplay().image.cropping(to: CGRect(x: 80, y: 80, width: 740, height: 260))!, pointScale: 2)
    (pin.window.contentView as? PinContentView)?.setHovering(true)
    snapshot(pin.window.contentView!, name: "pin-window", in: pin.window)
    pin.opacity = 0.6
    check(FileManager.default.fileExists(atPath: scratch + "pin-window.png") && FileManager.default.fileExists(atPath: scratch + "permission-window.png"), "pin and permission snapshots written")

    let hud = c.hud
    hud.show("Copied 42 characters", symbol: "text.viewfinder")
    snapshot(hud.panel!.contentView!, name: "hud", dark: true, backdrop: NSColor(white: 0.6, alpha: 1))
    snapshot(hud.panel!.contentView!, name: "hud-light-wallpaper", dark: true, backdrop: NSColor(white: 0.93, alpha: 1))
    check(nothingOnScreen(), "snapshots ordered nothing on screen")
}


@MainActor
private func cards(in view: NSView) -> [FormCard] {
    (view as? FormCard).map { [$0] } ?? view.subviews.flatMap(cards(in:))
}

@MainActor
private func checkSettingsLayout(_ w: World, _ sw: SettingsWindowController) throws {
    section("Settings: window, sidebar, form layout")
    let win = sw.window!
    let content = win.contentView!
    check(win.contentViewController == nil, "the settings window has no tab view controller")
    check(win.styleMask.contains(.fullSizeContentView) && !win.styleMask.contains(.resizable) && win.titlebarAppearsTransparent && win.titleVisibility == .hidden,
          "settings: full-size content, transparent title bar, hidden title, not resizable")
    check(content.bounds.size == NSSize(width: 760, height: 560), "settings content is 760 x 560", detail: "\(content.bounds.size)")

    let ids = ["general", "shortcuts", "quick-access", "capture", "permissions"]
    let items = ids.compactMap { findView("settings.sidebar.\($0)", in: content) as? SidebarItem }
    check(items.count == 5 && items.map(\.title) == sw.panes.map(\.paneTitle), "the sidebar has one SidebarItem per pane, in pane order")
    content.layoutSubtreeIfNeeded()
    let rects = items.map { $0.convert($0.bounds, to: content) }
    check(rects.allSatisfy { $0.minX == DS.Space.s12 && $0.width == 200 - 2 * DS.Space.s12 && $0.height == DS.Size.control },
          "sidebar items are 176 wide, control tall, s12 from the left", detail: "\(rects)")
    check(abs((content.bounds.height - rects[0].maxY) - 44) < 0.5, "the first item starts 44pt below the top, under the window buttons", detail: "\(content.bounds.height - rects[0].maxY)")
    check(zip(rects, rects.dropFirst()).allSatisfy { abs($0.minY - $1.maxY - DS.Space.s2) < 0.5 }, "sidebar items are s2 apart")
    let sidebar = items[0].superview?.superview
    check(sidebar?.frame == CGRect(x: 0, y: 0, width: 200, height: 560), "the sidebar is 200 wide and fills the window's full height", detail: "\(String(describing: sidebar?.frame))")

    let scroll = findView("settings.scroll", in: content) as! NSScrollView
    let frame = win.frame
    for (i, item) in items.enumerated() {
        item.performClick(nil)
        check(sw.selectedPane === sw.panes[i] && scroll.documentView === sw.panes[i].view && items.filter(\.isSelected).map(\.title) == [sw.panes[i].paneTitle],
              "clicking \(item.title) shows that pane and selects only that item")
    }
    check(win.frame == frame, "switching panes never resizes the window")
    check(scroll.hasHorizontalScroller == false && scroll.scrollerStyle == .overlay && !scroll.drawsBackground, "the page scrolls vertically with overlay scrollers and no background")
    items[0].performClick(nil)

    for pane in sw.panes {
        let page = pane.view
        check(page.frame.width == 560 && page.frame.height > 200 && page.frame.height < 1400, "\(pane.paneTitle): the page is 560 wide with a fitted height", detail: "\(page.frame.size)")
        let found = cards(in: page)
        check(!found.isEmpty && found.allSatisfy { $0.frame.width == 512 && $0.convert($0.bounds, to: page).minX == 24 }, "\(pane.paneTitle): every card is 512 wide on the s24 inset",
              detail: "\(found.map { $0.convert($0.bounds, to: page) })")
        for card in found {
            card.layoutSubtreeIfNeeded()
            for row in card.rows {
                row.layoutSubtreeIfNeeded()
                let h = row.intrinsicContentSize.height
                check(h >= 44 && row.frame.height == h, "\(pane.paneTitle): row \(row.titleField?.stringValue ?? "footer") is at least 44 tall", detail: "\(h)")
                if let control = row.control, !control.isHidden {
                    let edge = control.frame.maxX - (control is NSTextField ? Form.labelInset : 0)
                    check(abs(edge - (512 - DS.Space.s16)) < 0.5, "\(pane.paneTitle): \(row.titleField?.stringValue ?? "footer") control ends on the one right edge", detail: "\(edge)")
                    check(abs(control.frame.midY - row.bounds.midY) <= 0.5, "\(pane.paneTitle): \(row.titleField?.stringValue ?? "footer") control is vertically centred", detail: "\(control.frame.midY) of \(row.bounds.midY)")
                }
                if let title = row.titleField, let caption = row.caption, !caption.isHidden {
                    check(title.frame.maxY <= caption.frame.minY + 0.5 && caption.frame.maxX <= (row.control?.frame.minX ?? 512) + Form.labelInset,
                          "\(pane.paneTitle): \(title.stringValue) has its caption beneath it and clear of the control")
                }
            }
        }
    }

    let general = sw.panes[0]
    let loginRow = findView("general.launchAtLogin", in: general.view)?.superview as? FormRow
    w.login.failure = nil
    _ = click("general.launchAtLogin", in: general.view)
    check(loginRow?.caption?.isHidden == true && loginRow?.intrinsicContentSize.height == 44, "launch at login: with no error the note is hidden and the row is 44 tall")
    w.login.failure = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "not allowed"])
    _ = click("general.launchAtLogin", in: general.view)
    check(loginRow?.caption?.isHidden == false && loginRow?.caption?.textColor == DS.Color.dangerText && (loginRow?.intrinsicContentSize.height ?? 0) > 44,
          "launch at login: an error shows its note in dangerText and the row grows to hold it")
    w.login.failure = nil
    _ = click("general.launchAtLogin", in: general.view)
    check(loginRow?.caption?.isHidden == true && loginRow?.intrinsicContentSize.height == 44, "launch at login: a later success hides the note and the row is 44 tall again")

    let folder = findView("general.folder", in: general.view) as? NSTextField
    check(folder?.lineBreakMode == .byTruncatingMiddle && folder?.font == DS.Text.caption.font && folder?.textColor == DS.Color.textSecondary,
          "the save folder path is caption-styled and truncates in the middle")
    check(findView("general.chooseFolder", in: general.view) is Button && (findView("general.resetFolder", in: general.view) as? Button)?.variant == .ghost,
          "Choose is a Button and Use Desktop a ghost Button")
    check((findView("general.launchAtLogin", in: general.view) as? Checkbox)?.title == "" && (findView("general.launchAtLogin", in: general.view) as? Checkbox)?.accessibilityLabel() == "Launch Kadraj at login",
          "settings checkboxes are design-system Checkboxes with no title and an accessibility label")
    let popup = findView("general.format", in: general.view) as? NSPopUpButton
    check(popup?.controlSize == .small && popup?.font == DS.Text.label.font, "popups are small and use the label style")

    let rec = findView("shortcut.area", in: sw.panes[1].view) as! ShortcutRecorderView
    check(rec.intrinsicContentSize == NSSize(width: 140, height: DS.Size.control), "the shortcut recorder is 140 wide and control tall")
    let reset = findView("shortcutReset.area", in: sw.panes[1].view) as? IconButton
    check(reset?.size == .small && reset?.tone == .plain && reset?.symbol == "arrow.counterclockwise" && reset?.accessibilityLabel() == "Reset", "Reset is a small plain IconButton")
    for (recording, token, label) in [(false, DS.Color.bgControl, "idle"), (true, DS.Color.accentSubtle, "recording")] {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let r = ShortcutRecorderView()
            r.frame.size = r.intrinsicContentSize
            r.appearance = NSAppearance(named: appearance)
            if recording { r.beginRecording() }
            let rep = r.bitmapImageRepForCachingDisplay(in: r.bounds)!
            r.cacheDisplay(in: r.bounds, to: rep)
            let got = rep.colorAt(x: Int(r.bounds.width) / 2 * Int(CGFloat(rep.pixelsWide) / r.bounds.width), y: 3)!.usingColorSpace(.sRGB)!
            let want = rgba(token, appearance)
            check(abs(got.redComponent - want[0]) < 0.03 && abs(got.greenComponent - want[1]) < 0.03 && abs(got.blueComponent - want[2]) < 0.03,
                  "the recorder paints \(label) as \(recording ? "accentSubtle" : "bgControl") in \(appearance == .aqua ? "light" : "dark")",
                  detail: "got \(got.redComponent) \(got.greenComponent) \(got.blueComponent)")
        }
    }
    check(nothingOnScreen(), "settings layout checks ordered nothing on screen")
}


@MainActor
func checkSmallWindows() async throws {
    section("Small windows: permission, HUD, pin")
    let w = try World(after: [.showOverlay])
    defer { w.cleanup() }
    let c = w.coordinator

    w.permission = false
    c.perform(.capture(.fullscreen))
    let pw = c.permissionWindow!.window!
    let view = pw.contentView!
    view.layoutSubtreeIfNeeded()
    check(pw.backgroundColor == DS.Color.bgWindow && view.frame.width == 520, "permission: bgWindow, 520 wide")
    let open = findView("permission.open", in: view) as? Button, quit = findView("permission.quit", in: view) as? Button
    check(open?.variant == .primary && open?.keyEquivalent == "\r" && quit?.variant == .ghost && quit?.title == "Quit Kadraj",
          "permission: Open System Settings is primary on Return, Quit Kadraj is ghost")
    if let open, let quit {
        let a = open.convert(open.bounds, to: view), b = quit.convert(quit.bounds, to: view)
        check(abs(a.maxX - (view.bounds.width - DS.Space.s24)) <= 0.5 && abs(a.minX - b.maxX - DS.Space.s8) <= 0.5, "permission: the buttons are right-aligned on the s24 padding, s8 apart", detail: "\(a) \(b)")
        check(abs(a.minY - DS.Space.s24) <= 0.5, "permission: the buttons sit s24 above the bottom edge", detail: "\(a.minY)")
    }
    func fields(_ v: NSView) -> [NSTextField] { (v as? NSTextField).map { [$0] } ?? v.subviews.flatMap(fields) }
    let title = fields(view).first { $0.stringValue.hasPrefix("Kadraj needs permission") }
    check(title?.font == DS.Text.title.font && title?.textColor == DS.Color.textPrimary, "permission: the title is DS title style")
    let intro = fields(view).first { $0.stringValue.hasPrefix("macOS blocks") }
    check(intro?.font == DS.Text.body.font && intro?.textColor == DS.Color.textSecondary, "permission: the intro is body in textSecondary")
    let hint = fields(view).first { $0.stringValue.hasPrefix("After you switch") }
    check(hint?.font == DS.Text.caption.font && hint?.textColor == DS.Color.textSecondary, "permission: the hint is a caption")
    let steps = PermissionWindowController.steps.compactMap { step in fields(view).first { $0.stringValue == step } }
    check(steps.count == 3 && steps.allSatisfy { $0.font == DS.Text.body.font }, "permission: three steps in body style")
    let discs = (0..<3).compactMap { i -> NSView? in
        func hunt(_ v: NSView) -> [NSView] { (String(describing: type(of: v)).hasSuffix("StepNumber") ? [v] : []) + v.subviews.flatMap(hunt) }
        return hunt(view).count == 3 ? hunt(view)[i] : nil
    }
    check(discs.count == 3 && discs.allSatisfy { $0.frame.size == NSSize(width: 20, height: 20) }, "permission: the step numbers are 20pt discs")
    if discs.count == 3, steps.count == 3 {
        let ok = zip(discs, steps).allSatisfy { disc, text in
            let d = disc.convert(disc.bounds, to: view), t = text.convert(text.alignmentRect(forFrame: text.bounds), to: view)
            // The first text line is 18 tall, the disc 20, so the disc is centred on it when its top is 1pt above the line.
            let line = view.isFlipped ? t.minY + 9 : t.maxY - 9
            return abs(d.midY - line) <= 1 && abs(t.minX - d.maxX - DS.Space.s12) <= 2.5
        }
        check(ok, "permission: each disc is centred on its step's first line, s12 before the text")
    }
    let red = fields(view).filter { $0.textColor == .systemRed }
    check(red.isEmpty, "permission: no system red anywhere")

    let hud = c.hud
    hud.show("Copied 42 characters", symbol: "text.viewfinder")
    let hv = hud.panel!.contentView as! HUDView
    let size = HUDView.size(for: "Copied 42 characters", hasSymbol: true)
    let text = NSAttributedString(string: "Copied 42 characters", attributes: DS.Text.bodyStrong.attributes(color: .black)).size().width
    check(size.height == 40 && size.width == DS.Space.s16 + DS.Size.iconLarge + DS.Space.s8 + ceil(text) + DS.Space.s16, "HUD: 40 tall, s16 padding, s8 between symbol and text", detail: "\(size)")
    check(HUDView.size(for: "x", hasSymbol: false).width == 2 * DS.Space.s16 + ceil(NSAttributedString(string: "x", attributes: DS.Text.bodyStrong.attributes(color: .black)).size().width),
          "HUD: with no symbol the width drops the symbol and its gap")
    check(HUDView.size(for: String(repeating: "wide ", count: 60), hasSymbol: true).width == 520, "HUD: very long messages stop at 520")
    check(hv.appearance?.name == .darkAqua && hud.panel?.hasShadow == true, "HUD: always darkAqua, with the native window shadow")
    hv.frame = NSRect(origin: .zero, size: size)
    do {
        // The window host may be light; the HUD is dark regardless, so the same pixel is checked under a light host appearance.
        hv.window?.appearance = NSAppearance(named: .aqua)
        let rep = hv.bitmapImageRepForCachingDisplay(in: hv.bounds)!
        hv.cacheDisplay(in: hv.bounds, to: rep)
        let k = CGFloat(rep.pixelsWide) / hv.bounds.width
        let got = rep.colorAt(x: Int(40 * k), y: Int(4 * k))!.usingColorSpace(.sRGB)!
        let want = rgba(DS.Color.bgHud, .darkAqua)
        check(abs(got.alphaComponent - want[3]) < 0.05 && abs(got.redComponent - want[0]) < 0.06, "HUD: paints bgHud, the dark surface, under a light host",
              detail: "got \(got.redComponent) a \(got.alphaComponent)")
    }
    var inkTop = Int.max, inkBottom = -1
    do {
        let rep = hv.bitmapImageRepForCachingDisplay(in: hv.bounds)!
        hv.cacheDisplay(in: hv.bounds, to: rep)
        let k = CGFloat(rep.pixelsWide) / hv.bounds.width
        for y in 0..<rep.pixelsHigh {
            for x in Int((DS.Space.s16 + DS.Size.iconLarge + DS.Space.s8) * k)..<Int((hv.bounds.width - DS.Space.s16) * k) where (rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)?.brightnessComponent ?? 0) > 0.6 {
                inkTop = min(inkTop, y); inkBottom = max(inkBottom, y)
            }
        }
        let centre = (CGFloat(inkTop) + CGFloat(inkBottom + 1)) / 2 / k
        check(inkBottom > 0 && abs(centre - hv.bounds.midY) <= 2, "HUD: the text sits on the vertical middle of the bar", detail: "ink centre \(centre) of \(hv.bounds.midY)")
    }

    c.handleCaptured(.init(image: Pix.fixtureDisplay().image.cropping(to: CGRect(x: 80, y: 80, width: 740, height: 120))!, kind: .area, pointScale: 1))
    let cardView = c.overlay.cardView(for: c.overlay.stack[0])!
    for (label, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
        cardView.appearance = NSAppearance(named: appearance)
        let rep = cardView.bitmapImageRepForCachingDisplay(in: cardView.bounds)!
        cardView.cacheDisplay(in: cardView.bounds, to: rep)
        let k = CGFloat(rep.pixelsWide) / cardView.bounds.width
        let got = rep.colorAt(x: Int(cardView.bounds.midX * k), y: Int((DS.Space.s8 + 4) * k))!.usingColorSpace(.sRGB)!
        let want = rgba(DS.Color.bgSunken, appearance)
        check(abs(got.redComponent - want[0]) < 0.04 && abs(got.greenComponent - want[1]) < 0.04 && abs(got.blueComponent - want[2]) < 0.04,
              "[\(label)] the letterbox of a wide capture on a Quick Access card is the bgSunken well", detail: "got \(got.redComponent) \(got.greenComponent) \(got.blueComponent)")
    }
    c.overlay.closeAll()

    let pin = c.pins.pin(Pix.fixtureDisplay().image.cropping(to: CGRect(x: 80, y: 80, width: 740, height: 260))!, pointScale: 2)
    let pv = pin.window.contentView!
    pv.appearance = NSAppearance(named: .aqua)
    let prep = pv.bitmapImageRepForCachingDisplay(in: pv.bounds)!
    pv.cacheDisplay(in: pv.bounds, to: prep)
    let pk = CGFloat(prep.pixelsWide) / pv.bounds.width
    let edge = prep.colorAt(x: 0, y: Int(pv.bounds.height * pk / 2))!.usingColorSpace(.sRGB)!, inner = prep.colorAt(x: Int(3 * pk), y: Int(pv.bounds.height * pk / 2))!.usingColorSpace(.sRGB)!
    let ratio = edge.redComponent / max(inner.redComponent, 0.001)
    check(ratio > 0.8 && ratio < 0.97, "pin: the 1pt edge is the imageOutline token, black at 10%, over the picture", detail: "edge \(edge.redComponent) inner \(inner.redComponent)")
    pin.close()
    check(nothingOnScreen(), "small window checks ordered nothing on screen")
}
