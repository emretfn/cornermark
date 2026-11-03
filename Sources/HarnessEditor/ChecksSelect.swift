import AppKit
import CornermarkCore
import CornermarkEditor

func annRect(_ a: Annotation?) -> CGRect? {
    guard let a else { return nil }
    switch a.kind {
    case .rect(let r, _, _), .ellipse(let r, _), .blur(let r, _), .pixelate(let r, _, _), .spotlight(let r), .image(let r, _): return r
    default: return nil
    }
}

func annotation(_ rig: Rig, _ id: UUID) -> Annotation? { rig.doc.annotations.first { $0.id == id } }

func checkSelect() {
    section("Select, move, undo, resize, delete")
    let rig = makeRig(zoom: 0.6)
    let d = rig.driver, c = rig.controller
    let undoKey: () -> Void = { d.key("z", code: 6, flags: .command) }
    let redoKey: () -> Void = { d.key("z", code: 6, flags: [.command, .shift]) }

    d.tapKey("r")
    d.drag(source: CGPoint(x: 200, y: 150), to: CGPoint(x: 500, y: 350))
    let id = rig.last!.id
    let original = CGRect(x: 200, y: 150, width: 300, height: 200)
    d.tapKey("v")
    d.click(d.windowPoint(source: CGPoint(x: 275, y: 150)))
    check("click on the rect outline selects it", c.selection == id)

    let undoDepth = c.history.past.count
    d.drag(source: CGPoint(x: 275, y: 150), to: CGPoint(x: 375, y: 210))
    let moved = annRect(annotation(rig, id))!
    check("dragging a selected annotation moves it by the source-pixel delta", near(moved, original.offsetBy(dx: 100, dy: 60), 1.5), fmt(moved))
    check("a whole move drag is one undo step", c.history.past.count == undoDepth + 1, "\(c.history.past.count) vs \(undoDepth)")
    undoKey()
    check("Cmd+Z restores the pre-move rect", near(annRect(annotation(rig, id))!, original, 0.01), fmt(annRect(annotation(rig, id)) ?? .zero))
    redoKey()
    check("Cmd+Shift+Z redoes the move", near(annRect(annotation(rig, id))!, original.offsetBy(dx: 100, dy: 60), 1.5))

    let r1 = annRect(annotation(rig, id))!
    d.drag(source: CGPoint(x: r1.maxX, y: r1.maxY), to: CGPoint(x: r1.maxX + 40, y: r1.maxY + 40))
    let r2 = annRect(annotation(rig, id))!
    check("corner handle resizes the rect", near(r2, CGRect(x: r1.minX, y: r1.minY, width: r1.width + 40, height: r1.height + 40), 1.5), fmt(r2))
    d.drag(source: CGPoint(x: r2.minX, y: r2.midY), to: CGPoint(x: r2.minX + 30, y: r2.midY + 90))
    let r3 = annRect(annotation(rig, id))!
    check("edge handle resizes along one axis only", near(r3, CGRect(x: r2.minX + 30, y: r2.minY, width: r2.width - 30, height: r2.height), 1.5), fmt(r3))
    d.drag(source: CGPoint(x: r3.minX, y: r3.minY), to: CGPoint(x: r3.maxX + 60, y: r3.maxY + 30))
    let r4 = annRect(annotation(rig, id))!
    check("dragging a handle past the opposite edge flips the rect", r4.width > 0 && abs(r4.minX - r3.maxX) < 1.5 && abs(r4.width - 60) < 1.5, fmt(r4))
    d.drag(source: CGPoint(x: r3.maxX, y: r3.maxY), to: CGPoint(x: r3.maxX + 10, y: r3.maxY + 10))

    c.perform(.remove(id))
    d.tapKey("v")
    d.tapKey("r", flags: .shift)
    d.drag(source: CGPoint(x: 600, y: 400), to: CGPoint(x: 800, y: 560))
    d.drag(source: CGPoint(x: 700, y: 450), to: CGPoint(x: 900, y: 620))
    let top = rig.doc.annotations[rig.doc.annotations.count - 1].id, bottom = rig.doc.annotations[rig.doc.annotations.count - 2].id
    d.tapKey("v")
    d.click(d.windowPoint(source: CGPoint(x: 760, y: 500)))
    check("click selects the topmost annotation under the pointer", c.selection == top)
    d.click(d.windowPoint(source: CGPoint(x: 620, y: 420)))
    check("click selects the one below where only it is hit", c.selection == bottom)
    d.click(d.windowPoint(source: CGPoint(x: 80, y: 700)))
    check("click on empty canvas deselects", c.selection == nil)

    d.click(d.windowPoint(source: CGPoint(x: 620, y: 420)))
    d.escape()
    check("Escape deselects", c.selection == nil)

    d.click(d.windowPoint(source: CGPoint(x: 620, y: 420)))
    let count = rig.doc.annotations.count
    d.deleteKey()
    check("Delete removes the selection", rig.doc.annotations.count == count - 1 && annotation(rig, bottom) == nil && c.selection == nil)
    undoKey()
    check("Cmd+Z brings the deleted annotation back", rig.doc.annotations.count == count && annotation(rig, bottom) != nil)

    // Arrow and its curve handle.
    d.tapKey("a")
    d.drag(source: CGPoint(x: 200, y: 600), to: CGPoint(x: 500, y: 600))
    let arrowID = rig.last!.id
    d.tapKey("v")
    d.click(d.windowPoint(source: CGPoint(x: 350, y: 600)))
    let seg = c.view(identifier: "prop.arrowStyle") as? NSSegmentedControl
    seg?.selectedSegment = 3
    seg?.sendAction(seg?.action, to: seg?.target)
    if case .arrow(_, _, _, let style)? = annotation(rig, arrowID)?.kind {
        check("arrow style control restyles the selected arrow", style == .curved, "\(style)")
    } else { check("arrow still present", false) }
    let ctrlDefault = CGPoint(x: 350, y: 600 + 75)
    d.drag(source: ctrlDefault, to: CGPoint(x: 350, y: 700))
    if case .arrow(_, _, let control?, _)? = annotation(rig, arrowID)?.kind {
        check("curved arrow control handle sets the control point", near(control, CGPoint(x: 350, y: 700), 1.5), fmt(control))
    } else { check("curved arrow control point set", false) }
    d.drag(source: CGPoint(x: 500, y: 600), to: CGPoint(x: 560, y: 560))
    if case .arrow(let f, let t, _, _)? = annotation(rig, arrowID)?.kind {
        check("arrow endpoint handle moves only that end", near(t, CGPoint(x: 560, y: 560), 1.5) && near(f, CGPoint(x: 200, y: 600), 0.01), "\(fmt(f)) \(fmt(t))")
    }

    // Line endpoint with Shift snaps to 45 degrees.
    d.tapKey("l")
    d.drag(source: CGPoint(x: 700, y: 650), to: CGPoint(x: 900, y: 650))
    let lineID = rig.last!.id
    d.tapKey("v")
    d.click(d.windowPoint(source: CGPoint(x: 800, y: 650)))
    d.drag(source: CGPoint(x: 900, y: 650), to: CGPoint(x: 880, y: 745), flags: .shift)
    if case .line(let f, let t)? = annotation(rig, lineID)?.kind {
        let a = atan2(t.y - f.y, t.x - f.x) * 180 / .pi
        check("shift while dragging a line end snaps to 45 degrees", abs(a - 45) < 0.5, "\(a)")
    }
    closeRig(rig)

    section("Move under rotation and crop")
    let rr = makeRig(zoom: 0.6)
    rr.controller.perform(.rotateClockwise)
    rr.controller.perform(.setCrop(CGRect(x: 100, y: 80, width: 800, height: 560)))
    relayout(rr)
    rr.driver.tapKey("o", flags: .shift)
    rr.driver.drag(source: CGPoint(x: 300, y: 250), to: CGPoint(x: 460, y: 380))
    let eid = rr.last!.id
    let e0 = annRect(rr.last)!
    rr.driver.tapKey("v")
    rr.driver.drag(source: CGPoint(x: 380, y: 315), to: CGPoint(x: 430, y: 365))
    let e1 = annRect(annotation(rr, eid))!
    check("move in a rotated, cropped view translates by the source delta", near(e1, e0.offsetBy(dx: 50, dy: 50), 1.5), fmt(e1))
    closeRig(rr)
}
