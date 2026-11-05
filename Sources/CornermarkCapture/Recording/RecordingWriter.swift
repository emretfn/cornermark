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
    private let realTime: Bool
    private var origin: CMTime?
    private var lastTime: CMTime = .zero
    private var written = 0
    private var finished = false

    init(url: URL, format: FrameFormat, realTime: Bool) throws {
        self.url = url
        self.realTime = realTime
        self.format = format
        try? FileManager.default.removeItem(at: url)
        do { writer = try AVAssetWriter(outputURL: url, fileType: .mp4) } catch { throw RecordingError.writer(error.localizedDescription) }
        let bitsPerPixel = 0.2
        let bitRate = max(2_000_000, Int(Double(format.width * format.height * format.fps) * bitsPerPixel))
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
        if origin == nil {
            origin = frame.time
            writer.startSession(atSourceTime: .zero)
        }
        let pts = CMTimeSubtract(frame.time, origin!)
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

    func finish() async throws -> RecordingReport {
        lock.lock()
        finished = true
        let count = written, last = lastTime.seconds, first = origin?.seconds ?? 0
        lock.unlock()
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
        return RecordingReport(url: url, format: format, framesWritten: count, framesDropped: max(0, slots - count), duration: last, fileBytes: bytes, firstFrameTime: first)
    }

    func cancel() {
        lock.lock(); finished = true; lock.unlock()
        writer.cancelWriting()
        try? FileManager.default.removeItem(at: url)
    }
}
