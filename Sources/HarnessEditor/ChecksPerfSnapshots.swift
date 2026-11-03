import AppKit
import KadrajCore
import KadrajEditor

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
        }
    }

    let rig = makeBusyRig()
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

    rig.driver.tapKey("g")
    var bg = BackgroundStyle()
    bg.fill = .builtin(index: 1); bg.padding = 80; bg.cornerRadius = 20
    rig.controller.perform(.setBackground(bg))
    rig.controller.zoom = 0.5
    relayout(rig)
    both(rig, "background-panel")

    rig.controller.perform(.setBackground(nil))
    rig.driver.tapKey("c")
    rig.driver.drag(cropPoint(rig, CGPoint(x: 0, y: 0)), cropPoint(rig, CGPoint(x: 140, y: 90)))
    rig.driver.drag(cropPoint(rig, CGPoint(x: 1200, y: 800)), cropPoint(rig, CGPoint(x: 1010, y: 690)))
    rig.controller.zoom = 0.6
    relayout(rig)
    both(rig, "crop-mid-edit")
    closeRig(rig)
}
