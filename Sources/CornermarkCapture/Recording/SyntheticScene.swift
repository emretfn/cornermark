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

/// Another application's window on the fixture display: a fake notification banner, a fake desktop icon, or a fake Finder window.
/// They belong to made-up processes, so the exclusion plan treats them as it treats the real ones, and they hold no real content.
public struct FixtureWindow: Equatable {
    public enum Content: Equatable { case banner(title: String, body: String), desktopIcon(String), finderWindow(String) }
    public var app: ContentExclusion.App
    public var window: ContentExclusion.Window
    /// Display points with a top-left origin.
    public var frame: CGRect
    public var content: Content

    /// Draws into the current graphics context, which must have a top-left origin.
    public func draw() {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        func text(_ s: String, _ r: CGRect, _ size: CGFloat, _ weight: NSFont.Weight, _ color: NSColor, center: Bool = false) {
            style.alignment = center ? .center : .left
            (s as NSString).draw(in: r, withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color, .paragraphStyle: style])
        }
        switch content {
        case .banner(let title, let body):
            NSColor(white: 0.92, alpha: 1).setFill()
            NSBezierPath(roundedRect: frame, xRadius: 14, yRadius: 14).fill()
            NSColor(srgbRed: 0.85, green: 0.30, blue: 0.55, alpha: 1).setFill()
            NSBezierPath(roundedRect: CGRect(x: frame.minX + 12, y: frame.minY + 14, width: 36, height: 36), xRadius: 8, yRadius: 8).fill()
            text(title, CGRect(x: frame.minX + 60, y: frame.minY + 14, width: frame.width - 72, height: 20), 14, .semibold, .black)
            text(body, CGRect(x: frame.minX + 60, y: frame.minY + 36, width: frame.width - 72, height: 20), 13, .regular, NSColor(white: 0.25, alpha: 1))
        case .desktopIcon(let label):
            NSColor(srgbRed: 0.35, green: 0.65, blue: 0.95, alpha: 1).setFill()
            NSBezierPath(roundedRect: CGRect(x: frame.midX - 26, y: frame.minY, width: 52, height: 60), xRadius: 6, yRadius: 6).fill()
            NSColor(white: 1, alpha: 0.85).setFill()
            NSBezierPath.fill(CGRect(x: frame.midX - 16, y: frame.minY + 14, width: 32, height: 4))
            NSBezierPath.fill(CGRect(x: frame.midX - 16, y: frame.minY + 24, width: 24, height: 4))
            text(label, CGRect(x: frame.minX, y: frame.minY + 64, width: frame.width, height: 18), 12, .medium, .white, center: true)
        case .finderWindow(let title):
            NSColor(white: 0.97, alpha: 1).setFill()
            NSBezierPath(roundedRect: frame, xRadius: 10, yRadius: 10).fill()
            NSColor(white: 0.86, alpha: 1).setFill()
            NSBezierPath.fill(CGRect(x: frame.minX, y: frame.minY + 28, width: frame.width, height: 1))
            for (i, color) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
                color.setFill()
                NSBezierPath(ovalIn: CGRect(x: frame.minX + 10 + CGFloat(i) * 18, y: frame.minY + 9, width: 11, height: 11)).fill()
            }
            text(title, CGRect(x: frame.minX + 70, y: frame.minY + 6, width: frame.width - 80, height: 18), 12, .semibold, NSColor(white: 0.2, alpha: 1))
            for i in 0..<3 {
                NSColor(srgbRed: 0.35, green: 0.65, blue: 0.95, alpha: 1).setFill()
                NSBezierPath(roundedRect: CGRect(x: frame.minX + 24 + CGFloat(i) * 80, y: frame.minY + 50, width: 40, height: 48), xRadius: 5, yRadius: 5).fill()
            }
        }
    }
}

extension SyntheticScene {
    /// Made-up process numbers for the fake applications. No real process is ever named.
    public static let notificationPID: pid_t = 90_001
    public static let finderPID: pid_t = 90_002

    /// A banner in the top-right corner, three desktop icons down the right edge, and a Finder window, on a display of `size` points.
    public static func otherWindows(on size: CGSize) -> [FixtureWindow] {
        let nc = ContentExclusion.App(pid: notificationPID, bundleID: ContentExclusion.notificationCenter)
        let finder = ContentExclusion.App(pid: finderPID, bundleID: ContentExclusion.finder)
        var out = [FixtureWindow(app: nc, window: .init(id: 90_101, ownerPID: nc.pid, layer: 23),
                                 frame: CGRect(x: size.width - 356, y: 16, width: 340, height: 64),
                                 content: .banner(title: "Test notification", body: "A fake banner owned by the test"))]
        for (i, name) in ["Test file 1", "Test file 2", "Test file 3"].enumerated() {
            out.append(FixtureWindow(app: finder, window: .init(id: 90_201 + CGWindowID(i), ownerPID: finder.pid, layer: -2_147_483_603),
                                     frame: CGRect(x: size.width - 108, y: 104 + CGFloat(i) * 96, width: 92, height: 84), content: .desktopIcon(name)))
        }
        out.append(FixtureWindow(app: finder, window: .init(id: 90_301, ownerPID: finder.pid, layer: 0),
                                 frame: CGRect(x: 120, y: 120, width: 270, height: 120), content: .finderWindow("Test Finder window")))
        return out
    }
}
