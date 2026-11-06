import AppKit
import CornermarkCore
import CornermarkDesign
import CornermarkEditor
import CornermarkL10n

private func pseudo(_ s: String) -> String { "‹\(s)›" }
private func isWrapped(_ s: String) -> Bool { s.hasPrefix("‹") && s.hasSuffix("›") }

/// A string a person reads. Numbers, ratios, colour codes and symbols are the same in every language.
private func needsTranslation(_ s: String) -> Bool {
    s.rangeOfCharacter(from: .letters) != nil && s.range(of: "^#[0-9A-Fa-f]{6}$", options: .regularExpression) == nil
}

private struct Shown: Equatable {
    var kind: String
    var text: String
}

private func shownStrings(in roots: [NSView]) -> [Shown] {
    var out: [Shown] = []
    func add(_ kind: String, _ s: String?) {
        if let s, needsTranslation(s) { out.append(Shown(kind: kind, text: s)) }
    }
    func walk(_ v: NSView) {
        if v.isHidden { return }
        add("tooltip", v.toolTip)
        if let field = v as? NSTextField {
            if field.isEditable { add("placeholder", field.placeholderAttributedString?.string ?? field.placeholderString) }
            else { add("label", field.stringValue) }
        } else if let button = v as? NSButton, !(button is NSPopUpButton), !(button is IconButton) {
            add("button", button.title)
        }
        if v is NSControl { add("accessibility label", v.accessibilityLabel()) }
        if let segments = v as? NSSegmentedControl {
            for i in 0..<segments.segmentCount {
                add("segment", segments.label(forSegment: i))
                add("segment tooltip", segments.toolTip(forSegment: i))
                add("segment accessibility", segments.image(forSegment: i)?.accessibilityDescription)
            }
        }
        if let popup = v as? NSPopUpButton { popup.itemTitles.forEach { add("popup item", $0) } }
        v.menu?.items.forEach { add("menu item", $0.title) }
        v.subviews.forEach(walk)
    }
    roots.forEach(walk)
    return out
}

private struct EditorState: Equatable {
    var annotations: [UUID]
    var tool: EditorTool
    var selection: UUID?
    var zoom: CGFloat
    var scrollOrigin: CGPoint
    var undoDepth: Int
    var frame: CGRect
}

private func scrollView(_ c: EditorWindowController) -> NSScrollView { c.canvasView.enclosingScrollView! }

private func state(of c: EditorWindowController) -> EditorState {
    EditorState(annotations: c.currentDocument.annotations.map(\.id), tool: c.currentTool, selection: c.selection, zoom: c.zoom,
                scrollOrigin: scrollView(c).contentView.bounds.origin, undoDepth: c.history.past.count, frame: c.window!.frame)
}

private func centre(_ v: NSView?) -> CGFloat { v.map { $0.convert(CGPoint(x: $0.bounds.midX, y: $0.bounds.midY), to: nil).x } ?? .nan }

private func subtree(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(subtree) }

private func historySymbols(_ c: EditorWindowController) -> Data? {
    guard let seg = c.view(identifier: "toolbar.history") as? NSSegmentedControl else { return nil }
    return seg.image(forSegment: 0)?.tiffRepresentation
}

/// Switches to a pseudo right-to-left language and back, and checks what a person would see: every string follows the language,
/// the chrome mirrors, the canvas does not, and nothing the person was working on is lost.
private func languageRoundTrip(_ name: String, _ rig: Rig, minimumStrings: Int, extraRoots: @escaping () -> [NSView] = { [] },
                               whileRightToLeft: () -> Void = {}) {
    let c = rig.controller
    let roots = { [c.window!.contentView!] + extraRoots() }
    let canvasBefore = c.canvasView
    let contentBefore = c.window!.contentView
    let before = state(of: c)
    let english = shownStrings(in: roots())
    let symbolsEnglish = historySymbols(c)
    let toolsBefore = centre(c.view(identifier: "toolbar.tools")), copyBefore = centre(c.view(identifier: "toolbar.copy"))
    let barId = ["prop.colors", "crop.aspect"].first { c.view(identifier: $0) != nil }
    let width = c.window!.contentView!.bounds.width
    let canvasFrameBefore = c.canvasView.frame
    let zoomBefore = centre(c.view(identifier: "status.zoom")), barBefore = barId.map { centre(c.view(identifier: $0)) }

    L10n.setPseudoLanguage(.ar, transform: pseudo)
    relayout(rig)
    let shown = shownStrings(in: roots())
    let unwrapped = shown.filter { !isWrapped($0.text) }
    check("\(name) re-renders every visible string in the new language",
          unwrapped.isEmpty && shown.count >= minimumStrings && shown.count == english.count,
          "unwrapped \(unwrapped.prefix(6).map { "\($0.kind): \($0.text)" }), \(shown.count) shown, \(english.count) in English")

    let zoomLabel = (c.view(identifier: "status.zoom") as? NSTextField)?.stringValue ?? ""
    check("\(name) writes its readouts through the language", isWrapped(zoomLabel), zoomLabel)

    check("\(name) keeps its canvas, annotations, tool, selection, zoom, scroll and undo stack",
          state(of: c) == before && c.canvasView === canvasBefore && c.window!.contentView === contentBefore,
          "\(state(of: c)) vs \(before)")

    let content = c.window!.contentView!
    let chrome = ["toolbar.tools", "toolbar.copy", "toolbar.history", "status.zoom", "status.fit"].compactMap { c.view(identifier: $0) } + [content]
    check("\(name) mirrors its toolbar, bars and status bar for a right-to-left language",
          chrome.count == 6 && chrome.allSatisfy { $0.userInterfaceLayoutDirection == .rightToLeft },
          chrome.map { "\($0.accessibilityIdentifier()):\($0.userInterfaceLayoutDirection.rawValue)" }.joined(separator: " "))
    let canvasViews = subtree(scrollView(c))
    check("\(name) keeps the canvas left to right while the chrome is right to left",
          canvasViews.allSatisfy { $0.userInterfaceLayoutDirection == .leftToRight } && c.canvasView.userInterfaceLayoutDirection == .leftToRight,
          "\(canvasViews.filter { $0.userInterfaceLayoutDirection == .rightToLeft }.map { String(describing: type(of: $0)) })")
    check("\(name) puts the tools on the right of the toolbar and Copy on the left",
          toolsBefore < copyBefore && centre(c.view(identifier: "toolbar.tools")) > centre(c.view(identifier: "toolbar.copy")),
          "tools \(centre(c.view(identifier: "toolbar.tools"))) copy \(centre(c.view(identifier: "toolbar.copy")))")
    check("\(name) moves the zoom controls to the left of the status bar and keeps the canvas where it was",
          zoomBefore > width / 2 && centre(c.view(identifier: "status.zoom")) < width / 2 && c.canvasView.frame == canvasFrameBefore,
          "zoom \(zoomBefore) -> \(centre(c.view(identifier: "status.zoom"))) of \(width)")
    if let barId, let barBefore {
        check("\(name) moves the property bar's controls to the right edge",
              barBefore < width / 2 && centre(c.view(identifier: barId)) > width / 2, "\(barBefore) -> \(centre(c.view(identifier: barId)))")
    }
    check("\(name) draws undo and redo in reading order for a right-to-left language",
          symbolsEnglish != nil && historySymbols(c) != nil && symbolsEnglish != historySymbols(c))
    whileRightToLeft()

    L10n.setLanguage(.en)
    relayout(rig)
    check("\(name) returns to its English text", shownStrings(in: roots()) == english)
    check("\(name) returns to a left-to-right layout with the toolbar where it was",
          c.window!.contentView!.userInterfaceLayoutDirection == .leftToRight
              && centre(c.view(identifier: "status.zoom")) == zoomBefore && c.canvasView.frame == canvasFrameBefore
              && c.view(identifier: "toolbar.tools")?.userInterfaceLayoutDirection == .leftToRight
              && centre(c.view(identifier: "toolbar.tools")) == toolsBefore && centre(c.view(identifier: "toolbar.copy")) == copyBefore
              && historySymbols(c) == symbolsEnglish)
    check("\(name) still has its canvas, annotations, tool, selection, zoom, scroll and undo stack after returning to English",
          state(of: c) == before && c.canvasView === canvasBefore)
}

func checkLanguageSwitch() {
    section("Image editor in another language")
    defaults.removePersistentDomain(forName: "cornermark.harness.editor")
    defer {
        L10n.setLanguage(.en)
        defaults.removePersistentDomain(forName: "cornermark.harness.editor")
    }

    // Drawing tool, an annotation, a zoomed and scrolled canvas, a saved colour with its context menu.
    let drawing = makeRig(zoom: 0.6)
    drawing.driver.tapKey("a")
    drawing.driver.drag(source: CGPoint(x: 200, y: 200), to: CGPoint(x: 600, y: 420))
    click(drawing.controller.view(identifier: "prop.favorite"))
    relayout(drawing)
    drawing.controller.zoom = 2
    relayout(drawing)
    let clip = scrollView(drawing.controller).contentView
    clip.scroll(to: NSPoint(x: 220, y: 160))
    scrollView(drawing.controller).reflectScrolledClipView(clip)
    check("the drawing rig has an annotation, a favourite colour and a scrolled canvas",
          drawing.doc.annotations.count == 1 && drawing.controller.allViews(identifier: "prop.favoriteChip").count == 1
              && clip.bounds.origin.x > 0 && drawing.controller.zoom == 2, "\(clip.bounds.origin)")
    let arrow = drawing.doc.annotations.map(\.id)
    languageRoundTrip("the editor with the arrow tool", drawing, minimumStrings: 40) {
        check("the editor keeps the arrow it holds while the interface is right to left", drawing.doc.annotations.map(\.id) == arrow)
        check("the favourite colour's menu is translated", drawing.controller.allViews(identifier: "prop.favoriteChip")
            .allSatisfy { $0.menu?.items.allSatisfy { isWrapped($0.title) } == true })
    }
    closeRig(drawing)

    // Select tool with a selected annotation.
    let selecting = makeRig(zoom: 0.6)
    selecting.driver.tapKey("r")
    selecting.driver.drag(source: CGPoint(x: 200, y: 200), to: CGPoint(x: 500, y: 400))
    selecting.driver.tapKey("v")
    selecting.driver.click(selecting.driver.windowPoint(source: CGPoint(x: 350, y: 200)))
    relayout(selecting)
    check("the selecting rig has a selected annotation", selecting.controller.selection != nil && selecting.controller.currentTool == .select)
    languageRoundTrip("the editor with an annotation selected", selecting, minimumStrings: 30)
    closeRig(selecting)

    // Crop tool.
    let cropping = makeRig(zoom: 0.6)
    cropping.driver.tapKey("c")
    relayout(cropping)
    check("the cropping rig shows the crop controls", cropping.controller.view(identifier: "crop.apply") != nil)
    languageRoundTrip("the editor while cropping", cropping, minimumStrings: 30)
    closeRig(cropping)

    // Background tool: the panel keeps the fill, the slider values and the name being typed.
    let framing = makeRig(zoom: 0.6)
    framing.driver.tapKey("g")
    relayout(framing)
    click(framing.controller.view(identifier: "bg.fill.5"))
    (framing.controller.view(identifier: "bg.presetName") as? NSTextField)?.stringValue = "Draft name"
    (framing.controller.view(identifier: "bg.radius") as? NSSlider)?.doubleValue = 37
    press(framing.controller.view(identifier: "bg.radius") as? NSSlider)
    let background = framing.doc.background
    check("the framing rig shows the panel with a fill", background?.fill == .builtin(index: 5) && framing.controller.view(identifier: "bg.fill.0")?.isHidden == false)
    languageRoundTrip("the editor with the background panel open", framing, minimumStrings: 45) {
        let field = framing.controller.view(identifier: "bg.presetName") as? NSTextField
        check("the background panel keeps the preset name being typed", field?.stringValue == "Draft name", field?.stringValue ?? "nil")
        check("the background panel keeps its fill and corner radius while the interface is right to left",
              framing.doc.background == background && (framing.controller.view(identifier: "bg.radius") as? NSSlider)?.doubleValue == 37)
        let names = (0..<20).compactMap { framing.controller.view(identifier: "bg.fill.\($0)")?.toolTip }
        check("the background panel's gradient names are translated", names.count == 20 && names.allSatisfy(isWrapped), "\(names.prefix(3))")
        let bar = framing.controller.view(identifier: "bg.fill.0")?.superview
        check("the background panel sits on the other side of the canvas", centre(bar) < centre(framing.controller.canvasView.enclosingScrollView))
    }
    check("the background panel keeps the preset name after returning to English",
          (framing.controller.view(identifier: "bg.presetName") as? NSTextField)?.stringValue == "Draft name")
    closeRig(framing)

    // The resize panel is loaded but not presented; its text still follows the language.
    let resizing = makeRig(zoom: 0.6)
    let panel = resizing.controller.loadResizePanelView()
    (panel.subviews.compactMap { $0 as? NSStackView }.first ?? panel).layoutSubtreeIfNeeded()
    resizing.controller.perform(.setOutputScale(0.5))
    let scale = resizing.doc.outputScale
    languageRoundTrip("the editor with the resize panel loaded", resizing, minimumStrings: 50, extraRoots: { [panel] }) {
        check("the resize panel mirrors for a right-to-left language", panel.userInterfaceLayoutDirection == .rightToLeft)
        check("the resize panel keeps its scale while the interface is right to left", resizing.doc.outputScale == scale)
    }
    closeRig(resizing)
}
