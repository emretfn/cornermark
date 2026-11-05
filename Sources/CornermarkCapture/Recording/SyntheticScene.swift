import AppKit

/// A moving picture with no real content, for tests and for the window that verification records.
/// The corner colors tell orientation and crops apart, the bar tells motion, the clock tells time.
public enum SyntheticScene {
    public static let caption = "CORNERMARK TEST SCENE"
    public static let note = "synthetic, no real content"
    /// Seconds for the bar to cross once. It sweeps there and back.
    public static let barPeriod = 1.6
    public static let barWidthFraction = 0.08
    public static let cornerFraction = 0.12
    /// Top-left, top-right, bottom-left, bottom-right.
    public static let corners: [NSColor] = [
        NSColor(srgbRed: 0.90, green: 0.15, blue: 0.15, alpha: 1), NSColor(srgbRed: 0.15, green: 0.75, blue: 0.25, alpha: 1),
        NSColor(srgbRed: 0.20, green: 0.35, blue: 0.95, alpha: 1), NSColor(srgbRed: 0.95, green: 0.80, blue: 0.10, alpha: 1),
    ]
    public static let background = NSColor(srgbRed: 0.09, green: 0.10, blue: 0.13, alpha: 1)

    /// Where the bar sits, 0 at the left edge and 1 at the right, as a triangle wave.
    public static func barFraction(at time: Double) -> Double {
        let phase = (time / (barPeriod * 2)).truncatingRemainder(dividingBy: 1)
        let p = phase < 0 ? phase + 1 : phase
        return p < 0.5 ? p * 2 : 2 - p * 2
    }

    public static func timecode(_ time: Double) -> String {
        let ms = max(0, Int((time * 1000).rounded()))
        return String(format: "%02d:%02d.%03d", ms / 60000, (ms / 1000) % 60, ms % 1000)
    }

    /// Draws into the current graphics context, which must have a top-left origin.
    public static func draw(size: CGSize, time: Double) {
        let w = size.width, h = size.height
        background.setFill()
        NSBezierPath.fill(CGRect(origin: .zero, size: size))

        NSColor(white: 1, alpha: 0.07).setFill()
        let step = max(8, (min(w, h) / 9).rounded())
        var x = step
        while x < w { NSBezierPath.fill(CGRect(x: x, y: 0, width: 1, height: h)); x += step }
        var y = step
        while y < h { NSBezierPath.fill(CGRect(x: 0, y: y, width: w, height: 1)); y += step }

        let barW = w * barWidthFraction
        NSColor(white: 0.93, alpha: 1).setFill()
        NSBezierPath.fill(CGRect(x: barFraction(at: time) * (w - barW), y: h * 0.24, width: barW, height: h * 0.52))

        let c = min(w, h) * cornerFraction
        let origins = [CGPoint(x: 0, y: 0), CGPoint(x: w - c, y: 0), CGPoint(x: 0, y: h - c), CGPoint(x: w - c, y: h - c)]
        for (color, origin) in zip(corners, origins) {
            color.setFill()
            NSBezierPath.fill(CGRect(origin: origin, size: CGSize(width: c, height: c)))
        }

        drawCentered(timecode(time), font: .monospacedDigitSystemFont(ofSize: h * 0.15, weight: .bold), color: .white, y: h * 0.40, width: w)
        drawCentered(caption, font: .systemFont(ofSize: h * 0.05, weight: .semibold), color: NSColor(white: 0.85, alpha: 1), y: h * 0.04, width: w)
        drawCentered(note, font: .systemFont(ofSize: h * 0.04, weight: .regular), color: NSColor(white: 0.6, alpha: 1), y: h * 0.90, width: w)
    }

    /// An arrow pointer with its tip at `tip`, in a context with a top-left origin.
    public static func drawPointer(at tip: CGPoint) {
        let shape: [CGPoint] = [(0, 0), (0, 17), (4, 13), (7, 20), (10, 19), (7, 12), (12, 12)].map { CGPoint(x: tip.x + $0.0 * 1.4, y: tip.y + $0.1 * 1.4) }
        let path = NSBezierPath()
        path.move(to: shape[0])
        shape.dropFirst().forEach(path.line(to:))
        path.close()
        path.lineWidth = 1.5
        path.lineJoinStyle = .round
        NSColor.black.setFill()
        path.fill()
        NSColor.white.setStroke()
        path.stroke()
    }

    private static func drawCentered(_ text: String, font: NSFont, color: NSColor, y: CGFloat, width: CGFloat) {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        (text as NSString).draw(in: CGRect(x: 0, y: y, width: width, height: font.pointSize * 1.4),
                                withAttributes: [.font: font, .foregroundColor: color, .paragraphStyle: style])
    }
}
