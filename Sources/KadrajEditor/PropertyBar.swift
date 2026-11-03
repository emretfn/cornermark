import AppKit
import KadrajDesign
import KadrajCore

/// The contextual bar under the toolbar. Its controls come from `ToolSpec.properties`, so a new
/// tool shows the right controls without the bar knowing about it.
final class PropertyBar: BarView {
    let model: EditorModel
    var setAspect: (CropAspect) -> Void = { _ in }
    var applyCrop: () -> Void = {}
    var cancelCrop: () -> Void = {}

    private let stack = NSStackView()
    private lazy var stackFill = stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -DS.Space.s16)
    private var refreshers: [() -> Void] = []
    private var signature: [AnyHashable] = []
    private var sampler: NSColorSampler?
    private var namePopover: NSPopover?

    init(model: EditorModel) {
        self.model = model
        super.init(frame: .zero)
        edge = .bottom
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = DS.Space.s12
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: DS.Space.s16),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -DS.Space.s16),
            heightAnchor.constraint(equalToConstant: DS.Size.control + DS.Space.s12),
        ])
        reload()
    }

    required init?(coder: NSCoder) { fatalError() }

    private var currentProperties: [PropertyKind] { model.styleTool.spec.properties }

    func reload() {
        let sig: [AnyHashable] = [model.tool, model.styleTool, model.selection != nil,
                                  model.prefs.favoriteColors.count, model.stylePresetsForTool.map(\.id),
                                  model.cropDraft?.aspect]
        if sig == signature {
            refreshers.forEach { $0() }
            return
        }
        signature = sig
        rebuild()
    }

    private func rebuild() {
        refreshers = []
        stackFill.isActive = false
        stack.arrangedSubviews.forEach { stack.removeArrangedSubview($0); $0.removeFromSuperview() }

        if model.tool == .crop {
            buildCropControls()
            return
        }
        if model.tool == .background {
            stack.addArrangedSubview(UI.caption("Pick a background, padding and corner radius in the panel on the right."))
            return
        }
        let props = currentProperties
        guard !props.isEmpty else {
            let hint = model.tool == .select
                ? "Click to select. Drag to move, drag a handle to resize, double-click text to edit, Delete removes."
                : model.tool.spec.hint
            stack.addArrangedSubview(UI.caption(hint))
            return
        }
        for (i, p) in props.enumerated() {
            if i > 0 { stack.addArrangedSubview(divider()) }
            stack.addArrangedSubview(control(for: p))
        }
        stack.addArrangedSubview(divider())
        stack.addArrangedSubview(presetsMenu())
    }

    private func divider() -> NSView {
        let line = Separator(axis: .vertical)
        line.heightAnchor.constraint(equalToConstant: DS.Space.s16).isActive = true
        return line
    }

    private func control(for p: PropertyKind) -> NSView {
        switch p {
        case .color: return colorControls()
        case .width: return slider(label: model.styleTool == .counter ? "Size" : "Width", range: 1...(60 * widthScale), id: "prop.width",
                                   get: { $0.width }, set: { s, v in s.width = v.rounded() }, key: "width")
        case .fontSize: return slider(label: "Size", range: 8...(160 * widthScale), id: "prop.fontSize",
                                      get: { $0.fontSize }, set: { s, v in s.fontSize = v.rounded() }, key: "fontSize")
        case .pixelBlock: return slider(label: "Block", range: 3...(64 * widthScale), id: "prop.pixelBlock",
                                        get: { Double($0.pixelBlock) }, set: { s, v in s.pixelBlock = Int(v.rounded()) }, key: "pixelBlock")
        case .arrowStyle: return arrowStyleControl()
        case .textStyle: return textStyleControl()
        case .blurMode: return blurModeControl()
        }
    }

    private var widthScale: Double {
        max(1, Double(max(model.document.pixelSize.width, model.document.pixelSize.height) / 1400).rounded())
    }

    // MARK: Colour

    private func colorControls() -> NSView {
        var chips: [NSView] = []
        for color in Palette.swatches { chips.append(chip(color)) }

        let well = NSColorWell(style: .minimal)
        well.widthAnchor.constraint(equalToConstant: 30).isActive = true
        well.heightAnchor.constraint(equalToConstant: DS.Size.controlSmall).isActive = true
        well.toolTip = "Custom colour"
        well.setAccessibilityIdentifier("prop.colorWell")
        well.onAction { [unowned self] w in
            let color = RGBA((w as! NSColorWell).color)
            model.editStyle({ $0.color = color }, key: "color")
        }
        refreshers.append { [unowned self] in well.color = model.activeStyle.color.nsColor }
        refreshers.last?()
        chips.append(well)

        let eyedropper = UI.button(symbol: "eyedropper", tip: "Pick a colour from the screen", id: "prop.eyedropper")
        eyedropper.onAction { [unowned self] sender in
            let sampler = NSColorSampler()
            self.sampler = sampler
            sampler.show { picked in
                guard let picked else { return }
                self.model.editStyle({ $0.color = RGBA(picked) }, key: "color")
            }
        }
        chips.append(eyedropper)

        let star = UI.button(symbol: "star", tip: "Save this colour to your palette", id: "prop.favorite")
        star.onAction { [unowned self] _ in model.addFavoriteColor(model.activeStyle.color) }
        chips.append(star)

        for fav in model.prefs.favoriteColors { chips.append(chip(fav, favorite: true)) }
        let row = UI.hstack(chips, spacing: DS.Space.s2)
        row.setAccessibilityIdentifier("prop.colors")
        return row
    }

    private func chip(_ color: RGBA, favorite: Bool = false) -> NSView {
        let b = SwatchButton(color: color)
        b.isCurrent = { [unowned self] in model.activeStyle.color.isClose(to: color) }
        b.onAction { [unowned self] _ in model.editStyle({ $0.color = color }, key: "color"); model.endCoalescing() }
        b.setAccessibilityIdentifier(favorite ? "prop.favoriteChip" : "prop.chip")
        if favorite {
            let menu = NSMenu()
            menu.addItem(NSMenuItem(title: "Remove from palette") { [unowned self] in model.removeFavoriteColor(color) })
            b.menu = menu
        }
        refreshers.append { b.needsDisplay = true }
        return b
    }

    // MARK: Sliders and pickers

    private func slider(label: String, range: ClosedRange<Double>, id: String, get: @escaping (ToolStyle) -> Double,
                        set: @escaping (inout ToolStyle, Double) -> Void, key: String) -> NSView {
        let s = UI.slider(range, id: id)
        let value = UI.valueLabel()
        s.onAction { [unowned self] c in
            let v = (c as! NSSlider).doubleValue
            model.editStyle({ set(&$0, v) }, key: key)
            value.stringValue = "\(Int(v.rounded()))"
        }
        s.onTrackingEnd = { [unowned self] in model.endCoalescing() }
        refreshers.append { [unowned self] in
            let v = get(model.activeStyle)
            s.doubleValue = v
            value.stringValue = "\(Int(v.rounded()))"
        }
        refreshers.last?()
        return UI.hstack([UI.caption(label), s, value], spacing: DS.Space.s8)
    }

    private func segmented<T: Equatable>(_ items: [(String, T)], id: String, get: @escaping (ToolStyle) -> T,
                                         set: @escaping (inout ToolStyle, T) -> Void, key: String) -> NSView {
        let seg = Segments(labels: items.map(\.0), trackingMode: .selectOne, size: .small)
        seg.setAccessibilityIdentifier(id)
        seg.onAction { [unowned self] c in
            let i = (c as! NSSegmentedControl).selectedSegment
            model.editStyle({ set(&$0, items[i].1) }, key: key)
            model.endCoalescing()
        }
        refreshers.append { [unowned self] in
            let cur = get(model.activeStyle)
            seg.selectedSegment = items.firstIndex { $0.1 == cur } ?? -1
        }
        refreshers.last?()
        return seg
    }

    private func arrowStyleControl() -> NSView {
        UI.hstack([UI.caption("Style"), segmented(ArrowStyle.allCases.map { ($0.rawValue.capitalized, $0) }, id: "prop.arrowStyle",
                                                  get: { $0.arrowStyle }, set: { $0.arrowStyle = $1 }, key: "arrowStyle")], spacing: DS.Space.s8)
    }

    private func blurModeControl() -> NSView {
        UI.hstack([UI.caption("Mode"), segmented(BlurMode.allCases.map { ($0.rawValue.capitalized, $0) }, id: "prop.blurMode",
                                                 get: { $0.blurMode }, set: { $0.blurMode = $1 }, key: "blurMode")], spacing: DS.Space.s8)
    }

    private func textStyleControl() -> NSView {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.controlSize = .small
        popup.setAccessibilityIdentifier("prop.textStyle")
        for style in TextStylePreset.allCases { popup.addItem(withTitle: style.rawValue.capitalized) }
        popup.onAction { [unowned self] c in
            let i = (c as! NSPopUpButton).indexOfSelectedItem
            model.editStyle({ $0.textStyle = TextStylePreset.allCases[i] }, key: "textStyle")
            model.endCoalescing()
        }
        refreshers.append { [unowned self] in
            popup.selectItem(at: TextStylePreset.allCases.firstIndex(of: model.activeStyle.textStyle) ?? 0)
        }
        refreshers.last?()
        return UI.hstack([UI.caption("Look"), popup], spacing: DS.Space.s8)
    }

    // MARK: Presets

    private func presetsMenu() -> NSView {
        let popup = NSPopUpButton(frame: .zero, pullsDown: true)
        popup.controlSize = .small
        popup.setAccessibilityIdentifier("prop.presets")
        popup.addItem(withTitle: "Presets")
        let presets = model.stylePresetsForTool
        for preset in presets {
            popup.menu?.addItem(NSMenuItem(title: preset.name) { [unowned self] in model.applyStylePreset(preset) })
        }
        popup.menu?.addItem(.separator())
        popup.menu?.addItem(NSMenuItem(title: "Save Current Style…") { [unowned self] in promptForPresetName(from: popup) })
        if !presets.isEmpty {
            let deleteMenu = NSMenu()
            for preset in presets {
                deleteMenu.addItem(NSMenuItem(title: preset.name) { [unowned self] in model.deleteStylePreset(preset.id) })
            }
            let parent = NSMenuItem(title: "Delete Preset", action: nil, keyEquivalent: "")
            parent.submenu = deleteMenu
            popup.menu?.addItem(parent)
        }
        return popup
    }

    private func promptForPresetName(from anchor: NSView) {
        let field = TextInput(placeholder: "Preset name", size: .small)
        field.setAccessibilityIdentifier("prop.presetName")
        field.widthAnchor.constraint(equalToConstant: 150).isActive = true
        let popover = NSPopover()
        popover.behavior = .transient
        let save = Button(title: "Save", variant: .secondary, size: .small)
        save.keyEquivalent = "\r"
        let onSave: (NSControl) -> Void = { [unowned self] _ in
            model.saveStylePreset(named: field.stringValue)
            popover.close()
        }
        save.onAction(onSave)
        field.onAction(onSave)
        let row = UI.hstack([field, save], spacing: DS.Space.s8)
        row.edgeInsets = NSEdgeInsets(top: DS.Space.s12, left: DS.Space.s12, bottom: DS.Space.s12, right: DS.Space.s12)
        let vc = NSViewController()
        vc.view = row
        popover.contentViewController = vc
        namePopover = popover
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
    }

    // MARK: Crop

    private func buildCropControls() {
        let aspects = CropAspect.allCases
        let aspect = Segments(labels: aspects.map(\.title), trackingMode: .selectOne, size: .small, tilePadding: DS.Space.s8)
        aspect.setAccessibilityIdentifier("crop.aspect")
        aspect.onAction { [unowned self] c in setAspect(aspects[(c as! NSSegmentedControl).selectedSegment]) }
        refreshers.append { [unowned self] in
            aspect.selectedSegment = aspects.firstIndex(of: model.cropDraft?.aspect ?? .free) ?? 0
        }
        refreshers.last?()

        let reset = Button(title: "Reset", variant: .ghost, size: .small)
        reset.setAccessibilityIdentifier("crop.reset")
        reset.onAction { [unowned self] _ in
            model.setCropDraft(CropDraft(rect: model.document.sourceBounds, aspect: model.cropDraft?.aspect ?? .free))
        }
        let cancel = Button(title: "Cancel", variant: .ghost, size: .small)
        cancel.setAccessibilityIdentifier("crop.cancel")
        cancel.onAction { [unowned self] _ in cancelCrop() }
        let apply = Button(title: "Apply", variant: .primary, size: .small)
        apply.setAccessibilityIdentifier("crop.apply")
        apply.onAction { [unowned self] _ in applyCrop() }

        let spacer = NSView()
        spacer.setContentHuggingPriority(.fittingSizeCompression, for: .horizontal)
        let hint = UI.caption("Return applies, Esc cancels")

        for v: NSView in [aspect, spacer, hint, reset, cancel, apply] { stack.addArrangedSubview(v) }
        stack.setCustomSpacing(DS.Space.s16, after: hint)
        stack.setCustomSpacing(DS.Space.s4, after: reset)
        stack.setCustomSpacing(DS.Space.s8, after: cancel)
        // The spacer only takes up slack when the stack spans the bar.
        stackFill.isActive = true
    }
}
