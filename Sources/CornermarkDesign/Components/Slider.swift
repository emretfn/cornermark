import AppKit

/// A horizontal slider drawn from tokens. Open so a view can subclass it to watch tracking; the value model stays NSSlider's, so
/// target/action, accessibility as a slider and lookups typed `as? NSSlider` keep working. The fill is neutral: accent is for selection
/// and the single primary action.
open class Slider: NSSlider {
    public enum Style: CaseIterable {
        /// A thin track and a round knob, for tight bars such as the image editor's property bar.
        case track
        /// A filled field as tall as a button. A press anywhere sets the value, the value is written inside, and `detents` show as ticks.
        case field
    }

    public var style = Style.track {
        didSet {
            guard oldValue != style else { return }
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    /// The text written inside a field, for the current value. A field without it shows only the fill.
    public var format: ((Double) -> String)? {
        didSet { needsDisplay = true }
    }

    /// The text a field shows for its value now.
    public var valueText: String? { format?(doubleValue) }

    /// Values a field marks with a tick and snaps to when a drag passes within 2% of the range of one.
    public var detents: [Double] = [] {
        didSet { needsDisplay = true }
    }

    /// Pins a field's look for specimens and tests. Real interaction is ignored while it is set.
    var forcedState: InteractionState? { didSet { needsDisplay = true } }

    private var isHovering = false { didSet { if oldValue != isHovering { needsDisplay = true } } }
    private var isDragging = false { didSet { if oldValue != isDragging { needsDisplay = true } } }

    open override class var cellClass: AnyClass? {
        get { SliderCell.self }
        set {}
    }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    public required init?(coder: NSCoder) { super.init(coder: coder) }

    open override var intrinsicContentSize: NSSize {
        NSSize(width: style == .field ? NSView.noIntrinsicMetric : super.intrinsicContentSize.width,
               height: style == .field ? DS.Size.control : DS.Size.controlSmall)
    }

    open override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    open override var isEnabled: Bool {
        didSet {
            if !isEnabled { isHovering = false }
            needsDisplay = true
        }
    }

    open override var doubleValue: Double {
        didSet { if style == .field { needsDisplay = true } }
    }

    open override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        isHovering = false
    }

    open override func mouseEntered(with event: NSEvent) { isHovering = isEnabled }
    open override func mouseExited(with event: NSEvent) { isHovering = false }

    /// Called once a press on the slider lets go, after the last action of the drag.
    open func trackingDidEnd() {}

    // MARK: Pointer

    open override func mouseDown(with event: NSEvent) {
        guard style == .field else {
            super.mouseDown(with: event)
            trackingDidEnd()
            return
        }
        guard isEnabled else { return }
        isDragging = true
        track(event)
    }

    open override func mouseDragged(with event: NSEvent) {
        guard style == .field else { return super.mouseDragged(with: event) }
        guard isDragging else { return }
        track(event)
    }

    open override func mouseUp(with event: NSEvent) {
        guard style == .field else { return super.mouseUp(with: event) }
        guard isDragging else { return }
        track(event)
        isDragging = false
        trackingDidEnd()
    }

    /// Sets the value under the pointer and sends the action. The pointer's place across the whole field is the value.
    private func track(_ event: NSEvent) {
        let x = convert(event.locationInWindow, from: nil).x
        let fraction = bounds.width > 0 ? min(max(x / bounds.width, 0), 1) : 0
        doubleValue = settled(minValue + Double(fraction) * (maxValue - minValue))
        sendAction(action, to: target)
    }

    /// A tick-mark slider lands on its marks; a free one lands on a detent it is near.
    func settled(_ value: Double) -> Double {
        if numberOfTickMarks > 0, allowsTickMarkValuesOnly { return closestTickMarkValue(toValue: value) }
        let reach = (maxValue - minValue) * 0.02
        return detents.first { abs($0 - value) <= reach } ?? value
    }

    // MARK: Keys

    /// Arrows step a field by a twentieth of its range, or a tick mark; Shift steps five times as far. Home and End go to the ends.
    open override func keyDown(with event: NSEvent) {
        guard style == .field, isEnabled else { return super.keyDown(with: event) }
        let far = event.modifierFlags.contains(.shift) && numberOfTickMarks == 0 ? 5.0 : 1.0
        switch event.keyCode {
        case 123, 125: _ = step(by: -far)
        case 124, 126: _ = step(by: far)
        case 115: set(minValue)
        case 119: set(maxValue)
        default: super.keyDown(with: event)
        }
    }

    /// One arrow press: a twentieth of the range, or one tick mark.
    private func step(by count: Double) -> Bool {
        guard isEnabled else { return false }
        let unit = numberOfTickMarks > 1 ? (maxValue - minValue) / Double(numberOfTickMarks - 1) : (maxValue - minValue) / 20
        set(doubleValue + unit * count)
        return true
    }

    private func set(_ value: Double) {
        let clamped = min(max(value, minValue), maxValue)
        doubleValue = numberOfTickMarks > 0 && allowsTickMarkValuesOnly ? closestTickMarkValue(toValue: clamped) : clamped
        sendAction(action, to: target)
        trackingDidEnd()
    }

    open override func isAccessibilityElement() -> Bool { true }
    open override func accessibilityRole() -> NSAccessibility.Role? { .slider }

    open override func accessibilityPerformIncrement() -> Bool { step(by: 1) }
    open override func accessibilityPerformDecrement() -> Bool { step(by: -1) }

    open override func accessibilityValueDescription() -> String? {
        super.accessibilityValueDescription() ?? format?(doubleValue)
    }

    // MARK: Drawing

    var fieldState: InteractionState {
        if let forcedState { return forcedState }
        if !isEnabled { return .disabled }
        if isDragging { return .pressed }
        return isHovering ? .hover : .normal
    }

    /// Where the fill ends, on a whole point.
    var edgeX: CGFloat {
        let span = maxValue - minValue
        let fraction = span > 0 ? min(max((doubleValue - minValue) / span, 0), 1) : 0
        return (bounds.width * CGFloat(fraction)).rounded()
    }

    /// Interior marks: the tick marks of a stepped slider, or the detents of a free one.
    var tickValues: [Double] {
        let marks = numberOfTickMarks > 0 ? (0..<numberOfTickMarks).map { tickMarkValue(at: $0) } : detents
        return marks.filter { $0 > minValue && $0 < maxValue }
    }

    open override func draw(_ dirtyRect: NSRect) {
        guard style == .field else { return super.draw(dirtyRect) }
        let state = fieldState
        let c = DS.Color.self
        let field = NSBezierPath.continuous(bounds, radius: DS.Radius.md)
        Paint.fill(field, state == .hover || state == .pressed ? c.bgControlHover : c.bgControl)
        NSGraphicsContext.saveGraphicsState()
        field.addClip()
        let edge = edgeX
        if edge > 0 { Paint.fill(NSBezierPath(rect: CGRect(x: 0, y: 0, width: edge, height: bounds.height)), c.bgControlActive) }
        let span = maxValue - minValue
        let tickHeight = DS.Space.s4 + 1
        for value in tickValues where span > 0 {
            let x = (bounds.width * CGFloat((value - minValue) / span)).rounded()
            Paint.fill(NSBezierPath(rect: CGRect(x: x, y: isFlipped ? bounds.maxY - tickHeight : 0, width: 1, height: tickHeight)),
                       state == .disabled ? c.border : c.borderStrong)
        }
        NSGraphicsContext.restoreGraphicsState()

        let layout = fieldLayout(state)
        let active = state == .hover || state == .pressed || isFocused
        for piece in layout.marker { Paint.fill(NSBezierPath(rect: piece), active ? c.textPrimary : c.textSecondary) }
        guard let text = layout.text else { return }
        Paint.text(text, DS.Text.readout, state == .disabled ? c.textDisabled : c.textPrimary, in: layout.textRect)
    }

    /// The value text and the edge marker of a field. The value sits at the field's right end and never moves. The marker stops short
    /// of it, so once the fill reaches the value the marker leaves only stubs above and below the text and the number stays clean at
    /// any fill. Every rect is on whole points.
    func fieldLayout(_ state: InteractionState) -> (text: String?, textRect: CGRect, marker: [CGRect]) {
        let text = format?(doubleValue)
        let width = text.map { Paint.width(of: $0, DS.Text.readout) } ?? 0
        let lineHeight = DS.Text.readout.lineHeight
        let textRect = CGRect(x: (bounds.maxX - DS.Space.s8 - width).rounded(), y: ((bounds.height - lineHeight) / 2).rounded(), width: width, height: lineHeight)
        let edge = edgeX
        guard state != .disabled, edge >= 2 else { return (text, textRect, []) }
        let inset = state == .pressed ? DS.Space.s4 : DS.Space.s6
        let marker = CGRect(x: edge - 2, y: inset, width: 2, height: bounds.height - 2 * inset)
        let keepOut = textRect.insetBy(dx: -DS.Space.s4, dy: 0)
        guard text != nil, marker.maxX > keepOut.minX, marker.minX < keepOut.maxX else { return (text, textRect, [marker]) }
        let pieces = [CGRect(x: marker.minX, y: marker.minY, width: 2, height: keepOut.minY - marker.minY),
                      CGRect(x: marker.minX, y: keepOut.maxY, width: 2, height: marker.maxY - keepOut.maxY)]
        return (text, textRect, pieces.filter { $0.height > 0 })
    }

    private var isFocused: Bool { window?.firstResponder === self && window?.isKeyWindow == true }

    open override func becomeFirstResponder() -> Bool {
        needsDisplay = true
        return super.becomeFirstResponder()
    }

    open override func resignFirstResponder() -> Bool {
        needsDisplay = true
        return super.resignFirstResponder()
    }

    open override func drawFocusRingMask() {
        NSBezierPath.continuous(bounds, radius: style == .field ? DS.Radius.md : DS.Radius.sm).fill()
    }
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
