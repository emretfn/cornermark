import AppKit
import CornermarkCapture
import CornermarkCore
import CornermarkL10n
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
        case .bottomRight: return tr("Bottom right")
        case .bottomLeft: return tr("Bottom left")
        case .topRight: return tr("Top right")
        case .topLeft: return tr("Top left")
        }
    }
    var isRight: Bool { self == .bottomRight || self == .topRight }
    var isBottom: Bool { self == .bottomRight || self == .bottomLeft }
}

enum OverlaySize: String, Codable, CaseIterable {
    case small, medium, large
    var title: String {
        switch self {
        case .small: return tr("Small")
        case .medium: return tr("Medium", context: "size")
        case .large: return tr("Large")
        }
    }
    var cardWidth: CGFloat {
        switch self {
        case .small: return 160
        case .medium: return 220
        case .large: return 300
        }
    }
}

/// What a recording hears. A GIF has no sound, so it never records any.
struct AudioPreferences: Codable, Equatable {
    var microphone = false
    /// Nil records from the system's default input, and so does a device that is no longer connected.
    var microphoneID: String?
    /// Mixes the microphone's channels into one, so a voice on one input of an interface plays from both sides. On by default, because a
    /// recording's microphone is nearly always one voice.
    var mono = true
    var systemAudio = false

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AudioPreferences()
        microphone = (try? c.decodeIfPresent(Bool.self, forKey: .microphone)) ?? d.microphone
        microphoneID = (try? c.decodeIfPresent(String.self, forKey: .microphoneID)) ?? d.microphoneID
        mono = (try? c.decodeIfPresent(Bool.self, forKey: .mono)) ?? d.mono
        systemAudio = (try? c.decodeIfPresent(Bool.self, forKey: .systemAudio)) ?? d.systemAudio
    }

    var isEmpty: Bool { !microphone && !systemAudio }

    static var none: AudioPreferences {
        var p = AudioPreferences()
        p.microphone = false
        p.systemAudio = false
        return p
    }
}

/// How recordings are made and what happens when one finishes.
struct RecordingPreferences: Codable, Equatable {
    static let fpsChoices = RecordingQuickOptions.fpsChoices
    var fps = 60
    var quality: VideoQuality = .high
    var density: PixelDensity = .retina
    var limit: SizeLimit = .none
    /// Record MP4 draws the pointer into its picture. Record Project keeps it as a track either way, and this is whether it starts shown.
    var showCursor = true
    var showQuickAccess = true
    static let countdownChoices = RecordingQuickOptions.countdownChoices
    /// Seconds counted down before the first frame. 0 starts at once, because recording is a frequent task.
    var countdown = 0
    /// Darkens everything outside an area while it records. The darkening is never in the video.
    var dimOutside = true
    var hideDesktopIcons = false
    var hideNotifications = true
    var clicks = ClickHighlight()
    var keystrokes = KeystrokeDisplay()
    /// Off until someone turns it on, because it needs the camera.
    var camera = CameraBubble(isVisible: false)
    var audio = AudioPreferences()

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
        countdown = get(.countdown, d.countdown)
        dimOutside = get(.dimOutside, d.dimOutside)
        hideDesktopIcons = get(.hideDesktopIcons, d.hideDesktopIcons)
        hideNotifications = get(.hideNotifications, d.hideNotifications)
        clicks = get(.clicks, d.clicks)
        keystrokes = get(.keystrokes, d.keystrokes)
        camera = get(.camera, d.camera)
        camera.fullScreen = []
        audio = get(.audio, d.audio)
    }

    /// A frame rate that is not offered becomes the nearest one that is.
    func normalized() -> RecordingPreferences {
        var p = self
        p.fps = Self.fpsChoices.min { abs($0 - fps) < abs($1 - fps) } ?? 60
        p.countdown = Self.countdownChoices.min { abs($0 - countdown) < abs($1 - countdown) } ?? 0
        return p
    }

    func options(for style: RecordingStyle) -> RecordingOptions {
        RecordingOptions(fps: fps, showsCursor: style != .editing && showCursor, quality: quality, density: density, limit: limit,
                         exclusion: ContentExclusion(hidesNotifications: hideNotifications, hidesDesktopIcons: hideDesktopIcons),
                         capturesSystemAudio: audio(for: style).systemAudio)
    }

    func audio(for style: RecordingStyle) -> AudioPreferences { style == .gif ? AudioPreferences.none : audio }

    /// Keys are watched only when shown, because typed text can be private. A project keeps every click so rings can be added later.
    func inputCapture(for style: RecordingStyle) -> InputCapture {
        InputCapture(clicks: style == .editing || clicks.isVisible, keys: keystrokes.isVisible ? keystrokes.keys : nil)
    }

    func marks(for style: RecordingStyle) -> InputMarks? {
        style == .editing ? nil : InputMarks(clicks: clicks, keystrokes: keystrokes)
    }

    var showsInput: Bool { clicks.isVisible || keystrokes.isVisible }

    /// The part of these settings the recording panel's options menu reads and writes.
    var quick: RecordingQuickOptions {
        get {
            var o = RecordingQuickOptions()
            o.quality = quality
            o.fps = fps
            o.countdown = countdown
            o.showCursor = showCursor
            o.dimOutside = dimOutside
            o.hideNotifications = hideNotifications
            o.hideDesktopIcons = hideDesktopIcons
            return o
        }
        set {
            quality = newValue.quality
            fps = newValue.fps
            countdown = newValue.countdown
            showCursor = newValue.showCursor
            dimOutside = newValue.dimOutside
            hideNotifications = newValue.hideNotifications
            hideDesktopIcons = newValue.hideDesktopIcons
        }
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
    /// The interface language the user picked. Nil follows the Mac's preferred languages.
    var language: Language?

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
        language = get(.language, d.language)
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

    /// The language the interface shows: the one picked, else the first of `preferences` that Cornermark speaks, else English.
    func interfaceLanguage(preferences: [String]) -> Language {
        language ?? Language.resolve(preferences: preferences)
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
