import AppKit
import KadrajCore
import KadrajEditor

func samePixels(_ a: CGImage, _ b: CGImage) -> Bool { a.width == b.width && a.height == b.height && pixels(a) == pixels(b) }

func cgImage(from data: Data) -> CGImage? {
    guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(src, 0, nil)
}

/// A document with every feature in play, built through real gestures.
func makeBusyRig(callbacks: EditorCallbacks = EditorCallbacks(), pasteboard: NSPasteboard? = nil) -> Rig {
    let rig = makeRig(zoom: 0.6, callbacks: callbacks, pasteboard: pasteboard)
    let d = rig.driver
    d.tapKey("a"); d.drag(source: CGPoint(x: 160, y: 520), to: CGPoint(x: 420, y: 420))
    d.tapKey("r"); d.drag(source: CGPoint(x: 100, y: 140), to: CGPoint(x: 470, y: 420))
    d.tapKey("o"); d.drag(source: CGPoint(x: 640, y: 180), to: CGPoint(x: 940, y: 460))
    d.tapKey("n"); d.click(d.windowPoint(source: CGPoint(x: 120, y: 160)))
    d.tapKey("p"); d.drag(source: CGPoint(x: 520, y: 520), to: CGPoint(x: 800, y: 600), steps: 14)
    d.tapKey("h"); d.drag(source: CGPoint(x: 130, y: 500), to: CGPoint(x: 560, y: 505))
    d.tapKey("b"); d.drag(source: CGPoint(x: 700, y: 640), to: CGPoint(x: 900, y: 700))
    d.tapKey("t"); d.click(d.windowPoint(source: CGPoint(x: 600, y: 90)))
    d.type("Kadraj editor")
    d.escape()
    return rig
}

func checkOutputs() {
    section("Render, export, project, copy")
    var saved: (Document, AssetStore)?
    var copied = 0
    let pb = NSPasteboard(name: NSPasteboard.Name("kadraj.harness.copy"))
    let rig = makeBusyRig(callbacks: EditorCallbacks(onSaveProject: { saved = ($0, $1) }, onCopied: { copied += 1 }), pasteboard: pb)
    let c = rig.controller
    var bg = BackgroundStyle()
    bg.fill = .builtin(index: 2); bg.padding = 60; bg.cornerRadius = 16
    c.perform(.setBackground(bg))
    c.perform(.setCrop(CGRect(x: 40, y: 40, width: 1000, height: 650)))
    c.perform(.setOutputScale(0.75))
    check("busy document has annotations", rig.doc.annotations.count >= 8, "\(rig.doc.annotations.count)")

    let rendered = c.renderedImage()
    let direct = Renderer.render(rig.doc, assets: rig.assets)
    check("renderedImage equals Renderer.render pixel for pixel", samePixels(rendered, direct))
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kadraj-harness-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let pngURL = dir.appendingPathComponent("out.png")
    try? c.exportImage(to: pngURL)
    let want = try? Exporter.data(for: rig.doc, assets: rig.assets, format: .png)
    check("exported PNG bytes equal Exporter output", (try? Data(contentsOf: pngURL)) == want && want != nil)
    let jpgURL = dir.appendingPathComponent("out.jpg")
    try? c.exportImage(to: jpgURL)
    check("exporting to .jpg writes a JPEG", (try? Data(contentsOf: jpgURL))?.starts(with: [0xFF, 0xD8]) == true)

    // On-screen paint at zoom 1 is the exported image.
    c.perform(.setOutputScale(1))
    var flat = bg
    flat.shadow = false
    c.perform(.setBackground(flat))
    c.zoom = 1
    c.select(nil)
    relayout(rig)
    let view = c.canvasView
    let m = EditorWindowController.canvasMargin
    let size = Renderer.canvasSize(rig.doc, assets: rig.assets)
    let region = CGRect(x: m, y: m, width: size.width, height: size.height)
    let full = view.bounds
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(full.width), pixelsHigh: Int(full.height), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 32)!
    let gctx = NSGraphicsContext(bitmapImageRep: rep)!
    view.displayIgnoringOpacity(full, in: gctx)
    writePNG(rep, to: snapshotDir.appendingPathComponent("paint-screen.png"))
    let screen = rep.cgImage!.cropping(to: CGRect(x: m, y: m, width: size.width, height: size.height))!
    writePNG(NSBitmapImageRep(cgImage: Renderer.render(rig.doc, assets: rig.assets)), to: snapshotDir.appendingPathComponent("paint-export.png"))
    let export = Renderer.render(rig.doc, assets: rig.assets)
    let a = pixels(export)
    var b = [UInt8](repeating: 0, count: a.count)
    let ctx = CGContext(data: &b, width: export.width, height: export.height, bitsPerComponent: 8, bytesPerRow: export.width * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(screen, in: CGRect(x: 0, y: 0, width: export.width, height: export.height))
    var maxDiff = 0, sum = 0
    for i in 0..<a.count { let dlt = abs(Int(a[i]) - Int(b[i])); maxDiff = max(maxDiff, dlt); sum += dlt }
    let mean = Double(sum) / Double(a.count)
    check("canvas view at 100% matches the export (same paint path)", screen.width == export.width && screen.height == export.height && mean < 0.2,
          "size \(screen.width)x\(screen.height) vs \(export.width)x\(export.height) mean diff \(mean) max \(maxDiff)")
    print("INFO screen vs export: mean abs diff \(String(format: "%.4f", mean)), max \(maxDiff)")

    c.zoom = 0.6
    d_key(rig, "c", [.command])
    let clip = pb.data(forType: .png).flatMap(cgImage(from:))
    check("Cmd+C puts the rendered image on the pasteboard", clip.map { samePixels($0, c.renderedImage()) } ?? false)
    check("Cmd+C reports onCopied", copied == 1)

    let projectURL = dir.appendingPathComponent("test.kadraj", isDirectory: true)
    try? c.saveProject(to: projectURL)
    check("saving a project calls onSaveProject with the document", saved?.0 == rig.doc)
    if let (doc2, assets2) = try? ProjectFile.read(from: projectURL) {
        check("reading the project back gives an equal document", doc2 == rig.doc)
        check("project assets are byte equal", rig.doc.referencedAssets.allSatisfy { assets2.data(for: $0) == rig.assets.data(for: $0) })
        let reopened = EditorWindowController(document: doc2, assets: assets2, defaults: defaults)
        check("reopened editor has the same document and render", reopened.currentDocument == rig.doc && samePixels(reopened.renderedImage(), c.renderedImage()))
    } else { check("project reads back", false) }
    try? FileManager.default.removeItem(at: dir)

    let drag = try? c.makeDragFile()
    check("Drag me writes a PNG file equal to the render",
          drag.flatMap { try? Data(contentsOf: $0) }.flatMap(cgImage(from:)).map { samePixels($0, c.renderedImage()) } ?? false)
    drag.map { try? FileManager.default.removeItem(at: $0) }
    closeRig(rig)
}

func d_key(_ rig: Rig, _ ch: Character, _ flags: NSEvent.ModifierFlags) { rig.driver.tapKey(ch, flags: flags) }

func checkDrop() {
    section("Dropped images")
    let rig = makeRig(zoom: 0.6)
    let d = rig.driver, c = rig.controller
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kadraj-drop-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let ctx = CGContext(data: nil, width: 200, height: 120, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(srgbRed: 0, green: 0.8, blue: 0, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 120))
    let url = dir.appendingPathComponent("dropped.png")
    try? AssetStore.pngData(from: ctx.makeImage()!)?.write(to: url)
    let pb = NSPasteboard(name: NSPasteboard.Name("kadraj.harness.drop"))
    pb.clearContents()
    pb.writeObjects([url as NSURL])

    let ok = c.drop(pb, atWindowPoint: d.windowPoint(source: CGPoint(x: 600, y: 400)))
    check("dropping an image file is accepted", ok)
    if case .image(let r, let asset)? = rig.last?.kind {
        check("it becomes an image annotation centred on the drop point", near(r, CGRect(x: 500, y: 340, width: 200, height: 120), 1.5), fmt(r))
        check("the asset is stored in the asset store", rig.assets.contains(asset))
        check("the new image is selected", c.selection == rig.last?.id)
        let px = pixel(c.renderedImage(), 600, 400)
        check("the render shows the image pixels", px.g > 180 && px.r < 40, "\(px)")

        d.tapKey("v")
        d.drag(source: CGPoint(x: 600, y: 400), to: CGPoint(x: 650, y: 430))
        check("the image moves with a drag", annRect(rig.last).map { near($0, CGRect(x: 550, y: 370, width: 200, height: 120), 1.5) } ?? false, annRect(rig.last).map(fmt) ?? "nil")
        let moved = annRect(rig.last)!
        d.drag(source: CGPoint(x: moved.maxX, y: moved.maxY), to: CGPoint(x: moved.maxX + 100, y: moved.maxY + 10))
        let resized = annRect(rig.last)!
        check("a corner handle resizes the image and keeps its aspect", abs(resized.width / resized.height - 200.0 / 120) < 0.02 && resized.width > 250, fmt(resized))
    } else { check("drop produced an image annotation", false) }
    d.key("z", code: 6, flags: .command)
    d.key("z", code: 6, flags: .command)
    d.key("z", code: 6, flags: .command)
    check("undo removes the dropped image", rig.doc.annotations.isEmpty)
    try? FileManager.default.removeItem(at: dir)
    closeRig(rig)
}
