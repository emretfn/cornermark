import CoreGraphics
import Foundation

/// A stretch of the video, in seconds, in which the camera fills the picture.
public struct CameraSpan: Codable, Equatable, Sendable {
    public var from: Double
    public var to: Double
    public init(from: Double, to: Double) { self.from = from; self.to = to }
}

/// How the camera shows over a recording: a bubble in a corner of the picture, or the whole picture while a full-screen span runs.
public struct CameraBubble: Codable, Equatable, Sendable {
    public enum Shape: String, Codable, CaseIterable, Sendable { case circle, square, rectangle }
    public enum Size: String, Codable, CaseIterable, Sendable {
        case small, medium, large
        /// The bubble's height as a share of the picture's short side.
        public var fraction: Double {
            switch self {
            case .small: return 0.22
            case .medium: return 0.3
            case .large: return 0.42
            }
        }
    }
    public var isVisible: Bool
    public var shape: Shape
    public var size: Size
    public var position: GridPosition
    /// Shows the camera the way a mirror would, which is how people expect to see themselves.
    public var isMirrored: Bool
    /// Sorted by `from`.
    public var fullScreen: [CameraSpan]

    public init(isVisible: Bool = true, shape: Shape = .circle, size: Size = .medium, position: GridPosition = .bottomLeft, isMirrored: Bool = true,
                fullScreen: [CameraSpan] = []) {
        self.isVisible = isVisible; self.shape = shape; self.size = size; self.position = position; self.isMirrored = isMirrored
        self.fullScreen = fullScreen.sorted { $0.from < $1.from }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let d = CameraBubble()
        isVisible = (try? c.decodeIfPresent(Bool.self, forKey: .isVisible)) ?? d.isVisible
        shape = (try? c.decodeIfPresent(Shape.self, forKey: .shape)) ?? d.shape
        size = (try? c.decodeIfPresent(Size.self, forKey: .size)) ?? d.size
        // Files written before the 3×3 grid name one of four corners under `corner`.
        position = (try? c.decodeIfPresent(GridPosition.self, forKey: .position)) ?? (try? c.decodeIfPresent(GridPosition.self, forKey: .corner)) ?? d.position
        isMirrored = (try? c.decodeIfPresent(Bool.self, forKey: .isMirrored)) ?? d.isMirrored
        fullScreen = ((try? c.decodeIfPresent([CameraSpan].self, forKey: .fullScreen)) ?? nil)?.filter { $0.to >= $0.from }.sorted { $0.from < $1.from } ?? []
    }
    private enum Keys: String, CodingKey { case isVisible, shape, size, position, corner, isMirrored, fullScreen }
}

/// Where the camera's picture goes in one frame, in points of the recorded area with the origin at its top-left corner.
public struct CameraFrame: Equatable, Sendable {
    public var rect: CGRect
    public var cornerRadius: Double
    public var isMirrored: Bool
    /// 0 in the bubble, 1 when the camera fills the picture.
    public var fill: Double
    public init(rect: CGRect, cornerRadius: Double, isMirrored: Bool, fill: Double) {
        self.rect = rect; self.cornerRadius = cornerRadius; self.isMirrored = isMirrored; self.fill = fill
    }
}

public enum CameraLayout {
    /// Seconds the camera takes to grow to the full picture and to shrink back.
    public static let transition = 0.3
    /// A rectangle bubble is this much wider than tall.
    public static let rectangleAspect = 4.0 / 3.0

    public static func margin(area: CGSize) -> Double { (min(area.width, area.height) * 0.04).rounded() }

    /// The bubble at rest in its cell of the grid.
    public static func bubbleRect(_ bubble: CameraBubble, area: CGSize) -> CGRect {
        let short = min(area.width, area.height)
        let h = (short * bubble.size.fraction).rounded()
        let w = bubble.shape == .rectangle ? (h * rectangleAspect).rounded() : h
        return bubble.position.place(CGSize(width: w, height: h), in: area, margin: margin(area: area))
    }

    public static func cornerRadius(_ shape: CameraBubble.Shape, rect: CGRect) -> Double {
        let short = min(rect.width, rect.height)
        return shape == .circle ? short / 2 : (short * 0.16).rounded()
    }

    /// How far the camera has grown toward the full picture at `t`: it grows from each span's start and shrinks from its end, over
    /// `transition` seconds, so a span shorter than that never reaches the full picture.
    public static func fullScreenAmount(_ spans: [CameraSpan], at t: Double) -> Double {
        func ease(_ x: Double) -> Double {
            let f = min(max(x, 0), 1)
            return f * f * f * (f * (f * 6 - 15) + 10)
        }
        var amount = 0.0
        for span in spans where t >= span.from {
            amount = max(amount, min(ease((t - span.from) / transition), 1 - ease((t - span.to) / transition)))
        }
        return amount
    }

    /// Nil when the camera is hidden.
    public static func frame(_ bubble: CameraBubble, area: CGSize, at t: Double) -> CameraFrame? {
        guard bubble.isVisible, area.width > 0, area.height > 0 else { return nil }
        let rest = bubbleRect(bubble, area: area)
        let k = fullScreenAmount(bubble.fullScreen, at: t)
        func mix(_ a: Double, _ b: Double) -> Double { a + (b - a) * k }
        let rect = CGRect(x: mix(rest.minX, 0), y: mix(rest.minY, 0), width: mix(rest.width, area.width), height: mix(rest.height, area.height))
        return CameraFrame(rect: rect, cornerRadius: mix(cornerRadius(bubble.shape, rect: rest), 0), isMirrored: bubble.isMirrored, fill: k)
    }
}

/// Draws the camera into a picture. Recording, preview and export share it, so a bubble looks the same wherever it is drawn. The values
/// are fixed rather than design tokens, because a video must not change with the appearance.
public enum CameraBubblePainter {
    public static let edge = CGColor(gray: 1, alpha: 0.28)
    public static let shadow = CGColor(gray: 0, alpha: 0.35)

    /// The rect `image` covers so it fills `rect` without stretching, centred, cropping what spills over.
    public static func aspectFill(_ image: CGSize, in rect: CGRect) -> CGRect {
        guard image.width > 0, image.height > 0 else { return rect }
        let k = max(rect.width / image.width, rect.height / image.height)
        let w = image.width * k, h = image.height * k
        return CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h)
    }

    /// `ctx` counts points of the recorded area with y down, as `InputOverlayPainter` does.
    public static func draw(_ image: CGImage, _ frame: CameraFrame, in ctx: CGContext) {
        let rect = frame.rect
        guard rect.width >= 1, rect.height >= 1 else { return }
        let radius = min(frame.cornerRadius, min(rect.width, rect.height) / 2)
        let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        let bubbleness = 1 - frame.fill
        if bubbleness > 0 {
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: rect.height * 0.02), blur: rect.height * 0.08, color: shadow.copy(alpha: 0.35 * bubbleness))
            ctx.addPath(path)
            ctx.setFillColor(CGColor(gray: 0, alpha: 1))
            ctx.fillPath()
            ctx.restoreGState()
        }
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        let target = aspectFill(CGSize(width: image.width, height: image.height), in: rect)
        // The context has y down, and a CGImage draws with y up, so it is turned over once, and across too when mirrored.
        ctx.translateBy(x: target.midX, y: target.midY)
        ctx.scaleBy(x: frame.isMirrored ? -1 : 1, y: -1)
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: -target.width / 2, y: -target.height / 2, width: target.width, height: target.height))
        ctx.restoreGState()
        if bubbleness > 0 {
            ctx.saveGState()
            ctx.addPath(CGPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerWidth: max(radius - 0.5, 0), cornerHeight: max(radius - 0.5, 0), transform: nil))
            ctx.setStrokeColor(edge.copy(alpha: 0.28 * bubbleness) ?? edge)
            ctx.setLineWidth(1)
            ctx.strokePath()
            ctx.restoreGState()
        }
    }
}
