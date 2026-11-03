import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// Usage: swift make-dmg-background.swift <output.png>
// Draws the installer window background as a Cornermark capture in progress. Writes <output>.png at 1x and <output>@2x.png at 2x;
// dmgbuild finds the pair and combines them into a HiDPI TIFF. Coordinates are in points with the origin at the top left,
// the way Finder reports icon positions. dmg-settings.py places the icons at appIcon and applicationsIcon below.

let size = CGSize(width: 660, height: 420)
let appIcon = CGPoint(x: 180, y: 190)
let applicationsIcon = CGPoint(x: 480, y: 190)
let iconSize: CGFloat = 128

let lemon = CGColor(srgbRed: 0.941, green: 0.894, blue: 0.247, alpha: 1)

func brackets(around frame: CGRect, arm: CGFloat, in ctx: CGContext) {
    let corners: [(CGPoint, CGFloat, CGFloat)] = [
        (CGPoint(x: frame.minX, y: frame.minY), 1, 1), (CGPoint(x: frame.maxX, y: frame.minY), -1, 1),
        (CGPoint(x: frame.minX, y: frame.maxY), 1, -1), (CGPoint(x: frame.maxX, y: frame.maxY), -1, -1),
    ]
    for (p, dx, dy) in corners {
        ctx.move(to: CGPoint(x: p.x + dx * arm, y: p.y))
        ctx.addLine(to: p)
        ctx.addLine(to: CGPoint(x: p.x, y: p.y + dy * arm))
        ctx.strokePath()
    }
}

// The tapered style of the editor's arrow annotation: a thin tail that widens into a triangular head.
func taperedArrow(from: CGPoint, to: CGPoint, width: CGFloat, in ctx: CGContext) {
    let length = hypot(to.x - from.x, to.y - from.y)
    let dir = CGPoint(x: (to.x - from.x) / length, y: (to.y - from.y) / length)
    let n = CGPoint(x: -dir.y, y: dir.x)
    let headLength = max(width * 4.2, 14)
    let headHalfWidth = headLength * 0.6
    let tail = max(width * 0.12, 0.5), mid = max(width * 0.65, 2)
    let base = CGPoint(x: to.x - dir.x * headLength, y: to.y - dir.y * headLength)
    func at(_ p: CGPoint, _ k: CGFloat) -> CGPoint { CGPoint(x: p.x + n.x * k, y: p.y + n.y * k) }
    let outline = [at(from, tail), at(base, mid), at(base, headHalfWidth), to, at(base, -headHalfWidth), at(base, -mid), at(from, -tail)]
    ctx.addLines(between: outline)
    ctx.closePath()
    ctx.fillPath()
    ctx.fillEllipse(in: CGRect(x: from.x - tail, y: from.y - tail, width: tail * 2, height: tail * 2))
}

func draw(scale: Int) -> CGImage {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: Int(size.width) * scale, height: Int(size.height) * scale, bitsPerComponent: 8,
                        bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high
    ctx.translateBy(x: 0, y: size.height * CGFloat(scale))
    ctx.scaleBy(x: CGFloat(scale), y: -CGFloat(scale))

    let plate = CGGradient(colorsSpace: space, colors: [
        CGColor(srgbRed: 0.19, green: 0.185, blue: 0.175, alpha: 1),
        CGColor(srgbRed: 0.08, green: 0.08, blue: 0.07, alpha: 1),
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(plate, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])

    // The selection is the one clear area, like the capture overlay; the brackets are the viewfinder from the app icon.
    let target = CGRect(x: applicationsIcon.x - 96, y: applicationsIcon.y - 86, width: 192, height: 192)
    ctx.setFillColor(CGColor(gray: 1, alpha: 0.05))
    ctx.addPath(CGPath(roundedRect: target, cornerWidth: 10, cornerHeight: 10, transform: nil))
    ctx.fillPath()
    ctx.setStrokeColor(lemon)
    ctx.setLineWidth(4.5)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    brackets(around: target, arm: 34, in: ctx)

    ctx.setFillColor(lemon)
    let gap: CGFloat = 20
    taperedArrow(from: CGPoint(x: appIcon.x + iconSize / 2 + gap, y: appIcon.y),
                 to: CGPoint(x: target.minX - gap, y: applicationsIcon.y), width: 8, in: ctx)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
    let center = NSMutableParagraphStyle()
    center.alignment = .center
    let lines: [(String, CGFloat, CGFloat, CGFloat)] = [
        ("Drag Cornermark to Applications.", 13, 0.66, 352),
        ("First launch: if macOS blocks it, open System Settings > Privacy & Security and click Open Anyway.", 11, 0.5, 376),
    ]
    for (text, fontSize, alpha, top) in lines {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize),
            .foregroundColor: NSColor(white: 1, alpha: alpha),
            .paragraphStyle: center,
        ]
        text.draw(in: CGRect(x: 0, y: top, width: size.width, height: fontSize * 1.4), withAttributes: attributes)
    }
    NSGraphicsContext.restoreGraphicsState()
    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, dpi: Double, to url: URL) {
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi] as CFDictionary)
    guard CGImageDestinationFinalize(dest) else { fatalError("could not write \(url.path)") }
}

guard CommandLine.arguments.count == 2, CommandLine.arguments[1].hasSuffix(".png") else {
    FileHandle.standardError.write(Data("usage: make-dmg-background.swift <output.png>\n".utf8))
    exit(2)
}
let out = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
let retina = out.deletingLastPathComponent().appendingPathComponent(out.deletingPathExtension().lastPathComponent + "@2x.png")
writePNG(draw(scale: 1), dpi: 72, to: out)
writePNG(draw(scale: 2), dpi: 144, to: retina)
print("wrote \(out.path) and \(retina.path)")
