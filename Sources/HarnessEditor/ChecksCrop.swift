import AppKit
import CornermarkCore
import CornermarkEditor

/// Window point for a source pixel while the crop tool shows the whole, un-cropped image.
func cropPoint(_ rig: Rig, _ p: CGPoint) -> CGPoint {
    var doc = rig.doc
    doc.crop = nil; doc.background = nil; doc.outputScale = 1
    return rig.driver.windowPoint(source: p, document: doc)
}

func press(_ control: NSControl?, segment: Int? = nil) {
    guard let control else { return }
    if let segment, let seg = control as? NSSegmentedControl {
        Driver(openedWindows.last!).clickSegment(seg, segment)
        return
    }
    control.sendAction(control.action, to: control.target)
}

func segment(of control: NSSegmentedControl?, titled title: String) -> Int? {
    control.flatMap { c in (0..<c.segmentCount).first { c.label(forSegment: $0) == title } }
}

func checkCrop() {
    section("Crop")
    let rig = makeRig(zoom: 0.6)
    let d = rig.driver, c = rig.controller
    let full = CGRect(x: 0, y: 0, width: 1200, height: 800)

    d.tapKey("c")
    d.drag(cropPoint(rig, CGPoint(x: 0, y: 0)), cropPoint(rig, CGPoint(x: 150, y: 100)))
    d.drag(cropPoint(rig, CGPoint(x: 1200, y: 800)), cropPoint(rig, CGPoint(x: 1000, y: 700)))
    check("dragging crop handles does not touch the document until applied", rig.doc.crop == nil)
    d.returnKey()
    check("Return applies the crop rect", rig.doc.crop.map { near($0, CGRect(x: 150, y: 100, width: 850, height: 600), 1.5) } ?? false, rig.doc.crop.map(fmt) ?? "nil")
    check("applying crop returns to the select tool", c.currentTool == .select)
    let cs = Renderer.canvasSize(rig.doc, assets: rig.assets)
    check("canvas size follows the crop", cs == rig.doc.crop?.size, "\(cs) vs \(String(describing: rig.doc.crop))")
    check("renderedImage has the cropped size", CGFloat(c.renderedImage().width) == cs.width && CGFloat(c.renderedImage().height) == cs.height)
    d.key("z", code: 6, flags: .command)
    check("undo reverts the crop in one step", rig.doc.crop == nil)
    d.key("z", code: 6, flags: [.command, .shift])
    check("redo reapplies the crop", rig.doc.crop != nil)

    d.tapKey("c")
    d.returnKey()
    check("re-entering crop starts from the current crop and Return keeps it", rig.doc.crop.map { near($0, CGRect(x: 150, y: 100, width: 850, height: 600), 1.5) } ?? false)

    let before = rig.doc
    d.tapKey("c")
    d.drag(cropPoint(rig, CGPoint(x: 150, y: 100)), cropPoint(rig, CGPoint(x: 400, y: 300)))
    d.escape()
    check("Escape cancels the crop edit", rig.doc == before && c.currentTool == .select)

    // Crop active while annotating: the marks land correctly (also covered under rotation above).
    d.tapKey("r")
    d.drag(source: CGPoint(x: 300, y: 250), to: CGPoint(x: 500, y: 400))
    check("drawing with a crop active stores source pixels", rig.last.flatMap(annRect).map { near($0, CGRect(x: 300, y: 250, width: 200, height: 150), 1.5) } ?? false)
    d.key("z", code: 6, flags: .command)

    // Rotate and flip buttons keep an active crop attached to the content.
    let geometry = c.view(identifier: "toolbar.geometry") as? NSSegmentedControl
    press(geometry, segment: 0)
    let rotated = Renderer.canvasSize(rig.doc, assets: rig.assets)
    check("rotate button turns the document and swaps the canvas", rig.doc.geometry.quarterTurns == 1 && rotated.width == cs.height && rotated.height == cs.width, "\(rig.doc.geometry) \(rotated)")
    press(geometry, segment: 1)
    press(geometry, segment: 2)
    check("flip buttons toggle both flips", rig.doc.geometry.flipH && rig.doc.geometry.flipV, "\(rig.doc.geometry)")
    d.tapKey("r")
    relayout(rig)
    d.drag(source: CGPoint(x: 320, y: 260), to: CGPoint(x: 480, y: 380))
    check("drawing after rotate and flips still stores source pixels", rig.last.flatMap(annRect).map { near($0, CGRect(x: 320, y: 260, width: 160, height: 120), 1.5) } ?? false, rig.last.flatMap(annRect).map(fmt) ?? "nil")
    press(geometry, segment: 1)
    press(geometry, segment: 2)
    press(geometry, segment: 0)
    press(geometry, segment: 0)
    press(geometry, segment: 0)
    check("rotating and flipping back restores the geometry", rig.doc.geometry == Geometry(), "\(rig.doc.geometry)")

    d.tapKey("c")
    press(geometry, segment: 0)
    relayout(rig)
    d.returnKey()
    check("rotating while the crop tool is open keeps the crop rect in source pixels", rig.doc.crop.map { near($0, CGRect(x: 150, y: 100, width: 850, height: 600), 1.5) } ?? false, rig.doc.crop.map(fmt) ?? "nil")
    press(geometry, segment: 0); press(geometry, segment: 0); press(geometry, segment: 0)

    // Aspect, snapping, reset.
    c.perform(.setCrop(nil))
    d.tapKey("c")
    let aspect = c.view(identifier: "crop.aspect") as? NSSegmentedControl
    press(aspect, segment: segment(of: aspect, titled: "1:1"))
    d.returnKey()
    check("1:1 aspect option crops a centred square", rig.doc.crop.map { near($0, CGRect(x: 200, y: 0, width: 800, height: 800), 1.5) } ?? false, rig.doc.crop.map(fmt) ?? "nil")

    c.perform(.setCrop(nil))
    d.tapKey("c")
    press(aspect, segment: segment(of: aspect, titled: "16:9"))
    d.drag(cropPoint(rig, CGPoint(x: 1200, y: 800)), cropPoint(rig, CGPoint(x: 600, y: 500)))
    d.returnKey()
    if let crop = rig.doc.crop {
        check("dragging a corner with 16:9 locked keeps the ratio", abs(crop.width / crop.height - 16.0 / 9) < 0.02, fmt(crop))
    } else { check("16:9 crop applied", false) }

    c.perform(.setCrop(nil))
    d.tapKey("c")
    d.drag(cropPoint(rig, CGPoint(x: 0, y: 400)), cropPoint(rig, CGPoint(x: 6, y: 400)))
    d.drag(cropPoint(rig, CGPoint(x: 1200, y: 400)), cropPoint(rig, CGPoint(x: 1194, y: 400)))
    d.returnKey()
    check("edges within 8 screen points snap to the image edge", rig.doc.crop == nil, rig.doc.crop.map(fmt) ?? "nil")
    d.tapKey("c")
    d.drag(cropPoint(rig, CGPoint(x: 0, y: 400)), cropPoint(rig, CGPoint(x: 60, y: 400)))
    d.returnKey()
    check("a drag beyond the snap distance crops", rig.doc.crop.map { abs($0.minX - 60) < 1.5 } ?? false, rig.doc.crop.map(fmt) ?? "nil")

    c.perform(.setCrop(nil))
    d.tapKey("c")
    d.drag(cropPoint(rig, CGPoint(x: 0, y: 0)), cropPoint(rig, CGPoint(x: 500, y: 400)))
    d.drag(cropPoint(rig, CGPoint(x: 1200, y: 800)), cropPoint(rig, CGPoint(x: 900, y: 600)))
    d.drag(cropPoint(rig, CGPoint(x: 100, y: 100)), cropPoint(rig, CGPoint(x: 300, y: 250)))
    check("drag outside the draft starts a fresh crop (draft only)", rig.doc.crop == nil)
    d.returnKey()
    check("fresh crop drag applies to the dragged rect", rig.doc.crop.map { near($0, full.intersection(CGRect(x: 100, y: 100, width: 200, height: 150)), 1.5) } ?? false, rig.doc.crop.map(fmt) ?? "nil")
    closeRig(rig)

    section("Resize panel")
    let r2 = makeRig(zoom: 0.6)
    let geo = r2.controller.view(identifier: "toolbar.geometry") as? NSSegmentedControl
    _ = r2.controller.loadResizePanelView()
    let slider = r2.controller.view(identifier: "resize.scale") as? NSSlider
    check("resize panel exposes the output scale slider", slider != nil && geo != nil)
    slider?.doubleValue = 50
    press(slider)
    check("scale slider sets the output scale", abs(r2.doc.outputScale - 0.5) < 0.001 && Renderer.canvasSize(r2.doc, assets: r2.assets) == CGSize(width: 600, height: 400))
    check("exported render is half size", r2.controller.renderedImage().width == 600 && r2.controller.renderedImage().height == 400)
    (r2.controller.view(identifier: "resize.preset.200") as? NSButton)?.performClick(nil)
    check("200% preset doubles the export", abs(r2.doc.outputScale - 2) < 0.001 && r2.controller.renderedImage().width == 2400)
    r2.driver.tapKey("r")
    relayout(r2)
    r2.controller.zoom = 0.3
    relayout(r2)
    r2.driver.drag(source: CGPoint(x: 200, y: 200), to: CGPoint(x: 600, y: 400))
    check("drawing with output scale 2 still stores source pixels", r2.last.flatMap(annRect).map { near($0, CGRect(x: 200, y: 200, width: 400, height: 200), 2.5) } ?? false, r2.last.flatMap(annRect).map(fmt) ?? "nil")
    closeRig(r2)
}
