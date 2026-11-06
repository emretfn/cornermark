import AppKit
import CornermarkCore
import CornermarkDesign

final class ClicksPanel: NSView {
    var onCursor: (CursorSettings) -> Void = { _ in }
    var onClicks: (ClickHighlight) -> Void = { _ in }

    private let note = NSTextField(wrappingLabelWithString: "")
    private let press = Checkbox(title: "Press effect")
    private let pressNote = NSTextField(wrappingLabelWithString: "")
    private let ripple = Checkbox(title: "Ripple")
    private let rippleNote = NSTextField(wrappingLabelWithString: "A ring marks each click, in the color and size below.")
    private let color = NSPopUpButton(frame: .zero, pullsDown: false)
    private let size = Segments(labels: ClickHighlight.Size.allCases.map(ClicksPanel.title), tilePadding: DS.Space.s4)
    private let style = Segments(labels: ClickHighlight.Style.allCases.map(ClicksPanel.title), tilePadding: DS.Space.s4)
    private let motion = Segments(labels: ["Grow", "Still"], tilePadding: DS.Space.s4)
    private var ringLabels: [NSTextField] = []
    private var cursor = CursorSettings()
    private var clicks = ClickHighlight()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) { fatalError("ClicksPanel is created in code") }

    func show(cursor: CursorSettings, clicks: ClickHighlight, hasClicks: Bool) {
        self.cursor = cursor
        self.clicks = clicks
        note.isHidden = hasClicks
        press.state = cursor.pressesOnClick ? .on : .off
        ripple.state = clicks.isVisible ? .on : .off
        color.selectItem(at: ClickHighlight.Color.allCases.firstIndex(of: clicks.color) ?? 0)
        size.selectedSegment = ClickHighlight.Size.allCases.firstIndex(of: clicks.size) ?? 0
        style.selectedSegment = ClickHighlight.Style.allCases.firstIndex(of: clicks.style) ?? 0
        motion.selectedSegment = clicks.animates ? 0 : 1
        press.isEnabled = hasClicks && cursor.isVisible
        pressNote.stringValue = cursor.isVisible || !hasClicks ? "The pointer shrinks for a moment at each click."
            : "Turn on Show cursor in the Cursor section to use the press effect."
        ripple.isEnabled = hasClicks
        let ringOn = hasClicks && clicks.isVisible
        for control in [color, size, style, motion] as [NSControl] { control.isEnabled = ringOn }
        for label in ringLabels { label.textColor = ringOn ? DS.Color.textSecondary : DS.Color.textDisabled }
        for caption in [pressNote, rippleNote] { caption.textColor = hasClicks ? DS.Color.textSecondary : DS.Color.textDisabled }
        press.setAccessibilityHelp(hasClicks ? pressNote.stringValue : note.stringValue)
        ripple.setAccessibilityHelp(hasClicks ? rippleNote.stringValue : note.stringValue)
    }

    static func title(_ size: ClickHighlight.Size) -> String {
        switch size {
        case .small: return "Small"
        case .medium: return "Medium"
        case .large: return "Large"
        }
    }

    static func title(_ style: ClickHighlight.Style) -> String {
        switch style {
        case .outline: return "Outline"
        case .filled: return "Filled"
        }
    }

    static func title(_ color: ClickHighlight.Color) -> String {
        switch color {
        case .lemon: return "Lemon"
        case .white: return "White"
        case .orange: return "Orange"
        case .red: return "Red"
        case .green: return "Green"
        }
    }

    private func build() {
        note.stringValue = "This recording has no clicks. Cornermark keeps clicks when Input Monitoring is allowed."
        for caption in [note, pressNote, rippleNote] {
            caption.font = DS.Text.caption.font
            caption.textColor = DS.Color.textSecondary
        }
        note.font = DS.Text.body.font
        note.setAccessibilityIdentifier("video.clicks.note")
        press.setAccessibilityIdentifier("video.clicks.press")
        press.target = self
        press.action = #selector(pressChanged)
        ripple.setAccessibilityIdentifier("video.clicks.ripple")
        ripple.target = self
        ripple.action = #selector(rippleChanged)
        color.controlSize = .small
        color.font = DS.Text.label.font
        for c in ClickHighlight.Color.allCases {
            color.addItem(withTitle: Self.title(c))
            color.lastItem?.image = Self.swatch(c)
        }
        color.setAccessibilityIdentifier("video.clicks.color")
        color.setAccessibilityLabel("Ripple color")
        color.target = self
        color.action = #selector(ringChanged)
        for (control, id, name) in [(size, "video.clicks.size", "Ripple size"), (style, "video.clicks.style", "Ripple style"),
                                    (motion, "video.clicks.motion", "Ripple motion")] {
            control.setAccessibilityIdentifier(id)
            control.setAccessibilityLabel(name)
            control.target = self
            control.action = #selector(ringChanged)
        }
        style.setToolTip("A ring line", forSegment: 0)
        style.setToolTip("A ring line over a see-through disc", forSegment: 1)
        motion.setToolTip("The ring grows and fades", forSegment: 0)
        motion.setToolTip("The ring stays still, then goes", forSegment: 1)

        func row(_ title: String, _ control: NSView) -> NSStackView {
            let label = NSTextField.label(title, style: DS.Text.label, color: DS.Color.textSecondary)
            label.widthAnchor.constraint(equalToConstant: InspectorView.labelColumn).isActive = true
            ringLabels.append(label)
            let row = NSStackView(views: [label, control])
            row.spacing = DS.Space.s8
            row.alignment = .centerY
            return row
        }
        let rows = [row("Color", color), row("Size", size), row("Style", style), row("Motion", motion)]
        let rule = Separator(axis: .horizontal)
        let content = NSStackView(views: [note, press, pressNote, ripple, rippleNote, rule] + rows)
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = DS.Space.s12
        content.edgeInsets = NSEdgeInsets(top: 0, left: DS.Space.s16, bottom: DS.Space.s16, right: DS.Space.s16)
        content.setCustomSpacing(DS.Space.s16, after: note)
        content.setCustomSpacing(DS.Space.s4, after: press)
        content.setCustomSpacing(DS.Space.s16, after: pressNote)
        content.setCustomSpacing(DS.Space.s4, after: ripple)
        content.setCustomSpacing(DS.Space.s16, after: rippleNote)
        content.setCustomSpacing(DS.Space.s16, after: rule)
        let indent = DS.Size.iconLarge + DS.Space.s8
        for v in [note, rule] + rows as [NSView] {
            v.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -2 * DS.Space.s16).isActive = true
        }
        for caption in [pressNote, rippleNote] {
            caption.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -2 * DS.Space.s16 - indent).isActive = true
        }
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor),
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            pressNote.leadingAnchor.constraint(equalTo: press.leadingAnchor, constant: indent),
            rippleNote.leadingAnchor.constraint(equalTo: ripple.leadingAnchor, constant: indent),
        ])
        setAccessibilityIdentifier("video.clicks")
    }

    @objc private func pressChanged() {
        var next = cursor
        next.pressesOnClick = press.state == .on
        onCursor(next)
    }

    @objc private func rippleChanged() {
        var next = clicks
        next.isVisible = ripple.state == .on
        onClicks(next)
    }

    @objc private func ringChanged() {
        var next = clicks
        let colors = ClickHighlight.Color.allCases, sizes = ClickHighlight.Size.allCases, styles = ClickHighlight.Style.allCases
        if colors.indices.contains(color.indexOfSelectedItem) { next.color = colors[color.indexOfSelectedItem] }
        if sizes.indices.contains(size.selectedSegment) { next.size = sizes[size.selectedSegment] }
        if styles.indices.contains(style.selectedSegment) { next.style = styles[style.selectedSegment] }
        next.animates = motion.selectedSegment != 1
        onClicks(next)
    }

    private static func swatch(_ color: ClickHighlight.Color) -> NSImage {
        let fill = InputOverlayInk.design.click(color)
        return NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.setFillColor(fill)
            ctx.fillEllipse(in: rect.insetBy(dx: 1, dy: 1))
            ctx.setStrokeColor(InputOverlayInk.design.halo)
            ctx.setLineWidth(1)
            ctx.strokeEllipse(in: rect.insetBy(dx: 1.5, dy: 1.5))
            return true
        }
    }
}
