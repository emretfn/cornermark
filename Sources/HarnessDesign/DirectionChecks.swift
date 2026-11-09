import AppKit
import CornermarkL10n
@testable import CornermarkDesign

private let ltr = NSUserInterfaceLayoutDirection.leftToRight
private let rtl = NSUserInterfaceLayoutDirection.rightToLeft

private func similar(_ a: RGBA, _ b: RGBA, tolerance: Double = 0.03) -> Bool {
    abs(a.r - b.r) < tolerance && abs(a.g - b.g) < tolerance && abs(a.b - b.b) < tolerance && a.a > 0.9
}

/// The colour of the pixel at `x`, `y` points from the top left of the rendered view.
private func colour(of view: NSView, x: CGFloat, y: CGFloat, _ appearance: NSAppearance.Name = .aqua) -> RGBA {
    let rep = renderedImage(of: view, appearance: appearance)
    let scale = CGFloat(rep.pixelsWide) / view.bounds.width
    return pixel(rep, x: Int(x * scale), y: Int(y * scale))
}

/// The first and last column, in points, holding ink: anything not transparent, or with `background`, anything that differs from it.
private func inkColumns(of view: NSView, over background: RGBA? = nil, inset: CGFloat = 0) -> (min: CGFloat, max: CGFloat)? {
    let rep = renderedImage(of: view, appearance: .aqua)
    let scale = CGFloat(rep.pixelsWide) / view.bounds.width
    var first = Int.max, last = -1
    let margin = Int(inset * scale)
    for y in 0..<rep.pixelsHigh {
        for x in margin..<(rep.pixelsWide - margin) where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.3 {
            if let background, similar(pixel(rep, x: x, y: y), background, tolerance: 0.12) { continue }
            first = min(first, x)
            last = max(last, x)
        }
    }
    return last < 0 ? nil : (CGFloat(first) / scale, CGFloat(last + 1) / scale)
}

private func click(_ type: NSEvent.EventType, at point: CGPoint, in window: NSWindow) -> NSEvent {
    NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
                       eventNumber: 0, clickCount: 1, pressure: 1)!
}

private func arrow(_ keyCode: UInt16, in window: NSWindow) -> NSEvent {
    NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
                     characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: keyCode)!
}

private func hosted(_ view: NSView) -> NSWindow {
    let window = NSWindow(contentRect: CGRect(origin: .zero, size: CGSize(width: view.frame.width + 40, height: view.frame.height + 40)),
                          styleMask: [.titled], backing: .buffered, defer: true)
    view.frame.origin = CGPoint(x: 0, y: 0)
    window.contentView?.addSubview(view)
    return window
}

private var windows: [NSWindow] = []

/// Puts `view` in a real window, where constraints and the layout direction interact the way they do in the app.
private func inWindow<T: NSView>(_ view: T) -> T {
    windows.append(hosted(view))
    return view
}

func checkDirection() {
    section("Right to left: components mirror their geometry")
    checkRedraws()
    checkButtonLike()
    checkCheckbox()
    checkSegmentsDirection()
    checkSliderDirection()
    checkTextDirection()
    checkSelectDirection()
    checkLeftToRightViews()
    directionDiscipline()
}

private func checkRedraws() {
    let views: [(String, NSView)] = [
        ("Button", Button(title: "Capture", symbol: "record.circle", shortcut: "\u{21A9}")),
        ("Checkbox", Checkbox(title: "Shadow")),
        ("IconButton", IconButton(symbol: "timer", label: "Timer")),
        ("SidebarItem", SidebarItem(symbol: "gearshape", title: "General")),
        ("Badge", Badge(text: "Saved", symbol: "checkmark.circle")),
        ("Segments", Segments(labels: ["One", "Two"])),
        ("Slider", Slider(value: 0.5, minValue: 0, maxValue: 1, target: nil, action: nil)),
        ("TextInput", TextInput(placeholder: "Name")),
        ("Select", Select()),
    ]
    for (name, view) in views {
        view.frame.size = CGSize(width: 160, height: 28)
        let window = hosted(view)
        view.displayIfNeeded()
        view.needsDisplay = false
        view.applyLanguageDirection(rtl)
        check("\(name) redraws when its direction changes", view.needsDisplay && view.userInterfaceLayoutDirection == .rightToLeft)
        view.applyLanguageDirection(ltr)
        check("\(name) goes back to left to right", view.userInterfaceLayoutDirection == .leftToRight)
        window.close()
    }
}

private func checkButtonLike() {
    let button = inWindow(Button(title: "Record MP4", variant: .primary, size: .large, symbol: "record.circle", shortcut: "\u{21A9}"))
    let width = button.frame.width
    let before = button.contentRects
    check("a Button in left to right reads symbol, title, shortcut from the left",
          before.symbol!.minX < before.title.minX && before.title.minX < before.shortcut!.minX && before.symbol!.minX < 16)
    button.applyLanguageDirection(rtl)
    let after = button.contentRects
    check("a Button in right to left puts the symbol first on the right and the shortcut last on the left",
          after.symbol!.minX > after.title.minX && after.title.minX > after.shortcut!.minX && after.symbol!.maxX > width - 16,
          "\(after)")
    check("each part of a right-to-left Button is the mirror image of its left to right place",
          after.title == CGRect(x: width - before.title.maxX, y: before.title.minY, width: before.title.width, height: before.title.height)
          && after.symbol!.midX == width - before.symbol!.midX)
    button.applyLanguageDirection(ltr)
    check("the same Button reads from the left again after the language goes back", button.contentRects.symbol == before.symbol)

    let wide = inWindow(Button(title: "Done", variant: .secondary))
    wide.frame.size.width = 200
    wide.applyLanguageDirection(rtl)
    check("a wide Button centres its content in both directions", abs(wide.contentRects.title.midX - 100) < 1)

    let side = inWindow(SidebarItem(symbol: "gearshape", title: "General"))
    side.frame.size.width = 200
    check("a SidebarItem's accessibility label follows its title", { side.title = "Advanced"; return side.accessibilityLabel() == "Advanced" }())
    side.title = "General"
    let named = Button(title: "Done")
    named.setAccessibilityLabel("Done, Return")
    named.title = "Finish"
    let plain = Button(title: "Done")
    plain.title = "Finish"
    check("a Button's accessibility label follows its title, unless a caller named it", named.accessibilityLabel() == "Done, Return" && plain.accessibilityLabel() == "Finish")
    let titled = Checkbox(title: "Shadow")
    titled.title = "Glow"
    check("a Checkbox's accessibility label follows its title", titled.accessibilityLabel() == "Glow")
    let ltrSymbol = side.symbolRect, ltrTitle = side.titleRect
    side.applyLanguageDirection(rtl)
    check("a SidebarItem's symbol leads the title on the left, and on the right in right to left",
          ltrSymbol.minX < ltrTitle.minX && ltrSymbol.minX == DS.Space.s8 && side.symbolRect.maxX == 200 - DS.Space.s8 && side.symbolRect.minX > side.titleRect.minX)
    check("a SidebarItem's title keeps the room the symbol leaves in right to left", side.titleRect.width == ltrTitle.width && side.titleRect.maxX == 200 - ltrTitle.minX)
    check("a SidebarItem's selection is worded in the current language when VoiceOver asks",
          { side.isSelected = false; let off = side.accessibilityValue() as? String; L10n.setPseudoLanguage(.ar) { "\u{2039}\($0)\u{203A}" }
              defer { L10n.setLanguage(.en) }; return off == "Not selected" && side.accessibilityValue() as? String == "\u{2039}Not selected\u{203A}" }())

    let badge = inWindow(Badge(text: "Saved", symbol: "checkmark.circle", tone: .success))
    badge.frame.size.width = 140
    let leading = badge.symbolRect
    badge.applyLanguageDirection(rtl)
    check("a Badge's symbol leads its text on the left, and on the right in right to left",
          leading.minX == DS.Space.s8 && badge.symbolRect.maxX == 140 - DS.Space.s8 && badge.symbolRect.minX > badge.textRect.minX)

    let icon = inWindow(IconButton(symbol: "timer", label: "Timer", size: .large))
    icon.marksSelection = true
    icon.isSelected = true
    let right = icon.markFrame
    icon.applyLanguageDirection(rtl)
    check("a selected IconButton's check badge moves from the bottom right corner to the bottom left",
          right.midX > icon.bounds.midX && icon.markFrame.midX < icon.bounds.midX && icon.markFrame.midX == icon.bounds.width - right.midX && icon.subviews.first?.frame == icon.markFrame,
          "\(right) \(icon.markFrame)")
}

private func checkCheckbox() {
    let box = inWindow(Checkbox(title: "Show shadow"))
    box.frame.size.width += 40
    box.state = .on
    let width = box.frame.width
    check("a Checkbox's box is on the left of its label",
          box.box.minX == 0 && box.labelRect.minX > box.box.maxX && similar(colour(of: box, x: 2, y: box.bounds.midY), resolve(DS.Color.bgInverse, .aqua)))
    box.applyLanguageDirection(rtl)
    check("a Checkbox's box goes to the right of its label in right to left",
          box.box.maxX == width && box.box.minX > box.labelRect.minX && box.labelRect.maxX < box.box.minX, "\(box.box) \(box.labelRect)")
    check("the box is drawn on the right in right to left",
          similar(colour(of: box, x: width - 2, y: box.bounds.midY), resolve(DS.Color.bgInverse, .aqua)) && colour(of: box, x: 2, y: box.bounds.midY).a < 0.1)
    check("an off Checkbox keeps its box against the right edge too", { box.state = .off; return box.box.maxX == width }())
    let text = Checkbox(title: "Show shadow")
    text.frame.size.width += 40
    text.applyLanguageDirection(rtl)
    let ink = inkColumns(of: text)
    check("a right-to-left Checkbox's label is set against its box, not the far edge", ink.map { $0.max > text.frame.width - 1 && $0.min > 30 } ?? false, "\(String(describing: ink))")
}

private func checkSegmentsDirection() {
    let tiles = inWindow(Segments(labels: ["One", "Two", "Three"]))
    tiles.dividers = [0]
    tiles.setToolTip("first", forSegment: 0)
    tiles.setToolTip("third", forSegment: 2)
    let width = tiles.frame.width
    let centre = { (i: Int) in CGPoint(x: tiles.tile(i).midX, y: tiles.bounds.midY) }
    check("Segments run from the left in left to right", tiles.tile(0).minX == 0 && tiles.tile(0).minX < tiles.tile(1).minX && tiles.tile(1).minX < tiles.tile(2).minX)
    check("Segments pick the tile under the pointer in left to right", tiles.segment(at: centre(2)) == 2 && tiles.segment(at: centre(0)) == 0)
    let divider = tiles.dividerRect(after: 0)
    check("the divider after the first Segment is on its right in left to right", divider.minX > tiles.tile(0).maxX && divider.maxX < tiles.tile(1).minX)
    tiles.applyLanguageDirection(rtl)
    check("Segments run in reverse order in right to left, the first against the right edge",
          tiles.tile(0).maxX == width && tiles.tile(0).minX > tiles.tile(1).minX && tiles.tile(1).minX > tiles.tile(2).minX && tiles.tile(2).minX == 0,
          (0..<3).map { "\(tiles.tile($0))" }.joined(separator: " "))
    check("Segments pick the tile under the pointer in right to left", (0..<3).allSatisfy { tiles.segment(at: centre($0)) == $0 })
    let mirrored = tiles.dividerRect(after: 0)
    check("the divider follows its Segment to the left of it in right to left", mirrored.maxX < tiles.tile(0).minX && mirrored.minX > tiles.tile(1).maxX && mirrored.midX == width - divider.midX)
    let tip = { (i: Int) in tiles.view(tiles, stringForToolTip: 0, point: centre(i), userData: nil) }
    check("tooltips follow the mirrored tiles when the direction changes on a live control", tip(0) == "first" && tip(2) == "third")

    let track = inWindow(Segments(labels: ["Light", "Dark"], width: 160, style: .track))
    track.selectedSegment = 0
    check("a track's thumb sits under the first choice, on the left", track.thumbRect!.minX < track.bounds.midX && track.segment(at: CGPoint(x: 1, y: 14)) == 0)
    track.applyLanguageDirection(rtl)
    check("a track's thumb sits under the first choice, on the right, in right to left",
          track.thumbRect!.midX > track.bounds.midX && abs(track.thumbRect!.midX - track.tile(0).midX) < 1, "\(String(describing: track.thumbRect))")
    check("a track's end choices take the inset beside them in right to left", track.segment(at: CGPoint(x: 159, y: 14)) == 0 && track.segment(at: CGPoint(x: 1, y: 14)) == 1)
    track.selectedSegment = 1
    check("selecting the second choice moves the thumb to the left in right to left", track.thumbRect!.midX < track.bounds.midX)
    check("the track draws its thumb at the mirrored place",
          similar(colour(of: track, x: track.tile(1).midX, y: 4), resolve(DS.Color.bgControlThumb, .aqua)) && similar(colour(of: track, x: track.tile(0).midX, y: 4), resolve(DS.Color.bgControl, .aqua)))

    let symbols = Segments(symbols: ["pencil", "trash"], labels: ["Pencil", "Trash"], trackingMode: .selectOne)
    let first = symbols.tile(0).midX
    symbols.applyLanguageDirection(rtl)
    check("symbol Segments mirror too", symbols.tile(0).midX == symbols.frame.width - first)
}

private func checkSliderDirection() {
    let field = Slider(value: 0.25, minValue: 0, maxValue: 1, target: nil, action: nil)
    field.style = .field
    field.frame = CGRect(x: 0, y: 0, width: 200, height: DS.Size.control)
    field.format = { String(format: "%.0f%%", $0 * 100) }
    let window = hosted(field)
    let filled = resolve(DS.Color.bgControlActive, .aqua), empty = resolve(DS.Color.bgControl, .aqua)
    check("a field Slider fills from the left in left to right",
          field.edgeX == 50 && similar(colour(of: field, x: 20, y: 2), filled) && similar(colour(of: field, x: 120, y: 2), empty))
    field.applyLanguageDirection(rtl)
    check("a field Slider's fill grows from the right in right to left",
          field.edgeX == 150 && field.fillLength == 50 && similar(colour(of: field, x: 180, y: 2), filled) && similar(colour(of: field, x: 80, y: 2), empty))
    let layout = field.fieldLayout(.normal)
    check("a field Slider's value text and edge marker are mirrored", layout.textRect.minX < 20 && layout.marker.allSatisfy { $0.minX >= 148 && $0.minX <= 150 } && !layout.marker.isEmpty,
          "\(layout)")
    field.detents = [0.5]
    let tickY = field.bounds.height - 2
    check("a field Slider's detent tick is drawn mirrored, at 99 where left to right draws it at 100",
          !similar(colour(of: field, x: 99.5, y: tickY), colour(of: field, x: 90, y: tickY), tolerance: 0.01)
          && similar(colour(of: field, x: 100.5, y: tickY), colour(of: field, x: 90, y: tickY), tolerance: 0.01))

    field.mouseDown(with: click(.leftMouseDown, at: CGPoint(x: 190, y: 14), in: window))
    field.mouseUp(with: click(.leftMouseUp, at: CGPoint(x: 190, y: 14), in: window))
    check("pressing near the right end of a right-to-left field Slider sets a low value", field.doubleValue < 0.1, "\(field.doubleValue)")
    field.doubleValue = 0.5
    field.keyDown(with: arrow(123, in: window))
    let afterLeft = field.doubleValue
    field.keyDown(with: arrow(124, in: window))
    check("Left raises and Right lowers a right-to-left field Slider, Up still raises", afterLeft > 0.5 && field.doubleValue == 0.5 && { field.keyDown(with: arrow(126, in: window)); return field.doubleValue > 0.5 }(),
          "\(afterLeft) \(field.doubleValue)")
    field.applyLanguageDirection(ltr)
    field.doubleValue = 0.5
    field.keyDown(with: arrow(124, in: window))
    check("Right raises a left-to-right field Slider", field.doubleValue > 0.5)
    field.mouseDown(with: click(.leftMouseDown, at: CGPoint(x: 190, y: 14), in: window))
    field.mouseUp(with: click(.leftMouseUp, at: CGPoint(x: 190, y: 14), in: window))
    check("pressing near the right end of a left-to-right field Slider sets a high value", field.doubleValue > 0.9, "\(field.doubleValue)")

    let track = Slider(value: 0.25, minValue: 0, maxValue: 1, target: nil, action: nil)
    track.frame = CGRect(x: 0, y: 0, width: 200, height: 20)
    let fill = resolve(DS.Color.textSecondary, .aqua), rail = resolve(DS.Color.bgControlActive, .aqua)
    check("a track Slider fills from the left in left to right", similar(colour(of: track, x: 20, y: 10), fill) && similar(colour(of: track, x: 180, y: 10), rail))
    track.applyLanguageDirection(rtl)
    let knob = (track.cell as! SliderCell).knobRect(flipped: track.isFlipped)
    check("a track Slider's knob and fill start at the right in right to left",
          knob.midX > 100 && similar(colour(of: track, x: 190, y: 10), fill) && similar(colour(of: track, x: 20, y: 10), rail), "\(knob)")
}

private func checkTextDirection() {
    let field = TextInput(placeholder: "Name")
    check("a TextInput aligns naturally in left to right", field.alignment == .natural)
    field.applyLanguageDirection(rtl)
    check("a TextInput aligns to the right in right to left", field.alignment == .right && field.baseWritingDirection == .rightToLeft)
    field.applyLanguageDirection(ltr)
    check("a TextInput goes back to natural alignment", field.alignment == .natural && field.baseWritingDirection == .natural)
    let centred = TextInput(placeholder: "W", monospaced: true, centered: true)
    centred.applyLanguageDirection(rtl)
    check("a centred TextInput stays centred in right to left", centred.alignment == .center)

    let sized = TextInput(placeholder: "Name")
    sized.frame = CGRect(x: 0, y: 0, width: 200, height: DS.Size.control)
    sized.stringValue = "abc"
    let background = resolve(DS.Color.bgControl, .aqua)
    let leftInk = inkColumns(of: sized, over: background, inset: 6)
    sized.applyLanguageDirection(rtl)
    let rightInk = inkColumns(of: sized, over: background, inset: 6)
    check("typed text sits against the left edge in left to right and the right edge in right to left",
          (leftInk?.max ?? 999) < 100 && (rightInk?.min ?? 0) > 100, "\(String(describing: leftInk)) \(String(describing: rightInk))")
    let window = hosted(sized)
    window.makeFirstResponder(sized)
    check("the field editor's caret follows the field's direction", sized.currentEditor()?.baseWritingDirection == .rightToLeft)
    window.makeFirstResponder(nil)

    let label = NSTextField.label("Hello", style: DS.Text.body, color: DS.Color.textPrimary)
    check("a Label aligns naturally, so its text follows its language", label.alignment == .natural)
    let drawn = render(size: CGSize(width: 120, height: 20), scale: 2, flipped: true) {
        Paint.text("Hello", DS.Text.body, DS.Color.textPrimary, in: CGRect(x: 0, y: 0, width: 120, height: 20), rtl: true)
    }
    var first = drawn.pixelsWide, last = 0
    for y in 0..<drawn.pixelsHigh { for x in 0..<drawn.pixelsWide where (drawn.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.3 { first = min(first, x); last = max(last, x) } }
    check("Paint.text sets a line against the right edge of its rect in right to left", first > drawn.pixelsWide / 2 && last >= drawn.pixelsWide - 4, "\(first)...\(last)")
}

private func checkSelectDirection() {
    let select = Select()
    select.addItems(withTitles: ["Free", "Square", "Wide"])
    select.frame.size = CGSize(width: 140, height: DS.Size.control)
    let leading = select.triggerRects
    check("a Select's chevron ends the field on the right and its title starts on the left",
          leading.chevron.maxX == 140 - DS.Space.s8 && leading.title.minX == DS.Space.s8 && leading.title.maxX < leading.chevron.minX)
    select.applyLanguageDirection(rtl)
    let rects = select.triggerRects
    check("a Select's chevron moves to the left and its title to the right in right to left",
          rects.chevron.minX == DS.Space.s8 && rects.title.maxX == 140 - DS.Space.s8 && rects.title.minX > rects.chevron.maxX, "\(rects)")
    select.menu?.items[0].image = NSImage(systemSymbolName: "pencil", accessibilityDescription: nil)
    select.selectItem(at: 0)
    check("a picked item's image leads the title on the right in right to left", select.triggerRects.image.map { $0.maxX == 140 - DS.Space.s8 && $0.minX > select.triggerRects.title.minX } ?? false)

    let trigger = CGRect(x: 600, y: 500, width: 140, height: 28), screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    let menu = CGSize(width: 220, height: 120)
    check("a Select's menu opens with its left edge on the trigger's in left to right", Select.place(menu, under: trigger, within: screen).rect.minX == 600)
    check("a Select's menu opens with its right edge on the trigger's in right to left", Select.place(menu, under: trigger, within: screen, direction: rtl).rect.maxX == 740)
    check("a Select's menu stays on screen at the left edge in right to left",
          Select.place(menu, under: CGRect(x: 4, y: 500, width: 100, height: 28), within: screen, direction: rtl).rect.minX == 0)

    let window = hosted(select)
    select.open(animated: false)
    let list = select.menuWindow!.list
    check("a Select's open menu takes the trigger's direction", list.userInterfaceLayoutDirection == .rightToLeft)
    let row = list.rects(ofRow: 1)
    check("a menu row's check is on the left and its title on the right in right to left",
          row.check.minX < row.title.minX && row.title.maxX == list.frame(of: 1).maxX - DS.Space.s8, "\(row)")
    let selected = list.rects(ofRow: select.indexOfSelectedItem)
    check("a menu row's image leads its title on the right in right to left", selected.image.map { $0.minX > selected.title.minX } ?? false)
    select.close()
    window.close()
}

private func checkLeftToRightViews() {
    let caps = KeyCaps(["\u{2325}\u{2190}", "\u{2325}\u{2192}"])
    caps.applyLanguageDirection(rtl)
    check("KeyCaps keep the keyboard's order in right to left", caps.userInterfaceLayoutDirection == .leftToRight)
    let grid = PositionGrid(labels: (0..<9).map { "cell \($0)" }, identifier: "grid")
    grid.applyLanguageDirection(rtl)
    check("a PositionGrid is a picture of the frame, so it and its cells stay left to right",
          grid.userInterfaceLayoutDirection == .leftToRight && grid.cells.allSatisfy { $0.userInterfaceLayoutDirection == .leftToRight })

    let size = CGSize(width: 120, height: 60)
    for style in Surface.Style.allCases {
        let surface = Surface(style: style, shadowInset: 12)
        surface.frame.size = size
        let left = renderedImage(of: surface, appearance: .aqua).tiffRepresentation
        surface.applyLanguageDirection(rtl)
        check("a \(style) Surface looks the same in both directions", left == renderedImage(of: surface, appearance: .aqua).tiffRepresentation)
    }
}

/// Every component that places text or a symbol by side says how it follows the direction. A new one that draws left to right only fails here.
private func directionDiscipline() {
    let dir = "Sources/CornermarkDesign/Components"
    guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir).filter({ $0.hasSuffix(".swift") }), !files.isEmpty else {
        check("component sources are readable from the package root", false, dir)
        return
    }
    // Glyph draws into the rect its caller gives it, and the caller mirrors that.
    for file in files.sorted() where file != "Glyph.swift" {
        let text = (try? String(contentsOfFile: "\(dir)/\(file)", encoding: .utf8)) ?? ""
        let places = text.contains("Paint.text(") || text.contains("Paint.symbol(") || text.contains("Glyph.draw(")
        guard places else { continue }
        let follows = text.contains("mirrored(") || text.contains("KeepsLeftToRight") || text.contains("isRightToLeft")
        check("\(file) follows the layout direction wherever it places text or a symbol", follows)
    }
    let unmirrored = files.filter { file in
        let text = (try? String(contentsOfFile: "\(dir)/\(file)", encoding: .utf8)) ?? ""
        return text.contains("alignment: .left") || text.contains("alignment = .left")
    }
    check("no component pins text to the left with .left alignment", unmirrored.isEmpty, unmirrored.joined(separator: ", "))
}
