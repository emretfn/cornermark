import CoreGraphics
import CornermarkCore
import Foundation

/// One recording, from the first frame to the finished file. The pointer, when watched, is kept as its own track beside the video.
public final class Recorder {
    public let output: URL
    private let source: FrameSource
    private let pointer: PointerSource?
    private let quality: VideoQuality
    private var writer: RecordingWriter?
    private var track = PointerTrackBuilder()
    private let trackLock = NSLock()
    public private(set) var format: FrameFormat?
    /// What the pictures show, in global AppKit points. Valid once `start` returns.
    public var pointArea: CGRect { source.pointArea }
    /// The length of the video so far. A pause does not grow it.
    public var seconds: Double { writer?.seconds ?? 0 }

    public init(source: FrameSource, output: URL, pointer: PointerSource? = nil, quality: VideoQuality = .high) {
        self.source = source
        self.output = output
        self.pointer = pointer
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
            try await source.start { [writer] frame in writer.append(frame) }
        } catch {
            pointer?.stop()
            writer.cancel()
            self.writer = nil
            throw error
        }
    }

    public func pause() { writer?.pause() }
    public func resume() { writer?.resume() }

    public func stop() async throws -> RecordingReport {
        await source.stop()
        pointer?.stop()
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
        return report
    }

    /// Ends the recording and deletes its file.
    public func cancel() async {
        await source.stop()
        pointer?.stop()
        writer?.cancel()
        writer = nil
    }
}
