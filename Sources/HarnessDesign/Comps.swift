import AppKit
import CornermarkDesign

private typealias C = DS.Color

private let darkAppearance = NSAppearance(named: .darkAqua)!

private func saved(_ body: () -> Void) {
    NSGraphicsContext.current?.saveGraphicsState()
    body()
    NSGraphicsContext.current?.restoreGraphicsState()
}

private func clipped(to path: NSBezierPath, _ body: () -> Void) { saved { path.addClip(); body() } }

/// A round or rounded button on top of the chrome, with an SF Symbol and no label.
private func iconButton(_ rect: CGRect, symbol: String, size: CGFloat = DS.Size.icon, fill: NSColor? = nil, tint: NSColor, radius: CGFloat = DS.Radius.md,
                        outline: NSColor? = nil) {
    let path = Draw.rounded(rect, radius)
    if let fill { Draw.fill(path, fill) }
    if let outline { Draw.stroke(path, outline) }
    Draw.symbol(symbol, in: rect, size: size, tint)
}

private func handles(of rect: CGRect) {
    for ix in 0..<3 {
        for iy in 0..<3 where !(ix == 1 && iy == 1) {
            let c = CGPoint(x: rect.minX + rect.width / 2 * CGFloat(ix), y: rect.minY + rect.height / 2 * CGFloat(iy))
            Draw.fill(Draw.circle(CGRect(x: c.x - 5, y: c.y - 5, width: 10, height: 10)), C.selectionHalo)
            Draw.fill(Draw.circle(CGRect(x: c.x - 4, y: c.y - 4, width: 8, height: 8)), C.selectionStroke)
        }
    }
}

extension Sheet {
    func inContext() {
        section("In context", "Three comps drawn only from the tokens above: capture HUD, Quick Access, editor.")
        let gap = DS.Space.s32
        let hudWidth: CGFloat = 760, rowHeight: CGFloat = 496

        label("Capture overlay", "Always dark, so it carries .darkAqua and the same tokens.", x: left)
        label("Quick Access", "Floating card, concentric thumbnail, round actions.", x: left + hudWidth + gap)
        y += 20 + DS.Space.s12
        hudComp(CGRect(x: left, y: y, width: hudWidth, height: rowHeight))
        quickAccessComp(CGRect(x: left + hudWidth + gap, y: y, width: Self.contentWidth - hudWidth - gap, height: rowHeight))
        y += rowHeight + DS.Space.s32

        label("Editor", "Toolbar, property bar and canvas on surface, surface, canvas.", x: left)
        y += 20 + DS.Space.s12
        editorComp(CGRect(x: left, y: y, width: Self.contentWidth, height: 560))
        y += 560
    }

    private func label(_ title: String, _ caption: String, x: CGFloat) {
        Draw.text(title, DS.Text.bodyStrong, C.textPrimary, at: CGPoint(x: x, y: y))
        Draw.text(caption, DS.Text.caption, C.textSecondary, at: CGPoint(x: x + Draw.width(title, DS.Text.bodyStrong) + DS.Space.s8, y: y + 2))
    }

    // MARK: Capture HUD

    private func hudComp(_ f: CGRect) {
        let frame = Draw.rounded(f, DS.Radius.xl)
        let selection = CGRect(x: f.minX + 120, y: f.minY + 88, width: 480, height: 272)
        clipped(to: frame) {
            FakeScreen.draw(.wallpaper, in: f)
            let scrim = NSBezierPath(rect: f)
            scrim.append(NSBezierPath(rect: selection))
            scrim.windingRule = .evenOdd
            Draw.fill(scrim, C.bgScrim)
        }
        Draw.stroke(frame, C.imageOutline)

        let edge = NSBezierPath(rect: selection)
        edge.lineWidth = 3
        C.selectionHalo.setStroke()
        edge.stroke()
        edge.lineWidth = 1
        C.selectionStroke.setStroke()
        edge.stroke()
        handles(of: selection)

        darkAppearance.performAsCurrentDrawingAppearance {
            let readout = "480 × 272"
            let chip = CGRect(x: selection.minX, y: selection.minY - DS.Space.s8 - DS.Size.controlSmall,
                              width: Draw.width(readout, DS.Text.readout) + 2 * DS.Space.s8, height: DS.Size.controlSmall)
            DS.Elevation.raised.draw(Draw.rounded(chip, DS.Radius.sm), fill: C.bgHud)
            Draw.text(readout, DS.Text.readout, C.textPrimary, centeredIn: chip)

            let pad = DS.Space.s4, button = DS.Size.controlLarge
            let modes = ["rectangle.dashed", "macwindow", "display", "arrow.up.and.down.text.horizontal", "timer"]
            let captureWidth = Draw.width("Capture", DS.Text.bodyStrong) + 2 * DS.Space.s16
            let dividerSpan = DS.Space.s8 + 1 + DS.Space.s8
            let aspectWidth: CGFloat = 64, fieldWidth: CGFloat = 48, timesWidth = DS.Space.s16
            let width = pad + CGFloat(modes.count) * button + CGFloat(modes.count - 1) * DS.Space.s4 + dividerSpan + aspectWidth + dividerSpan
                + 2 * fieldWidth + timesWidth + dividerSpan + captureWidth + pad
            let bar = CGRect(x: selection.midX - width / 2, y: selection.maxY + DS.Space.s16, width: width, height: button + 2 * pad)
            let radius = DS.Radius.concentric(inner: DS.Radius.md, padding: pad)
            DS.Elevation.hud.draw(Draw.rounded(bar, radius), fill: C.bgHud)

            func divider(_ x: inout CGFloat) {
                x += DS.Space.s8
                Draw.fill(NSBezierPath(rect: CGRect(x: x, y: bar.midY - 10, width: 1, height: 20)), C.separator)
                x += 1 + DS.Space.s8
            }
            var x = bar.minX + pad
            let top = bar.minY + pad
            for (i, symbol) in modes.enumerated() {
                let rect = CGRect(x: x, y: top, width: button, height: button)
                if i == 0 {
                    iconButton(rect, symbol: symbol, size: DS.Size.iconLarge, fill: C.accentSubtle, tint: C.accentText, outline: C.accentBorder)
                } else {
                    iconButton(rect, symbol: symbol, size: DS.Size.iconLarge, tint: C.textSecondary)
                }
                x += button + (i < modes.count - 1 ? DS.Space.s4 : 0)
            }
            divider(&x)
            Draw.text("Free", DS.Text.label, C.textSecondary, at: CGPoint(x: x + DS.Space.s4, y: bar.midY - 8))
            Draw.symbol("chevron.up.chevron.down", in: CGRect(x: x + aspectWidth - 20, y: top, width: 16, height: button), size: DS.Size.iconSmall, C.textSecondary)
            x += aspectWidth
            divider(&x)
            let fieldTop = bar.midY - DS.Size.control / 2
            for (i, value) in ["480", "272"].enumerated() {
                let field = CGRect(x: x, y: fieldTop, width: fieldWidth, height: DS.Size.control)
                Draw.fill(Draw.rounded(field, DS.Radius.sm), C.bgControl)
                Draw.text(value, DS.Text.readout, C.textPrimary, centeredIn: field)
                x += fieldWidth
                if i == 0 {
                    Draw.text("×", DS.Text.caption, C.textSecondary, centeredIn: CGRect(x: x, y: fieldTop, width: timesWidth, height: DS.Size.control))
                    x += timesWidth
                }
            }
            divider(&x)
            let capture = CGRect(x: x, y: top, width: captureWidth, height: button)
            Draw.fill(Draw.rounded(capture, DS.Radius.md), C.accentSolid)
            Draw.text("Capture", DS.Text.bodyStrong, C.onAccent, centeredIn: capture)
        }
    }

    // MARK: Quick Access

    private func quickAccessComp(_ f: CGRect) {
        let panel = Draw.rounded(f, DS.Radius.xl)
        Draw.fill(panel, C.bgCanvas)
        Draw.stroke(panel, C.border)
        let size = CGSize(width: 272, height: 224)
        quickAccessCard(CGRect(origin: CGPoint(x: f.midX - size.width / 2, y: f.minY + DS.Space.s16), size: size),
                        name: "Ekran Görüntüsü 14.32.05", meta: "PNG  ·  1920 × 1080  ·  412 KB", variant: .wallpaper, active: true)
        quickAccessCard(CGRect(origin: CGPoint(x: f.midX - size.width / 2, y: f.minY + DS.Space.s16 + size.height + DS.Space.s16), size: size),
                        name: "Ekran Görüntüsü 14.31.48", meta: "PNG  ·  1440 × 900  ·  268 KB", variant: .document, active: false)
    }

    private func quickAccessCard(_ card: CGRect, name: String, meta: String, variant: FakeScreen.Variant, active: Bool) {
        let path = Draw.rounded(card, DS.Radius.xl)
        DS.Elevation.floating.draw(path, fill: C.bgRaised)
        Draw.stroke(path, C.borderSubtle)

        let pad = DS.Space.s8
        let thumb = CGRect(x: card.minX + pad, y: card.minY + pad, width: card.width - 2 * pad, height: 160)
        let thumbPath = Draw.rounded(thumb, DS.Radius.concentric(inner: DS.Radius.md, padding: pad) - pad)
        clipped(to: thumbPath) {
            FakeScreen.draw(variant, in: thumb)
            if active {
                let shade = CGRect(x: thumb.minX, y: thumb.maxY - 88, width: thumb.width, height: 88)
                NSGradient(colors: [C.bgScrim.withAlphaComponent(0), C.bgScrim])?.draw(from: shade.origin, to: CGPoint(x: shade.minX, y: shade.maxY), options: [])
            }
        }
        Draw.stroke(thumbPath, C.imageOutline)

        if active {
            darkAppearance.performAsCurrentDrawingAppearance {
                let diameter = DS.Size.control
                let symbols = ["doc.on.doc", "square.and.arrow.down", "pencil.tip.crop.circle", "pin", "text.viewfinder"]
                var x = thumb.midX - (CGFloat(symbols.count) * diameter + CGFloat(symbols.count - 1) * DS.Space.s8) / 2
                for symbol in symbols {
                    let rect = CGRect(x: x, y: thumb.maxY - DS.Space.s8 - diameter, width: diameter, height: diameter)
                    DS.Elevation.raised.draw(Draw.circle(rect), fill: C.bgHud)
                    Draw.symbol(symbol, in: rect, size: DS.Size.icon, C.textPrimary)
                    x += diameter + DS.Space.s8
                }
                let close = CGRect(x: thumb.minX + DS.Space.s8, y: thumb.minY + DS.Space.s8, width: DS.Size.controlSmall, height: DS.Size.controlSmall)
                DS.Elevation.raised.draw(Draw.circle(close), fill: C.bgHud)
                Draw.symbol("xmark", in: close, size: DS.Size.iconSmall, C.textPrimary)
            }
        }

        let textX = card.minX + DS.Space.s12
        let footer = thumb.maxY + DS.Space.s12
        Draw.text(name, DS.Text.label, C.textPrimary, at: CGPoint(x: textX, y: footer), width: card.width - 2 * DS.Space.s12)
        Draw.text(meta, DS.Text.caption, C.textSecondary, at: CGPoint(x: textX, y: footer + 18), width: card.width - 2 * DS.Space.s12)
        if active {
            let text = "Kopyalandı"
            let width = DS.Space.s8 + DS.Size.iconSmall + DS.Space.s4 + Draw.width(text, DS.Text.label) + DS.Space.s8
            let chip = CGRect(x: thumb.maxX - DS.Space.s8 - width, y: thumb.minY + DS.Space.s8, width: width, height: DS.Size.controlSmall)
            DS.Elevation.raised.draw(Draw.rounded(chip, DS.Radius.sm), fill: C.successSubtle)
            Draw.stroke(Draw.rounded(chip, DS.Radius.sm), C.successBorder)
            Draw.symbol("checkmark.circle", in: CGRect(x: chip.minX + DS.Space.s8, y: chip.minY, width: DS.Size.iconSmall, height: chip.height),
                        size: DS.Size.iconSmall, C.successText)
            Draw.text(text, DS.Text.label, C.successText, at: CGPoint(x: chip.minX + DS.Space.s8 + DS.Size.iconSmall + DS.Space.s4, y: chip.midY - 8))
        }
    }

    // MARK: Editor

    private func editorComp(_ f: CGRect) {
        let window = Draw.rounded(f, DS.Radius.lg)
        DS.Elevation.floating.draw(window, fill: C.bgWindow)

        let titleBar = CGRect(x: f.minX, y: f.minY, width: f.width, height: 36)
        let toolbar = CGRect(x: f.minX, y: titleBar.maxY, width: f.width, height: 44)
        let properties = CGRect(x: f.minX, y: toolbar.maxY, width: f.width, height: 40)
        let canvas = CGRect(x: f.minX, y: properties.maxY, width: f.width, height: f.maxY - properties.maxY)

        clipped(to: window) {
            Draw.fill(NSBezierPath(rect: CGRect(x: f.minX, y: titleBar.minY, width: f.width, height: properties.maxY - titleBar.minY)), C.bgSurface)
            Draw.fill(NSBezierPath(rect: canvas), C.bgCanvas)
            Draw.hairline(x0: f.minX, x1: f.maxX, y: properties.minY, C.separator)
            Draw.hairline(x0: f.minX, x1: f.maxX, y: properties.maxY - 1, C.separator)
        }

        for (i, color) in [C.dangerSolid, C.warningSolid, C.successSolid].enumerated() {
            Draw.fill(Draw.circle(CGRect(x: f.minX + DS.Space.s16 + CGFloat(i) * 20, y: titleBar.midY - 6, width: 12, height: 12)), color)
        }
        Draw.text("Ekran Görüntüsü 14.32.05", DS.Text.label, C.textPrimary, centeredIn: titleBar)

        toolbarRow(toolbar)
        propertyRow(properties)
        canvasContent(canvas)
        Draw.stroke(window, C.border)
    }

    private func toolbarRow(_ bar: CGRect) {
        let size = DS.Size.control
        let top = bar.midY - size / 2
        var x = bar.minX + DS.Space.s16
        let groups: [[String]] = [["cursorarrow"], ["arrow.up.right", "line.diagonal", "rectangle", "rectangle.fill", "circle", "circle.fill"],
                                 ["textformat", "1.circle"], ["pencil", "highlighter"], ["drop.halffull", "squareshape.split.3x3", "flashlight.on.fill"],
                                 ["crop", "photo.artframe"]]
        for (g, group) in groups.enumerated() {
            for symbol in group {
                let rect = CGRect(x: x, y: top, width: size, height: size)
                if symbol == "arrow.up.right" {
                    iconButton(rect, symbol: symbol, fill: C.accentSubtle, tint: C.accentText, outline: C.accentBorder)
                } else {
                    iconButton(rect, symbol: symbol, tint: C.textPrimary)
                }
                x += size + DS.Space.s4
            }
            if g < groups.count - 1 {
                x += DS.Space.s4
                Draw.fill(NSBezierPath(rect: CGRect(x: x, y: bar.midY - 8, width: 1, height: 16)), C.separator)
                x += 1 + DS.Space.s8
            }
        }

        var right = bar.maxX - DS.Space.s16
        let copyWidth = Draw.width("Copy", DS.Text.bodyStrong) + 2 * DS.Space.s16
        let copy = CGRect(x: right - copyWidth, y: top, width: copyWidth, height: size)
        Draw.fill(Draw.rounded(copy, DS.Radius.md), C.accentSolid)
        Draw.text("Copy", DS.Text.bodyStrong, C.onAccent, centeredIn: copy)
        right = copy.minX - DS.Space.s8
        let trailing: [[String]] = [["square.and.arrow.down", "pin"], ["hand.draw"], ["arrow.uturn.forward", "arrow.uturn.backward"],
                                    ["arrow.up.left.and.down.right.magnifyingglass", "arrow.up.and.down.righttriangle.up.righttriangle.down",
                                     "arrow.left.and.right.righttriangle.left.righttriangle.right", "rotate.right"]]
        for (g, group) in trailing.enumerated() {
            for symbol in group {
                right -= size
                iconButton(CGRect(x: right, y: top, width: size, height: size), symbol: symbol, tint: C.textSecondary)
                right -= DS.Space.s4
            }
            if g < trailing.count - 1 {
                right -= DS.Space.s4
                Draw.fill(NSBezierPath(rect: CGRect(x: right, y: bar.midY - 8, width: 1, height: 16)), C.separator)
                right -= DS.Space.s8
            }
        }
    }

    private func propertyRow(_ bar: CGRect) {
        var x = bar.minX + DS.Space.s16
        Draw.text("Renk", DS.Text.caption, C.textSecondary, at: CGPoint(x: x, y: bar.midY - 7))
        x += Draw.width("Renk", DS.Text.caption) + DS.Space.s12
        let colors: [UInt32] = [0xE5484D, 0xF76B15, 0xF5D90A, 0x30A46C, 0x3E63DD, 0xFFFFFF]
        for (i, hex) in colors.enumerated() {
            let slot = CGRect(x: x, y: bar.midY - 11, width: DS.Size.controlSmall, height: DS.Size.controlSmall)
            Draw.fill(Draw.circle(slot.insetBy(dx: 3, dy: 3)), Draw.srgb(hex))
            Draw.stroke(Draw.circle(slot.insetBy(dx: 3, dy: 3)), C.imageOutline)
            if i == 0 {
                let ring = Draw.circle(slot.insetBy(dx: 1, dy: 1))
                ring.lineWidth = 2
                C.accentMark.setStroke()
                ring.stroke()
            }
            x += DS.Size.controlSmall + DS.Space.s2
        }
        x += DS.Space.s12
        Draw.fill(NSBezierPath(rect: CGRect(x: x, y: bar.midY - 8, width: 1, height: 16)), C.separator)
        x += 1 + DS.Space.s16

        Draw.text("Kalınlık", DS.Text.caption, C.textSecondary, at: CGPoint(x: x, y: bar.midY - 7))
        x += Draw.width("Kalınlık", DS.Text.caption) + DS.Space.s12
        let track = CGRect(x: x, y: bar.midY - 2, width: 120, height: 4)
        Draw.fill(Draw.rounded(track, 2), C.bgControlActive)
        let value = track.minX + track.width * 0.4
        Draw.fill(Draw.rounded(CGRect(x: track.minX, y: track.minY, width: value - track.minX, height: 4), 2), C.textSecondary)
        let knob = CGRect(x: value - 7, y: bar.midY - 7, width: 14, height: 14)
        DS.Elevation.raised.draw(Draw.circle(knob), fill: C.bgRaised)
        Draw.stroke(Draw.circle(knob), C.borderStrong)
        x = track.maxX + DS.Space.s12
        Draw.text("4 px", DS.Text.readout, C.textPrimary, at: CGPoint(x: x, y: bar.midY - 7))

        Draw.text("x 412    y 96    w 220    h 120", DS.Text.readout, C.textSecondary,
                  at: CGPoint(x: bar.maxX - DS.Space.s16 - 232, y: bar.midY - 7), width: 232, align: .right)
    }

    private func canvasContent(_ canvas: CGRect) {
        let image = CGRect(x: canvas.midX - 296, y: canvas.minY + 36, width: 592, height: 368)
        let path = Draw.rounded(image, DS.Radius.md)
        DS.Elevation.raised.draw(path, fill: .white)
        clipped(to: path) { FakeScreen.draw(.document, in: image) }
        Draw.stroke(path, C.imageOutline)

        let red = Draw.srgb(0xE5484D)
        let target = CGRect(x: image.minX + 290, y: image.minY + 84, width: 226, height: 124)
        let box = Draw.rounded(target, DS.Radius.xs)
        box.lineWidth = 3
        red.setStroke()
        box.stroke()

        let tail = CGPoint(x: image.minX + 110, y: image.minY + 290), tip = CGPoint(x: target.minX + 24, y: target.maxY + 6)
        let angle = atan2(tip.y - tail.y, tip.x - tail.x)
        Draw.line(from: tail, to: CGPoint(x: tip.x - 10 * cos(angle), y: tip.y - 10 * sin(angle)), red, width: 3)
        let head = NSBezierPath()
        head.move(to: tip)
        head.line(to: CGPoint(x: tip.x - 16 * cos(angle - 0.45), y: tip.y - 16 * sin(angle - 0.45)))
        head.line(to: CGPoint(x: tip.x - 16 * cos(angle + 0.45), y: tip.y - 16 * sin(angle + 0.45)))
        head.close()
        Draw.fill(head, red)

        let badge = CGRect(x: target.minX - 40, y: target.minY - 16, width: 24, height: 24)
        Draw.fill(Draw.circle(badge), red)
        Draw.text("1", DS.Text.bodyStrong, .white, centeredIn: badge)
        handles(of: target.insetBy(dx: -4, dy: -4))
    }
}
