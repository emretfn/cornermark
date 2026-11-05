import AppKit
import CornermarkCapture
import Foundation

struct AfterCapture: OptionSet, Codable, Equatable {
    let rawValue: Int
    static let showOverlay = AfterCapture(rawValue: 1)
    static let copy = AfterCapture(rawValue: 2)
    static let save = AfterCapture(rawValue: 4)
    static let openEditor = AfterCapture(rawValue: 8)

    init(rawValue: Int) { self.rawValue = rawValue }
    init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(Int.self) }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}

enum SaveFormat: String, Codable, CaseIterable {
    case png, jpeg
    var fileExtension: String { self == .jpeg ? "jpg" : "png" }
    var title: String { self == .jpeg ? "JPEG" : "PNG" }
}

enum ScreenCorner: String, Codable, CaseIterable {
    case bottomRight, bottomLeft, topRight, topLeft
    var title: String {
        switch self {
        case .bottomRight: return "Bottom right"
        case .bottomLeft: return "Bottom left"
        case .topRight: return "Top right"
        case .topLeft: return "Top left"
        }
    }
    var isRight: Bool { self == .bottomRight || self == .topRight }
    var isBottom: Bool { self == .bottomRight || self == .bottomLeft }
}

enum OverlaySize: String, Codable, CaseIterable {
    case small, medium, large
    var title: String { rawValue.capitalized }
    var cardWidth: CGFloat {
        switch self {
        case .small: return 160
        case .medium: return 220
        case .large: return 300
        }
    }
}

/// How recordings are made and what happens when one finishes.
struct RecordingPreferences: Codable, Equatable {
    static let fpsChoices = [30, 60]
    var fps = 60
    var quality: VideoQuality = .high
    var density: PixelDensity = .retina
    var limit: SizeLimit = .none
    /// Record Video draws the pointer into its picture. Record for Editing keeps it as a track either way, and this is whether it starts shown.
    var showCursor = true
    var showQuickAccess = true

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func get<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T { (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback }
        let d = RecordingPreferences()
        fps = get(.fps, d.fps)
        quality = get(.quality, d.quality)
        density = get(.density, d.density)
        limit = get(.limit, d.limit)
        showCursor = get(.showCursor, d.showCursor)
        showQuickAccess = get(.showQuickAccess, d.showQuickAccess)
    }

    /// A frame rate that is not offered becomes the nearest one that is.
    func normalized() -> RecordingPreferences {
        var p = self
        p.fps = Self.fpsChoices.min { abs($0 - fps) < abs($1 - fps) } ?? 60
        return p
    }

    func options(for style: RecordingStyle) -> RecordingOptions {
        RecordingOptions(fps: fps, showsCursor: style == .video && showCursor, quality: quality, density: density, limit: limit)
    }
}

/// Everything the user can configure, persisted as one JSON value.
struct Settings: Codable, Equatable {
    var afterCapture: AfterCapture = [.showOverlay, .copy]
    var saveFolder: String?
    var imageFormat: SaveFormat = .png
    var playSound = true
    var launchAtLogin = false
    var customShortcuts: [String: HotKey] = [:]
    var disabledShortcuts: Set<String> = []
    var overlayCorner: ScreenCorner = .bottomRight
    var overlaySize: OverlaySize = .medium
    /// Seconds until a Quick Access card closes by itself; 0 keeps it until dismissed. Stored as a
    /// plain number because an optional would vanish from the JSON when nil.
    var autoCloseSeconds: Double = 8
    var windowShadow = true
    var timerSeconds = 5
    var retentionDays = 30
    var checkForUpdatesAutomatically = true
    /// The version that last ran, so the first launch after an update can say so. Nil before the first run.
    var lastRunVersion: String?
    var recording = RecordingPreferences()

    var overlayAutoClose: Double? {
        get { autoCloseSeconds > 0 ? autoCloseSeconds : nil }
        set { autoCloseSeconds = newValue ?? 0 }
    }

    static let autoCloseChoices: [Double?] = [nil, 3, 5, 8, 15, 30]

    init() {}

    /// Missing keys fall back to defaults, so adding a field never resets what the user already chose.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func get<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T { (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback }
        let d = Settings.defaultsSnapshot
        afterCapture = get(.afterCapture, d.afterCapture)
        saveFolder = get(.saveFolder, d.saveFolder)
        imageFormat = get(.imageFormat, d.imageFormat)
        playSound = get(.playSound, d.playSound)
        launchAtLogin = get(.launchAtLogin, d.launchAtLogin)
        customShortcuts = get(.customShortcuts, d.customShortcuts)
        disabledShortcuts = get(.disabledShortcuts, d.disabledShortcuts)
        overlayCorner = get(.overlayCorner, d.overlayCorner)
        overlaySize = get(.overlaySize, d.overlaySize)
        autoCloseSeconds = get(.autoCloseSeconds, d.autoCloseSeconds)
        windowShadow = get(.windowShadow, d.windowShadow)
        timerSeconds = get(.timerSeconds, d.timerSeconds)
        retentionDays = get(.retentionDays, d.retentionDays)
        checkForUpdatesAutomatically = get(.checkForUpdatesAutomatically, d.checkForUpdatesAutomatically)
        lastRunVersion = get(.lastRunVersion, d.lastRunVersion)
        recording = get(.recording, d.recording)
        self = normalized()
    }

    private static let defaultsSnapshot = Settings()

    func normalized() -> Settings {
        var s = self
        s.timerSeconds = min(max(s.timerSeconds, 1), 60)
        s.retentionDays = min(max(s.retentionDays, 1), 3650)
        s.autoCloseSeconds = s.autoCloseSeconds > 0 ? min(max(s.autoCloseSeconds, 1), 600) : 0
        s.recording = s.recording.normalized()
        return s
    }

    /// Custom binding, else the table default, unless the user switched the shortcut off.
    func hotKey(for id: ActionID) -> HotKey? {
        if disabledShortcuts.contains(id.rawValue) { return nil }
        return customShortcuts[id.rawValue] ?? ActionTable.spec(id).hotKey
    }

    func resolvedSaveFolder(default fallback: URL) -> URL {
        saveFolder.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) } ?? fallback
    }
}

@MainActor
final class SettingsStore {
    static let key = "cornermark.settings"
    private let defaults: UserDefaults
    private(set) var value: Settings
    private var observers: [(Settings, Settings) -> Void] = []

    init(defaults: UserDefaults) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key) {
            if let decoded = try? JSONDecoder().decode(Settings.self, from: data) {
                value = decoded
            } else {
                Log.shell.error("settings value unreadable, using defaults")
                value = Settings()
            }
        } else {
            value = Settings()
        }
    }

    func observe(_ handler: @escaping (_ old: Settings, _ new: Settings) -> Void) { observers.append(handler) }

    func update(_ change: (inout Settings) -> Void) {
        var next = value
        change(&next)
        next = next.normalized()
        guard next != value else { return }
        let old = value
        value = next
        if let data = try? JSONEncoder().encode(next) { defaults.set(data, forKey: Self.key) }
        for o in observers { o(old, next) }
    }
}
