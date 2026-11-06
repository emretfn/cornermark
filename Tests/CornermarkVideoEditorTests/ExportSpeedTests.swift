import AVFoundation
import CornermarkCore
import Metal
import XCTest
@testable import CornermarkVideoEditor

/// Guards what the faster export must keep: the pictures it writes are the pictures the plain drawing makes, whichever way they are
/// averaged, and the file is written the same whatever the number of threads. None of it depends on how long anything takes.
final class ExportSpeedTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("cornermark-export-speed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }

    private let width = 640, height = 360

    /// A picture with detail at every scale, so a wrong placement or a wrong filter shows as a large difference.
    private func detailedPicture(space: CGColorSpace) throws -> CGImage {
        let ctx = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue))
        let pixels = try XCTUnwrap(ctx.data).assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            for x in 0..<width {
                let o = y * ctx.bytesPerRow + x * 4
                let stripe = ((x / 6) + (y / 5)) % 2 == 0 ? 40 : 200
                pixels[o] = UInt8((x * 255) / width); pixels[o + 1] = UInt8((y * 255) / height); pixels[o + 2] = UInt8(stripe); pixels[o + 3] = 255
            }
        }
        return try XCTUnwrap(ctx.makeImage())
    }

    private func project(zoomed: Bool) -> RecordingProject {
        let duration = 3.0
        let pointer = stride(from: 0.0, through: duration, by: 1.0 / 60).map { PointerSample(t: $0, x: 20 + 90 * $0, y: 20 + 40 * $0) }
        var edits = RecordingProject.Edits()
        edits.background = VideoBackground(fill: .gradient(index: 2), padding: 24, shadow: 40, cornerRadius: 10)
        edits.motionBlur = MotionBlur(scope: .zoomsAndCursor, shutterAngle: 360)
        if zoomed { edits.zooms = [Zoom(start: 0.2, end: 2.5, scale: 2, mode: .followCursor)] }
        return RecordingProject(source: .init(pixelWidth: width, pixelHeight: height, pointWidth: Double(width) / 2, pointHeight: Double(height) / 2, fps: 60, duration: duration),
                                events: .init(pointer: pointer), edits: edits)
    }

    /// What averaging the plain drawings gives: each sample drawn by `ExportFrameRenderer.draw` and the bytes averaged in floating point.
    private func reference(_ samples: [FrameState], _ renderer: ExportFrameRenderer, source: CGImage) throws -> [UInt8] {
        var sum: [Double] = []
        for sample in samples {
            let ctx = try XCTUnwrap(ExportFrameRenderer.bitmap(width: renderer.width, height: renderer.height))
            renderer.draw(sample, source: source, in: ctx)
            let bytes = UnsafeBufferPointer(start: try XCTUnwrap(ctx.data).assumingMemoryBound(to: UInt8.self), count: ctx.bytesPerRow * ctx.height)
            if sum.isEmpty { sum = [Double](repeating: 0, count: bytes.count) }
            for i in 0..<bytes.count { sum[i] += Double(bytes[i]) }
        }
        return sum.map { UInt8(($0 / Double(samples.count)).rounded()) }
    }

    private func averaged(_ samples: [FrameState], _ renderer: ExportFrameRenderer, source: CGImage) throws -> (bytes: [UInt8], usedGPU: Bool) {
        let ctx = try XCTUnwrap(ExportFrameRenderer.bitmap(width: renderer.width, height: renderer.height))
        let accumulator = SampleAccumulator()
        accumulator.draw(samples, with: renderer, source: source, camera: nil, in: ctx)
        let bytes = Array(UnsafeBufferPointer(start: try XCTUnwrap(ctx.data).assumingMemoryBound(to: UInt8.self), count: ctx.bytesPerRow * ctx.height))
        return (bytes, accumulator.lastUsedGPU)
    }

    private func difference(_ a: [UInt8], _ b: [UInt8]) -> (maxDiff: Int, psnr: Double) {
        var squares = 0.0, worst = 0
        for i in 0..<a.count {
            let d = Int(a[i]) - Int(b[i])
            squares += Double(d * d); worst = max(worst, abs(d))
        }
        return (worst, 10 * log10(255 * 255 / max(squares / Double(a.count), 1e-9)))
    }

    func testAFrameWhereOnlyThePointerMovesIsTheAverageOfTheFullDrawings() throws {
        let project = project(zoomed: false)
        let renderer = ExportFrameRenderer(plan: ExportPlan(project: project, settings: ExportSettings()), project: project, folder: nil)
        let source = try detailedPicture(space: ExportFrameRenderer.colorSpace)
        let samples = frameSamples(project, outputTime: 1.0, fps: 60, pixelsAcross: renderer.frameRect.width)
        XCTAssertGreaterThan(samples.count, 2, "the pointer moves enough to blur")
        XCTAssertTrue(samples.allSatisfy { $0.crop == samples[0].crop }, "only the pointer moves")
        let made = try averaged(samples, renderer, source: source)
        let d = difference(made.bytes, try reference(samples, renderer, source: source))
        XCTAssertFalse(made.usedGPU, "a frame the pointer alone blurs is drawn on the processor, exactly")
        XCTAssertLessThanOrEqual(d.maxDiff, 1, "only rounding differs: \(d)")
    }

    func testAZoomingFrameAveragedOnTheGPUMatchesTheFullDrawings() throws {
        try XCTSkipIf(MTLCreateSystemDefaultDevice() == nil, "no Metal device")
        let project = project(zoomed: true)
        let renderer = ExportFrameRenderer(plan: ExportPlan(project: project, settings: ExportSettings()), project: project, folder: nil)
        for space in [ExportFrameRenderer.colorSpace, try XCTUnwrap(CGColorSpace(name: CGColorSpace.displayP3))] {
            let source = try detailedPicture(space: space)
            let samples = frameSamples(project, outputTime: 0.5, fps: 60, pixelsAcross: renderer.frameRect.width)
            XCTAssertGreaterThan(samples.count, 2, "the zoom moves enough to blur")
            XCTAssertFalse(samples.allSatisfy { $0.crop == samples[0].crop }, "the crop moves between the samples")
            let made = try averaged(samples, renderer, source: source)
            XCTAssertTrue(made.usedGPU, "a zooming frame without rings or a badge is averaged on the GPU")
            let d = difference(made.bytes, try reference(samples, renderer, source: source))
            XCTAssertGreaterThan(d.psnr, 40, "the average is the same picture to the eye: \(d)")
        }
    }

    func testAFrameWithARingStaysOnTheProcessorAndMatches() throws {
        var project = project(zoomed: true)
        project.events.clicks = [ClickEvent(t: 0.45, x: 60, y: 50)]
        project.edits.clicks = ClickHighlight(isVisible: true)
        let renderer = ExportFrameRenderer(plan: ExportPlan(project: project, settings: ExportSettings()), project: project, folder: nil)
        let source = try detailedPicture(space: ExportFrameRenderer.colorSpace)
        let samples = frameSamples(project, outputTime: 0.5, fps: 60, pixelsAcross: renderer.frameRect.width)
        XCTAssertFalse(samples[0].input.isEmpty, "a ring is on screen")
        let made = try averaged(samples, renderer, source: source)
        XCTAssertFalse(made.usedGPU, "a ring follows the crop, so each placement is drawn")
        XCTAssertLessThanOrEqual(difference(made.bytes, try reference(samples, renderer, source: source)).maxDiff, 3)
    }

    // MARK: whole exports

    private func makeSource(frames: Int = 24) async throws -> (URL, RecordingProject) {
        let url = folder.appendingPathComponent("screen.mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 180])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 180,
        ])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for i in 0..<frames {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
            CVPixelBufferLockBaseAddress(buffer!, [])
            let base = CVPixelBufferGetBaseAddress(buffer!)!.assumingMemoryBound(to: UInt8.self)
            for o in stride(from: 0, to: CVPixelBufferGetDataSize(buffer!), by: 4) {
                base[o] = UInt8(truncatingIfNeeded: i * 9 + (o / 4) % 320); base[o + 1] = UInt8(i * 5); base[o + 2] = UInt8(truncatingIfNeeded: (o / 1280) * 2); base[o + 3] = 255
            }
            CVPixelBufferUnlockBaseAddress(buffer!, [])
            adaptor.append(buffer!, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 30))
        }
        input.markAsFinished()
        await writer.finishWriting()
        let duration = Double(frames) / 30
        var edits = RecordingProject.Edits()
        edits.zooms = [Zoom(start: 0.1, end: duration - 0.1, scale: 2, mode: .followCursor)]
        edits.background = VideoBackground(fill: .gradient(index: 1), padding: 16, shadow: 30, cornerRadius: 8)
        let project = RecordingProject(source: .init(pixelWidth: 320, pixelHeight: 180, pointWidth: 160, pointHeight: 90, fps: 30, duration: duration),
                                       events: .init(pointer: [PointerSample(t: 0, x: 10, y: 10), PointerSample(t: duration, x: 140, y: 80)]), edits: edits)
        return (url, project)
    }

    /// A checksum of every decoded frame, in order, which does not depend on the container's dates.
    private func frameChecksums(_ url: URL) async throws -> [UInt64] {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var sums: [UInt64] = []
        while let sample = output.copyNextSampleBuffer() {
            let buffer = try XCTUnwrap(CMSampleBufferGetImageBuffer(sample))
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            var h: UInt64 = 1469598103934665603
            let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
            for row in 0..<CVPixelBufferGetHeight(buffer) {
                let line = base + row * CVPixelBufferGetBytesPerRow(buffer)
                for i in 0..<(CVPixelBufferGetWidth(buffer) * 4) { h = (h ^ UInt64(line[i])) &* 1099511628211 }
            }
            CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
            sums.append(h)
        }
        return sums
    }

    func testTheNumberOfThreadsDoesNotChangeTheFile() async throws {
        let (source, project) = try await makeSource()
        let one = folder.appendingPathComponent("one.mp4"), many = folder.appendingPathComponent("many.mp4")
        let a = try await VideoExporter.export(project: project, video: source, settings: ExportSettings(), to: one, tuning: ExportTuning(workers: 1))
        let b = try await VideoExporter.export(project: project, video: source, settings: ExportSettings(), to: many, tuning: ExportTuning(workers: 4))
        XCTAssertEqual(a.framesWritten, b.framesWritten)
        XCTAssertGreaterThan(b.blurredFrames, 0, "the project has frames that are averaged")
        let sums = try await frameChecksums(one)
        XCTAssertEqual(sums.count, a.framesWritten)
        let others = try await frameChecksums(many)
        XCTAssertEqual(sums, others, "frames reach the encoder in order and are drawn the same way whichever thread draws them")
    }

    func testTheHardwareEncoderIsUsedWhereThereIsOne() async throws {
        let (source, project) = try await makeSource(frames: 6)
        let report = try await VideoExporter.export(project: project, video: source, settings: ExportSettings(), to: folder.appendingPathComponent("hw.mp4"))
        #if arch(arm64)
        XCTAssertTrue(report.usesHardware, "an Apple silicon Mac encodes with its media engine, not the processor: \(report.encoderID)")
        #endif
        XCTAssertFalse(report.encoderID.isEmpty)
    }

    func testEveryFrameOfAZoomedExportIsWrittenOnce() async throws {
        try XCTSkipIf(MTLCreateSystemDefaultDevice() == nil, "no Metal device")
        let (source, project) = try await makeSource()
        let gpu = folder.appendingPathComponent("gpu.mp4")
        _ = try await VideoExporter.export(project: project, video: source, settings: ExportSettings(), to: gpu)
        let ok = try await frameChecksums(gpu)
        XCTAssertEqual(ok.count, 24)
        XCTAssertEqual(Set(ok).count, ok.count, "every frame is different, so none was written twice or skipped")
    }
}
