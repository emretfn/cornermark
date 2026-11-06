import AppKit
import CornermarkCore
import CornermarkDesign

/// What blurs as it moves and how long the shutter stays open. Export draws it; the preview shows it while paused.
final class MotionBlurPanel: SettingsPanel {
    /// The key folds one slider drag into one undo step.
    var onChange: (MotionBlur, CoalescingKey?) -> Void = { _, _ in }
    private(set) var blur = MotionBlur()
    private let scope = Segments(labels: MotionBlur.Scope.allCases.map(MotionBlurPanel.title), width: SettingsPanel.inner)
    private var intensity: TrackingSlider!
    private var note: NSTextField!
    private var previewCaption: NSTextField!

    static func title(_ scope: MotionBlur.Scope) -> String {
        switch scope {
        case .off: return "Off"
        case .zooms: return "Zooms"
        case .zoomsAndCursor: return "Zooms + cursor"
        }
    }

    static func explanation(_ scope: MotionBlur.Scope) -> String {
        switch scope {
        case .off: return "Every frame is sharp."
        case .zooms: return "Zooms and pans blur as they move. The cursor blurs only when a zoom carries it."
        case .zoomsAndCursor: return "Zooms, pans and a fast cursor blur as they move."
        }
    }

    static let previewNote = "What was recorded stays sharp. The preview shows blur while paused, and the export always includes it."

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        scope.setAccessibilityIdentifier("video.blur.scope")
        scope.setAccessibilityLabel("Motion blur")
        for (i, s) in MotionBlur.Scope.allCases.enumerated() { scope.setToolTip(Self.explanation(s), forSegment: i) }
        scope.target = self
        scope.action = #selector(picked)
        intensity = slider(id: "video.blur.intensity", label: "Intensity", range: MotionBlur.shutterRange, action: #selector(slid))
        intensity.toolTip = "How long the shutter stays open in each frame. 180° is half a frame, 360° a whole one."
        intensity.format = { Self.degrees(($0 / 5).rounded() * 5) }
        let intensityRow = row("Intensity", [intensity])
        intensityRow.widthAnchor.constraint(equalToConstant: Self.inner).isActive = true
        note = caption(Self.explanation(blur.scope), id: "video.blur.note")
        previewCaption = caption(Self.previewNote, id: "video.blur.preview")
        add([scope, note, intensityRow, previewCaption])
        stack.setCustomSpacing(DS.Space.s8, after: scope)
        stack.setCustomSpacing(DS.Space.s16, after: note)
        stack.setCustomSpacing(DS.Space.s16, after: intensityRow)
        setAccessibilityIdentifier("video.blur")
    }

    required init?(coder: NSCoder) { fatalError("MotionBlurPanel is created in code") }

    func show(_ blur: MotionBlur) {
        self.blur = blur
        scope.selectedSegment = MotionBlur.Scope.allCases.firstIndex(of: blur.scope) ?? 0
        intensity.doubleValue = blur.shutterAngle
        intensity.setAccessibilityValueDescription("\(Int(blur.shutterAngle.rounded())) degrees")
        note.stringValue = Self.explanation(blur.scope)
        let on = blur.scope != .off
        intensity.isEnabled = on
        // It describes blur that is on; with blur off it would promise blur the export does not have.
        previewCaption.isHidden = !on
        setLabelsEnabled(on)
    }

    static func degrees(_ angle: Double) -> String { "\(Int(angle.rounded()))°" }

    @objc private func picked() {
        var next = blur
        next.scope = MotionBlur.Scope.allCases[max(scope.selectedSegment, 0)]
        guard next != blur else { return }
        show(next)
        onChange(next, nil)
    }

    @objc private func slid() {
        var next = blur
        // Whole steps of 5° read cleanly and leave room to fine-tune.
        next.shutterAngle = (intensity.doubleValue / 5).rounded() * 5
        guard next != blur else { return }
        show(next)
        onChange(next, CoalescingKey("blur.shutter"))
    }
}
