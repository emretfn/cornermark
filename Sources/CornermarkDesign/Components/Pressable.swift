import AppKit

/// The one interaction model. Components read their look from a table keyed on this and their variant, never from parallel flags.
public enum InteractionState: Equatable, CaseIterable {
    case normal, hover, pressed, disabled
}

/// Colours a control takes in one state. `fill` is nil for controls that draw nothing behind their content.
struct ButtonAppearance {
    var fill: NSColor?
    var text: NSColor
    var border: NSColor? = nil
}

/// Base of `Button` and `IconButton`. It stays an NSButton so target/action, `performClick`, accessibility and lookups
/// typed `as? NSButton` keep working, but it draws everything itself: stock bezels turn grey whenever the window is not
/// key, which a non-activating capture panel almost always is.
///
/// Public only because Swift requires a public class's superclass to be public; subclassing it is not part of the API.
public class Pressable: NSButton {
    /// Pins the look for specimens and tests. Real interaction is ignored while it is set.
    var forcedState: InteractionState? { didSet { needsDisplay = true } }

    private var isHovering = false { didSet { if oldValue != isHovering { needsDisplay = true } } }

    public var interactionState: InteractionState {
        if let forcedState { return forcedState }
        if !isEnabled { return .disabled }
        if isHighlighted { return .pressed }
        return isHovering ? .hover : .normal
    }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setUp()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUp()
    }

    private func setUp() {
        isBordered = false
        setButtonType(.momentaryPushIn)
        focusRingType = .exterior
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    /// The control's silhouette, used for its fill and its focus ring.
    func shape(in rect: CGRect) -> NSBezierPath { .continuous(rect, radius: DS.Radius.md) }

    /// Draws the control in `state`. The press scale is already applied.
    func paint(_ state: InteractionState) {}

    public override var isEnabled: Bool {
        didSet {
            if !isEnabled { isHovering = false }
            needsDisplay = true
        }
    }

    public override var isHighlighted: Bool { didSet { needsDisplay = true } }

    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        isHovering = false
    }

    public override func mouseEntered(with event: NSEvent) { isHovering = true }
    public override func mouseExited(with event: NSEvent) { isHovering = false }

    public override final func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let state = interactionState
        context.saveGState()
        if state == .pressed, !DS.Motion.isReduced {
            context.translateBy(x: bounds.midX, y: bounds.midY)
            context.scaleBy(x: DS.Motion.pressScale, y: DS.Motion.pressScale)
            context.translateBy(x: -bounds.midX, y: -bounds.midY)
        }
        paint(state)
        context.restoreGState()
    }

    public override func drawFocusRingMask() { shape(in: bounds).fill() }
    public override var focusRingMaskBounds: NSRect { bounds }
}
