import AppKit

/// Draws through the same NSGraphicsContext path a view's draw(_:) uses, into a bitmap whose pixels are `scale` times its points.
func render(size: CGSize, scale: CGFloat, flipped: Bool, appearance: NSAppearance.Name = .aqua, _ draw: () -> Void) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    var context = NSGraphicsContext(bitmapImageRep: rep)!
    if flipped {
        context.cgContext.translateBy(x: 0, y: size.height)
        context.cgContext.scaleBy(x: 1, y: -1)
        context = NSGraphicsContext(cgContext: context.cgContext, flipped: true)
    }
    let saved = NSGraphicsContext.current
    NSGraphicsContext.current = context
    NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance(draw)
    context.flushGraphics()
    NSGraphicsContext.current = saved
    return rep
}

func writePNG(_ rep: NSBitmapImageRep, to url: URL) {
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    if let data = rep.representation(using: .png, properties: [:]) { try? data.write(to: url) }
}

func pixel(_ rep: NSBitmapImageRep, x: Int, y: Int) -> RGBA {
    let c = rep.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
    return RGBA(r: Double(c.redComponent), g: Double(c.greenComponent), b: Double(c.blueComponent), a: Double(c.alphaComponent))
}
