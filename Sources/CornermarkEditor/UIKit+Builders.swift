import AppKit
import CornermarkDesign
import CornermarkL10n
import ObjectiveC

/// Closure-backed target so controls are wired where they are created.
final class ActionTarget: NSObject {
    let handler: (NSControl) -> Void
    init(_ handler: @escaping (NSControl) -> Void) { self.handler = handler }
    @objc func fire(_ sender: NSControl) { handler(sender) }
}

final class MenuTarget: NSObject {
    let handler: () -> Void
    init(_ handler: @escaping () -> Void) { self.handler = handler }
    @objc func fire(_ sender: Any?) { handler() }
}

extension NSMenuItem {
    convenience init(title: String, handler: @escaping () -> Void) {
        let target = MenuTarget(handler)
        self.init(title: title, action: #selector(MenuTarget.fire(_:)), keyEquivalent: "")
        self.target = target
        representedObject = target
    }
}

private var actionKey: UInt8 = 0

extension NSControl {
    @discardableResult
    func onAction(_ handler: @escaping (NSControl) -> Void) -> Self {
        let target = ActionTarget(handler)
        objc_setAssociatedObject(self, &actionKey, target, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        self.target = target
        action = #selector(ActionTarget.fire(_:))
        return self
    }

    @discardableResult
    func identified(_ id: String) -> Self {
        setAccessibilityIdentifier(id)
        return self
    }
}

/// A slider that reports the end of a drag, so a run of value changes can close one undo step.
final class TrackingSlider: Slider {
    var onTrackingEnd: (() -> Void)?

    override func trackingDidEnd() { onTrackingEnd?() }
}

/// A bar background that follows light and dark mode.
public class BarView: NSView {
    public enum Edge { case top, bottom, left }
    public var edge: Edge = .bottom

    public override init(frame: NSRect) { super.init(frame: frame) }
    public required init?(coder: NSCoder) { fatalError() }

    public override func draw(_ dirtyRect: NSRect) {
        DS.Color.bgSurface.setFill()
        bounds.fill()
        DS.Color.separator.setFill()
        switch edge {
        case .bottom: NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
        case .top: NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
        case .left: NSRect(x: isRightToLeft ? bounds.width - 1 : 0, y: 0, width: 1, height: bounds.height).fill()
        }
    }
}

/// Where a number that follows its control ends: against the trailing edge, whichever side that is.
var trailingAlignment: NSTextAlignment { L10n.isRightToLeft ? .left : .right }

enum UI {
    static func caption(_ text: String) -> NSTextField {
        let f = NSTextField.label(text, style: DS.Text.caption, color: DS.Color.textSecondary)
        f.setContentCompressionResistancePriority(.required, for: .horizontal)
        return f
    }

    static func valueLabel(width: CGFloat = 34) -> NSTextField {
        let f = NSTextField.label("", style: DS.Text.readout, color: DS.Color.textSecondary)
        f.alignment = trailingAlignment
        f.widthAnchor.constraint(equalToConstant: width).isActive = true
        return f
    }

    static func slider(_ range: ClosedRange<Double>, width: CGFloat? = 110, id: String) -> TrackingSlider {
        let s = TrackingSlider(value: range.lowerBound, minValue: range.lowerBound, maxValue: range.upperBound, target: nil, action: nil)
        s.controlSize = .small
        s.isContinuous = true
        if let width { s.widthAnchor.constraint(equalToConstant: width).isActive = true }
        s.setAccessibilityIdentifier(id)
        return s
    }

    static func button(symbol name: String, tip: String, id: String) -> IconButton {
        let b = IconButton(symbol: name, label: tip, size: .small)
        b.setAccessibilityIdentifier(id)
        return b
    }

    static func hstack(_ views: [NSView], spacing: CGFloat = DS.Space.s6) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = .horizontal
        s.alignment = .centerY
        s.spacing = spacing
        return s
    }

    static func vstack(_ views: [NSView], spacing: CGFloat = DS.Space.s12) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = .vertical
        s.alignment = .leading
        s.spacing = spacing
        return s
    }
}


import CornermarkCore

extension RGBA {
    var nsColor: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: a) }
    init(_ color: NSColor) {
        let c = color.usingColorSpace(.sRGB) ?? color
        self.init(Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent), Double(c.alphaComponent))
    }
    func isClose(to o: RGBA) -> Bool { abs(r - o.r) + abs(g - o.g) + abs(b - o.b) < 0.02 }
}

/// A round colour chip that shows a ring when it matches the current colour.
final class SwatchButton: NSButton {
    var color: RGBA
    var isCurrent: () -> Bool = { false }

    init(color: RGBA, size: CGFloat = DS.Size.controlSmall) {
        self.color = color
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        isBordered = false
        title = ""
        setButtonType(.momentaryChange)
        widthAnchor.constraint(equalToConstant: size).isActive = true
        heightAnchor.constraint(equalToConstant: size).isActive = true
        toolTip = String(format: "#%02X%02X%02X", Int(color.r * 255), Int(color.g * 255), Int(color.b * 255))
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let chip = NSBezierPath(ovalIn: bounds.insetBy(dx: 3, dy: 3))
        color.nsColor.setFill()
        chip.fill()
        DS.Color.imageOutline.setStroke()
        chip.lineWidth = 1
        chip.stroke()
        if isCurrent() {
            DS.Color.accentMark.setStroke()
            let ring = NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1))
            ring.lineWidth = 2
            ring.stroke()
        }
    }
}
