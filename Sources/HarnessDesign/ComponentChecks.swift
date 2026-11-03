import AppKit
@testable import KadrajDesign

private final class Probe: NSObject {
    var count = 0
    @objc func fire() { count += 1 }
}

private func crossing(_ type: NSEvent.EventType) -> NSEvent {
    NSEvent.enterExitEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)!
}

private let appearances: [(String, NSAppearance.Name)] = [("aqua", .aqua), ("darkAqua", .darkAqua)]
private let white = RGBA(r: 1, g: 1, b: 1), black = RGBA(r: 0, g: 0, b: 0)

private func ratio(_ text: NSColor, on fill: NSColor, _ appearance: NSAppearance.Name, over backdrop: RGBA) -> Double {
    let bg = resolve(fill, appearance).over(backdrop)
    return contrastRatio(resolve(text, appearance).over(bg), bg)
}

/// The pixel of a view rendered through cacheDisplay, `x` and `y` in points from the top-left.
private func sample(_ view: NSView, _ appearance: NSAppearance.Name, x: CGFloat, y: CGFloat) -> RGBA {
    let rep = renderedImage(of: view, appearance: appearance)
    let scale = CGFloat(rep.pixelsWide) / view.bounds.width
    return pixel(rep, x: Int(x * scale), y: Int(y * scale))
}

private func close(_ a: RGBA, _ b: RGBA, tolerance: Double = 0.02) -> Bool {
    abs(a.r - b.r) < tolerance && abs(a.g - b.g) < tolerance && abs(a.b - b.b) < tolerance && abs(a.a - b.a) < tolerance
}

private func pinned(_ button: Pressable, _ state: InteractionState) -> Pressable {
    button.forcedState = state
    return button
}

func checkComponents() {
    section("Components: behaviour")
    behaviour()
    section("Components: icons are centred optically")
    checkIconCentring()
    checkInputTextCentring()
    section("Components: geometry")
    geometry()
    section("Components: contrast of text on fill, every variant and state except disabled")
    componentContrast()
    section("Components: rendered pixels follow the tables")
    renderedLook()
    section("Components: token discipline")
    tokenDiscipline()
}

private func behaviour() {
    let probe = Probe()
    let button = Button(title: "Capture", variant: .primary)
    button.target = probe
    button.action = #selector(Probe.fire)
    button.performClick(nil)
    check("Button performClick fires its action once", probe.count == 1, "count \(probe.count)")
    button.isEnabled = false
    button.performClick(nil)
    check("a disabled Button does not fire", probe.count == 1, "count \(probe.count)")

    let icon = IconButton(symbol: "timer", label: "Timer")
    icon.target = probe
    icon.action = #selector(Probe.fire)
    icon.performClick(nil)
    icon.isEnabled = false
    icon.performClick(nil)
    check("IconButton fires when enabled and not when disabled", probe.count == 2, "count \(probe.count)")
    check("Button and IconButton are NSButtons, so lookups typed as? NSButton keep working", (button as AnyObject) is NSButton && (icon as AnyObject) is NSButton)

    let b = Button(title: "Done", variant: .secondary)
    var trail: [InteractionState] = [b.interactionState]
    b.mouseEntered(with: crossing(.mouseEntered)); trail.append(b.interactionState)
    b.isHighlighted = true; trail.append(b.interactionState)
    b.isHighlighted = false; trail.append(b.interactionState)
    b.mouseExited(with: crossing(.mouseExited)); trail.append(b.interactionState)
    check("state walks normal, hover, pressed, hover, normal on enter, press, release, exit", trail == [.normal, .hover, .pressed, .hover, .normal], "\(trail)")
    b.mouseEntered(with: crossing(.mouseEntered))
    b.isEnabled = false
    check("disabling a hovered control wins over hover", b.interactionState == .disabled)
    b.isEnabled = true
    check("re-enabling does not resurrect a stale hover", b.interactionState == .normal, "\(b.interactionState)")
    b.forcedState = .pressed
    check("forcedState overrides real interaction", b.interactionState == .pressed)

    check("controls accept the first mouse and take keyboard focus", b.acceptsFirstMouse(for: nil) && !b.refusesFirstResponder && b.focusRingType == .exterior)

    icon.isEnabled = true
    check("IconButton exposes its label as accessibility label and tooltip", icon.accessibilityLabel() == "Timer" && icon.toolTip == "Timer")
    let before = icon.accessibilityValue() as? String
    icon.isSelected = true
    let after = icon.accessibilityValue() as? String
    check("IconButton selection is exposed as accessibility value, not colour alone", before != after && after == "Selected", "\(String(describing: before)) -> \(String(describing: after))")

    let host = NSView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
    let surface = Surface(style: .hud, shadowInset: DS.Space.s32)
    surface.frame = CGRect(x: 50, y: 50, width: 200, height: 120)
    host.addSubview(surface)
    let inner = NSView(frame: surface.contentRect)
    surface.addSubview(inner)
    check("Surface contentRect is its bounds minus the shadow inset", surface.contentRect == CGRect(x: 32, y: 32, width: 136, height: 56))
    check("Surface hitTest ignores the transparent margin", surface.hitTest(CGPoint(x: 60, y: 60)) == nil && surface.hitTest(CGPoint(x: 150, y: 110)) === inner)

    let label = NSTextField.label("Done", style: DS.Text.captionStrong, color: DS.Color.textSecondary)
    check("Label takes its font and colour role from the style", label.font == DS.Text.captionStrong.font && label.textColor == DS.Color.textSecondary && !label.isEditable)

    let input = TextInput(placeholder: "W", size: .regular, monospaced: true)
    check("monospaced TextInput uses the readout font", input.font == DS.Text.readout.font && input.alignment == .left)
    check("TextInput placeholder is textSecondary and its text textPrimary", input.textColor == DS.Color.textPrimary
        && (input.placeholderAttributedString?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor) == DS.Color.textSecondary)
    input.isEnabled = false
    check("disabled TextInput switches to textDisabled", input.textColor == DS.Color.textDisabled)
}

private func geometry() {
    for size in ComponentSize.allCases {
        let token = size == .small ? DS.Size.controlSmall : size == .regular ? DS.Size.control : DS.Size.controlLarge
        for variant in Button.Variant.allCases {
            check("Button .\(variant) .\(size) intrinsic height is \(Int(token))", Button(title: "Capture", variant: variant, size: size).intrinsicContentSize.height == token)
        }
        let square = IconButton(symbol: "timer", label: "Timer", size: size).intrinsicContentSize
        check("IconButton .\(size) is a \(Int(token)) square", square == NSSize(width: token, height: token))
        check("TextInput .\(size) height is \(Int(token))", TextInput(placeholder: "W", size: size).intrinsicContentSize.height == token)
    }
    check("Badge height is controlSmall", Badge(text: "Seçili", symbol: "checkmark", tone: .accent).intrinsicContentSize.height == DS.Size.controlSmall)

    func textWidth(_ s: String, _ style: TextStyle) -> CGFloat { ceil(NSAttributedString(string: s, attributes: style.attributes(color: DS.Color.textPrimary)).size().width) }
    let small = Button(title: "Done", size: .small).intrinsicContentSize.width
    check("small Button width is s12 padding plus the label", small == textWidth("Done", DS.Text.label) + 2 * DS.Space.s12, "\(small)")
    let regular = Button(title: "Done", size: .regular).intrinsicContentSize.width
    check("regular Button width is s16 padding plus the bodyStrong label", regular == textWidth("Done", DS.Text.bodyStrong) + 2 * DS.Space.s16, "\(regular)")
    let withIcon = Button(title: "Done", size: .regular, symbol: "camera").intrinsicContentSize.width
    check("an icon takes 2pt off the padding on its side", withIcon == regular - 2 + DS.Size.icon + DS.Space.s6, "\(withIcon) vs \(regular)")

    let h = Separator(axis: .horizontal).intrinsicContentSize, v = Separator(axis: .vertical).intrinsicContentSize
    check("Separator is 1pt thick on its cross axis", h.height == 1 && v.width == 1 && h.width == NSView.noIntrinsicMetric && v.height == NSView.noIntrinsicMetric)
}

private func componentContrast() {
    let nonDisabled = InteractionState.allCases.filter { $0 != .disabled }
    let surfaces: [(String, NSColor)] = [("bgWindow", DS.Color.bgWindow), ("bgSurface", DS.Color.bgSurface)]
    for (label, appearance) in appearances {
        for variant in Button.Variant.allCases {
            for state in nonDisabled {
                let look = variant.appearance(state)
                let fills = look.fill.map { [("fill", $0)] } ?? surfaces
                for (name, fill) in fills {
                    let r = ratio(look.text, on: fill, appearance, over: white)
                    check(String(format: "[%@] Button .%@ %@ text on %@ >= 4.5 : %.2f", label, "\(variant)", "\(state)", name, r), r >= 4.5)
                }
            }
        }
        for selected in [false, true] {
            for state in nonDisabled {
                let look = IconButton.look(tone: .plain, selected: selected, state)
                for (name, fill) in look.fill.map({ [("fill", $0)] }) ?? surfaces {
                    let r = ratio(look.text, on: fill, appearance, over: white)
                    check(String(format: "[%@] IconButton .plain%@ %@ on %@ >= 4.5 : %.2f", label, selected ? " selected" : "", "\(state)", name, r), r >= 4.5)
                }
            }
        }
        for tone in Badge.Tone.allCases {
            let look = tone.appearance
            let r = ratio(look.text, on: look.fill, appearance, over: white)
            check(String(format: "[%@] Badge .%@ text on fill >= 4.5 : %.2f", label, "\(tone)", r), r >= 4.5)
        }
        for (name, text) in [("textPrimary", DS.Color.textPrimary), ("placeholder textSecondary", DS.Color.textSecondary)] {
            let r = ratio(text, on: DS.Color.bgControl, appearance, over: white)
            check(String(format: "[%@] TextInput %@ on bgControl >= 4.5 : %.2f", label, name, r), r >= 4.5)
        }
    }
    // Overlay buttons are always dark and translucent, so they are measured over both ends of the range.
    for (backdropName, backdrop) in [("white", white), ("black", black)] {
        for selected in [false, true] {
            for state in nonDisabled {
                let look = IconButton.look(tone: .overlay, selected: selected, state)
                let r = ratio(look.text, on: look.fill ?? DS.Color.bgHud, .darkAqua, over: backdrop)
                check(String(format: "[darkAqua] IconButton .overlay%@ %@ over %@ >= 4.5 : %.2f", selected ? " selected" : "", "\(state)", backdropName, r), r >= 4.5)
            }
        }
    }
}

private func renderedLook() {
    for (label, appearance) in appearances {
        for variant in Button.Variant.allCases {
            for state in InteractionState.allCases {
                guard let fill = variant.appearance(state).fill else { continue }
                let button = pinned(Button(title: "Capture", variant: variant, size: .regular), state)
                let got = sample(button, appearance, x: 3, y: button.bounds.height / 2)
                let want = resolve(fill, appearance)
                check("[\(label)] Button .\(variant) \(state) paints its table fill \(want.hex)", close(got, want), "got \(got.hex) a \(got.a)")
            }
        }
        let overlay = pinned(IconButton(symbol: "timer", label: "Timer", tone: .overlay), .normal)
        let got = sample(overlay, appearance, x: 3, y: overlay.bounds.height / 2)
        check("[\(label)] overlay IconButton is dark whatever the host appearance", close(got, resolve(DS.Color.bgHud, .darkAqua), tolerance: 0.03), "got \(got.hex) a \(got.a)")
        let selected = IconButton(symbol: "timer", label: "Timer")
        selected.isSelected = true
        check("[\(label)] selected IconButton paints accentSubtle", close(sample(selected, appearance, x: 4, y: selected.bounds.height / 2), resolve(DS.Color.accentSubtle, appearance)))
    }

    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 200, height: 80), styleMask: [.borderless], backing: .buffered, defer: false)
    window.appearance = NSAppearance(named: .aqua)
    let primary = Button(title: "Capture", variant: .primary, size: .large)
    window.contentView!.addSubview(primary)
    check("the host window is not key", !window.isKeyWindow)
    let got = sample(primary, .aqua, x: 3, y: primary.bounds.height / 2)
    // A window backing store has its own colour space, which nudges saturated colours, so the accent is checked for staying yellow
    // and a neutral fill, which survives the conversion, is checked exactly.
    check("a primary Button in a non-key window keeps its accent fill", got.r > 0.9 && got.g > 0.85 && got.b < 0.4, "got \(got.hex)")
    let quiet = Button(title: "Capture", variant: .secondary, size: .large)
    window.contentView!.addSubview(quiet)
    check("a secondary Button in a non-key window keeps bgControl", close(sample(quiet, .aqua, x: 3, y: 18), resolve(DS.Color.bgControl, .aqua)),
          "got \(sample(quiet, .aqua, x: 3, y: 18).hex)")

    let reducedScale = DS.Motion.isReduced ? 1 : DS.Motion.pressScale
    let idle = Button(title: "Capture", variant: .secondary, size: .large)
    let pressed = pinned(Button(title: "Capture", variant: .secondary, size: .large), .pressed)
    let edge = { (b: NSView) in sample(b, .aqua, x: 1, y: b.bounds.height / 2) }
    check("pressed scales the control about its centre unless motion is reduced", reducedScale == 1 || edge(pressed).a < edge(idle).a || !close(edge(pressed), edge(idle)),
          "idle \(edge(idle).hex) a \(edge(idle).a), pressed \(edge(pressed).hex) a \(edge(pressed).a)")

    for (name, view) in [("Button", Button(title: "Capture", variant: .primary) as NSView), ("IconButton", IconButton(symbol: "timer", label: "Timer")),
                         ("TextInput", { let t = TextInput(placeholder: "W"); t.frame.size.width = 60; return t }())] {
        let size = view.bounds.size
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2), bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = size
        let ctx = NSGraphicsContext(bitmapImageRep: rep)!
        let saved = NSGraphicsContext.current
        NSGraphicsContext.current = ctx
        memset(rep.bitmapData!, 0, rep.bytesPerRow * rep.pixelsHigh)
        NSColor.black.setFill()
        view.drawFocusRingMask()
        ctx.flushGraphics()
        NSGraphicsContext.current = saved
        let centre = rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)!.alphaComponent
        let corner = rep.colorAt(x: 0, y: 0)!.alphaComponent
        check("\(name) focus ring mask is its rounded silhouette", centre > 0.99 && corner < 0.01, "centre \(centre), corner \(corner)")
    }

    print("NOT VERIFIED (headless): the system draws the keyboard focus ring itself only for a visible key window, so only the mask shape is checked")
}

private func tokenDiscipline() {
    let dir = "Sources/KadrajDesign/Components"
    guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir).filter({ $0.hasSuffix(".swift") }), !files.isEmpty else {
        check("component sources are readable from the package root", false, dir)
        return
    }
    let forbidden = [#"NSColor[.(]"#, #"\.withAlphaComponent"#, #"NSFont[.(]"#, #"systemFont"#, #"ofSize:"#, #"[rR]adius: *[0-9]"#, #"xRadius"#, #"\.(white|black|clear)\b"#]
    for file in files.sorted() {
        let text = (try? String(contentsOfFile: "\(dir)/\(file)", encoding: .utf8)) ?? ""
        let hits = forbidden.filter { text.range(of: $0, options: .regularExpression) != nil }
        check("\(file) uses tokens only, no raw colour, font size or radius", hits.isEmpty, hits.joined(separator: ", "))
    }
}

private func checkIconCentring() {
    let symbols = ["doc.on.doc", "square.and.arrow.down", "pencil.tip.crop.circle", "text.viewfinder", "pin", "xmark",
                   "rectangle.dashed", "macwindow", "display", "arrow.up.and.down.text.horizontal", "timer",
                   "rotate.right", "cursorarrow", "crop"]
    let scale = 4
    for symbol in symbols {
        let button = IconButton(symbol: symbol, label: symbol, size: .large)
        let w = Int(button.bounds.width) * scale, h = Int(button.bounds.height) * scale
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = button.bounds.size
        button.cacheDisplay(in: button.bounds, to: rep)
        var minX = w, maxX = -1, minY = h, maxY = -1
        var mass = 0.0, massX = 0.0, massY = 0.0
        for y in 0..<h {
            for x in 0..<w {
                let alpha = Double(rep.colorAt(x: x, y: y)?.alphaComponent ?? 0)
                mass += alpha; massX += alpha * (Double(x) + 0.5); massY += alpha * (Double(y) + 0.5)
                if alpha > 0.3 { minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y) }
            }
        }
        let dx = ((Double(minX + maxX + 1) / 2 + massX / mass) / 2 - Double(w) / 2) / Double(scale)
        let dy = ((Double(minY + maxY + 1) / 2 + massY / mass) / 2 - Double(h) / 2) / Double(scale)
        check(String(format: "%@ optical centre is off by dx %.2f dy %.2f, at most 0.25", symbol, dx, dy), maxX >= 0 && abs(dx) <= 0.25 && abs(dy) <= 0.25)
    }
}

private func checkInputTextCentring() {
    let field = TextInput(placeholder: "W", monospaced: true, centered: true)
    field.appearance = NSAppearance(named: .darkAqua)
    field.stringValue = "200"
    field.frame = CGRect(x: 0, y: 0, width: 48, height: DS.Size.control)
    let scale = 4, w = 48 * scale, h = Int(DS.Size.control) * scale
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = field.bounds.size
    field.cacheDisplay(in: field.bounds, to: rep)
    var minY = h, maxY = -1
    for y in 0..<h {
        for x in 0..<w where (rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)?.brightnessComponent ?? 0) > 0.6 {
            minY = min(minY, y); maxY = max(maxY, y)
        }
    }
    let dy = (Double(minY + maxY + 1) / 2 - Double(h) / 2) / Double(scale)
    check(String(format: "TextInput digits are off centre by dy %.2f, at most 0.5", dy), maxY >= 0 && abs(dy) <= 0.5)
}
