import AppKit
import Carbon.HIToolbox
import KadrajCapture
import KadrajCore
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
    check(ocrStatus.stringValue.contains("Same shortcut as Capture Area") && ocrStatus.textColor == .systemRed, "a conflicting shortcut shows a red failure in Settings", detail: ocrStatus.stringValue)
    ocrRec.beginRecording()
    ocrRec.keyDown(with: Synth.keyEvent(nil, 26, "7", modifiers: [.control, .shift]))
    check(click("shortcutReset.ocr", in: pane(1)), "reset OCR shortcut")

    w.backend.failing[ActionTable.spec(.window).hotKey!] = Int32(eventHotKeyExistsErr)
    w.coordinator.hotKeys?.apply(c.settings.value)
    sw.refreshAll()
    let winStatus = findView("shortcutStatus.window", in: pane(1)) as! NSTextField
    check(winStatus.stringValue.hasPrefix("Not working: Taken by") && winStatus.textColor == .systemRed, "OS registration failure is visible in Settings", detail: winStatus.stringValue)
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
    snapshot(h.window!.contentView!, name: "history-light", in: h.window)
    snapshot(h.window!.contentView!, name: "history-dark", dark: true, in: h.window)
    h.setFilter(.area)
    h.window?.contentView?.layoutSubtreeIfNeeded()
    snapshot(h.window!.contentView!, name: "history-filtered-area", in: h.window)

    c.perform(.openSettings)
    let sw = c.settingsWindow!
    w.pickedFolder = nil
    w.backend.failing[ActionTable.spec(.window).hotKey!] = Int32(eventHotKeyExistsErr)
    c.hotKeys?.apply(c.settings.value)
    sw.refreshAll()
    for pane in sw.panes {
        let v = pane.view
        v.frame = NSRect(origin: .zero, size: v.frame.size)
        let hostWindow = hostOffscreen(v, size: v.frame.size)
        _ = hostWindow
        let name = "settings-" + pane.paneTitle.lowercased().replacingOccurrences(of: " ", with: "-")
        snapshot(v, name: name, backdrop: NSColor(white: 0.93, alpha: 1))
    }

    w.permission = false
    c.perform(.capture(.fullscreen))
    let pw = c.permissionWindow!.window!
    snapshot(pw.contentView!, name: "permission-window", in: pw)

    let pin = c.pins.pin(Pix.fixtureDisplay().image.cropping(to: CGRect(x: 80, y: 80, width: 740, height: 260))!, pointScale: 2)
    (pin.window.contentView as? PinContentView)?.setHovering(true)
    snapshot(pin.window.contentView!, name: "pin-window", in: pin.window)
    pin.opacity = 0.6
    check(FileManager.default.fileExists(atPath: scratch + "pin-window.png") && FileManager.default.fileExists(atPath: scratch + "permission-window.png"), "pin and permission snapshots written")

    let hud = c.hud
    hud.show("Copied 42 characters", symbol: "text.viewfinder")
    snapshot(hud.panel!.contentView!, name: "hud", backdrop: NSColor(white: 0.6, alpha: 1))
    check(nothingOnScreen(), "snapshots ordered nothing on screen")
}
