import AppKit
@testable import CornermarkDesign

/// The editor's own controls: the field slider, the select, the segment track and the toggle tiles. Each check drives the control
/// through the same entry points a person reaches (pointer, keys, VoiceOver) and reads what it then says or draws.
func checkEditorControls() {
    fieldSlider()
    select()
    segmentTrack()
}

private final class Counter: NSObject {
    var fired = 0
    @objc func fire() { fired += 1 }
}

private func hostWindow(_ view: NSView, width: CGFloat = 320, height: CGFloat = 120) -> NSWindow {
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: width, height: height), styleMask: [.borderless], backing: .buffered, defer: false)
    window.appearance = NSAppearance(named: .aqua)
    window.contentView!.addSubview(view)
    return window
}

private func mouse(_ type: NSEvent.EventType, at x: CGFloat, in view: NSView) -> NSEvent {
    let point = view.convert(CGPoint(x: x, y: view.bounds.midY), to: nil)
    return NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                              windowNumber: view.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
}

func keyEvent(_ code: UInt16, _ characters: String = "", flags: NSEvent.ModifierFlags = [], window: NSWindow? = nil) -> NSEvent {
    NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                     windowNumber: window?.windowNumber ?? 0, context: nil, characters: characters, charactersIgnoringModifiers: characters,
                     isARepeat: false, keyCode: code)!
}

private func fieldSlider() {
    final class Watched: Slider { var ended = 0; override func trackingDidEnd() { ended += 1 } }
    let counter = Counter()
    let s = Watched(frame: CGRect(x: 10, y: 10, width: 200, height: DS.Size.control))
    s.style = .field
    s.minValue = 0
    s.maxValue = 1
    s.doubleValue = 0.1
    s.isContinuous = true
    s.target = counter
    s.action = #selector(Counter.fire)
    s.format = { "\(Int(($0 * 100).rounded()))%" }
    let window = hostWindow(s)
    check("a field slider is control tall and still an NSSlider", s.intrinsicContentSize.height == DS.Size.control && (s as AnyObject) is NSSlider)
    check("VoiceOver reads a field slider as a slider with its written value", s.accessibilityRole() == .slider && s.accessibilityValueDescription() == "10%",
          "\(String(describing: s.accessibilityRole())) \(s.accessibilityValueDescription() ?? "nil")")

    s.mouseDown(with: mouse(.leftMouseDown, at: 150, in: s))
    check("a press anywhere on the field sets the value under the pointer", abs(s.doubleValue - 0.75) < 1e-9 && counter.fired == 1, "\(s.doubleValue) fired \(counter.fired)")
    s.mouseDragged(with: mouse(.leftMouseDragged, at: 50, in: s))
    check("dragging moves the value with the pointer", abs(s.doubleValue - 0.25) < 1e-9 && counter.fired == 2 && s.ended == 0, "\(s.doubleValue)")
    s.mouseDragged(with: mouse(.leftMouseDragged, at: -40, in: s))
    check("past the field's end the value stops at the minimum", s.doubleValue == 0)
    s.mouseUp(with: mouse(.leftMouseUp, at: 60, in: s))
    check("letting go sends the last value and ends the tracking once", abs(s.doubleValue - 0.3) < 1e-9 && s.ended == 1 && counter.fired == 4, "ended \(s.ended) fired \(counter.fired)")

    s.detents = [0.5]
    s.mouseDown(with: mouse(.leftMouseDown, at: 102, in: s))
    s.mouseUp(with: mouse(.leftMouseUp, at: 102, in: s))
    check("a press near a detent lands on it", s.doubleValue == 0.5, "\(s.doubleValue)")
    s.mouseDown(with: mouse(.leftMouseDown, at: 110, in: s))
    s.mouseUp(with: mouse(.leftMouseUp, at: 110, in: s))
    check("a press clear of a detent keeps its own value", abs(s.doubleValue - 0.55) < 1e-9, "\(s.doubleValue)")

    s.doubleValue = 0.5
    s.keyDown(with: keyEvent(124, window: window))
    check("Right arrow steps a twentieth of the range and sends the action", abs(s.doubleValue - 0.55) < 1e-9 && s.ended == 4, "\(s.doubleValue) ended \(s.ended)")
    s.keyDown(with: keyEvent(123, flags: .shift, window: window))
    check("Shift-Left arrow steps five times as far", abs(s.doubleValue - 0.3) < 1e-9, "\(s.doubleValue)")
    s.keyDown(with: keyEvent(119, window: window))
    check("End goes to the maximum", s.doubleValue == 1)
    s.keyDown(with: keyEvent(115, window: window))
    check("Home goes to the minimum", s.doubleValue == 0)

    let stepped = Slider(frame: CGRect(x: 0, y: 0, width: 200, height: DS.Size.control))
    stepped.style = .field
    stepped.minValue = 0
    stepped.maxValue = 2
    stepped.numberOfTickMarks = 3
    stepped.allowsTickMarkValuesOnly = true
    _ = hostWindow(stepped)
    stepped.mouseDown(with: mouse(.leftMouseDown, at: 120, in: stepped))
    stepped.mouseUp(with: mouse(.leftMouseUp, at: 120, in: stepped))
    check("a stepped field lands on its nearest step", stepped.doubleValue == 1, "\(stepped.doubleValue)")
    stepped.keyDown(with: keyEvent(124))
    check("an arrow moves a stepped field one step", stepped.doubleValue == 2)
    check("a stepped field marks its inner steps", stepped.tickValues == [1], "\(stepped.tickValues)")

    // The value must read at every fill: the marker never enters the text's room, and the text never moves.
    var crossings: [String] = []
    var places = Set<CGFloat>()
    for step in 0...100 {
        s.doubleValue = Double(step) / 100
        for state in [InteractionState.normal, .hover, .pressed] {
            let layout = s.fieldLayout(state)
            places.insert(layout.textRect.minX)
            let room = layout.textRect.insetBy(dx: -DS.Space.s2, dy: 0)
            if layout.marker.contains(where: { $0.intersects(room) }) { crossings.append("\(step)% \(state)") }
            let whole = ([layout.textRect] + layout.marker).allSatisfy { $0.minX == $0.minX.rounded() && $0.minY == $0.minY.rounded() }
            if !whole { crossings.append("\(step)% \(state) off the point grid") }
        }
    }
    check("at every fill from 0 to 100% the edge marker keeps clear of the value text, on whole points", crossings.isEmpty, crossings.prefix(6).joined(separator: ", "))
    check("the value text stays in one place at every fill of the same width", places.count <= 3, "\(places.sorted())")
    s.doubleValue = 0.95
    let high = s.fieldLayout(.normal)
    check("near the top of the range the marker still shows above and below the value", high.marker.count == 2, "\(high.marker)")

    for (name, appearance) in [("aqua", NSAppearance.Name.aqua), ("darkAqua", .darkAqua)] {
        // Detached from the window, whose backing colour space would nudge the neutrals.
        let loose = Slider(frame: CGRect(x: 0, y: 0, width: 200, height: DS.Size.control))
        loose.style = .field
        loose.doubleValue = 0.5
        let rep = renderedImage(of: loose, appearance: appearance)
        let scale = CGFloat(rep.pixelsWide) / loose.bounds.width
        func at(_ x: CGFloat) -> RGBA { pixel(rep, x: Int(x * scale), y: Int(loose.bounds.height / 2 * scale)) }
        let fill = resolve(DS.Color.bgControlActive, appearance), track = resolve(DS.Color.bgControl, appearance)
        check("[\(name)] the field's fill is the neutral bgControlActive and its rest bgControl", near(at(40), fill) && near(at(160), track),
              "\(at(40).hex) want \(fill.hex), \(at(160).hex) want \(track.hex)")
        check("[\(name)] the fill is neutral, never the accent", abs(at(40).r - at(40).b) < 0.05)
    }
}

func near(_ a: RGBA, _ b: RGBA, tolerance: Double = 0.03) -> Bool {
    abs(a.r - b.r) <= tolerance && abs(a.g - b.g) <= tolerance && abs(a.b - b.b) <= tolerance
}

private func select() {
    let counter = Counter()
    let field = Select()
    for title in ["Auto", "1:1", "16:9", "Grape"] { field.addItem(withTitle: title) }
    field.menu?.insertItem(.separator(), at: 1)
    field.selectItem(at: 0)
    field.target = counter
    field.action = #selector(Counter.fire)
    field.frame = CGRect(x: 20, y: 40, width: 140, height: DS.Size.control)
    let window = hostWindow(field)
    check("Select is an NSPopUpButton, control tall, so item lookups and tags keep working", (field as AnyObject) is NSPopUpButton && field.intrinsicContentSize.height == DS.Size.control)
    check("VoiceOver reads Select as a popup button with its value", field.accessibilityRole() == .popUpButton && field.accessibilityValue() as? String == "Auto",
          "\(String(describing: field.accessibilityRole())) \(String(describing: field.accessibilityValue()))")
    check("a right click never brings up the system menu", field.menu(for: mouse(.rightMouseDown, at: 5, in: field)) == nil)

    field.keyDown(with: keyEvent(49, " ", window: window))
    check("Space on the focused field opens its own menu, highlighting the picked item", field.isMenuOpen && field.menuWindow?.list.highlighted == 0 && field.isAccessibilityExpanded())
    NSApp.sendEvent(keyEvent(125, window: window))
    check("Down arrow, through the app's event path, skips the separator", field.menuWindow?.list.highlighted == 2, "\(String(describing: field.menuWindow?.list.highlighted))")
    NSApp.sendEvent(keyEvent(36, "\r", window: window))
    check("Return picks the highlighted item, closes the menu and sends the action once", !field.isMenuOpen && field.titleOfSelectedItem == "1:1" && counter.fired == 1,
          "\(field.titleOfSelectedItem ?? "nil") fired \(counter.fired)")

    check("VoiceOver's press opens the menu", field.accessibilityPerformPress() && field.isMenuOpen)
    NSApp.sendEvent(keyEvent(5, "g", window: window))
    check("typing a letter jumps to the item it starts", field.menuWindow?.list.highlighted == 4)
    NSApp.sendEvent(keyEvent(53, "\u{1b}", window: window))
    check("Esc closes without picking", !field.isMenuOpen && field.titleOfSelectedItem == "1:1" && counter.fired == 1)

    field.performClick(nil)
    NSApp.sendEvent(keyEvent(119, window: window))
    NSApp.sendEvent(keyEvent(49, " ", window: window))
    check("End then Space picks the last item", field.titleOfSelectedItem == "Grape" && counter.fired == 2)

    field.performClick(nil)
    let other = NSWindow(contentRect: CGRect(x: 400, y: 0, width: 50, height: 50), styleMask: [.borderless], backing: .buffered, defer: false)
    let outside = NSEvent.mouseEvent(with: .leftMouseDown, location: CGPoint(x: 5, y: 5), modifierFlags: [], timestamp: 0, windowNumber: other.windowNumber,
                                     context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    NSApp.sendEvent(outside)
    check("a click outside closes the menu", !field.isMenuOpen)
    field.performClick(nil)
    field.isEnabled = false
    check("turning the field off closes its menu", !field.isMenuOpen)
    field.isEnabled = true

    if let list = SelectMenuWindow(rows: [.init(title: "A", image: nil, isEnabled: true, isSeparator: false)], selected: 0, minWidth: 140,
                                   appearance: NSAppearance(named: .aqua)!).contentView as? SelectMenuList {
        check("the menu is at least as wide as its field, its rows control tall", list.frame.width >= 140 && list.frame(of: 0).height == DS.Size.control)
    }

    let screen = CGRect(x: 0, y: 0, width: 800, height: 600)
    let menu = CGSize(width: 160, height: 150)
    let low = Select.place(menu, under: CGRect(x: 100, y: 20, width: 120, height: 28), within: screen)
    check("near the bottom of the screen the menu opens above the field", low.above && low.rect.minY == 52, "\(low.rect)")
    let right = Select.place(menu, under: CGRect(x: 720, y: 400, width: 70, height: 28), within: screen)
    check("near the right edge it stays on screen", !right.above && right.rect.maxX <= 800 && right.rect.maxY == 396, "\(right.rect)")
    let squeezed = Select.place(CGSize(width: 160, height: 590), under: CGRect(x: 10.5, y: 300.25, width: 60, height: 28), within: screen)
    check("a menu too tall for either side stays inside the screen on whole points", squeezed.rect.minY >= 0 && squeezed.rect.maxY <= 600
          && squeezed.rect.minX == squeezed.rect.minX.rounded() && squeezed.rect.minY == squeezed.rect.minY.rounded(), "\(squeezed.rect)")

    let dark = Select()
    dark.addItem(withTitle: "Free")
    dark.frame = CGRect(x: 0, y: 0, width: 100, height: DS.Size.control)
    let hud = hostWindow(dark)
    hud.appearance = NSAppearance(named: .darkAqua)
    dark.performClick(nil)
    let name = dark.menuWindow?.appearance?.bestMatch(from: [.aqua, .darkAqua])
    check("inside an always-dark panel the menu is dark too", name == .darkAqua, "\(String(describing: name))")
    if let list = dark.menuWindow?.list {
        let rep = renderedImage(of: list, appearance: .darkAqua)
        let scale = CGFloat(rep.pixelsWide) / list.bounds.width
        let got = pixel(rep, x: Int(list.bounds.midX * scale), y: Int(2 * scale))
        check("[darkAqua] the menu's surface is bgRaised", near(got, resolve(DS.Color.bgRaised, .darkAqua)), "\(got.hex)")
    }
    dark.close()

    for (label, appearance) in [("aqua", NSAppearance.Name.aqua), ("darkAqua", .darkAqua)] {
        let loose = Select()
        loose.addItem(withTitle: "Follow Cursor")
        loose.frame = CGRect(x: 0, y: 0, width: 140, height: DS.Size.control)
        let rep = renderedImage(of: loose, appearance: appearance)
        let scale = CGFloat(rep.pixelsWide) / loose.bounds.width
        let got = pixel(rep, x: Int(3 * scale), y: Int(14 * scale))
        check("[\(label)] the field is the neutral bgControl", near(got, resolve(DS.Color.bgControl, appearance)), "\(got.hex)")
    }
}

private func segmentTrack() {
    let counter = Counter()
    let track = Segments(labels: ["White", "Black", "Dot"], width: 144, style: .track)
    track.selectedSegment = 0
    track.target = counter
    track.action = #selector(Counter.fire)
    track.frame.origin = CGPoint(x: 10, y: 10)
    let window = hostWindow(track)
    check("a segment track is control tall and exactly the width it is given", track.intrinsicContentSize == NSSize(width: 144, height: DS.Size.control),
          "\(track.intrinsicContentSize)")
    let tiles = (0..<3).map(track.tile)
    check("the choices touch inside the track's 2 pt inset, on whole points", tiles[0].minX == DS.Space.s2 && tiles[0].maxX == tiles[1].minX && tiles[1].maxX == tiles[2].minX
          && tiles.allSatisfy { $0.minX == $0.minX.rounded() && $0.height == DS.Size.control - 2 * DS.Space.s2 }, "\(tiles)")
    check("the thumb rests on the pick", track.thumbRect == tiles[0], "\(String(describing: track.thumbRect))")

    let at = CGPoint(x: tiles[2].midX, y: tiles[2].midY)
    let point = track.convert(at, to: nil)
    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
        let e = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                   eventNumber: 0, clickCount: 1, pressure: 1)!
        type == .leftMouseDown ? track.mouseDown(with: e) : track.mouseUp(with: e)
    }
    check("a click picks the choice and sends the action once", track.selectedSegment == 2 && counter.fired == 1, "\(track.selectedSegment) fired \(counter.fired)")
    let sliding = track.thumbRect
    check("after a click the thumb starts from the old pick and slides, unless motion is reduced",
          DS.Motion.isReduced || (sliding.map { $0.minX < tiles[2].minX } ?? false), "\(String(describing: sliding))")
    let deadline = Date().addingTimeInterval(1)
    while Date() < deadline, track.thumbRect != tiles[2] { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    check("within the base duration the thumb comes to rest on the new pick", track.thumbRect == tiles[2], "\(String(describing: track.thumbRect))")
    track.selectedSegment = 1
    check("a pick from code moves the thumb at once", track.thumbRect == tiles[1])
    check("on the track the pick reads in textPrimary and the others in textSecondary, never the accent",
          Segments.trackLook(selected: true, state: .normal).text == DS.Color.textPrimary && Segments.trackLook(selected: false, state: .normal).text == DS.Color.textSecondary)

    for (label, appearance) in [("aqua", NSAppearance.Name.aqua), ("darkAqua", .darkAqua)] {
        let loose = Segments(labels: ["White", "Black", "Dot"], width: 144, style: .track)
        loose.selectedSegment = 1
        let rep = renderedImage(of: loose, appearance: appearance)
        let scale = CGFloat(rep.pixelsWide) / loose.bounds.width
        func at(_ x: CGFloat, _ y: CGFloat) -> RGBA { pixel(rep, x: Int(x * scale), y: Int(y * scale)) }
        let thumb = loose.tile(1)
        check("[\(label)] the track is bgControl and the thumb bgControlThumb", near(at(1, 14), resolve(DS.Color.bgControl, appearance))
              && near(at(thumb.minX + 3, 5), resolve(DS.Color.bgControlThumb, appearance)), "\(at(1, 14).hex) \(at(thumb.minX + 3, 5).hex)")
        loose.isEnabled = false
        let off = renderedImage(of: loose, appearance: appearance)
        check("[\(label)] a switched-off track keeps its thumb, flat in bgControlActive", near(pixel(off, x: Int((thumb.minX + 3) * scale), y: Int(5 * scale)),
              resolve(DS.Color.bgControlActive, appearance)))
    }
    let symbols = Segments(symbols: ["circle", "square", "rectangle"], labels: ["Circle", "Square", "Rectangle"], width: 144)
    check("a symbol track shares its width equally", symbols.style == .track && abs(symbols.tile(0).width - symbols.tile(2).width) <= 2 && symbols.intrinsicContentSize.width == 144 && symbols.intrinsicContentSize.height == DS.Size.control)
}
