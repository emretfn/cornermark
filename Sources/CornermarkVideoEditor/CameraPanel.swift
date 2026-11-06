import AppKit
import CornermarkCore
import CornermarkDesign

/// The camera after recording: whether it shows, its shape, size, place and whether it is mirrored.
final class CameraPanel: SettingsPanel {
    var onChange: (CameraBubble) -> Void = { _ in }
    private(set) var bubble = CameraBubble()
    private let show = Checkbox(title: "Show camera")
    private let shape = Segments(symbols: CameraBubble.Shape.allCases.map(CameraPanel.symbol), labels: CameraBubble.Shape.allCases.map(\.rawValue.capitalized),
                                 size: .small, tileWidth: DS.Size.control)
    private let size = Segments(labels: CameraBubble.Size.allCases.map(\.rawValue.capitalized), width: SettingsPanel.controlWidth)
    private let position = PositionGrid(identifier: "video.camera.position")
    private let mirror = Checkbox(title: "Mirror camera")

    static func symbol(_ shape: CameraBubble.Shape) -> String {
        switch shape {
        case .circle: return "circle"
        case .square: return "square"
        case .rectangle: return "rectangle"
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        show.setAccessibilityIdentifier("video.camera.show")
        mirror.setAccessibilityIdentifier("video.camera.mirror")
        mirror.toolTip = "Show the camera the way a mirror would"
        for box in [show, mirror] {
            box.target = self
            box.action = #selector(changed)
        }
        shape.setAccessibilityIdentifier("video.camera.shape")
        shape.setAccessibilityLabel("Camera shape")
        size.setAccessibilityIdentifier("video.camera.size")
        size.setAccessibilityLabel("Camera size")
        for control in [shape, size] {
            control.target = self
            control.action = #selector(changed)
        }
        position.setAccessibilityLabel("Camera position")
        position.onPick = { [unowned self] _ in changed() }
        add([show, row("Shape", [shape]), row("Size", [size]), row("Position", [position], alignment: .top), mirror])
        setAccessibilityIdentifier("video.camera")
    }

    required init?(coder: NSCoder) { fatalError("CameraPanel is created in code") }

    func show(_ bubble: CameraBubble) {
        self.bubble = bubble
        show.state = bubble.isVisible ? .on : .off
        shape.selectedSegment = CameraBubble.Shape.allCases.firstIndex(of: bubble.shape) ?? 0
        size.selectedSegment = CameraBubble.Size.allCases.firstIndex(of: bubble.size) ?? 0
        position.position = bubble.position
        mirror.state = bubble.isMirrored ? .on : .off
        let on = bubble.isVisible
        for control in [shape, size, mirror] as [NSControl] { control.isEnabled = on }
        position.isEnabled = on
        setLabelsEnabled(on)
    }

    @objc private func changed() {
        var next = bubble
        next.isVisible = show.state == .on
        next.shape = CameraBubble.Shape.allCases[max(shape.selectedSegment, 0)]
        next.size = CameraBubble.Size.allCases[max(size.selectedSegment, 0)]
        next.position = position.position
        next.isMirrored = mirror.state == .on
        guard next != bubble else { return }
        bubble = next
        onChange(next)
    }
}
