import AppKit
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

/// Starts and stops the one recording the app may have at a time.
@MainActor
final class RecordingController {
    enum Phase: Equatable { case idle, starting, recording, stopping }

    private let env: AppEnvironment
    private let folder: () -> URL
    private(set) var phase = Phase.idle
    private var recorder: Recorder?
    /// Set for a recording for editing, whose project is written beside its video when it finishes.
    private var projectFolder: URL?
    private var style = RecordingStyle.editing
    private var stopWhenStarted = false
    private var activity: NSObjectProtocol?
    /// The project folder, or the video file of a plain recording.
    var onSaved: (URL) -> Void = { _ in }
    var onFailed: (String) -> Void = { _ in }

    init(env: AppEnvironment, folder: @escaping () -> URL) {
        self.env = env
        self.folder = folder
    }

    func start(_ target: RecordingTarget, style: RecordingStyle = .editing) {
        guard phase == .idle else { return Log.shell.error("recording refused: one is already running") }
        let options = RecordingOptions.for(style)
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
        self.style = style
        let name = (projectFolder ?? output).lastPathComponent
        // A finished video has its pointer in the picture, so nothing watches it.
        let recorder = Recorder(source: source, output: output, pointer: style == .editing ? env.pointerSource() : nil)
        let kind = source is FixtureFrameSource ? "fixture" : "screen"
        recorder.onFailure = { [weak self] error in
            Task { @MainActor in self?.sourceEnded(error) }
        }
        self.recorder = recorder
        phase = .starting
        stopWhenStarted = false
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "Recording the screen")
        Task {
            do {
                try await recorder.start()
                let size = recorder.format.map { "\($0.width)x\($0.height)" } ?? "?"
                Log.shell.notice("recording started project=\(name, privacy: .public) style=\(style.rawValue, privacy: .public) source=\(kind, privacy: .public) size=\(size, privacy: .public) fps=\(options.fps, privacy: .public) clock=\(String(format: "%.6f", recordingClockNow()), privacy: .public)")
                phase = .recording
                if stopWhenStarted { await finish() }
            } catch {
                Log.shell.error("recording failed to start: \(String(describing: error), privacy: .public)")
                reset()
                onFailed(error as? RecordingError == .permissionDenied ? "Screen recording is not allowed" : "Could not start recording")
            }
        }
    }

    func stop() {
        switch phase {
        case .recording: Task { await finish() }
        case .starting: stopWhenStarted = true
        case .idle, .stopping:
            Log.shell.error("recording refused: nothing is recording")
            env.recordingTestWindow?.close()
        }
    }

    private func sourceEnded(_ error: Error) {
        guard phase == .recording else { return }
        Log.shell.error("recording source ended: \(String(describing: error), privacy: .public)")
        Task { await finish() }
    }

    private func finish() async {
        guard let recorder, phase == .recording || phase == .starting else { return }
        phase = .stopping
        do {
            let report = try await recorder.stop()
            if let folder = projectFolder { try RecordingProjectFile.write(report.project, to: folder) }
            let rate = String(format: "%.3f", report.dropRate * 100)
            let seconds = String(format: "%.3f", report.duration)
            let saved = projectFolder ?? report.url
            let name = saved.lastPathComponent, style = self.style
            Log.shell.notice("recording finished project=\(name, privacy: .public) style=\(style.rawValue, privacy: .public) file=\(report.url.lastPathComponent, privacy: .public) pointerSamples=\(report.pointer.count, privacy: .public) firstFrame=\(String(format: "%.6f", report.firstFrameTime), privacy: .public) frames=\(report.framesWritten, privacy: .public) dropped=\(report.framesDropped, privacy: .public) dropPercent=\(rate, privacy: .public) seconds=\(seconds, privacy: .public) bytes=\(report.fileBytes, privacy: .public) size=\(report.format.width, privacy: .public)x\(report.format.height, privacy: .public)")
            reset()
            onSaved(saved)
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
        projectFolder = nil
        phase = .idle
        env.recordingTestWindow?.close()
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
    }
}
