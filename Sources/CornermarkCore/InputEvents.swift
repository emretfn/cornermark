import Foundation

/// A mouse press, in points of the recorded area with the origin at its top-left corner.
public struct ClickEvent: Codable, Equatable, Sendable {
    public var t: Double
    public var x: Double
    public var y: Double
    public init(t: Double, x: Double, y: Double) { self.t = t; self.x = x; self.y = y }
}

/// A key press as it is shown, such as `⇧⌘4`, `a` or `↩`. `isCommand` is true when Command or Control was held.
public struct KeyEvent: Codable, Equatable, Sendable {
    public var t: Double
    public var label: String
    public var isCommand: Bool
    public init(t: Double, label: String, isCommand: Bool) { self.t = t; self.label = label; self.isCommand = isCommand }
}

public struct ClickHighlight: Codable, Equatable, Sendable {
    /// Seconds a ring stays on screen after a press.
    public static let lifetime = 0.4

    public enum Color: String, Codable, CaseIterable, Sendable { case lemon, white, orange, red, green }
    public enum Style: String, Codable, CaseIterable, Sendable { case outline, filled }
    public enum Size: String, Codable, CaseIterable, Sendable {
        case small, medium, large
        /// The ring's full radius in points.
        public var radius: Double {
            switch self {
            case .small: return 14
            case .medium: return 20
            case .large: return 28
            }
        }
    }

    public var isVisible: Bool
    public var color: Color
    public var style: Style
    public var size: Size
    /// Off draws a still ring for the whole lifetime.
    public var animates: Bool

    public init(isVisible: Bool = false, color: Color = .lemon, style: Style = .outline, size: Size = .medium, animates: Bool = true) {
        self.isVisible = isVisible; self.color = color; self.style = style; self.size = size; self.animates = animates
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let d = ClickHighlight()
        isVisible = (try? c.decodeIfPresent(Bool.self, forKey: .isVisible)) ?? d.isVisible
        color = (try? c.decodeIfPresent(Color.self, forKey: .color)) ?? d.color
        style = (try? c.decodeIfPresent(Style.self, forKey: .style)) ?? d.style
        size = (try? c.decodeIfPresent(Size.self, forKey: .size)) ?? d.size
        animates = (try? c.decodeIfPresent(Bool.self, forKey: .animates)) ?? d.animates
    }
    private enum Keys: String, CodingKey { case isVisible, color, style, size, animates }
}

public struct KeystrokeDisplay: Codable, Equatable, Sendable {
    /// Seconds a badge stays fully shown after its last key.
    public static let hold = 1.6
    public static let enter = 0.2
    public static let fade = 0.2
    /// The longest text a badge shows. Older characters scroll off the front.
    public static let maxCharacters = 24

    public enum Keys: String, Codable, CaseIterable, Sendable {
        /// Only keys pressed with Command or Control.
        case shortcuts
        case all

        public func admits(isCommand: Bool) -> Bool { self == .all || isCommand }
    }
    public enum Size: String, Codable, CaseIterable, Sendable {
        case small, medium, large
        /// The label's font size in points.
        public var fontSize: Double {
            switch self {
            case .small: return 18
            case .medium: return 24
            case .large: return 34
            }
        }
    }
    public enum Theme: String, Codable, CaseIterable, Sendable { case dark, light }

    public var isVisible: Bool
    public var keys: Keys
    public var position: GridPosition
    public var size: Size
    public var theme: Theme

    public init(isVisible: Bool = false, keys: Keys = .shortcuts, position: GridPosition = .bottomCenter, size: Size = .medium, theme: Theme = .dark) {
        self.isVisible = isVisible; self.keys = keys; self.position = position; self.size = size; self.theme = theme
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = KeystrokeDisplay()
        isVisible = (try? c.decodeIfPresent(Bool.self, forKey: .isVisible)) ?? d.isVisible
        keys = (try? c.decodeIfPresent(Keys.self, forKey: .keys)) ?? d.keys
        position = (try? c.decodeIfPresent(GridPosition.self, forKey: .position)) ?? d.position
        size = (try? c.decodeIfPresent(Size.self, forKey: .size)) ?? d.size
        theme = (try? c.decodeIfPresent(Theme.self, forKey: .theme)) ?? d.theme
    }

}

public struct InputCapture: Equatable, Sendable {
    public var clicks: Bool
    /// Nil watches no keys.
    public var keys: KeystrokeDisplay.Keys?
    public init(clicks: Bool = false, keys: KeystrokeDisplay.Keys? = nil) { self.clicks = clicks; self.keys = keys }
    public var isEmpty: Bool { !clicks && keys == nil }

    public func admitsKey(isCommand: Bool) -> Bool { keys?.admits(isCommand: isCommand) ?? false }
}

public struct KeyModifiers: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let control = KeyModifiers(rawValue: 1)
    public static let option = KeyModifiers(rawValue: 2)
    public static let shift = KeyModifiers(rawValue: 4)
    public static let command = KeyModifiers(rawValue: 8)
}

public enum KeyLabel {
    /// Keys whose glyph does not come from the keyboard layout, by virtual key code.
    public static let special: [UInt16: String] = [
        36: "\u{21A9}", 76: "\u{2324}", 48: "\u{21E5}", 49: "\u{2423}", 51: "\u{232B}", 117: "\u{2326}", 53: "esc",
        123: "\u{2190}", 124: "\u{2192}", 125: "\u{2193}", 126: "\u{2191}",
        115: "\u{2196}", 119: "\u{2198}", 116: "\u{21DE}", 121: "\u{21DF}",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]

    /// `base` is the character the key makes with no modifier, `typed` what it made with the held ones.
    /// A shortcut (Command or Control held) shows every modifier and the base key, so ⇧⌘4 reads as pressed.
    /// Anything else shows what was typed. Nil when the press shows nothing, such as a dead key.
    public static func make(keyCode: UInt16, base: String, typed: String, modifiers: KeyModifiers) -> KeyEvent? {
        let isCommand = modifiers.contains(.command) || modifiers.contains(.control)
        if isCommand {
            guard let key = special[keyCode] ?? visible(base)?.uppercased() else { return nil }
            return KeyEvent(t: 0, label: symbols(modifiers) + key, isCommand: true)
        }
        if let key = special[keyCode] {
            let held = modifiers.intersection([.option, .shift])
            return KeyEvent(t: 0, label: symbols(held) + key, isCommand: false)
        }
        guard let text = visible(typed) else { return nil }
        return KeyEvent(t: 0, label: text, isCommand: false)
    }

    /// In the order macOS menus print them.
    public static func symbols(_ m: KeyModifiers) -> String {
        (m.contains(.control) ? "\u{2303}" : "") + (m.contains(.option) ? "\u{2325}" : "") + (m.contains(.shift) ? "\u{21E7}" : "") + (m.contains(.command) ? "\u{2318}" : "")
    }

    private static func visible(_ s: String) -> String? {
        let kept = s.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) && $0.properties.generalCategory != .privateUse }
        return kept.isEmpty ? nil : String(String.UnicodeScalarView(kept))
    }
}

/// One click mark at one instant, in points of the recorded area.
public struct ClickRing: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var radius: Double
    public var opacity: Double
}

public struct KeyBadge: Equatable, Sendable {
    public var text: String
    public var scale: Double
    public var opacity: Double
}

public struct InputOverlayState: Equatable, Sendable {
    public var rings: [ClickRing]
    public var badge: KeyBadge?
    public init(rings: [ClickRing] = [], badge: KeyBadge? = nil) { self.rings = rings; self.badge = badge }
    public var isEmpty: Bool { rings.isEmpty && badge == nil }
}

public enum InputOverlay {
    /// The marks at `t`. Events and `t` only have to share a clock, so raw recording times work as well as video times.
    /// Both arrays are sorted by `t`.
    public static func state(clicks: [ClickEvent], keys: [KeyEvent], highlight: ClickHighlight, keystrokes: KeystrokeDisplay, at t: Double) -> InputOverlayState {
        var state = InputOverlayState()
        if highlight.isVisible {
            state.rings = clicks.compactMap { ring($0, highlight, at: t) }
        }
        if keystrokes.isVisible {
            state.badge = badge(keys.filter { $0.t <= t && keystrokes.keys.admits(isCommand: $0.isCommand) }, at: t)
        }
        return state
    }

    static func ring(_ click: ClickEvent, _ h: ClickHighlight, at t: Double) -> ClickRing? {
        let age = t - click.t
        guard age >= 0, age < ClickHighlight.lifetime else { return nil }
        let r = h.size.radius
        guard h.animates else { return ClickRing(x: click.x, y: click.y, radius: r, opacity: 1) }
        let p = age / ClickHighlight.lifetime
        let grow = 1 - pow(1 - min(p / 0.6, 1), 3)
        let fade = p < 0.45 ? 1 : 1 - (p - 0.45) / 0.55
        return ClickRing(x: click.x, y: click.y, radius: r * (0.6 + 0.4 * grow), opacity: max(0, fade))
    }

    static func badge(_ keys: [KeyEvent], at t: Double) -> KeyBadge? {
        guard let last = keys.last else { return nil }
        let age = t - last.t
        guard age < KeystrokeDisplay.hold + KeystrokeDisplay.fade else { return nil }
        var start = keys.count - 1
        if !last.isCommand {
            while start > 0, !keys[start - 1].isCommand, keys[start].t - keys[start - 1].t < KeystrokeDisplay.hold { start -= 1 }
        }
        var text = keys[start...].map(\.label).joined()
        if text.count > KeystrokeDisplay.maxCharacters { text = String(text.suffix(KeystrokeDisplay.maxCharacters)) }
        let since = t - keys[start].t
        let enter = min(max(since / KeystrokeDisplay.enter, 0), 1)
        let eased = 1 - pow(1 - enter, 3)
        let opacity = age <= KeystrokeDisplay.hold ? min(1, since / 0.06) : 1 - (age - KeystrokeDisplay.hold) / KeystrokeDisplay.fade
        return KeyBadge(text: text, scale: 0.9 + 0.1 * eased, opacity: max(0, min(1, opacity)))
    }
}

extension RecordingProject {
    public func inputOverlay(at sourceTime: Double) -> InputOverlayState {
        InputOverlay.state(clicks: events.clicks, keys: events.keys, highlight: edits.clicks, keystrokes: edits.keystrokes, at: sourceTime)
    }
}
