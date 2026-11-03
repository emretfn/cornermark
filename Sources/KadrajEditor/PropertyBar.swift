import AppKit
import KadrajCore

/// The contextual bar under the toolbar. Its controls come from `ToolSpec.properties`, so a new
/// tool shows the right controls without the bar knowing about it.
final class PropertyBar: BarView {
    let model: EditorModel
    var setAspect: (CropAspect) -> Void = { _ in }
    var applyCrop: () -> Void = {}
    var cancelCrop: () -> Void = {}

    private let stack = NSStackView()
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
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14),
            heightAnchor.constraint(equalToConstant: 44),
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
        let box = NSBox()
        box.boxType = .separator
        box.heightAnchor.constraint(equalToConstant: 20).isActive = true
        box.widthAnchor.constraint(equalToConstant: 1).isActive = true
        return box
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
        well.heightAnchor.constraint(equalToConstant: 22).isActive = true
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
        let row = UI.hstack(chips, spacing: 3)
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
        return UI.hstack([UI.caption(label), s, value])
    }

    private func segmented<T: Equatable>(_ items: [(String, T)], id: String, get: @escaping (ToolStyle) -> T,
                                         set: @escaping (inout ToolStyle, T) -> Void, key: String) -> NSView {
        let seg = NSSegmentedControl(labels: items.map(\.0), trackingMode: .selectOne, target: nil, action: nil)
        seg.controlSize = .small
        seg.segmentStyle = .rounded
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
                                                  get: { $0.arrowStyle }, set: { $0.arrowStyle = $1 }, key: "arrowStyle")])
    }

    private func blurModeControl() -> NSView {
        UI.hstack([UI.caption("Mode"), segmented(BlurMode.allCases.map { ($0.rawValue.capitalized, $0) }, id: "prop.blurMode",
                                                 get: { $0.blurMode }, set: { $0.blurMode = $1 }, key: "blurMode")])
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
        return UI.hstack([UI.caption("Look"), popup])
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
        let field = NSTextField(string: "")
        field.placeholderString = "Preset name"
        field.setAccessibilityIdentifier("prop.presetName")
        field.widthAnchor.constraint(equalToConstant: 150).isActive = true
        let popover = NSPopover()
        popover.behavior = .transient
        let save = NSButton(title: "Save", target: nil, action: nil)
        save.bezelStyle = .rounded
        save.keyEquivalent = "\r"
        let onSave: (NSControl) -> Void = { [unowned self] _ in
            model.saveStylePreset(named: field.stringValue)
            popover.close()
        }
        save.onAction(onSave)
        field.onAction(onSave)
        let row = UI.hstack([field, save])
        row.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        let vc = NSViewController()
        vc.view = row
        popover.contentViewController = vc
        namePopover = popover
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
    }

    // MARK: Crop

    private func buildCropControls() {
        let aspect = NSPopUpButton(frame: .zero, pullsDown: false)
        aspect.controlSize = .small
        aspect.setAccessibilityIdentifier("crop.aspect")
        for a in CropAspect.allCases { aspect.addItem(withTitle: a.title) }
        aspect.onAction { [unowned self] c in setAspect(CropAspect.allCases[(c as! NSPopUpButton).indexOfSelectedItem]) }
        refreshers.append { [unowned self] in
            aspect.selectItem(at: CropAspect.allCases.firstIndex(of: model.cropDraft?.aspect ?? .free) ?? 0)
        }
        refreshers.last?()

        let reset = NSButton(title: "Reset", target: nil, action: nil)
        reset.bezelStyle = .rounded
        reset.controlSize = .small
        reset.setAccessibilityIdentifier("crop.reset")
        reset.onAction { [unowned self] _ in
            model.setCropDraft(CropDraft(rect: model.document.sourceBounds, aspect: model.cropDraft?.aspect ?? .free))
        }
        let cancel = NSButton(title: "Cancel", target: nil, action: nil)
        cancel.bezelStyle = .rounded
        cancel.controlSize = .small
        cancel.setAccessibilityIdentifier("crop.cancel")
        cancel.onAction { [unowned self] _ in cancelCrop() }
        let apply = NSButton(title: "Apply", target: nil, action: nil)
        apply.bezelStyle = .rounded
        apply.controlSize = .small
        apply.setAccessibilityIdentifier("crop.apply")
        apply.onAction { [unowned self] _ in applyCrop() }

        for v: NSView in [UI.caption("Aspect"), aspect, divider(), reset, cancel, apply, UI.caption("Return applies, Esc cancels")] {
            stack.addArrangedSubview(v)
        }
    }
}
