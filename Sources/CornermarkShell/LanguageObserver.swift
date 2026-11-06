import AppKit
import CornermarkDesign
import CornermarkL10n

/// Runs `handler` on the main thread each time the interface language changes, until it is released.
/// A window or panel keeps one and re-renders its text in `handler`. The handler has run by the time `L10n.setLanguage` returns.
final class LanguageObserver {
    private var token: NSObjectProtocol?

    init(_ handler: @escaping @MainActor () -> Void) {
        token = NotificationCenter.default.addObserver(forName: L10n.didChange, object: nil, queue: nil) { _ in
            MainActor.assumeIsolated(handler)
        }
    }

    deinit { if let token { NotificationCenter.default.removeObserver(token) } }
}

enum Numerals {
    /// A whole number written with the current locale's digits, never grouped: `7`, `07` with two digits, `٠٧` in Arabic.
    static func text(_ n: Int, minimumDigits: Int = 1) -> String {
        n.formatted(.number.locale(L10n.locale).grouping(.never).precision(.integerLength(minimumDigits...)))
    }
}

extension IconButton {
    /// Renames the button for sight and for assistive technology.
    func rename(_ label: String) {
        toolTip = label
        setAccessibilityLabel(label)
    }
}

extension NSWindow {
    /// Sets a new content view and resizes the window to `size`, keeping its top-left corner where it was.
    func replaceContent(_ view: NSView, fitting size: NSSize) {
        let topLeft = CGPoint(x: frame.minX, y: frame.maxY)
        contentView = view
        setContentSize(size)
        setFrameTopLeftPoint(topLeft)
    }
}
