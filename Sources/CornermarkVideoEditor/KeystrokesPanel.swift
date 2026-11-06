import AppKit
import CornermarkCore
import CornermarkDesign

/// The keystroke badge after recording: whether it shows, which keys, its size, style and place.
final class KeystrokesPanel: SettingsPanel {
    var onChange: (KeystrokeDisplay) -> Void = { _ in }
    private(set) var display = KeystrokeDisplay()
    private let show = Checkbox(title: "Show keystrokes")
    private let keys = Segments(labels: ["Shortcuts", "All keys"], width: SettingsPanel.controlWidth, style: .track)
    private let size = Segments(labels: KeystrokeDisplay.Size.allCases.map(\.rawValue.capitalized), width: SettingsPanel.controlWidth, style: .track)
    private let style = Segments(labels: KeystrokeDisplay.Theme.allCases.map(\.rawValue.capitalized), width: SettingsPanel.controlWidth, style: .track)
    private let position = PositionGrid(identifier: "video.keys.position")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        show.setAccessibilityIdentifier("video.keys.show")
        show.target = self
        show.action = #selector(changed)
        keys.setToolTip("Only keys pressed with Command or Control", forSegment: 0)
        keys.setToolTip("Every key, typing included", forSegment: 1)
        for (control, id, label) in [(keys, "video.keys.mode", "Keys to show"), (size, "video.keys.size", "Badge size"), (style, "video.keys.style", "Badge style")] {
            control.setAccessibilityIdentifier(id)
            control.setAccessibilityLabel(label)
            control.target = self
            control.action = #selector(changed)
        }
        position.setAccessibilityLabel("Badge position")
        position.onPick = { [unowned self] _ in changed() }
        add([show, row("Keys", [keys]), row("Size", [size]), row("Style", [style]), row("Position", [position], alignment: .top)])
        setAccessibilityIdentifier("video.keys")
    }

    required init?(coder: NSCoder) { fatalError("KeystrokesPanel is created in code") }

    func show(_ display: KeystrokeDisplay) {
        self.display = display
        show.state = display.isVisible ? .on : .off
        keys.selectedSegment = KeystrokeDisplay.Keys.allCases.firstIndex(of: display.keys) ?? 0
        size.selectedSegment = KeystrokeDisplay.Size.allCases.firstIndex(of: display.size) ?? 0
        style.selectedSegment = KeystrokeDisplay.Theme.allCases.firstIndex(of: display.theme) ?? 0
        position.position = display.position
        let on = display.isVisible
        for control in [keys, size, style] as [NSControl] { control.isEnabled = on }
        position.isEnabled = on
        setLabelsEnabled(on)
    }

    @objc private func changed() {
        var next = display
        next.isVisible = show.state == .on
        next.keys = KeystrokeDisplay.Keys.allCases[max(keys.selectedSegment, 0)]
        next.size = KeystrokeDisplay.Size.allCases[max(size.selectedSegment, 0)]
        next.theme = KeystrokeDisplay.Theme.allCases[max(style.selectedSegment, 0)]
        next.position = position.position
        guard next != display else { return }
        display = next
        onChange(next)
    }
}
