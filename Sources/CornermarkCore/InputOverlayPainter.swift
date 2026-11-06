import CoreGraphics
import CoreText
import Foundation

public struct InputOverlayInk {
    public var click: (ClickHighlight.Color) -> CGColor
    public var halo: CGColor
    public var badgeFill: (KeystrokeDisplay.Theme) -> CGColor
    public var badgeText: (KeystrokeDisplay.Theme) -> CGColor
    public var badgeBorder: (KeystrokeDisplay.Theme) -> CGColor

    public init(click: @escaping (ClickHighlight.Color) -> CGColor, halo: CGColor, badgeFill: @escaping (KeystrokeDisplay.Theme) -> CGColor,
                badgeText: @escaping (KeystrokeDisplay.Theme) -> CGColor, badgeBorder: @escaping (KeystrokeDisplay.Theme) -> CGColor) {
        self.click = click; self.halo = halo; self.badgeFill = badgeFill; self.badgeText = badgeText; self.badgeBorder = badgeBorder
    }
}

/// Draws an `InputOverlayState` into a context whose units are the recording's points, y down.
public enum InputOverlayPainter {
    public static func draw(_ state: InputOverlayState, area: CGSize, highlight: ClickHighlight, keystrokes: KeystrokeDisplay,
                            ink: InputOverlayInk, in ctx: CGContext) {
        for ring in state.rings { draw(ring, highlight, ink, ctx) }
        if let badge = state.badge { draw(badge, area: area, keystrokes, ink, ctx) }
    }

    public static func ringLineWidth(_ h: ClickHighlight) -> Double { max(2, h.size.radius * 0.15) }
    public static func ringHaloWidth(_ h: ClickHighlight) -> Double { ringLineWidth(h) + 2 }
    public static let ringFillAlpha = 0.4

    private static func draw(_ ring: ClickRing, _ h: ClickHighlight, _ ink: InputOverlayInk, _ ctx: CGContext) {
        let line = ringLineWidth(h)
        let circle = CGRect(x: ring.x - ring.radius, y: ring.y - ring.radius, width: ring.radius * 2, height: ring.radius * 2)
        let color = ink.click(h.color)
        ctx.saveGState()
        ctx.setAlpha(ring.opacity)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        if h.style == .filled {
            ctx.setFillColor(color.copy(alpha: ringFillAlpha) ?? color)
            ctx.fillEllipse(in: circle)
        }
        ctx.setStrokeColor(ink.halo)
        ctx.setLineWidth(ringHaloWidth(h))
        ctx.strokeEllipse(in: circle)
        ctx.setStrokeColor(color)
        ctx.setLineWidth(line)
        ctx.strokeEllipse(in: circle)
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }

    /// The badge's frame at full size, in points of the recorded area.
    public static func badgeFrame(text: String, area: CGSize, _ k: KeystrokeDisplay) -> CGRect {
        let size = textSize(text, k.size.fontSize)
        let padX = k.size.fontSize * 0.6, padY = k.size.fontSize * 0.36
        let w = min(size.width + padX * 2, area.width * 0.9), h = size.height + padY * 2
        let margin = max(12, min(area.width, area.height) * 0.05)
        return k.position.place(CGSize(width: w, height: h), in: area, margin: margin)
    }

    private static func draw(_ badge: KeyBadge, area: CGSize, _ k: KeystrokeDisplay, _ ink: InputOverlayInk, _ ctx: CGContext) {
        let frame = badgeFrame(text: badge.text, area: area, k)
        let radius = min(frame.height / 2, k.size.fontSize * 0.5)
        ctx.saveGState()
        ctx.setAlpha(badge.opacity)
        ctx.translateBy(x: frame.midX, y: frame.midY)
        ctx.scaleBy(x: badge.scale, y: badge.scale)
        ctx.translateBy(x: -frame.midX, y: -frame.midY)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        let shape = CGPath(roundedRect: frame, cornerWidth: radius, cornerHeight: radius, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 3), blur: 12, color: CGColor(gray: 0, alpha: 0.3))
        ctx.addPath(shape)
        ctx.setFillColor(ink.badgeFill(k.theme))
        ctx.fillPath()
        ctx.restoreGState()
        ctx.addPath(shape)
        ctx.setStrokeColor(ink.badgeBorder(k.theme))
        ctx.setLineWidth(1)
        ctx.strokePath()
        let line = textLine(badge.text, k.size.fontSize, color: ink.badgeText(k.theme))
        var ascent: CGFloat = 0, descent: CGFloat = 0
        let width = CTLineGetTypographicBounds(line, &ascent, &descent, nil)
        ctx.saveGState()
        ctx.addPath(shape)
        ctx.clip()
        let baseline = frame.midY + (ascent - descent) / 2
        ctx.textMatrix = .identity
        let pad = k.size.fontSize * 0.6
        let x = width <= frame.width - pad * 2 ? frame.midX - width / 2 : frame.maxX - pad - width
        ctx.translateBy(x: x, y: baseline)
        ctx.scaleBy(x: 1, y: -1)
        ctx.textPosition = .zero
        CTLineDraw(line, ctx)
        ctx.restoreGState()
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }

    private static func font(_ size: Double) -> CTFont {
        let system = CTFontCreateUIFontForLanguage(.system, size, nil) ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
        let traits = [kCTFontWeightTrait: 0.3] as CFDictionary
        let descriptor = CTFontDescriptorCreateCopyWithAttributes(CTFontCopyFontDescriptor(system), [kCTFontTraitsAttribute: traits] as CFDictionary)
        return CTFontCreateWithFontDescriptor(descriptor, size, nil)
    }

    private static func textLine(_ text: String, _ size: Double, color: CGColor) -> CTLine {
        let attributes = [kCTFontAttributeName: font(size), kCTForegroundColorAttributeName: color] as CFDictionary
        return CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, text as CFString, attributes))
    }

    private static func textSize(_ text: String, _ size: Double) -> CGSize {
        let line = textLine(text, size, color: CGColor(gray: 0, alpha: 1))
        var ascent: CGFloat = 0, descent: CGFloat = 0
        let width = CTLineGetTypographicBounds(line, &ascent, &descent, nil)
        return CGSize(width: ceil(width), height: ceil(ascent + descent))
    }
}
