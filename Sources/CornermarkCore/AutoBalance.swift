import CoreGraphics
import Foundation

enum AutoBalance {
    /// Per-channel difference under which two pixels count as the same margin color.
    static let tolerance = 10

    /// Shrinks `crop` so the uniform margin on every side of `image` becomes equal to the smallest
    /// one. A side with no margin therefore pulls every side down to zero.
    static func balancedCrop(of image: CGImage, crop: CGRect) -> CGRect {
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let crop = crop.integralClamped(to: bounds)
        guard !crop.isNull, let sub = image.cropping(to: crop), let buf = PixelBuffer(image: sub) else { return crop }
        let w = buf.width, h = buf.height

        func differs(_ i: Int, _ ref: Int) -> Bool {
            for c in 0..<4 where abs(Int(buf.bytes[i + c]) - Int(buf.bytes[ref + c])) > tolerance { return true }
            return false
        }
        func rowUniform(_ y: Int, ref: Int, x0: Int, x1: Int) -> Bool {
            for x in x0..<x1 where differs((y * w + x) * 4, ref) { return false }
            return true
        }
        func colUniform(_ x: Int, ref: Int, y0: Int, y1: Int) -> Bool {
            for y in y0..<y1 where differs((y * w + x) * 4, ref) { return false }
            return true
        }

        let midX = w / 2, midY = h / 2
        var top = 0
        let topRef = (0 * w + midX) * 4
        while top < h, rowUniform(top, ref: topRef, x0: 0, x1: w) { top += 1 }
        guard top < h else { return crop }

        var bottom = 0
        let bottomRef = ((h - 1) * w + midX) * 4
        while bottom < h - top, rowUniform(h - 1 - bottom, ref: bottomRef, x0: 0, x1: w) { bottom += 1 }

        let y0 = top, y1 = h - bottom
        var left = 0
        let leftRef = (midY * w) * 4
        while left < w, colUniform(left, ref: leftRef, y0: y0, y1: y1) { left += 1 }
        var right = 0
        let rightRef = (midY * w + w - 1) * 4
        while right < w - left, colUniform(w - 1 - right, ref: rightRef, y0: y0, y1: y1) { right += 1 }

        guard left + right < w else { return crop }
        let target = min(top, bottom, left, right)
        let dl = CGFloat(left - target), dt = CGFloat(top - target)
        let dr = CGFloat(right - target), db = CGFloat(bottom - target)
        return CGRect(x: crop.minX + dl, y: crop.minY + dt,
                      width: crop.width - dl - dr, height: crop.height - dt - db)
    }
}
