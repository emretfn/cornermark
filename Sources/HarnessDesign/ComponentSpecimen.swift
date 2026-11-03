import AppKit
@testable import KadrajDesign

private typealias C = DS.Color

/// Real component instances, rendered through the view pipeline with `cacheDisplay` and stamped into the sheet.
func renderedImage(of view: NSView, appearance: NSAppearance.Name) -> NSBitmapImageRep {
    view.appearance = NSAppearance(named: appearance)
    view.layoutSubtreeIfNeeded()
    let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
    view.cacheDisplay(in: view.bounds, to: rep)
    return rep
}

extension Sheet {
    private func stamp(_ view: NSView, at origin: CGPoint, appearance forced: NSAppearance.Name? = nil) {
        let rep = renderedImage(of: view, appearance: forced ?? appearance)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        image.draw(in: CGRect(origin: origin, size: view.bounds.size), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    private func column(_ title: String, x: CGFloat, width: CGFloat) {
        Draw.text(title, DS.Text.readout, C.textSecondary, at: CGPoint(x: x, y: y), width: width)
    }

    func components() {
        section("Components", "Real instances of the shipped controls, rendered by HarnessDesign. Each cell pins its state; the controls read one InteractionState and a table.")
        buttons()
        iconButtons()
        segments()
        sliders()
        checkboxes()
        textInputs()
        surfaces()
        smallParts()
    }

    // MARK: Button

    private func buttons() {
        Draw.text("Button", DS.Text.bodyStrong, C.textPrimary, at: CGPoint(x: left, y: y))
        Draw.text("variant x size x state, with and without an icon", DS.Text.caption, C.textSecondary, at: CGPoint(x: left + 56, y: y + 2))
        y += 28
        let cell: CGFloat = 124, labelWidth: CGFloat = 176
        let heads = [("title only", 0), ("with icon", 1)]
        for (group, g) in heads {
            let x0 = left + labelWidth + (g == 0 ? 0 : 4 * cell + 24)
            Draw.text(group, DS.Text.captionStrong, C.textSecondary, at: CGPoint(x: x0, y: y), width: 4 * cell)
        }
        y += 16
        for (_, g) in heads {
            let x0 = left + labelWidth + (g == 0 ? 0 : 4 * cell + 24)
            for (i, state) in InteractionState.allCases.enumerated() { column("\(state)", x: x0 + CGFloat(i) * cell, width: cell) }
        }
        y += 20
        for variant in Button.Variant.allCases {
            for size in ComponentSize.allCases {
                let rowHeight = DS.Size.controlLarge + DS.Space.s8
                if size == .small { Draw.text(".\(variant)", DS.Text.label, C.textPrimary, at: CGPoint(x: left, y: y + 4)) }
                Draw.text("\(size)  \(Int(size == .small ? DS.Size.controlSmall : size == .regular ? DS.Size.control : DS.Size.controlLarge))", DS.Text.readout,
                          C.textSecondary, at: CGPoint(x: left + 88, y: y + 4))
                for (g, symbol) in [String?.none, "camera.viewfinder"].enumerated() {
                    let x0 = left + labelWidth + (g == 0 ? 0 : 4 * cell + 24)
                    for (i, state) in InteractionState.allCases.enumerated() {
                        let button = Button(title: "Capture", variant: variant, size: size, symbol: symbol)
                        button.forcedState = state
                        button.isEnabled = state != .disabled
                        stamp(button, at: CGPoint(x: x0 + CGFloat(i) * cell, y: y))
                    }
                }
                y += rowHeight
            }
            y += DS.Space.s8
        }
    }

    // MARK: IconButton

    private func iconButtons() {
        y += DS.Space.s24
        Draw.text("IconButton", DS.Text.bodyStrong, C.textPrimary, at: CGPoint(x: left, y: y))
        Draw.text("plain and overlay, unselected and selected, three sizes, four states each", DS.Text.caption, C.textSecondary,
                  at: CGPoint(x: left + 84, y: y + 2))
        y += 28
        let cell: CGFloat = 64, labelWidth: CGFloat = 200, groupGap: CGFloat = 24
        for (g, size) in ComponentSize.allCases.enumerated() {
            let x0 = left + labelWidth + CGFloat(g) * (4 * cell + groupGap)
            Draw.text("\(size)", DS.Text.captionStrong, C.textSecondary, at: CGPoint(x: x0, y: y), width: 4 * cell)
        }
        y += 16
        for g in 0..<ComponentSize.allCases.count {
            let x0 = left + labelWidth + CGFloat(g) * (4 * cell + groupGap)
            for (i, state) in InteractionState.allCases.enumerated() { column("\(state)", x: x0 + CGFloat(i) * cell, width: cell) }
        }
        y += 18
        for (tone, selected) in [(IconButton.Tone.plain, false), (.plain, true), (.overlay, false), (.overlay, true)] {
            let rowHeight = DS.Size.controlLarge + 2 * DS.Space.s8
            if tone == .overlay {
                let strip = CGRect(x: left + labelWidth - DS.Space.s8, y: y, width: 3 * (4 * cell + groupGap) - groupGap + 2 * DS.Space.s8, height: rowHeight)
                NSGraphicsContext.current?.saveGraphicsState()
                Draw.rounded(strip, DS.Radius.md).addClip()
                FakeScreen.draw(.wallpaper, in: strip)
                NSGraphicsContext.current?.restoreGraphicsState()
            }
            Draw.text(".\(tone)\(selected ? "  selected" : "")", DS.Text.label, C.textPrimary, at: CGPoint(x: left, y: y + rowHeight / 2 - 8))
            for (g, size) in ComponentSize.allCases.enumerated() {
                let x0 = left + labelWidth + CGFloat(g) * (4 * cell + groupGap)
                for (i, state) in InteractionState.allCases.enumerated() {
                    let button = IconButton(symbol: "rectangle.dashed", label: "Area", size: size, tone: tone)
                    button.isSelected = selected
                    button.forcedState = state
                    button.isEnabled = state != .disabled
                    let side = button.bounds.width
                    stamp(button, at: CGPoint(x: x0 + CGFloat(i) * cell, y: y + (rowHeight - side) / 2))
                }
            }
            y += rowHeight + DS.Space.s4
        }
    }

    // MARK: Segments, Slider, Checkbox

    private func segments() {
        y += DS.Space.s24
        Draw.text("Segments", DS.Text.bodyStrong, C.textPrimary, at: CGPoint(x: left, y: y))
        Draw.text("separate tiles, dividers between groups, one segment pinned to each state", DS.Text.caption, C.textSecondary, at: CGPoint(x: left + 70, y: y + 2))
        y += 28
        let tools = ["cursorarrow", "arrow.up.right", "line.diagonal", "rectangle", "textformat", "1.circle", "pencil", "crop", "photo.artframe"]
        let rows: [(String, Segments, [Int: InteractionState])] = [
            ("tools, regular", { let s = Segments(symbols: tools, labels: tools); s.dividers = [0, 2, 5, 6]; s.selectedSegment = 1; return s }(),
             [3: .hover, 4: .pressed, 8: .disabled]),
            ("quiet, regular, momentary", Segments(symbols: ["rotate.right", "arrow.left.and.right.righttriangle.left.righttriangle.right", "arrow.up.and.down.righttriangle.up.righttriangle.down"],
                                                   labels: ["Rotate", "Flip horizontally", "Flip vertically"], trackingMode: .momentary, quiet: true), [1: .hover, 2: .pressed]),
            ("labels, small", { let s = Segments(labels: ["Classic", "Tapered", "Double"]); s.selectedSegment = 0; return s }(), [1: .hover, 2: .disabled]),
            ("tools, small", { let s = Segments(symbols: ["arrow.uturn.backward", "arrow.uturn.forward"], labels: ["Undo", "Redo"], trackingMode: .momentary, size: .small); return s }(),
             [0: .hover, 1: .disabled]),
        ]
        for (name, control, states) in rows {
            control.forcedStates = states
            Draw.text(name, DS.Text.label, C.textPrimary, at: CGPoint(x: left, y: y + control.bounds.height / 2 - 8), width: 168)
            stamp(control, at: CGPoint(x: left + 176, y: y))
            y += DS.Size.control + DS.Space.s8
        }
    }

    private func sliders() {
        y += DS.Space.s24
        Draw.text("Slider", DS.Text.bodyStrong, C.textPrimary, at: CGPoint(x: left, y: y))
        Draw.text("3pt track, neutral fill, 14pt raised knob; the accent is never used", DS.Text.caption, C.textSecondary, at: CGPoint(x: left + 48, y: y + 2))
        y += 28
        for (i, (name, value, enabled, small)) in [("0%", 0.0, true, true), ("40%", 0.4, true, true), ("100%", 1.0, true, true), ("40%, regular", 0.4, true, false),
                                                   ("disabled", 0.4, false, true)].enumerated() {
            let slider = Slider(value: value, minValue: 0, maxValue: 1, target: nil, action: nil)
            slider.controlSize = small ? .small : .regular
            slider.isEnabled = enabled
            slider.frame = CGRect(x: 0, y: 0, width: 140, height: slider.intrinsicContentSize.height)
            let x = left + CGFloat(i) * 192
            stamp(slider, at: CGPoint(x: x, y: y))
            Draw.text(name, DS.Text.readout, C.textSecondary, at: CGPoint(x: x, y: y + DS.Size.controlSmall + 4), width: 160)
        }
        y += DS.Size.controlSmall + 4 + 14
    }

    private func checkboxes() {
        y += DS.Space.s24
        Draw.text("Checkbox", DS.Text.bodyStrong, C.textPrimary, at: CGPoint(x: left, y: y))
        Draw.text("off and on, four states each; the box carries the accent only when on", DS.Text.caption, C.textSecondary, at: CGPoint(x: left + 70, y: y + 2))
        y += 28
        let cell: CGFloat = 144
        for (i, state) in InteractionState.allCases.enumerated() { column("\(state)", x: left + 96 + CGFloat(i) * cell, width: cell) }
        y += 20
        for on in [false, true] {
            Draw.text(on ? "on" : "off", DS.Text.readout, C.textSecondary, at: CGPoint(x: left, y: y + 6))
            for (i, state) in InteractionState.allCases.enumerated() {
                let box = Checkbox(title: "Shadow", size: .small)
                box.state = on ? .on : .off
                box.forcedState = state
                box.isEnabled = state != .disabled
                stamp(box, at: CGPoint(x: left + 96 + CGFloat(i) * cell, y: y))
            }
            y += DS.Size.controlSmall + DS.Space.s8
        }
    }

    // MARK: TextInput

    private func textInputs() {
        y += DS.Space.s24
        Draw.text("TextInput", DS.Text.bodyStrong, C.textPrimary, at: CGPoint(x: left, y: y))
        Draw.text("three sizes; proportional and monospaced; centred; disabled", DS.Text.caption, C.textSecondary, at: CGPoint(x: left + 76, y: y + 2))
        y += 28
        let cell: CGFloat = 168
        let heads = ["placeholder", "filled", "monospaced", "centred monospaced", "disabled"]
        for (i, head) in heads.enumerated() { column(head, x: left + 96 + CGFloat(i) * cell, width: cell) }
        y += 20
        for size in ComponentSize.allCases {
            Draw.text("\(size)", DS.Text.readout, C.textSecondary, at: CGPoint(x: left, y: y + 8))
            for i in 0..<heads.count {
                let input = TextInput(placeholder: "Width", size: size, monospaced: i == 2 || i == 3, centered: i == 3)
                if i != 0 && i != 4 { input.stringValue = i == 1 ? "Ekran Görüntüsü" : "1280" }
                input.isEnabled = i != 4
                input.frame.size.width = 144
                stamp(input, at: CGPoint(x: left + 96 + CGFloat(i) * cell, y: y))
            }
            y += DS.Size.controlLarge + DS.Space.s8
        }
    }

    // MARK: Surface

    private func surfaces() {
        y += DS.Space.s24
        Draw.text("Surface", DS.Text.bodyStrong, C.textPrimary, at: CGPoint(x: left, y: y))
        Draw.text("hud, raised, floating and panel with a 32pt shadow inset; the HUD is always dark", DS.Text.caption, C.textSecondary,
                  at: CGPoint(x: left + 56, y: y + 2))
        y += 24
        let inset = DS.Space.s32, content = CGSize(width: 224, height: 88)
        let band = CGRect(x: left, y: y, width: Self.contentWidth, height: content.height + 2 * inset)
        Draw.fill(Draw.rounded(band, DS.Radius.xl), C.bgCanvas)
        Draw.stroke(Draw.rounded(band, DS.Radius.xl), C.border)
        for (i, style) in Surface.Style.allCases.enumerated() {
            let surface = Surface(style: style, shadowInset: inset)
            surface.frame.size = CGSize(width: content.width + 2 * inset, height: content.height + 2 * inset)
            let origin = CGPoint(x: left + 16 + CGFloat(i) * (content.width + 2 * inset + 8), y: y)
            if style == .hud {
                let patch = CGRect(x: origin.x + inset - 12, y: origin.y + inset - 12, width: content.width + 24, height: content.height + 24)
                NSGraphicsContext.current?.saveGraphicsState()
                Draw.rounded(patch, DS.Radius.lg).addClip()
                FakeScreen.draw(.wallpaper, in: patch)
                NSGraphicsContext.current?.restoreGraphicsState()
            }
            stamp(surface, at: origin, appearance: style == .hud ? .darkAqua : nil)
            let label = CGPoint(x: origin.x + inset + DS.Space.s12, y: origin.y + inset + DS.Space.s12)
            NSAppearance(named: style == .hud ? .darkAqua : appearance)!.performAsCurrentDrawingAppearance {
                Draw.text(".\(style)", DS.Text.readout, C.textSecondary, at: label, width: content.width - 24)
            }
        }
        y += band.height
    }

    // MARK: Badge, Separator, Label

    private func smallParts() {
        y += DS.Space.s24
        Draw.text("Badge", DS.Text.bodyStrong, C.textPrimary, at: CGPoint(x: left, y: y))
        Draw.text("every tone carries an icon and a label, so state never rides on colour alone", DS.Text.caption, C.textSecondary,
                  at: CGPoint(x: left + 44, y: y + 2))
        y += 28
        let badges: [(Badge.Tone, String, String)] = [(.neutral, "Kopyalandı", "doc.on.doc"), (.accent, "Seçili", "checkmark"),
                                                      (.danger, "Kısayol çakışıyor", "exclamationmark.octagon"),
                                                      (.warning, "Kaydırma yavaş", "exclamationmark.triangle"), (.success, "İzin verildi", "checkmark.circle")]
        var x = left
        for (tone, text, symbol) in badges {
            let badge = Badge(text: text, symbol: symbol, tone: tone)
            stamp(badge, at: CGPoint(x: x, y: y))
            Draw.text(".\(tone)", DS.Text.readout, C.textSecondary, at: CGPoint(x: x, y: y + DS.Size.controlSmall + 6), width: 160)
            x += max(badge.bounds.width, 72) + DS.Space.s24
        }
        y += DS.Size.controlSmall + 6 + 14

        y += DS.Space.s24
        Draw.text("Separator and Label", DS.Text.bodyStrong, C.textPrimary, at: CGPoint(x: left, y: y))
        y += 28
        let horizontal = Separator(axis: .horizontal)
        horizontal.frame.size.width = 160
        stamp(horizontal, at: CGPoint(x: left, y: y + 8))
        Draw.text(".horizontal", DS.Text.readout, C.textSecondary, at: CGPoint(x: left, y: y + 18), width: 160)
        let vertical = Separator(axis: .vertical)
        vertical.frame.size.height = 40
        stamp(vertical, at: CGPoint(x: left + 200, y: y))
        Draw.text(".vertical", DS.Text.readout, C.textSecondary, at: CGPoint(x: left + 212, y: y + 14), width: 160)
        var lx = left + 360
        for (text, style, color) in [("Scrolling capture", DS.Text.captionStrong, C.textPrimary), ("1,240 px", DS.Text.readoutLarge, C.textPrimary),
                                     ("Keep scrolling down", DS.Text.caption, C.textSecondary), ("Scroll slower", DS.Text.caption, C.warningText)] {
            let label = NSTextField.label(text, style: style, color: color)
            label.sizeToFit()
            stamp(label, at: CGPoint(x: lx, y: y + (40 - label.bounds.height) / 2))
            lx += label.bounds.width + DS.Space.s24
        }
        y += 40
    }
}
