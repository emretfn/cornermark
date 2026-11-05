import Foundation

/// One recording, from the first frame to the finished file.
public final class Recorder {
    public let output: URL
    private let source: FrameSource
    private var writer: RecordingWriter?
    public private(set) var format: FrameFormat?

    public init(source: FrameSource, output: URL) {
        self.source = source
        self.output = output
    }

    public var onFailure: ((Error) -> Void)? {
        get { source.onFailure }
        set { source.onFailure = newValue }
    }

    public func start() async throws {
        let format = try await source.prepare()
        let writer = try RecordingWriter(url: output, format: format, realTime: source.deliversInRealTime)
        self.format = format
        self.writer = writer
        do {
            try await source.start { [writer] frame in writer.append(frame) }
        } catch {
            writer.cancel()
            self.writer = nil
            throw error
        }
    }

    public func stop() async throws -> RecordingReport {
        await source.stop()
        guard let writer else { throw RecordingError.noFrames }
        self.writer = nil
        return try await writer.finish()
    }
}
