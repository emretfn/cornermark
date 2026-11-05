import AppKit
import CornermarkCore
import CornermarkDesign

/// The settings of the zoom picked on the timeline, in place of a section's panel: its level as presets and a slider, its mode,
/// and the edits that reach beyond it.
final class ZoomPanel: NSStackView {
    enum Change: Equatable {
        /// `dragging` is true while the slider moves, so one drag is one undo step.
        case scale(Double, dragging: Bool)
        case mode(ZoomMode)
        case applyToAll
        case remove
    }

    var onChange: (Change) -> Void = { _ in }

    private let presets = Segments(labels: Zoom.levels.map(Zoom.percent), size: .small, tilePadding: DS.Space.s4)
    private let slider = Slider()
    private let value = NSTextField.label("", style: DS.Text.readout, color: DS.Color.textSecondary)
    private let mode = NSPopUpButton(frame: .zero, pullsDown: false)
    private let modeNote = NSTextField(wrappingLabelWithString: ZoomPanel.modeNote)
    private let applyToAll = Button(title: "Apply Level to All", variant: .secondary, size: .small)
    private let remove = Button(title: "Remove Zoom", variant: .dangerGhost, size: .small)
    private var zoom: Zoom?

    static let modeNote = "The camera holds on the spot the zoom was added at."

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) { fatalError("ZoomPanel is created in code") }

    func show(_ zoom: Zoom, count: Int) {
        self.zoom = zoom
        presets.selectedSegment = Zoom.levels.firstIndex { abs($0 - zoom.scale) < 0.005 } ?? -1
        slider.doubleValue = zoom.scale
        value.stringValue = Zoom.percent(zoom.scale)
        mode.selectItem(at: ZoomMode.allCases.firstIndex(of: zoom.mode) ?? 0)
        applyToAll.isEnabled = count > 1
    }

    private func build() {
        orientation = .vertical
        alignment = .leading
        spacing = DS.Space.s12
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Zoom settings")
        setAccessibilityIdentifier("video.zoom.panel")

        slider.minValue = Zoom.scaleRange.lowerBound
        slider.maxValue = Zoom.scaleRange.upperBound
        slider.isContinuous = true
        slider.controlSize = .small
        slider.setAccessibilityLabel("Zoom level")
        slider.setAccessibilityIdentifier("video.zoom.level")
        slider.target = self
        slider.action = #selector(sliderMoved)
        value.alignment = .right
        value.setContentHuggingPriority(.required, for: .horizontal)
        value.widthAnchor.constraint(equalToConstant: 36).isActive = true

        presets.setAccessibilityLabel("Zoom level presets")
        presets.setAccessibilityIdentifier("video.zoom.presets")
        presets.target = self
        presets.action = #selector(presetPicked)

        for m in ZoomMode.allCases { mode.addItem(withTitle: m.title) }
        mode.controlSize = .small
        mode.font = DS.Text.label.font
        mode.setAccessibilityLabel("Zoom mode")
        mode.setAccessibilityIdentifier("video.zoom.mode")
        mode.target = self
        mode.action = #selector(modePicked)
        modeNote.font = DS.Text.caption.font
        modeNote.textColor = DS.Color.textSecondary
        modeNote.setAccessibilityIdentifier("video.zoom.modeNote")

        applyToAll.setAccessibilityIdentifier("video.zoom.applyToAll")
        applyToAll.onPress { [unowned self] in onChange(.applyToAll) }
        remove.setAccessibilityIdentifier("video.zoom.remove")
        remove.onPress { [unowned self] in onChange(.remove) }

        let levelRow = row("Level", [slider, value])
        let modeRow = row("Mode", [mode])
        let buttons = NSStackView(views: [applyToAll, remove])
        buttons.spacing = DS.Space.s8
        for v in [levelRow, presets, modeRow, modeNote, buttons] as [NSView] { addArrangedSubview(v) }
        setCustomSpacing(DS.Space.s8, after: levelRow)
        setCustomSpacing(DS.Space.s4, after: modeRow)
        setCustomSpacing(DS.Space.s16, after: modeNote)
        for v in [levelRow, modeRow, modeNote] { v.widthAnchor.constraint(equalTo: widthAnchor).isActive = true }
        // Five presets need the panel's whole width, so they sit under the level's row rather than in its control column.
        presets.setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    private func row(_ label: String, _ views: [NSView]) -> NSStackView {
        let name = NSTextField.label(label, style: DS.Text.label, color: DS.Color.textSecondary)
        name.widthAnchor.constraint(equalToConstant: InspectorView.labelColumn).isActive = true
        let row = NSStackView(views: [name] + views)
        row.spacing = DS.Space.s8
        row.alignment = .centerY
        return row
    }

    @objc private func sliderMoved() {
        let dragging = NSApp.currentEvent.map { $0.type == .leftMouseDragged || $0.type == .leftMouseDown } ?? false
        // Whole percents, and the presets snap the slider when it passes within a step of one.
        var s = (slider.doubleValue * 100).rounded() / 100
        if let near = Zoom.levels.first(where: { abs($0 - s) < 0.03 }) { s = near }
        onChange(.scale(s, dragging: dragging))
    }

    @objc private func presetPicked() {
        guard Zoom.levels.indices.contains(presets.selectedSegment) else { return }
        onChange(.scale(Zoom.levels[presets.selectedSegment], dragging: false))
    }

    @objc private func modePicked() {
        guard ZoomMode.allCases.indices.contains(mode.indexOfSelectedItem) else { return }
        onChange(.mode(ZoomMode.allCases[mode.indexOfSelectedItem]))
    }
}
