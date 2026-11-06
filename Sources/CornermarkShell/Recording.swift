import AppKit
import AVFoundation
import CornermarkCapture
import CornermarkCore
import CornermarkVideoEditor
import ImageIO

/// Why an environment will not record a target. Nothing was filmed when one of these is thrown.
enum RecordingRefusal: Error, Equatable, CustomStringConvertible {
    case unavailable
    case notTestWindow(CGWindowID)
    case noTestWindow
    case unknownDisplay(CGDirectDisplayID)

    var description: String {
        switch self {
        case .unavailable: return "this environment cannot record"
        case .notTestWindow(let id): return "window \(id) is not this instance's test window"
        case .noTestWindow: return "this instance has no test window, send record/test-window first"
        case .unknownDisplay(let id): return "display \(id) is not the fixture display"
        }
    }
}

/// The window a scripted instance owns and films. It holds a synthetic scene and no real content.
@MainActor
protocol RecordingTestWindowHosting: AnyObject {
    var windowID: CGWindowID? { get }
    @discardableResult func show() -> CGWindowID?
    /// Makes one of the instance's own windows the test window, in place of the synthetic scene. `close` closes it.
    @discardableResult func adopt(_ window: NSWindow) -> CGWindowID?
    func close()
}

enum RecordingOutput {
    /// `Cornermark Recording 2026-11-03 at 14.05.09`, the name of a recording's folder.
    static func folderName(for date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "'Cornermark Recording' yyyy-MM-dd 'at' HH.mm.ss"
        return f.string(from: date)
    }

    /// A project package. Never overwrites: a second recording within the same second gets " 2", " 3", and so on.
    static func uniqueFolder(in folder: URL, for date: Date) -> URL {
        unique(in: folder, base: folderName(for: date), suffix: ".\(RecordingProjectFile.packageExtension)", isDirectory: true)
    }

    /// A finished file, `Cornermark Recording 2026-11-03 at 14.05.09.mp4` or `.gif`, never overwriting either.
    static func uniqueFile(in folder: URL, for date: Date, extension ext: String) -> URL {
        unique(in: folder, base: folderName(for: date), suffix: ".\(ext)", isDirectory: false)
    }

    /// A GIF made from an existing video sits beside it under the same name, never overwriting.
    static func gifBeside(_ video: URL) -> URL {
        unique(in: video.deletingLastPathComponent(), base: video.deletingPathExtension().lastPathComponent, suffix: ".gif", isDirectory: false)
    }

    /// Where a sound track is written while recording. A project keeps it in its folder. A video keeps it hidden beside the file until
    /// it is mixed into the video.
    static func audioFile(_ kind: AudioTrackReport.Kind, for destination: RecordedVideo) -> URL {
        let project = kind == .microphone ? RecordingProjectFile.microphoneName : RecordingProjectFile.systemAudioName
        if destination.format == .project { return destination.location.appendingPathComponent(project) }
        let base = destination.location.deletingPathExtension().lastPathComponent
        return destination.location.deletingLastPathComponent().appendingPathComponent(".\(base).\(project)")
    }

    /// Where a recording in `style` lands, with nothing created yet.
    static func destination(_ style: RecordingStyle, in folder: URL, for date: Date) -> RecordedVideo {
        let location: URL
        switch style {
        case .editing: location = uniqueFolder(in: folder, for: date)
        case .video: location = uniqueFile(in: folder, for: date, extension: "mp4")
        case .gif: location = uniqueFile(in: folder, for: date, extension: "gif")
        }
        return RecordedVideo(location: location, format: style.format, duration: 0)
    }

    /// Writes the GIF a recording asked for from the video it filmed, then removes that video. When the GIF cannot be made the video
    /// is kept beside where the GIF would be, as a plain recording, so nothing filmed is lost. `failed` says which happened.
    static func finishGif(_ gif: URL, kind: CaptureKind) async -> (recording: FinishedRecording, failed: Bool)? {
        let film = RecordedVideo(location: gif, format: .gif, duration: 0).film
        do {
            let made = try await makeGif(from: film, to: gif, kind: kind)
            try? FileManager.default.removeItem(at: film)
            return (made, false)
        } catch {
            Log.shell.error("gif not written file=\(gif.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)")
            try? FileManager.default.removeItem(at: gif)
            let kept = unique(in: gif.deletingLastPathComponent(), base: gif.deletingPathExtension().lastPathComponent, suffix: ".mp4", isDirectory: false)
            guard (try? FileManager.default.moveItem(at: film, to: kept)) != nil else { return nil }
            let asset = AVURLAsset(url: kept)
            let seconds = (try? await asset.load(.duration).seconds) ?? 0
            let size = (try? await asset.loadTracks(withMediaType: .video).first?.load(.naturalSize)) ?? .zero
            return (FinishedRecording(video: RecordedVideo(location: kept, format: .video, duration: seconds), pixelSize: size, kind: kind), true)
        }
    }

    /// Writes `gif` from the video at `video`, which stays as it is.
    static func makeGif(from video: URL, to gif: URL, kind: CaptureKind) async throws -> FinishedRecording {
        let report = try await GifConverter.convert(video, to: gif)
        Log.shell.notice("gif written file=\(gif.lastPathComponent, privacy: .public) from=\(video.lastPathComponent, privacy: .public) frames=\(report.frames, privacy: .public) size=\(report.width, privacy: .public)x\(report.height, privacy: .public) seconds=\(String(format: "%.2f", report.duration), privacy: .public) bytes=\(report.bytes, privacy: .public)")
        return FinishedRecording(video: RecordedVideo(location: gif, format: .gif, duration: report.duration),
                                 pixelSize: CGSize(width: report.width, height: report.height), kind: kind)
    }

    private static func unique(in folder: URL, base: String, suffix: String, isDirectory: Bool) -> URL {
        var url = folder.appendingPathComponent(base + suffix, isDirectory: isDirectory)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(base) \(n)\(suffix)", isDirectory: isDirectory)
            n += 1
        }
        return url
    }
}

/// A recording that reached its file, with what history needs to list it.
struct FinishedRecording: Equatable {
    var video: RecordedVideo
    var pixelSize: CGSize
    /// What was filmed, in the terms history already uses.
    var kind: CaptureKind
}

extension RecordingStyle {
    var format: RecordedVideo.Format {
        switch self {
        case .video: return .video
        case .editing: return .project
        case .gif: return .gif
        }
    }
}

extension RecordingTarget {
    var captureKind: CaptureKind {
        switch self {
        case .window: return .window
        case .display(_, area: nil): return .fullscreen
        case .display: return .area
        }
    }
}

/// Starts, pauses and stops the one recording the app may have at a time.
@MainActor
final class RecordingController {
    enum Phase: Equatable {
        case idle
        /// The source is being prepared, so the area is not known yet.
        case starting
        case countingDown(Int)
        case recording
        case paused
        case stopping

        /// A file is open and growing or held.
        var isRunning: Bool { self == .recording || self == .paused }
    }

    /// What one press of a start button asked for. A restart begins it again with the same values.
    private struct Request {
        var target: RecordingTarget
        var style: RecordingStyle
        var preferences: RecordingPreferences
    }

    private let env: AppEnvironment
    private let folder: () -> URL
    private(set) var phase = Phase.idle {
        didSet { if phase != oldValue { onChange() } }
    }
    /// What the pictures show, in global AppKit points, once the source knows.
    private(set) var area: CGRect?
    private(set) var target: RecordingTarget?
    private(set) var preferences = RecordingPreferences()
    private var request: Request?
    private var recorder: Recorder?
    /// Where the recording lands. Its `film` is the file the recorder writes.
    private var destination: RecordedVideo?
    private var journalEntry: RecordingJournal.Entry?
    /// A stop before the first frame with no countdown still records, so a link pair `record` then `record/stop` makes a file.
    private var stopRequested = false
    /// A stop during the countdown ends it with no file.
    private var cancelRequested = false
    private var activity: NSObjectProtocol?
    /// The camera's look while a recording with the camera runs. The bubble on screen and the recorder both read it.
    private(set) var cameraLook: CameraLook?
    /// Camera pictures for the bubble on screen, from the camera's queue.
    let cameraFeed = CameraFeed()
    /// Called on the main thread when the camera's look changes during a recording.
    var onCameraChange: () -> Void = {}
    /// Seconds between countdown numbers. The harness shortens it.
    var countdownTick: TimeInterval = 1
    var onSaved: (FinishedRecording) -> Void = { _ in }
    var onFailed: (String) -> Void = { _ in }
    var onNotice: (String) -> Void = { _ in }
    /// Called on every phase change and when the area becomes known.
    var onChange: () -> Void = {}
    /// Called when the microphone's level or its silence changes, about 30 times a second while it records.
    var onMicrophone: () -> Void = {}
    /// The microphone being recorded, nil when none is.
    private(set) var microphone: MicrophoneStatus?
    private var hearing: MicrophoneHearing?
    /// The recording has a microphone, from the moment it is prepared, so the bar has its room from the start.
    var hearsMicrophone: Bool { hearing != nil }
    private var meterTimer: Timer?

    init(env: AppEnvironment, folder: @escaping () -> URL) {
        self.env = env
        self.folder = folder
    }

    /// The length of the video so far. A pause does not grow it.
    var seconds: Double { recorder?.seconds ?? 0 }

    func start(_ target: RecordingTarget, style: RecordingStyle = .editing, preferences: RecordingPreferences = RecordingPreferences()) {
        guard phase == .idle else { return Log.shell.error("recording refused: one is already running") }
        let options = preferences.options(for: style)
        let source: FrameSource
        do { source = try env.frameSource(target, options) } catch {
            Log.shell.error("recording refused: \(String(describing: error), privacy: .public)")
            return onFailed("Recording not allowed")
        }
        do { try FileManager.default.createDirectory(at: folder(), withIntermediateDirectories: true) } catch {
            Log.shell.error("recording refused: cannot create the folder: \(error.localizedDescription, privacy: .public)")
            return onFailed("Could not save the recording")
        }
        let destination = RecordingOutput.destination(style, in: folder(), for: env.clock())
        if destination.format == .project {
            do { try FileManager.default.createDirectory(at: destination.location, withIntermediateDirectories: false) } catch {
                Log.shell.error("recording refused: cannot create the project folder: \(error.localizedDescription, privacy: .public)")
                return onFailed("Could not save the recording")
            }
        }
        self.destination = destination
        self.target = target
        self.preferences = preferences
        cameraLook = preferences.camera.isVisible ? CameraLook(preferences.camera) : nil
        request = Request(target: target, style: style, preferences: preferences)
        // The activity keeps the display awake until `reset` ends it, countdown included.
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleDisplaySleepDisabled, .latencyCritical], reason: "Recording the screen")
        launch(source)
    }

    /// Prepares the source, counts down when asked, then films.
    private func launch(_ source: FrameSource) {
        guard let request, let destination else { return }
        let options = request.preferences.options(for: request.style)
        let name = destination.location.lastPathComponent
        let capture = request.preferences.inputCapture(for: request.style)
        let inputAllowed = env.hasInputPermission()
        let input = capture.isEmpty || !inputAllowed ? nil : env.inputSource(capture)
        if request.preferences.showsInput, !inputAllowed {
            Log.shell.error("recording input unavailable: Input Monitoring is not allowed, recording without clicks and keystrokes")
            onNotice("Turn on Input Monitoring to show clicks and keys")
        }
        let camera = cameraRecording(style: request.style, destination: destination)
        let sound = audio(for: request, destination: destination, source: source)
        // A finished video or GIF has its pointer in the picture, so nothing watches it.
        let recorder = Recorder(source: source, output: destination.film, pointer: request.style == .editing ? env.pointerSource() : nil,
                                input: input, marks: request.preferences.marks(for: request.style),
                                microphone: sound.microphone, systemAudio: sound.system, camera: camera, quality: options.quality)
        let inputKind = input.map { $0 is ScriptedInputSource ? "scripted" : "live" } ?? "none"
        let kind = source is FixtureFrameSource ? "fixture" : "screen"
        recorder.onFailure = { [weak self] error in
            Task { @MainActor in self?.sourceEnded(error) }
        }
        self.recorder = recorder
        stopRequested = false
        cancelRequested = false
        area = nil
        phase = .starting
        Task {
            do {
                _ = try await source.prepare()
                area = source.pointArea
                onChange()
                if stopRequested, request.preferences.countdown > 0 { cancelRequested = true }
                for n in stride(from: request.preferences.countdown, to: 0, by: -1) where !cancelRequested {
                    phase = .countingDown(n)
                    try await Task.sleep(nanoseconds: UInt64(countdownTick * 1_000_000_000))
                }
                if cancelRequested {
                    Log.shell.notice("recording cancelled before it started project=\(name, privacy: .public)")
                    return reset()
                }
                hearing?.restart(at: recordingClockNow())
                try await recorder.start()
                logAudio(request, sound, recorder)
                journalEntry = env.recordingJournal?.open(location: destination.location, format: destination.format,
                                                          kind: request.target.captureKind, area: recorder.pointArea)
                let size = recorder.format.map { "\($0.width)x\($0.height)" } ?? "?"
                Log.shell.notice("recording input source=\(inputKind, privacy: .public) clicks=\(capture.clicks, privacy: .public) keys=\(capture.keys?.rawValue ?? "off", privacy: .public) marksInPicture=\(recorder.marksInPicture, privacy: .public) failure=\(recorder.inputFailure.map(String.init(describing:)) ?? "none", privacy: .public) taps=\(LiveInputSource.tapsCreated, privacy: .public)")
                let cameraKind = camera.map { $0.source is ScriptedCameraSource ? "scripted" : "live" } ?? "none"
                Log.shell.notice("recording camera wanted=\(request.preferences.camera.isVisible, privacy: .public) source=\(cameraKind, privacy: .public) access=\(self.env.cameraAccess().rawValue, privacy: .public) inPicture=\(recorder.cameraInPicture, privacy: .public) failure=\(recorder.cameraFailure.map(String.init(describing:)) ?? "none", privacy: .public) requests=\(CameraAccess.requests, privacy: .public) sessions=\(LiveCameraSource.sessionsOpened, privacy: .public)")
                if recorder.cameraFailure != nil {
                    cameraLook = nil
                    onNotice("The camera could not start, so this recording has no camera. Quit other apps using the camera and record again.")
                }
                Log.shell.notice("recording started project=\(name, privacy: .public) style=\(request.style.rawValue, privacy: .public) source=\(kind, privacy: .public) size=\(size, privacy: .public) fps=\(options.fps, privacy: .public) quality=\(options.quality.rawValue, privacy: .public) cursorInPicture=\(options.showsCursor, privacy: .public) hideNotifications=\(options.exclusion.hidesNotifications, privacy: .public) hideDesktopIcons=\(options.exclusion.hidesDesktopIcons, privacy: .public) clock=\(String(format: "%.6f", recordingClockNow()), privacy: .public)")
                phase = .recording
                startMeter()
                if stopRequested { await finish() }
            } catch {
                Log.shell.error("recording failed to start: \(String(describing: error), privacy: .public)")
                reset()
                onFailed(error as? RecordingError == .permissionDenied ? "Screen recording is not allowed" : "Could not start recording")
            }
        }
    }

    /// The camera is drawn into a finished video or GIF, and written to its own file beside a project's video.
    private func cameraRecording(style: RecordingStyle, destination: RecordedVideo) -> CameraRecording? {
        guard cameraLook != nil else { return nil }
        guard env.cameraAccess() == .allowed, let source = env.cameraSource() else {
            cameraLook = nil
            guard env.cameraAccess() != .allowed else { return nil }
            Log.shell.error("recording camera unavailable: camera access is \(self.env.cameraAccess().rawValue, privacy: .public), recording without the camera")
            onNotice("Allow camera access in Settings > Camera to show the camera")
            return nil
        }
        guard let cameraLook else { return nil }
        let output = style == .editing ? destination.location.appendingPathComponent(RecordingProjectFile.cameraName) : nil
        let feed = cameraFeed
        return CameraRecording(source: source, output: output, look: cameraLook, preview: { feed.send($0) })
    }

    /// Changes the camera's look while recording. A click on the bubble toggles full screen through here too.
    func changeCamera(_ change: CameraChange) {
        guard phase != .idle, phase != .stopping, let look = cameraLook else { return Log.shell.error("recording refused: no camera is showing") }
        look.update { b in
            if let shape = change.shape { b.shape = shape }
            if let size = change.size { b.size = size }
            if let corner = change.corner { b.position = corner }
            if let mirrored = change.mirrored { b.isMirrored = mirrored }
        }
        if let full = change.fullScreen {
            let on: Bool
            switch full {
            case .on: on = true
            case .off: on = false
            case .toggle: on = !look.isFullScreen
            }
            look.setFullScreen(on, at: recordingClockNow())
        }
        let b = look.current
        Log.shell.notice("camera changed shape=\(b.shape.rawValue, privacy: .public) size=\(b.size.rawValue, privacy: .public) corner=\(b.position.rawValue, privacy: .public) mirrored=\(b.isMirrored, privacy: .public) fullScreen=\(look.isFullScreen, privacy: .public)")
        onCameraChange()
    }

    func pause() {
        guard phase == .recording, let recorder else { return Log.shell.error("recording refused: nothing to pause") }
        recorder.pause()
        hearing?.paused = true
        phase = .paused
        Log.shell.notice("recording paused seconds=\(String(format: "%.3f", recorder.seconds), privacy: .public)")
    }

    func resume() {
        guard phase == .paused, let recorder else { return Log.shell.error("recording refused: nothing to resume") }
        recorder.resume()
        hearing?.paused = false
        hearing?.restart(at: recordingClockNow())
        phase = .recording
        Log.shell.notice("recording resumed seconds=\(String(format: "%.3f", recorder.seconds), privacy: .public)")
    }

    /// Throws away what was filmed and begins again with the same target and settings, countdown included.
    func restart() {
        guard phase.isRunning, let recorder, let request else { return Log.shell.error("recording refused: nothing to restart") }
        phase = .stopping
        let discarded = recorder.seconds
        stopMeter()
        Task {
            await recorder.cancel()
            if let journalEntry { env.recordingJournal?.close(journalEntry) }
            journalEntry = nil
            Log.shell.notice("recording restarted discarded=\(String(format: "%.3f", discarded), privacy: .public)")
            do { launch(try env.frameSource(request.target, request.preferences.options(for: request.style))) } catch {
                Log.shell.error("recording refused: \(String(describing: error), privacy: .public)")
                reset()
                onFailed("Recording not allowed")
            }
        }
    }

    /// Throws away what was filmed and ends the recording: no file is left and nothing reaches History.
    func discard() {
        guard phase.isRunning, let recorder else { return Log.shell.error("recording refused: nothing to discard") }
        phase = .stopping
        let discarded = recorder.seconds
        stopMeter()
        Task {
            await recorder.cancel()
            Log.shell.notice("recording discarded seconds=\(String(format: "%.3f", discarded), privacy: .public)")
            reset()
        }
    }

    func stop() {
        switch phase {
        case .recording, .paused: Task { await finish() }
        case .starting: stopRequested = true
        case .countingDown: cancelRequested = true
        case .idle, .stopping:
            Log.shell.error("recording refused: nothing is recording")
            env.recordingTestWindow?.close()
        }
    }

    private func sourceEnded(_ error: Error) {
        guard phase.isRunning else { return }
        Log.shell.error("recording source ended: \(String(describing: error), privacy: .public)")
        Task { await finish() }
    }

    private func finish() async {
        guard let recorder, let request, let destination, phase.isRunning else { return }
        phase = .stopping
        stopMeter()
        do {
            let report = try await recorder.stop()
            logAudioFinished(report, recorder)
            if destination.format == .video, !report.audio.isEmpty { await mixSound(report, into: destination.film) }
            if destination.format == .project {
                var project = report.project
                project.edits.cursor.isVisible = request.preferences.showCursor
                project.edits.clicks = request.preferences.clicks
                project.edits.keystrokes = request.preferences.keystrokes
                try RecordingProjectFile.write(project, to: destination.location)
            }
            // A GIF's journal entry stays open until the GIF is written, so a crash while it is made is recovered at the next launch.
            let entry = journalEntry
            journalEntry = nil
            if destination.format != .gif, let entry { env.recordingJournal?.close(entry) }
            let rate = String(format: "%.3f", report.dropRate * 100)
            if let camera = report.camera {
                let b = camera.bubble
                Log.shell.notice("recording camera finished pictures=\(camera.pictures, privacy: .public) filled=\(camera.filled, privacy: .public) file=\(camera.file?.lastPathComponent ?? "none", privacy: .public) fullScreenSpans=\(b.fullScreen.count, privacy: .public) shape=\(b.shape.rawValue, privacy: .public) size=\(b.size.rawValue, privacy: .public) corner=\(b.position.rawValue, privacy: .public) mirrored=\(b.isMirrored, privacy: .public)")
            }
            let marked = recorder.markedFrames
            Log.shell.notice("recording input finished clicks=\(report.clicks.count, privacy: .public) keys=\(report.keys.count, privacy: .public) markedFrames=\(marked.marked, privacy: .public) filledFrames=\(marked.filled, privacy: .public)")
            let seconds = String(format: "%.3f", report.duration)
            let name = destination.location.lastPathComponent, style = request.style, kind = request.target.captureKind
            let finished = FinishedRecording(
                video: RecordedVideo(location: destination.location, format: destination.format, duration: report.project.source.duration),
                pixelSize: CGSize(width: report.format.width, height: report.format.height), kind: kind)
            Log.shell.notice("recording finished project=\(name, privacy: .public) style=\(style.rawValue, privacy: .public) file=\(report.url.lastPathComponent, privacy: .public) pointerSamples=\(report.pointer.count, privacy: .public) firstFrame=\(String(format: "%.6f", report.firstFrameTime), privacy: .public) frames=\(report.framesWritten, privacy: .public) dropped=\(report.framesDropped, privacy: .public) dropPercent=\(rate, privacy: .public) seconds=\(seconds, privacy: .public) pauses=\(report.pauses.count, privacy: .public) bytes=\(report.fileBytes, privacy: .public) bitRate=\(report.bitRate, privacy: .public) cursorShown=\(request.preferences.showCursor, privacy: .public) size=\(report.format.width, privacy: .public)x\(report.format.height, privacy: .public)")
            reset()
            guard destination.format == .gif else { return onSaved(finished) }
            // The recorder is free again while the GIF is made, so a new recording can start.
            let made = await RecordingOutput.finishGif(destination.location, kind: kind)
            if let entry { env.recordingJournal?.close(entry) }
            guard let made else { return onFailed("Could not save the recording") }
            if made.failed { onFailed("Could not convert the recording to GIF. It is saved as a video.") }
            onSaved(made.recording)
        } catch {
            Log.shell.error("recording failed to finish: \(String(describing: error), privacy: .public)")
            reset()
            onFailed("Could not save the recording")
        }
    }

    private func reset() {
        stopMeter()
        hearing = nil
        recorder = nil
        if let destination, destination.format == .project,
           (try? FileManager.default.contentsOfDirectory(atPath: destination.location.path))?.isEmpty == true {
            try? FileManager.default.removeItem(at: destination.location)
        }
        if let journalEntry { env.recordingJournal?.close(journalEntry) }
        journalEntry = nil
        destination = nil
        request = nil
        area = nil
        target = nil
        cameraLook = nil
        phase = .idle
        env.recordingTestWindow?.close()
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
    }
}

extension RecordingController {
    private struct Sound {
        var microphone: AudioRecording?
        var system: AudioRecording?
        var microphoneName = "none"
        var kind = "none"
    }

    /// The sound sources a recording asked for and may have. A microphone without access is left out with a notice, and never asked for.
    private func audio(for request: Request, destination: RecordedVideo, source: FrameSource) -> Sound {
        let prefs = request.preferences.audio(for: request.style)
        var sound = Sound()
        hearing = nil
        if prefs.microphone {
            if env.microphoneAccess() != .allowed {
                Log.shell.error("recording microphone unavailable: access=\(self.env.microphoneAccess().rawValue, privacy: .public), recording without it")
                onNotice("Turn on microphone access in System Settings to record your voice")
            } else if let mic = env.microphoneSource(prefs.microphoneID) {
                let hearing = MicrophoneHearing(start: recordingClockNow())
                self.hearing = hearing
                sound.microphone = AudioRecording(source: mic, output: RecordingOutput.audioFile(.microphone, for: destination), mono: prefs.mono) { level, end in
                    hearing.hear(level, until: end)
                }
                sound.microphoneName = env.microphones().first { $0.id == prefs.microphoneID }?.name ?? "default"
                sound.kind = mic is ScriptedAudioSource ? "scripted" : "live"
            }
        }
        if prefs.systemAudio, let system = env.systemAudioSource(source) {
            sound.system = AudioRecording(source: system, output: RecordingOutput.audioFile(.system, for: destination))
            if sound.kind == "none" { sound.kind = system is ScriptedAudioSource ? "scripted" : "live" }
        }
        microphone = nil
        return sound
    }

    private func logAudio(_ request: Request, _ sound: Sound, _ recorder: Recorder) {
        let prefs = request.preferences.audio(for: request.style)
        let failures = recorder.audioFailures.map { "\($0.key.rawValue):\($0.value)" }.sorted().joined(separator: ",")
        Log.shell.notice("recording audio microphone=\(sound.microphone != nil && recorder.audioFailures[.microphone] == nil, privacy: .public) device=\(sound.microphoneName, privacy: .public) mono=\(prefs.mono, privacy: .public) system=\(sound.system != nil && recorder.audioFailures[.system] == nil, privacy: .public) source=\(sound.kind, privacy: .public) failure=\(failures.isEmpty ? "none" : failures, privacy: .public) realMicrophoneAccess=\(MicrophoneAccess.current.rawValue, privacy: .public) devicesOpened=\(LiveMicrophoneSource.sessionsOpened, privacy: .public) accessRequests=\(MicrophoneAccess.requests, privacy: .public)")
        if recorder.audioFailures[.microphone] != nil {
            hearing = nil
            onNotice("Could not record the microphone")
        }
    }

    private func logAudioFinished(_ report: RecordingReport, _ recorder: Recorder) {
        guard !report.audio.isEmpty || !recorder.audioFailures.isEmpty else { return }
        let tracks = report.audio.map {
            "\($0.kind.rawValue)=\($0.url.lastPathComponent) seconds=\(String(format: "%.3f", $0.duration)) channels=\($0.channels) rate=\(Int($0.rate)) filled=\(String(format: "%.3f", $0.filled))"
        }.joined(separator: " ")
        Log.shell.notice("recording audio finished \(tracks, privacy: .public) videoSeconds=\(String(format: "%.3f", report.project.source.duration), privacy: .public) devicesOpened=\(LiveMicrophoneSource.sessionsOpened, privacy: .public) accessRequests=\(MicrophoneAccess.requests, privacy: .public)")
    }

    /// A finished video carries its sound in the file: the tracks are mixed into it and their hidden files removed. When that fails the
    /// video stays without sound and a notice says so.
    private func mixSound(_ report: RecordingReport, into film: URL) async {
        let mixed = film.deletingLastPathComponent().appendingPathComponent(".\(film.deletingPathExtension().lastPathComponent).mixing.mp4")
        do {
            try await AudioMux.mux(video: film, audio: report.audio.map(\.url), to: mixed)
            _ = try FileManager.default.replaceItemAt(film, withItemAt: mixed)
            Log.shell.notice("recording sound mixed file=\(film.lastPathComponent, privacy: .public) tracks=\(report.audio.count, privacy: .public)")
        } catch {
            try? FileManager.default.removeItem(at: mixed)
            Log.shell.error("recording sound not mixed: \(String(describing: error), privacy: .public)")
            onNotice("Could not add the sound. The video is saved without it.")
        }
        report.audio.forEach { try? FileManager.default.removeItem(at: $0.url) }
    }

    private func startMeter() {
        guard hearing != nil, meterTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.readMeter() } }
        RunLoop.main.add(timer, forMode: .common)
        meterTimer = timer
        readMeter()
    }

    private func stopMeter() {
        meterTimer?.invalidate()
        meterTimer = nil
        if microphone != nil {
            microphone = nil
            onMicrophone()
        }
    }

    private func readMeter() {
        guard let hearing else { return }
        let next = hearing.status(at: recordingClockNow())
        let was = microphone
        microphone = next
        if next.isSilent != (was?.isSilent ?? false) {
            if next.isSilent {
                Log.shell.notice("recording microphone silent seconds=\(String(format: "%.3f", self.seconds), privacy: .public) quietFor=\(String(format: "%.1f", next.quietFor), privacy: .public)")
            } else {
                Log.shell.notice("recording microphone sound again seconds=\(String(format: "%.3f", self.seconds), privacy: .public)")
            }
        }
        if next != was { onMicrophone() }
    }
}

/// What the control bar shows of the microphone.
struct MicrophoneStatus: Equatable {
    var level: AudioLevel
    /// No sound for `MicrophoneSilence.delay` seconds: muted, its volume at zero, or no longer sending.
    var isSilent: Bool
    var quietFor: Double
}

/// The microphone's latest level and its silence, written on the sound's queue and read on the main thread.
final class MicrophoneHearing: @unchecked Sendable {
    private let lock = NSLock()
    private var silence: MicrophoneSilence
    private var level = AudioLevel.silence
    /// While paused nothing is recorded, so silence is not a problem.
    var paused: Bool {
        get { lock.withLock { isPaused } }
        set { lock.withLock { isPaused = newValue } }
    }
    private var isPaused = false

    init(start: Double) { silence = MicrophoneSilence(start: start) }

    func hear(_ level: AudioLevel, until end: Double) {
        lock.withLock {
            self.level = level
            if !isPaused { silence.hear(level, until: end) }
        }
    }

    func restart(at time: Double) { lock.withLock { silence.restart(at: time) } }

    func status(at now: Double) -> MicrophoneStatus {
        lock.withLock {
            MicrophoneStatus(level: isPaused ? .silence : level, isSilent: !isPaused && silence.isSilent(at: now), quietFor: max(0, now - silence.lastSound))
        }
    }
}

/// The picture a recording shows in Quick Access and History: its first frame.
enum VideoPoster {
    static let maxPixel = 1920

    static func image(of video: RecordedVideo) async -> CGImage? {
        if video.format == .gif {
            return CGImageSourceCreateWithURL(video.file as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
        }
        return await image(of: video.file)
    }

    static func image(of file: URL) async -> CGImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: file))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixel, height: maxPixel)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        return try? await generator.image(at: .zero).image
    }

    /// Stands in when the video cannot be read, so the recording is still listed.
    static func placeholder(_ size: CGSize) -> CGImage {
        let long = max(size.width, size.height, 1)
        let w = max(2, Int(size.width / long * 320)), h = max(2, Int(size.height / long * 320))
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 0.12, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()!
    }
}
