import CoreGraphics
import CornermarkCore
import Foundation

/// One recording, from the first frame to the finished file. The pointer, clicks and keys, when watched, are kept as tracks beside the video.
public final class Recorder {
    public let output: URL
    /// Only recent events can still show: a ring lasts under a second, and a badge shows at most its last characters.
    private static let recentClicks = 32
    private static let recentKeys = 2 * KeystrokeDisplay.maxCharacters
    private let source: FrameSource
    private let pointer: PointerSource?
    private let input: InputSource?
    private let marks: InputMarks?
    private let quality: VideoQuality
    private var writer: RecordingWriter?
    private var compositor: InputCompositor?
    private var track = PointerTrackBuilder()
    private var clicks: [ClickEvent] = []
    private var keys: [KeyEvent] = []
    private let trackLock = NSLock()
    public var marksInPicture: Bool { marks != nil }
    /// Why clicks and keys are not watched, when an input source was given and could not start.
    public private(set) var inputFailure: InputUnavailable?
    /// Pictures that carry click or key marks, and how many of them filled a gap in the stream.
    public var markedFrames: (marked: Int, filled: Int) { trackLock.withLock { (compositor?.marked ?? 0, compositor?.filled ?? 0) } }
    public private(set) var format: FrameFormat?
    /// What the pictures show, in global AppKit points. Valid once `start` returns.
    public var pointArea: CGRect { source.pointArea }
    /// The length of the video so far. A pause does not grow it.
    public var seconds: Double { writer?.seconds ?? 0 }

    public init(source: FrameSource, output: URL, pointer: PointerSource? = nil, input: InputSource? = nil, marks: InputMarks? = nil,
                quality: VideoQuality = .high) {
        self.source = source
        self.output = output
        self.pointer = pointer
        self.input = input
        self.marks = marks.flatMap { $0.isVisible ? $0 : nil }
        self.quality = quality
    }

    public var onFailure: ((Error) -> Void)? {
        get { source.onFailure }
        set { source.onFailure = newValue }
    }

    public func start() async throws {
        let format = try await source.prepare()
        let writer = try RecordingWriter(url: output, format: format, realTime: source.deliversInRealTime, quality: quality)
        self.format = format
        self.writer = writer
        pointer?.start(in: source.pointArea) { [weak self] reading in
            guard let self else { return }
            self.trackLock.withLock { self.track.add(time: reading.time, x: reading.x, y: reading.y) }
        }
        do {
            try input?.start(in: source.pointArea) { [weak self] reading in
                guard let self else { return }
                self.trackLock.withLock {
                    switch reading {
                    case .click(let c): self.clicks.append(c)
                    case .key(let k): self.keys.append(k)
                    }
                }
            }
        } catch {
            inputFailure = error as? InputUnavailable ?? .tapFailed
        }
        if let marks { compositor = InputCompositor(marks: marks, format: format, area: source.pointArea.size) }
        do {
            try await source.start { [weak self, writer] frame in
                guard let self, self.compositor != nil else { return writer.append(frame) }
                let pictures = self.trackLock.withLock {
                    self.compositor?.pictures(for: frame, clicks: Array(self.clicks.suffix(Self.recentClicks)), keys: Array(self.keys.suffix(Self.recentKeys))) ?? [frame]
                }
                pictures.forEach(writer.append)
            }
        } catch {
            input?.stop()
            pointer?.stop()
            writer.cancel()
            self.writer = nil
            throw error
        }
    }

    public func pause() {
        writer?.pause()
        trackLock.withLock { compositor?.forget() }
    }
    public func resume() { writer?.resume() }

    public func stop() async throws -> RecordingReport {
        await source.stop()
        pointer?.stop()
        input?.stop()
        guard let writer else { throw RecordingError.noFrames }
        self.writer = nil
        var report = try await writer.finish()
        report.area = source.pointArea
        let paused = report.pauses.reduce(0) { $0 + $1.to - $1.from }
        let samples = trackLock.withLock {
            track.samples(firstFrameTime: report.firstFrameTime, lastTime: report.firstFrameTime + report.duration + paused)
        }
        report.pointer = samples.compactMap { s in
            RecordingPause.videoTime(s.t, skipping: report.pauses).map { PointerSample(t: $0, x: s.x, y: s.y) }
        }
        let (rawClicks, rawKeys) = trackLock.withLock { (clicks, keys) }
        let end = report.duration + paused
        func videoTime(_ t: Double) -> Double? {
            let since = t - report.firstFrameTime
            guard since >= 0, since <= end else { return nil }
            return RecordingPause.videoTime(since, skipping: report.pauses)
        }
        report.clicks = rawClicks.compactMap { c in videoTime(c.t).map { ClickEvent(t: $0, x: c.x, y: c.y) } }
        report.keys = rawKeys.compactMap { k in videoTime(k.t).map { KeyEvent(t: $0, label: k.label, isCommand: k.isCommand) } }
        return report
    }

    /// Ends the recording and deletes its file.
    public func cancel() async {
        await source.stop()
        pointer?.stop()
        input?.stop()
        writer?.cancel()
        writer = nil
    }
}
