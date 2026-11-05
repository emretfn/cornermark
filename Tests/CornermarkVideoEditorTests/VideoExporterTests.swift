import AVFoundation
import CornermarkCore
import XCTest
@testable import CornermarkVideoEditor

final class VideoExporterTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("cornermark-export-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }

    /// A source of `frames` solid frames whose grey level steps up, so a frame's level tells which source frame it was.
    private func makeSource(width: Int = 320, height: Int = 180, fps: Int = 30, frames: Int = 30) async throws -> (URL, RecordingProject) {
        let url = folder.appendingPathComponent("screen.mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for i in 0..<frames {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
            CVPixelBufferLockBaseAddress(buffer!, [])
            memset(CVPixelBufferGetBaseAddress(buffer!), Int32(i * 8), CVPixelBufferGetDataSize(buffer!))
            CVPixelBufferUnlockBaseAddress(buffer!, [])
            adaptor.append(buffer!, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: CMTimeScale(fps)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed)
        let duration = Double(frames) / Double(fps)
        let project = RecordingProject(source: .init(pixelWidth: width, pixelHeight: height, pointWidth: Double(width) / 2, pointHeight: Double(height) / 2,
                                                     fps: fps, duration: duration),
                                       events: .init(pointer: [PointerSample(t: 0, x: 10, y: 10), PointerSample(t: duration, x: 150, y: 80)]))
        return (url, project)
    }

    func testTheExportIsAsLongAsTheProjectAndPlaysItsFrames() async throws {
        let (source, project) = try await makeSource()
        let out = folder.appendingPathComponent("export.mp4")
        let report = try await VideoExporter.export(project: project, video: source, settings: ExportSettings(), to: out)
        XCTAssertEqual(report.duration, project.source.duration, accuracy: 1.0 / 30, "the file is as long as the project")
        XCTAssertEqual(report.framesWritten, 30)
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.path))
        XCTAssertGreaterThan(report.bytes, 0)
        let track = try await AVURLAsset(url: out).loadTracks(withMediaType: .video).first
        let size = try await track?.load(.naturalSize)
        XCTAssertEqual(size, CGSize(width: 320, height: 180))
        XCTAssertEqual((try FileManager.default.contentsOfDirectory(atPath: folder.path)).sorted(), ["export.mp4", "screen.mp4"], "no partial file is left")
    }

    /// The grey level of each frame of `url`, decoded in order.
    private func levels(_ url: URL) async throws -> [Int] {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var out: [Int] = []
        while let sample = output.copyNextSampleBuffer(), let buffer = CMSampleBufferGetImageBuffer(sample) {
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            let p = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
            let row = CVPixelBufferGetBytesPerRow(buffer)
            out.append(Int(p[CVPixelBufferGetHeight(buffer) / 2 * row + 40 * 4 + 1]))
            CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
        }
        return out
    }

    func testATrimmedExportIsAsLongAsItsClipsAndCutsOnTheirFrames() async throws {
        var (source, project) = try await makeSource()
        project.events = .init()
        project.edits.clips = [Clip(start: 0, end: 0.5), Clip(start: 0.7, end: 0.9)]
        let out = folder.appendingPathComponent("trimmed.mp4")
        let report = try await VideoExporter.export(project: project, video: source, settings: ExportSettings(), to: out)
        XCTAssertEqual(report.framesWritten, 21)
        XCTAssertEqual(report.duration, 0.7, accuracy: 0.5 / 30, "the file is as long as what the clips keep")
        let shown = try await levels(out)
        let expected = (Array(0..<15) + Array(21..<27)).map { $0 * 8 }
        XCTAssertEqual(shown.count, expected.count)
        for (k, (got, want)) in zip(shown, expected).enumerated() {
            XCTAssertEqual(got, want, accuracy: 4, "output frame \(k) shows source frame \(want / 8)")
        }
        XCTAssertEqual(shown[14], 14 * 8, accuracy: 4, "the last frame before the cut is source frame 14")
        XCTAssertEqual(shown[15], 21 * 8, accuracy: 4, "the first frame after the cut is source frame 21, not 15")
    }

    func testCancellingLeavesNoFile() async throws {
        let (source, project) = try await makeSource(frames: 90)
        let out = folder.appendingPathComponent("export.mp4")
        let task = Task { try await VideoExporter.export(project: project, video: source, settings: ExportSettings(), to: out) { fraction in
            if fraction > 0.2 { withUnsafeCurrentTask { $0?.cancel() } }
        } }
        do {
            _ = try await task.value
            XCTFail("a cancelled export must not finish")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["screen.mp4"], "nothing but the source is left")
    }

    func testFramesFollowThePointerTrack() throws {
        let project = RecordingProject(source: .init(pixelWidth: 200, pixelHeight: 100, pointWidth: 100, pointHeight: 50, fps: 30, duration: 1),
                                       events: .init(pointer: [PointerSample(t: 0, x: 20, y: 10)]))
        let renderer = ExportFrameRenderer(plan: ExportPlan(project: project, settings: ExportSettings()), source: project.source)
        let image = try XCTUnwrap(renderer.image(frameState(project, outputTime: 0), source: nil))
        let pixels = try XCTUnwrap(image.dataProvider?.data as Data?)
        func grey(_ x: Int, _ y: Int) -> UInt8 { pixels[y * image.bytesPerRow + x * 4 + 1] }
        XCTAssertGreaterThan(grey(20 * 2 + 3, 10 * 2 + 12), 200, "the pointer's white body is just below and right of its tip, y down")
        XCTAssertEqual(grey(150, 80), 0, "the rest is the black backdrop of a frame without a picture")
    }
}
