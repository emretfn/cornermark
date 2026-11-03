import AppKit

typealias LCH = (l: Double, c: Double, h: Double)

/// One accent or status family for one appearance. Only the accent carries a hover step.
struct StatusRamp {
    let subtle: NSColor
    let border: NSColor
    let solid: NSColor
    let solidHover: NSColor?
    let text: NSColor
    let onSolid: NSColor

    init(subtle: LCH, border: LCH, solid: LCH, solidHover: LCH? = nil, text: LCH, onSolid: LCH) {
        self.subtle = Palette.oklch(subtle)
        self.border = Palette.oklch(border)
        self.solid = Palette.oklch(solid)
        self.solidHover = solidHover.map { Palette.oklch($0) }
        self.text = Palette.oklch(text)
        self.onSolid = Palette.oklch(onSolid)
    }
}

enum Palette {
    static func oklch(_ lch: LCH, alpha: CGFloat = 1) -> NSColor { oklch(lch.l, lch.c, lch.h, alpha: alpha) }

    /// Reduces chroma until the colour fits sRGB, so lightness and hue survive the gamut clip.
    static func oklch(_ l: Double, _ c: Double, _ h: Double, alpha: CGFloat = 1) -> NSColor {
        var lo = 0.0, hi = c
        var rgb = linearRGB(l, hi, h)
        if !inGamut(rgb) {
            for _ in 0..<24 {
                let mid = (lo + hi) / 2
                if inGamut(linearRGB(l, mid, h)) { lo = mid } else { hi = mid }
            }
            rgb = linearRGB(l, lo, h)
        }
        func encode(_ v: Double) -> CGFloat {
            let x = min(max(v, 0), 1)
            return CGFloat(x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1 / 2.4) - 0.055)
        }
        return NSColor(srgbRed: encode(rgb.r), green: encode(rgb.g), blue: encode(rgb.b), alpha: alpha)
    }

    /// Inverse of `oklch`, for the colour as it resolves under the current appearance.
    static func lch(of color: NSColor) -> LCH {
        let c = color.usingColorSpace(.sRGB) ?? color
        func decode(_ v: CGFloat) -> Double {
            let x = Double(v)
            return x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)
        }
        let r = decode(c.redComponent), g = decode(c.greenComponent), b = decode(c.blueComponent)
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        let L = 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s
        let a = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s
        let bb = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
        var h = atan2(bb, a) * 180 / .pi
        if h < 0 { h += 360 }
        return (L, hypot(a, bb), h)
    }

    private static func linearRGB(_ l: Double, _ c: Double, _ h: Double) -> (r: Double, g: Double, b: Double) {
        let a = c * cos(h * .pi / 180), b = c * sin(h * .pi / 180)
        let l_ = pow(l + 0.3963377774 * a + 0.2158037573 * b, 3)
        let m_ = pow(l - 0.1055613458 * a - 0.0638541728 * b, 3)
        let s_ = pow(l - 0.0894841775 * a - 1.2914855480 * b, 3)
        return (4.0767416621 * l_ - 3.3077115913 * m_ + 0.2309699292 * s_,
                -1.2684380046 * l_ + 2.6097574011 * m_ - 0.3413193965 * s_,
                -0.0041960863 * l_ - 0.7034186147 * m_ + 1.7076147010 * s_)
    }

    private static func inGamut(_ rgb: (r: Double, g: Double, b: Double)) -> Bool {
        let e = 1e-4
        return [rgb.r, rgb.g, rgb.b].allSatisfy { $0 >= -e && $0 <= 1 + e }
    }

    // MARK: Neutral ramps, steps 1 to 12 at index 0 to 11. Hue 85 keeps the greys warm without reading as tinted.

    static let neutralLightL: [Double] = [0.985, 0.97, 0.945, 0.92, 0.895, 0.865, 0.82, 0.62, 0.60, 0.62, 0.46, 0.22]
    static let neutralDarkL: [Double] = [0.17, 0.20, 0.235, 0.265, 0.295, 0.33, 0.39, 0.56, 0.58, 0.50, 0.79, 0.95]
    static let neutralLight = neutralLightL.map { oklch($0, 0.004, 85) }
    static let neutralDark = neutralDarkL.map { oklch($0, 0.005, 85) }

    // MARK: Accent and status


    static let dangerLight = StatusRamp(subtle: (0.955, 0.025, 25), border: (0.82, 0.09, 25), solid: (0.55, 0.20, 25),
                                        text: (0.50, 0.17, 25), onSolid: (1, 0, 0))
    static let dangerDark = StatusRamp(subtle: (0.27, 0.06, 25), border: (0.45, 0.12, 25), solid: (0.58, 0.19, 25),
                                       text: (0.76, 0.13, 25), onSolid: (1, 0, 0))
    // The spec gives warning.solid dark text without a value; this reuses the accent onSolid lightness at the warning hue.
    static let warningLight = StatusRamp(subtle: (0.955, 0.04, 55), border: (0.82, 0.10, 55), solid: (0.72, 0.17, 55),
                                         text: (0.50, 0.13, 55), onSolid: (0.20, 0.01, 55))
    static let warningDark = StatusRamp(subtle: (0.27, 0.05, 55), border: (0.47, 0.10, 55), solid: (0.76, 0.16, 55),
                                        text: (0.80, 0.13, 55), onSolid: (0.20, 0.01, 55))
    static let successLight = StatusRamp(subtle: (0.955, 0.03, 150), border: (0.82, 0.09, 150), solid: (0.52, 0.13, 150),
                                         text: (0.46, 0.11, 150), onSolid: (1, 0, 0))
    static let successDark = StatusRamp(subtle: (0.26, 0.05, 150), border: (0.45, 0.09, 150), solid: (0.55, 0.14, 150),
                                        text: (0.80, 0.14, 150), onSolid: (1, 0, 0))

    typealias Accent = (light: StatusRamp, dark: StatusRamp)

    static let accentLight = StatusRamp(subtle: (0.955, 0.04, 105), border: (0.80, 0.09, 105), solid: (0.90, 0.18, 105),
                                        solidHover: (0.86, 0.18, 105), text: (0.50, 0.13, 105), onSolid: (0.20, 0.01, 105))
    static let accentDark = StatusRamp(subtle: (0.27, 0.05, 105), border: (0.47, 0.09, 105), solid: (0.90, 0.18, 105),
                                       solidHover: (0.86, 0.18, 105), text: (0.90, 0.11, 105), onSolid: (0.20, 0.01, 105))
    static let accent: Accent = (accentLight, accentDark)
}
