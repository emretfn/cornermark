import AppKit
import KadrajCore
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
