import AppKit

public final class Separator: NSView {
    /// The direction the line runs: a horizontal separator divides rows, a vertical one divides columns.
    public enum Axis { case horizontal, vertical }

    public let axis: Axis
    private static let thickness: CGFloat = 1

    public init(axis: Axis) {
        self.axis = axis
        super.init(frame: .zero)
        frame.size = NSSize(width: axis == .vertical ? Self.thickness : 0, height: axis == .horizontal ? Self.thickness : 0)
    }

    public required init?(coder: NSCoder) { fatalError("Separator is created in code") }

    public override var intrinsicContentSize: NSSize {
        axis == .horizontal ? NSSize(width: NSView.noIntrinsicMetric, height: Self.thickness)
                            : NSSize(width: Self.thickness, height: NSView.noIntrinsicMetric)
    }

    public override func draw(_ dirtyRect: NSRect) {
        DS.Color.separator.setFill()
        bounds.fill()
    }
}
