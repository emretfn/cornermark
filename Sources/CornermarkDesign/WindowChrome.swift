import AppKit

/// Windows whose first row of controls lives under a transparent title bar instead of in toolbar items.
public enum WindowChrome {
    /// Gives `window` the taller title bar an empty toolbar brings and measures the row that sits on the window buttons' centre line.
    /// `leading` is where a row's first control starts, s16 past the zoom button. Both are decided by the system, so they are read
    /// from the live window buttons rather than assumed.
    @MainActor
    public static func titleRowMetrics(for window: NSWindow, toolbarIdentifier: String) -> (height: CGFloat, leading: CGFloat) {
        window.toolbar = NSToolbar(identifier: toolbarIdentifier)
        let leading = (window.standardWindowButton(.zoomButton)?.frame.maxX ?? 68) + DS.Space.s16
        window.layoutIfNeeded()
        let buttonCentre = window.standardWindowButton(.zoomButton).flatMap { button -> CGFloat? in
            guard let frame = window.contentView?.superview else { return nil }
            let rect = button.convert(button.bounds, to: frame)
            return frame.isFlipped ? rect.midY : frame.bounds.height - rect.midY
        }
        return (2 * (buttonCentre ?? 26), leading)
    }
}
