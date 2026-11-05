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

    public func stop() async throws -> RecordingReport {
        await source.stop()
        pointer?.stop()
        guard let writer else { throw RecordingError.noFrames }
        self.writer = nil
        var report = try await writer.finish()
        report.area = source.pointArea
        report.pointer = trackLock.withLock {
            track.samples(firstFrameTime: report.firstFrameTime, lastTime: report.firstFrameTime + report.duration)
        }
        return report
    }
}
