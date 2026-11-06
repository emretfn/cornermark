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
    var onClicks: (ClickHighlight) -> Void = { _ in }

    private(set) var railButtons: [EditorSection: IconButton] = [:]
    let backgroundPanel = BackgroundPanel()
    let cameraPanel = CameraPanel()
    let keystrokesPanel = KeystrokesPanel()
    let audioPanel = AudioPanel()
    let motionBlurPanel = MotionBlurPanel()
    /// The sections whose settings this recording can use: it has a camera, keystrokes or sound. The others show a note.
    var available: Set<EditorSection> = []
    private var recordingPanels: [EditorSection: SettingsPanel] { [.camera: cameraPanel, .keystrokes: keystrokesPanel, .audio: audioPanel] }
    let clicksPanel = ClicksPanel()
    private let title = NSTextField.label("", style: DS.Text.heading, color: DS.Color.textPrimary)
    private let body = NSStackView()
    private let showCursor = Checkbox(title: "Show cursor")
    private let cursorSize = TrackingSlider()
    private let cursorSizeValue = NSTextField.label("", style: DS.Text.readout, color: DS.Color.textSecondary)
    private let cursorStyle = Segments(labels: CursorStyle.allCases.map(InspectorView.title), width: SettingsPanel.controlWidth)
    private let cursorMotion = Segments(labels: CursorMotion.allCases.map(InspectorView.title), width: SettingsPanel.controlWidth)
    private let hideIdle = Checkbox(title: "Hide when not moving")
    private let hideTyping = Checkbox(title: "Hide when typing")
    private var rowLabels: [NSTextField] = []
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
    func show(_ section: EditorSection, cursor: CursorSettings, clicks: ClickHighlight, hasClicks: Bool, background: VideoBackground, picture: CGImage?, zoom: Zoom? = nil, zoomCount: Int = 0,
              origin: RecordingProject.Source.Origin = .recording, hasAudio: Bool = false) {
        self.cursor = cursor
        for (s, b) in railButtons { b.isSelected = zoom == nil && s == section }
        title.stringValue = zoom == nil ? section.title : "Zoom"
        zoomPanel.isHidden = zoom == nil
        if let zoom { zoomPanel.show(zoom, count: zoomCount) }
        let panels = recordingPanels
        for (s, panel) in panels { panel.isHidden = !(s == section && available.contains(s) && zoom == nil) }
        let hasPanel = panels[section] != nil && available.contains(section)
        let note = zoom == nil && !hasPanel ? Self.note(section, origin: origin, hasAudio: hasAudio) : ""
        let isCursor = section == .cursor && zoom == nil
        cursorRows.forEach { $0.isHidden = !isCursor || !note.isEmpty }
        emptyNote.isHidden = note.isEmpty
        emptyNote.stringValue = note
        backgroundPanel.isHidden = section != .background || zoom != nil
        backgroundPanel.show(background, picture: picture)
        clicksPanel.isHidden = section != .clicks || zoom != nil || !note.isEmpty
        motionBlurPanel.isHidden = section != .motionBlur || zoom != nil
        clicksPanel.show(cursor: cursor, clicks: clicks, hasClicks: hasClicks)
        showCursor.state = cursor.isVisible ? .on : .off
        cursorSize.doubleValue = cursor.scale
        cursorSizeValue.stringValue = String(format: "%.1f\u{00D7}", cursor.scale)
        cursorStyle.selectedSegment = CursorStyle.allCases.firstIndex(of: cursor.style) ?? 0
        cursorMotion.selectedSegment = CursorMotion.allCases.firstIndex(of: cursor.motion) ?? 0
        hideIdle.state = cursor.hidesWhenIdle ? .on : .off
        hideTyping.state = cursor.hidesWhenTyping ? .on : .off
        // Every other setting shapes a pointer that is not drawn while Show cursor is off.
        let on = cursor.isVisible
        for control in [cursorSize, cursorStyle, cursorMotion, hideIdle, hideTyping] as [NSControl] { control.isEnabled = on }
        cursorSizeValue.textColor = on ? DS.Color.textSecondary : DS.Color.textDisabled
        for label in rowLabels { label.textColor = on ? DS.Color.textSecondary : DS.Color.textDisabled }
    }

    static func title(_ style: CursorStyle) -> String {
        switch style {
        case .white: return "White"
        case .black: return "Black"
        case .dot: return "Dot"
        }
    }

    static func title(_ motion: CursorMotion) -> String {
        switch motion {
        case .natural: return "Natural"
        case .smooth: return "Smooth"
        }
    }

    /// What a section without settings says. Each one states what this video holds, not what a later version adds.
    static func note(_ section: EditorSection, origin: RecordingProject.Source.Origin = .recording, hasAudio: Bool = false) -> String {
        if origin == .file {
            switch section {
            case .cursor: return "This video was opened from a file, so it has no pointer track. Its pointer is part of the picture, and zooms still work. Record Project to change the pointer afterwards."
            case .clicks: return "This video was opened from a file, so no clicks were recorded with it."
            case .keystrokes: return "This video was opened from a file, so no keystrokes were recorded with it."
            case .audio: return hasAudio ? "This video plays and exports with its own sound." : "This video has no sound."
            case .camera: return "This video has no camera."
            case .background, .motionBlur: break
            }
        }
        switch section {
        case .cursor, .clicks: return ""
        case .keystrokes: return "This recording has no keystrokes. Turn on Show keystrokes in Recording settings before you record."
        case .audio: return "This recording has no sound. Turn on Record microphone or Record system audio in Audio settings before you record."
        case .camera: return "This recording has no camera. Turn on Show camera in Camera settings before you record."
        case .background, .motionBlur: return ""
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
        cursorStyle.setAccessibilityIdentifier("video.cursor.style")
        cursorStyle.setAccessibilityLabel("Cursor style")
        for (i, tip) in ["White arrow", "Black arrow", "Translucent dot"].enumerated() { cursorStyle.setToolTip(tip, forSegment: i) }
        cursorStyle.target = self
        cursorStyle.action = #selector(styleChanged)
        cursorMotion.setAccessibilityIdentifier("video.cursor.motion")
        cursorMotion.setAccessibilityLabel("Cursor motion")
        cursorMotion.setToolTip("The path as it was recorded", forSegment: 0)
        cursorMotion.setToolTip("A steadier path that settles at each stop", forSegment: 1)
        cursorMotion.target = self
        cursorMotion.action = #selector(motionChanged)
        for (box, id) in [(hideIdle, "video.cursor.hideIdle"), (hideTyping, "video.cursor.hideTyping")] {
            box.setAccessibilityIdentifier(id)
            box.target = self
            box.action = #selector(hidingChanged)
        }
        func row(_ title: String, _ controls: [NSView]) -> NSStackView {
            let label = NSTextField.label(title, style: DS.Text.label, color: DS.Color.textSecondary)
            label.widthAnchor.constraint(equalToConstant: Self.labelColumn).isActive = true
            rowLabels.append(label)
            let row = NSStackView(views: [label] + controls)
            row.spacing = DS.Space.s8
            row.alignment = .centerY
            return row
        }
        let sizeRow = row("Size", [cursorSize, cursorSizeValue])
        let styleRow = row("Style", [cursorStyle])
        let motionRow = row("Motion", [cursorMotion])
        // The stack insets its rows, so the line between the look and the hiding options is laid over a spacer of its height.
        let ruleSlot = NSView()
        ruleSlot.heightAnchor.constraint(equalToConstant: 1).isActive = true
        let rule = Separator(axis: .horizontal)
        cursorRows = [showCursor, sizeRow, styleRow, motionRow, ruleSlot, rule, hideIdle, hideTyping]

        emptyNote.font = DS.Text.body.font
        emptyNote.textColor = DS.Color.textSecondary
        emptyNote.setAccessibilityIdentifier("video.panel.note")

        title.setAccessibilityIdentifier("video.panel.title")
        title.setAccessibilityRole(.staticText)
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = DS.Space.s12
        body.edgeInsets = NSEdgeInsets(top: DS.Space.s16, left: DS.Space.s16, bottom: DS.Space.s16, right: DS.Space.s16)
        for v in [title, showCursor, sizeRow, styleRow, motionRow, ruleSlot, hideIdle, hideTyping, emptyNote, zoomPanel] as [NSView] { body.addArrangedSubview(v) }
        for v in [sizeRow, styleRow, motionRow, ruleSlot, emptyNote, zoomPanel] {
            v.widthAnchor.constraint(equalTo: body.widthAnchor, constant: -2 * DS.Space.s16).isActive = true
        }
        body.setCustomSpacing(DS.Space.s16, after: title)
        body.setCustomSpacing(DS.Space.s16, after: motionRow)
        body.setCustomSpacing(DS.Space.s16, after: ruleSlot)
        let filler = NSView()
        filler.setContentHuggingPriority(.defaultLow, for: .vertical)
        body.addArrangedSubview(filler)
        body.setAccessibilityIdentifier("video.panel")

        let divider = Separator(axis: .vertical)
        let edge = Separator(axis: .vertical)
        backgroundPanel.isHidden = true
        let panels = Array(recordingPanels.values) + [motionBlurPanel]
        panels.forEach { $0.isHidden = true }
        clicksPanel.isHidden = true
        clicksPanel.onCursor = { [unowned self] in onCursor($0) }
        clicksPanel.onClicks = { [unowned self] in onClicks($0) }
        for v in [rail, divider, body, edge, rule, backgroundPanel, clicksPanel] + panels as [NSView] {
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
            clicksPanel.topAnchor.constraint(equalTo: title.bottomAnchor, constant: DS.Space.s16),
            clicksPanel.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            clicksPanel.trailingAnchor.constraint(equalTo: body.trailingAnchor),
            edge.leadingAnchor.constraint(equalTo: body.trailingAnchor),
            edge.trailingAnchor.constraint(equalTo: trailingAnchor),
            edge.topAnchor.constraint(equalTo: topAnchor),
            edge.bottomAnchor.constraint(equalTo: bottomAnchor),
            rule.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: body.trailingAnchor),
            rule.centerYAnchor.constraint(equalTo: ruleSlot.centerYAnchor),
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

    @objc private func styleChanged() {
        guard CursorStyle.allCases.indices.contains(cursorStyle.selectedSegment) else { return }
        var next = cursor
        next.style = CursorStyle.allCases[cursorStyle.selectedSegment]
        onCursor(next)
    }

    @objc private func motionChanged() {
        guard CursorMotion.allCases.indices.contains(cursorMotion.selectedSegment) else { return }
        var next = cursor
        next.motion = CursorMotion.allCases[cursorMotion.selectedSegment]
        onCursor(next)
    }

    @objc private func hidingChanged() {
        var next = cursor
        next.hidesWhenIdle = hideIdle.state == .on
        next.hidesWhenTyping = hideTyping.state == .on
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
