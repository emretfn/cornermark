import AppKit
import KadrajCore
import KadrajDesign
import KadrajEditor

func click(_ view: NSView?) { (view as? NSControl)?.performClick(nil) }

func checkBackgroundPanel() {
    section("Background panel")
    let rig = makeRig(zoom: nil)
    let d = rig.driver, c = rig.controller
    d.tapKey("g")
    relayout(rig)
    check("background tool opens the panel", c.view(identifier: "bg.fill.0")?.isHidden == false && c.view(identifier: "bg.fill.0")!.window != nil)
    check("panel shows all 20 builtin thumbnails", (0..<20).allSatisfy { c.view(identifier: "bg.fill.\($0)") != nil })
    check("document starts without a background", rig.doc.background == nil)

    click(c.view(identifier: "bg.fill.7"))
    check("clicking a thumbnail applies that builtin fill", rig.doc.background?.fill == .builtin(index: 7), "\(String(describing: rig.doc.background))")
    click(c.view(identifier: "bg.fill.12"))
    check("another thumbnail replaces it", rig.doc.background?.fill == .builtin(index: 12))

    let align = c.view(identifier: "bg.alignment") as? NSPopUpButton
    align?.selectItem(withTitle: "Bottom"); press(align)
    check("alignment menu sets alignment", rig.doc.background?.alignment == .bottom)
    let aspect = c.view(identifier: "bg.aspect") as? NSPopUpButton
    aspect?.selectItem(withTitle: "16:9"); press(aspect)
    check("aspect ratio menu sets the ratio", abs((rig.doc.background?.aspectRatio ?? 0) - 16.0 / 9) < 0.001)
    let size = Renderer.canvasSize(rig.doc, assets: rig.assets)
    check("canvas honours the ratio", abs(size.width / size.height - 16.0 / 9) < 0.01, "\(size)")
    let shadow = c.view(identifier: "bg.shadow") as? NSButton
    let shadowBefore = rig.doc.background?.shadow
    shadow?.performClick(nil)
    check("shadow checkbox toggles the shadow", rig.doc.background?.shadow == !(shadowBefore ?? true))
    let balance = c.view(identifier: "bg.autoBalance") as? NSButton
    balance?.performClick(nil)
    check("auto balance checkbox toggles auto balance", rig.doc.background?.autoBalance == true)
    _ = Renderer.render(rig.doc, assets: rig.assets)
    balance?.performClick(nil)
    let radius = c.view(identifier: "bg.radius") as? NSSlider
    radius?.doubleValue = 33; press(radius)
    check("corner radius slider sets the radius", rig.doc.background?.cornerRadius == 33)

    let well = c.view(identifier: "bg.solid") as? NSColorWell
    well?.color = NSColor(srgbRed: 0.1, green: 0.5, blue: 0.9, alpha: 1)
    press(well)
    if case .solid(let col)? = rig.doc.background?.fill {
        check("colour well sets a solid fill", abs(col.r - 0.1) < 0.01 && abs(col.b - 0.9) < 0.01)
    } else { check("colour well sets a solid fill", false) }

    section("Slider drags coalesce")
    let slider = c.view(identifier: "bg.padding") as! NSSlider
    let base = c.history.past.count
    let start = rig.doc.background?.padding ?? 0
    d.dragSlider(slider, toFraction: 0.5)
    let afterFirst = rig.doc.background?.padding ?? 0
    check("six slider ticks change the padding", abs(afterFirst - start) > 20, "\(start) -> \(afterFirst)")
    check("six slider ticks are one undo step", c.history.past.count == base + 1, "past \(c.history.past.count) base \(base)")
    click(c.view(identifier: "bg.shadow"))
    click(c.view(identifier: "bg.shadow"))
    d.dragSlider(slider, toFraction: 0.15)
    check("a later drag after another edit is its own undo step", c.history.past.count == base + 4 && abs((rig.doc.background?.padding ?? 0) - afterFirst) > 20, "past \(c.history.past.count)")
    d.key("z", code: 6, flags: .command)
    check("one Cmd+Z undoes the whole later drag", abs((rig.doc.background?.padding ?? -1) - afterFirst) < 0.5, "\(rig.doc.background?.padding ?? -1) vs \(afterFirst)")

    section("Background presets")
    click(c.view(identifier: "bg.fill.3"))
    let saved = rig.doc.background!
    let nameField = c.view(identifier: "bg.presetName") as? NSTextField
    nameField?.stringValue = "Soft"
    click(c.view(identifier: "bg.presetSave"))
    check("saving a preset adds an apply button", c.view(identifier: "bg.preset.apply.Soft") != nil)
    check("presets persist in UserDefaults", defaults.data(forKey: "kadraj.presets.background") != nil)
    click(c.view(identifier: "bg.none"))
    check("None removes the background", rig.doc.background == nil)
    click(c.view(identifier: "bg.preset.apply.Soft"))
    check("applying a preset restores the saved style", rig.doc.background == saved)
    let reopened = makeRig(zoom: nil)
    reopened.driver.tapKey("g")
    relayout(reopened)
    check("a new editor lists the saved preset", reopened.controller.view(identifier: "bg.preset.apply.Soft") != nil)
    closeRig(reopened)
    click(c.view(identifier: "bg.preset.delete.Soft"))
    check("deleting a preset removes it", c.view(identifier: "bg.preset.apply.Soft") == nil)
    closeRig(rig)
}

func rgbaClose(_ a: RGBA, _ b: RGBA) -> Bool { abs(a.r - b.r) < 0.01 && abs(a.g - b.g) < 0.01 && abs(a.b - b.b) < 0.01 }

func checkPropertyBar() {
    section("Property bar, palette and style presets")
    let rig = makeRig(zoom: 0.6)
    let d = rig.driver, c = rig.controller
    d.tapKey("a")
    relayout(rig)
    let chips = c.allViews(identifier: "prop.chip")
    check("eight colour swatches", chips.count == 8, "\(chips.count)")
    click(chips[4])
    d.drag(source: CGPoint(x: 100, y: 100), to: CGPoint(x: 300, y: 200))
    if case .arrow = rig.last?.kind {
        check("clicking a swatch colours the next arrow", rgbaClose(rig.last!.stroke.color, RGBA(0.118, 0.533, 0.941)), "\(rig.last!.stroke.color)")
    }
    let width = c.view(identifier: "prop.width") as? NSSlider
    width?.doubleValue = 14; press(width)
    let style = c.view(identifier: "prop.arrowStyle") as? NSSegmentedControl
    Driver(c.window!.windowController as! EditorWindowController).clickSegment(style!, 1)
    d.drag(source: CGPoint(x: 100, y: 300), to: CGPoint(x: 300, y: 400))
    if case .arrow(_, _, _, let st) = rig.last!.kind {
        check("width slider and arrow style apply to the next arrow", rig.last!.stroke.width == 14 && st == .tapered, "w \(rig.last!.stroke.width) style \(st)")
    }

    click(c.view(identifier: "prop.favorite"))
    check("star button saves the colour to the favourites palette", defaults.data(forKey: "kadraj.palette.favorites") != nil && c.allViews(identifier: "prop.favoriteChip").count == 1)
    let second = makeRig(zoom: nil)
    second.driver.tapKey("a")
    relayout(second)
    check("favourites survive into a new editor", second.controller.allViews(identifier: "prop.favoriteChip").count == 1)
    closeRig(second)

    c.saveStylePreset(named: "Callout")
    check("style preset is saved for this tool", c.stylePresetNames == ["Callout"])
    click(chips[0])
    width?.doubleValue = 3; press(width)
    c.applyStylePreset(named: "Callout")
    d.drag(source: CGPoint(x: 400, y: 100), to: CGPoint(x: 600, y: 200))
    check("applying the preset restores colour, width and arrow style",
          rgbaClose(rig.last!.stroke.color, RGBA(0.118, 0.533, 0.941)) && rig.last!.stroke.width == 14, "\(rig.last!.stroke)")
    let popup = c.view(identifier: "prop.presets") as? NSPopUpButton
    check("presets menu lists the saved preset", popup?.itemTitles.contains("Callout") == true, "\(popup?.itemTitles ?? [])")
    check("style presets persist in UserDefaults", defaults.data(forKey: "kadraj.presets.style") != nil)

    d.tapKey("v")
    d.click(d.windowPoint(source: CGPoint(x: 500, y: 150)))
    let depth = c.history.past.count
    let target = rig.last!.id
    click(c.allViews(identifier: "prop.chip")[0])
    check("a swatch recolours the selected annotation", rgbaClose(annotation(rig, target)!.stroke.color, RGBA(0.898, 0.188, 0.227)))
    check("recolouring is one undo step", c.history.past.count == depth + 1)
    closeRig(rig)
}


/// Controls of one property-bar row share a centre line, and the stock ones are as tall as the chips and sliders beside them.
func checkPropertyBarAlignment() {
    section("Property bar: one centre line, even heights")
    let rig = makeRig(zoom: 0.6)
    let c = rig.controller
    let frame = c.window!.contentView!.superview!
    let ids = ["prop.colors", "prop.colorWell", "prop.eyedropper", "prop.favorite", "prop.width", "prop.fontSize", "prop.pixelBlock", "prop.arrowStyle", "prop.blurMode", "prop.textStyle", "prop.presets"]
    for tool in [EditorTool.arrow, .line, .rect, .text, .counter, .pencil, .highlighter, .blur, .pixelate, .spotlight] {
        c.currentTool = tool
        relayout(rig)
        let found = ids.flatMap { id in c.allViews(identifier: id).map { (id, $0.convert($0.bounds, to: frame)) } }
        let centres = found.map(\.1.midY)
        guard let first = centres.first else { check("\(tool): shows a hint and no controls", tool == .spotlight); continue }
        let spread = (centres.max() ?? first) - (centres.min() ?? first)
        check("\(tool): every control sits on one centre line", spread <= 0.5, found.map { "\($0.0)@\(String(format: "%.1f", $0.1.midY))" }.joined(separator: " "))
        for (id, rect) in found where id != "prop.colors" {
            print(String(format: "INFO %@ %@ height %.1f", "\(tool)", id, rect.height))
        }
        let heights = found.filter { ["prop.textStyle", "prop.presets", "prop.arrowStyle", "prop.blurMode", "prop.width", "prop.fontSize", "prop.pixelBlock"].contains($0.0) }.map(\.1.height)
        check("\(tool): popups, segments and sliders are all \(Int(22)) tall", heights.allSatisfy { abs($0 - 22) <= 0.5 }, "\(heights)")
    }
    closeRig(rig)
}


/// The resize popover: every row ends on one right edge and the four presets are one width.
func checkResizePanelLayout() {
    section("Resize panel layout")
    let rig = makeRig(zoom: 0.6)
    let c = rig.controller
    let panel = c.loadResizePanelView()
    panel.frame.size = panel.fittingSize
    panel.layoutSubtreeIfNeeded()
    let presets = [25, 50, 100, 200].compactMap { c.view(identifier: "resize.preset.\($0)") }
    let slider = c.view(identifier: "resize.scale")
    check("the panel has a slider and four presets", presets.count == 4 && slider is NSSlider)
    if presets.count == 4, let slider {
        let rects = presets.map { $0.convert($0.bounds, to: panel) }
        check("the four presets are one width and s8 apart", rects.allSatisfy { abs($0.width - rects[0].width) < 0.5 } && zip(rects, rects.dropFirst()).allSatisfy { abs($1.minX - $0.maxX - 8) < 0.5 },
              "\(rects.map(\.width))")
        let edge = rects[3].maxX
        check("the presets end s16 from the panel's right edge", abs(edge - (panel.bounds.width - 16)) < 0.5, "\(edge) of \(panel.bounds.width)")
        func texts(_ v: NSView) -> [NSTextField] { (v as? NSTextField).map { [$0] } ?? v.subviews.flatMap(texts) }
        let readout = texts(panel).first { $0.stringValue.hasSuffix("%") && $0.stringValue.count <= 4 }
        if let readout {
            let r = readout.convert(readout.alignmentRect(forFrame: readout.bounds), to: panel)
            check("the readout is right-aligned and ends on the presets' right edge", readout.alignment == .right && abs(r.maxX - edge) < 0.5, "\(r.maxX) vs \(edge)")
            let s = slider.convert(slider.bounds, to: panel)
            check("the slider fills the row up to the readout", r.minX >= s.maxX && s.minX == rects[0].minX, "slider \(s) readout \(r)")
        } else { check("the panel shows a readout", false) }
        let title = texts(panel).first { $0.stringValue == "Resize" }
        check("the title is the heading style", title?.font == DS.Text.heading.font)
    }
    closeRig(rig)
}


/// The custom colour well is a chip: neutral with a palette glyph while a chip's colour is in use, filled and ringed otherwise.
func checkColourWell() {
    section("Property bar: the custom colour well")
    let rig = makeRig(zoom: 0.6)
    let c = rig.controller
    rig.driver.tapKey("a")
    relayout(rig)
    func sample(_ view: NSView, _ x: CGFloat, _ y: CGFloat) -> NSColor {
        view.appearance = NSAppearance(named: .aqua)
        let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: rep)
        let k = CGFloat(rep.pixelsWide) / view.bounds.width
        return rep.colorAt(x: Int(x * k), y: Int(y * k))!.usingColorSpace(.sRGB)!
    }
    func resolved(_ color: NSColor) -> NSColor {
        var out = color
        NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance { out = color.usingColorSpace(.sRGB)! }
        return out
    }
    func close(_ a: NSColor, _ b: NSColor, _ tol: CGFloat = 0.06) -> Bool {
        abs(a.redComponent - b.redComponent) < tol && abs(a.greenComponent - b.greenComponent) < tol && abs(a.blueComponent - b.blueComponent) < tol
    }
    guard let well = c.view(identifier: "prop.colorWell") as? NSColorWell else { check("prop.colorWell is an NSColorWell", false); closeRig(rig); return }
    check("prop.colorWell stays an NSColorWell, a 22pt circle tile like the chips", well.frame.size == NSSize(width: 22, height: 22), "\(well.frame.size)")
    let surface = resolved(DS.Color.bgSurface)
    check("with a chip's colour in use the well is neutral, no ring", close(sample(well, 1, 11), surface) && close(sample(well, 11, 4), resolved(DS.Color.bgControl), 0.04),
          "\(sample(well, 1, 11)) \(sample(well, 11, 4))")
    // A window backing store has its own colour space, which nudges saturated colours, so these two are matched loosely.
    let purple = NSColor(srgbRed: 0.45, green: 0.2, blue: 0.75, alpha: 1)
    well.color = purple
    well.sendAction(well.action, to: well.target)
    relayout(rig)
    check("a colour that is none of the chips fills the well", close(sample(well, 11, 11), purple, 0.2), "\(sample(well, 11, 11))")
    check("and rings it in accentMark", close(sample(well, 1, 11), resolved(DS.Color.accentMark), 0.2) && !close(sample(well, 1, 11), surface, 0.2), "\(sample(well, 1, 11))")
    c.view(identifier: "prop.chip").flatMap { $0 as? NSButton }?.performClick(nil)
    relayout(rig)
    check("choosing a chip returns the well to neutral", close(sample(well, 1, 11), surface), "\(sample(well, 1, 11))")
    closeRig(rig)
}
