import AppKit

/// The well a picture of unknown shape sits in: a sunken, rounded field with the picture fitted inside it, so pictures of
/// different proportions line up in a grid instead of leaving ragged gaps.
public enum ImageWell {
    /// Draws the well in `rect` in the current graphics context, flipped or not, and the image fitted to it. The image is
    /// clipped to the well's shape and the outline is stroked inside the shape on top of it.
    public static func draw(_ image: CGImage?, in rect: CGRect, radius: CGFloat = DS.Radius.md) {
        let well = NSBezierPath.continuous(rect, radius: radius)
        Paint.fill(well, DS.Color.bgSunken)
        if let image, image.width > 0, image.height > 0, rect.width > 0, rect.height > 0 {
            let size = CGSize(width: image.width, height: image.height)
            let scale = min(rect.width / size.width, rect.height / size.height)
            let fitted = CGRect(x: rect.midX - size.width * scale / 2, y: rect.midY - size.height * scale / 2,
                                width: size.width * scale, height: size.height * scale)
            NSGraphicsContext.saveGraphicsState()
            well.addClip()
            NSGraphicsContext.current?.imageInterpolation = .high
            // respectFlipped keeps the picture upright in a flipped view, where a plain draw would turn it over.
            NSImage(cgImage: image, size: fitted.size).draw(in: fitted, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
        }
        Paint.strokeInside(well, DS.Color.imageOutline)
    }
}
