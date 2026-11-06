import AppKit
import CornermarkL10n

/// Every key the video editor answers, in one table. The editor window, the timeline, the zoom lane, the main menu and the list in
/// Settings all read it, so a key cannot work without being listed or be listed without working.
public enum EditorShortcuts {
    public static let all: [EditorShortcut] = [
        .init(.playPause, [.init(.space)], in: .window),
        .init(.step, [.init(.left), .init(.right)], in: .timeline, shiftEnlarges: true),
        .init(.jump, [.init(.home), .init(.end)], in: .timeline),
        .init(.fullScreen, [.init(.letter("f"), [.control, .command])], in: .window),
        .init(.escape, [.init(.escape)], in: .window),
        .init(.split, [.init(.letter("b"), .command)], in: .window),
        .init(.delete, [.init(.delete), .init(.forwardDelete)], in: .window),
        .init(.trimStart, [.init(.left, .option), .init(.right, .option)], in: .timeline, shiftEnlarges: true),
        .init(.trimEnd, [.init(.left, [.option, .command]), .init(.right, [.option, .command])], in: .timeline, shiftEnlarges: true),
        .init(.addZoom, [.init(.letter("z"))], in: .window),
        .init(.duplicateZoom, [.init(.letter("d"), .command)], in: .window),
        .init(.pickZoom, [.init(.left), .init(.right)], in: .zoomLane),
        .init(.moveZoom, [.init(.left, .option), .init(.right, .option)], in: .zoomLane, shiftEnlarges: true),
        .init(.resizeZoom, [.init(.left, [.option, .command]), .init(.right, [.option, .command])], in: .zoomLane, shiftEnlarges: true),
        .init(.moveTarget, [.init(.left), .init(.right), .init(.up), .init(.down)], in: .zoomTarget, shiftEnlarges: true),
        .init(.undo, [.init(.letter("z"), .command)], in: .window),
        .init(.redo, [.init(.letter("z"), [.shift, .command])], in: .window),
        .init(.save, [.init(.letter("s"), .command)], in: .window),
        .init(.saveAs, [.init(.letter("s"), [.shift, .command])], in: .window),
        .init(.openVideo, [.init(.letter("o"), .command)], in: .app),
        .init(.export, [.init(.letter("e"), .command)], in: .window),
        .init(.exportFrame, [.init(.letter("e"), [.shift, .command])], in: .window),
    ]

    public static func shortcut(for command: EditorCommand) -> EditorShortcut {
        all.first { $0.command == command }!
    }

    /// What a key press in `place` does: the command, which of its keys was pressed, and whether Shift made the step larger.
    public static func match(_ chord: EditorChord, in place: EditorPlace) -> EditorKeyPress? {
        for s in all where s.place == place {
            if let i = s.keys.firstIndex(of: chord) { return EditorKeyPress(command: s.command, keyIndex: i, enlarged: false) }
            if s.shiftEnlarges, chord.modifiers.contains(.shift) {
                var plain = chord
                plain.modifiers.remove(.shift)
                if let i = s.keys.firstIndex(of: plain) { return EditorKeyPress(command: s.command, keyIndex: i, enlarged: true) }
            }
        }
        return nil
    }

    public static func match(_ event: NSEvent, in place: EditorPlace) -> EditorKeyPress? {
        EditorChord(event: event).flatMap { match($0, in: place) }
    }
}

public struct EditorShortcut: Equatable, Sendable {
    public let command: EditorCommand
    /// Each key the command takes, in the order Settings shows them. A pair is back and forward, or start and end.
    public let keys: [EditorChord]
    public let place: EditorPlace
    /// The same keys with Shift take a larger step: a second on the timeline and the zoom lane, ten steps on the target frame.
    public let shiftEnlarges: Bool

    init(_ command: EditorCommand, _ keys: [EditorChord], in place: EditorPlace, shiftEnlarges: Bool = false) {
        self.command = command; self.keys = keys; self.place = place; self.shiftEnlarges = shiftEnlarges
    }

    /// How Settings writes the keys, such as `⌥← ⌥→`.
    public var keyText: String { keys.map(\.display).joined(separator: "  ") }

    /// Where the keys work and what Shift adds, for the caption under the command in Settings.
    public var note: String? {
        let whereText: String? = switch place {
        case .window: nil
        case .timeline: tr("With the timeline focused.")
        case .zoomLane: tr("With the zoom lane focused.")
        case .zoomTarget: tr("With a manual zoom's target frame focused.")
        case .app: nil
        }
        let step: String = switch place {
        case .zoomLane: tr("0.1 s a press, a second with Shift.")
        case .zoomTarget: tr("1% of the picture a press, 10% with Shift.")
        default: tr("A frame a press, a second with Shift.")
        }
        let shift = shiftEnlarges ? step : nil
        let parts = [whereText, shift, command.detail].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}

/// One editor command, one row in Settings.
public enum EditorCommand: String, CaseIterable, Sendable {
    case playPause, step, jump, fullScreen, escape
    case split, delete, trimStart, trimEnd
    case addZoom, duplicateZoom, pickZoom, moveZoom, resizeZoom, moveTarget
    case undo, redo, save, saveAs, openVideo, export, exportFrame

    public enum Group: String, CaseIterable, Sendable {
        case playback, clips, zooms, file
        public var title: String {
            switch self {
            case .playback: tr("Video editor: playback")
            case .clips: tr("Video editor: clips")
            case .zooms: tr("Video editor: zooms")
            case .file: tr("Video editor: project and export")
            }
        }
    }

    public var group: Group {
        switch self {
        case .playPause, .step, .jump, .fullScreen, .escape: .playback
        case .split, .delete, .trimStart, .trimEnd: .clips
        case .addZoom, .duplicateZoom, .pickZoom, .moveZoom, .resizeZoom, .moveTarget: .zooms
        case .undo, .redo, .save, .saveAs, .openVideo, .export, .exportFrame: .file
        }
    }

    public var title: String {
        switch self {
        case .playPause: tr("Play or Pause")
        case .step: tr("Step One Frame")
        case .jump: tr("Go to Start or End")
        case .fullScreen: tr("Full Screen Preview")
        case .escape: tr("Exit Full Screen or Deselect")
        case .split: tr("Split at Playhead")
        case .delete: tr("Delete Clip or Zoom")
        case .trimStart: tr("Trim Clip Start")
        case .trimEnd: tr("Trim Clip End")
        case .addZoom: tr("Add Zoom at Playhead")
        case .duplicateZoom: tr("Duplicate Zoom")
        case .pickZoom: tr("Select Previous or Next Zoom")
        case .moveZoom: tr("Move Zoom")
        case .resizeZoom: tr("Move Zoom End")
        case .moveTarget: tr("Move Zoom Target")
        case .undo: tr("Undo")
        case .redo: tr("Redo")
        case .save: tr("Save")
        case .saveAs: tr("Save As")
        case .openVideo: tr("Open Video")
        case .export: tr("Export")
        case .exportFrame: tr("Export Current Frame as Image")
        }
    }

    /// More of what the command does, when its name cannot say it all.
    public var detail: String? {
        switch self {
        case .escape: tr("Also closes Animation Settings.")
        default: nil
        }
    }
}

/// Where a key is heard: anywhere in the editor window, only in the focused timeline, zoom lane or target frame, or in the app's menu.
public enum EditorPlace: Sendable { case window, timeline, zoomLane, zoomTarget, app }

public struct EditorKeyPress: Equatable, Sendable {
    public var command: EditorCommand
    /// Which of the command's keys: 0 is back or start, 1 is forward or end; the target frame's are left, right, up and down.
    public var keyIndex: Int
    public var enlarged: Bool
    public var forward: Bool { keyIndex == 1 }
}

public struct EditorChord: Hashable, Sendable {
    public enum Key: Hashable, Sendable {
        case space, escape, delete, forwardDelete, left, right, up, down, home, end
        case letter(Character)
    }

    public struct Modifiers: OptionSet, Hashable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let control = Modifiers(rawValue: 1)
        public static let option = Modifiers(rawValue: 2)
        public static let shift = Modifiers(rawValue: 4)
        public static let command = Modifiers(rawValue: 8)
    }

    public var key: Key
    public var modifiers: Modifiers

    public init(_ key: Key, _ modifiers: Modifiers = []) { self.key = key; self.modifiers = modifiers }

    /// Caps Lock, the keypad and the Fn flag that arrow keys carry are not part of a chord.
    public init?(event: NSEvent) {
        guard let key = Self.keys.first(where: { $0.value == event.keyCode })?.key else { return nil }
        let flags = event.modifierFlags
        var m: Modifiers = []
        if flags.contains(.control) { m.insert(.control) }
        if flags.contains(.option) { m.insert(.option) }
        if flags.contains(.shift) { m.insert(.shift) }
        if flags.contains(.command) { m.insert(.command) }
        self.init(key, m)
    }

    public var keyCode: UInt16 { Self.keys.first { $0.key == key }!.value }

    public var eventFlags: NSEvent.ModifierFlags {
        var f: NSEvent.ModifierFlags = []
        if modifiers.contains(.control) { f.insert(.control) }
        if modifiers.contains(.option) { f.insert(.option) }
        if modifiers.contains(.shift) { f.insert(.shift) }
        if modifiers.contains(.command) { f.insert(.command) }
        return f
    }

    /// The menu's key equivalent and its modifiers. Only a letter can be one.
    public var menuKey: (String, NSEvent.ModifierFlags)? {
        guard case .letter(let c) = key else { return nil }
        return (String(c), eventFlags)
    }

    /// Mac order: control, option, shift, command, then the key.
    public var display: String {
        var s = ""
        if modifiers.contains(.control) { s += "\u{2303}" }
        if modifiers.contains(.option) { s += "\u{2325}" }
        if modifiers.contains(.shift) { s += "\u{21E7}" }
        if modifiers.contains(.command) { s += "\u{2318}" }
        switch key {
        case .space: s += tr("Space")
        case .escape: s += tr("Esc")
        case .delete: s += "\u{232B}"
        case .forwardDelete: s += "\u{2326}"
        case .left: s += "\u{2190}"
        case .right: s += "\u{2192}"
        case .up: s += "\u{2191}"
        case .down: s += "\u{2193}"
        case .home: s += tr("Home")
        case .end: s += tr("End")
        case .letter(let c): s += c.uppercased()
        }
        return s
    }

    /// The keys in words, for VoiceOver, such as "Option Command Left Arrow".
    public var spoken: String {
        var words: [String] = []
        if modifiers.contains(.control) { words.append(tr("Control")) }
        if modifiers.contains(.option) { words.append(tr("Option")) }
        if modifiers.contains(.shift) { words.append(tr("Shift")) }
        if modifiers.contains(.command) { words.append(tr("Command")) }
        switch key {
        case .space: words.append(tr("Space"))
        case .escape: words.append(tr("Escape"))
        case .delete: words.append(tr("Delete", context: "key name"))
        case .forwardDelete: words.append(tr("Forward Delete"))
        case .left: words.append(tr("Left Arrow"))
        case .right: words.append(tr("Right Arrow"))
        case .up: words.append(tr("Up Arrow"))
        case .down: words.append(tr("Down Arrow"))
        case .home: words.append(tr("Home"))
        case .end: words.append(tr("End"))
        case .letter(let c): words.append(c.uppercased())
        }
        return words.joined(separator: " ")
    }

    private static let keys: [(key: Key, value: UInt16)] = [
        (.space, 49), (.escape, 53), (.delete, 51), (.forwardDelete, 117), (.left, 123), (.right, 124), (.down, 125), (.up, 126), (.home, 115), (.end, 119),
        (.letter("b"), 11), (.letter("d"), 2), (.letter("e"), 14), (.letter("f"), 3), (.letter("o"), 31), (.letter("s"), 1), (.letter("z"), 6),
    ]
}
