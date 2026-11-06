import CoreGraphics

/// Pure rect math between the AppKit points a link names and the display-local points a stream wants.
public enum StreamGeometry {
    /// `area` and `displayFrame` are global AppKit points (bottom-left origin). The result is display-local with a top-left origin,
    /// clipped to the display. Nil when the area misses the display.
    public static func sourceRect(area: CGRect, displayFrame: CGRect) -> CGRect? {
        let clipped = area.standardized.intersection(displayFrame)
        guard !clipped.isNull, clipped.width >= 1, clipped.height >= 1 else { return nil }
        return CGRect(x: clipped.minX - displayFrame.minX, y: displayFrame.maxY - clipped.maxY, width: clipped.width, height: clipped.height)
    }

    /// Pixels for a point rect on a display with `scale` pixels per point, after the density and size limit in `options`, rounded to even sides.
    public static func format(of rect: CGRect, scale: Double, options: RecordingOptions) -> FrameFormat {
        let density = options.density == .standard ? 1 : scale
        var w = rect.width * density, h = rect.height * density
        if let box = options.limit.box, w > 0, h > 0 {
            let (bw, bh) = w >= h ? (box.long, box.short) : (box.short, box.long)
            let f = min(1, bw / w, bh / h)
            w *= f; h *= f
        }
        return FrameFormat(width: Int(w.rounded()), height: Int(h.rounded()), fps: options.fps)
    }
}
