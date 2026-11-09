import AppKit
import CornermarkCore
import CornermarkDesign
import CornermarkL10n
import Foundation

/// Numbers the way the interface language writes them, without grouping. Time codes, sizes and frame rates keep their shape and
/// take only the digits of the language, so `0:12.40` stays a time code in every script.
enum Digits {
    private static let lock = NSLock()
    private static var cache: (locale: String, glyphs: [Character])?

    /// The ten digits as `L10n.locale` writes them.
    private static var glyphs: [Character] {
        let locale = L10n.locale
        lock.lock()
        defer { lock.unlock() }
        if let cache, cache.locale == locale.identifier { return cache.glyphs }
        let made = (0...9).map { $0.formatted(.number.locale(locale).grouping(.never)).first ?? Character("\($0)") }
        cache = (locale.identifier, made)
        return made
    }

    /// `ascii` with its 0 to 9 written in the language's digits.
    static func localize(_ ascii: String) -> String {
        let table = glyphs
        guard table[1] != "1" else { return ascii }
        return String(ascii.map { c in c.wholeNumberValue.flatMap { c.isASCII ? table[$0] : nil } ?? c })
    }

    /// The whole number `text` holds in any script's digits, or nil when it is not one.
    static func parse(_ text: String) -> Int? {
        let ascii = text.map { $0.wholeNumberValue.map { String($0) } ?? String($0) }.joined()
        return Int(ascii)
    }

    static func text(_ n: Int, minLength: Int = 1) -> String {
        localize(String(format: "%0\(minLength)d", n))
    }

    /// `value` with `fraction` decimals, written with the language's digits and decimal separator.
    static func fixed(_ value: Double, _ fraction: Int) -> String {
        let text = localize(String(format: "%.\(fraction)f", value))
        guard fraction > 0, let separator = L10n.locale.decimalSeparator, separator != "." else { return text }
        return text.replacingOccurrences(of: ".", with: separator)
    }

    /// `150%` for 1.5.
    static func percent(_ fraction: Double) -> String {
        tr("{value}%", ["value": text(Int((fraction * 100).rounded()))])
    }
}

extension AudioTrack {
    var localizedTitle: String { self == .microphone ? tr("Microphone") : tr("System audio") }
}

extension ZoomMode {
    var localizedTitle: String {
        switch self {
        case .followCursor: return tr("Follow Cursor")
        case .manual: return tr("Manual")
        }
    }
}

extension GridPosition {
    var localizedTitle: String {
        switch self {
        case .topLeft: return tr("Top left")
        case .topCenter: return tr("Top center")
        case .topRight: return tr("Top right")
        case .middleLeft: return tr("Middle left")
        case .center: return tr("Center")
        case .middleRight: return tr("Middle right")
        case .bottomLeft: return tr("Bottom left")
        case .bottomCenter: return tr("Bottom center")
        case .bottomRight: return tr("Bottom right")
        }
    }
}

extension ExportQuality {
    var localizedTitle: String {
        switch self {
        case .low: return tr("Low")
        case .medium: return tr("Medium", context: "quality")
        case .high: return tr("High")
        }
    }
}

extension VideoAspect {
    var localizedTitle: String {
        switch self {
        case .auto: return tr("Auto")
        case .ratio(let w, let h): return tr("{width}:{height}", ["width": Digits.text(w), "height": Digits.text(h)])
        case .custom: return tr("Custom")
        }
    }
}

extension BuiltinBackground {
    /// The palette's name in the interface language. The names are the ones `BuiltinBackgrounds` lists.
    var localizedName: String {
        switch name {
        case "Sunset": return tr("Sunset")
        case "Ocean": return tr("Ocean")
        case "Aurora": return tr("Aurora")
        case "Peach": return tr("Peach")
        case "Lavender": return tr("Lavender")
        case "Mint": return tr("Mint")
        case "Midnight": return tr("Midnight")
        case "Candy": return tr("Candy")
        case "Citrus": return tr("Citrus")
        case "Graphite": return tr("Graphite")
        case "Dusk": return tr("Dusk")
        case "Forest": return tr("Forest")
        case "Rose Gold": return tr("Rose Gold")
        case "Sky": return tr("Sky")
        case "Ember": return tr("Ember")
        case "Lagoon": return tr("Lagoon")
        case "Cotton": return tr("Cotton")
        case "Slate": return tr("Slate")
        case "Mocha": return tr("Mocha")
        case "Mono": return tr("Mono", context: "gradient name")
        default: return name
        }
    }
}

extension NSView {
    /// `applyLanguageDirection()`, except that a position grid is a picture of the frame and keeps its left and right.
    func applyChromeDirection() {
        applyLanguageDirection()
        keepPositionGridsLeftToRight()
    }

    private func keepPositionGridsLeftToRight() {
        if let grid = self as? PositionGrid { return grid.applyLanguageDirection(.leftToRight) }
        for sub in subviews { sub.keepPositionGridsLeftToRight() }
    }
}

/// Moves the focus to the control that held it before a window rebuilt its views, found by accessibility identifier.
struct FocusMemory {
    private let identifier: String?

    @MainActor
    init(_ window: NSWindow?) {
        var responder = window?.firstResponder
        if let text = responder as? NSText, let field = text.delegate as? NSView { responder = field }
        identifier = (responder as? NSView)?.accessibilityIdentifier()
    }

    @MainActor
    func restore(in editor: VideoEditorWindowController) {
        guard let identifier, let view = editor.view(identifier: identifier), !view.isHiddenOrHasHiddenAncestor else { return }
        editor.window?.makeFirstResponder(view)
    }
}

/// A row of media controls (go to start, play, go to end). Their symbols describe media time, which runs left to right in every language.
final class MediaControlStack: NSStackView, KeepsLeftToRight {}
