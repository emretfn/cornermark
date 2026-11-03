import CoreGraphics
import Foundation

public struct BuiltinBackground: Sendable, Hashable {
    public let name: String
    public let stops: [RGBA]
    /// 0 = left to right, 90 = top to bottom (y-down screen space).
    public let angleDegrees: Double
}

public enum BuiltinBackgrounds {
    private static func g(_ name: String, _ angle: Double, _ hex: UInt32...) -> BuiltinBackground {
        BuiltinBackground(name: name, stops: hex.map { RGBA(hex: $0) }, angleDegrees: angle)
    }

    public static let all: [BuiltinBackground] = [
        g("Sunset", 45, 0xFF9A8B, 0xFF6A88, 0xFF99AC),
        g("Ocean", 60, 0x2E3192, 0x1BFFFF),
        g("Aurora", 120, 0x0F2027, 0x2C5364, 0x43CEA2),
        g("Peach", 90, 0xFFE0C2, 0xFFB199),
        g("Lavender", 45, 0xC3B1E1, 0x8EC5FC),
        g("Mint", 135, 0xD4FC79, 0x96E6A1),
        g("Midnight", 90, 0x0F0C29, 0x302B63, 0x24243E),
        g("Candy", 30, 0xFBC2EB, 0xA6C1EE),
        g("Citrus", 60, 0xF9D423, 0xFF4E50),
        g("Graphite", 90, 0x434343, 0x1A1A1A),
        g("Dusk", 100, 0x355C7D, 0x6C5B7B, 0xC06C84),
        g("Forest", 135, 0x134E5E, 0x71B280),
        g("Rose Gold", 45, 0xF3D2C1, 0xE0A899, 0xB76E79),
        g("Sky", 90, 0x89F7FE, 0x66A6FF),
        g("Ember", 45, 0x42275A, 0x734B6D, 0xE96443),
        g("Lagoon", 150, 0x00C9FF, 0x92FE9D),
        g("Cotton", 20, 0xFFDEE9, 0xB5FFFC),
        g("Slate", 90, 0xE2E8F0, 0x94A3B8),
        g("Mocha", 60, 0xD7C0AE, 0x8A6E5A),
        g("Mono", 90, 0xFAFAFA, 0xD4D4D8),
    ]

    public static func background(at index: Int) -> BuiltinBackground {
        all[min(max(index, 0), all.count - 1)]
    }
}

enum BackgroundPainter {
    static func fill(_ fill: BackgroundFill, rect: CGRect, in ctx: CGContext, assets: AssetStore) {
        switch fill {
        case .none:
            break
        case .solid(let c):
            ctx.setFillColor(c.cgColor)
            ctx.fill(rect)
        case .gradient(let a, let b, let angle):
            gradient([a, b], angle: angle, rect: rect, in: ctx)
        case .builtin(let index):
            let b = BuiltinBackgrounds.background(at: index)
            gradient(b.stops, angle: b.angleDegrees, rect: rect, in: ctx)
        case .image(let asset):
            guard let image = assets.image(for: asset) else { return }
            let iw = CGFloat(image.width), ih = CGFloat(image.height)
            let scale = max(rect.width / iw, rect.height / ih)
            let size = CGSize(width: iw * scale, height: ih * scale)
            ctx.saveGState()
            ctx.clip(to: rect)
            ctx.drawImageYDown(image, in: CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2,
                                                 width: size.width, height: size.height))
            ctx.restoreGState()
        }
    }

    private static func gradient(_ stops: [RGBA], angle: Double, rect: CGRect, in ctx: CGContext) {
        guard stops.count >= 2 else { return }
        let colors = stops.map(\.cgColor) as CFArray
        let locations = (0..<stops.count).map { CGFloat($0) / CGFloat(stops.count - 1) }
        guard let gradient = CGGradient(colorsSpace: Bitmap.sRGB, colors: colors, locations: locations) else { return }
        let rad = angle * .pi / 180
        let d = CGPoint(x: cos(rad), y: sin(rad))
        let half = (abs(rect.width * d.x) + abs(rect.height * d.y)) / 2
        let c = CGPoint(x: rect.midX, y: rect.midY)
        ctx.saveGState()
        ctx.clip(to: rect)
        ctx.drawLinearGradient(gradient, start: c - d * half, end: c + d * half,
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        ctx.restoreGState()
    }
}
