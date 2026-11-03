import AppKit
import KadrajDesign

private typealias Token = (name: String, color: NSColor)

private let C = DS.Color.self
private let surfaces: [Token] = [("bgWindow", C.bgWindow), ("bgSurface", C.bgSurface), ("bgControl", C.bgControl),
                                 ("bgControlHover", C.bgControlHover), ("bgSunken", C.bgSunken), ("bgRaised", C.bgRaised)]

private struct Pair {
    let fg: Token
    let bg: Token
    let minimum: Double
}

private func pairs(_ fgs: [Token], on bgs: [Token], _ minimum: Double) -> [Pair] {
    fgs.flatMap { fg in bgs.map { Pair(fg: fg, bg: $0, minimum: minimum) } }
}

private let accent = "accent", danger = "danger", warning = "warning", success = "success"

private func family(_ name: String) -> (text: Token, subtle: Token, solid: Token, on: Token) {
    switch name {
    case accent: return (("accentText", C.accentText), ("accentSubtle", C.accentSubtle), ("accentSolid", C.accentSolid), ("onAccent", C.onAccent))
    case danger: return (("dangerText", C.dangerText), ("dangerSubtle", C.dangerSubtle), ("dangerSolid", C.dangerSolid), ("onDanger", C.onDanger))
    case warning: return (("warningText", C.warningText), ("warningSubtle", C.warningSubtle), ("warningSolid", C.warningSolid), ("onWarning", C.onWarning))
    default: return (("successText", C.successText), ("successSubtle", C.successSubtle), ("successSolid", C.successSolid), ("onSuccess", C.onSuccess))
    }
}

private let windowSurface: [Token] = [surfaces[0], surfaces[1]]

private let table: [Pair] = {
    var all = pairs([("textPrimary", C.textPrimary), ("textSecondary", C.textSecondary)], on: surfaces, 4.5)
    all += pairs([family(accent).text], on: windowSurface + [family(accent).subtle], 4.5)
    all += [Pair(fg: family(accent).on, bg: family(accent).solid, minimum: 4.5),
            Pair(fg: family(accent).on, bg: ("accentSolidHover", C.accentSolidHover), minimum: 4.5)]
    for name in [danger, warning, success] {
        let f = family(name)
        all.append(Pair(fg: f.on, bg: f.solid, minimum: 4.5))
        all += pairs([f.text], on: windowSurface + [f.subtle], 4.5)
    }
    all += pairs([("borderStrong", C.borderStrong)], on: windowSurface, 3.0)
    all += pairs([("accentMark", C.accentMark)], on: windowSurface, 3.0)
    return all
}()

private func ratio(_ pair: Pair, _ appearance: NSAppearance.Name) -> Double {
    let bg = resolve(pair.bg.color, appearance)
    return contrastRatio(resolve(pair.fg.color, appearance).over(bg), bg)
}

func checkContrast() {
    section("Contrast (WCAG), measured from resolved dynamic colours")
    for (label, appearance) in [("aqua", NSAppearance.Name.aqua), ("darkAqua", .darkAqua)] {
        for pair in table {
            let r = ratio(pair, appearance)
            let kind = pair.minimum == 3.0 ? "3.0" : "4.5"
            check(String(format: "[%@] %@ on %@ >= %@ : %.2f", label, pair.fg.name, pair.bg.name, kind, r), r >= pair.minimum,
                  String(format: "measured %.2f, needs %.1f", r, pair.minimum))
        }
    }

    for (backdropName, backdrop) in [("white", RGBA(r: 1, g: 1, b: 1)), ("black", RGBA(r: 0, g: 0, b: 0))] {
        let hud = resolve(C.bgHud, .darkAqua).over(backdrop)
        for fg in [("textPrimary", C.textPrimary), ("textSecondary", C.textSecondary)] {
            let r = contrastRatio(resolve(fg.1, .darkAqua).over(hud), hud)
            check(String(format: "[darkAqua] %@ on bgHud over %@ >= 4.5 : %.2f", fg.0, backdropName, r), r >= 4.5,
                  String(format: "measured %.2f, needs 4.5", r))
        }
    }
}
