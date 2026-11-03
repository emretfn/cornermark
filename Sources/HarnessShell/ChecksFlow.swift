import AppKit
import CornermarkCapture
import CornermarkCore
import CornermarkEditor
@testable import CornermarkShell

@MainActor
func checkCaptureFlow() async throws {
    section("capture through AppAction: store, history, card")
    let w = try World(after: [.showOverlay])
    defer { w.cleanup() }
    let c = w.coordinator
    let generalBefore = w.pasteboard.changeCount

    check(await w.capture(.fullscreen, expecting: 1), "fullscreen capture via AppAction reaches the CaptureStore")
    let record = w.store.list().first
    check(record?.kind == .fullscreen && record?.pixelSize == CGSize(width: 1280, height: 800), "stored record is fullscreen at the fixture size", detail: "\(String(describing: record))")
    check(record.map { FileManager.default.fileExists(atPath: w.store.paths(for: $0).image.path) } == true, "image.png exists in the capture folder")

    c.perform(.openHistory)
    check(c.history?.records.map(\.id) == [record!.id], "history list shows the new capture")
    check(c.history?.window?.isVisible == false, "history window is built but not visible")

    check(c.overlay.stack.count == 1, "a Quick Access card appeared")
    let card = c.overlay.stack[0]
    let panel = c.overlay.panel(for: card)!
    check(card.record.id == record!.id && card.state == .visible, "card is for the new record and starts .visible")
    check(!panel.isVisible && panel.contentView is QuickAccessCardView, "card panel exists but was never ordered in")
    check(card.info == "1280 \u{00D7} 800", "card shows the dimensions", detail: card.info)
    check(w.pasteboard.changeCount == generalBefore, "overlay-only routing leaves the pasteboard alone")
    check(w.sounds == 0, "sound off: no sound played")

    w.settings.update { $0.playSound = true }
    _ = await w.capture(.fullscreen, expecting: 2)
    check(w.sounds == 1, "sound on: one sound per capture")
    check(c.overlay.stack.count == 2 && c.overlay.stack[0].record.id != card.record.id, "newest card goes first in the stack")
    check(nothingOnScreen(), "no window is visible and the app is not active")

    section("area capture driven by synthetic events")
    w.now = w.now.addingTimeInterval(60)
    let before = w.store.list().count
    c.perform(.capture(.area))
    check(await waitUntil { !c.capture.overlayWindows.isEmpty }, "area capture builds overlay windows (offscreen)")
    let ow = c.capture.overlayWindows.first!
    check(!ow.isVisible, "capture overlay window is not visible")
    let sel = Fixture.global(Fixture.textBox)
    Synth.drag(ow, from: CGPoint(x: sel.minX, y: sel.maxY), to: CGPoint(x: sel.maxX, y: sel.minY))
    check(await waitUntil { w.store.list().count == before + 1 }, "dragging a selection stores an area capture")
    let area = w.store.list().first!
    check(area.kind == .area && area.pixelSize == Fixture.textBox.size, "area record has the selection size", detail: "\(area.pixelSize)")
    check(c.capture.lastSelection != nil, "previous-area selection is remembered")
    c.perform(.capture(.previousArea))
    check(await waitUntil { w.store.list().count == before + 2 }, "previous-area repeats without any UI")
}

@MainActor
func checkAfterCaptureRouting() async throws {
    section("after-capture settings routing")
    let w = try World(after: [.copy])
    defer { w.cleanup() }
    let c = w.coordinator

    _ = await w.capture(.fullscreen, expecting: 1)
    check(w.pasteboardImage().map { $0.width == 1280 && $0.height == 800 } == true, "copy: the PNG is on the private pasteboard")
    check(c.overlay.stack.isEmpty, "copy only: no card")
    check(!FileManager.default.fileExists(atPath: w.saveDir.path), "copy only: nothing written to the save folder")
    check(c.editors.isEmpty, "copy only: no editor")
    check(c.hud.lastMessage == "Copied to clipboard", "copy only: confirmation HUD", detail: c.hud.lastMessage ?? "nil")

    w.pasteboard.clearContents()
    w.settings.update { $0.afterCapture = [.save] }
    _ = await w.capture(.fullscreen, expecting: 2)
    let name = "Cornermark 2026-11-03 at 14.05.09.png"
    let file = w.saveDir.appendingPathComponent(name)
    check(FileManager.default.fileExists(atPath: file.path), "autosave: \(name) written to the temp save folder")
    check((try? FileManager.default.contentsOfDirectory(atPath: w.saveDir.path))?.count == 1, "autosave: exactly one file")
    check(Pix.decode(file).map { $0.width == 1280 && $0.height == 800 } == true, "autosave: file decodes at full size")
    check(w.pasteboard.data(forType: .png) == nil, "save only: pasteboard untouched")

    _ = await w.capture(.fullscreen, expecting: 3)
    check(FileManager.default.fileExists(atPath: w.saveDir.appendingPathComponent("Cornermark 2026-11-03 at 14.05.09 2.png").path), "autosave twice in one second does not overwrite")

    w.now = Fixture.timestamp(2026, 11, 3, 14, 6, 0)
    w.settings.update { $0.imageFormat = .jpeg }
    _ = await w.capture(.fullscreen, expecting: 4)
    check(FileManager.default.fileExists(atPath: w.saveDir.appendingPathComponent("Cornermark 2026-11-03 at 14.06.00.jpg").path), "autosave in JPEG uses the .jpg name for the new second")

    w.now = Fixture.timestamp(2026, 11, 3, 14, 6, 30)
    w.settings.update { $0.afterCapture = [.openEditor]; $0.imageFormat = .png }
    _ = await w.capture(.fullscreen, expecting: 5)
    let newest = w.store.list().first!
    let editor = c.editors[newest.id]
    check(editor != nil, "open-editor: an EditorWindowController was built for the capture")
    check(editor?.currentDocument.pixelSize == CGSize(width: 1280, height: 800), "open-editor: document has the capture size")
    check(editor.map { $0.renderedImage().width == 1280 } == true, "open-editor: renderedImage() works")
    check(editor?.window?.isVisible == false, "open-editor: window was not ordered in (show() is skipped offscreen)")
    check(c.overlay.stack.isEmpty, "open-editor only: no card")

    w.settings.update { $0.afterCapture = [.showOverlay, .copy, .save, .openEditor] }
    w.now = Fixture.timestamp(2026, 11, 3, 14, 7, 0)
    _ = await w.capture(.fullscreen, expecting: 6)
    check(c.overlay.stack.count == 1 && w.pasteboardImage() != nil
          && FileManager.default.fileExists(atPath: w.saveDir.appendingPathComponent("Cornermark 2026-11-03 at 14.07.00.png").path)
          && c.editors.count == 2, "all four routes together: card, clipboard, file and editor")

    w.settings.update { $0.afterCapture = [] }
    let n = w.store.list().count
    w.pasteboard.clearContents()
    _ = await w.capture(.fullscreen, expecting: n + 1)
    check(w.pasteboard.data(forType: .png) == nil && c.overlay.stack.count == 1, "no routes: capture lands in history only")
    check(c.editors.count == 2, "no routes: no extra editor")
    check(nothingOnScreen(), "routing never put a window on screen")
}

@MainActor
func checkPermission() async throws {
    section("permission denied")
    let w = try World(after: [.showOverlay])
    defer { w.cleanup() }
    let c = w.coordinator

    w.permission = false
    c.perform(.capture(.fullscreen))
    check(c.permissionWindow != nil && w.presented.contains { $0 === c.permissionWindow?.window }, "no permission: the permission window is presented instead of capturing")
    check(w.store.list().isEmpty && c.capture.overlayWindows.isEmpty, "no permission: nothing captured")
    let view = c.permissionWindow?.window?.contentView
    let texts = collectText(view)
    check(texts.contains { $0.contains("Screen & System Audio Recording") }, "window names the Screen & System Audio Recording permission")
    check(texts.contains { $0.localizedCaseInsensitiveContains("quit and reopen") }, "window carries the restart hint")
    check(click("permission.open", in: view), "Open System Settings button exists")
    check(w.opened == [AppEnvironment.screenCapturePaneURL], "button opens the Screen Capture privacy pane", detail: "\(w.opened)")
    check(AppEnvironment.screenCapturePaneURL.absoluteString.hasSuffix("Privacy_ScreenCapture"), "pane URL targets Privacy_ScreenCapture")
    check(click("permission.quit", in: view) && w.quits == 1, "Quit button calls the injected quit")

    w.permission = true
    w.source.failure = .permissionDenied
    w.presented = []
    c.perform(.capture(.fullscreen))
    check(await waitUntil { !w.presented.isEmpty }, "a .failed(.permissionDenied) outcome presents the permission window too")
    check(w.store.list().isEmpty, "denied capture stored nothing")

    w.source.failure = .noDisplay
    c.perform(.capture(.fullscreen))
    check(await waitUntil { c.hud.lastMessage == "Capture failed" }, "another failure shows a HUD, not the permission window")
    w.source.failure = nil
    check(nothingOnScreen(), "permission flow ordered nothing on screen")
}

@MainActor
func collectText(_ view: NSView?) -> [String] {
    guard let view else { return [] }
    var out: [String] = []
    if let t = view as? NSTextField { out.append(t.stringValue) }
    if let b = view as? NSButton { out.append(b.title) }
    for s in view.subviews { out += collectText(s) }
    return out
}

@MainActor
func checkCardActions() async throws {
    section("Quick Access card actions")
    let w = try World(after: [.showOverlay])
    defer { w.cleanup() }
    let c = w.coordinator
    let text = Pix.textImage(Fixture.textLines)
    c.handleCaptured(CaptureOutput(image: text, kind: .area, pointScale: 1))
    var card = c.overlay.stack[0]
    var view = c.overlay.cardView(for: card)!
    check(Set(view.buttons.keys) == Set(CardAction.allCases) && view.buttons.values.allSatisfy { $0.isHidden }, "card has Copy, Save, Annotate, Pin, OCR, Close; hidden until hover")

    view.mouseEntered(with: Synth.enterExit(.mouseEntered, in: c.overlay.panel(for: card)!))
    check(card.state == .hovering && view.buttons.values.allSatisfy { !$0.isHidden }, "mouseEntered: state .hovering and buttons shown")
    view.mouseExited(with: Synth.enterExit(.mouseExited, in: c.overlay.panel(for: card)!))
    check(card.state == .visible && view.buttons.values.allSatisfy { $0.isHidden }, "mouseExited: state .visible and buttons hidden")

    check(click("card.copy", in: view), "Copy button clicked")
    check(w.pasteboardImage().map { $0.width == text.width && $0.height == text.height } == true, "Copy: the card's image is on the pasteboard")

    check(click("card.save", in: view), "Save button clicked")
    let saved = (try? FileManager.default.contentsOfDirectory(atPath: w.saveDir.path)) ?? []
    check(saved == ["Cornermark 2026-11-03 at 14.05.09.png"], "Save: file in the save folder with the pattern name", detail: "\(saved)")
    check(c.hud.lastMessage == "Saved Cornermark 2026-11-03 at 14.05.09.png", "Save: HUD names the file", detail: c.hud.lastMessage ?? "nil")

    w.pasteboard.clearContents()
    check(click("card.ocr", in: view), "OCR button clicked")
    check(await waitUntil(30) { w.pasteboard.string(forType: .string) != nil }, "OCR: recognized text reached the pasteboard")
    let got = w.pasteboard.string(forType: .string) ?? ""
    check(got == Fixture.textLines.joined(separator: "\n"), "OCR: text keeps line order", detail: got.replacingOccurrences(of: "\n", with: " | "))
    check(c.hud.lastMessage?.hasPrefix("Copied ") == true && c.hud.lastMessage?.hasSuffix("characters") == true, "OCR: confirmation HUD", detail: c.hud.lastMessage ?? "nil")

    let url = c.overlay.dragFile(for: card)
    let item = view.dragItem()
    check(item != nil && url != nil, "drag-out produces a dragging item")
    let dragged = (item?.item as? NSURL) as URL?
    check(dragged?.pathExtension == "png" && dragged?.lastPathComponent.hasPrefix("Cornermark 2026-11-03 at 14.05.09") == true, "drag-out file is a PNG named like a Cornermark screenshot", detail: dragged?.lastPathComponent ?? "nil")
    check(dragged.flatMap(Pix.decode).map { $0.width == text.width && $0.height == text.height } == true, "drag-out file holds the capture pixels")
    check(dragged?.deletingLastPathComponent().standardizedFileURL == w.env.dragDirectory.standardizedFileURL, "drag-out file lives in the injected drag directory")

    check(c.overlay.card(forRecord: card.record.id) != nil, "card still open before drag state changes")
    c.overlay.beginDrag(card)
    check(card.state == .dragging, "beginDrag: state .dragging")
    c.overlay.endDrag(card, dropped: false)
    check(card.state == .visible && c.overlay.stack.count == 1, "drag that landed nowhere leaves the card open")
    c.overlay.beginDrag(card)
    c.overlay.endDrag(card, dropped: true)
    check(card.state == .closing && c.overlay.stack.isEmpty, "drag that landed in an app closes the card")

    _ = c.overlay.restoreLast()
    card = c.overlay.stack[0]
    view = c.overlay.cardView(for: card)!
    check(click("card.pin", in: view), "Pin button clicked")
    check(c.pins.pins.count == 1 && c.overlay.stack.isEmpty, "Pin: a pin was created and the card closed")
    let pin = c.pins.pins[0]
    check(pin.window.frame.size == CGSize(width: text.width, height: text.height) && !pin.window.isVisible, "Pin: window at image size, not visible")

    _ = c.overlay.restoreLast()
    card = c.overlay.stack[0]
    view = c.overlay.cardView(for: card)!
    check(click("card.annotate", in: view), "Annotate button clicked")
    check(c.editors[card.record.id] != nil && c.overlay.stack.isEmpty, "Annotate: editor built for the record, card closed")

    _ = c.overlay.restoreLast()
    card = c.overlay.stack[0]
    view = c.overlay.cardView(for: card)!
    let editorCount = c.editors.count
    let dbl = Synth.mouse(.leftMouseDown, at: .zero, in: c.overlay.panel(for: card)!, clickCount: 2)
    view.mouseDown(with: dbl)
    check(c.editors.count == editorCount && c.overlay.stack.isEmpty, "double click annotates (reuses the open editor) and closes the card")

    _ = c.overlay.restoreLast()
    card = c.overlay.stack[0]
    view = c.overlay.cardView(for: card)!
    check(click("card.close", in: view) && c.overlay.stack.isEmpty && card.state == .closing, "Close button closes the card")
    check(c.overlay.recentlyClosed.last === card, "closed card is kept for restore")
    check(nothingOnScreen(), "card actions ordered nothing on screen")
}

@MainActor
func checkOCRFlow() async throws {
    section("OCR through AppAction (area drag over text, then over a QR code)")
    let w = try World(after: [])
    defer { w.cleanup() }
    let c = w.coordinator
    let before = w.store.list().count

    c.perform(.captureOCR)
    check(await waitUntil { !c.capture.overlayWindows.isEmpty }, "OCR capture opens the area selector offscreen")
    let sel = Fixture.global(Fixture.textBox, grow: 20)
    Synth.drag(c.capture.overlayWindows.first!, from: CGPoint(x: sel.minX, y: sel.maxY), to: CGPoint(x: sel.maxX, y: sel.minY))
    check(await waitUntil(30) { w.pasteboard.string(forType: .string) != nil }, "text from the screen area is copied to the clipboard")
    let got = w.pasteboard.string(forType: .string) ?? ""
    check(got == Fixture.textLines.joined(separator: "\n"), "clipboard text equals the three rendered lines in order", detail: got.replacingOccurrences(of: "\n", with: " | "))
    check(c.hud.lastMessage?.hasPrefix("Copied ") == true, "confirmation HUD shown", detail: c.hud.lastMessage ?? "nil")
    check(w.store.list().count == before, "an OCR capture is not added to history")

    w.pasteboard.clearContents()
    c.perform(.captureOCR)
    _ = await waitUntil { !c.capture.overlayWindows.isEmpty }
    let q = Fixture.global(Fixture.qrBox, grow: 10)
    Synth.drag(c.capture.overlayWindows.first!, from: CGPoint(x: q.minX, y: q.maxY), to: CGPoint(x: q.maxX, y: q.minY))
    check(await waitUntil(30) { w.pasteboard.string(forType: .string) != nil }, "QR area copies something")
    check(w.pasteboard.string(forType: .string) == Fixture.qrPayload, "QR payload is copied as text", detail: w.pasteboard.string(forType: .string) ?? "nil")
    check(c.hud.lastMessage?.hasPrefix("Copied QR code") == true, "HUD says a QR code was copied", detail: c.hud.lastMessage ?? "nil")
    check(nothingOnScreen(), "OCR flow ordered nothing on screen")
}
