import AppKit
import CornermarkCapture
import CornermarkCore
import CornermarkDesign

extension AppEnvironment {
    static let cameraPaneURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!
}

extension CameraBubble.Shape {
    var title: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .circle: return "circle"
        case .square: return "square"
        case .rectangle: return "rectangle"
        }
    }
}

extension CameraBubble.Size {
    var title: String { rawValue.capitalized }
}

extension CameraBubble.Corner {
    var title: String {
        switch self {
        case .bottomLeft: return "Bottom left"
        case .bottomRight: return "Bottom right"
        case .topLeft: return "Top left"
        case .topRight: return "Top right"
        }
    }
}

final class CameraPane: SettingsPane {
    override var paneTitle: String { "Camera" }
    override var symbol: String { "web.camera" }
    private let show = Form.checkbox("Show camera", id: "camera.show")
    private let shape = Segments(symbols: CameraBubble.Shape.allCases.map(\.symbol), labels: CameraBubble.Shape.allCases.map(\.title), size: .small,
                                 tileWidth: DS.Size.control)
    private let size = Form.popup(CameraBubble.Size.allCases.map(\.title), id: "camera.size")
    private let corner = Form.popup(CameraBubble.Corner.allCases.map(\.title), id: "camera.corner")
    private let mirror = Form.checkbox("Mirror camera", id: "camera.mirror")
    private let accessStatus = NSTextField.label("", style: DS.Text.bodyStrong, color: DS.Color.textPrimary)
    private let accessDot = StatusDot()
    private let accessNote = Form.caption("")
    private let accessButton = Button(title: "Allow Camera Access", variant: .secondary, size: .small)

    override func buildForm() -> FormPage {
        shape.setAccessibilityIdentifier("camera.shape")
        shape.setAccessibilityLabel("Shape")
        size.setAccessibilityLabel("Size")
        corner.setAccessibilityLabel("Position")
        accessStatus.setAccessibilityIdentifier("camera.access")
        accessButton.setAccessibilityIdentifier("camera.access.button")
        show.onAction { [unowned self] c in
            let on = (c as! NSButton).state == .on
            change { $0.recording.camera.isVisible = on }
            if on, ctx.env.cameraAccess() == .notAsked { ctx.env.requestCameraAccess { [weak self] _ in self?.refresh() } }
        }
        shape.onAction { [unowned self] c in
            let i = (c as! NSSegmentedControl).selectedSegment
            guard CameraBubble.Shape.allCases.indices.contains(i) else { return }
            change { $0.recording.camera.shape = CameraBubble.Shape.allCases[i] }
        }
        size.onAction { [unowned self] c in
            let i = (c as! NSPopUpButton).indexOfSelectedItem
            change { $0.recording.camera.size = CameraBubble.Size.allCases[i] }
        }
        corner.onAction { [unowned self] c in
            let i = (c as! NSPopUpButton).indexOfSelectedItem
            change { $0.recording.camera.corner = CameraBubble.Corner.allCases[i] }
        }
        mirror.onAction { [unowned self] c in change { $0.recording.camera.isMirrored = (c as! NSButton).state == .on } }
        accessButton.onAction { [unowned self] _ in
            if ctx.env.cameraAccess() == .notAsked {
                ctx.env.requestCameraAccess { [weak self] _ in self?.refresh() }
            } else {
                ctx.env.openURL(AppEnvironment.cameraPaneURL)
            }
        }
        return Form.page(title: paneTitle, groups: [
            .init(rows: [
                Form.row(title: "Show camera", caption: Form.caption("Shows you in a bubble over the recording. Record for Editing keeps the camera as its own track, so you can still change it later."),
                         control: show),
            ]),
            .init("Bubble", rows: [
                Form.row(title: "Shape", control: Form.hstack([shape])),
                Form.row(title: "Size", control: size),
                Form.row(title: "Position", caption: Form.caption("You can also drag the bubble to another corner while recording."), control: corner),
                Form.row(title: "Mirror camera", caption: Form.caption("Shows you the way a mirror does. Turn it off to make text behind you readable."), control: mirror),
            ], footer: "While recording, click the bubble to fill the recording with the camera, and click again to bring the bubble back."),
            .init(rows: [
                Form.row(title: "Camera access", caption: accessNote, control: Form.hstack([accessDot, accessStatus, accessButton], spacing: DS.Space.s6)),
            ]),
        ])
    }

    override func update() {
        let c = settings.recording.camera
        show.state = c.isVisible ? .on : .off
        shape.selectedSegment = CameraBubble.Shape.allCases.firstIndex(of: c.shape) ?? 0
        size.selectItem(at: CameraBubble.Size.allCases.firstIndex(of: c.size) ?? 0)
        corner.selectItem(at: CameraBubble.Corner.allCases.firstIndex(of: c.corner) ?? 0)
        mirror.state = c.isMirrored ? .on : .off
        ([shape, size, corner, mirror] as [NSControl]).forEach { $0.isEnabled = c.isVisible }
        let access = ctx.env.cameraAccess()
        let blocking = access != .allowed && c.isVisible
        switch access {
        case .allowed: accessStatus.stringValue = "Allowed"
        case .notAsked: accessStatus.stringValue = "Not asked yet"
        case .denied: accessStatus.stringValue = "Not allowed"
        }
        accessStatus.textColor = access == .allowed ? DS.Color.successText : blocking ? DS.Color.dangerText : DS.Color.textSecondary
        accessDot.color = accessStatus.textColor ?? DS.Color.textSecondary
        accessNote.textColor = blocking ? DS.Color.dangerText : DS.Color.textSecondary
        switch access {
        case .allowed:
            accessNote.stringValue = "Cornermark uses the camera only while it records with the camera on."
        case .notAsked:
            accessNote.stringValue = blocking
                ? "Recordings leave the camera out until you allow it. Click Allow Camera Access."
                : "macOS asks the first time you turn the camera on."
        case .denied:
            accessNote.stringValue = blocking
                ? "Recordings leave the camera out. Turn on Cornermark in System Settings > Privacy & Security > Camera."
                : "The camera needs it. Recording works without it."
        }
        accessButton.title = access == .notAsked ? "Allow Camera Access" : "Open System Settings"
        accessButton.variant = blocking ? .primary : .secondary
        accessButton.isHidden = access == .allowed
    }
}
