import AppKit
import CornermarkCapture
import CornermarkDesign

/// The recording panel sits in the middle of a selection of any size, so its origin can land between device pixels. These checks
/// render the live panel where the overlay put it and compare its source toggles with the same view drawn on its own pixel grid.
@MainActor
func runPanelSharpnessTests() async {
    section("recording panel: sharp at 1x and 2x")
    let frame = CGRect(x: 0, y: 0, width: 1200, height: 800)
    let screen = Fixtures.display(id: 7, frame: frame, scale: 1, windows: [], seed: 7)
    let rc = makeController(FixtureScreenSource(displays: [screen], windows: []), pointer: CGPoint(x: 600, y: 400))
    var sourcesOn: Set<RecordingSource> = []
    var pending: Set<RecordingSource> = []
    rc.recordingSources = { RecordingSources(on: sourcesOn, pending: pending) }
    let out = await start(rc, .recording)
    guard let window = overlay(rc, frame: frame), let root = window.contentView else { return check(false, "the recording overlay opens") }
    // An odd width and height, as a hand-drawn selection usually has, puts the centre on a half point.
    Synth.drag(window, from: CGPoint(x: 101, y: 101), to: CGPoint(x: 974, y: 573))
    guard let panel = findView("cornermark.record.start.video", in: rc.overlayWindows)?.superview else { return check(false, "the panel is shown") }
    let toggles = ["microphone", "systemAudio", "camera", "clicks", "keystrokes"]
        .compactMap { findView("cornermark.record.source." + $0, in: rc.overlayWindows) as? IconButton }
    guard toggles.count == 5 else { return check(false, "the panel has five source toggles") }

    func offGrid() -> [String] {
        ([panel] + descendants(of: panel)).compactMap { view -> String? in
            let r = view.convert(view.bounds, to: nil)
            let aligned = [r.minX, r.minY, r.width, r.height].allSatisfy { abs($0 - $0.rounded()) < 0.001 }
            return aligned ? nil : "\(view.accessibilityIdentifier().isEmpty ? String(describing: type(of: view)) : view.accessibilityIdentifier()) \(r)"
        }
    }
    check(offGrid().isEmpty, "the panel and every control in it sit on whole points, so nothing straddles a pixel at 1x", detail: offGrid().joined(separator: "; "))
    rc.recordingSources = { RecordingSources(note: .blocked("Turn on Cornermark in System Settings > Privacy & Security > Input Monitoring, then reopen it.")) }
    rc.refreshOverlay()
    check(offGrid().isEmpty, "a two-line note beside the toggles sits on whole points too", detail: offGrid().joined(separator: "; "))
    rc.recordingSources = { RecordingSources(on: sourcesOn, pending: pending) }
    rc.refreshOverlay()

    let row = toggles.map(\.frame).reduce(toggles[0].frame) { $0.union($1) }
    let evidence = ProcessInfo.processInfo.environment["CORNERMARK_EVIDENCE_DIR"].map { $0 + "/" } ?? scratch
    func compare(_ scale: CGFloat, _ name: String) -> (diff: Int, energy: Double, live: [UInt8], width: Int) {
        let reference = toggleRow(of: panel, row: row, in: panel, panelOrigin: .zero, scale: scale)
        let placed = panel.convert(panel.bounds, to: root).origin
        let live = toggleRow(of: panel, row: row, in: root, panelOrigin: CGPoint(x: floor(placed.x), y: floor(placed.y)), scale: scale)
        save(live.image, to: evidence + "toggles-\(name).png", zoom: Int(8 / scale))
        let diff = zip(live.rgba, reference.rgba).map { abs(Int($0) - Int($1)) }.max() ?? 255
        return (diff, edgeEnergy(live.rgba, live.image.width) / max(edgeEnergy(reference.rgba, reference.image.width), 1), live.rgba, live.image.width)
    }
    let one = compare(1, "1x")
    let two = compare(2, "2x")
    print(String(format: "MEASURE toggles 1x max diff %d, edge energy %.3f of reference; 2x max diff %d, edge energy %.3f", one.diff, one.energy, two.diff, two.energy))
    check(one.diff <= 2 && one.energy > 0.98, "at 1x the toggles render as sharp as the panel drawn on its own pixel grid",
          detail: String(format: "max diff %d, edge energy %.3f", one.diff, one.energy))
    check(two.diff <= 2 && two.energy > 0.98, "and at 2x", detail: String(format: "max diff %d, edge energy %.3f", two.diff, two.energy))

    // The permission round trip: the camera waits for an answer while the overlay steps aside, then comes back on.
    pending = [.camera]
    rc.refreshOverlay()
    rc.yieldOverlay(true)
    check(toggles[2].isEnabled == false, "a toggle waiting for permission takes no clicks")
    sourcesOn = [.camera]
    pending = []
    rc.yieldOverlay(false)
    rc.refreshOverlay()
    check(toggles[2].isEnabled && toggles[2].isSelected && toggles[2].interactionState == .normal,
          "once macOS answers, the camera toggle is on and nothing of the waiting state is left", detail: "\(toggles[2].interactionState)")
    for scale in [CGFloat(1), 2] {
        let placed = panel.convert(panel.bounds, to: root).origin
        save(toggleRow(of: panel, row: row, in: root, panelOrigin: CGPoint(x: floor(placed.x), y: floor(placed.y)), scale: scale).image, to: evidence + "toggles-camera-on-\(Int(scale))x.png", zoom: Int(8 / scale))
    }
    sourcesOn = []
    rc.refreshOverlay()
    let again = compare(1, "1x-after-yield")
    check(again.live == one.live, "the toggles at 1x are the same pixels after a 2x render and a hide and show", detail: "max diff \(again.diff)")

    let reference = toggleRow(of: panel, row: row, in: panel, panelOrigin: .zero, scale: 2)
    let width = reference.image.width
    let ratios = toggles.map { toggle -> Double in
        let r = CGRect(x: (toggle.frame.minX - row.minX) * 2, y: (row.maxY - toggle.frame.maxY) * 2, width: toggle.frame.width * 2, height: toggle.frame.height * 2)
        let px = Pixels.sub(reference.rgba, width: width, rect: r)
        let lum = stride(from: 0, to: px.count, by: 4).map { luminance(px[$0], px[$0 + 1], px[$0 + 2]) }
        return (lum.max()! + 0.05) / (lum.min()! + 0.05)
    }
    print("MEASURE off glyph contrast on the panel " + ratios.map { String(format: "%.2f", $0) }.joined(separator: " "))
    check(ratios.allSatisfy { $0 >= 4.5 }, "every off glyph keeps 4.5:1 against the panel", detail: ratios.map { String(format: "%.2f", $0) }.joined(separator: " "))

    Synth.escape(window)
    _ = await waitUntil { out.value != nil }
}

@MainActor
private func descendants(of view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants(of: $0) } }

/// Draws `host` at `scale` over the panel's footprint and returns the toggle row, row 0 at the top.
@MainActor
private func toggleRow(of panel: NSView, row: CGRect, in host: NSView, panelOrigin: CGPoint, scale: CGFloat) -> (image: CGImage, rgba: [UInt8]) {
    let area = CGRect(origin: panelOrigin, size: panel.bounds.size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(area.width * scale), pixelsHigh: Int(area.height * scale), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = area.size
    host.cacheDisplay(in: area, to: rep)
    let crop = CGRect(x: row.minX * scale, y: (area.height - row.maxY) * scale, width: row.width * scale, height: row.height * scale)
    let image = rep.cgImage!.cropping(to: crop)!
    return (image, Pixels.rgba(image))
}

private func luminance(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> Double {
    func lin(_ v: UInt8) -> Double { let c = Double(v) / 255; return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
    return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
}

/// Sum of squared neighbour differences in luminance. A half-pixel shift spreads every edge over two pixels and roughly halves it.
private func edgeEnergy(_ rgba: [UInt8], _ width: Int) -> Double {
    let height = rgba.count / 4 / width
    func l(_ x: Int, _ y: Int) -> Double { let i = (y * width + x) * 4; return luminance(rgba[i], rgba[i + 1], rgba[i + 2]) }
    var sum = 0.0
    for y in 0..<(height - 1) { for x in 0..<(width - 1) { sum += pow(l(x + 1, y) - l(x, y), 2) + pow(l(x, y + 1) - l(x, y), 2) } }
    return sum
}

private func save(_ image: CGImage, to path: String, zoom: Int) {
    let ctx = Pixels.context(image.width * zoom, image.height * zoom)
    ctx.interpolationQuality = .none
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
    if let big = ctx.makeImage(), let data = Pixels.pngData(big) { try? data.write(to: URL(fileURLWithPath: path)) }
}
