import AppKit

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}

enum Align { case left, center, right }

/// A y-down drawing surface measured in points and backed by a bitmap at `scale` pixels per point.
final class Canvas {
    let size: CGSize
    let scale: CGFloat
    let ctx: CGContext
    private let gfx: NSGraphicsContext

    init(size: CGSize, scale: CGFloat = 2) {
        self.size = size
        self.scale = scale
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        ctx = CGContext(data: nil, width: Int((size.width * scale).rounded()), height: Int((size.height * scale).rounded()),
                        bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.translateBy(x: 0, y: size.height * scale)
        ctx.scaleBy(x: scale, y: -scale)
        ctx.interpolationQuality = .high
        gfx = NSGraphicsContext(cgContext: ctx, flipped: true)
    }

    func image() -> CGImage { ctx.makeImage()! }

    func withState(_ body: () -> Void) {
        ctx.saveGState()
        body()
        ctx.restoreGState()
    }

    // MARK: Shapes

    func fill(_ rect: CGRect, _ color: NSColor, radius: CGFloat = 0) {
        ctx.setFillColor(color.cgColor)
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.fillPath()
    }

    func stroke(_ rect: CGRect, _ color: NSColor, radius: CGFloat = 0, width: CGFloat = 1) {
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(width)
        ctx.addPath(CGPath(roundedRect: rect.insetBy(dx: width / 2, dy: width / 2), cornerWidth: max(radius - width / 2, 0), cornerHeight: max(radius - width / 2, 0), transform: nil))
        ctx.strokePath()
    }

    func line(_ a: CGPoint, _ b: CGPoint, _ color: NSColor, width: CGFloat = 1, dash: [CGFloat] = []) {
        withState {
            ctx.setStrokeColor(color.cgColor)
            ctx.setLineWidth(width)
            ctx.setLineDash(phase: 0, lengths: dash)
            ctx.move(to: a)
            ctx.addLine(to: b)
            ctx.strokePath()
        }
    }

    func circle(center: CGPoint, radius: CGFloat, fill color: NSColor) {
        ctx.setFillColor(color.cgColor)
        ctx.fillEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    }

    /// `body` is drawn with a soft shadow beneath it. Offsets are in device pixels, which is what CoreGraphics expects.
    func shadowed(dy: CGFloat, blur: CGFloat, alpha: CGFloat, _ body: () -> Void) {
        withState {
            ctx.setShadow(offset: CGSize(width: 0, height: -dy * scale), blur: blur * scale, color: CGColor(gray: 0, alpha: alpha))
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            body()
            ctx.endTransparencyLayer()
        }
    }

    func drawImage(_ image: CGImage, in rect: CGRect) {
        withState {
            ctx.translateBy(x: rect.minX, y: rect.maxY)
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: rect.width, height: rect.height))
        }
    }

    func linearGradient(_ colors: [NSColor], in rect: CGRect, from: CGPoint, to: CGPoint) {
        let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: colors.map(\.cgColor) as CFArray,
                           locations: colors.indices.map { CGFloat($0) / CGFloat(max(colors.count - 1, 1)) })!
        withState {
            ctx.clip(to: rect)
            ctx.drawLinearGradient(g, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
    }

    // MARK: Text and symbols

    @discardableResult
    func text(_ string: String, at p: CGPoint, font: NSFont, color: NSColor, align: Align = .left, kern: CGFloat = 0) -> CGFloat {
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .kern: kern]
        let s = NSAttributedString(string: string, attributes: attrs)
        let w = s.size().width
        let x: CGFloat
        switch align {
        case .left: x = p.x
        case .center: x = p.x - w / 2
        case .right: x = p.x - w
        }
        withGraphics { s.draw(at: CGPoint(x: x, y: p.y)) }
        return w
    }

    func textWidth(_ string: String, font: NSFont) -> CGFloat {
        NSAttributedString(string: string, attributes: [.font: font]).size().width
    }

    func symbol(_ name: String, in rect: CGRect, color: NSColor, pointSize: CGFloat, weight: NSFont.Weight = .regular) {
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight).applying(.init(paletteColors: [color]))
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) else {
            fatalError("missing SF Symbol \(name)")
        }
        let s = image.size
        let fit = CGRect(x: rect.midX - s.width / 2, y: rect.midY - s.height / 2, width: s.width, height: s.height)
        withGraphics { image.draw(in: fit, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil) }
    }

    private func withGraphics(_ body: () -> Void) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = gfx
        body()
        NSGraphicsContext.restoreGraphicsState()
    }
}

enum Font {
    static func ui(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont { .systemFont(ofSize: size, weight: weight) }
    static func mono(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont { .monospacedSystemFont(ofSize: size, weight: weight) }
    static func digits(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont { .monospacedDigitSystemFont(ofSize: size, weight: weight) }
}

extension CGImage {
    func resized(toWidth width: Int) -> CGImage {
        guard width != self.width else { return self }
        let height = Int((Double(self.height) * Double(width) / Double(self.width)).rounded())
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.interpolationQuality = .high
        ctx.draw(self, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }

    func cropped(_ rect: CGRect) -> CGImage { cropping(to: rect.integral)! }
}
