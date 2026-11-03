import AppKit

/// A horizontal slider drawn from tokens. Open so a view can subclass it to watch tracking; the value model stays NSSlider's.
/// The fill is neutral: accent is for selection and the single primary action.
open class Slider: NSSlider {
    open override class var cellClass: AnyClass? {
        get { SliderCell.self }
        set {}
    }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    public required init?(coder: NSCoder) { super.init(coder: coder) }

    open override var intrinsicContentSize: NSSize {
        NSSize(width: super.intrinsicContentSize.width, height: DS.Size.controlSmall)
    }

    open override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    open override var isEnabled: Bool {
        didSet { needsDisplay = true }
    }

    open override func drawFocusRingMask() { NSBezierPath.continuous(bounds, radius: DS.Radius.sm).fill() }
    open override var focusRingMaskBounds: NSRect { bounds }
}

final class SliderCell: NSSliderCell {
    static let trackHeight: CGFloat = 3
    static let knobDiameter: CGFloat = 14

    override var knobThickness: CGFloat { Self.knobDiameter }

    override func drawBar(inside rect: NSRect, flipped: Bool) {
        let centre = controlView?.bounds.midY ?? rect.midY
        let track = CGRect(x: rect.minX, y: centre - Self.trackHeight / 2, width: rect.width, height: Self.trackHeight)
        let enabled = isEnabled
        Paint.fill(NSBezierPath.continuous(track, radius: Self.trackHeight / 2), DS.Color.bgControlActive)

        let travel = knobRect(flipped: flipped).midX - track.minX
        let filled = CGRect(x: track.minX, y: track.minY, width: max(travel, 0), height: track.height)
        if filled.width > 0 {
            Paint.fill(NSBezierPath.continuous(filled, radius: Self.trackHeight / 2), enabled ? DS.Color.textSecondary : DS.Color.textDisabled)
        }
    }

    override func drawKnob(_ knobRect: NSRect) {
        let centre = controlView?.bounds.midY ?? knobRect.midY
        let d = Self.knobDiameter
        let knob = CGRect(x: knobRect.midX - d / 2, y: centre - d / 2, width: d, height: d)
        let path = NSBezierPath(ovalIn: knob)
        if isEnabled {
            DS.Elevation.raised.draw(path, fill: DS.Color.bgRaised)
            Paint.strokeInside(path, DS.Color.borderStrong)
        } else {
            Paint.fill(path, DS.Color.bgControl)
            Paint.strokeInside(path, DS.Color.border)
        }
    }
}
