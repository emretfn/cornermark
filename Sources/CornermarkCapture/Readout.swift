import AppKit
import CornermarkDesign
import CornermarkL10n

/// Numbers an overlay shows, written the way the current language writes them. They read out a size or a position, so they are never grouped.
enum Readout {
    static func number(_ value: Int) -> String { value.formatted(.number.grouping(.never).locale(L10n.locale)) }

    /// A selection's size, such as "1920 × 1080".
    static func size(width: CGFloat, height: CGFloat) -> String {
        tr("{width} × {height}", ["width": number(Int(width.rounded())), "height": number(Int(height.rounded()))])
    }

    /// A pointer position, such as "412, 96".
    static func point(x: Int, y: Int) -> String { tr("{x}, {y}", ["x": number(x), "y": number(y)]) }

    /// What a person typed into a size field. Digits typed on any keyboard count, so a field shown in Arabic digits reads back.
    static func parse(_ text: String) -> Double? {
        let ascii = text.trimmingCharacters(in: .whitespaces).map { $0.isASCII ? String($0) : $0.wholeNumberValue.map(String.init) ?? String($0) }
        return Double(ascii.joined())
    }
}

/// The frames a panel was laid out with, left to right. A panel places its controls with frames, so it keeps these and writes them
/// mirrored when its direction is right to left, which keeps the layout code in one direction.
struct LeftToRightFrames {
    private var frames: [ObjectIdentifier: CGRect] = [:]

    /// Remembers where each subview of `host` is now, as left to right.
    mutating func record(in host: NSView) {
        for view in host.subviews { record(view, in: host) }
    }

    /// Remembers one subview's frame, which `host` may already have mirrored.
    mutating func record(_ view: NSView, in host: NSView) {
        frames[ObjectIdentifier(view)] = host.isRightToLeft ? host.mirrored(view.frame) : view.frame
    }

    func apply(to host: NSView) {
        for view in host.subviews {
            if let frame = frames[ObjectIdentifier(view)] { view.frame = host.mirrored(frame) }
        }
    }
}
