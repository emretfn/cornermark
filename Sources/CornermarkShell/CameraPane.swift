import AppKit
import CornermarkCapture
import CornermarkCore
import CornermarkDesign
import CornermarkL10n

extension AppEnvironment {
    static let cameraPaneURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!
}

extension CameraBubble.Shape {
    var title: String {
        switch self {
        case .circle: return tr("Circle")
        case .square: return tr("Square")
        case .rectangle: return tr("Rectangle")
        }
    }
    var symbol: String {
        switch self {
        case .circle: return "circle"
        case .square: return "square"
        case .rectangle: return "rectangle"
        }
    }
}

extension CameraBubble.Size {
    var title: String {
        switch self {
        case .small: return tr("Small")
        case .medium: return tr("Medium", context: "size")
        case .large: return tr("Large")
        }
    }
}

extension CameraBubble {
    /// The places the Camera pane offers. A recording starts in a corner; the video editor can move the bubble to any cell later.
    static let paneCorners: [GridPosition] = [.bottomLeft, .bottomRight, .topLeft, .topRight]
}

final class CameraPane: SettingsPane {
    override var paneID: String { "camera" }
    override var paneTitle: String { tr("Camera") }
    override var symbol: String { "web.camera" }
    private let show = Form.checkbox(id: "camera.show")
    private let shape = Segments(symbols: CameraBubble.Shape.allCases.map(\.symbol), labels: CameraBubble.Shape.allCases.map(\.title), size: .small,
                                 tileWidth: DS.Size.control)
    private let size = Form.popup(id: "camera.size")
    private let corner = Form.popup(id: "camera.corner")
    private let mirror = Form.checkbox(id: "camera.mirror")
    private let accessStatus = NSTextField.label("", style: DS.Text.bodyStrong, color: DS.Color.textPrimary)
    private let accessDot = StatusDot()
    private let accessNote = Form.caption("")
    private let accessButton = Button(title: "", variant: .secondary, size: .small)

    override func buildForm() -> FormPage {
        for (i, s) in CameraBubble.Shape.allCases.enumerated() {
            shape.setImage(NSImage(systemSymbolName: s.symbol, accessibilityDescription: s.title), forSegment: i)
            shape.setToolTip(s.title, forSegment: i)
        }
        size.setTitles(CameraBubble.Size.allCases.map(\.title))
        corner.setTitles(CameraBubble.paneCorners.map(\.title))
        shape.setAccessibilityIdentifier("camera.shape")
        shape.setAccessibilityLabel(tr("Shape"))
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
            change { $0.recording.camera.position = CameraBubble.paneCorners[i] }
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
                Form.row(title: tr("Show camera"), caption: Form.caption(tr("Shows you in a bubble over the recording. Record Project keeps the camera as its own track, so you can still change it later.")),
                         control: show),
            ]),
            .init(tr("Bubble"), rows: [
                Form.row(title: tr("Shape"), control: Form.hstack([shape])),
                Form.row(title: tr("Size"), control: size),
                Form.row(title: tr("Position"), caption: Form.caption(tr("You can also drag the bubble to another corner while recording.")), control: corner),
                Form.row(title: tr("Mirror camera"), caption: Form.caption(tr("Shows you the way a mirror does. Turn it off to make text behind you readable.")), control: mirror),
            ], footer: tr("While recording, click the bubble to fill the recording with the camera, and click again to bring the bubble back.")),
            .init(rows: [
                Form.row(title: tr("Camera access"), caption: accessNote, control: Form.hstack([accessDot, accessStatus, accessButton], spacing: DS.Space.s6)),
            ]),
        ])
    }

    override func update() {
        let c = settings.recording.camera
        show.state = c.isVisible ? .on : .off
        shape.selectedSegment = CameraBubble.Shape.allCases.firstIndex(of: c.shape) ?? 0
        size.selectItem(at: CameraBubble.Size.allCases.firstIndex(of: c.size) ?? 0)
        corner.selectItem(at: CameraBubble.paneCorners.firstIndex(of: c.position) ?? 0)
        mirror.state = c.isMirrored ? .on : .off
        ([shape, size, corner, mirror] as [NSControl]).forEach { $0.isEnabled = c.isVisible }
        let access = ctx.env.cameraAccess()
        let blocking = access != .allowed && c.isVisible
        switch access {
        case .allowed: accessStatus.stringValue = tr("Allowed")
        case .notAsked: accessStatus.stringValue = tr("Not asked yet")
        case .denied: accessStatus.stringValue = tr("Not allowed")
        }
        accessStatus.textColor = access == .allowed ? DS.Color.successText : blocking ? DS.Color.dangerText : DS.Color.textSecondary
        accessDot.color = accessStatus.textColor ?? DS.Color.textSecondary
        accessNote.textColor = blocking ? DS.Color.dangerText : DS.Color.textSecondary
        switch access {
        case .allowed:
            accessNote.stringValue = tr("Cornermark uses the camera only while it records with the camera on.")
        case .notAsked:
            accessNote.stringValue = blocking
                ? tr("Recordings leave the camera out until you allow it. Click Allow Camera Access.")
                : tr("macOS asks the first time you turn the camera on.")
        case .denied:
            accessNote.stringValue = blocking
                ? tr("Recordings leave the camera out. Turn on Cornermark in System Settings > Privacy & Security > Camera.")
                : tr("The camera needs it. Recording works without it.")
        }
        accessButton.relabel(access == .notAsked ? tr("Allow Camera Access") : tr("Open System Settings"))
        accessButton.variant = blocking ? .primary : .secondary
        accessButton.isHidden = access == .allowed
    }
}
