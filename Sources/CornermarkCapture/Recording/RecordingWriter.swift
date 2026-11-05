import AVFoundation
import Foundation

/// Writes frames to an H.264 MP4. Safe to call from any one delivery queue while another thread finishes.
final class RecordingWriter {
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let lock = NSLock()
    private let url: URL
    let format: FrameFormat
    /// Average bits a second the encoder aims for.
    let bitRate: Int
    private let realTime: Bool
    private var origin: CMTime?
    private var lastTime: CMTime = .zero
    private var written = 0
    private var finished = false
    private var paused = false
    private var resuming = false
    /// Source time that pauses removed so far. Every later frame moves back by it, so the video has no gap.
    private var removed = CMTime.zero
    private var pauses: [RecordingPause] = []

    init(url: URL, format: FrameFormat, realTime: Bool, quality: VideoQuality = .high) throws {
        self.url = url
        self.realTime = realTime
        self.format = format
        try? FileManager.default.removeItem(at: url)
        do { writer = try AVAssetWriter(outputURL: url, fileType: .mp4) } catch { throw RecordingError.writer(error.localizedDescription) }
        // A fragment closes every second, so a recording cut off by a crash is readable up to its last second and can be recovered.
        // Finishing normally writes a plain file. Measured: a writer killed at frame 100 of 30 fps left 90 readable frames.
        writer.movieFragmentInterval = CMTime(seconds: 1, preferredTimescale: 600)
        // The floor keeps a small area legible, and shrinks with the quality so each step still costs less.
        let floor = 10_000_000 * quality.bitsPerPixel
        let bitRate = Int(max(floor, Double(format.width * format.height * format.fps) * quality.bitsPerPixel))
        self.bitRate = bitRate
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: format.width,
            AVVideoHeightKey: format.height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitRate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoMaxKeyFrameIntervalKey: format.fps * 2,
                AVVideoExpectedSourceFrameRateKey: format.fps,
                AVVideoAllowFrameReorderingKey: false,
            ],
        ])
        input.expectsMediaDataInRealTime = realTime
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        guard writer.canAdd(input) else { throw RecordingError.writer("The encoder rejected these settings") }
        writer.add(input)
        guard writer.startWriting() else { throw RecordingError.writer(writer.error?.localizedDescription ?? "Could not start writing") }
    }

    /// A live source that outruns the encoder loses frames, because a recording that falls behind must stay in step with the screen.
    /// An offline source waits for the encoder instead.
    func append(_ frame: VideoFrame) {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return }
        guard !paused else { return }
        if origin == nil {
            origin = frame.time
            writer.startSession(atSourceTime: .zero)
        }
        let raw = CMTimeSubtract(frame.time, origin!)
        if resuming, written > 0 {
            // The first frame after a pause follows the last one before it by one frame.
            let next = CMTimeAdd(lastTime, CMTime(value: 1, timescale: CMTimeScale(format.fps)))
            let gap = CMTimeSubtract(CMTimeSubtract(raw, removed), next)
            if gap > .zero {
                pauses.append(RecordingPause(from: CMTimeAdd(next, removed).seconds, to: raw.seconds))
                removed = CMTimeAdd(removed, gap)
            }
        }
        resuming = false
        let pts = CMTimeSubtract(raw, removed)
        guard written == 0 || pts > lastTime else { return }
        var waited = 0
        while !realTime, !input.isReadyForMoreMediaData, waited < 10_000 {
            usleep(1000)
            waited += 1
        }
        guard input.isReadyForMoreMediaData else { return }
        if adaptor.append(frame.pixels, withPresentationTime: pts) {
            lastTime = pts
            written += 1
        }
    }

    /// Frames stop reaching the file until `resume`. The time in between is left out of the video.
    func pause() { lock.withLock { paused = true } }

    func resume() {
        lock.withLock {
            paused = false
            resuming = true
        }
    }

    /// The length of the video written so far, which a pause does not grow.
    var seconds: Double {
        lock.withLock { written == 0 ? 0 : lastTime.seconds + 1 / Double(format.fps) }
    }

    func finish() async throws -> RecordingReport {
        let (count, last, first, pauses) = lock.withLock {
            finished = true
            return (written, lastTime.seconds, origin?.seconds ?? 0, self.pauses)
        }
        guard count > 0 else {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            throw RecordingError.noFrames
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw RecordingError.writer(writer.error?.localizedDescription ?? "The file was not finished") }
        let slots = Int((last * Double(format.fps)).rounded()) + 1
        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        var report = RecordingReport(url: url, format: format, framesWritten: count, framesDropped: max(0, slots - count), duration: last, fileBytes: bytes, bitRate: bitRate, firstFrameTime: first)
        report.pauses = pauses
        return report
    }

    func cancel() {
        lock.lock(); finished = true; lock.unlock()
        writer.cancelWriting()
        try? FileManager.default.removeItem(at: url)
    }
}
