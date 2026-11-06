import AppKit
import CornermarkCore
import CornermarkDesign
import CornermarkL10n

/// How the camera moves in this video, opened from Animation Settings in the zoom panel: the length of a move into or out of a zoom,
/// and how a Follow Cursor zoom keeps up with the pointer. It floats over the settings column, leaving the preview whole, and applies
/// to every zoom.
final class ZoomAnimationPanel: Surface {
    static let width: CGFloat = 288
    static let inset = DS.Space.s32

    /// The key folds one slider drag into one undo step.
    var onChange: (ZoomAnimation, CoalescingKey?) -> Void = { _, _ in }
    var onSliderEnd: () -> Void = {}
    var onClose: () -> Void = {}

    private let title = NSTextField.label(tr("Animation Settings"), style: DS.Text.heading, color: DS.Color.textPrimary)
    private let scope = NSTextField.label(tr("Applies to every zoom in this video."), style: DS.Text.caption, color: DS.Color.textSecondary)
    private let moveHeading = NSTextField.label(tr("Zoom in and out"), style: DS.Text.captionStrong, color: DS.Color.textPrimary)
    private let followHeading = NSTextField.label(tr("Follow Cursor"), style: DS.Text.captionStrong, color: DS.Color.textPrimary)
    private let duration = TrackingSlider()
    private let deadZone = TrackingSlider()
    private let settle = TrackingSlider()
    private let moveNote = ZoomAnimationPanel.note(tr("How long the camera takes to zoom in or out."))
    private let followNote = ZoomAnimationPanel.note(tr("The pointer moves freely inside the hold area. Once it leaves, the camera catches up in about this time."))
    private let reset = Button(title: tr("Reset to Defaults"), variant: .ghost, size: .small)
    private let done = Button(title: tr("Done"), variant: .secondary, size: .small)
    private(set) var animation = ZoomAnimation()

    /// Catch-up is shown as the seconds the camera takes to settle, so all three read as a feel rather than a rate.
    static let settleRange = 0.3...1.5

    init() {
        super.init(style: .floating, shadowInset: Self.inset)
        build()
    }

    required init?(coder: NSCoder) { fatalError("ZoomAnimationPanel is created in code") }

    var firstControl: NSView { duration }

    func show(_ animation: ZoomAnimation) {
        self.animation = animation
        duration.doubleValue = animation.duration
        duration.setAccessibilityValueDescription(Self.spoken(animation.duration))
        deadZone.doubleValue = animation.deadZone
        deadZone.setAccessibilityValueDescription(tr("{percent} of the view", ["percent": Self.percent(animation.deadZone)]))
        let settling = min(max(animation.settleTime, Self.settleRange.lowerBound), Self.settleRange.upperBound)
        settle.doubleValue = settling
        settle.setAccessibilityValueDescription(Self.spoken(animation.settleTime))
        reset.isEnabled = animation != ZoomAnimation()
    }

    static func seconds(_ s: Double) -> String { tr("{value} s", ["value": Digits.fixed(s, 2)]) }
    static func percent(_ v: Double) -> String { Digits.percent(v) }
    static func spoken(_ s: Double) -> String { tr("{value} seconds", ["value": Digits.fixed(s, 2)]) }

    private static func note(_ text: String) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = DS.Text.caption.font
        field.textColor = DS.Color.textSecondary
        field.preferredMaxLayoutWidth = width - 2 * DS.Space.s16
        return field
    }

    private func build() {
        func configure(_ s: TrackingSlider, _ range: ClosedRange<Double>, id: String, label: String, action: Selector) {
            s.minValue = range.lowerBound
            s.maxValue = range.upperBound
            s.isContinuous = true
            s.setAccessibilityIdentifier(id)
            s.setAccessibilityLabel(label)
            s.target = self
            s.action = action
            s.onTrackingEnd = { [unowned self] in onSliderEnd() }
        }
        configure(duration, ZoomAnimation.durationRange, id: "video.zoomAnimation.duration", label: tr("Zoom move duration"), action: #selector(durationMoved))
        configure(deadZone, ZoomAnimation.deadZoneRange, id: "video.zoomAnimation.holdArea", label: tr("Hold area"), action: #selector(deadZoneMoved))
        configure(settle, Self.settleRange, id: "video.zoomAnimation.catchUp", label: tr("Catch-up time"), action: #selector(settleMoved))
        duration.toolTip = tr("Seconds for each move into or out of a zoom. Zooms closer than two moves hand over without returning to 100%.")
        deadZone.toolTip = tr("The share of the view the pointer moves in before a Follow Cursor zoom pans.")
        settle.toolTip = tr("Seconds a Follow Cursor zoom takes to catch up after the pointer leaves the hold area.")
        title.setAccessibilityIdentifier("video.zoomAnimation.title")
        moveNote.setAccessibilityIdentifier("video.zoomAnimation.moveNote")
        followNote.setAccessibilityIdentifier("video.zoomAnimation.followNote")
        reset.setAccessibilityIdentifier("video.zoomAnimation.reset")
        reset.onPress { [unowned self] in
            show(ZoomAnimation())
            onChange(ZoomAnimation(), nil)
        }
        done.setAccessibilityIdentifier("video.zoomAnimation.done")
        done.onPress { [unowned self] in onClose() }

        duration.format = { Self.seconds(($0 * 100).rounded() / 100) }
        deadZone.format = { Self.percent($0) }
        settle.format = { Self.seconds(($0 * 100).rounded() / 100) }
        let durationRow = row(tr("Duration"), [duration])
        let holdRow = row(tr("Hold area"), [deadZone])
        let catchUpRow = row(tr("Catch-up"), [settle])
        let rule = Separator(axis: .horizontal)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.fittingSizeCompression, for: .horizontal)
        let buttons = NSStackView(views: [reset, spacer, done])
        buttons.spacing = DS.Space.s8

        let stack = NSStackView(views: [title, scope, moveHeading, durationRow, moveNote, rule, followHeading, holdRow, catchUpRow, followNote, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = DS.Space.s8
        stack.setCustomSpacing(DS.Space.s4, after: title)
        stack.setCustomSpacing(DS.Space.s16, after: scope)
        stack.setCustomSpacing(DS.Space.s4, after: durationRow)
        stack.setCustomSpacing(DS.Space.s12, after: moveNote)
        stack.setCustomSpacing(DS.Space.s12, after: rule)
        stack.setCustomSpacing(DS.Space.s4, after: catchUpRow)
        stack.setCustomSpacing(DS.Space.s16, after: followNote)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        let pad = Self.inset + DS.Space.s16
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.width + 2 * Self.inset),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: pad),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -pad),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -pad),
        ])
        for v in [durationRow, holdRow, catchUpRow, rule, moveNote, followNote, buttons] {
            v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(tr("Animation Settings"))
        setAccessibilityIdentifier("video.zoomAnimation.panel")
    }

    private func row(_ label: String, _ views: [NSView]) -> NSStackView {
        let name = NSTextField.label(label, style: DS.Text.label, color: DS.Color.textSecondary)
        name.widthAnchor.constraint(equalToConstant: InspectorView.labelColumn).isActive = true
        let row = NSStackView(views: [name] + views)
        row.spacing = DS.Space.s8
        row.alignment = .centerY
        return row
    }

    private func changed(_ next: ZoomAnimation, _ key: String) {
        guard next != animation else { return }
        show(next)
        onChange(next, CoalescingKey(key))
    }

    @objc private func durationMoved() {
        var next = animation
        // Hundredths of a second, the precision the readout shows.
        next.duration = (duration.doubleValue * 100).rounded() / 100
        changed(next, "zoomAnimation.duration")
    }

    @objc private func deadZoneMoved() {
        var next = animation
        next.deadZone = (deadZone.doubleValue * 20).rounded() / 20
        changed(next, "zoomAnimation.deadZone")
    }

    @objc private func settleMoved() {
        var next = animation
        let seconds = (settle.doubleValue * 100).rounded() / 100
        // The default's rate settles in 0.678 s, which the readout rounds to 0.68; landing there gives the default back exactly.
        next.driftRate = abs(seconds - ZoomAnimation().settleTime) < 0.005 ? ZoomAnimation().driftRate : ZoomAnimation.driftRate(settling: seconds)
        changed(next, "zoomAnimation.catchUp")
    }
}

extension NSView {
    /// Fades a floating panel in over 0.20 s, growing from 96% about `corner` in its layer's own points, or out over 0.15 s. Reduced
    /// motion keeps only the fade. `stillHidden` says, once the fade out ends, whether the panel should leave the window.
    func fade(visible on: Bool, growsFrom corner: CGPoint, stillHidden: @escaping () -> Bool) {
        guard let layer = layer ?? { wantsLayer = true; return layer }() else { return }
        guard window?.isVisible == true else { isHidden = !on; return }
        isHidden = false
        layer.removeAllAnimations()
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = on ? 0 : 1
        fade.toValue = on ? 1 : 0
        fade.duration = on ? DS.Motion.Duration.base : DS.Motion.Duration.fast
        fade.timingFunction = DS.Motion.Curve.easeOut
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in if !on, stillHidden() { self?.isHidden = true } }
        layer.add(fade, forKey: "fade")
        if on && !DS.Motion.isReduced {
            let grow = CABasicAnimation(keyPath: "transform")
            var t = CATransform3DMakeTranslation(corner.x, corner.y, 0)
            t = CATransform3DScale(t, DS.Motion.enterScale, DS.Motion.enterScale, 1)
            t = CATransform3DTranslate(t, -corner.x, -corner.y, 0)
            grow.fromValue = t
            grow.toValue = CATransform3DIdentity
            grow.duration = DS.Motion.Duration.base
            grow.timingFunction = DS.Motion.Curve.easeOut
            layer.add(grow, forKey: "grow")
        }
        CATransaction.commit()
    }
}
