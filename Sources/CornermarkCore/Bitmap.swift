import CoreGraphics
import Foundation

enum Bitmap {
    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
    static let info = CGImageAlphaInfo.premultipliedLast.rawValue
    static let maxPixels = 400_000_000

    /// A zeroed RGBA context. With `yDown` the CTM is flipped so drawing uses top-left-origin
    /// coordinates; the backing memory is always row 0 = top row.
    static func makeContext(width: Int, height: Int, yDown: Bool) -> CGContext? {
        guard width > 0, height > 0, width * height <= maxPixels else { return nil }
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: sRGB, bitmapInfo: info) else { return nil }
        if yDown {
            ctx.translateBy(x: 0, y: CGFloat(height))
            ctx.scaleBy(x: 1, y: -1)
        }
        ctx.interpolationQuality = .high
        return ctx
    }

    static func blankImage(width: Int = 1, height: Int = 1) -> CGImage {
        let ctx = makeContext(width: max(1, width), height: max(1, height), yDown: false)!
        return ctx.makeImage()!
    }
}

extension CGContext {
    /// Draws `image` upright into `rect`, for a context whose user space is y-down.
    func drawImageYDown(_ image: CGImage, in rect: CGRect) {
        saveGState()
        translateBy(x: rect.minX, y: rect.maxY)
        scaleBy(x: 1, y: -1)
        draw(image, in: CGRect(x: 0, y: 0, width: rect.width, height: rect.height))
        restoreGState()
    }
}

/// Tightly packed premultiplied RGBA, row 0 = top.
struct PixelBuffer {
    var width: Int
    var height: Int
    var bytes: [UInt8]

    init(width: Int, height: Int, bytes: [UInt8]) {
        self.width = width; self.height = height; self.bytes = bytes
    }

    init?(image: CGImage) {
        let w = image.width, h = image.height
        guard let ctx = Bitmap.makeContext(width: w, height: h, yDown: false) else { return nil }
        ctx.interpolationQuality = .none
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return nil }
        let bpr = ctx.bytesPerRow
        var out = [UInt8](repeating: 0, count: w * h * 4)
        out.withUnsafeMutableBytes { dst in
            for y in 0..<h {
                memcpy(dst.baseAddress! + y * w * 4, data + y * bpr, w * 4)
            }
        }
        self.init(width: w, height: h, bytes: out)
    }

    func makeImage() -> CGImage? {
        guard width > 0, height > 0 else { return nil }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: Bitmap.sRGB,
                       bitmapInfo: CGBitmapInfo(rawValue: Bitmap.info), provider: provider,
                       decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    func pixel(_ x: Int, _ y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        let i = (y * width + x) * 4
        return (bytes[i], bytes[i + 1], bytes[i + 2], bytes[i + 3])
    }
}
