import AppKit

/// Keys written as caps, one per key combination, such as `⌥←` and `⌥→`. It reads, it does not record: a key that can be changed
/// uses the shortcut recorder instead.
public final class KeyCaps: NSView {
    public let keys: [String]

    /// `spoken` names the keys in words for VoiceOver, which reads symbols such as ⌥ unevenly.
    public init(_ keys: [String], spoken: [String]? = nil) {
        self.keys = keys
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel((spoken ?? keys).joined(separator: ", "))
        frame.size = intrinsicContentSize
    }

    public required init?(coder: NSCoder) { fatalError("KeyCaps is created in code") }

    // The system face draws the key symbols at their designed size; the monospaced face falls back to small substitutes.
    static let style = DS.Text.label
    static let padding = DS.Space.s6
    static let gap = DS.Space.s4

    private func capWidth(_ key: String) -> CGFloat { max(ceil(Paint.width(of: key, Self.style)) + 2 * Self.padding, DS.Size.controlSmall) }

    public override var intrinsicContentSize: NSSize {
        NSSize(width: keys.map(capWidth).reduce(0, +) + CGFloat(max(keys.count - 1, 0)) * Self.gap, height: DS.Size.controlSmall)
    }

    public override func draw(_ dirtyRect: NSRect) {
        var x: CGFloat = 0
        for key in keys {
            let rect = CGRect(x: x, y: 0, width: capWidth(key), height: bounds.height)
            let path = NSBezierPath.continuous(rect, radius: DS.Radius.xs)
            Paint.fill(path, DS.Color.bgControl)
            Paint.strokeInside(path, DS.Color.border)
            Paint.text(key, Self.style, DS.Color.textPrimary, in: rect, alignment: .center)
            x = rect.maxX + Self.gap
        }
    }
}
