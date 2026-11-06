import AppKit
import CornermarkCore
import CornermarkDesign

/// A column of settings rows under a section's title: a 64-point label column and controls that end on the panel's right edge.
/// Camera, Keystrokes and Audio build on it.
class SettingsPanel: NSView {
    static let inner = InspectorView.panelWidth - 2 * DS.Space.s16
    static let controlWidth = inner - InspectorView.labelColumn - DS.Space.s8

    let stack = NSStackView()
    /// A slider let go, which ends its undo step.
    var onSliderEnd: () -> Void = {}
    private var labels: [NSTextField] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = DS.Space.s12
        stack.edgeInsets = NSEdgeInsets(top: 0, left: DS.Space.s16, bottom: DS.Space.s16, right: DS.Space.s16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("SettingsPanel is created in code") }

    /// A label in the label column, then `controls`.
    func row(_ title: String, _ controls: [NSView], alignment: NSLayoutConstraint.Attribute = .centerY) -> NSStackView {
        let label = NSTextField.label(title, style: DS.Text.label, color: DS.Color.textSecondary)
        label.widthAnchor.constraint(equalToConstant: InspectorView.labelColumn).isActive = true
        labels.append(label)
        let row = NSStackView(views: [label] + controls)
        row.spacing = DS.Space.s8
        row.alignment = alignment
        return row
    }

    func add(_ views: [NSView], fullWidth: [NSView] = []) {
        views.forEach(stack.addArrangedSubview)
        for v in fullWidth { v.widthAnchor.constraint(equalToConstant: Self.inner).isActive = true }
    }

    func caption(_ text: String, id: String) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = DS.Text.caption.font
        field.textColor = DS.Color.textSecondary
        field.preferredMaxLayoutWidth = Self.inner
        field.setAccessibilityIdentifier(id)
        return field
    }

    func slider(id: String, label: String, range: ClosedRange<Double>, action: Selector) -> TrackingSlider {
        let s = TrackingSlider()
        s.minValue = range.lowerBound
        s.maxValue = range.upperBound
        s.isContinuous = true
        s.controlSize = .small
        s.setAccessibilityIdentifier(id)
        s.setAccessibilityLabel(label)
        s.target = self
        s.action = action
        s.onTrackingEnd = { [unowned self] in onSliderEnd() }
        return s
    }

    func readout() -> NSTextField {
        let field = NSTextField.label("", style: DS.Text.readout, color: DS.Color.textSecondary)
        field.alignment = .right
        field.setContentHuggingPriority(.required, for: .horizontal)
        // Wide enough for 100%, so the slider keeps its length as the number changes.
        field.widthAnchor.constraint(equalToConstant: 34).isActive = true
        return field
    }

    /// Greys the label column for settings that only matter while the section's switch is on.
    func setLabelsEnabled(_ on: Bool, except kept: Set<ObjectIdentifier> = []) {
        for label in labels where !kept.contains(ObjectIdentifier(label)) { label.textColor = on ? DS.Color.textSecondary : DS.Color.textDisabled }
    }
}

/// Every cell of the grid, row by row, in the order `PositionGrid` lays them out.
extension PositionGrid {
    convenience init(identifier: String) {
        self.init(labels: GridPosition.allCases.map(\.title), identifier: identifier)
    }

    var position: GridPosition {
        get { GridPosition.allCases[selectedIndex] }
        set { selectedIndex = GridPosition.allCases.firstIndex(of: newValue) ?? 0 }
    }
}
