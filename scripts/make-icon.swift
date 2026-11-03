import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// Usage: swift make-icon.swift <output.icns|output.png>
// Draws the Cornermark icon (a lemon viewfinder on a graphite plate) at every size an .icns needs, or once at 512 for a .png.

func superellipse(_ r: CGRect) -> CGPath {
    let path = CGMutablePath()
    let exponent = 2.0 / 5.0
    for i in 0..<720 {
        let t = Double(i) / 720 * 2 * .pi
        let x = r.midX + r.width / 2 * CGFloat(copysign(pow(abs(cos(t)), exponent), cos(t)))
        let y = r.midY + r.height / 2 * CGFloat(copysign(pow(abs(sin(t)), exponent), sin(t)))
        if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
    }
    path.closeSubpath()
    return path
}

func drawIcon(size: Int) -> CGImage {
    let s = CGFloat(size)
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high

    // The plate follows Apple's icon grid so the icon matches its neighbours' size in the Dock.
    let inset = s * 0.098
    let plate = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let shape = superellipse(plate)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03, color: CGColor(gray: 0, alpha: 0.3))
    ctx.addPath(shape)
    ctx.setFillColor(CGColor(srgbRed: 0.08, green: 0.08, blue: 0.07, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    let bg = CGGradient(colorsSpace: space, colors: [
        CGColor(srgbRed: 0.19, green: 0.185, blue: 0.175, alpha: 1),
        CGColor(srgbRed: 0.08, green: 0.08, blue: 0.07, alpha: 1),
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: s), end: .zero, options: [])
    ctx.restoreGState()

    // A hairline keeps the graphite plate visible on dark wallpapers and in a dark Dock.
    ctx.addPath(shape)
    ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.14))
    ctx.setLineWidth(max(1, s * 0.004))
    ctx.strokePath()

    // Viewfinder: four corner brackets in the design system's accent, oklch(0.90 0.18 105). Small sizes thicken the strokes to stay legible.
    let small = size < 48
    let frame = plate.insetBy(dx: plate.width * (small ? 0.17 : 0.2), dy: plate.width * (small ? 0.17 : 0.2))
    let arm = frame.width * (small ? 0.24 : 0.3)
    ctx.setStrokeColor(CGColor(srgbRed: 0.941, green: 0.894, blue: 0.247, alpha: 1))
    ctx.setLineWidth(s * (small ? 0.085 : 0.062))
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    let corners: [(CGPoint, CGFloat, CGFloat)] = [
        (CGPoint(x: frame.minX, y: frame.maxY), 1, -1), (CGPoint(x: frame.maxX, y: frame.maxY), -1, -1),
        (CGPoint(x: frame.minX, y: frame.minY), 1, 1), (CGPoint(x: frame.maxX, y: frame.minY), -1, 1),
    ]
    for (p, dx, dy) in corners {
        ctx.move(to: CGPoint(x: p.x + dx * arm, y: p.y))
        ctx.addLine(to: p)
        ctx.addLine(to: CGPoint(x: p.x, y: p.y + dy * arm))
        ctx.strokePath()
    }
    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) {
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("could not write \(url.path)") }
}

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: make-icon.swift <output.icns|output.png>\n".utf8))
    exit(2)
}
let out = URL(fileURLWithPath: CommandLine.arguments[1])
let fm = FileManager.default
if out.pathExtension == "png" {
    try fm.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
    writePNG(drawIcon(size: 512), to: out)
    print("wrote \(out.path)")
    exit(0)
}
let iconset = fm.temporaryDirectory.appendingPathComponent("Cornermark-\(UUID().uuidString).iconset")
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: iconset) }

for base in [16, 32, 128, 256, 512] {
    writePNG(drawIcon(size: base), to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    writePNG(drawIcon(size: base * 2), to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
try fm.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", out.path]
try task.run()
task.waitUntilExit()
guard task.terminationStatus == 0 else { fatalError("iconutil failed") }
print("wrote \(out.path)")
