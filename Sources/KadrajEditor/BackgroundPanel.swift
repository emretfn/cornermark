import AppKit
import KadrajCore
import UniformTypeIdentifiers

/// Gradient swatches drawn by `Renderer` itself, so a thumbnail is exactly what the background looks like.
enum BackgroundThumbnails {
    private static var cache: [Int: NSImage] = [:]
    private static let panel: (AssetStore, AssetID, CGSize) = {
        let store = AssetStore()
        let w = 46, h = 28
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 0.97, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(CGColor(gray: 0.82, alpha: 1))
        ctx.fill(CGRect(x: 0, y: h - 6, width: w, height: 6))
        let id = store.add(image: ctx.makeImage()!)!
        return (store, id, CGSize(width: w, height: h))
    }()

    static func image(index: Int) -> NSImage {
        if let hit = cache[index] { return hit }
        var doc = Document(base: panel.1, pixelSize: panel.2, pointScale: 1)
        var style = BackgroundSettings()
        style.fill = .builtin(index: index)
        style.padding = 15
        style.aspectRatio = 1.5
        style.cornerRadius = 4
        style.shadow = true
        doc.background = style
        let cg = Renderer.render(doc, assets: panel.0)
        let image = NSImage(cgImage: cg, size: NSSize(width: 52, height: 35))
        cache[index] = image
        return image
    }
}

/// NSView declares its own BackgroundStyle.
typealias BackgroundSettings = KadrajCore.BackgroundStyle

final class ThumbButton: NSButton {
    var isCurrent: () -> Bool = { false }

    init(image: NSImage, tip: String, id: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: 52, height: 35))
        self.image = image
        imageScaling = .scaleAxesIndependently
        isBordered = false
        title = ""
        toolTip = tip
        setAccessibilityIdentifier(id)
        setAccessibilityLabel(tip)
        widthAnchor.constraint(equalToConstant: 52).isActive = true
        heightAnchor.constraint(equalToConstant: 35).isActive = true
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if isCurrent() {
            NSColor.controlAccentColor.setStroke()
            let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5), xRadius: 4, yRadius: 4)
            ring.lineWidth = 3
            ring.stroke()
        } else {
            NSColor.separatorColor.setStroke()
            let edge = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
            edge.lineWidth = 1
            edge.stroke()
        }
    }
}

final class BackgroundPanel: NSView {
    static let width: CGFloat = 300
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
        content.spacing = 14
        content.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 16, right: 16)
        content.translatesAutoresizingMaskIntoConstraints = false

        let flipped = FlippedView()
        flipped.translatesAutoresizingMaskIntoConstraints = false
        flipped.addSubview(content)
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = flipped
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 1), scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor), scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            content.leadingAnchor.constraint(equalTo: flipped.leadingAnchor), content.trailingAnchor.constraint(equalTo: flipped.trailingAnchor),
            content.topAnchor.constraint(equalTo: flipped.topAnchor), content.bottomAnchor.constraint(equalTo: flipped.bottomAnchor),
            flipped.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])

        content.addArrangedSubview(section("Fill", fillGrid()))
        content.addArrangedSubview(section("Layout", layoutControls()))
        content.addArrangedSubview(section("Appearance", appearanceControls()))
        content.addArrangedSubview(section("Presets", presetsSection()))
        reload()
    }

    private func section(_ title: String, _ body: NSView) -> NSView {
        let header = NSTextField(labelWithString: title.uppercased())
        header.font = .systemFont(ofSize: 10, weight: .semibold)
        header.textColor = .secondaryLabelColor
        return UI.vstack([header, body], spacing: 8)
    }

    // MARK: Fill

    private func fillGrid() -> NSView {
        func tile(_ image: NSImage, tip: String, id: String, current: @escaping () -> Bool, action: @escaping () -> Void) -> ThumbButton {
            let b = ThumbButton(image: image, tip: tip, id: id)
            b.isCurrent = current
            b.onAction { _ in action() }
            tiles.append { b.needsDisplay = true }
            return b
        }

        let none = tile(noneImage(), tip: "No background", id: "bg.none", current: { [unowned self] in style == nil }) { [unowned self] in
            model.perform(.setBackground(nil))
        }

        let well = NSColorWell(style: .minimal)
        well.setAccessibilityIdentifier("bg.solid")
        well.toolTip = "Solid colour"
        well.widthAnchor.constraint(equalToConstant: 52).isActive = true
        well.heightAnchor.constraint(equalToConstant: 35).isActive = true
        well.color = .systemGray
        well.onAction { [unowned self] c in
            let color = RGBA((c as! NSColorWell).color)
            edit({ $0.fill = .solid(color) }, key: "solid")
        }
        tiles.append { [unowned self] in
            if case .solid(let c)? = style?.fill { well.color = c.nsColor }
        }

        let image = NSButton(title: "Image…", target: nil, action: nil)
        image.bezelStyle = .rounded
        image.controlSize = .small
        image.setAccessibilityIdentifier("bg.image")
        image.onAction { [unowned self] _ in chooseImage() }

        var rows: [NSView] = [UI.hstack([none, well, image], spacing: 8)]
        let all = BuiltinBackgrounds.all
        for start in stride(from: 0, to: all.count, by: 4) {
            let row = (start..<min(start + 4, all.count)).map { i in
                tile(BackgroundThumbnails.image(index: i), tip: all[i].name, id: "bg.fill.\(i)", current: { [unowned self] in
                    if case .builtin(let idx)? = style?.fill { return idx == i } else { return false }
                }) { [unowned self] in edit({ $0.fill = .builtin(index: i) }) }
            }
            rows.append(UI.hstack(row, spacing: 8))
        }
        return UI.vstack(rows, spacing: 8)
    }

    private func noneImage() -> NSImage {
        NSImage(size: NSSize(width: 52, height: 35), flipped: false) { rect in
            NSColor.controlBackgroundColor.setFill()
            rect.fill()
            NSColor.secondaryLabelColor.setStroke()
            let slash = NSBezierPath()
            slash.move(to: NSPoint(x: rect.minX + 12, y: rect.minY + 6)); slash.line(to: NSPoint(x: rect.maxX - 12, y: rect.maxY - 6))
            slash.lineWidth = 1.5
            slash.stroke()
            return true
        }
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

    // MARK: Layout and appearance

    private func sliderRow(_ label: String, range: ClosedRange<Double>, id: String, key: String,
                           get: @escaping (BackgroundSettings) -> Double, set: @escaping (inout BackgroundSettings, Double) -> Void) -> NSView {
        let s = UI.slider(range, width: 130, id: id)
        let value = UI.valueLabel()
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
        let name = UI.caption(label)
        name.widthAnchor.constraint(equalToConstant: 56).isActive = true
        return UI.hstack([name, s, value])
    }

    private static let aspects: [(String, Double?)] = [
        ("Auto", nil), ("1:1", 1), ("4:3", 4.0 / 3), ("3:2", 1.5), ("16:9", 16.0 / 9), ("16:10", 1.6), ("3:4", 0.75), ("9:16", 9.0 / 16),
    ]

    private func layoutControls() -> NSView {
        let padding = sliderRow("Padding", range: 0...300, id: "bg.padding", key: "padding", get: { $0.padding }, set: { $0.padding = $1 })

        let align = NSPopUpButton(frame: .zero, pullsDown: false)
        align.controlSize = .small
        align.setAccessibilityIdentifier("bg.alignment")
        for a in BackgroundAlignment.allCases { align.addItem(withTitle: a.rawValue.capitalized) }
        align.onAction { [unowned self] c in
            guard !updating else { return }
            let a = BackgroundAlignment.allCases[(c as! NSPopUpButton).indexOfSelectedItem]
            edit { $0.alignment = a }
        }
        refreshers.append { [unowned self] in
            align.selectItem(at: BackgroundAlignment.allCases.firstIndex(of: (style ?? BackgroundSettings()).alignment) ?? 0)
        }

        let aspect = NSPopUpButton(frame: .zero, pullsDown: false)
        aspect.controlSize = .small
        aspect.setAccessibilityIdentifier("bg.aspect")
        for (title, _) in Self.aspects { aspect.addItem(withTitle: title) }
        aspect.onAction { [unowned self] c in
            guard !updating else { return }
            let ratio = Self.aspects[(c as! NSPopUpButton).indexOfSelectedItem].1
            edit { $0.aspectRatio = ratio }
        }
        refreshers.append { [unowned self] in
            let ratio = (style ?? BackgroundSettings()).aspectRatio
            aspect.selectItem(at: Self.aspects.firstIndex { $0.1 == ratio } ?? 0)
        }

        func labelled(_ name: String, _ control: NSView) -> NSView {
            let l = UI.caption(name)
            l.widthAnchor.constraint(equalToConstant: 56).isActive = true
            return UI.hstack([l, control])
        }
        return UI.vstack([padding, labelled("Align", align), labelled("Ratio", aspect)], spacing: 8)
    }

    private func appearanceControls() -> NSView {
        let radius = sliderRow("Corners", range: 0...100, id: "bg.radius", key: "radius", get: { $0.cornerRadius }, set: { $0.cornerRadius = $1 })

        func check(_ title: String, id: String, get: @escaping (BackgroundSettings) -> Bool, set: @escaping (inout BackgroundSettings, Bool) -> Void) -> NSButton {
            let b = NSButton(checkboxWithTitle: title, target: nil, action: nil)
            b.controlSize = .small
            b.setAccessibilityIdentifier(id)
            b.onAction { [unowned self] c in
                guard !updating else { return }
                let on = (c as! NSButton).state == .on
                edit { set(&$0, on) }
            }
            refreshers.append { [unowned self] in b.state = get(style ?? BackgroundSettings()) ? .on : .off }
            return b
        }
        let shadow = check("Shadow", id: "bg.shadow", get: { $0.shadow }, set: { $0.shadow = $1 })
        let balance = check("Auto Balance", id: "bg.autoBalance", get: { $0.autoBalance }, set: { $0.autoBalance = $1 })
        return UI.vstack([radius, UI.hstack([shadow, balance], spacing: 14)], spacing: 8)
    }

    // MARK: Presets

    private func presetsSection() -> NSView {
        let field = NSTextField(string: "")
        field.placeholderString = "Preset name"
        field.controlSize = .small
        field.setAccessibilityIdentifier("bg.presetName")
        field.widthAnchor.constraint(equalToConstant: 150).isActive = true
        let save = NSButton(title: "Save", target: nil, action: nil)
        save.bezelStyle = .rounded
        save.controlSize = .small
        save.setAccessibilityIdentifier("bg.presetSave")
        let doSave: (NSControl) -> Void = { [unowned self] _ in
            model.saveBackgroundPreset(named: field.stringValue)
            field.stringValue = ""
        }
        save.onAction(doSave)
        field.onAction(doSave)

        presetList.orientation = .vertical
        presetList.alignment = .leading
        presetList.spacing = 4
        return UI.vstack([UI.hstack([field, save]), presetList], spacing: 8)
    }

    private func rebuildPresets() {
        presetList.arrangedSubviews.forEach { presetList.removeArrangedSubview($0); $0.removeFromSuperview() }
        for preset in model.prefs.backgroundPresets {
            let apply = NSButton(title: preset.name, target: nil, action: nil)
            apply.bezelStyle = .inline
            apply.controlSize = .small
            apply.setAccessibilityIdentifier("bg.preset.apply.\(preset.name)")
            apply.onAction { [unowned self] _ in model.applyBackgroundPreset(preset) }
            let delete = UI.button(symbol: "xmark", tip: "Delete preset", id: "bg.preset.delete.\(preset.name)")
            delete.onAction { [unowned self] _ in model.deleteBackgroundPreset(preset.id) }
            presetList.addArrangedSubview(UI.hstack([apply, delete]))
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
