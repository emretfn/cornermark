import AppKit

public struct TextStyle {
    public enum Design { case `default`, monospaced, rounded }

    public let size: CGFloat
    public let lineHeight: CGFloat
    public let weight: NSFont.Weight
    public let design: Design

    public init(size: CGFloat, lineHeight: CGFloat, weight: NSFont.Weight, design: Design = .default) {
        self.size = size
        self.lineHeight = lineHeight
        self.weight = weight
        self.design = design
    }

    public var font: NSFont {
        switch design {
        case .default:
            return .systemFont(ofSize: size, weight: weight)
        case .monospaced:
            return .monospacedSystemFont(ofSize: size, weight: weight)
        case .rounded:
            let base = NSFont.systemFont(ofSize: size, weight: weight)
            return base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) } ?? base
        }
    }

    public func attributes(color: NSColor) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = lineHeight
        paragraph.maximumLineHeight = lineHeight
        // A fixed line height puts the spare space above the text; the offset splits it evenly so text centres in its line box.
        let f = font
        let offset = (lineHeight - (f.ascender - f.descender + f.leading)) / 2
        return [.font: f, .foregroundColor: color, .paragraphStyle: paragraph, .baselineOffset: offset]
    }
}

extension DS {
    public enum Text {
        public static let title = TextStyle(size: 20, lineHeight: 26, weight: .semibold)
        public static let heading = TextStyle(size: 15, lineHeight: 20, weight: .semibold)
        public static let body = TextStyle(size: 13, lineHeight: 18, weight: .regular)
        public static let bodyStrong = TextStyle(size: 13, lineHeight: 18, weight: .medium)
        public static let label = TextStyle(size: 12, lineHeight: 16, weight: .medium)
        public static let caption = TextStyle(size: 11, lineHeight: 14, weight: .regular)
        public static let captionStrong = TextStyle(size: 11, lineHeight: 14, weight: .semibold)
        public static let readout = TextStyle(size: 11, lineHeight: 14, weight: .medium, design: .monospaced)
        public static let readoutLarge = TextStyle(size: 20, lineHeight: 26, weight: .semibold, design: .monospaced)
        public static let numeral = TextStyle(size: 96, lineHeight: 96, weight: .semibold, design: .rounded)
    }
}
