import AppKit
import CornermarkCore
import CornermarkDesign
import CornermarkEditor

func ms(_ block: () -> Void) -> Double {
    let t = DispatchTime.now().uptimeNanoseconds
    block()
    return Double(DispatchTime.now().uptimeNanoseconds - t) / 1e6
}

func paint(_ view: NSView, _ rect: CGRect) {
    let r = rect.intersection(view.bounds)
    guard !r.isEmpty, let rep = view.bitmapImageRepForCachingDisplay(in: r) else { return }
    view.cacheDisplay(in: r, to: rep)
}

func checkPerformance() {
    section("Performance on a 5K image")
    let rig = makeRig(width: 5120, height: 2880, zoom: nil)
    let d = rig.driver, c = rig.controller
    relayout(rig)
    let view = c.canvasView
    print("INFO 5K canvas zoom \(String(format: "%.3f", c.zoom)), view \(view.frame.size)")

    let composite = ms { _ = Renderer.sourceComposite(rig.doc, assets: rig.assets) }
    let firstPaint = ms { paint(view, view.bounds) }
    let fullPaint = (0..<5).map { _ in ms { paint(view, view.bounds) } }.min()!
    print(String(format: "INFO sourceComposite 5K: %.1f ms, first full paint %.1f ms, steady full-canvas paint (best of 5) %.1f ms", composite, firstPaint, fullPaint))

    func rectAround(_ pts: [CGPoint]) -> CGRect {
        var r = CGRect(origin: view.convert(pts[0], from: nil), size: .zero)
        for p in pts { r = r.union(CGRect(origin: view.convert(p, from: nil), size: .zero)) }
        return r.insetBy(dx: -16, dy: -16)
    }

    d.tapKey("p")
    let start = d.windowPoint(source: CGPoint(x: 600, y: 600))
    var path: [CGPoint] = []
    for i in 0..<60 { let t = CGFloat(i) / 59; path.append(CGPoint(x: start.x + t * 500, y: start.y + sin(t * 9) * 60)) }
    d.down(path[0])
    var frameTimes: [Double] = []
    var recent: [CGPoint] = [path[0]]
    for p in path.dropFirst() {
        recent.append(p)
        let region = rectAround(Array(recent.suffix(5)))
        frameTimes.append(ms { d.move(p); paint(view, region) })
    }
    d.up(path.last!)
    let total = frameTimes.reduce(0, +)
    let worst = frameTimes.max()!
    print(String(format: "INFO pencil drag, 59 move+redraw frames (dirty region only): total %.1f ms, mean %.2f ms, worst %.2f ms", total, total / 59, worst))
    check("60-frame pencil drag on 5K stays under 1 s (16 ms/frame budget = 60 fps)", total < 1000, String(format: "%.1f ms", total))
    check("pencil stroke recorded", { if case .pencil(let pts)? = rig.last?.kind { return pts.count > 30 } else { return false } }())

    let afterCommit = ms { paint(view, view.bounds) }
    let compositeWithStroke = ms { _ = Renderer.sourceComposite(rig.doc, assets: rig.assets) }
    print(String(format: "INFO first full paint after commit (composite rebuild included): %.1f ms; sourceComposite with the stroke alone: %.1f ms", afterCommit, compositeWithStroke))

    // Same drag, but forcing a full-canvas repaint each frame: what a naive repaint would cost.
    d.tapKey("h")
    d.down(path[0])
    var naive: [Double] = []
    for p in path.dropFirst() { naive.append(ms { d.move(p); paint(view, view.bounds) }) }
    d.up(path.last!)
    print(String(format: "INFO highlighter drag with full-canvas repaint every frame: total %.1f ms, mean %.2f ms", naive.reduce(0, +), naive.reduce(0, +) / 59))

    // Blur reads pixels underneath: large regions preview as a frosted outline, small ones recompute live.
    d.tapKey("b")
    d.down(path[0])
    var blur: [Double] = []
    for p in path.dropFirst() { blur.append(ms { d.move(p); paint(view, view.bounds) }) }
    let blurRelease = ms { d.up(path.last!); paint(view, view.bounds) }
    print(String(format: "INFO large blur drag (frosted preview): total %.1f ms, mean %.2f ms; release renders the real blur in %.1f ms", blur.reduce(0, +), blur.reduce(0, +) / 59, blurRelease))
    closeRig(rig)

    let hd = makeRig(width: 1920, height: 1080, zoom: nil)
    relayout(hd)
    let hv = hd.controller.canvasView
    hd.driver.tapKey("b")
    let o = hd.driver.windowPoint(source: CGPoint(x: 500, y: 400))
    hd.driver.down(o)
    var live: [Double] = []
    for i in 1...8 { let t = CGFloat(i) / 8; let p = CGPoint(x: o.x + t * 120, y: o.y - t * 90); live.append(ms { hd.driver.move(p); paint(hv, hv.bounds) }) }
    hd.driver.up(CGPoint(x: o.x + 120, y: o.y - 90))
    print(String(format: "INFO 1080p blur drag (live recompute, small region): mean %.1f ms per frame over 8 frames", live.reduce(0, +) / 8))
    closeRig(hd)
}

/// Annotated scene used by the snapshots.
func snapshotScenes() {
    section("Snapshots")
    func both(_ rig: Rig, _ name: String) {
        for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let url = snapshot(rig.controller, "\(suffix)-\(name)", appearance: appearance)
            check("snapshot written: \(url.lastPathComponent)", FileManager.default.fileExists(atPath: url.path))
            if name == "annotations-select" { toolbarStrip(rig.controller, "\(suffix)-toolbar-strip") }
        }
    }

    let rig = makeBusyRig()
    toolbarMetrics(rig)
    rig.driver.tapKey("v")
    rig.driver.click(rig.driver.windowPoint(source: CGPoint(x: 285, y: 140)))
    relayout(rig)
    both(rig, "annotations-select")

    rig.driver.tapKey("a")
    rig.driver.down(rig.driver.windowPoint(source: CGPoint(x: 900, y: 600)))
    for i in 1...6 { rig.driver.move(rig.driver.windowPoint(source: CGPoint(x: 900 - CGFloat(i) * 30, y: 600 + CGFloat(i) * 20))) }
    both(rig, "arrow-tool-mid-drag")
    rig.driver.up(rig.driver.windowPoint(source: CGPoint(x: 720, y: 720)))

    rig.driver.tapKey("t")
    rig.driver.click(rig.driver.windowPoint(source: CGPoint(x: 700, y: 60)))
    rig.driver.type("Editing inline")
    both(rig, "text-editing")
    rig.driver.escape()
    relayout(rig)
    both(rig, "text-tool")

    rig.driver.tapKey("b")
    relayout(rig)
    both(rig, "blur-tool")

    rig.driver.tapKey("a")
    if let well = rig.controller.view(identifier: "prop.colorWell") as? NSColorWell {
        well.color = NSColor(srgbRed: 0.45, green: 0.2, blue: 0.75, alpha: 1)
        well.sendAction(well.action, to: well.target)
    }
    relayout(rig)
    both(rig, "arrow-custom-colour")

    rig.driver.tapKey("g")
    var bg = BackgroundStyle()
    bg.fill = .builtin(index: 1); bg.padding = 80; bg.cornerRadius = 20
    rig.controller.perform(.setBackground(bg))
    rig.controller.zoom = 0.5
    relayout(rig)
    both(rig, "background-panel")

    for name in ["Soft shadow", "Slide deck"] {
        (rig.controller.view(identifier: "bg.presetName") as? NSTextField)?.stringValue = name
        click(rig.controller.view(identifier: "bg.presetSave"))
    }
    bg.fill = .solid(RGBA(0.35, 0.45, 0.85))
    rig.controller.perform(.setBackground(bg))
    relayout(rig)
    both(rig, "background-panel-preset")

    rig.controller.perform(.setBackground(nil))
    rig.driver.tapKey("c")
    rig.driver.drag(cropPoint(rig, CGPoint(x: 0, y: 0)), cropPoint(rig, CGPoint(x: 140, y: 90)))
    rig.driver.drag(cropPoint(rig, CGPoint(x: 1200, y: 800)), cropPoint(rig, CGPoint(x: 1010, y: 690)))
    rig.controller.zoom = 0.6
    relayout(rig)
    both(rig, "crop-mid-edit")

    rig.driver.down(cropPoint(rig, CGPoint(x: 1010, y: 690)))
    for i in 1...4 { rig.driver.move(cropPoint(rig, CGPoint(x: 1010 - CGFloat(i) * 30, y: 690 - CGFloat(i) * 20))) }
    both(rig, "crop-dragging")
    rig.driver.up(cropPoint(rig, CGPoint(x: 890, y: 610)))

    rig.controller.perform(.setCrop(nil))
    rig.driver.tapKey("v")
    rig.driver.tapKey("c")
    rig.driver.drag(cropPoint(rig, CGPoint(x: 0, y: 0)), cropPoint(rig, CGPoint(x: 500, y: 300)))
    rig.driver.drag(cropPoint(rig, CGPoint(x: 1200, y: 800)), cropPoint(rig, CGPoint(x: 600, y: 380)))
    relayout(rig)
    both(rig, "crop-small-box")

    rig.controller.window!.setContentSize(NSSize(width: rig.controller.window!.minSize.width, height: 700))
    relayout(rig)
    both(rig, "crop-min-width")
    resizePanelSnapshots(rig)
    closeRig(rig)
}

/// The resize popover's content on the popover's surface, in both appearances.
func resizePanelSnapshots(_ rig: Rig) {
    for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
        let content = rig.controller.loadResizePanelView()
        content.layoutSubtreeIfNeeded()
        let size = content.fittingSize
        let host = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        host.appearance = NSAppearance(named: appearance)
        host.backgroundColor = DS.Color.bgRaised
        let root = NSView(frame: NSRect(origin: .zero, size: size))
        root.addSubview(content)
        content.frame = root.bounds
        host.contentView = root
        host.setContentSize(size)
        root.layoutSubtreeIfNeeded()
        settle(0.1)
        let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds)!
        root.cacheDisplay(in: root.bounds, to: rep)
        // The popover paints its own surface under the content; stand in for it with the raised colour.
        let image = NSImage(size: root.bounds.size)
        image.lockFocus()
        host.effectiveAppearance.performAsCurrentDrawingAppearance {
            DS.Color.bgRaised.setFill()
            NSRect(origin: .zero, size: root.bounds.size).fill()
        }
        NSImage(size: rep.size, flipped: false) { _ in rep.draw(); return true }.draw(in: NSRect(origin: .zero, size: root.bounds.size))
        image.unlockFocus()
        if let tiff = image.tiffRepresentation, let out = NSBitmapImageRep(data: tiff) {
            let url = snapshotDir.appendingPathComponent("\(suffix)-resize-panel.png")
            writePNG(out, to: url)
            check("snapshot written: \(url.lastPathComponent)", FileManager.default.fileExists(atPath: url.path))
        }
        content.removeFromSuperview()
        root.removeFromSuperview()
    }
}

private let toolbarIdentifiers = ["toolbar.tools", "toolbar.geometry", "toolbar.history", "toolbar.dragHandle", "toolbar.actions", "toolbar.copy"]

/// The system paints a glass capsule behind every toolbar item, which a headless snapshot renders as flat white. This draws
/// the item views themselves on the window colour, so the controls can be read in both appearances.
func toolbarStrip(_ controller: EditorWindowController, _ name: String) {
    let gap: CGFloat = 16
    let reps = toolbarIdentifiers.compactMap { id in controller.view(identifier: id).map { view -> NSBitmapImageRep in
        let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    } }
    let width = reps.reduce(0) { $0 + $1.size.width + gap } + gap
    let height = (reps.map(\.size.height).max() ?? 0) + 2 * gap
    let strip = NSImage(size: NSSize(width: width, height: height))
    strip.lockFocus()
    controller.window!.effectiveAppearance.performAsCurrentDrawingAppearance {
        controller.window!.backgroundColor.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
    }
    var x = gap
    for rep in reps {
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        image.draw(in: NSRect(x: x, y: (height - rep.size.height) / 2, width: rep.size.width, height: rep.size.height))
        x += rep.size.width + gap
    }
    strip.unlockFocus()
    if let tiff = strip.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) { writePNG(rep, to: snapshotDir.appendingPathComponent("\(name).png")) }
}

/// Lays the toolbar out at the window's minimum width and reports where its items end, so a toolbar that outgrows the window
/// shows up here as a chevron instead of in someone's window.
func toolbarMetrics(_ rig: Rig) {
    section("Toolbar at the minimum window width")
    let window = rig.controller.window!
    window.setContentSize(NSSize(width: window.minSize.width, height: 700))
    relayout(rig)
    let frame = window.contentView!.superview!
    let ends = toolbarIdentifiers.compactMap { id -> (String, CGRect)? in
        rig.controller.view(identifier: id).map { (id, $0.convert($0.bounds, to: frame)) }
    }
    for (id, rect) in ends { print(String(format: "INFO %@ spans x %.1f to %.1f, width %.1f", id, rect.minX, rect.maxX, rect.width)) }
    let right = ends.map { $0.1.maxX }.max() ?? .infinity
    print(String(format: "INFO window width %.1f, toolbar content ends at %.1f", frame.bounds.width, right))
    check("every toolbar control is found", ends.count == toolbarIdentifiers.count, "\(ends.map(\.0))")
    check("the toolbar fits the window at its minimum width", right <= frame.bounds.width, String(format: "%.1f of %.1f", right, frame.bounds.width))
    for (id, _) in ends {
        let control = rig.controller.view(identifier: id)!
        check("a press on \(id) stays with it instead of moving the window", !control.mouseDownCanMoveWindow)
    }
    for (id, rect) in ends {
        let hit = frame.hitTest(NSPoint(x: rect.midX, y: rect.midY))
        check("a click on \(id) reaches it through the title bar", hit?.isDescendant(of: rig.controller.view(identifier: id)!) == true, "hit \(String(describing: hit))")
    }
    check("the toolbar row holds no system items, so macOS 26 draws no glass capsules", window.toolbar?.items.isEmpty == true)
    if let zoom = window.standardWindowButton(.zoomButton), let tools = rig.controller.view(identifier: "toolbar.tools") {
        let a = zoom.convert(zoom.bounds, to: frame).midY, b = tools.convert(tools.bounds, to: frame).midY
        check(String(format: "toolbar row sits on the window buttons' centre line: %.1f, %.1f", a, b), abs(a - b) <= 1)
    }
    rig.controller.currentTool = .arrow
    relayout(rig)
    if let width = rig.controller.view(identifier: "prop.width") {
        let rect = width.convert(width.bounds, to: frame)
        let hit = frame.hitTest(NSPoint(x: rect.midX, y: rect.midY))
        check("a click on the property bar is not taken by the title bar", hit?.isDescendant(of: width) == true, "hit \(String(describing: hit))")
    } else {
        check("the arrow tool shows the width slider", false)
    }
    window.setContentSize(NSSize(width: 1280, height: 860))
    relayout(rig)
}
