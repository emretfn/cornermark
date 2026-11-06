import AVFoundation
import CoreGraphics
import CornermarkCore
import Metal
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
    /// Frames drawn as an average of several moments, and the drawings made for the whole file.
    public var blurredFrames = 0
    public var drawings = 0
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

/// Draws one frame of the finished video: the background, then the source picture, the camera, the click rings and keystroke badge,
/// and the pointer `frameState` places, clipped to the recording's rounded frame, in the recording's points with y down, the way the
/// preview's layers do.
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
        self.init(width: plan.width, height: plan.height, project: project, folder: folder)
    }

    public init(width: Int, height: Int, project: RecordingProject, folder: URL?) {
        self.width = width; self.height = height
        pointSize = CGSize(width: max(project.source.pointWidth, 1), height: max(project.source.pointHeight, 1))
        canvas = project.canvas
        highlight = project.edits.clicks
        keystrokes = project.edits.keystrokes
        backdrop = VideoBackdrop.image(canvas, width: width, height: height, picture: folder.flatMap { project.edits.background.picture(in: $0) })
    }

    public static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    /// The bitmap export draws a frame into. The preview draws the keystroke badge into one too, so its glyphs land on the same pixels.
    static func bitmap(width: Int, height: Int) -> CGContext? {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    }

    /// The recording's rectangle in the bitmap, y up.
    public var frameRect: CGRect {
        let sx = CGFloat(width) / canvas.size.width, sy = CGFloat(height) / canvas.size.height
        let f = canvas.frame
        return CGRect(x: f.minX * sx, y: CGFloat(height) - f.maxY * sy, width: f.width * sx, height: f.height * sy)
    }

    private func clipToFrame(_ ctx: CGContext) {
        guard canvas.hasBackdrop else { return }
        let frame = frameRect
        let radius = canvas.cornerRadius * min(frame.width / pointSize.width, frame.height / pointSize.height)
        ctx.addPath(CGPath(roundedRect: frame, cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.clip()
    }

    /// Puts `ctx` in the recording's points inside the frame, with `crop` showing: y down, the unit of pointer positions.
    private func enterRecordingPoints(_ ctx: CGContext, crop: ZoomRect) {
        let frame = frameRect
        ctx.translateBy(x: frame.minX, y: frame.maxY)
        ctx.scaleBy(x: frame.width / (pointSize.width * crop.width), y: -frame.height / (pointSize.height * crop.height))
        ctx.translateBy(x: -pointSize.width * crop.x, y: -pointSize.height * crop.y)
    }

    /// `ctx` is a bitmap of `width` × `height` pixels with the usual y-up origin. `camera` is the camera file's picture at the same moment.
    public func draw(_ state: FrameState, source: CGImage?, camera: CGImage? = nil, in ctx: CGContext) {
        draw(state, source: source, camera: camera, only: nil, in: ctx)
    }

    /// With `only`, nothing outside that rectangle is drawn, which costs only what the rectangle holds.
    func draw(_ state: FrameState, source: CGImage?, camera: CGImage?, only: CGRect?, in ctx: CGContext) {
        if let only { ctx.saveGState(); ctx.clip(to: only) }
        defer { if only != nil { ctx.restoreGState() } }
        let full = CGRect(x: 0, y: 0, width: width, height: height)
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fill(full)
        ctx.interpolationQuality = .high
        if let backdrop { ctx.draw(backdrop, in: full) }
        let frame = frameRect
        ctx.saveGState()
        clipToFrame(ctx)
        // The crop zooms the recording inside the frame, and the frame's clip cuts what falls outside it.
        if let source { ctx.draw(source, in: Self.pictureRect(state.crop, in: frame)) }
        drawCamera(state, camera, in: ctx)
        if state.cursor != nil || !state.input.isEmpty {
            enterRecordingPoints(ctx, crop: state.crop)
            if !state.input.isEmpty {
                InputOverlayPainter.draw(state.input, area: pointSize, highlight: highlight, keystrokes: keystrokes, ink: .design, in: ctx)
            }
            if let cursor = state.cursor { PointerShape.draw(cursor, in: ctx) }
        }
        ctx.restoreGState()
    }

    /// The camera bubble is an overlay on the frame, so it ignores the crop. Rings and the pointer are in recording points and follow it.
    private func drawCamera(_ state: FrameState, _ camera: CGImage?, in ctx: CGContext) {
        guard let placed = state.camera, let camera else { return }
        let frame = frameRect
        ctx.saveGState()
        ctx.translateBy(x: frame.minX, y: frame.maxY)
        ctx.scaleBy(x: frame.width / pointSize.width, y: -frame.height / pointSize.height)
        CameraBubblePainter.draw(camera, placed, in: ctx)
        ctx.restoreGState()
    }

    /// The whole pixels of the bitmap the recording's frame covers, which is where a picture averaged for it goes.
    var pictureRegion: CGRect { frameRect.integral.intersection(CGRect(x: 0, y: 0, width: width, height: height)) }

    /// The frame as `draw` makes it, with the recording replaced by `picture`: the average of its drawings, already placed, `region` pixels
    /// of the bitmap that draw one to one. Whatever does not depend on the crop goes on as usual, and the rings, the badge and the pointer do
    /// not: they are not drawn here, so the caller does not use this where there are any.
    func drawAverage(_ picture: CGImage, in region: CGRect, state: FrameState, camera: CGImage?, in ctx: CGContext) {
        let full = CGRect(x: 0, y: 0, width: width, height: height)
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fill(full)
        ctx.interpolationQuality = .high
        if let backdrop { ctx.draw(backdrop, in: full) }
        ctx.saveGState()
        clipToFrame(ctx)
        ctx.interpolationQuality = .none
        ctx.draw(picture, in: region)
        drawCamera(state, camera, in: ctx)
        ctx.restoreGState()
    }

    /// Draws only the pointer over a frame `draw` made without it, the way `draw` puts it on top of everything else.
    func drawCursor(_ cursor: CursorFrame, crop: ZoomRect, in ctx: CGContext) {
        ctx.saveGState()
        clipToFrame(ctx)
        enterRecordingPoints(ctx, crop: crop)
        PointerShape.draw(cursor, in: ctx)
        ctx.restoreGState()
    }

    /// Whole pixels, y up, that the pointer at `cursor` can touch with `crop` showing: a box that holds its largest look plus a margin.
    func cursorBounds(_ cursor: CursorFrame, crop: ZoomRect) -> CGRect {
        let frame = frameRect
        let sx = frame.width / (pointSize.width * crop.width), sy = frame.height / (pointSize.height * crop.height)
        let cx = frame.minX + (cursor.x - pointSize.width * crop.x) * sx
        let cy = frame.maxY - (cursor.y - pointSize.height * crop.y) * sy
        let reach = 21 * cursor.scale + 3
        let box = CGRect(x: cx - reach * sx - 2, y: cy - reach * sy - 2, width: 2 * reach * sx + 4, height: 2 * reach * sy + 4).integral
        return box.intersection(canvas.hasBackdrop ? frame.integral : CGRect(x: 0, y: 0, width: width, height: height))
            .intersection(CGRect(x: 0, y: 0, width: width, height: height))
    }

    /// Where the whole recording lands so that `crop` fills `frame`, in y-up coordinates.
    public static func pictureRect(_ crop: ZoomRect, in frame: CGRect) -> CGRect {
        let w = frame.width / crop.width, h = frame.height / crop.height
        return CGRect(x: frame.minX - crop.x * w, y: frame.minY - (1 - crop.y - crop.height) * h, width: w, height: h)
    }

    public func image(_ state: FrameState, source: CGImage?, camera: CGImage? = nil) -> CGImage? {
        guard let ctx = Self.bitmap(width: width, height: height) else { return nil }
        draw(state, source: source, camera: camera, in: ctx)
        return ctx.makeImage()
    }

    /// The average of `samples`, the frame motion blur draws. One sample is the sharp frame.
    public func image(_ samples: [FrameState], source: CGImage?, camera: CGImage? = nil, accumulator: SampleAccumulator = SampleAccumulator()) -> CGImage? {
        guard let ctx = Self.bitmap(width: width, height: height) else { return nil }
        accumulator.draw(samples, with: self, source: source, camera: camera, in: ctx)
        return ctx.makeImage()
    }
}

/// Averages several drawings of a frame into one, byte by byte in premultiplied sRGB. Keeps its buffers between frames of one size.
///
/// When every drawing has the same crop, which is a frame where only the pointer moves, the picture under the pointer is drawn once and
/// only the part of the frame the pointer crosses is drawn and averaged again. The result is the same bytes the full drawings give.
public final class SampleAccumulator {
    private var scratch: CGContext?
    private var sum: [UInt16] = []
    private var converter: CGContext?
    /// The converted picture's bytes and, where there is a GPU, what it needs to average placements of it.
    private var converterPixels: SharedPixels?
    private var pictureTexture: MTLTexture?
    private var averageResult: SharedPixels?
    private var averageSize = (width: 0, height: 0)
    /// Whether the last frame with several drawings was averaged on the GPU.
    private(set) var lastUsedGPU = false

    public init() {}

    /// A recording is tagged with its screen's colors, and drawing it into the sRGB bitmap converts every pixel it covers. Several
    /// drawings of one picture would convert it again each time, which is most of their cost, so it is converted once into a picture
    /// that is already sRGB. The pixels end up the same, since the conversion comes before the scaling either way.
    private func converted(_ image: CGImage) -> CGImage? {
        if converter == nil || converter?.width != image.width || converter?.height != image.height { makeConverter(width: image.width, height: image.height) }
        guard let converter else { return nil }
        converter.interpolationQuality = .none
        converter.setBlendMode(.copy)
        converter.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return converter.makeImage()
    }

    private func makeConverter(width: Int, height: Int) {
        converter = nil; converterPixels = nil; pictureTexture = nil
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        if let gpu = SampleAverager.shared {
            let rowBytes = gpu.rowBytes(width: width)
            if let pixels = SharedPixels(device: gpu.device, bytes: rowBytes * height), let texture = gpu.texture(over: pixels, width: width, height: height, rowBytes: rowBytes),
               let ctx = CGContext(data: pixels.pointer, width: width, height: height, bitsPerComponent: 8, bytesPerRow: rowBytes, space: ExportFrameRenderer.colorSpace, bitmapInfo: bitmapInfo) {
                converter = ctx; converterPixels = pixels; pictureTexture = texture
                return
            }
        }
        converter = ExportFrameRenderer.bitmap(width: width, height: height)
    }

    /// Averages the placements on the GPU, where the picture is not made much smaller (a reduction needs the filtering Core Graphics does)
    /// and no ring or badge needs a drawing of its own at every placement, and draws the pointer over the average where it moves.
    private func drawOnGPU(_ samples: [FrameState], with renderer: ExportFrameRenderer, source: CGImage, camera: CGImage?, in ctx: CGContext, scratch: CGContext) -> Bool {
        guard let gpu = SampleAverager.shared, let texture = pictureTexture, converterPixels != nil, source.width == texture.width, source.height == texture.height,
              samples.allSatisfy({ $0.input.isEmpty }), let out = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return false }
        let frame = renderer.frameRect, region = renderer.pictureRegion
        let w = Int(region.width), h = Int(region.height)
        guard w > 0, h > 0 else { return false }
        var placements: [SampleAverager.Placement] = []
        for sample in samples {
            let picture = ExportFrameRenderer.pictureRect(sample.crop, in: frame)
            // Below nine tenths of its size the picture is reduced, which the sampler would alias.
            guard picture.width >= 0.9 * CGFloat(source.width), picture.height >= 0.9 * CGFloat(source.height) else { return false }
            placements.append(.init(minX: Float(picture.minX), maxY: Float(picture.maxY), width: Float(picture.width), height: Float(picture.height)))
        }
        // Where the pointer moves, a drawing of every placement is still needed; when that is most of the frame, the GPU saves little.
        let reach = samples.compactMap { sample in sample.cursor.map { renderer.cursorBounds($0, crop: sample.crop) } }
        let moving = reach.filter { !$0.isEmpty }.reduce(nil, { (union: CGRect?, box: CGRect) in union.map { $0.union(box) } ?? box })
        if let moving, moving.width * moving.height > 0.25 * region.width * region.height { return false }
        if averageResult == nil || averageSize != (w, h) {
            averageResult = SharedPixels(device: gpu.device, bytes: w * h * 4)
            averageSize = (w, h)
        }
        guard let result = averageResult,
              gpu.average(picture: texture, placements: placements, origin: CGPoint(x: region.minX, y: region.maxY), result: result, width: w, height: h),
              let provider = CGDataProvider(dataInfo: nil, data: result.pointer, size: w * h * 4, releaseData: { _, _, _ in }),
              let average = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: ExportFrameRenderer.colorSpace,
                                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                                    provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return false }
        var bare = samples[0]
        bare.cursor = nil
        renderer.drawAverage(average, in: region, state: bare, camera: camera, in: ctx)
        guard let moving, let drawn = scratch.data?.assumingMemoryBound(to: UInt8.self) else { return true }
        // The box the pointer crosses is drawn and averaged as before, at every placement.
        let x0 = Int(moving.minX), cols = Int(moving.width), row0 = ctx.height - Int(moving.maxY), rows = Int(moving.height)
        let stride = ctx.bytesPerRow, rowBytes = cols * 4
        let at = drawn + row0 * scratch.bytesPerRow + x0 * 4
        sum.withUnsafeMutableBufferPointer { sum in
            sum.baseAddress!.update(repeating: 0, count: rows * rowBytes)
            for sample in samples {
                renderer.draw(sample, source: source, camera: camera, only: moving, in: scratch)
                Self.add(at, stride: scratch.bytesPerRow, rowBytes: rowBytes, rows: rows, to: sum.baseAddress!)
            }
            Self.average(sum.baseAddress!, count: samples.count, rowBytes: rowBytes, rows: rows, into: out + row0 * stride + x0 * 4, stride: stride)
        }
        return true
    }

    /// One sample draws straight into `ctx`, as a frame without blur does.
    public func draw(_ samples: [FrameState], with renderer: ExportFrameRenderer, source: CGImage?, camera: CGImage?, in ctx: CGContext) {
        guard samples.count > 1, let scratch = scratch(like: ctx) else {
            if let sharp = samples.first { renderer.draw(sharp, source: source, camera: camera, in: ctx) }
            return
        }
        let source = source.flatMap(converted)
        lastUsedGPU = false
        if let first = samples.first, samples.allSatisfy({ $0.crop == first.crop }) {
            drawPointerMoving(samples, with: renderer, source: source, camera: camera, in: ctx, scratch: scratch)
        } else if let source, drawOnGPU(samples, with: renderer, source: source, camera: camera, in: ctx, scratch: scratch) {
            lastUsedGPU = true
            return
        } else {
            drawAll(samples, with: renderer, source: source, camera: camera, in: ctx, scratch: scratch)
        }
    }

    private func drawAll(_ samples: [FrameState], with renderer: ExportFrameRenderer, source: CGImage?, camera: CGImage?, in ctx: CGContext, scratch: CGContext) {
        guard let out = ctx.data?.assumingMemoryBound(to: UInt8.self), let drawn = scratch.data?.assumingMemoryBound(to: UInt8.self) else { return }
        let rowBytes = ctx.bytesPerRow
        sum.withUnsafeMutableBufferPointer { sum in
            sum.update(repeating: 0)
            for sample in samples {
                renderer.draw(sample, source: source, camera: camera, in: scratch)
                Self.add(drawn, stride: scratch.bytesPerRow, rowBytes: rowBytes, rows: ctx.height, to: sum.baseAddress!)
            }
            Self.average(sum.baseAddress!, count: samples.count, rowBytes: rowBytes, rows: ctx.height, into: out, stride: ctx.bytesPerRow)
        }
    }

    private func drawPointerMoving(_ samples: [FrameState], with renderer: ExportFrameRenderer, source: CGImage?, camera: CGImage?, in ctx: CGContext, scratch: CGContext) {
        guard let out = ctx.data?.assumingMemoryBound(to: UInt8.self), let drawn = scratch.data?.assumingMemoryBound(to: UInt8.self) else { return }
        var bare = samples[0]
        bare.cursor = nil
        renderer.draw(bare, source: source, camera: camera, in: ctx)
        let crop = bare.crop
        let boxes = samples.map { $0.cursor.map { renderer.cursorBounds($0, crop: crop) } }
        guard let region = boxes.compactMap({ $0 }).filter({ !$0.isEmpty }).reduce(nil, { (union: CGRect?, box: CGRect) in union.map { $0.union(box) } ?? box }) else { return }
        // A bitmap's rows run top down in memory, while the boxes are y up.
        let x0 = Int(region.minX), cols = Int(region.width), row0 = ctx.height - Int(region.maxY), rows = Int(region.height)
        let stride = ctx.bytesPerRow, rowBytes = cols * 4
        let from = out + row0 * stride + x0 * 4, to = drawn + row0 * scratch.bytesPerRow + x0 * 4
        sum.withUnsafeMutableBufferPointer { sum in
            sum.baseAddress!.update(repeating: 0, count: rows * rowBytes)
            for sample in samples {
                for r in 0..<rows { memcpy(to + r * scratch.bytesPerRow, from + r * stride, rowBytes) }
                if let cursor = sample.cursor { renderer.drawCursor(cursor, crop: crop, in: scratch) }
                Self.add(to, stride: scratch.bytesPerRow, rowBytes: rowBytes, rows: rows, to: sum.baseAddress!)
            }
            Self.average(sum.baseAddress!, count: samples.count, rowBytes: rowBytes, rows: rows, into: out + row0 * stride + x0 * 4, stride: stride)
        }
    }

    /// Adds `rows` rows of `rowBytes` bytes from `source` into the running `sum`, which is packed row after row.
    private static func add(_ source: UnsafePointer<UInt8>, stride: Int, rowBytes: Int, rows: Int, to sum: UnsafeMutablePointer<UInt16>) {
        for r in 0..<rows {
            let s = source + r * stride, d = sum + r * rowBytes
            for i in 0..<rowBytes { d[i] &+= UInt16(s[i]) }
        }
    }

    /// Writes `sum / count`, rounded to the nearest, into `out`.
    private static func average(_ sum: UnsafePointer<UInt16>, count: Int, rowBytes: Int, rows: Int, into out: UnsafeMutablePointer<UInt8>, stride: Int) {
        let scale = 1 / Float(count)
        for r in 0..<rows {
            let s = sum + r * rowBytes, d = out + r * stride
            for i in 0..<rowBytes { d[i] = UInt8(truncatingIfNeeded: Int32(Float(s[i]) * scale + 0.5)) }
        }
    }

    private func scratch(like ctx: CGContext) -> CGContext? {
        if let scratch, scratch.width == ctx.width, scratch.height == ctx.height, scratch.bytesPerRow == ctx.bytesPerRow { return scratch }
        scratch = CGContext(data: nil, width: ctx.width, height: ctx.height, bitsPerComponent: 8, bytesPerRow: ctx.bytesPerRow, space: ExportFrameRenderer.colorSpace,
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        sum = [UInt16](repeating: 0, count: scratch == nil ? 0 : ctx.bytesPerRow * ctx.height)
        return scratch
    }
}

/// How hard an export works. An export is something the person asked for and is waiting on, so its threads run at the user-initiated
/// class: the utility class puts them on the efficiency cores, where each frame took about two and a half times as long. The machine
/// stays usable because few threads run, not because they are slow: the drawing uses at most half the cores, and the pictures that can
/// be averaged on the GPU leave the processor nearly idle.
public struct ExportTuning: Equatable, Sendable {
    /// Frames drawn at the same time. The decoder and the encoder run beside them.
    public var workers: Int
    public var qos: QualityOfService

    public init(workers: Int, qos: QualityOfService = .userInitiated) { self.workers = max(1, workers); self.qos = qos }

    /// Half the cores, between 1 and 6: the hardware encoder takes about 120 frames a second at 2560 x 1440 whatever else is done, and a
    /// few drawing threads already keep it fed.
    public static var standard: ExportTuning { ExportTuning(workers: min(6, max(1, ProcessInfo.processInfo.activeProcessorCount / 2))) }
}

/// The file appears at `output` only when it is complete; cancelling or failing leaves nothing there.
public enum VideoExporter {
    public static func export(project: RecordingProject, video: URL, settings: ExportSettings, to output: URL, tuning: ExportTuning = .standard,
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
        // The recording's own tracks come in at the editor's levels, and a track that is off is left out.
        let mix = try await AudioMixReader(files: [(video, 1)] + project.audioMix.map { (folder.appendingPathComponent($0.file), $0.gain) }, clips: project.timeline.clips,
                                           duration: plan.duration)
        defer { mix?.cancel() }
        do {
            let sink = Sink(writer: writer, audio: mix)
            let drawn = try await render(project: project, video: video, plan: plan, encoder: encoder, sink: sink, tuning: tuning, progress: progress)
            try await sink.finish()
            let duration = try await AVURLAsset(url: partial).load(.duration).seconds
            let bytes = ((try? FileManager.default.attributesOfItem(atPath: partial.path))?[.size] as? NSNumber)?.int64Value ?? 0
            try FileManager.default.moveItem(at: partial, to: output)
            return ExportReport(url: output, plan: plan, framesWritten: plan.frameCount, duration: duration, bytes: bytes, usesHardware: encoder.usesHardware,
                                encoderID: encoder.encoderID, renderSeconds: Date().timeIntervalSince(started), hasAudio: mix != nil,
                                blurredFrames: drawn.blurred, drawings: drawn.drawings)
        } catch {
            if writer.status == .writing { writer.cancelWriting() }
            throw error
        }
    }

    /// The finished video's frame at `outputTime` as one picture at the export's original size: the same drawing, and the source and
    /// camera frames read the same way, as the frame an export writes at that moment. It is the sharp frame, since a still has no shutter.
    public static func frame(project: RecordingProject, video: URL, at outputTime: Double) async throws -> CGImage {
        let plan = ExportPlan(project: project, settings: ExportSettings(resolution: .original))
        let t = min(max(outputTime, 0), project.outputDuration)
        let state = frameState(project, outputTime: t)
        let timeline = project.timeline
        let clip = timeline.clipIndex(at: t)
        // The reader starts shortly before the moment rather than at the clip's start, so a late frame does not decode the whole clip.
        var range = timeline.clips[clip]
        range.start = max(range.start, state.sourceTime - 1)
        let asset = AVURLAsset(url: video)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw ExportError.noVideo }
        let source = try ClipReader(asset: asset, track: track, clip: clip, range: range).image(at: state.sourceTime)
        var camera: CGImage?
        if state.camera != nil, let file = project.source.camera {
            let cameraAsset = AVURLAsset(url: video.deletingLastPathComponent().appendingPathComponent(file))
            if let cameraTrack = try? await cameraAsset.loadTracks(withMediaType: .video).first {
                camera = try? ClipReader(asset: cameraAsset, track: cameraTrack, clip: clip, range: range).image(at: state.sourceTime)
            }
        }
        let renderer = ExportFrameRenderer(plan: plan, project: project, folder: video.deletingLastPathComponent())
        guard let image = renderer.image(state, source: source, camera: camera) else { throw ExportError.writer("the frame could not be drawn") }
        return image
    }

    /// The encoder this machine gives an export of `plan`'s size, without writing anything.
    public static func probeEncoder(plan: ExportPlan) throws -> (usesHardware: Bool, encoderID: String) {
        let encoder = try Encoder(plan: plan)
        defer { encoder.invalidate() }
        return (encoder.usesHardware, encoder.encoderID)
    }

    private static func render(project: RecordingProject, video: URL, plan: ExportPlan, encoder: Encoder, sink: Sink, tuning: ExportTuning,
                               progress: @escaping @Sendable (Double) -> Void) async throws -> (blurred: Int, drawings: Int) {
        let asset = AVURLAsset(url: video)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw ExportError.noVideo }
        // The camera file shares the video's timeline, so each clip reads the same stretch of it. A project whose camera file is gone
        // still exports, without the camera.
        let cameraAsset = project.source.camera.map { AVURLAsset(url: video.deletingLastPathComponent().appendingPathComponent($0)) }
        let cameraTrack = try? await cameraAsset?.loadTracks(withMediaType: .video).first
        let pipeline = FramePipeline(project: project, plan: plan, encoder: encoder, sink: sink, tuning: tuning, progress: progress,
                                     source: (asset, track), camera: cameraAsset.flatMap { a in cameraTrack.map { (a, $0) } },
                                     folder: video.deletingLastPathComponent())
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (done: CheckedContinuation<(blurred: Int, drawings: Int), Error>) in
                let thread = Thread { do { done.resume(returning: try pipeline.run()) } catch { done.resume(throwing: error) } }
                thread.qualityOfService = tuning.qos
                thread.name = "export.decode"
                thread.start()
            }
        } onCancel: { pipeline.cancel() }
    }

    fileprivate static func draw(into buffer: CVPixelBuffer, _ body: (CGContext) -> Void) throws {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer),
                                  bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: ExportFrameRenderer.colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { throw ExportError.writer("a frame could not be drawn") }
        body(ctx)
    }
}

/// Reads, draws and encodes the frames of an export at the same time. One thread decodes the source in order, `tuning.workers` draw
/// frames in any order, and one thread hands the finished frames to the encoder in order, so the pictures reach the file as they would
/// from a single thread. A frame waits for a free slot before it is decoded, so the frames in flight, and the memory they hold, are bounded.
private final class FramePipeline: @unchecked Sendable {
    private let project: RecordingProject
    private let plan: ExportPlan
    private let encoder: Encoder
    private let sink: Sink
    private let tuning: ExportTuning
    private let progress: @Sendable (Double) -> Void
    private let source: (asset: AVAsset, track: AVAssetTrack)
    private let camera: (asset: AVAsset, track: AVAssetTrack)?
    private let renderer: ExportFrameRenderer

    /// Frames that may still be taken in; a count under `cond`, which unlike a semaphore may be dropped with any value.
    private var freeSlots: Int
    private let drawers = OperationQueue()
    private let cond = NSCondition()
    private var finished: [Int: CVPixelBuffer] = [:]
    private var failure: Error?
    private var cancelled = false
    private var spare: [SampleAccumulator] = []
    private var blurred = 0, drawings = 0

    init(project: RecordingProject, plan: ExportPlan, encoder: Encoder, sink: Sink, tuning: ExportTuning, progress: @escaping @Sendable (Double) -> Void,
         source: (AVAsset, AVAssetTrack), camera: (AVAsset, AVAssetTrack)?, folder: URL) {
        self.project = project; self.plan = plan; self.encoder = encoder; self.sink = sink; self.tuning = tuning; self.progress = progress
        self.source = source; self.camera = camera
        renderer = ExportFrameRenderer(plan: plan, project: project, folder: folder)
        freeSlots = tuning.workers + 2
        drawers.maxConcurrentOperationCount = tuning.workers
        drawers.qualityOfService = tuning.qos
        drawers.name = "export.draw"
    }

    func cancel() { fail(CancellationError()) }

    private func fail(_ error: Error) {
        cond.lock()
        if failure == nil { failure = error }
        cond.broadcast()
        cond.unlock()
    }

    private var aborted: Bool { cond.lock(); defer { cond.unlock() }; return failure != nil }

    func run() throws -> (blurred: Int, drawings: Int) {
        let encoding = DispatchGroup()
        encoding.enter()
        let thread = Thread { [self] in defer { encoding.leave() }; encode() }
        thread.qualityOfService = tuning.qos
        thread.name = "export.encode"
        thread.start()
        decode()
        encoding.wait()
        drawers.cancelAllOperations()
        cond.lock(); defer { cond.unlock() }
        if let failure { throw failure }
        return (blurred, drawings)
    }

    /// Walks the frames in order, reads the source pictures they show, and hands each to a drawing thread.
    private func decode() {
        do {
            let timeline = project.timeline
            var reader: ClipReader?, cameraReader: ClipReader?
            for k in 0..<plan.frameCount {
              try autoreleasepool {
                if aborted { return }
                let t = plan.time(ofFrame: k)
                let samples = frameSamples(project, outputTime: t, fps: plan.fps, pixelsAcross: renderer.frameRect.width)
                let state = samples[0]
                let clip = timeline.clipIndex(at: t)
                if reader?.clip != clip { reader = try ClipReader(asset: source.asset, track: source.track, clip: clip, range: timeline.clips[clip]) }
                let current = reader?.image(at: state.sourceTime)
                var cameraImage: CGImage?
                if state.camera != nil, let camera {
                    if cameraReader?.clip != clip { cameraReader = try? ClipReader(asset: camera.asset, track: camera.track, clip: clip, range: timeline.clips[clip]) }
                    cameraImage = cameraReader?.image(at: state.sourceTime)
                }
                cond.lock()
                while freeSlots == 0 && failure == nil { cond.wait() }
                freeSlots -= 1
                let stop = failure != nil
                cond.unlock()
                if stop { return }
                drawers.addOperation { [self] in draw(k, samples, current, cameraImage) }
              }
            }
        } catch { fail(error) }
    }

    private func draw(_ k: Int, _ samples: [FrameState], _ current: CGImage?, _ camera: CGImage?) {
        if aborted { return }
        let accumulator = checkout()
        defer { giveBack(accumulator) }
        do {
            let buffer = try encoder.makeBuffer()
            try VideoExporter.draw(into: buffer) { accumulator.draw(samples, with: renderer, source: current, camera: camera, in: $0) }
            cond.lock()
            finished[k] = buffer
            if samples.count > 1 { blurred += 1 }
            drawings += samples.count
            cond.broadcast()
            cond.unlock()
        } catch { fail(error) }
    }

    /// Takes the frames back in order, gives them to the encoder, and writes what it has finished.
    private func encode() {
        do {
            let frameDuration = CMTime(value: 1, timescale: CMTimeScale(plan.fps))
            var reported = -1
            for k in 0..<plan.frameCount {
                let more: Bool = try autoreleasepool {
                    cond.lock()
                    while finished[k] == nil && failure == nil { cond.wait() }
                    let buffer = finished.removeValue(forKey: k)
                    let stop = failure != nil
                    cond.unlock()
                    guard let buffer, !stop else { return false }
                    try encoder.encode(buffer, at: CMTime(value: CMTimeValue(k), timescale: CMTimeScale(plan.fps)), duration: frameDuration)
                    try sink.append(encoder.take())
                    cond.lock(); freeSlots += 1; cond.broadcast(); cond.unlock()
                    let percent = (k + 1) * 100 / plan.frameCount
                    if percent != reported { reported = percent; progress(Double(k + 1) / Double(plan.frameCount)) }
                    return true
                }
                if !more { return }
            }
            try encoder.finish()
            try sink.append(encoder.take())
        } catch { fail(error) }
    }

    private func checkout() -> SampleAccumulator {
        cond.lock(); defer { cond.unlock() }
        return spare.popLast() ?? SampleAccumulator()
    }

    private func giveBack(_ accumulator: SampleAccumulator) {
        cond.lock(); spare.append(accumulator); cond.unlock()
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
    /// Frames given to the session whose compressed sample has not come back. Bounded, so a slow encoder holds up the drawing instead of
    /// letting finished frames pile up in memory.
    private var inFlight = 0
    private let room = NSCondition()
    static let maxInFlight = 6

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
        room.lock()
        while inFlight >= Self.maxInFlight && !hasFailed { room.wait(until: Date(timeIntervalSinceNow: 0.05)) }
        inFlight += 1
        room.unlock()
        let status = VTCompressionSessionEncodeFrame(session, imageBuffer: buffer, presentationTimeStamp: time, duration: duration,
                                                     frameProperties: nil, infoFlagsOut: nil) { [weak self] status, _, sample in
            self?.receive(status, sample)
        }
        guard status == noErr else { throw ExportError.encoder(status) }
    }

    private var hasFailed: Bool { lock.lock(); defer { lock.unlock() }; return failure != noErr }

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
        if status != noErr { failure = status } else if let sample { ready.append(sample) }
        lock.unlock()
        room.lock(); inFlight -= 1; room.broadcast(); room.unlock()
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

    /// Blocks while the writer is not ready for more, so it runs on the encoder's own thread.
    func append(_ samples: [CMSampleBuffer]) throws {
        for sample in samples {
            let input = try self.input ?? start(with: sample)
            while !input.isReadyForMoreMediaData {
                if writer.status == .failed { throw ExportError.writer(writer.error?.localizedDescription ?? "the file could not be written") }
                Thread.sleep(forTimeInterval: 0.001)
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
