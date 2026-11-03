import AppKit

var failures = 0
var passes = 0

func check(_ name: String, _ ok: @autoclosure () -> Bool, _ detail: @autoclosure () -> String = "") {
    if ok() {
        passes += 1
        print("PASS \(name)")
    } else {
        failures += 1
        print("FAIL \(name)\(detail().isEmpty ? "" : "  [\(detail())]")")
    }
}

func section(_ title: String) { print("\n== \(title)") }

let accentName = "limon"

struct RGBA {
    var r: Double, g: Double, b: Double, a: Double = 1

    var hex: String { String(format: "#%02X%02X%02X", Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded())) }

    func over(_ bg: RGBA) -> RGBA {
        RGBA(r: r * a + bg.r * (1 - a), g: g * a + bg.g * (1 - a), b: b * a + bg.b * (1 - a), a: 1)
    }

    var luminance: Double {
        func lin(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
    }
}

func contrastRatio(_ a: RGBA, _ b: RGBA) -> Double {
    let (hi, lo) = (max(a.luminance, b.luminance), min(a.luminance, b.luminance))
    return (hi + 0.05) / (lo + 0.05)
}

/// Resolves a dynamic colour under an appearance, the way a view drawing in that appearance would see it.
func resolve(_ color: NSColor, _ appearance: NSAppearance.Name) -> RGBA {
    var out = RGBA(r: 0, g: 0, b: 0)
    NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
        let c = color.usingColorSpace(.sRGB)!
        out = RGBA(r: Double(c.redComponent), g: Double(c.greenComponent), b: Double(c.blueComponent), a: Double(c.alphaComponent))
    }
    return out
}
