import AppKit
import CornermarkDesign
import CornermarkCore
import UniformTypeIdentifiers

/// Gradient swatches drawn by `Renderer` itself, so a thumbnail is exactly what the background looks like.
/// The picture is a transparent 2x2 inside padding, so only the fill shows.
enum BackgroundThumbnails {
    private static var cache: [Int: NSImage] = [:]
    private static let clear: (AssetStore, AssetID) = {
        let store = AssetStore()
        let ctx = CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return (store, store.add(image: ctx.makeImage()!)!)
    }()

    static func image(index: Int) -> NSImage {
        if let hit = cache[index] { return hit }
        // The canvas is 2 + 2 * padding wide: exactly twice the tile, so the swatch is sharp on a 2x display.
        let pixels = TileChrome.side * 2
        var doc = Document(base: clear.1, pixelSize: CGSize(width: 2, height: 2), pointScale: 1)
        var style = BackgroundSettings()
        style.fill = .builtin(index: index)
        style.padding = (pixels - 2) / 2
        style.aspectRatio = 1
        style.cornerRadius = 0
        style.shadow = false
        doc.background = style
        let image = NSImage(cgImage: Renderer.render(doc, assets: clear.0), size: NSSize(width: TileChrome.side, height: TileChrome.side))
        cache[index] = image
        return image
    }
}

/// NSView declares its own BackgroundStyle.
typealias BackgroundSettings = CornermarkCore.BackgroundStyle

/// The square the fill grid is made of. The picture is inset when the tile is current, so the accent ring sits outside it
/// with a gap and the two corner radii stay concentric.
enum TileChrome {
    static let side: CGFloat = 44
    private static let ring: CGFloat = 2
    private static let gap: CGFloat = 1

    static func draw(in bounds: CGRect, current: Bool, hovering: Bool, content: (CGRect) -> Void) {
        let inset = current ? ring + gap : 0
        let rect = bounds.insetBy(dx: inset, dy: inset)
        let picture: NSBezierPath = .continuous(rect, radius: DS.Radius.md - inset)

        NSGraphicsContext.saveGraphicsState()
        picture.addClip()
        content(rect)
        DS.Color.imageOutline.setStroke()
        picture.lineWidth = 2
        picture.stroke()
        NSGraphicsContext.restoreGraphicsState()

        if current {
            DS.Color.accentMark.setStroke()
            let outline: NSBezierPath = .continuous(bounds.insetBy(dx: ring / 2, dy: ring / 2), radius: DS.Radius.md - ring / 2)
            outline.lineWidth = ring
            outline.stroke()
        } else if hovering {
            let outline: NSBezierPath = .continuous(bounds, radius: DS.Radius.md)
            NSGraphicsContext.saveGraphicsState()
            outline.addClip()
            DS.Color.borderStrong.setStroke()
            outline.lineWidth = 2
            outline.stroke()
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    static func trackHover(_ view: NSView) {
        view.addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: view))
    }

    static func fix(_ view: NSView) {
        view.widthAnchor.constraint(equalToConstant: side).isActive = true
        view.heightAnchor.constraint(equalToConstant: side).isActive = true
    }
}

final class ThumbButton: NSButton {
    var isCurrent: () -> Bool = { false }
    private let paint: (CGRect) -> Void
    private var hovering = false { didSet { if oldValue != hovering { needsDisplay = true } } }

    init(tip: String, id: String, paint: @escaping (CGRect) -> Void) {
        self.paint = paint
        super.init(frame: NSRect(x: 0, y: 0, width: TileChrome.side, height: TileChrome.side))
        isBordered = false
        title = ""
        toolTip = tip
        setAccessibilityIdentifier(id)
        setAccessibilityLabel(tip)
        TileChrome.fix(self)
        TileChrome.trackHover(self)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func draw(_ dirtyRect: NSRect) {
        TileChrome.draw(in: bounds, current: isCurrent(), hovering: hovering, content: paint)
    }

    override func drawFocusRingMask() { NSBezierPath.continuous(bounds, radius: DS.Radius.md).fill() }
    override var focusRingMaskBounds: NSRect { bounds }
}

final class BackgroundPanel: NSView {
    static let width: CGFloat = 284
    /// Every control ends on this one right edge: the panel width less the s16 inset on each side.
    private static let inner = width - 2 * DS.Space.s16
    private static let labelColumn: CGFloat = 64
    private static let controlWidth = inner - labelColumn
    private static let readoutWidth: CGFloat = 28
    private static let columns = 5

    let model: EditorModel

    private let content = NSStackView()
    private var tiles: [() -> Void] = []
    private var refreshers: [() -> Void] = []
    private let presetList = NSStackView()
    private var presetSignature: [UUID] = []
    private var updating = false

    init(model: EditorModel) {
        self.model = model
        super.init(frame: .zero)
        build()
    }

    required init?(coder: NSCoder) { fatalError() }

    private var style: BackgroundSettings? { model.document.background }

    func edit(_ change: (inout BackgroundSettings) -> Void, key: String? = nil) {
        var s = style ?? BackgroundSettings()
        change(&s)
        model.perform(.setBackground(s), coalescing: key.map { CoalescingKey("bg.\($0)") })
    }

    private func build() {
        let bar = BarView()
        bar.edge = .left
        bar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bar)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: leadingAnchor), bar.trailingAnchor.constraint(equalTo: trailingAnchor),
            bar.topAnchor.constraint(equalTo: topAnchor), bar.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 0
        content.translatesAutoresizingMaskIntoConstraints = false

        let flipped = FlippedView()
        flipped.translatesAutoresizingMaskIntoConstraints = false
        flipped.addSubview(content)
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        // A legacy scroller would take width from the grid and move every right edge.
        scroll.scrollerStyle = .overlay
        scroll.documentView = flipped
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor), scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor), scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            content.leadingAnchor.constraint(equalTo: flipped.leadingAnchor), content.trailingAnchor.constraint(equalTo: flipped.trailingAnchor),
            content.topAnchor.constraint(equalTo: flipped.topAnchor), content.bottomAnchor.constraint(equalTo: flipped.bottomAnchor),
            flipped.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])

        let sections: [NSView] = [section("Background", fillGrid()), section("Frame", frameControls()), section("Presets", presetsSection())]
        for (i, view) in sections.enumerated() {
            if i > 0 {
                let line = Separator(axis: .horizontal)
                line.widthAnchor.constraint(equalToConstant: Self.width).isActive = true
                content.addArrangedSubview(line)
            }
            content.addArrangedSubview(view)
        }
        reload()
    }

    private func section(_ title: String, _ body: NSView) -> NSView {
        let header = NSTextField.label(title, style: DS.Text.label, color: DS.Color.textPrimary)
        let stack = UI.vstack([header, body], spacing: DS.Space.s12)
        stack.edgeInsets = NSEdgeInsets(top: DS.Space.s16, left: DS.Space.s16, bottom: DS.Space.s16, right: DS.Space.s16)
        stack.widthAnchor.constraint(equalToConstant: Self.width).isActive = true
        return stack
    }

    // MARK: Fill

    private func fillGrid() -> NSView {
        func tile(tip: String, id: String, current: @escaping () -> Bool, paint: @escaping (CGRect) -> Void, action: @escaping () -> Void) -> ThumbButton {
            let b = ThumbButton(tip: tip, id: id, paint: paint)
            b.isCurrent = current
            b.onAction { _ in action() }
            tiles.append { b.needsDisplay = true }
            return b
        }

        let none = tile(tip: "No background", id: "bg.none", current: { [unowned self] in style == nil }, paint: { rect in
            DS.Color.bgControl.setFill()
            rect.fill()
            DS.Color.textSecondary.setStroke()
            let slash = NSBezierPath()
            slash.move(to: NSPoint(x: rect.minX + 10, y: rect.minY + 10)); slash.line(to: NSPoint(x: rect.maxX - 10, y: rect.maxY - 10))
            slash.lineWidth = 1.5
            slash.lineCapStyle = .round
            slash.stroke()
        }) { [unowned self] in model.perform(.setBackground(nil)) }

        let well = SolidWell(shape: .tile)
        well.setAccessibilityIdentifier("bg.solid")
        well.setAccessibilityLabel("Solid colour")
        well.toolTip = "Solid colour"
        TileChrome.fix(well)
        well.color = .systemGray
        well.isCurrent = { [unowned self] in if case .solid? = style?.fill { return true } else { return false } }
        well.onAction { [unowned self] c in
            let color = RGBA((c as! NSColorWell).color)
            edit({ $0.fill = .solid(color) }, key: "solid")
        }
        tiles.append { [unowned self] in
            if case .solid(let c)? = style?.fill { well.color = c.nsColor }
            well.redrawTile()
        }

        let image = tile(tip: "Image…", id: "bg.image", current: { [unowned self] in
            if case .image? = style?.fill { return true } else { return false }
        }, paint: { rect in
            DS.Color.bgControl.setFill()
            rect.fill()
            Glyph.draw("photo", in: rect, pointSize: DS.Size.icon, DS.Color.textSecondary)
        }) { [unowned self] in chooseImage() }

        var all: [NSView] = [none, well, image]
        let builtins = BuiltinBackgrounds.all
        for i in builtins.indices {
            all.append(tile(tip: builtins[i].name, id: "bg.fill.\(i)", current: { [unowned self] in
                if case .builtin(let idx)? = style?.fill { return idx == i } else { return false }
            }, paint: { rect in BackgroundThumbnails.image(index: i).draw(in: rect) }) { [unowned self] in edit({ $0.fill = .builtin(index: i) }) })
        }

        let rows = stride(from: 0, to: all.count, by: Self.columns).map { start in
            UI.hstack(Array(all[start..<min(start + Self.columns, all.count)]), spacing: DS.Space.s8)
        }
        return UI.vstack(rows, spacing: DS.Space.s8)
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        useBackgroundImage(at: url)
    }

    func useBackgroundImage(at url: URL) {
        guard let data = try? Data(contentsOf: url), let id = model.assets.add(encoded: data) else { return }
        edit { $0.fill = .image(asset: id) }
    }

    // MARK: Frame

    private func labelColumn(_ text: String) -> NSTextField {
        let name = UI.caption(text)
        name.widthAnchor.constraint(equalToConstant: Self.labelColumn).isActive = true
        return name
    }

    /// A label column and a control that runs to the right edge, one control tall.
    private func row(_ label: String, _ control: NSView) -> NSView {
        let r = UI.hstack([labelColumn(label), control], spacing: 0)
        r.heightAnchor.constraint(equalToConstant: DS.Size.control).isActive = true
        return r
    }

    private func sliderRow(_ label: String, range: ClosedRange<Double>, id: String, key: String,
                           get: @escaping (BackgroundSettings) -> Double, set: @escaping (inout BackgroundSettings, Double) -> Void) -> NSView {
        let s = UI.slider(range, width: nil, id: id)
        s.widthAnchor.constraint(equalToConstant: Self.controlWidth - DS.Space.s8 - Self.readoutWidth).isActive = true
        let value = UI.valueLabel(width: Self.readoutWidth)
        s.onAction { [unowned self] c in
            guard !updating else { return }
            let v = (c as! NSSlider).doubleValue
            edit({ set(&$0, v.rounded()) }, key: key)
            value.stringValue = "\(Int(v.rounded()))"
        }
        s.onTrackingEnd = { [unowned self] in model.endCoalescing() }
        refreshers.append { [unowned self] in
            let v = get(style ?? BackgroundSettings())
            s.doubleValue = v
            value.stringValue = "\(Int(v.rounded()))"
        }
        return row(label, UI.hstack([s, value], spacing: DS.Space.s8))
    }

    private static let aspects: [(String, Double?)] = [
        ("Auto", nil), ("1:1", 1), ("4:3", 4.0 / 3), ("3:2", 1.5), ("16:9", 16.0 / 9), ("16:10", 1.6), ("3:4", 0.75), ("9:16", 9.0 / 16),
    ]

    private func popup(id: String, titles: [String]) -> NSPopUpButton {
        let p = NSPopUpButton(frame: .zero, pullsDown: false)
        p.controlSize = .small
        p.font = DS.Text.label.font
        p.setAccessibilityIdentifier(id)
        for title in titles { p.addItem(withTitle: title) }
        p.widthAnchor.constraint(equalToConstant: Self.controlWidth).isActive = true
        return p
    }

    private func checkRow(_ label: String, id: String, get: @escaping (BackgroundSettings) -> Bool,
                          set: @escaping (inout BackgroundSettings, Bool) -> Void) -> NSView {
        let box = Checkbox(title: "", size: .small)
        box.setAccessibilityIdentifier(id)
        box.setAccessibilityLabel(label)
        box.onAction { [unowned self] c in
            guard !updating else { return }
            let on = (c as! NSButton).state == .on
            edit { set(&$0, on) }
        }
        refreshers.append { [unowned self] in box.state = get(style ?? BackgroundSettings()) ? .on : .off }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.fittingSizeCompression, for: .horizontal)
        let r = UI.hstack([UI.caption(label), spacer, box], spacing: 0)
        r.widthAnchor.constraint(equalToConstant: Self.inner).isActive = true
        r.heightAnchor.constraint(equalToConstant: DS.Size.control).isActive = true
        return r
    }

    private func frameControls() -> NSView {
        let padding = sliderRow("Padding", range: 0...300, id: "bg.padding", key: "padding", get: { $0.padding }, set: { $0.padding = $1 })
        let corners = sliderRow("Corners", range: 0...100, id: "bg.radius", key: "radius", get: { $0.cornerRadius }, set: { $0.cornerRadius = $1 })

        let aspect = popup(id: "bg.aspect", titles: Self.aspects.map(\.0))
        aspect.onAction { [unowned self] c in
            guard !updating else { return }
            let ratio = Self.aspects[(c as! NSPopUpButton).indexOfSelectedItem].1
            edit { $0.aspectRatio = ratio }
        }
        refreshers.append { [unowned self] in
            let ratio = (style ?? BackgroundSettings()).aspectRatio
            aspect.selectItem(at: Self.aspects.firstIndex { $0.1 == ratio } ?? 0)
        }

        let align = popup(id: "bg.alignment", titles: BackgroundAlignment.allCases.map { $0.rawValue.capitalized })
        align.onAction { [unowned self] c in
            guard !updating else { return }
            let a = BackgroundAlignment.allCases[(c as! NSPopUpButton).indexOfSelectedItem]
            edit { $0.alignment = a }
        }
        refreshers.append { [unowned self] in
            align.selectItem(at: BackgroundAlignment.allCases.firstIndex(of: (style ?? BackgroundSettings()).alignment) ?? 0)
        }

        let shadow = checkRow("Shadow", id: "bg.shadow", get: { $0.shadow }, set: { $0.shadow = $1 })
        let balance = checkRow("Auto Balance", id: "bg.autoBalance", get: { $0.autoBalance }, set: { $0.autoBalance = $1 })
        return UI.vstack([padding, corners, row("Ratio", aspect), row("Align", align), shadow, balance], spacing: DS.Space.s4)
    }

    // MARK: Presets

    private func presetsSection() -> NSView {
        let field = TextInput(placeholder: "Preset name", size: .small)
        field.setAccessibilityIdentifier("bg.presetName")
        let save = Button(title: "Save", variant: .secondary, size: .small)
        save.setAccessibilityIdentifier("bg.presetSave")
        field.widthAnchor.constraint(equalToConstant: Self.inner - DS.Space.s8 - save.intrinsicContentSize.width).isActive = true
        let doSave: (NSControl) -> Void = { [unowned self] _ in
            model.saveBackgroundPreset(named: field.stringValue)
            field.stringValue = ""
        }
        save.onAction(doSave)
        field.onAction(doSave)

        presetList.orientation = .vertical
        presetList.alignment = .leading
        presetList.spacing = DS.Space.s4
        return UI.vstack([UI.hstack([field, save], spacing: DS.Space.s8), presetList], spacing: DS.Space.s8)
    }

    private func rebuildPresets() {
        presetList.arrangedSubviews.forEach { presetList.removeArrangedSubview($0); $0.removeFromSuperview() }
        for preset in model.prefs.backgroundPresets {
            let apply = Button(title: preset.name, variant: .ghost, size: .small)
            apply.setAccessibilityIdentifier("bg.preset.apply.\(preset.name)")
            apply.onAction { [unowned self] _ in model.applyBackgroundPreset(preset) }
            let delete = UI.button(symbol: "xmark", tip: "Delete preset", id: "bg.preset.delete.\(preset.name)")
            delete.onAction { [unowned self] _ in model.deleteBackgroundPreset(preset.id) }

            let spacer = NSView()
            spacer.setContentHuggingPriority(.fittingSizeCompression, for: .horizontal)
            let line = UI.hstack([apply, spacer, delete], spacing: 0)
            line.widthAnchor.constraint(equalToConstant: Self.inner).isActive = true
            presetList.addArrangedSubview(line)
        }
        if presetList.arrangedSubviews.isEmpty {
            presetList.addArrangedSubview(UI.caption("No presets yet"))
        }
    }

    func reload() {
        updating = true
        defer { updating = false }
        let ids = model.prefs.backgroundPresets.map(\.id)
        if ids != presetSignature {
            presetSignature = ids
            rebuildPresets()
        }
        refreshers.forEach { $0() }
        tiles.forEach { $0() }
    }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
