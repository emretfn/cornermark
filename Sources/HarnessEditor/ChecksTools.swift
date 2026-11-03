import AppKit
import KadrajCore
import KadrajEditor

func rectOf(_ a: CGPoint, _ b: CGPoint) -> CGRect {
    CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
}

/// Draws one mark with every drawing tool by a real drag from `a` to `b` (source pixels) and checks the stored geometry.
func exerciseDrawingTools(_ rig: Rig, label: String, a: CGPoint, b: CGPoint, counterStart: Int) {
    let d = rig.driver
    let tol: CGFloat = 1.6
    let expectRect = rectOf(a, b)

    func draw(_ key: Character, shift: Bool = false, to end: CGPoint? = nil, steps: Int = 8) -> Annotation? {
        let before = rig.doc.annotations.count
        d.tapKey(key, flags: shift ? .shift : [])
        d.drag(source: a, to: end ?? b, steps: steps)
        guard rig.doc.annotations.count == before + 1 else { return nil }
        return rig.last
    }

    if let ann = draw("a"), case .arrow(let f, let t, _, _) = ann.kind {
        check("\(label): arrow tool drag stores from/to in source pixels", near(f, a, tol) && near(t, b, tol), "from \(fmt(f)) to \(fmt(t)) expected \(fmt(a)) \(fmt(b))")
    } else { check("\(label): arrow tool adds one arrow", false) }

    if let ann = draw("l"), case .line(let f, let t) = ann.kind {
        check("\(label): line tool drag stores endpoints", near(f, a, tol) && near(t, b, tol), "\(fmt(f)) \(fmt(t))")
    } else { check("\(label): line tool adds one line", false) }

    if let ann = draw("r"), case .rect(let r, let filled, _) = ann.kind {
        check("\(label): rect tool drag stores outline rect", near(r, expectRect, tol) && !filled, fmt(r))
    } else { check("\(label): rect tool adds one rect", false) }

    if let ann = draw("r", shift: true), case .rect(let r, let filled, _) = ann.kind {
        check("\(label): shift+R picks filled rect", near(r, expectRect, tol) && filled, fmt(r))
    } else { check("\(label): filled rect tool adds one rect", false) }

    if let ann = draw("o"), case .ellipse(let r, let filled) = ann.kind {
        check("\(label): ellipse tool drag stores bounding rect", near(r, expectRect, tol) && !filled, fmt(r))
    } else { check("\(label): ellipse tool adds one ellipse", false) }

    if let ann = draw("o", shift: true), case .ellipse(let r, let filled) = ann.kind {
        check("\(label): shift+O picks filled ellipse", near(r, expectRect, tol) && filled, fmt(r))
    } else { check("\(label): filled ellipse tool adds one ellipse", false) }

    let n0 = rig.doc.annotations.count
    d.tapKey("n")
    d.click(d.windowPoint(source: b))
    if rig.doc.annotations.count == n0 + 1, case .counter(let c, let n, _) = rig.last!.kind {
        check("\(label): counter click lands at source point with next number", near(c, b, tol) && n == counterStart, "center \(fmt(c)) number \(n) expected \(counterStart)")
    } else { check("\(label): counter click adds a counter", false) }

    for (key, name) in [("p" as Character, "pencil"), ("h", "highlighter")] {
        if let ann = draw(key, steps: 12) {
            var pts: [CGPoint] = []
            if case .pencil(let p) = ann.kind { pts = p } else if case .highlighter(let p) = ann.kind { pts = p }
            let onLine = pts.allSatisfy { p in
                let ab = CGPoint(x: b.x - a.x, y: b.y - a.y), t = max(0, min(1, ((p.x - a.x) * ab.x + (p.y - a.y) * ab.y) / (ab.x * ab.x + ab.y * ab.y)))
                return near(p, CGPoint(x: a.x + ab.x * t, y: a.y + ab.y * t), 2.5)
            }
            check("\(label): \(name) records the dragged path in source pixels",
                  pts.count >= 8 && near(pts.first!, a, tol) && near(pts.last!, b, tol) && onLine, "\(pts.count) points")
        } else { check("\(label): \(name) adds one stroke", false) }
    }

    if let ann = draw("b"), case .blur(let r, _) = ann.kind {
        check("\(label): blur tool drag stores region", near(r, expectRect, tol), fmt(r))
    } else { check("\(label): blur tool adds one blur", false) }

    if let ann = draw("x"), case .pixelate(let r, let block, _) = ann.kind {
        check("\(label): pixelate tool drag stores region and block size", near(r, expectRect, tol) && block > 0, fmt(r))
    } else { check("\(label): pixelate tool adds one pixelate", false) }

    if let ann = draw("s"), case .spotlight(let r) = ann.kind {
        check("\(label): spotlight tool drag stores region", near(r, expectRect, tol), fmt(r))
    } else { check("\(label): spotlight tool adds one spotlight", false) }

    // Shift constraints: a 20 degree arrow snaps to horizontal, a wide rect becomes a square.
    let skew = CGPoint(x: a.x + 200, y: a.y + 73)
    if let ann = draw("a", shift: false, to: skew), case .arrow = ann.kind { _ = ann }
    d.tapKey("a")
    d.drag(source: a, to: skew, flags: .shift)
    if case .arrow(let f, let t, _, _) = rig.last!.kind {
        let angle = atan2(t.y - f.y, t.x - f.x) * 180 / .pi
        check("\(label): shift constrains arrow to a 45 degree step", abs(angle) < 0.5 && near(f, a, tol), "angle \(angle)")
    }
    d.tapKey("r")
    d.drag(source: a, to: CGPoint(x: a.x + 180, y: a.y + 60), flags: .shift)
    if case .rect(let r, _, _) = rig.last!.kind {
        check("\(label): shift constrains rect to a square", abs(r.width - r.height) < 1 && abs(r.width - 180) < 1.5, fmt(r))
    }
}

func checkShortcuts() {
    section("Shortcuts switch tools")
    let rig = makeRig()
    let d = rig.driver
    let table: [(Character, Bool, EditorTool)] = [("a", false, .arrow), ("l", false, .line), ("r", false, .rect), ("r", true, .filledRect),
        ("o", false, .ellipse), ("o", true, .filledEllipse), ("t", false, .text), ("n", false, .counter), ("p", false, .pencil),
        ("h", false, .highlighter), ("b", false, .blur), ("x", false, .pixelate), ("s", false, .spotlight), ("c", false, .crop), ("v", false, .select)]
    for (key, shift, tool) in table {
        d.tapKey(key, flags: shift ? .shift : [])
        check("key \(shift ? "Shift+" : "")\(String(key).uppercased()) selects \(tool)", rig.controller.currentTool == tool, "\(rig.controller.currentTool)")
    }
    let toolbar = rig.controller.view(identifier: "toolbar.tools") as? NSSegmentedControl
    check("toolbar segment follows the active tool", toolbar?.selectedSegment == EditorTool.allCases.firstIndex(of: .select))
    closeRig(rig)
}

func checkDrawing() {
    section("Drawing at non-1 zoom")
    let rig = makeRig(zoom: 0.6)
    check("zoom is 0.6", abs(rig.controller.zoom - 0.6) < 0.001)
    exerciseDrawingTools(rig, label: "zoom 0.6", a: CGPoint(x: 140, y: 120), b: CGPoint(x: 420, y: 300), counterStart: 1)
    let n = rig.doc.annotations.count
    check("every drawing gesture committed exactly one annotation", n == 15, "\(n)")
    closeRig(rig)

    section("Drawing after rotation, crop and background")
    let r2 = makeRig(zoom: 0.55)
    r2.controller.perform(.rotateClockwise)
    r2.controller.perform(.setCrop(CGRect(x: 160, y: 90, width: 760, height: 520)))
    var bg = BackgroundStyle()
    bg.fill = .builtin(index: 4); bg.padding = 70; bg.cornerRadius = 18; bg.shadow = true
    r2.controller.perform(.setBackground(bg))
    relayout(r2)
    check("crop and rotation changed the canvas", Renderer.canvasSize(r2.doc, assets: r2.assets) == CGSize(width: 520 + 140, height: 760 + 140),
          "\(Renderer.canvasSize(r2.doc, assets: r2.assets))")
    exerciseDrawingTools(r2, label: "rot+crop+bg", a: CGPoint(x: 240, y: 170), b: CGPoint(x: 560, y: 390), counterStart: 1)
    closeRig(r2)

    section("Counter numbering")
    let r3 = makeRig()
    r3.driver.tapKey("n")
    for x in [200.0, 300, 400] { r3.driver.click(r3.driver.windowPoint(source: CGPoint(x: x, y: 200))) }
    func counters() -> [Int] { r3.doc.annotations.compactMap { if case .counter(_, let n, _) = $0.kind { return n } else { return nil } } }
    check("counters number 1, 2, 3", counters() == [1, 2, 3], "\(counters())")
    r3.controller.perform(.remove(r3.doc.annotations[1].id))
    r3.driver.click(r3.driver.windowPoint(source: CGPoint(x: 500, y: 200)))
    check("next counter reuses the free number 2", counters() == [1, 3, 2], "\(counters())")
    closeRig(r3)
}
