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

    private(set) var railButtons: [EditorSection: IconButton] = [:]
    let backgroundPanel = BackgroundPanel()
    let cameraPanel = CameraPanel()
    let keystrokesPanel = KeystrokesPanel()
    let audioPanel = AudioPanel()
    /// The sections whose settings this recording can use: it has a camera, keystrokes or sound. The others show a note.
    var available: Set<EditorSection> = []
    private var recordingPanels: [EditorSection: SettingsPanel] { [.camera: cameraPanel, .keystrokes: keystrokesPanel, .audio: audioPanel] }
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

    func show(_ section: EditorSection, cursor: CursorSettings, background: VideoBackground, picture: CGImage?) {
        self.cursor = cursor
        for (s, b) in railButtons { b.isSelected = s == section }
        title.stringValue = section.title
        let isCursor = section == .cursor
        cursorRows.forEach { $0.isHidden = !isCursor }
        let panels = recordingPanels
        for (s, panel) in panels { panel.isHidden = !(s == section && available.contains(s)) }
        emptyNote.isHidden = isCursor || section == .background || (panels[section] != nil && available.contains(section))
        emptyNote.stringValue = Self.note(section)
        backgroundPanel.isHidden = section != .background
        backgroundPanel.show(background, picture: picture)
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
        case .keystrokes: return "This recording has no keystrokes. Turn on Show keystrokes in Recording settings before you record."
        case .audio: return "This recording has no sound. Turn on Record microphone or Record system audio in Audio settings before you record."
        case .camera: return "This recording has no camera. Turn on Show camera in Camera settings before you record."
        case .background: return ""
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
        for v in [title, showCursor, sizeRow, emptyNote] as [NSView] { body.addArrangedSubview(v) }
        for v in [sizeRow, emptyNote] {
            v.widthAnchor.constraint(equalTo: body.widthAnchor, constant: -2 * DS.Space.s16).isActive = true
        }
        body.setCustomSpacing(DS.Space.s16, after: title)
        let filler = NSView()
        filler.setContentHuggingPriority(.defaultLow, for: .vertical)
        body.addArrangedSubview(filler)
        body.setAccessibilityIdentifier("video.panel")

        let divider = Separator(axis: .vertical)
        let edge = Separator(axis: .vertical)
        backgroundPanel.isHidden = true
        let panels = Array(recordingPanels.values)
        panels.forEach { $0.isHidden = true }
        for v in [rail, divider, body, edge, backgroundPanel] + panels as [NSView] {
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
            backgroundPanel.topAnchor.constraint(equalTo: title.bottomAnchor, constant: DS.Space.s16),
            backgroundPanel.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            backgroundPanel.trailingAnchor.constraint(equalTo: body.trailingAnchor),
            backgroundPanel.bottomAnchor.constraint(equalTo: bottomAnchor),
        ] + panels.flatMap { panel in [
            panel.topAnchor.constraint(equalTo: title.bottomAnchor, constant: DS.Space.s16),
            panel.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: body.trailingAnchor),
            panel.bottomAnchor.constraint(equalTo: bottomAnchor),
        ] } + [
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
final class TrackingSlider: Slider {
    var onTrackingEnd: () -> Void = {}

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        onTrackingEnd()
    }
}
