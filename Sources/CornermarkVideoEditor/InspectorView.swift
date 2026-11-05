import AppKit
import CornermarkCore
import CornermarkDesign

/// The settings column on the left: a rail of section buttons and the panel of the chosen section.
final class InspectorView: NSView {
    static let railWidth: CGFloat = 48
    static let panelWidth: CGFloat = 248
    static let labelColumn: CGFloat = 64

    var onSelect: (EditorSection) -> Void = { _ in }
    var onCursor: (CursorSettings) -> Void = { _ in }
    var onCursorSizeEnd: () -> Void = {}
    let zoomPanel = ZoomPanel()

    private(set) var railButtons: [EditorSection: IconButton] = [:]
    private let title = NSTextField.label("", style: DS.Text.heading, color: DS.Color.textPrimary)
    private let body = NSStackView()
    private let showCursor = Checkbox(title: "Show cursor")
    private let cursorSize = TrackingSlider()
    private let cursorSizeValue = NSTextField.label("", style: DS.Text.readout, color: DS.Color.textSecondary)
    private let emptyNote = NSTextField(wrappingLabelWithString: "")
    private var cursorRows: [NSView] = []
    private var cursor = CursorSettings()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) { fatalError("InspectorView is created in code") }

    /// Sliders work in this range. A stored size outside it is kept until the slider moves.
    static let sizeRange = 0.5...4.0

    /// A picked zoom takes the panel over from the section, and the rail then marks none.
    func show(_ section: EditorSection, cursor: CursorSettings, zoom: Zoom? = nil, zoomCount: Int = 0) {
        self.cursor = cursor
        for (s, b) in railButtons { b.isSelected = zoom == nil && s == section }
        title.stringValue = zoom == nil ? section.title : "Zoom"
        zoomPanel.isHidden = zoom == nil
        if let zoom { zoomPanel.show(zoom, count: zoomCount) }
        let isCursor = section == .cursor && zoom == nil
        cursorRows.forEach { $0.isHidden = !isCursor }
        emptyNote.isHidden = isCursor || zoom != nil
        emptyNote.stringValue = Self.note(section)
        showCursor.state = cursor.isVisible ? .on : .off
        cursorSize.doubleValue = cursor.scale
        cursorSize.isEnabled = cursor.isVisible
        cursorSizeValue.stringValue = String(format: "%.1f\u{00D7}", cursor.scale)
        cursorSizeValue.textColor = cursor.isVisible ? DS.Color.textSecondary : DS.Color.textDisabled
    }

    /// What a section without settings says. Each one states what this recording holds, not what a later version adds.
    static func note(_ section: EditorSection) -> String {
        switch section {
        case .cursor: return ""
        case .keystrokes: return "This recording has no keystrokes."
        case .audio: return "This recording has no sound."
        case .camera: return "This recording has no camera."
        case .background: return "Background settings are not available yet."
        case .motionBlur: return "Motion blur is not available yet."
        }
    }

    private func build() {
        let rail = NSStackView()
        rail.orientation = .vertical
        rail.alignment = .centerX
        rail.spacing = DS.Space.s6
        rail.edgeInsets = NSEdgeInsets(top: DS.Space.s12, left: 0, bottom: DS.Space.s12, right: 0)
        rail.setAccessibilityIdentifier("video.rail")
        for section in EditorSection.allCases {
            let b = IconButton(symbol: section.symbol, label: section.title, size: .regular)
            b.selection = .neutral
            b.setAccessibilityIdentifier("video.rail.\(section.rawValue)")
            b.target = self
            b.action = #selector(railPressed(_:))
            b.identifier = NSUserInterfaceItemIdentifier(section.rawValue)
            railButtons[section] = b
            rail.addArrangedSubview(b)
        }
        rail.addArrangedSubview(NSView())
        rail.views.last?.setContentHuggingPriority(.defaultLow, for: .vertical)

        showCursor.setAccessibilityIdentifier("video.cursor.show")
        showCursor.target = self
        showCursor.action = #selector(visibilityChanged)
        cursorSize.minValue = Self.sizeRange.lowerBound
        cursorSize.maxValue = Self.sizeRange.upperBound
        cursorSize.isContinuous = true
        cursorSize.controlSize = .small
        cursorSize.onTrackingEnd = { [unowned self] in onCursorSizeEnd() }
        cursorSize.setAccessibilityIdentifier("video.cursor.size")
        cursorSize.setAccessibilityLabel("Cursor size")
        cursorSize.target = self
        cursorSize.action = #selector(sizeChanged)
        cursorSizeValue.alignment = .right
        cursorSizeValue.setContentHuggingPriority(.required, for: .horizontal)
        let sizeLabel = NSTextField.label("Size", style: DS.Text.label, color: DS.Color.textSecondary)
        sizeLabel.widthAnchor.constraint(equalToConstant: Self.labelColumn).isActive = true
        let sizeRow = NSStackView(views: [sizeLabel, cursorSize, cursorSizeValue])
        sizeRow.spacing = DS.Space.s8
        sizeRow.alignment = .centerY
        cursorRows = [showCursor, sizeRow]

        emptyNote.font = DS.Text.body.font
        emptyNote.textColor = DS.Color.textSecondary
        emptyNote.setAccessibilityIdentifier("video.panel.note")

        title.setAccessibilityIdentifier("video.panel.title")
        title.setAccessibilityRole(.staticText)
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = DS.Space.s12
        body.edgeInsets = NSEdgeInsets(top: DS.Space.s16, left: DS.Space.s16, bottom: DS.Space.s16, right: DS.Space.s16)
        for v in [title, showCursor, sizeRow, emptyNote, zoomPanel] as [NSView] { body.addArrangedSubview(v) }
        for v in [sizeRow, emptyNote, zoomPanel] {
            v.widthAnchor.constraint(equalTo: body.widthAnchor, constant: -2 * DS.Space.s16).isActive = true
        }
        body.setCustomSpacing(DS.Space.s16, after: title)
        let filler = NSView()
        filler.setContentHuggingPriority(.defaultLow, for: .vertical)
        body.addArrangedSubview(filler)
        body.setAccessibilityIdentifier("video.panel")

        let divider = Separator(axis: .vertical)
        let edge = Separator(axis: .vertical)
        for v in [rail, divider, body, edge] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            rail.leadingAnchor.constraint(equalTo: leadingAnchor),
            rail.topAnchor.constraint(equalTo: topAnchor),
            rail.bottomAnchor.constraint(equalTo: bottomAnchor),
            rail.widthAnchor.constraint(equalToConstant: Self.railWidth),
            divider.leadingAnchor.constraint(equalTo: rail.trailingAnchor),
            divider.topAnchor.constraint(equalTo: topAnchor),
            divider.bottomAnchor.constraint(equalTo: bottomAnchor),
            body.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            body.topAnchor.constraint(equalTo: topAnchor),
            body.bottomAnchor.constraint(equalTo: bottomAnchor),
            body.widthAnchor.constraint(equalToConstant: Self.panelWidth),
            edge.leadingAnchor.constraint(equalTo: body.trailingAnchor),
            edge.trailingAnchor.constraint(equalTo: trailingAnchor),
            edge.topAnchor.constraint(equalTo: topAnchor),
            edge.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @objc private func railPressed(_ sender: IconButton) {
        guard let raw = sender.identifier?.rawValue, let section = EditorSection(rawValue: raw) else { return }
        onSelect(section)
    }

    @objc private func visibilityChanged() {
        var next = cursor
        next.isVisible = showCursor.state == .on
        onCursor(next)
    }

    @objc private func sizeChanged() {
        var next = cursor
        next.scale = (cursorSize.doubleValue * 10).rounded() / 10
        onCursor(next)
    }
}

/// A slider that says when a drag ends: `mouseDown` returns only once the pointer lets go.
private final class TrackingSlider: Slider {
    var onTrackingEnd: () -> Void = {}

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        onTrackingEnd()
    }
}
