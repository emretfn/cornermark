import AppKit
import CornermarkCore
import CornermarkDesign

/// The settings of the zoom picked on the timeline, in place of a section's panel: its level as a slider with the presets as detents, its mode, the
/// spot a Manual zoom aims at, and the edits that reach beyond it.
final class ZoomPanel: NSStackView {
    enum Change: Equatable {
        /// `dragging` is true while the slider moves, so one drag is one undo step.
        case scale(Double, dragging: Bool)
        case mode(ZoomMode)
        case center(ZoomPoint, ZoomTargetView.Phase)
        case animationSettings
        case applyToAll
        case remove
    }

    var onChange: (Change) -> Void = { _ in }

    private let slider = Slider()
    private let mode = Select()
    private let modeNote = NSTextField.label(ZoomPanel.modeNote(.followCursor), style: DS.Text.caption, color: DS.Color.textSecondary)
    let target = ZoomTargetView()
    let animationSettings = Button(title: "Animation Settings", variant: .secondary, size: .small, symbol: "slider.horizontal.3")
    private let applyToAll = Button(title: "Apply Level to All", variant: .secondary, size: .small)
    private let remove = Button(title: "Remove Zoom", variant: .dangerGhost, size: .small)
    private var zoom: Zoom?

    /// What each mode does, in one line under the mode menu.
    static func modeNote(_ mode: ZoomMode) -> String {
        switch mode {
        case .followCursor: return "Holds still, then drifts after the cursor."
        case .manual: return "Holds the spot framed below."
        }
    }

    /// The whole story, for the tooltip and VoiceOver.
    static func modeDetail(_ mode: ZoomMode) -> String {
        switch mode {
        case .followCursor: return "The camera holds while the cursor stays near the middle of the view, then drifts to follow it."
        case .manual: return "The camera holds the spot framed below. Drag the frame or use the arrow keys to move it."
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) { fatalError("ZoomPanel is created in code") }

    func show(_ zoom: Zoom, count: Int) {
        self.zoom = zoom
        slider.doubleValue = zoom.scale
        mode.selectItem(at: ZoomMode.allCases.firstIndex(of: zoom.mode) ?? 0)
        modeNote.stringValue = Self.modeNote(zoom.mode)
        modeNote.toolTip = Self.modeDetail(zoom.mode)
        mode.setAccessibilityHelp(Self.modeDetail(zoom.mode))
        target.zoom = zoom
        target.isHidden = zoom.mode != .manual
        // A hidden picture leaves the stack, so the note keeps the gap the picture would have had below it.
        setCustomSpacing(zoom.mode == .manual ? DS.Space.s8 : DS.Space.s16, after: modeNote)
        applyToAll.isEnabled = count > 1
    }

    private func build() {
        orientation = .vertical
        alignment = .leading
        spacing = DS.Space.s8
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Zoom settings")
        setAccessibilityIdentifier("video.zoom.panel")

        slider.minValue = Zoom.scaleRange.lowerBound
        slider.maxValue = Zoom.scaleRange.upperBound
        slider.isContinuous = true
        slider.style = .field
        slider.format = Zoom.percent
        // The presets are detents on the slider: ticks under the field that a drag snaps to.
        slider.detents = Zoom.levels
        slider.setAccessibilityLabel("Zoom level")
        slider.setAccessibilityIdentifier("video.zoom.level")
        slider.target = self
        slider.action = #selector(sliderMoved)

        for m in ZoomMode.allCases { mode.addItem(withTitle: m.title) }
        mode.setAccessibilityLabel("Zoom mode")
        mode.setAccessibilityIdentifier("video.zoom.mode")
        mode.target = self
        mode.action = #selector(modePicked)
        modeNote.lineBreakMode = .byTruncatingTail
        modeNote.setAccessibilityIdentifier("video.zoom.modeNote")

        target.onChange = { [unowned self] in onChange(.center($0, $1)) }
        animationSettings.setAccessibilityIdentifier("video.zoom.animationSettings")
        animationSettings.toolTip = "How every zoom in this video moves in, out and after the pointer"
        animationSettings.onPress { [unowned self] in onChange(.animationSettings) }
        applyToAll.setAccessibilityIdentifier("video.zoom.applyToAll")
        applyToAll.onPress { [unowned self] in onChange(.applyToAll) }
        remove.setAccessibilityIdentifier("video.zoom.remove")
        remove.onPress { [unowned self] in onChange(.remove) }

        let levelRow = row("Level", [slider])
        let modeRow = row("Mode", [mode])
        let buttons = NSStackView(views: [applyToAll, remove])
        buttons.spacing = DS.Space.s8
        for v in [levelRow, modeRow, modeNote, target, animationSettings, buttons] as [NSView] { addArrangedSubview(v) }
        setCustomSpacing(DS.Space.s8, after: levelRow)
        setCustomSpacing(DS.Space.s4, after: modeRow)
        setCustomSpacing(DS.Space.s8, after: modeNote)
        setCustomSpacing(DS.Space.s16, after: target)
        setCustomSpacing(DS.Space.s16, after: animationSettings)
        for v in [levelRow, modeRow, modeNote, target] { v.widthAnchor.constraint(equalTo: widthAnchor).isActive = true }
    }

    private func row(_ label: String, _ views: [NSView]) -> NSStackView {
        let name = NSTextField.label(label, style: DS.Text.label, color: DS.Color.textSecondary)
        name.widthAnchor.constraint(equalToConstant: InspectorView.labelColumn).isActive = true
        // The last stretchable control fills the row, so a menu ends on the panel's right edge like the slider above it.
        mode.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [name] + views)
        row.spacing = DS.Space.s8
        row.alignment = .centerY
        row.distribution = .fill
        return row
    }

    @objc private func sliderMoved() {
        let dragging = NSApp.currentEvent.map { $0.type == .leftMouseDragged || $0.type == .leftMouseDown } ?? false
        // Whole percents, and the presets snap the slider when it passes within a step of one.
        var s = (slider.doubleValue * 100).rounded() / 100
        if let near = Zoom.levels.first(where: { abs($0 - s) < 0.03 }) { s = near }
        onChange(.scale(s, dragging: dragging))
    }

    @objc private func modePicked() {
        guard ZoomMode.allCases.indices.contains(mode.indexOfSelectedItem) else { return }
        onChange(.mode(ZoomMode.allCases[mode.indexOfSelectedItem]))
    }
}
