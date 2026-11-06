import AVFoundation
import CoreGraphics
import CornermarkCore
import CornermarkDesign
import VideoToolbox

public struct ExportReport: Equatable, Sendable {
    public var url: URL
    public var plan: ExportPlan
    public var framesWritten: Int
    /// Read back from the finished file.
    public var duration: Double
    public var bytes: Int64
    /// Answered by the encoder session that wrote the file.
    public var usesHardware: Bool
    public var encoderID: String
    /// Wall time of the whole export.
    public var renderSeconds: Double
    /// The recording's microphone and system sound, mixed into the file's one sound track.
    public var hasAudio = false
}

extension ExportPlan {
    public init(project: RecordingProject, settings: ExportSettings, video: URL) {
        let bytes = ((try? FileManager.default.attributesOfItem(atPath: video.path))?[.size] as? NSNumber)?.int64Value
        self.init(project: project, settings: settings, sourceBytes: bytes)
    }
}

public enum ExportError: Error, Equatable {
    case noVideo
    case encoder(OSStatus)
    case writer(String)
}

public struct ExportFrameRenderer: @unchecked Sendable {
    public let width: Int
    public let height: Int
    /// The recorded area in points, the unit of pointer positions.
    public let pointSize: CGSize
    public let canvas: VideoCanvas
    let highlight: ClickHighlight
    let keystrokes: KeystrokeDisplay
    /// The fill and shadow, made once: the recording is opaque, so nothing behind it changes from frame to frame.
    let backdrop: CGImage?

    /// `folder` is the project folder, where a background picture the viewer added lives.
    public init(plan: ExportPlan, project: RecordingProject, folder: URL?) {
        width = plan.width; height = plan.height
        pointSize = CGSize(width: max(project.source.pointWidth, 1), height: max(project.source.pointHeight, 1))
        canvas = project.canvas
        highlight = project.edits.clicks
        keystrokes = project.edits.keystrokes
        backdrop = VideoBackdrop.image(canvas, width: plan.width, height: plan.height, picture: folder.flatMap { project.edits.background.picture(in: $0) })
    }

    public static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    /// The recording's rectangle in the bitmap, y up.
    var frameRect: CGRect {
        let sx = CGFloat(width) / canvas.size.width, sy = CGFloat(height) / canvas.size.height
        let f = canvas.frame
        return CGRect(x: f.minX * sx, y: CGFloat(height) - f.maxY * sy, width: f.width * sx, height: f.height * sy)
    }

    /// `ctx` is a bitmap of `width` × `height` pixels with the usual y-up origin. `camera` is the camera file's picture at the same moment.
    public func draw(_ state: FrameState, source: CGImage?, camera: CGImage? = nil, in ctx: CGContext) {
        let full = CGRect(x: 0, y: 0, width: width, height: height)
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fill(full)
        ctx.interpolationQuality = .high
        if let backdrop { ctx.draw(backdrop, in: full) }
        let frame = frameRect
        let radius = canvas.cornerRadius * min(frame.width / pointSize.width, frame.height / pointSize.height)
        ctx.saveGState()
        if canvas.hasBackdrop {
            ctx.addPath(CGPath(roundedRect: frame, cornerWidth: radius, cornerHeight: radius, transform: nil))
            ctx.clip()
        }
        // The crop zooms the recording inside the frame, and the frame's clip cuts what falls outside it.
        if let source { ctx.draw(source, in: Self.pictureRect(state.crop, in: frame)) }
        // The camera bubble is an overlay on the frame, so it ignores the crop. Rings and the pointer are in recording points and follow it.
        if let placed = state.camera, let camera {
            ctx.saveGState()
            ctx.translateBy(x: frame.minX, y: frame.maxY)
            ctx.scaleBy(x: frame.width / pointSize.width, y: -frame.height / pointSize.height)
            CameraBubblePainter.draw(camera, placed, in: ctx)
            ctx.restoreGState()
        }
        if state.cursor != nil || !state.input.isEmpty {
            let crop = state.crop
            ctx.translateBy(x: frame.minX, y: frame.maxY)
            ctx.scaleBy(x: frame.width / (pointSize.width * crop.width), y: -frame.height / (pointSize.height * crop.height))
            ctx.translateBy(x: -pointSize.width * crop.x, y: -pointSize.height * crop.y)
            if !state.input.isEmpty {
                InputOverlayPainter.draw(state.input, area: pointSize, highlight: highlight, keystrokes: keystrokes, ink: .design, in: ctx)
            }
            if let cursor = state.cursor { PointerShape.draw(cursor, in: ctx) }
        }
        ctx.restoreGState()
    }

    /// Where the whole recording lands so that `crop` fills `frame`, in y-up coordinates.
    public static func pictureRect(_ crop: ZoomRect, in frame: CGRect) -> CGRect {
        let w = frame.width / crop.width, h = frame.height / crop.height
        return CGRect(x: frame.minX - crop.x * w, y: frame.minY - (1 - crop.y - crop.height) * h, width: w, height: h)
    }

    public func image(_ state: FrameState, source: CGImage?, camera: CGImage? = nil) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: Self.colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        draw(state, source: source, camera: camera, in: ctx)
        return ctx.makeImage()
    }
}

/// The file appears at `output` only when it is complete; cancelling or failing leaves nothing there.
public enum VideoExporter {
    public static func export(project: RecordingProject, video: URL, settings: ExportSettings, to output: URL,
                              progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> ExportReport {
        let started = Date()
        let plan = ExportPlan(project: project, settings: settings, video: video)
        // The writer keeps scratch files beside its output, so everything goes into a folder of its own that leaves as a whole.
        let scratch = output.deletingLastPathComponent().appendingPathComponent(".export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let partial = scratch.appendingPathComponent(output.lastPathComponent)
        let encoder = try Encoder(plan: plan)
        defer { encoder.invalidate() }
        let writer = try AVAssetWriter(outputURL: partial, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true
        let folder = video.deletingLastPathComponent()
        // A video opened from a file carries its sound in its own file; a recording's video has none, so it adds nothing to the mix.
        let mix = try await AudioMixReader(files: [video] + project.source.audioFiles.map { folder.appendingPathComponent($0) }, clips: project.timeline.clips,
                                           duration: plan.duration)
        defer { mix?.cancel() }
        do {
            let frames = try await render(project: project, video: video, plan: plan, encoder: encoder, sink: Sink(writer: writer, audio: mix), progress: progress)
            let duration = try await AVURLAsset(url: partial).load(.duration).seconds
            let bytes = ((try? FileManager.default.attributesOfItem(atPath: partial.path))?[.size] as? NSNumber)?.int64Value ?? 0
            try FileManager.default.moveItem(at: partial, to: output)
            return ExportReport(url: output, plan: plan, framesWritten: frames, duration: duration, bytes: bytes, usesHardware: encoder.usesHardware,
                                encoderID: encoder.encoderID, renderSeconds: Date().timeIntervalSince(started), hasAudio: mix != nil)
        } catch {
            if writer.status == .writing { writer.cancelWriting() }
            throw error
        }
    }

    /// The encoder this machine gives an export of `plan`'s size, without writing anything.
    public static func probeEncoder(plan: ExportPlan) throws -> (usesHardware: Bool, encoderID: String) {
        let encoder = try Encoder(plan: plan)
        defer { encoder.invalidate() }
        return (encoder.usesHardware, encoder.encoderID)
    }

    private static func render(project: RecordingProject, video: URL, plan: ExportPlan, encoder: Encoder, sink: Sink,
                               progress: @Sendable (Double) -> Void) async throws -> Int {
        let asset = AVURLAsset(url: video)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw ExportError.noVideo }
        let timeline = project.timeline
        // The camera file shares the video's timeline, so each clip reads the same stretch of it. A project whose camera file is gone
        // still exports, without the camera.
        let cameraAsset = project.source.camera.map { AVURLAsset(url: video.deletingLastPathComponent().appendingPathComponent($0)) }
        let cameraTrack = try? await cameraAsset?.loadTracks(withMediaType: .video).first
        var cameraReader: ClipReader?
        let renderer = ExportFrameRenderer(plan: plan, project: project, folder: video.deletingLastPathComponent())
        var reader: ClipReader?
        var reported = -1
        let frameDuration = CMTime(value: 1, timescale: CMTimeScale(plan.fps))
        for k in 0..<plan.frameCount {
            try Task.checkCancellation()
            let t = plan.time(ofFrame: k)
            let state = frameState(project, outputTime: t)
            let clip = timeline.clipIndex(at: t)
            if reader?.clip != clip { reader = try ClipReader(asset: asset, track: track, clip: clip, range: timeline.clips[clip]) }
            let current = reader?.image(at: state.sourceTime)
            var camera: CGImage?
            if state.camera != nil, let cameraAsset, let cameraTrack {
                if cameraReader?.clip != clip { cameraReader = try? ClipReader(asset: cameraAsset, track: cameraTrack, clip: clip, range: timeline.clips[clip]) }
                camera = cameraReader?.image(at: state.sourceTime)
            }
            let buffer = try encoder.makeBuffer()
            try draw(into: buffer) { renderer.draw(state, source: current, camera: camera, in: $0) }
            try encoder.encode(buffer, at: CMTime(value: CMTimeValue(k), timescale: CMTimeScale(plan.fps)), duration: frameDuration)
            try await sink.append(encoder.take())
            let percent = (k + 1) * 100 / plan.frameCount
            if percent != reported { reported = percent; progress(Double(k + 1) / Double(plan.frameCount)) }
        }
        try encoder.finish()
        try await sink.append(encoder.take())
        try await sink.finish()
        return plan.frameCount
    }

    private static func draw(into buffer: CVPixelBuffer, _ body: (CGContext) -> Void) throws {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer),
                                  bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: ExportFrameRenderer.colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { throw ExportError.writer("a frame could not be drawn") }
        body(ctx)
    }
}

/// Reads one clip's source frames in order and answers with the last frame at or before a moment, the frame a player shows then.
private final class ClipReader {
    let clip: Int
    private let reader: AVAssetReader
    private let output: AVAssetReaderTrackOutput
    private var pending: (time: Double, image: CGImage)?
    private var current: CGImage?

    init(asset: AVAsset, track: AVAssetTrack, clip: Int, range: Clip) throws {
        self.clip = clip
        reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: range.start, preferredTimescale: 600),
                                       end: CMTime(seconds: range.end, preferredTimescale: 600))
        output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { throw ExportError.writer(reader.error?.localizedDescription ?? "the source could not be read") }
        pending = next()
    }

    deinit { reader.cancelReading() }

    func image(at sourceTime: Double) -> CGImage? {
        while let p = pending, p.time <= sourceTime + 1e-6 { current = p.image; pending = next() }
        return current ?? pending?.image
    }

    private func next() -> (time: Double, image: CGImage)? {
        while let sample = output.copyNextSampleBuffer() {
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            var image: CGImage?
            VTCreateCGImageFromCVPixelBuffer(buffer, options: nil, imageOut: &image)
            if let image { return (CMSampleBufferGetPresentationTimeStamp(sample).seconds, image) }
        }
        return nil
    }
}

/// One H.264 compression session. Frames go in as BGRA, compressed samples come out on VideoToolbox's thread and wait in `ready`.
private final class Encoder: @unchecked Sendable {
    let session: VTCompressionSession
    let usesHardware: Bool
    let encoderID: String
    private let lock = NSLock()
    private var ready: [CMSampleBuffer] = []
    private var failure: OSStatus = noErr

    init(plan: ExportPlan) throws {
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: plan.width,
            kCVPixelBufferHeightKey: plan.height,
            kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any](),
        ]
        func create(_ spec: [CFString: Any]) -> VTCompressionSession? {
            var session: VTCompressionSession?
            let status = VTCompressionSessionCreate(allocator: nil, width: Int32(plan.width), height: Int32(plan.height), codecType: kCMVideoCodecType_H264,
                                                    encoderSpecification: spec as CFDictionary, imageBufferAttributes: attributes as CFDictionary,
                                                    compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &session)
            return status == noErr ? session : nil
        }
        // Requiring the hardware encoder fails outright where there is none, such as a size beyond its limits; the software one then
        // writes the same file more slowly, and the report says which ran.
        guard let session = create([kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true])
            ?? create([kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: false]) else {
            throw ExportError.encoder(kVTVideoEncoderNotAvailableNowErr)
        }
        self.session = session
        let properties: [CFString: Any] = [
            kVTCompressionPropertyKey_RealTime: false,
            kVTCompressionPropertyKey_ProfileLevel: kVTProfileLevel_H264_High_AutoLevel,
            kVTCompressionPropertyKey_AverageBitRate: plan.bitRate,
            kVTCompressionPropertyKey_ExpectedFrameRate: plan.fps,
            kVTCompressionPropertyKey_MaxKeyFrameInterval: plan.fps * 2,
            kVTCompressionPropertyKey_AllowFrameReordering: false,
            kVTCompressionPropertyKey_ColorPrimaries: kCVImageBufferColorPrimaries_ITU_R_709_2,
            kVTCompressionPropertyKey_TransferFunction: kCVImageBufferTransferFunction_ITU_R_709_2,
            kVTCompressionPropertyKey_YCbCrMatrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2,
        ]
        let status = VTSessionSetProperties(session, propertyDictionary: properties as CFDictionary)
        guard status == noErr else { VTCompressionSessionInvalidate(session); throw ExportError.encoder(status) }
        VTCompressionSessionPrepareToEncodeFrames(session)
        usesHardware = (Self.property(session, kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder) as? Bool) ?? false
        encoderID = (Self.property(session, kVTCompressionPropertyKey_EncoderID) as? String) ?? "unknown"
    }

    private static func property(_ session: VTCompressionSession, _ key: CFString) -> CFTypeRef? {
        var value: Unmanaged<CFTypeRef>?
        guard VTSessionCopyProperty(session, key: key, allocator: nil, valueOut: &value) == noErr else { return nil }
        return value?.takeRetainedValue()
    }

    func makeBuffer() throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        guard let pool = VTCompressionSessionGetPixelBufferPool(session), CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess,
              let buffer else { throw ExportError.writer("no frame buffer") }
        CVBufferSetAttachment(buffer, kCVImageBufferCGColorSpaceKey, ExportFrameRenderer.colorSpace, .shouldPropagate)
        return buffer
    }

    func encode(_ buffer: CVPixelBuffer, at time: CMTime, duration: CMTime) throws {
        let status = VTCompressionSessionEncodeFrame(session, imageBuffer: buffer, presentationTimeStamp: time, duration: duration,
                                                     frameProperties: nil, infoFlagsOut: nil) { [weak self] status, _, sample in
            self?.receive(status, sample)
        }
        guard status == noErr else { throw ExportError.encoder(status) }
    }

    func finish() throws {
        let status = VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        guard status == noErr else { throw ExportError.encoder(status) }
    }

    /// The compressed samples so far, in decode order.
    func take() throws -> [CMSampleBuffer] {
        lock.lock()
        defer { lock.unlock() }
        guard failure == noErr else { throw ExportError.encoder(failure) }
        let out = ready
        ready.removeAll()
        return out
    }

    func invalidate() { VTCompressionSessionInvalidate(session) }

    private func receive(_ status: OSStatus, _ sample: CMSampleBuffer?) {
        lock.lock()
        defer { lock.unlock() }
        if status != noErr { failure = status } else if let sample { ready.append(sample) }
    }
}

/// Writes compressed samples as they are. The input is made from the first sample, since an MP4 track needs its format up front.
/// The sound, when there is some, is pulled by the writer on its own queue as it interleaves it with the pictures.
private final class Sink {
    let writer: AVAssetWriter
    private let audio: AudioMixReader?
    private var input: AVAssetWriterInput?
    private let audioDone = DispatchGroup()

    init(writer: AVAssetWriter, audio: AudioMixReader?) { self.writer = writer; self.audio = audio }

    func append(_ samples: [CMSampleBuffer]) async throws {
        for sample in samples {
            let input = try self.input ?? start(with: sample)
            while !input.isReadyForMoreMediaData {
                if writer.status == .failed { throw ExportError.writer(writer.error?.localizedDescription ?? "the file could not be written") }
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            guard input.append(sample) else { throw ExportError.writer(writer.error?.localizedDescription ?? "a frame could not be written") }
        }
    }

    private func start(with sample: CMSampleBuffer) throws -> AVAssetWriterInput {
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: CMSampleBufferGetFormatDescription(sample))
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else { throw ExportError.writer("the video track could not be added") }
        writer.add(input)
        let sound = audio.map { _ in AudioMixReader.makeInput() }
        if let sound {
            guard writer.canAdd(sound) else { throw ExportError.writer("the sound track could not be added") }
            writer.add(sound)
        }
        guard writer.startWriting() else { throw ExportError.writer(writer.error?.localizedDescription ?? "the file could not be started") }
        writer.startSession(atSourceTime: .zero)
        if let audio, let sound {
            audioDone.enter()
            audio.feed(sound) { [audioDone] in audioDone.leave() }
        }
        self.input = input
        return input
    }

    func finish() async throws {
        guard let input else { throw ExportError.writer("no frame was encoded") }
        input.markAsFinished()
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in audioDone.notify(queue: .global()) { done.resume() } }
        if audio?.failed == true { throw ExportError.writer("the sound could not be read") }
        await writer.finishWriting()
        guard writer.status == .completed else { throw ExportError.writer(writer.error?.localizedDescription ?? "the file could not be finished") }
    }
}
