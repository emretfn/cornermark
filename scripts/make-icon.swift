import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// Usage: swift make-icon.swift <output.icns>
// Draws the Kadraj icon (a viewfinder over a deep blue squircle) at every size an .icns needs.

func drawIcon(size: Int) -> CGImage {
    let s = CGFloat(size)
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high

    let inset = s * 0.055
    let plate = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let squircle = CGPath(roundedRect: plate, cornerWidth: plate.width * 0.225, cornerHeight: plate.width * 0.225, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03, color: CGColor(gray: 0, alpha: 0.35))
    ctx.addPath(squircle)
    ctx.setFillColor(CGColor(srgbRed: 0.09, green: 0.11, blue: 0.28, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()
    let bg = CGGradient(colorsSpace: space, colors: [
        CGColor(srgbRed: 0.17, green: 0.20, blue: 0.55, alpha: 1),
        CGColor(srgbRed: 0.07, green: 0.09, blue: 0.24, alpha: 1),
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: s * 0.2, y: s * 0.95), end: CGPoint(x: s * 0.8, y: s * 0.05), options: [])
    let glow = CGGradient(colorsSpace: space, colors: [
        CGColor(srgbRed: 0.25, green: 0.85, blue: 0.80, alpha: 0.55),
        CGColor(srgbRed: 0.25, green: 0.85, blue: 0.80, alpha: 0),
    ] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: s * 0.5, y: s * 0.5), startRadius: 0,
                           endCenter: CGPoint(x: s * 0.5, y: s * 0.5), endRadius: s * 0.46, options: [])

    // Viewfinder: four corner brackets framing the plate.
    let frame = plate.insetBy(dx: plate.width * 0.2, dy: plate.width * 0.2)
    let arm = frame.width * 0.28
    let weight = max(1, s * 0.05)
    ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.96))
    ctx.setLineWidth(weight)
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

    // Aperture: a ring with a solid core in the centre of the frame.
    let c = CGPoint(x: plate.midX, y: plate.midY)
    let ring = frame.width * 0.2
    ctx.setStrokeColor(CGColor(srgbRed: 0.45, green: 0.95, blue: 0.88, alpha: 1))
    ctx.setLineWidth(weight * 0.8)
    ctx.strokeEllipse(in: CGRect(x: c.x - ring, y: c.y - ring, width: ring * 2, height: ring * 2))
    let core = ring * 0.42
    ctx.setFillColor(CGColor(srgbRed: 0.45, green: 0.95, blue: 0.88, alpha: 1))
    ctx.fillEllipse(in: CGRect(x: c.x - core, y: c.y - core, width: core * 2, height: core * 2))
    ctx.restoreGState()

    ctx.addPath(squircle)
    ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.12))
    ctx.setLineWidth(max(1, s * 0.004))
    ctx.strokePath()
    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) {
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("could not write \(url.path)") }
}

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: make-icon.swift <output.icns>\n".utf8))
    exit(2)
}
let out = URL(fileURLWithPath: CommandLine.arguments[1])
let fm = FileManager.default
let iconset = fm.temporaryDirectory.appendingPathComponent("Kadraj-\(UUID().uuidString).iconset")
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
