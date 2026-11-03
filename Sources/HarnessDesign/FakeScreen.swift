import AppKit

/// Stand-in screenshots. Raw colours are fine here: they are user content, not interface.
enum FakeScreen {
    enum Variant { case wallpaper, document }

    private struct Rng {
        var state: UInt64
        mutating func next() -> CGFloat {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return CGFloat((state >> 33) & 0xFFFF) / 65535
        }
    }

    static func draw(_ variant: Variant, in rect: CGRect) {
        guard let context = NSGraphicsContext.current else { return }
        context.saveGraphicsState()
        defer { context.restoreGraphicsState() }
        NSBezierPath(rect: rect).addClip()
        var rng = Rng(state: variant == .wallpaper ? 7 : 21)
        switch variant {
        case .wallpaper: wallpaper(rect, &rng)
        case .document: document(rect, &rng)
        }
    }

    private static func lines(_ rect: CGRect, count: Int, color: NSColor, _ rng: inout Rng) {
        var y = rect.minY
        for _ in 0..<count where y + 5 <= rect.maxY {
            let w = rect.width * (0.45 + 0.55 * rng.next())
            Draw.fill(Draw.rounded(CGRect(x: rect.minX, y: y, width: w, height: 5), 2.5), color)
            y += 12
        }
    }

    private static func window(_ rect: CGRect, tint: UInt32, _ rng: inout Rng) {
        let path = Draw.rounded(rect, 10)
        NSGraphicsContext.current?.saveGraphicsState()
        NSShadow.drop(alpha: 0.25, blur: 18, dy: 8)
        Draw.fill(path, Draw.srgb(tint))
        NSGraphicsContext.current?.restoreGraphicsState()
        NSGraphicsContext.current?.saveGraphicsState()
        path.addClip()
        Draw.fill(NSBezierPath(rect: CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: 24)), Draw.srgb(0xE9E6E1))
        for (i, c) in [UInt32(0xFF5F57), 0xFEBC2E, 0x28C840].enumerated() {
            Draw.fill(Draw.circle(CGRect(x: rect.minX + 10 + CGFloat(i) * 16, y: rect.minY + 8, width: 8, height: 8)), Draw.srgb(c))
        }
        let side = CGRect(x: rect.minX, y: rect.minY + 24, width: rect.width * 0.26, height: rect.height - 24)
        Draw.fill(NSBezierPath(rect: side), Draw.srgb(0xEFECE8))
        lines(side.insetBy(dx: 10, dy: 12), count: 14, color: Draw.srgb(0x8E8A84, 0.7), &rng)
        let body = CGRect(x: side.maxX + 14, y: side.minY + 14, width: rect.maxX - side.maxX - 28, height: rect.height - 52)
        let tiles: [UInt32] = [0xE5484D, 0xF5A524, 0x30A46C, 0x3E63DD, 0x8E4EC6, 0x12A594]
        let tileW = (body.width - 24) / 3
        for i in 0..<6 where body.minY + CGFloat(i / 3) * 56 + 44 < body.maxY {
            let t = CGRect(x: body.minX + CGFloat(i % 3) * (tileW + 12), y: body.minY + CGFloat(i / 3) * 56, width: tileW, height: 44)
            Draw.fill(Draw.rounded(t, 6), Draw.srgb(tiles[i], 0.9))
        }
        lines(CGRect(x: body.minX, y: body.minY + 124, width: body.width, height: max(0, body.height - 124)), count: 12,
              color: Draw.srgb(0x3A3733, 0.75), &rng)
        NSGraphicsContext.current?.restoreGraphicsState()
        Draw.stroke(path, Draw.srgb(0x000000, 0.12))
    }

    private static func wallpaper(_ r: CGRect, _ rng: inout Rng) {
        NSGradient(colors: [Draw.srgb(0xFFD7B0), Draw.srgb(0xF4B8C8), Draw.srgb(0x9FB4F2)])?.draw(in: r, angle: -35)
        window(CGRect(x: r.minX + r.width * 0.05, y: r.minY + r.height * 0.07, width: r.width * 0.56, height: r.height * 0.7), tint: 0xFFFFFF, &rng)
        window(CGRect(x: r.minX + r.width * 0.40, y: r.minY + r.height * 0.22, width: r.width * 0.56, height: r.height * 0.7), tint: 0xFBFAF8, &rng)
    }

    private static func document(_ r: CGRect, _ rng: inout Rng) {
        Draw.fill(NSBezierPath(rect: r), Draw.srgb(0xFFFFFF))
        Draw.fill(NSBezierPath(rect: CGRect(x: r.minX, y: r.minY, width: r.width, height: r.height * 0.1)), Draw.srgb(0xF2F0EC))
        for (i, c) in [UInt32(0xFF5F57), 0xFEBC2E, 0x28C840].enumerated() {
            Draw.fill(Draw.circle(CGRect(x: r.minX + r.width * 0.03 + CGFloat(i) * r.width * 0.03, y: r.minY + r.height * 0.035, width: r.height * 0.03, height: r.height * 0.03)), Draw.srgb(c))
        }
        let pad = r.width * 0.08
        Draw.fill(Draw.rounded(CGRect(x: r.minX + pad, y: r.minY + r.height * 0.18, width: r.width * 0.4, height: r.height * 0.07), 4), Draw.srgb(0x1F1D1A))
        lines(CGRect(x: r.minX + pad, y: r.minY + r.height * 0.3, width: r.width * 0.5, height: r.height * 0.3), count: 6, color: Draw.srgb(0x8E8A84, 0.55), &rng)
        let chart = CGRect(x: r.minX + r.width * 0.62, y: r.minY + r.height * 0.18, width: r.width * 0.3, height: r.height * 0.42)
        Draw.fill(Draw.rounded(chart, 8), Draw.srgb(0xEEF2FD))
        for i in 0..<6 {
            let h = chart.height * (0.25 + 0.6 * rng.next())
            Draw.fill(Draw.rounded(CGRect(x: chart.minX + 12 + CGFloat(i) * (chart.width - 24) / 6, y: chart.maxY - 12 - h, width: (chart.width - 24) / 6 - 6, height: h), 3), Draw.srgb(0x3E63DD))
        }
        for i in 0..<3 {
            let t = CGRect(x: r.minX + pad + CGFloat(i) * r.width * 0.28, y: r.minY + r.height * 0.68, width: r.width * 0.25, height: r.height * 0.2)
            Draw.fill(Draw.rounded(t, 6), Draw.srgb([0xFDECEC, 0xFEF3DC, 0xE6F6EC][i]))
            lines(t.insetBy(dx: 10, dy: 12), count: 3, color: Draw.srgb(0x3A3733, 0.5), &rng)
        }
    }
}

extension NSShadow {
    /// Content shadow inside the fake screenshots, outside the token system on purpose.
    static func drop(alpha: CGFloat, blur: CGFloat, dy: CGFloat) {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(alpha)
        shadow.shadowBlurRadius = blur
        shadow.shadowOffset = NSSize(width: 0, height: -dy)
        shadow.set()
    }
}
