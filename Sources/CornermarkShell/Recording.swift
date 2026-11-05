import AppKit
import AVFoundation
import CornermarkCapture
import CornermarkCore

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

    /// Never overwrites: a second recording within the same second gets " 2", " 3", and so on.
    static func uniqueFolder(in folder: URL, for date: Date) -> URL { unique(in: folder, base: folderName(for: date), suffix: "", isDirectory: true) }

    /// A finished video's file, `Cornermark Recording 2026-11-03 at 14.05.09.mp4`, never overwriting either.
    static func uniqueVideo(in folder: URL, for date: Date) -> URL { unique(in: folder, base: folderName(for: date), suffix: ".mp4", isDirectory: false) }

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
    /// Set for a recording for editing, whose project is written beside its video when it finishes.
    private var projectFolder: URL?
    private var output: URL?
    private var journalEntry: RecordingJournal.Entry?
    /// A stop before the first frame with no countdown still records, so a link pair `record` then `record/stop` makes a file.
    private var stopRequested = false
    /// A stop during the countdown ends it with no file.
    private var cancelRequested = false
    private var activity: NSObjectProtocol?
    /// Seconds between countdown numbers. The harness shortens it.
    var countdownTick: TimeInterval = 1
    var onSaved: (FinishedRecording) -> Void = { _ in }
    var onFailed: (String) -> Void = { _ in }
    /// Called on every phase change and when the area becomes known.
    var onChange: () -> Void = {}

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
        let output: URL
        switch style {
        case .editing:
            let project = RecordingOutput.uniqueFolder(in: folder(), for: env.clock())
            do { try FileManager.default.createDirectory(at: project, withIntermediateDirectories: false) } catch {
                Log.shell.error("recording refused: cannot create the project folder: \(error.localizedDescription, privacy: .public)")
                return onFailed("Could not save the recording")
            }
            projectFolder = project
            output = project.appendingPathComponent(RecordingProjectFile.videoName)
        case .video:
            output = RecordingOutput.uniqueVideo(in: folder(), for: env.clock())
        }
        self.output = output
        self.target = target
        self.preferences = preferences
        request = Request(target: target, style: style, preferences: preferences)
        // The activity keeps the display awake until `reset` ends it, countdown included.
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleDisplaySleepDisabled, .latencyCritical], reason: "Recording the screen")
        launch(source)
    }

    /// Prepares the source, counts down when asked, then films.
    private func launch(_ source: FrameSource) {
        guard let request, let output else { return }
        let options = request.preferences.options(for: request.style)
        let name = (projectFolder ?? output).lastPathComponent
        // A finished video has its pointer in the picture, so nothing watches it.
        let recorder = Recorder(source: source, output: output, pointer: request.style == .editing ? env.pointerSource() : nil, quality: options.quality)
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
                try await recorder.start()
                journalEntry = env.recordingJournal?.open(location: projectFolder ?? output, format: projectFolder == nil ? .video : .project,
                                                          kind: request.target.captureKind, area: recorder.pointArea)
                let size = recorder.format.map { "\($0.width)x\($0.height)" } ?? "?"
                Log.shell.notice("recording started project=\(name, privacy: .public) style=\(request.style.rawValue, privacy: .public) source=\(kind, privacy: .public) size=\(size, privacy: .public) fps=\(options.fps, privacy: .public) quality=\(options.quality.rawValue, privacy: .public) cursorInPicture=\(options.showsCursor, privacy: .public) hideNotifications=\(options.exclusion.hidesNotifications, privacy: .public) hideDesktopIcons=\(options.exclusion.hidesDesktopIcons, privacy: .public) clock=\(String(format: "%.6f", recordingClockNow()), privacy: .public)")
                phase = .recording
                if stopRequested { await finish() }
            } catch {
                Log.shell.error("recording failed to start: \(String(describing: error), privacy: .public)")
                reset()
                onFailed(error as? RecordingError == .permissionDenied ? "Screen recording is not allowed" : "Could not start recording")
            }
        }
    }

    func pause() {
        guard phase == .recording, let recorder else { return Log.shell.error("recording refused: nothing to pause") }
        recorder.pause()
        phase = .paused
        Log.shell.notice("recording paused seconds=\(String(format: "%.3f", recorder.seconds), privacy: .public)")
    }

    func resume() {
        guard phase == .paused, let recorder else { return Log.shell.error("recording refused: nothing to resume") }
        recorder.resume()
        phase = .recording
        Log.shell.notice("recording resumed seconds=\(String(format: "%.3f", recorder.seconds), privacy: .public)")
    }

    /// Throws away what was filmed and begins again with the same target and settings, countdown included.
    func restart() {
        guard phase.isRunning, let recorder, let request else { return Log.shell.error("recording refused: nothing to restart") }
        phase = .stopping
        let discarded = recorder.seconds
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
        guard let recorder, let request, phase.isRunning else { return }
        phase = .stopping
        do {
            let report = try await recorder.stop()
            if let folder = projectFolder {
                var project = report.project
                project.edits.cursor.isVisible = request.preferences.showCursor
                try RecordingProjectFile.write(project, to: folder)
            }
            if let journalEntry { env.recordingJournal?.close(journalEntry) }
            journalEntry = nil
            let rate = String(format: "%.3f", report.dropRate * 100)
            let seconds = String(format: "%.3f", report.duration)
            let saved = projectFolder ?? report.url
            let name = saved.lastPathComponent, style = request.style
            let finished = FinishedRecording(
                video: RecordedVideo(location: saved, format: projectFolder == nil ? .video : .project, duration: report.project.source.duration),
                pixelSize: CGSize(width: report.format.width, height: report.format.height), kind: request.target.captureKind)
            Log.shell.notice("recording finished project=\(name, privacy: .public) style=\(style.rawValue, privacy: .public) file=\(report.url.lastPathComponent, privacy: .public) pointerSamples=\(report.pointer.count, privacy: .public) firstFrame=\(String(format: "%.6f", report.firstFrameTime), privacy: .public) frames=\(report.framesWritten, privacy: .public) dropped=\(report.framesDropped, privacy: .public) dropPercent=\(rate, privacy: .public) seconds=\(seconds, privacy: .public) pauses=\(report.pauses.count, privacy: .public) bytes=\(report.fileBytes, privacy: .public) bitRate=\(report.bitRate, privacy: .public) cursorShown=\(request.preferences.showCursor, privacy: .public) size=\(report.format.width, privacy: .public)x\(report.format.height, privacy: .public)")
            reset()
            onSaved(finished)
        } catch {
            Log.shell.error("recording failed to finish: \(String(describing: error), privacy: .public)")
            reset()
            onFailed("Could not save the recording")
        }
    }

    private func reset() {
        recorder = nil
        if let folder = projectFolder, (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.isEmpty == true {
            try? FileManager.default.removeItem(at: folder)
        }
        if let journalEntry { env.recordingJournal?.close(journalEntry) }
        journalEntry = nil
        projectFolder = nil
        output = nil
        request = nil
        area = nil
        target = nil
        phase = .idle
        env.recordingTestWindow?.close()
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
    }
}

/// The picture a recording shows in Quick Access and History: its first frame.
enum VideoPoster {
    static let maxPixel = 1920

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
