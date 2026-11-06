import CoreGraphics
import CornermarkCore
import CornermarkL10n
import Foundation

/// Numbers in the editor are pixel sizes and percentages. They take the digits of the interface language but never a grouping
/// separator, so "1200 × 800" stays one run in every language.
enum Digits {
    static func string(_ value: Int) -> String {
        value.formatted(.number.locale(L10n.locale).grouping(.never))
    }

    static func string(_ value: CGFloat) -> String { string(Int(value)) }

    static func percent(_ fraction: CGFloat) -> String {
        tr("{percent}%", ["percent": string(Int((fraction * 100).rounded()))])
    }

    static func size(_ size: CGSize) -> String {
        tr("{width} × {height}", ["width": string(size.width), "height": string(size.height)])
    }
}

extension ArrowStyle {
    var title: String {
        switch self {
        case .classic: return tr("Classic")
        case .tapered: return tr("Tapered")
        case .outline: return tr("Outline")
        case .curved: return tr("Curved")
        }
    }
}

extension BlurMode {
    var title: String {
        switch self {
        case .smooth: return tr("Smooth")
        case .secure: return tr("Secure")
        }
    }
}

extension TextStylePreset {
    var title: String {
        switch self {
        case .plain: return tr("Plain")
        case .bold: return tr("Bold")
        case .outlined: return tr("Outlined")
        case .pill: return tr("Pill")
        case .banner: return tr("Banner")
        case .shadowed: return tr("Shadowed")
        case .mono: return tr("Mono", context: "text style")
        }
    }
}

extension BackgroundAlignment {
    var title: String {
        switch self {
        case .center: return tr("Center")
        case .top: return tr("Top")
        case .bottom: return tr("Bottom")
        case .left: return tr("Left")
        case .right: return tr("Right")
        }
    }
}

/// The built-in gradients are named in `CornermarkCore`; this table is where those names are translated.
enum BackgroundNames {
    private static let titles: [String: LocalizedText] = [
        "Sunset": trKey("Sunset"), "Ocean": trKey("Ocean"), "Aurora": trKey("Aurora"), "Peach": trKey("Peach"),
        "Lavender": trKey("Lavender"), "Mint": trKey("Mint"), "Midnight": trKey("Midnight"), "Candy": trKey("Candy"),
        "Citrus": trKey("Citrus"), "Graphite": trKey("Graphite"), "Dusk": trKey("Dusk"), "Forest": trKey("Forest"),
        "Rose Gold": trKey("Rose Gold"), "Sky": trKey("Sky"), "Ember": trKey("Ember"), "Lagoon": trKey("Lagoon"),
        "Cotton": trKey("Cotton"), "Slate": trKey("Slate"), "Mocha": trKey("Mocha"), "Mono": trKey("Mono", context: "gradient name"),
    ]

    static func title(_ name: String) -> String { titles[name]?.text ?? name }
}
