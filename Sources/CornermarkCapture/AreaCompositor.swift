import CoreGraphics

public struct AreaComposite {
    public var image: CGImage
    public var pointScale: Double
}

/// Turns a selection in global AppKit points into one image cut from the frozen displays it touches.
public enum AreaCompositor {
    /// Nil when the rect lies on no display.
    public static func composite(rect: CGRect, displays: [DisplaySnapshot]) -> AreaComposite? {
        let parts = displays.filter { !$0.frame.intersection(rect).isEmpty }
        guard let first = parts.first else { return nil }

        // One display holds the whole rect: keep the exact crop, no canvas and no resampling.
        if parts.count == 1, first.frame.intersection(rect) == rect {
            return ImageCrop.crop(first, rect: rect).map { AreaComposite(image: $0, pointScale: first.scale) }
        }

        let scale = parts.map(\.scale).max() ?? 1
        let s = CGFloat(scale)
        let width = Int((rect.width * s).rounded()), height = Int((rect.height * s).rounded())
        guard width >= 1, height >= 1,
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }

        for part in parts {
            let overlap = part.frame.intersection(rect)
            let source = ImageCrop.pixelRect(of: overlap, in: part)
            guard !source.isNull, source.width >= 1, source.height >= 1, let piece = part.image.cropping(to: source) else { continue }
            // Neighbours round their shared edge identically, so no seam opens between them. The canvas has
            // the same y-up orientation as global points, so the piece needs no flip.
            let x0 = ((overlap.minX - rect.minX) * s).rounded(), x1 = ((overlap.maxX - rect.minX) * s).rounded()
            let y0 = ((overlap.minY - rect.minY) * s).rounded(), y1 = ((overlap.maxY - rect.minY) * s).rounded()
            let dest = CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
            ctx.saveGState()
            ctx.clip(to: dest)
            ctx.interpolationQuality = Int(dest.width) == piece.width && Int(dest.height) == piece.height ? .none : .high
            ctx.draw(piece, in: dest)
            ctx.restoreGState()
        }
        return ctx.makeImage().map { AreaComposite(image: $0, pointScale: scale) }
    }
}
