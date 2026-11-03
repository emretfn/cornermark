import AppKit
import CornermarkDesign

private typealias C = DS.Color

/// One tall page that reads top to bottom: tokens first, then the comps that use them.
final class Sheet {
    static let width: CGFloat = 1400
    static let margin: CGFloat = 64
    static let contentWidth = width - 2 * margin

    let appearance: NSAppearance.Name
    let accent: String
    var y: CGFloat = 0
    var left: CGFloat { Self.margin }
    var right: CGFloat { Self.width - Self.margin }

    init(appearance: NSAppearance.Name, accent: String) {
        self.appearance = appearance
        self.accent = accent
    }

    /// Draws the whole page and returns its height, so a first pass can size the real one.
    func draw(height: CGFloat) -> CGFloat {
        C.bgWindow.setFill()
        CGRect(x: 0, y: 0, width: Self.width, height: height).fill()
        y = Self.margin
        header()
        surfaces()
        textAndLines()
        accentAndStatus()
        typeScale()
        spaceAndSize()
        radii()
        elevation()
        components()
        inContext()
        return y + Self.margin
    }

    // MARK: Page furniture

    private func header() {
        Draw.text("Cornermark design tokens", DS.Text.title, C.textPrimary, at: CGPoint(x: left, y: y))
        y += 26 + DS.Space.s4
        let mode = appearance == .darkAqua ? "dark" : "light"
        Draw.text("Accent \(accent)  ·  \(mode) appearance  ·  rendered by HarnessDesign from the public DS tokens", DS.Text.body, C.textSecondary,
                  at: CGPoint(x: left, y: y))
        y += 18
    }

    func section(_ title: String, _ caption: String) {
        y += DS.Space.s32 + DS.Space.s16
        Draw.text(title, DS.Text.heading, C.textPrimary, at: CGPoint(x: left, y: y))
        let titleWidth = Draw.width(title, DS.Text.heading)
        Draw.text(caption, DS.Text.caption, C.textSecondary, at: CGPoint(x: left + titleWidth + DS.Space.s12, y: y + 3))
        y += 20 + DS.Space.s12
        Draw.hairline(x0: left, x1: right, y: y, C.separator)
        y += 1 + DS.Space.s24
    }

    func hex(_ color: NSColor) -> String {
        let c = resolve(color, appearance)
        return c.a < 0.999 ? "\(c.hex)  \(Int((c.a * 100).rounded()))%" : c.hex
    }

    /// Alpha tokens read against both ends of the range, so the left half sits on white and the right on black.
    func splitBackdrop(_ path: NSBezierPath, _ rect: CGRect) {
        NSGraphicsContext.current?.saveGraphicsState()
        path.addClip()
        Draw.fill(NSBezierPath(rect: CGRect(x: rect.minX, y: rect.minY, width: rect.width / 2, height: rect.height)), .white)
        Draw.fill(NSBezierPath(rect: CGRect(x: rect.midX, y: rect.minY, width: rect.width / 2, height: rect.height)), .black)
        NSGraphicsContext.current?.restoreGraphicsState()
    }

    /// A labelled swatch cell. `paint` draws inside the rounded swatch.
    func cell(_ name: String, _ detail: String, at origin: CGPoint, size: CGSize = CGSize(width: 120, height: 72), backdrop: Bool = false,
              paint: (CGRect) -> Void) {
        let rect = CGRect(origin: origin, size: size)
        let path = Draw.rounded(rect, DS.Radius.md)
        if backdrop { splitBackdrop(path, rect) }
        NSGraphicsContext.current?.saveGraphicsState()
        path.addClip()
        paint(rect)
        NSGraphicsContext.current?.restoreGraphicsState()
        Draw.stroke(path, C.border)
        Draw.text(name, DS.Text.label, C.textPrimary, at: CGPoint(x: rect.minX, y: rect.maxY + DS.Space.s8), width: size.width)
        Draw.text(detail, DS.Text.readout, C.textSecondary, at: CGPoint(x: rect.minX, y: rect.maxY + DS.Space.s8 + 16), width: size.width)
    }

    func fillSwatch(_ color: NSColor) -> (CGRect) -> Void { { Draw.fill(NSBezierPath(rect: $0), color) } }

    // MARK: Colour

    private func surfaces() {
        section("Surfaces", "Neutral roles resolved for the \(appearance == .darkAqua ? "dark" : "light") appearance. The shell is grey so screenshots carry the colour.")
        let tokens: [(String, NSColor)] = [("bgWindow", C.bgWindow), ("bgSurface", C.bgSurface), ("bgRaised", C.bgRaised), ("bgSunken", C.bgSunken),
                                           ("bgCanvas", C.bgCanvas), ("bgControl", C.bgControl), ("bgControlHover", C.bgControlHover),
                                           ("bgControlActive", C.bgControlActive), ("bgHud", C.bgHud), ("bgScrim", C.bgScrim)]
        for (i, token) in tokens.enumerated() {
            let alpha = resolve(token.1, appearance).a < 0.999
            cell(token.0, hex(token.1), at: CGPoint(x: left + CGFloat(i) * 128, y: y), backdrop: alpha, paint: fillSwatch(token.1))
        }
        y += 72 + DS.Space.s8 + 30
    }

    private func textAndLines() {
        section("Text and lines", "Primary and secondary text clear 4.5:1 on every surface. Borders that bound an input reach 3:1.")
        func tile(_ fill: NSColor, _ content: @escaping (CGRect) -> Void) -> (CGRect) -> Void {
            { rect in
                Draw.fill(NSBezierPath(rect: rect), fill)
                content(rect)
            }
        }
        var column = 0
        func next() -> CGPoint {
            defer { column += 1 }
            return CGPoint(x: left + CGFloat(column) * 128, y: y)
        }
        for (name, color) in [("textPrimary", C.textPrimary), ("textSecondary", C.textSecondary), ("textDisabled", C.textDisabled)] {
            cell(name, hex(color), at: next(), paint: tile(C.bgSurface) { Draw.text("Aa", DS.Text.title, color, centeredIn: $0) })
        }
        cell("separator", hex(C.separator), at: next(), paint: tile(C.bgSurface) {
            Draw.hairline(x0: $0.minX + 16, x1: $0.maxX - 16, y: $0.midY, C.separator)
        })
        for (name, color) in [("borderSubtle", C.borderSubtle), ("border", C.border), ("borderStrong", C.borderStrong)] {
            cell(name, hex(color), at: next(), paint: tile(C.bgSurface) {
                Draw.stroke(Draw.rounded($0.insetBy(dx: 24, dy: 18), DS.Radius.md), color, width: 1)
            })
        }
        cell("focusRing", hex(C.focusRing), at: next(), paint: tile(C.bgSurface) {
            let inner = $0.insetBy(dx: 28, dy: 22)
            Draw.fill(Draw.rounded(inner, DS.Radius.md), C.bgControl)
            let ring = Draw.rounded(inner.insetBy(dx: -3, dy: -3), DS.Radius.concentric(inner: DS.Radius.md, padding: 3))
            ring.lineWidth = 3
            C.focusRing.setStroke()
            ring.stroke()
        })
        cell("imageOutline", hex(C.imageOutline), at: next(), paint: tile(C.bgCanvas) { rect in
            let image = rect.insetBy(dx: 20, dy: 14)
            FakeScreen.draw(.document, in: image)
            Draw.stroke(Draw.rounded(image, 0), C.imageOutline)
        })
        cell("selection", "stroke + halo", at: next(), paint: tile(.black) { rect in
            FakeScreen.draw(.wallpaper, in: rect)
            let selection = NSBezierPath(rect: rect.insetBy(dx: 28, dy: 18))
            selection.lineWidth = 3
            C.selectionHalo.setStroke()
            selection.stroke()
            selection.lineWidth = 1
            C.selectionStroke.setStroke()
            selection.stroke()
        })
        y += 72 + DS.Space.s8 + 30
    }

    private struct Family {
        let name: String, purpose: String
        let subtle: NSColor, border: NSColor, solid: NSColor, hover: NSColor?, text: NSColor, on: NSColor
        let chipSymbol: String, chipLabel: String, buttonLabel: String
    }

    private func accentAndStatus() {
        section("Accent and status", "One accent means selected or primary. Status colours always travel with an icon or a label.")
        let families = [
            Family(name: "Accent  \(accent)", purpose: "Selected state, primary action", subtle: C.accentSubtle, border: C.accentBorder,
                   solid: C.accentSolid, hover: C.accentSolidHover, text: C.accentText, on: C.onAccent,
                   chipSymbol: "checkmark", chipLabel: "Seçili", buttonLabel: "Yakala"),
            Family(name: "Danger", purpose: "Conflicts, missing permission", subtle: C.dangerSubtle, border: C.dangerBorder,
                   solid: C.dangerSolid, hover: nil, text: C.dangerText, on: C.onDanger,
                   chipSymbol: "exclamationmark.octagon", chipLabel: "Kısayol çakışıyor", buttonLabel: "Sil"),
            Family(name: "Warning", purpose: "Scrolling capture caution", subtle: C.warningSubtle, border: C.warningBorder,
                   solid: C.warningSolid, hover: nil, text: C.warningText, on: C.onWarning,
                   chipSymbol: "exclamationmark.triangle", chipLabel: "Kaydırma yavaş", buttonLabel: "Devam et"),
            Family(name: "Success", purpose: "Permission granted", subtle: C.successSubtle, border: C.successBorder,
                   solid: C.successSolid, hover: nil, text: C.successText, on: C.onSuccess,
                   chipSymbol: "checkmark.circle", chipLabel: "İzin verildi", buttonLabel: "Hazır"),
        ]
        for f in families {
            Draw.text(f.name, DS.Text.bodyStrong, C.textPrimary, at: CGPoint(x: left, y: y), width: 184)
            Draw.text(f.purpose, DS.Text.caption, C.textSecondary, at: CGPoint(x: left, y: y + 20), width: 176)
            var x = left + 192
            func place(_ name: String, _ color: NSColor, paint: @escaping (CGRect) -> Void) {
                cell(name, hex(color), at: CGPoint(x: x, y: y), size: CGSize(width: 120, height: 56), paint: paint)
                x += 128
            }
            place("subtle", f.subtle) { Draw.fill(NSBezierPath(rect: $0), f.subtle); Draw.text("Aa", DS.Text.heading, f.text, centeredIn: $0) }
            place("border", f.border) { Draw.fill(NSBezierPath(rect: $0), f.border) }
            place("solid", f.solid) { Draw.fill(NSBezierPath(rect: $0), f.solid); Draw.text("Aa", DS.Text.heading, f.on, centeredIn: $0) }
            if let hover = f.hover {
                place("solidHover", hover) { Draw.fill(NSBezierPath(rect: $0), hover); Draw.text("Aa", DS.Text.heading, f.on, centeredIn: $0) }
            }
            place("text", f.text) { Draw.fill(NSBezierPath(rect: $0), C.bgWindow); Draw.text("Aa", DS.Text.heading, f.text, centeredIn: $0) }
            place("onSolid", f.on) { Draw.fill(NSBezierPath(rect: $0), f.on) }

            x = right - 304
            let chipWidth = DS.Space.s8 + DS.Size.iconSmall + DS.Space.s4 + Draw.width(f.chipLabel, DS.Text.label) + DS.Space.s8
            let chip = CGRect(x: x, y: y + 4, width: chipWidth, height: DS.Size.controlSmall)
            Draw.fill(Draw.rounded(chip, DS.Radius.sm), f.subtle)
            Draw.stroke(Draw.rounded(chip, DS.Radius.sm), f.border)
            Draw.symbol(f.chipSymbol, in: CGRect(x: chip.minX + DS.Space.s8, y: chip.minY, width: DS.Size.iconSmall, height: chip.height), size: DS.Size.iconSmall, f.text)
            Draw.text(f.chipLabel, DS.Text.label, f.text, at: CGPoint(x: chip.minX + DS.Space.s8 + DS.Size.iconSmall + DS.Space.s4, y: chip.midY - 8))
            let button = CGRect(x: chip.maxX + DS.Space.s12, y: y + 4 - 3, width: Draw.width(f.buttonLabel, DS.Text.bodyStrong) + 2 * DS.Space.s16, height: DS.Size.control)
            Draw.fill(Draw.rounded(button, DS.Radius.md), f.solid)
            Draw.text(f.buttonLabel, DS.Text.bodyStrong, f.on, centeredIn: button)
            y += 56 + DS.Space.s8 + 30 + DS.Space.s16
        }
        y -= DS.Space.s16
    }

    // MARK: Type, space, radius, elevation

    private func typeScale() {
        section("Type", "System font throughout. SF Pro adjusts optical size and tracking itself, so there is no manual tracking and no all-caps style.")
        let rows: [(String, TextStyle, String, String)] = [
            ("title", DS.Text.title, "20 / 26  semibold", "Ekran görüntüsü yakalandı"),
            ("heading", DS.Text.heading, "15 / 20  semibold", "Kayıt konumu ve biçim"),
            ("body", DS.Text.body, "13 / 18  regular", "Seçili alan panoya kopyalandı ve geçmişe eklendi."),
            ("bodyStrong", DS.Text.bodyStrong, "13 / 18  medium", "Panoya kopyala"),
            ("label", DS.Text.label, "12 / 16  medium", "Gecikme süresi"),
            ("caption", DS.Text.caption, "11 / 14  regular", "Kısayol başka bir uygulama tarafından kullanılıyor."),
            ("captionStrong", DS.Text.captionStrong, "11 / 14  semibold", "Genel"),
            ("readout", DS.Text.readout, "11 / 14  medium  SF Mono", "1280 × 720    x 412    y 96    2×"),
            ("numeral", DS.Text.numeral, "96 / 96  semibold  rounded", "3"),
        ]
        for (i, row) in rows.enumerated() {
            let height = row.1.lineHeight + 2 * DS.Space.s8
            if i > 0 { Draw.hairline(x0: left, x1: right, y: y, C.separator) }
            Draw.text("DS.Text.\(row.0)", DS.Text.readout, C.textSecondary, at: CGPoint(x: left, y: y + height / 2 - 7))
            Draw.text(row.2, DS.Text.caption, C.textSecondary, at: CGPoint(x: left + 232, y: y + height / 2 - 7))
            Draw.text(row.3, row.1, C.textPrimary, at: CGPoint(x: left + 456, y: y + DS.Space.s8), width: right - left - 456)
            y += height
        }
    }

    private func spaceAndSize() {
        section("Space and size", "A 4pt scale with 2 and 6 for tight toolbars. Controls are 22, 28 and 36 tall.")
        let top = y
        Draw.text("Space", DS.Text.captionStrong, C.textSecondary, at: CGPoint(x: left, y: y))
        var rowY = y + 24
        for (name, value) in zip(["s2", "s4", "s6", "s8", "s12", "s16", "s24", "s32"], DS.Space.all) {
            Draw.text("DS.Space.\(name)", DS.Text.readout, C.textSecondary, at: CGPoint(x: left, y: rowY + 5))
            Draw.text("\(Int(value))", DS.Text.readout, C.textPrimary, at: CGPoint(x: left + 128, y: rowY + 5))
            Draw.fill(Draw.rounded(CGRect(x: left + 168, y: rowY + 8, width: value * 6, height: 8), 2), C.textSecondary)
            rowY += 24
        }

        let sx = left + 640
        Draw.text("Size", DS.Text.captionStrong, C.textSecondary, at: CGPoint(x: sx, y: top))
        var x = sx
        let baseline = top + 24 + DS.Size.controlLarge
        for (name, h) in [("controlSmall", DS.Size.controlSmall), ("control", DS.Size.control), ("controlLarge", DS.Size.controlLarge)] {
            let box = CGRect(x: x, y: baseline - h, width: 96, height: h)
            Draw.fill(Draw.rounded(box, DS.Radius.md), C.bgControl)
            Draw.stroke(Draw.rounded(box, DS.Radius.md), C.border)
            Draw.text(name, DS.Text.readout, C.textSecondary, at: CGPoint(x: x, y: baseline + 8), width: 120)
            Draw.text("\(Int(h))", DS.Text.readout, C.textPrimary, at: CGPoint(x: x, y: baseline + 22), width: 96)
            x += 136
        }
        x = sx
        let iconTop = baseline + 64
        for (name, size) in [("iconSmall", DS.Size.iconSmall), ("icon", DS.Size.icon), ("iconLarge", DS.Size.iconLarge)] {
            let box = CGRect(x: x, y: iconTop, width: DS.Size.controlLarge, height: DS.Size.controlLarge)
            Draw.fill(Draw.rounded(box, DS.Radius.md), C.bgControl)
            Draw.stroke(Draw.rounded(box, DS.Radius.md), C.border)
            Draw.symbol("camera.viewfinder", in: box, size: size, C.textPrimary)
            Draw.text(name, DS.Text.readout, C.textSecondary, at: CGPoint(x: x + 48, y: iconTop + 3), width: 96)
            Draw.text("\(Int(size)) pt", DS.Text.readout, C.textPrimary, at: CGPoint(x: x + 48, y: iconTop + 19), width: 96)
            x += 160
        }
        y = max(rowY, iconTop + DS.Size.controlLarge) + DS.Space.s8
    }

    private func radii() {
        section("Radius", "Corners are continuous, not circular. Nested surfaces step by the padding between them.")
        var x = left
        for (name, r) in [("xs", DS.Radius.xs), ("sm", DS.Radius.sm), ("md", DS.Radius.md), ("lg", DS.Radius.lg), ("xl", DS.Radius.xl)] {
            let rect = CGRect(x: x, y: y, width: 96, height: 96)
            Draw.fill(Draw.rounded(rect, r), C.bgControl)
            Draw.stroke(Draw.rounded(rect, r), C.border)
            Draw.text("DS.Radius.\(name)", DS.Text.readout, C.textSecondary, at: CGPoint(x: x, y: rect.maxY + 8), width: 120)
            Draw.text("\(Int(r))", DS.Text.readout, C.textPrimary, at: CGPoint(x: x, y: rect.maxY + 22), width: 96)
            x += 120
        }

        func nested(_ x: CGFloat, innerRadius: CGFloat, caption: String, detail: String) {
            let outer = CGRect(x: x, y: y, width: 128, height: 96)
            Draw.fill(Draw.rounded(outer, DS.Radius.xl), C.bgSurface)
            Draw.stroke(Draw.rounded(outer, DS.Radius.xl), C.border)
            let inner = outer.insetBy(dx: DS.Space.s8, dy: DS.Space.s8)
            Draw.fill(Draw.rounded(inner, innerRadius), C.bgControlActive)
            Draw.text(caption, DS.Text.readout, C.textSecondary, at: CGPoint(x: x, y: outer.maxY + 8), width: 160)
            Draw.text(detail, DS.Text.readout, C.textPrimary, at: CGPoint(x: x, y: outer.maxY + 22), width: 160)
        }
        let concentric = DS.Radius.concentric(inner: DS.Radius.md, padding: DS.Space.s8)
        nested(left + 624, innerRadius: DS.Radius.md, caption: "concentric", detail: "inner 8 + pad 8 = \(Int(concentric))")
        nested(left + 784, innerRadius: DS.Radius.xl, caption: "not concentric", detail: "inner 16, pad 8")

        let box = CGRect(x: left + 960, y: y, width: 96, height: 96)
        Draw.fill(Draw.rounded(box, 32), C.bgControl)
        let circular = NSBezierPath(roundedRect: box, xRadius: 32, yRadius: 32)
        circular.lineWidth = 1
        C.textDisabled.setStroke()
        circular.stroke()
        let continuous = Draw.rounded(box, 32)
        continuous.lineWidth = 1
        C.textPrimary.setStroke()
        continuous.stroke()
        Draw.text("circular vs continuous", DS.Text.readout, C.textSecondary, at: CGPoint(x: box.minX, y: box.maxY + 8), width: 200)
        Draw.text("radius 32, enlarged", DS.Text.readout, C.textPrimary, at: CGPoint(x: box.minX, y: box.maxY + 22), width: 200)
        y += 96 + 8 + 30
    }

    private func elevation() {
        section("Elevation", "Shadow means depth, borders mean structure. Each level pairs a contact and an ambient shadow with a 1pt top highlight.")
        let panel = CGRect(x: left, y: y, width: Self.contentWidth, height: 232)
        Draw.fill(Draw.rounded(panel, DS.Radius.xl), C.bgCanvas)
        Draw.stroke(Draw.rounded(panel, DS.Radius.xl), C.border)

        let specs: [(String, CornermarkDesign.Elevation, String, [String])] = [
            ("raised", DS.Elevation.raised, "Menus, small cards", ["contact  y1 b2  12%", "ambient  y2 b6  10%", "highlight  none"]),
            ("hud", DS.Elevation.hud, "Capture bar, HUD", ["contact  y1 b3  30%", "ambient  y8 b24  35%", "highlight  white 10%"]),
            ("floating", DS.Elevation.floating, "Quick Access card, pins", ["contact  y2 b4  25%", "ambient  y12 b32  40%", "highlight  white 12%"]),
        ]
        for (i, spec) in specs.enumerated() {
            let card = CGRect(x: panel.minX + 56 + CGFloat(i) * 400, y: panel.minY + 56, width: 280, height: 120)
            let isHud = spec.0 == "hud"
            if isHud {
                let patch = card.insetBy(dx: -24, dy: -24)
                NSGraphicsContext.current?.saveGraphicsState()
                Draw.rounded(patch, DS.Radius.lg).addClip()
                FakeScreen.draw(.wallpaper, in: patch)
                NSGraphicsContext.current?.restoreGraphicsState()
            }
            let path = Draw.rounded(card, DS.Radius.xl)
            let paint = {
                spec.1.draw(path, fill: isHud ? C.bgHud : C.bgRaised)
                Draw.stroke(path, isHud ? C.border : C.borderSubtle)
                Draw.text("DS.Elevation.\(spec.0)", DS.Text.bodyStrong, C.textPrimary, at: CGPoint(x: card.minX + 16, y: card.minY + 16))
                Draw.text(spec.2, DS.Text.caption, C.textSecondary, at: CGPoint(x: card.minX + 16, y: card.minY + 36))
                for (n, line) in spec.3.enumerated() {
                    Draw.text(line, DS.Text.readout, C.textSecondary, at: CGPoint(x: card.minX + 16, y: card.minY + 62 + CGFloat(n) * 14), width: 248)
                }
            }
            if isHud { NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance(paint) } else { paint() }
        }
        y = panel.maxY
    }
}

func renderSpecimens() {
    for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
        var height: CGFloat = 0
        _ = render(size: CGSize(width: Sheet.width, height: 16), scale: 1, flipped: true, appearance: appearance) {
            height = ceil(Sheet(appearance: appearance, accent: accentName).draw(height: 16))
        }
        let rep = render(size: CGSize(width: Sheet.width, height: height), scale: 2, flipped: true, appearance: appearance) {
            _ = Sheet(appearance: appearance, accent: accentName).draw(height: height)
        }
        let url = URL(fileURLWithPath: "build/design/specimen-\(name).png")
        writePNG(rep, to: url)
        print("wrote \(url.path)  \(Int(Sheet.width)) x \(Int(height)) pt")
    }
}
