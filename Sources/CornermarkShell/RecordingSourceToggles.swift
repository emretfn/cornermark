import AppKit
import CornermarkCapture
import CornermarkL10n

/// Where a permission stands, read without asking.
enum PermissionAnswer: String, Equatable {
    case allowed, denied, notAsked

    init(_ access: MicrophoneAccess) { self.init(rawValue: access.rawValue)! }
    init(_ access: CameraAccess) { self.init(rawValue: access.rawValue)! }
}

extension RecordingSource {
    /// Whether the settings ask for this source.
    func isWanted(in p: RecordingPreferences) -> Bool {
        switch self {
        case .microphone: return p.audio.microphone
        case .systemAudio: return p.audio.systemAudio
        case .camera: return p.camera.isVisible
        case .clicks: return p.clicks.isVisible
        case .keystrokes: return p.keystrokes.isVisible
        }
    }

    func set(_ on: Bool, in p: inout RecordingPreferences) {
        switch self {
        case .microphone: p.audio.microphone = on
        case .systemAudio: p.audio.systemAudio = on
        case .camera: p.camera.isVisible = on
        case .clicks: p.clicks.isVisible = on
        case .keystrokes: p.keystrokes.isVisible = on
        }
    }

    /// How to allow a source macOS refused. The privacy pane's name matches System Settings.
    var deniedNote: String {
        switch self {
        case .microphone: return tr("Turn on Cornermark in System Settings > Privacy & Security > Microphone.")
        case .systemAudio: return tr("Turn on Cornermark in System Settings > Privacy & Security > Screen & System Audio Recording.")
        case .camera: return tr("Turn on Cornermark in System Settings > Privacy & Security > Camera.")
        case .clicks, .keystrokes: return tr("Turn on Cornermark in System Settings > Privacy & Security > Input Monitoring, then reopen it.")
        }
    }
}

/// The recording panel's toggles. They read and write the same `RecordingPreferences` as the Settings panes, and a toggle turned on
/// asks for its permission when macOS has not asked yet, so the question comes the moment someone wants the source.
///
/// A toggle shows on only when the next recording really takes the source: wanted in the settings and allowed. A refused source is
/// written off, so the panel and Settings agree, and the note says how to allow it.
@MainActor
final class RecordingSourceToggles {
    static let inputAskedKey = "cornermark.inputMonitoringAsked"
    private let env: AppEnvironment
    private let settings: SettingsStore
    /// The source macOS just refused. Its note stays until the next toggle changes a setting.
    private var refused: RecordingSource?
    private var asking: Set<RecordingSource> = []
    /// Called once an answer from macOS changes what the panel shows.
    var onChange: () -> Void = {}
    /// True while a microphone or camera prompt is open, false once every answer is back. The overlay steps aside for the prompt.
    var onAsking: (Bool) -> Void = { _ in }
    /// Called just before Input Monitoring is requested. macOS sends no answer for it and the permission works only after Cornermark
    /// reopens, so the overlay closes first instead of waiting over the prompt.
    var onInputRequest: () -> Void = {}
    static var waitingNote: String { tr("Waiting for permission. Answer the macOS prompt to go on.") }

    init(env: AppEnvironment, settings: SettingsStore) {
        self.env = env
        self.settings = settings
    }

    /// Nil for a source that needs no permission beyond Screen Recording.
    func answer(_ source: RecordingSource) -> PermissionAnswer? {
        switch source {
        case .systemAudio: return nil
        case .microphone: return PermissionAnswer(env.microphoneAccess())
        case .camera: return PermissionAnswer(env.cameraAccess())
        case .clicks, .keystrokes:
            // macOS reads Input Monitoring as allowed or not, so whether it was asked is remembered here.
            if env.hasInputPermission() { return .allowed }
            return env.defaults.bool(forKey: Self.inputAskedKey) ? .denied : .notAsked
        }
    }

    var state: RecordingSources {
        let prefs = settings.value.recording
        let on = Set(RecordingSource.allCases.filter { $0.isWanted(in: prefs) && (answer($0) ?? .allowed) == .allowed })
        if !asking.isEmpty { return RecordingSources(on: on, pending: asking, note: .waiting(Self.waitingNote)) }
        if let refused { return RecordingSources(on: on, note: .blocked(refused.deniedNote)) }
        if let waiting = RecordingSource.allCases.first(where: { $0.isWanted(in: prefs) && !on.contains($0) }) {
            let text = answer(waiting) == .denied ? waiting.deniedNote : tr("Turn on {source} to allow access.", ["source": waiting.name])
            return RecordingSources(on: on, note: .blocked(text))
        }
        if on.contains(.microphone) || on.contains(.systemAudio) { return RecordingSources(on: on, note: .hint(tr("Record GIF never records sound."))) }
        return RecordingSources(on: on)
    }

    func toggle(_ source: RecordingSource) {
        if state.on.contains(source) {
            write(source, false)
            return
        }
        switch answer(source) ?? .allowed {
        case .allowed:
            write(source, true)
        case .denied:
            write(source, false, refused: source)
        case .notAsked:
            guard !asking.contains(source) else { return }
            Log.shell.notice("recording panel asks for access source=\(source.rawValue, privacy: .public)")
            if source == .clicks || source == .keystrokes {
                onInputRequest()
                env.defaults.set(true, forKey: Self.inputAskedKey)
                let granted = env.requestInputPermission()
                Log.shell.notice("recording panel access answer source=\(source.rawValue, privacy: .public) granted=\(granted, privacy: .public)")
                return write(source, granted, refused: granted ? nil : source)
            }
            asking.insert(source)
            if asking.count == 1 { onAsking(true) }
            onChange()
            request(source) { [weak self] granted in
                guard let self else { return }
                asking.remove(source)
                Log.shell.notice("recording panel access answer source=\(source.rawValue, privacy: .public) granted=\(granted, privacy: .public)")
                write(source, granted, refused: granted ? nil : source)
                if asking.isEmpty { onAsking(false) }
                onChange()
            }
        }
    }

    /// Forgets a refusal, so a new overlay starts from the settings alone.
    func reset() { refused = nil }

    private func write(_ source: RecordingSource, _ on: Bool, refused: RecordingSource? = nil) {
        self.refused = refused
        settings.update { source.set(on, in: &$0.recording) }
        Log.shell.notice("recording panel source=\(source.rawValue, privacy: .public) on=\(on, privacy: .public)")
    }

    private func request(_ source: RecordingSource, _ done: @escaping (Bool) -> Void) {
        switch source {
        case .microphone: env.requestMicrophoneAccess(done)
        case .camera: env.requestCameraAccess(done)
        case .clicks, .keystrokes, .systemAudio: done(true)
        }
    }
}
