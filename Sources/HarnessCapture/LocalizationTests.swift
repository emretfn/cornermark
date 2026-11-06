import AppKit
import CornermarkCore
import CornermarkDesign
import CornermarkL10n
@testable import CornermarkCapture

private func pseudo() { L10n.setPseudoLanguage(.ar) { "\u{2039}\($0)\u{203A}" } }

private func isWrapped(_ text: String) -> Bool { text.hasPrefix("\u{2039}") && text.hasSuffix("\u{203A}") }

/// Every string a person can read or hear in `root`: labels, titles, tooltips, accessibility labels and help, popup and menu items.
/// User content (editable fields) and text with no letters (numbers, symbols, ratios) are left out.
@MainActor
private func readableStrings(in root: NSView) -> [String] {
    var out: [String] = []
    func add(_ text: String?) {
        if let text, text.contains(where: \.isLetter) { out.append(text) }
    }
    func addMenu(_ menu: NSMenu?) {
        guard let menu else { return }
        add(menu.title)
        for item in menu.items where !item.isSeparatorItem { add(item.title) }
    }
    func walk(_ view: NSView) {
        if view.isHidden { return }
        add(view.toolTip)
        if view.isAccessibilityElement() {
            add(view.accessibilityLabel())
            add(view.accessibilityHelp())
        }
        if let field = view as? NSTextField {
            if field.isEditable { add(field.placeholderAttributedString?.string) } else { add(field.stringValue) }
        } else if let button = view as? NSButton {
            if !(button is IconButton) { add(button.title) }
            addMenu(button.menu)
            if let popup = button as? NSPopUpButton { popup.itemArray.forEach { add($0.title) } }
        }
        view.subviews.forEach(walk)
    }
    walk(root)
    return out
}

@MainActor
private func unwrapped(in root: NSView) -> [String] { readableStrings(in: root).filter { !isWrapped($0) } }

@MainActor
private func frame(_ id: String, in windows: [NSWindow]) -> CGRect? { findView(id, in: windows)?.frame }

@MainActor
func runLocalizationTests() async {
    defer { L10n.setLanguage(.en) }
    section("localization: numbers an overlay shows")
    check(Readout.size(width: 1920, height: 1080) == "1920 × 1080" && Readout.point(x: 412, y: 96) == "412, 96",
          "English readouts are written as before, with no grouping")
    check(Readout.parse(" 12 ") == 12 && Readout.parse("\u{0664}\u{0660}\u{0660}") == 400 && Readout.parse("abc") == nil,
          "a size typed in any digits reads back, and text that is not a number does not")
    pseudo()
    check(isWrapped(Readout.size(width: 1920, height: 1080)) && Readout.size(width: 1920, height: 1080).contains("\u{00D7}"),
          "the size readout goes through the language and keeps its multiplication sign")
    L10n.setLanguage(.en)

    let s1 = Fixtures.display(id: 1, frame: d1.frame, scale: 1, windows: [winB, winA], seed: 1)
    let s2 = Fixtures.display(id: 2, frame: d2.frame, scale: 2, windows: [], seed: 2)
    let source = FixtureScreenSource(displays: [s1, s2], windows: [winB, winA])

    section("localization: the capture toolbar")
    do {
        let rc = makeController(source, pointer: CGPoint(x: 300, y: 200))
        let out = await start(rc, .allInOne)
        guard let panel = overlay(rc, frame: d1.frame) as? OverlayPanel else { return check(false, "the capture overlay opens") }
        Synth.drag(panel, from: CGPoint(x: 60, y: 60), to: CGPoint(x: 540, y: 340))
        let selection = adjustingRect(rc)
        let ids = ["mode.area", "mode.scrolling", "capture"].map { "cornermark.toolbar." + $0 }
        let english = ids.compactMap { frame($0, in: rc.overlayWindows) }
        check(english.count == 3 && english[0].minX < english[1].minX && english[1].minX < english[2].minX && !unwrapped(in: panel.root).isEmpty,
              "in English the toolbar reads from the left, area then scrolling then capture")
        pseudo()
        let texts = readableStrings(in: panel.root)
        check(!texts.isEmpty && unwrapped(in: panel.root).isEmpty, "the toolbar re-renders every label, tooltip and menu item in the new language",
              detail: unwrapped(in: panel.root).joined(separator: " | "))
        check(texts.contains("\u{2039}Capture\u{203A}") && texts.contains("\u{2039}Aspect ratio\u{203A}") && texts.contains("\u{2039}Free\u{203A}"),
              "including the button, the aspect tooltip and the aspect items")
        check(panel.root.userInterfaceLayoutDirection == .rightToLeft && panel.chrome.userInterfaceLayoutDirection == .leftToRight
              && panel.root.subviews.first.map { $0.userInterfaceLayoutDirection == .leftToRight } == true,
              "the overlay root mirrors while the screenshot and the selection layer stay left to right")
        let mirrored = ids.compactMap { frame($0, in: rc.overlayWindows) }
        check(mirrored.count == 3 && mirrored[0].minX > mirrored[1].minX && mirrored[1].minX > mirrored[2].minX,
              "the toolbar's controls run right to left", detail: "\(mirrored)")
        check(adjustingRect(rc) == selection && selection != nil && rc.overlayWindows.contains { $0 === panel },
              "the toolbar re-renders in the new language and keeps the selection", detail: "\(String(describing: adjustingRect(rc)))")
        check((findView("cornermark.toolbar.width", in: rc.overlayWindows) as? NSTextField)?.stringValue == Readout.number(480),
              "and the size fields show the size in the language's digits")
        L10n.setLanguage(.en)
        let back = ids.compactMap { frame($0, in: rc.overlayWindows) }
        check(readableStrings(in: panel.root).contains("Capture") && unwrapped(in: panel.root).count == readableStrings(in: panel.root).count
              && panel.root.userInterfaceLayoutDirection == .leftToRight && back.count == 3 && back[0].minX < back[2].minX,
              "going back to English brings the English text, the left to right direction and the left to right order back")
        Synth.escape(panel)
        check(out.isCancelled, "Escape still leaves")
    }

    section("localization: the recording panel")
    do {
        let rc = makeController(source, pointer: CGPoint(x: 300, y: 200))
        var sourcesOn: Set<RecordingSource> = [.microphone]
        rc.recordingSources = { RecordingSources(on: sourcesOn, note: .hint(tr("Record GIF never records sound."))) }
        rc.toggleRecordingSource = { sourcesOn.formSymmetricDifference([$0]); rc.refreshOverlay() }
        let out = await start(rc, .recording)
        guard let panel = overlay(rc, frame: d1.frame) as? OverlayPanel else { return check(false, "the recording overlay opens") }
        Synth.drag(panel, from: CGPoint(x: 60, y: 60), to: CGPoint(x: 540, y: 340))
        let selection = adjustingRect(rc)
        let ids = ["start.video", "start.gif", "target.area", "options"].map { "cornermark.record." + $0 }
        pseudo()
        let texts = readableStrings(in: panel.root)
        check(texts.count > 20 && unwrapped(in: panel.root).isEmpty, "the recording panel re-renders every label, tooltip and help in the new language",
              detail: unwrapped(in: panel.root).joined(separator: " | "))
        let options = (findView("cornermark.record.options", in: rc.overlayWindows) as? NSButton)?.menu
        check(options.map { $0.items.count > 8 && $0.items.filter { !$0.isSeparatorItem }.allSatisfy { isWrapped($0.title) } } == true,
              "and the options menu's headings and items", detail: options?.items.map(\.title).joined(separator: " | ") ?? "nil")
        check((findView("cornermark.record.source.microphone", in: rc.overlayWindows) as? IconButton).map { $0.isSelected && $0.toolTip.map(isWrapped) == true } == true,
              "a source that was on is still on, in the new language")
        let r = ids.compactMap { frame($0, in: rc.overlayWindows) }
        check(r.count == 4 && r[0].minX > r[1].minX && r[3].minX > r[2].minX,
              "the start buttons and the top row run right to left: MP4 before GIF, options first on the right", detail: "\(r)")
        check(adjustingRect(rc) == selection && panel.root.userInterfaceLayoutDirection == .rightToLeft, "the selection survives the switch")
        if let field = findView("cornermark.record.width", in: rc.overlayWindows) as? NSTextField {
            check(field.stringValue == Readout.number(480), "the width field shows the language's digits", detail: field.stringValue)
            field.stringValue = "\u{0664}\u{0660}\u{0660}"
            field.sendAction(field.action, to: field.target)
            check(adjustingRect(rc)?.width == 400, "and takes a width typed in them", detail: "\(String(describing: adjustingRect(rc)))")
        }

        section("localization: the help window")
        (findView("cornermark.record.help", in: rc.overlayWindows) as? NSButton)?.performClick(nil)
        if let help = rc.overlayWindows.first(where: { $0 is RecordingHelpWindow }) as? RecordingHelpWindow, let content = help.contentView {
            check(unwrapped(in: content).isEmpty && readableStrings(in: content).count >= 4 && isWrapped(help.title), "the help window is worded in the new language",
                  detail: unwrapped(in: content).joined(separator: " | "))
            let art = descendants(of: content).first { $0 is RecordingHelpIllustration }
            check(content.userInterfaceLayoutDirection == .rightToLeft && art?.userInterfaceLayoutDirection == .leftToRight,
                  "it mirrors while its picture of the editor stays left to right")
            L10n.setLanguage(.en)
            check(rc.overlayWindows.allSatisfy { !($0 is RecordingHelpWindow) } && readableStrings(in: panel.root).contains("Record MP4")
                  && panel.root.userInterfaceLayoutDirection == .leftToRight, "switching back closes the stale help window and brings the panel's English back")
        } else {
            check(false, "the help button opens the help window")
        }
        Synth.escape(panel)
        check(out.isCancelled, "Escape leaves the recording overlay")
    }

    section("localization: the countdown")
    do {
        pseudo()
        let rc = makeController(source, pointer: CGPoint(x: 10, y: 10))
        rc.countdownTickInterval = 5
        let out = await start(rc, .timed(seconds: 3))
        if let window = rc.overlayWindows.first, let view = window.contentView as? CountdownView {
            check(isWrapped(view.hint) && view.remaining == 3, "the countdown's hint is worded in the language when it opens", detail: view.hint)
            check(view.userInterfaceLayoutDirection == .rightToLeft, "and the countdown takes the direction")
            Synth.escape(window)
        } else {
            check(false, "the timer opens a countdown")
        }
        check(out.isCancelled, "Escape cancels the countdown")
        L10n.setLanguage(.en)
    }

    section("localization: the scrolling capture HUD")
    do {
        let s3 = Fixtures.display(id: 3, frame: CGRect(x: 0, y: 0, width: 600, height: 500), scale: 1, windows: [], seed: 3)
        let scrollSource = FixtureScreenSource(displays: [s3])
        let page = Fixtures.page(width: 300, height: 1500, seed: 5)
        scrollSource.liveFrame = { _, _ in
            let ctx = Pixels.context(600, 500)
            ctx.draw(s3.image, in: CGRect(x: 0, y: 0, width: 600, height: 500))
            ctx.draw(page.cropping(to: CGRect(x: 0, y: 0, width: 300, height: 300))!, in: CGRect(x: 50, y: 100, width: 300, height: 300))
            return ctx.makeImage()
        }
        let rc = makeController(scrollSource)
        let out = await start(rc, .scrolling)
        let area = overlay(rc, frame: s3.frame)!
        Synth.drag(area, from: CGPoint(x: 50, y: 100), to: CGPoint(x: 350, y: 400))
        guard let hud = rc.overlayWindows.first(where: { !$0.ignoresMouseEvents }), let content = hud.contentView else {
            return check(false, "the scrolling HUD opens")
        }
        let done = findView("cornermark.scroll.done", in: [hud])!.frame, cancel = findView("cornermark.scroll.cancel", in: [hud])!.frame
        check(cancel.maxX < done.minX, "in English Done is the last button, on the right")
        pseudo()
        check(!readableStrings(in: content).isEmpty && unwrapped(in: content).isEmpty, "the HUD re-renders in the new language, buttons, title and hint",
              detail: unwrapped(in: content).joined(separator: " | "))
        let doneRTL = findView("cornermark.scroll.done", in: [hud])!.frame, cancelRTL = findView("cornermark.scroll.cancel", in: [hud])!.frame
        check(content.userInterfaceLayoutDirection == .rightToLeft && doneRTL.maxX < cancelRTL.minX && doneRTL.minX == content.bounds.width - done.maxX,
              "and mirrors: Done is the last button, on the left", detail: "\(doneRTL) \(cancelRTL)")
        L10n.setLanguage(.en)
        check(findView("cornermark.scroll.done", in: [hud])!.frame == done && (findView("cornermark.scroll.done", in: [hud]) as? NSButton)?.title == "Done",
              "going back puts the English text and the left to right layout back")
        Synth.escape(hud)
        _ = await waitUntil { out.value != nil }
        check(out.isCancelled, "Escape cancels the scrolling capture")
    }
}

@MainActor
private func descendants(of view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants(of: $0) } }

@MainActor
private func adjustingRect(_ c: CaptureController) -> CGRect? {
    if case .adjusting(let s, _)? = c.overlayState { return s.rect }
    return nil
}
