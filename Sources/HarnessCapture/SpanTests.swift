import AppKit
import KadrajCapture
import KadrajCore

/// Every pixel of a spanning capture, predicted from the cell display it came from. Pixels cut from a display
/// finer than the canvas are resampled, so only those within 3 source pixels of a cell edge are skipped.
@MainActor
func expectComposite(_ out: CaptureOutput?, rect: CGRect, displays: [DisplaySnapshot], _ name: String) {
    guard let out else { return check(false, "\(name): no output") }
    let touched = displays.filter { !$0.frame.intersection(rect).isEmpty }
    let s = CGFloat(touched.map(\.scale).max() ?? 1)
    let w = Int((rect.width * s).rounded()), h = Int((rect.height * s).rounded())
    guard out.image.width == w, out.image.height == h else {
        return check(false, "\(name): canvas is \(out.image.width)x\(out.image.height), want \(w)x\(h)")
    }
    check(out.pointScale == Double(s) && out.kind == .area, "\(name): pointScale is the maximum scale of the displays touched (\(s))", detail: "\(out.pointScale)")

    let got = Pixels.rgba(out.image)
    var bad = 0
    var firstBad: String?
    for py in 0..<h {
        for px in 0..<w {
            let g = CGPoint(x: rect.minX + (CGFloat(px) + 0.5) / s, y: rect.maxY - (CGFloat(py) + 0.5) / s)
            let o = (py * w + px) * 4
            let pixel = Array(got[o..<(o + 4)])
            var ok: Bool
            if let d = touched.first(where: { $0.frame.contains(g) }) {
                let lx = (g.x - d.frame.minX).truncatingRemainder(dividingBy: Cells.size)
                let ly = (d.frame.maxY - g.y).truncatingRemainder(dividingBy: Cells.size)
                let margin = 3 / CGFloat(d.scale)
                let resampled = CGFloat(d.scale) < s
                if resampled, min(lx, Cells.size - lx) < margin || min(ly, Cells.size - ly) < margin { continue }
                ok = mostlyEqual(pixel, Cells.color(at: g, in: touched)!, tolerance: resampled ? 2 : 0)
            } else {
                ok = pixel == [0, 0, 0, 0]
            }
            if !ok { bad += 1; if firstBad == nil { firstBad = "(\(px),\(py)) at \(g): \(pixel)" } }
        }
    }
    check(bad == 0, "\(name): all \(w)x\(h) pixels come from the right display position (gaps transparent)", detail: "\(bad) wrong, first \(firstBad ?? "")")

    var faded = 0
    for d in touched {
        let o = d.frame.intersection(rect)
        let x0 = Int(((o.minX - rect.minX) * s).rounded()), x1 = Int(((o.maxX - rect.minX) * s).rounded())
        let y0 = h - Int(((o.maxY - rect.minY) * s).rounded()), y1 = h - Int(((o.minY - rect.minY) * s).rounded())
        for px in x0..<x1 { for py in [y0, y1 - 1] where got[(py * w + px) * 4 + 3] != 255 { faded += 1 } }
        for py in y0..<y1 { for px in [x0, x1 - 1] where got[(py * w + px) * 4 + 3] != 255 { faded += 1 } }
    }
    check(faded == 0, "\(name): every edge pixel of every display part is opaque (no seam or faded border)", detail: "\(faded) not opaque")
}

@MainActor
func expectMarker(_ out: CaptureOutput?, rect: CGRect, displays: [DisplaySnapshot], at g: CGPoint, _ name: String) {
    guard let out else { return check(false, "\(name): no output") }
    let s = CGFloat(out.pointScale)
    let px = Int((g.x - rect.minX) * s), py = Int((rect.maxY - g.y) * s)
    guard px >= 0, py >= 0, px < out.image.width, py < out.image.height else { return check(false, "\(name): marker outside canvas") }
    let got = Pixels.rgba(out.image)
    let o = (py * out.image.width + px) * 4
    let want = Cells.color(at: g, in: displays) ?? [0, 0, 0, 0]
    check(mostlyEqual(Array(got[o..<(o + 4)]), want, tolerance: 2), "\(name): marker from global \(g) sits at canvas (\(px),\(py))", detail: "got \(Array(got[o..<(o + 4)])) want \(want)")
}

struct PanelImage {
    let rgba: [UInt8]
    let width: Int
    let height: Int
    let frame: CGRect

    init?(_ image: CGImage?, frame: CGRect) {
        guard let image else { return nil }
        rgba = Pixels.rgba(image); width = image.width; height = image.height; self.frame = frame
    }

    func pixel(_ g: CGPoint) -> [UInt8] {
        let f = CGFloat(width) / frame.width
        let x = min(max(Int((g.x - frame.minX) * f), 0), width - 1), y = min(max(Int((frame.maxY - g.y) * f), 0), height - 1)
        return Array(rgba[((y * width + x) * 4)..<((y * width + x) * 4 + 4)])
    }
}

/// The dim is 50% black, but the snapshot's color space shifts it a few levels, so match a band around half.
func isDimmed(_ got: [UInt8], from c: [UInt8]) -> Bool {
    got[3] == 255 && (0..<3).allSatisfy { Double(got[$0]) >= Double(c[$0]) * 0.45 && Double(got[$0]) <= Double(c[$0]) * 0.6 }
}
func lum(_ c: [UInt8]) -> Int { Int(c[0]) + Int(c[1]) + Int(c[2]) }

@MainActor
func spanDrag(_ c: CaptureController, _ out: Outcome, from a: CGPoint, to b: CGPoint, in frame: CGRect) async {
    Synth.drag(overlay(c, frame: frame)!, from: a, to: b)
    _ = await waitUntil { out.value != nil }
}

@MainActor
func runSpanTests() async {
    let c1 = Cells.display(id: 1, frame: d1.frame, scale: 1)
    let c2 = Cells.display(id: 2, frame: d2.frame, scale: 2)
    let cells = [c1, c2]
    let source = FixtureScreenSource(displays: cells)

    section("selection across displays (1x then 2x, side by side)")
    let c = makeController(source)
    var out = await start(c, .area)
    let spanRect = CGRect(x: 500, y: 100, width: 260.5, height: 150.5)
    await spanDrag(c, out, from: CGPoint(x: 500, y: 100), to: CGPoint(x: 760.5, y: 250.5), in: d1.frame)
    expectComposite(out.output, rect: spanRect, displays: cells, "drag from the 1x display into the 2x display")
    expectMarker(out.output, rect: spanRect, displays: cells, at: CGPoint(x: 590, y: 170), "1x side")
    expectMarker(out.output, rect: spanRect, displays: cells, at: CGPoint(x: 610, y: 170), "2x side")
    expectMarker(out.output, rect: spanRect, displays: cells, at: CGPoint(x: 700, y: 110), "2x side, lower")
    let spanOut = out.output
    check(c.lastSelection == PreviousSelection(rect: spanRect), "lastSelection remembers the spanning rect with no display")
    if let img = spanOut?.image, let png = Pixels.pngData(img) {
        let path = multiScratch + "10-span-output.png"
        try? png.write(to: URL(fileURLWithPath: path))
        print("SNAPSHOT \(path) \(img.width)x\(img.height)")
    }

    out = await start(c, .previousArea)
    _ = await waitUntil { out.value != nil }
    check(c.overlayWindows.isEmpty && out.output.map { Pixels.rgba($0.image) } == spanOut.map { Pixels.rgba($0.image) } && out.output?.pointScale == 2,
          "previousArea across both displays reproduces the same pixels and scale")

    out = await start(c, .area)
    await spanDrag(c, out, from: CGPoint(x: 760.5, y: 250.5), to: CGPoint(x: 500, y: 100), in: d2.frame)
    check(out.output.map { Pixels.rgba($0.image) } == spanOut.map { Pixels.rgba($0.image) }, "a right-to-left drag (2x display to 1x display) gives the same pixels")
    expectComposite(out.output, rect: spanRect, displays: cells, "right-to-left drag")

    out = await start(c, .area)
    await spanDrag(c, out, from: CGPoint(x: 500, y: 100), to: CGPoint(x: 600, y: 200), in: d1.frame)
    expectPixels(out.output, from: c1, topLeftRect: CGRect(x: 500, y: 200, width: 100, height: 100), "a selection ending exactly on the boundary stays an exact crop of one display")

    out = await start(c, .area)
    await spanDrag(c, out, from: CGPoint(x: 650.5, y: 40), to: CGPoint(x: 800.5, y: 130), in: d2.frame)
    expectPixels(out.output, from: c2, topLeftRect: CGRect(x: 101, y: 340, width: 300, height: 180), "a selection inside the 2x display is an exact crop")
    check(out.output?.pointScale == 2, "that crop reports pointScale 2")

    out = await start(c, .area)
    let gapRect = CGRect(x: 500, y: 200, width: 300, height: 180)
    await spanDrag(c, out, from: CGPoint(x: 500, y: 200), to: CGPoint(x: 800, y: 380), in: d1.frame)
    expectComposite(out.output, rect: gapRect, displays: cells, "displays of different heights")
    if let o = out.output {
        let px = Pixels.rgba(o.image)
        func alpha(_ g: CGPoint) -> UInt8 {
            let i = (Int((gapRect.maxY - g.y) * 2) * o.image.width + Int((g.x - gapRect.minX) * 2)) * 4
            return px[i + 3]
        }
        check(alpha(CGPoint(x: 700, y: 350)) == 0 && alpha(CGPoint(x: 550, y: 350)) == 255 && alpha(CGPoint(x: 700, y: 250)) == 255,
              "the corner above the shorter display is transparent while both displays stay opaque")
    }

    section("previousArea when a display goes away")
    out = await start(c, .area)
    await spanDrag(c, out, from: CGPoint(x: 500, y: 100), to: CGPoint(x: 760.5, y: 250.5), in: d1.frame)
    source.displaySnapshots = [c1]
    out = await start(c, .previousArea)
    _ = await waitUntil { out.value != nil }
    expectPixels(out.output, from: c1, topLeftRect: CGRect(x: 500, y: 150, width: 100, height: 150), "previousArea keeps the part that is still on a display")
    check(out.output?.pointScale == 1 && c.overlayWindows.isEmpty, "the trimmed recapture is at the remaining display's scale with no UI")

    source.displaySnapshots = cells
    out = await start(c, .area)
    await spanDrag(c, out, from: CGPoint(x: 650, y: 50), to: CGPoint(x: 750, y: 150), in: d2.frame)
    source.displaySnapshots = [c1]
    out = await start(c, .previousArea)
    check(out.value == nil && c.overlayWindows.count == 1 && c.overlayWindows[0].frame == d1.frame,
          "previousArea falls back to picking an area when nothing of it remains")
    c.cancel()
    source.displaySnapshots = cells

    section("selection across displays (stacked, negative origins)")
    let top = Cells.display(id: 12, frame: CGRect(x: 0, y: 400, width: 400, height: 300), scale: 2)
    let bottom = Cells.display(id: 11, frame: CGRect(x: 0, y: 0, width: 600, height: 400), scale: 1)
    let stacked = [bottom, top]
    let sc = makeController(FixtureScreenSource(displays: stacked))
    out = await start(sc, .area)
    var r = CGRect(x: 100, y: 350, width: 160.5, height: 170.5)
    await spanDrag(sc, out, from: CGPoint(x: 100, y: 350), to: CGPoint(x: 260.5, y: 520.5), in: bottom.frame)
    expectComposite(out.output, rect: r, displays: stacked, "1x display below, 2x display above")
    expectMarker(out.output, rect: r, displays: stacked, at: CGPoint(x: 170, y: 390), "lower 1x display")
    expectMarker(out.output, rect: r, displays: stacked, at: CGPoint(x: 170, y: 410), "upper 2x display")
    out = await start(sc, .area)
    await spanDrag(sc, out, from: CGPoint(x: 260.5, y: 520.5), to: CGPoint(x: 100, y: 350), in: top.frame)
    expectComposite(out.output, rect: r, displays: stacked, "bottom-to-top and top-to-bottom drags agree")

    let left = Cells.display(id: 21, frame: CGRect(x: -400, y: 0, width: 400, height: 300), scale: 2)
    let main = Cells.display(id: 22, frame: CGRect(x: 0, y: 0, width: 600, height: 400), scale: 1)
    let leftOf = [main, left]
    let lc = makeController(FixtureScreenSource(displays: leftOf))
    out = await start(lc, .area)
    r = CGRect(x: -120.5, y: 100.5, width: 270.5, height: 99.5)
    await spanDrag(lc, out, from: CGPoint(x: 150, y: 200), to: CGPoint(x: -120.5, y: 100.5), in: main.frame)
    expectComposite(out.output, rect: r, displays: leftOf, "negative x origin, dragged leftwards")
    expectMarker(out.output, rect: r, displays: leftOf, at: CGPoint(x: -10, y: 150), "2x display at negative x")
    expectMarker(out.output, rect: r, displays: leftOf, at: CGPoint(x: 10, y: 150), "1x display at origin")

    let upper = Cells.display(id: 32, frame: CGRect(x: 0, y: 0, width: 400, height: 300), scale: 2)
    let lower = Cells.display(id: 31, frame: CGRect(x: -100, y: -300, width: 600, height: 300), scale: 1)
    let below = [upper, lower]
    let bc = makeController(FixtureScreenSource(displays: below))
    out = await start(bc, .area)
    r = CGRect(x: 200, y: -150, width: 50, height: 250)
    await spanDrag(bc, out, from: CGPoint(x: 200, y: 100), to: CGPoint(x: 250, y: -150), in: upper.frame)
    expectComposite(out.output, rect: r, displays: below, "1x display below with negative y and x origin")
    expectMarker(out.output, rect: r, displays: below, at: CGPoint(x: 230, y: -10), "1x display below")
    expectMarker(out.output, rect: r, displays: below, at: CGPoint(x: 230, y: 10), "2x display above")

    section("all-in-one across displays")
    let wide1 = Cells.display(id: 41, frame: CGRect(x: 0, y: 0, width: 900, height: 500), scale: 1)
    let wide2 = Cells.display(id: 42, frame: CGRect(x: 900, y: 0, width: 700, height: 400), scale: 2)
    let wide = [wide1, wide2]
    let a = makeController(FixtureScreenSource(displays: wide))
    out = await start(a, .allInOne)
    let wa = overlay(a, frame: wide1.frame)!
    func rect() -> CGRect? { if case .adjusting(let s, _)? = a.overlayState { return s.rect } else { return nil } }
    /// The panel hosting the toolbar, and the toolbar pill in that panel's coordinates.
    func toolbarHost() -> (NSWindow, CGRect)? {
        let hosts = a.overlayWindows.compactMap { w -> (NSWindow, CGRect)? in
            guard var v = findView("kadraj.toolbar.capture", in: w.contentView), let root = w.contentView else { return nil }
            while let up = v.superview, up !== root { v = up }
            return (w, v.frame.insetBy(dx: 16, dy: 16))
        }
        return hosts.count == 1 ? hosts[0] : nil
    }
    Synth.drag(wa, from: CGPoint(x: 700, y: 160), to: CGPoint(x: 899, y: 260))
    check(rect() == CGRect(x: 700, y: 160, width: 199, height: 100), "all-in-one pick starts on the first display")
    check(toolbarHost()?.0.frame == wide1.frame, "the toolbar sits on the display holding the selection")
    Synth.drag(wa, from: CGPoint(x: 899, y: 210), to: CGPoint(x: 1000.5, y: 210))
    check(rect() == CGRect(x: 700, y: 160, width: 300.5, height: 100), "dragging the right handle across the boundary resizes into the 2x display", detail: "\(String(describing: rect()))")
    if let (host, pill) = toolbarHost() {
        check(host.frame == wide1.frame && host.contentView!.bounds.contains(pill), "with most of the selection on the 1x display the toolbar stays on it, fully visible", detail: "\(pill)")
    } else { check(false, "the toolbar lives in exactly one panel") }
    for _ in 0..<10 { Synth.arrow(wa, 124, shift: true) }
    check(rect() == CGRect(x: 800, y: 160, width: 300.5, height: 100), "shift+arrow nudges carry the spanning selection", detail: "\(String(describing: rect()))")
    if let (host, pill) = toolbarHost() {
        check(host.frame == wide2.frame && host.contentView!.bounds.contains(pill), "once the 2x display holds most of it the toolbar moves there, fully visible", detail: "\(pill)")
    } else { check(false, "the toolbar lives in exactly one panel after the nudge") }
    if let w2 = overlay(a, frame: wide2.frame),
       let p1 = PanelImage(snapshot(wa, name: "11-all-in-one-span-display1", in: multiScratch), frame: wide1.frame),
       let p2 = PanelImage(snapshot(w2, name: "12-all-in-one-span-display2", in: multiScratch), frame: wide2.frame) {
        func whiteDot(_ p: PanelImage, _ g: CGPoint) -> Bool { p.pixel(g).prefix(3).allSatisfy { $0 >= 235 } }
        check(whiteDot(p1, CGPoint(x: 800, y: 210)) && !whiteDot(p2, CGPoint(x: 910, y: 210)), "the left handle is drawn on the display that contains it")
        check(whiteDot(p2, CGPoint(x: 1100.5, y: 210)) && whiteDot(p2, CGPoint(x: 950.25, y: 260)), "the right and top handles are drawn on the display that contains them")
    }
    Synth.returnKey(wa)
    _ = await waitUntil { out.value != nil }
    expectComposite(out.output, rect: CGRect(x: 800, y: 160, width: 300.5, height: 100), displays: wide, "Return commits the spanning all-in-one selection")

    section("overlay panels while a drag spans displays")
    let h = makeController(source)
    out = await start(h, .area)
    let w1 = overlay(h, frame: d1.frame)!
    Synth.drag(w1, from: CGPoint(x: 500, y: 100), to: CGPoint(x: 800, y: 250), release: false)
    check(h.overlayState.map { if case .dragging(let d) = $0 { return d.rect == CGRect(x: 500, y: 100, width: 300, height: 150) } else { return false } } ?? false,
          "mid-drag the overlay holds a 300x150 rect spanning both displays")
    let w2 = overlay(h, frame: d2.frame)!
    let before = [w1, w2].map { snapshot($0, name: "tmp-before", in: multiScratch).map(Pixels.rgba) }
    Synth.dragged(w1, to: CGPoint(x: 700, y: 200))
    let after = [w1, w2].map { snapshot($0, name: "tmp-after", in: multiScratch).map(Pixels.rgba) }
    check(zip(before, after).allSatisfy { $0 != nil && $0 != $1 }, "moving the drag end changes what every panel renders")
    try? FileManager.default.removeItem(atPath: multiScratch + "tmp-before.png")
    try? FileManager.default.removeItem(atPath: multiScratch + "tmp-after.png")
    Synth.dragged(w1, to: CGPoint(x: 800, y: 250))
    if let p1 = PanelImage(snapshot(w1, name: "08-span-mid-drag-display1", in: multiScratch), frame: d1.frame),
       let p2 = PanelImage(snapshot(w2, name: "09-span-mid-drag-display2", in: multiScratch), frame: d2.frame) {
        func cell(_ g: CGPoint) -> [UInt8] { Cells.color(at: g, in: cells)! }
        for (name, p, inside, outside) in [("display 1", p1, [CGPoint(x: 550, y: 170), CGPoint(x: 590, y: 130)], [CGPoint(x: 310, y: 310), CGPoint(x: 490, y: 170), CGPoint(x: 550, y: 290)]),
                                           ("display 2", p2, [CGPoint(x: 650, y: 170), CGPoint(x: 790, y: 230)], [CGPoint(x: 650, y: 50), CGPoint(x: 710, y: 290), CGPoint(x: 650, y: 290)])] {
            check(inside.allSatisfy { mostlyEqual(p.pixel($0), cell($0), tolerance: 4) }, "\(name): the hole shows the screen undimmed inside its part of the selection",
                  detail: inside.map { "\($0) got \(p.pixel($0)) want \(cell($0))" }.joined(separator: "; "))
            check(outside.allSatisfy { isDimmed(p.pixel($0), from: cell($0)) }, "\(name): everything outside the selection is dimmed",
                  detail: outside.map { "\($0) got \(p.pixel($0)) cell \(cell($0))" }.joined(separator: "; "))
        }
        func white(_ p: PanelImage, _ g: CGPoint) -> Bool { p.pixel(g).prefix(3).allSatisfy { $0 >= 235 } }
        check(white(p1, CGPoint(x: 550, y: 250.5)) && white(p1, CGPoint(x: 499.5, y: 170)), "display 1: the border follows the selection's top and left edges")
        check(white(p2, CGPoint(x: 700, y: 99.5)) && white(p2, CGPoint(x: 650, y: 99.5)), "display 2: the border follows the selection's bottom edge")
        check(!white(p1, CGPoint(x: 599.5, y: 170)) && !white(p2, CGPoint(x: 600.5, y: 170)), "no border is drawn along the display boundary inside the selection")
        check(lum(p2.pixel(CGPoint(x: 608, y: 268))) * 10 < lum(cell(CGPoint(x: 608, y: 268))) * 3, "the size badge is drawn on the display holding most of the selection")
        check(isDimmed(p1.pixel(CGPoint(x: 506, y: 268)), from: cell(CGPoint(x: 506, y: 268))), "and not on the other display")
        func crosshairLift(_ p: PanelImage, _ x: CGFloat) -> Int {
            let base = lum(cell(CGPoint(x: x, y: 250))) / 2
            return (-3...3).map { lum(p.pixel(CGPoint(x: x, y: 250 + CGFloat($0) * 0.5))) - base }.max() ?? 0
        }
        check(crosshairLift(p2, 910) > 80 && crosshairLift(p1, 50) < 40, "the crosshair appears only on the display under the cursor", detail: "lift \(crosshairLift(p2, 910)) / \(crosshairLift(p1, 50))")
        check(mostlyEqual(p2.pixel(CGPoint(x: 832, y: 55)), [26, 26, 26, 255], tolerance: 8), "the loupe appears on the display under the cursor")
    }
    h.cancel()

    section("scrolling selection stays on one display")
    let sh = makeController(source)
    out = await start(sh, .scrolling)
    Synth.drag(overlay(sh, frame: d1.frame)!, from: CGPoint(x: 550, y: 350), to: CGPoint(x: 700, y: 100))
    if case .scrollingCapture(let area, _)? = sh.overlayState {
        check(area.rect == CGRect(x: 550, y: 100, width: 50, height: 250) && area.display == d1, "a scrolling drag across displays is clamped to the display it began on", detail: "\(area)")
        check(sh.overlayWindows.count == 2 && sh.overlayWindows.allSatisfy { d1.frame.contains($0.frame.insetBy(dx: 4, dy: 4)) }, "its border and HUD windows stay on that display", detail: "\(sh.overlayWindows.map(\.frame))")
    } else { check(false, "a scrolling drag across displays is clamped to the display it began on", detail: "\(String(describing: sh.overlayState))") }
    sh.cancel()
}
