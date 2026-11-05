import CoreGraphics
import Foundation
import ImageIO

/// What the recording sits on. Every length is in points of the recorded area, the unit of pointer samples, so a background
/// looks the same at every export size.
public struct VideoBackground: Codable, Equatable, Sendable {
    public enum Fill: Codable, Equatable, Sendable {
        /// The recording fills the video, as it was recorded.
        case none
        /// `BuiltinBackgrounds.all[index]` as a straight gradient.
        case gradient(index: Int)
        /// `BuiltinBackgrounds.all[index]`'s colours painted as soft overlapping light.
        case wallpaper(index: Int)
        case solid(color: RGBA)
        /// The picture named by `image`.
        case image
    }

    public static let paddingRange = 0.0...200
    public static let shadowRange = 0.0...100
    public static let cornerRange = 0.0...64

    public var fill: Fill
    public var padding: Double
    /// 0 is no shadow, 100 the deepest.
    public var shadow: Double
    public var cornerRadius: Double
    /// A picture the viewer added, a file in the project folder. It stays here when another fill is picked, so it can be picked again.
    public var image: String?

    public init(fill: Fill = .none, padding: Double = 64, shadow: Double = 50, cornerRadius: Double = 12, image: String? = nil) {
        self.fill = fill; self.padding = padding; self.shadow = shadow; self.cornerRadius = cornerRadius; self.image = image
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let d = VideoBackground()
        fill = (try? c.decodeIfPresent(Fill.self, forKey: .fill)) ?? d.fill
        padding = (try? c.decodeIfPresent(Double.self, forKey: .padding)) ?? d.padding
        shadow = (try? c.decodeIfPresent(Double.self, forKey: .shadow)) ?? d.shadow
        cornerRadius = (try? c.decodeIfPresent(Double.self, forKey: .cornerRadius)) ?? d.cornerRadius
        image = (try? c.decodeIfPresent(String.self, forKey: .image)) ?? nil
    }
    private enum Keys: String, CodingKey { case fill, padding, shadow, cornerRadius, image }

    /// The `BuiltinBackgrounds` palettes offered as wallpapers, in panel order.
    public static let wallpapers = [2, 6, 10, 14, 11, 4]

    /// The added picture, read from `folder`. Nil when there is none or the file is gone.
    public func picture(in folder: URL) -> CGImage? {
        guard let image, !image.contains("/"),
              let source = CGImageSourceCreateWithURL(folder.appendingPathComponent(image) as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}

/// Where the recording lands on the finished video, in points with the origin at the top-left corner.
public struct VideoCanvas: Equatable, Sendable {
    public var size: CGSize
    /// The recording's rectangle.
    public var frame: CGRect
    public var cornerRadius: Double
    /// 0...1.
    public var shadow: Double
    public var fill: VideoBackground.Fill

    /// Without a fill the recording is the whole video and the frame settings do nothing, since a video has no transparency.
    public init(source: RecordingProject.Source, background: VideoBackground) {
        let content = CGSize(width: max(source.pointWidth, 1), height: max(source.pointHeight, 1))
        fill = background.fill
        guard background.fill != .none else {
            size = content; frame = CGRect(origin: .zero, size: content); cornerRadius = 0; shadow = 0
            return
        }
        let range = VideoBackground.self
        let pad = min(max(background.padding, range.paddingRange.lowerBound), range.paddingRange.upperBound).rounded()
        size = CGSize(width: content.width + 2 * pad, height: content.height + 2 * pad)
        frame = CGRect(origin: CGPoint(x: pad, y: pad), size: content)
        cornerRadius = min(min(max(background.cornerRadius, 0), range.cornerRange.upperBound), min(content.width, content.height) / 2)
        shadow = min(max(background.shadow, 0), range.shadowRange.upperBound) / range.shadowRange.upperBound
    }

    public var hasBackdrop: Bool { fill != .none }
}

extension RecordingProject {
    public var canvas: VideoCanvas { VideoCanvas(source: source, background: edits.background) }
}

/// Everything around the recording, drawn once per size: the fill and the shadow the opaque, rounded recording casts on it.
/// Preview and export both show this picture, then the recording clipped to `canvas.frame` on top.
public enum VideoBackdrop {
    public static func image(_ canvas: VideoCanvas, width: Int, height: Int, picture: CGImage?) -> CGImage? {
        guard canvas.hasBackdrop, let ctx = Bitmap.makeContext(width: width, height: height, yDown: true) else { return nil }
        let sx = CGFloat(width) / canvas.size.width, sy = CGFloat(height) / canvas.size.height
        let full = CGRect(x: 0, y: 0, width: width, height: height)
        paint(canvas.fill, picture: picture, rect: full, in: ctx)
        guard canvas.shadow > 0 else { return ctx.makeImage() }
        let k = min(sx, sy), s = CGFloat(canvas.shadow)
        let frame = canvas.frame.applying(CGAffineTransform(scaleX: sx, y: sy))
        let shape = CGPath(roundedRect: frame, cornerWidth: canvas.cornerRadius * k, cornerHeight: canvas.cornerRadius * k, transform: nil)
        ctx.saveGState()
        // Only the shadow lands: under the recording the fill stays, so its anti-aliased edge blends with the fill as it does in the preview.
        ctx.addRect(full)
        ctx.addPath(shape)
        ctx.clip(using: .evenOdd)
        // Shadow offsets ignore the flipped matrix, so a negative height falls down the picture.
        ctx.setShadow(offset: CGSize(width: 0, height: -20 * s * k), blur: 64 * s * k, color: CGColor(gray: 0, alpha: 0.5))
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.addPath(shape)
        ctx.fillPath()
        ctx.restoreGState()
        return ctx.makeImage()
    }

    /// `ctx` is y-down.
    static func paint(_ fill: VideoBackground.Fill, picture: CGImage?, rect: CGRect, in ctx: CGContext) {
        switch fill {
        case .none:
            break
        case .gradient(let index):
            BackgroundPainter.fill(.builtin(index: index), rect: rect, in: ctx, assets: noAssets)
        case .wallpaper(let index):
            wallpaper(index, rect: rect, in: ctx)
        case .solid(let color):
            ctx.setFillColor(color.cgColor)
            ctx.fill(rect)
        case .image:
            ctx.setFillColor(CGColor(gray: 0.5, alpha: 1))
            ctx.fill(rect)
            guard let picture else { return }
            let iw = CGFloat(picture.width), ih = CGFloat(picture.height)
            let scale = max(rect.width / iw, rect.height / ih)
            let size = CGSize(width: iw * scale, height: ih * scale)
            ctx.saveGState()
            ctx.clip(to: rect)
            ctx.interpolationQuality = .high
            ctx.drawImageYDown(picture, in: CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height))
            ctx.restoreGState()
        }
    }

    private static let noAssets = AssetStore()

    /// The palette's gradient under pools of its own colours that fade into each other. Positions are fractions of the rect, so
    /// a wallpaper keeps its look at any size; the seed turns the arrangement so neighbours differ.
    private static func wallpaper(_ seed: Int, rect: CGRect, in ctx: CGContext) {
        let palette = BuiltinBackgrounds.background(at: seed)
        BackgroundPainter.fill(.builtin(index: seed), rect: rect, in: ctx, assets: noAssets)
        let spots: [(x: CGFloat, y: CGFloat)] = [(0.12, 0.18), (0.88, 0.22), (0.72, 0.92), (0.18, 0.86), (0.5, 0.5)]
        let colors = palette.stops + palette.stops.reversed()
        let reach = max(rect.width, rect.height) * 0.62
        ctx.saveGState()
        ctx.clip(to: rect)
        for i in 0..<4 {
            let spot = spots[(i + seed) % spots.count], color = colors[(i + seed) % colors.count]
            let center = CGPoint(x: rect.minX + spot.x * rect.width, y: rect.minY + spot.y * rect.height)
            let clear = RGBA(color.r, color.g, color.b, 0)
            guard let g = CGGradient(colorsSpace: Bitmap.sRGB, colors: [RGBA(color.r, color.g, color.b, 0.85).cgColor, clear.cgColor] as CFArray,
                                     locations: [0, 1]) else { continue }
            ctx.drawRadialGradient(g, startCenter: center, startRadius: 0, endCenter: center, endRadius: reach, options: [])
        }
        let glow = CGPoint(x: rect.minX + rect.width * (seed % 2 == 0 ? 0.3 : 0.7), y: rect.minY + rect.height * 0.08)
        if let g = CGGradient(colorsSpace: Bitmap.sRGB, colors: [CGColor(gray: 1, alpha: 0.28), CGColor(gray: 1, alpha: 0)] as CFArray, locations: [0, 1]) {
            ctx.drawRadialGradient(g, startCenter: glow, startRadius: 0, endCenter: glow, endRadius: reach * 0.8, options: [])
        }
        ctx.restoreGState()
    }
}
