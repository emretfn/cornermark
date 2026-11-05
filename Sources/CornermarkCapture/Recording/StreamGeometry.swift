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

    /// Pixels for a point rect, rounded to even sides.
    public static func format(of rect: CGRect, scale: Double, fps: Int) -> FrameFormat {
        FrameFormat(width: Int((rect.width * scale).rounded()), height: Int((rect.height * scale).rounded()), fps: fps)
    }
}
