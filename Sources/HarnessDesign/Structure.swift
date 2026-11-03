import AppKit
@testable import CornermarkDesign

private func lch(_ color: NSColor, _ appearance: NSAppearance.Name) -> LCH {
    var out: LCH = (0, 0, 0)
    NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance { out = Palette.lch(of: color) }
    return out
}

func checkStructure() {
    section("Structure")

    for (name, ramp, expected) in [("light", Palette.neutralLight, Palette.neutralLightL), ("dark", Palette.neutralDark, Palette.neutralDarkL)] {
        let measured = ramp.map { Palette.lch(of: $0).l }
        let drift = zip(measured, expected).map { abs($0 - $1) }.max() ?? 0
        check(String(format: "neutral %@ ramp round-trips through sRGB, max L drift %.4f", name, drift), drift < 0.002)
        for i in 0..<(ramp.count - 1) {
            let gap = abs(measured[i + 1] - measured[i])
            check(String(format: "neutral %@ n%d to n%d are distinct, dL %.3f >= 0.010", name, i + 1, i + 2, gap), gap >= 0.01)
        }
    }

    let roles: [(String, (StatusRamp) -> NSColor)] = [("solid", { $0.solid }), ("text", { $0.text })]
    do {
        let accentRamps = [(NSAppearance.Name.aqua, Palette.accent.light), (.darkAqua, Palette.accent.dark)]
        let statuses = [("danger", Palette.dangerLight, Palette.dangerDark), ("warning", Palette.warningLight, Palette.warningDark),
                        ("success", Palette.successLight, Palette.successDark)]
        for (name, light, dark) in statuses {
            for (appearance, accentRamp) in accentRamps {
                let status = appearance == .aqua ? light : dark
                for (role, pick) in roles {
                    let a = Palette.lch(of: pick(accentRamp)).h, s = Palette.lch(of: pick(status)).h
                    var d = abs(a - s).truncatingRemainder(dividingBy: 360)
                    if d > 180 { d = 360 - d }
                    check(String(format: "[%@] %@ %@ hue %.0f vs accent %.0f : %.0f deg >= 15", appearance == .aqua ? "aqua" : "darkAqua", name, role, s, a, d), d >= 15)
                }
            }
        }
    }

    let grid = DS.Space.all
    let spec: [CGFloat] = [2, 4, 6, 8, 12, 16, 24, 32]
    check("Space values equal the spec scale \(grid)", grid == spec)
    check("Space values sit on the 4pt grid except s2 and s6", grid.allSatisfy { $0.truncatingRemainder(dividingBy: 4) == 0 || $0 == 2 || $0 == 6 })
    check("Radius.lg is concentric(md, 4)", DS.Radius.lg == DS.Radius.concentric(inner: DS.Radius.md, padding: DS.Space.s4))
    check("Radius.xl is concentric(md, 8)", DS.Radius.xl == DS.Radius.concentric(inner: DS.Radius.md, padding: DS.Space.s8))
    check("controlLarge plus 2 * s4 padding is the HUD content height 44", DS.Size.controlLarge + 2 * DS.Space.s4 == 44)

    let styles = [DS.Text.title, DS.Text.heading, DS.Text.body, DS.Text.bodyStrong, DS.Text.label, DS.Text.caption,
                  DS.Text.captionStrong, DS.Text.readout, DS.Text.numeral]
    check("every text style's cap height plus descender fits its line height", styles.allSatisfy { $0.font.capHeight - $0.font.descender <= $0.lineHeight },
          styles.map { String(format: "%.0f/%.1f", $0.lineHeight, $0.font.capHeight - $0.font.descender) }.joined(separator: " "))
    check("readout is monospaced", DS.Text.readout.font.isFixedPitch)
    let paragraph = DS.Text.body.attributes(color: .black)[.paragraphStyle] as? NSParagraphStyle
    check("attributes pin min and max line height", paragraph?.minimumLineHeight == 18 && paragraph?.maximumLineHeight == 18)

    check("Motion durations stay at or under 0.30s", [DS.Motion.Duration.press, DS.Motion.Duration.fast, DS.Motion.Duration.base, DS.Motion.Duration.slow].allSatisfy { $0 <= 0.30 })

    let outset = NSBezierPath.continuous(CGRect(x: 0, y: 0, width: 100, height: 60), radius: 16)
    check("continuous path stays inside its rect", CGRect(x: 0, y: 0, width: 100, height: 60).contains(outset.bounds),
          "\(outset.bounds)")
    check("continuous path is not clipped by a radius over the limit",
          CGRect(x: 0, y: 0, width: 40, height: 40).contains(NSBezierPath.continuous(CGRect(x: 0, y: 0, width: 40, height: 40), radius: 100).bounds))
}
