import Carbon.HIToolbox
import Foundation
import CornermarkCore

/// Everything in the menu bar panel that can be pressed. The identity is also the command the press runs.
enum PanelItem: Hashable {
    /// Any row of the action table, which includes the Update button and the All control above the recents.
    case action(ActionID)
    case recent(UUID)
    case togglePinLock(UUID)
    case closePin(UUID)
    case unlockAllPins
    case closeAllPins

    var identifier: String {
        switch self {
        case .action(let id): return "menu.action.\(id.rawValue)"
        case .recent(let id): return "menu.recent.\(id.uuidString)"
        case .togglePinLock(let id): return "menu.pin.lock.\(id.uuidString)"
        case .closePin(let id): return "menu.pin.close.\(id.uuidString)"
        case .unlockAllPins: return "menu.pins.unlockAll"
        case .closeAllPins: return "menu.pins.closeAll"
        }
    }
}

/// What the panel shows, decided in one place: which sections exist, what each row is called, whether it is enabled.
/// The views only draw it.
struct MenuPanelModel: Equatable {
    static let columns = 3
    static let recentLimit = 3

    struct UpdateBanner: Equatable {
        let symbol: String
        let title: String
        let detail: String
        /// Nil while installing, when there is nothing left to press.
        let button: PanelItem?
        let buttonLabel: String
    }

    struct Tile: Equatable {
        let item: PanelItem
        let symbol: String
        let title: String
        /// Nil when the user switched the shortcut off.
        let shortcut: String?
        let accessibilityLabel: String
    }

    struct Recent: Equatable {
        let item: PanelItem
        let record: CaptureRecord
        let accessibilityLabel: String
    }

    struct Row: Equatable {
        let item: PanelItem
        let symbol: String
        let title: String
        let isEnabled: Bool
        var accessibilityLabel: String { title.replacingOccurrences(of: "\u{2026}", with: "") }
    }

    struct Pin: Equatable {
        let id: UUID
        let title: String
        let isLocked: Bool
        var lock: PanelItem { .togglePinLock(id) }
        var close: PanelItem { .closePin(id) }
    }

    enum Section: Equatable {
        case update(UpdateBanner)
        case captures([Tile])
        case recent(header: String, all: PanelItem, [Recent])
        case rows([Row])
        case pins(header: String, [Pin], bulk: [Row])
        case footer([Row])
    }

    let sections: [Section]

    /// The footer in the order it is shown. An action with a menu group that is missing here still appears, after these.
    private static let footerOrder: [ActionID] = [.history, .whatsNew, .checkForUpdates, .settings, .quit]

    static func make(
        specs: [ActionSpec] = ActionTable.specs,
        settings: Settings,
        update: UpdateState,
        overlaysHidden: Bool,
        canRestoreOverlay: Bool,
        pins: [PinSummary],
        recording: RecordingController.Phase = .idle,
        /// Nil when no camera shows, else whether it fills the recording.
        cameraFullScreen: Bool? = nil,
        recent: [CaptureRecord],
        dateText: (Date) -> String = Self.dateText
    ) -> MenuPanelModel {
        var sections: [Section] = []

        if let banner = Self.banner(for: update) { sections.append(.update(banner)) }

        let tiles = specs.filter { $0.menuGroup == 0 }.map { spec -> Tile in
            let key = settings.hotKey(for: spec.id)
            let spoken = key.map { ", " + $0.spokenString } ?? ""
            // While a recording runs, its tile stops it.
            if spec.id == .recordScreen, recording != .idle {
                return Tile(item: .action(spec.id), symbol: "stop.circle", title: "Stop", shortcut: key?.displayString,
                            accessibilityLabel: "Stop Recording" + spoken)
            }
            return Tile(item: .action(spec.id), symbol: spec.symbol, title: spec.tileTitle, shortcut: key?.displayString,
                        accessibilityLabel: spec.title + spoken)
        }
        sections.append(.captures(tiles))

        // The bar never takes the keyboard, so pausing and restarting by keyboard happens here.
        if recording.isRunning {
            let pause = ActionTable.spec(recording == .paused ? .resumeRecording : .pauseRecording)
            let restart = ActionTable.spec(.restartRecording)
            var rows = [Row(item: .action(pause.id), symbol: pause.symbol, title: pause.title, isEnabled: true),
                        Row(item: .action(restart.id), symbol: restart.symbol, title: "Discard and Restart", isEnabled: true)]
            // The camera's bubble never takes the keyboard either, so its click has a row here.
            if let full = cameraFullScreen {
                rows.append(Row(item: .action(.recordingCamera), symbol: full ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                                title: full ? "Shrink Camera to Bubble" : "Fill with Camera", isEnabled: true))
            }
            sections.append(.rows(rows))
        }

        let newest = Array(recent.sorted { $0.createdAt > $1.createdAt }.prefix(recentLimit))
        if !newest.isEmpty {
            let items = newest.map { Recent(item: .recent($0.id), record: $0, accessibilityLabel: "\($0.kind.title) \($0.isRecording ? "recording" : "capture"), \(dateText($0.createdAt))") }
            sections.append(.recent(header: "Recent", all: .action(.history), items))
        }

        let overlayRows = specs.filter { $0.menuGroup == 1 }.map { spec -> Row in
            switch spec.id {
            case .hideOverlays:
                return Row(item: .action(spec.id), symbol: overlaysHidden ? "eye" : spec.symbol, title: overlaysHidden ? "Show Overlays" : spec.title, isEnabled: true)
            case .restoreOverlay:
                return Row(item: .action(spec.id), symbol: spec.symbol, title: spec.title, isEnabled: canRestoreOverlay)
            default:
                return Row(item: .action(spec.id), symbol: spec.symbol, title: spec.title, isEnabled: true)
            }
        }
        sections.append(.rows(overlayRows))

        if !pins.isEmpty {
            let list = pins.map { Pin(id: $0.id, title: $0.title, isLocked: $0.isLocked) }
            let bulk = pins.count > 1
                ? [Row(item: .unlockAllPins, symbol: "lock.open", title: "Unlock all", isEnabled: true),
                   Row(item: .closeAllPins, symbol: "xmark", title: "Close all", isEnabled: true)]
                : []
            sections.append(.pins(header: "Pinned screenshots", list, bulk: bulk))
        }

        sections.append(.footer(footer(specs: specs, update: update, hasRecent: !newest.isEmpty)))
        return MenuPanelModel(sections: sections)
    }

    private static func banner(for update: UpdateState) -> UpdateBanner? {
        switch update {
        case .available(let release):
            return UpdateBanner(symbol: "arrow.down.circle", title: "Cornermark \(release.version)", detail: "Ready to install",
                                button: .action(.checkForUpdates), buttonLabel: "Update to Cornermark \(release.version)")
        case .installing(let release):
            return UpdateBanner(symbol: "arrow.down.circle", title: "Cornermark \(release.version)", detail: "Installing\u{2026}",
                                button: nil, buttonLabel: "")
        case .idle, .checking:
            return nil
        }
    }

    private static func footer(specs: [ActionSpec], update: UpdateState, hasRecent: Bool) -> [Row] {
        let candidates = specs.enumerated().filter { _, spec in
            guard let group = spec.menuGroup, group >= 2 else { return false }
            // The All control above the recents opens the history; without recents the footer keeps the way in.
            if spec.id == .history { return !hasRecent }
            if spec.id == .checkForUpdates { return !update.showsBanner }
            return true
        }
        let ordered = candidates.sorted { a, b in
            let ra = footerOrder.firstIndex(of: a.element.id) ?? footerOrder.count
            let rb = footerOrder.firstIndex(of: b.element.id) ?? footerOrder.count
            return ra != rb ? ra < rb : a.offset < b.offset
        }
        return ordered.map { _, spec in
            switch spec.id {
            case .checkForUpdates:
                return Row(item: .action(spec.id), symbol: spec.symbol, title: update.menuTitle, isEnabled: update.menuEnabled)
            default:
                return Row(item: .action(spec.id), symbol: spec.symbol, title: spec.title, isEnabled: true)
            }
        }
    }

    static func dateText(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    /// The rows the keyboard walks, top to bottom. A row with several items is one the arrows also move across.
    /// Disabled rows are skipped, because Return on them would do nothing.
    var focusRows: [[PanelItem]] {
        var rows: [[PanelItem]] = []
        for section in sections {
            switch section {
            case .update(let banner):
                if let button = banner.button { rows.append([button]) }
            case .captures(let tiles):
                let ids = tiles.map(\.item)
                for start in stride(from: 0, to: ids.count, by: Self.columns) {
                    rows.append(Array(ids[start..<min(start + Self.columns, ids.count)]))
                }
            case .recent(_, let all, let items):
                rows.append([all])
                rows.append(items.map(\.item))
            case .rows(let list), .footer(let list):
                rows += list.filter(\.isEnabled).map { [$0.item] }
            case .pins(_, let pins, let bulk):
                for pin in pins { rows += [[pin.lock], [pin.close]] }
                rows += bulk.filter(\.isEnabled).map { [$0.item] }
            }
        }
        return rows
    }
}

extension UpdateState {
    /// The panel shows an update row in place of the Check for updates row.
    var showsBanner: Bool {
        switch self {
        case .available, .installing: return true
        case .idle, .checking: return false
        }
    }
}

extension HotKey {
    /// "Control Shift 2", for a screen reader that would read the symbols as nothing.
    var spokenString: String {
        var parts: [String] = []
        if modifiers & UInt32(controlKey) != 0 { parts.append("Control") }
        if modifiers & UInt32(optionKey) != 0 { parts.append("Option") }
        if modifiers & UInt32(shiftKey) != 0 { parts.append("Shift") }
        if modifiers & UInt32(cmdKey) != 0 { parts.append("Command") }
        parts.append(Self.spokenKeys[keyName] ?? keyName)
        return parts.joined(separator: " ")
    }

    private static let spokenKeys: [String: String] = [
        "\u{21A9}": "Return", "\u{21E5}": "Tab", "\u{232B}": "Delete",
        "\u{2190}": "Left Arrow", "\u{2192}": "Right Arrow", "\u{2191}": "Up Arrow", "\u{2193}": "Down Arrow",
        "=": "Equals", "-": "Minus", "[": "Left Bracket", "]": "Right Bracket", ";": "Semicolon", "'": "Quote",
        ",": "Comma", ".": "Period", "/": "Slash", "\\": "Backslash", "`": "Grave",
    ]
}

/// Moves the keyboard focus through the panel's rows. It holds no view: the panel draws a ring wherever `current` points.
struct MenuFocus: Equatable {
    enum Direction { case up, down, left, right }

    private(set) var rows: [[PanelItem]]
    /// Nil until the first arrow key, so someone using the mouse never sees a ring.
    private(set) var current: PanelItem?

    init(rows: [[PanelItem]], current: PanelItem? = nil) {
        self.rows = rows
        self.current = current
    }

    /// The first arrow goes to the first item. Up and down wrap and keep the column where the next row has one;
    /// left and right stop at the ends of a row and do nothing in a row of one.
    mutating func move(_ direction: Direction) {
        guard !rows.isEmpty, let current, let (r, c) = position(of: current) else {
            current = rows.first?.first
            return
        }
        switch direction {
        case .down, .up:
            let next = (r + (direction == .down ? 1 : rows.count - 1)) % rows.count
            self.current = rows[next][min(c, rows[next].count - 1)]
        case .left:
            if c > 0 { self.current = rows[r][c - 1] }
        case .right:
            if c < rows[r].count - 1 { self.current = rows[r][c + 1] }
        }
    }

    /// Follows a rebuilt panel: the focus stays where it was if that item still exists.
    mutating func rebase(onto rows: [[PanelItem]]) {
        self.rows = rows
        if let current, position(of: current) == nil { self.current = nil }
    }

    private func position(of item: PanelItem) -> (row: Int, column: Int)? {
        for (r, row) in rows.enumerated() {
            if let c = row.firstIndex(of: item) { return (r, c) }
        }
        return nil
    }
}

/// Where the panel opens: under the status item button, right edges level, kept inside the button's display.
enum MenuPlacement {
    static let gap: CGFloat = 4
    static let margin: CGFloat = 8

    static func frame(size: CGSize, button: CGRect, visible: CGRect) -> CGRect {
        var x = button.maxX - size.width
        x = min(x, visible.maxX - size.width - margin)
        x = max(x, visible.minX + margin)
        var y = button.minY - gap - size.height
        y = min(y, visible.maxY - size.height)
        y = max(y, visible.minY)
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }
}
