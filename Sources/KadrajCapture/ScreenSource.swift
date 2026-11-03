import CoreGraphics

public protocol ScreenSource {
    func displays() async throws -> [DisplaySnapshot]
    /// Front to back, excluding our own windows.
    func windows() async throws -> [WindowSnapshot]
    func image(of window: WindowSnapshot, options: WindowCaptureOptions) async throws -> CGImage
    func capture(displayID: CGDirectDisplayID) async throws -> DisplaySnapshot
}

enum ImageCrop {
    /// Pixel rect (top-left origin) of a global-points rect inside a display image.
    static func pixelRect(of rect: CGRect, in display: DisplaySnapshot) -> CGRect {
        let f = display.frame, image = display.image
        let sx = Double(image.width) / f.width, sy = Double(image.height) / f.height
        let x0 = ((rect.minX - f.minX) * sx).rounded(), x1 = ((rect.maxX - f.minX) * sx).rounded()
        let y0 = ((f.maxY - rect.maxY) * sy).rounded(), y1 = ((f.maxY - rect.minY) * sy).rounded()
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0).intersection(bounds)
    }

    /// A detached copy, so a small crop does not keep a whole display's pixels alive.
    static func crop(_ display: DisplaySnapshot, rect: CGRect) -> CGImage? {
        let px = pixelRect(of: rect, in: display)
        guard !px.isNull, px.width >= 1, px.height >= 1, let cropped = display.image.cropping(to: px) else { return nil }
        return detached(cropped)
    }

    static func detached(_ image: CGImage) -> CGImage {
        guard let space = image.colorSpace,
              let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return image }
        ctx.interpolationQuality = .none
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx.makeImage() ?? image
    }
}
