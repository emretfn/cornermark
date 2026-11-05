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
    private func makeSource(width: Int = 320, height: Int = 180, fps: Int = 30, frames: Int = 30, name: String = "screen.mp4",
                            pixel: ((Int) -> [UInt8])? = nil) async throws -> (URL, RecordingProject) {
        let url = folder.appendingPathComponent(name)
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
            if let pixel {
                let bgra = pixel(i), base = CVPixelBufferGetBaseAddress(buffer!)!.assumingMemoryBound(to: UInt8.self)
                for o in stride(from: 0, to: CVPixelBufferGetDataSize(buffer!), by: 4) { for k in 0..<4 { base[o + k] = bgra[k] } }
            } else {
                memset(CVPixelBufferGetBaseAddress(buffer!), Int32(i * 8), CVPixelBufferGetDataSize(buffer!))
            }
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

    func testTheExportDrawsTheCameraFromItsOwnFileWhereTheProjectPlacesIt() async throws {
        var (source, project) = try await makeSource()
        _ = try await makeSource(name: RecordingProjectFile.cameraName) { _ in [0x20, 0x20, 0xE0, 0xFF] }
        project.source.camera = RecordingProjectFile.cameraName
        func exported(_ name: String) async throws -> CGImage {
            let out = folder.appendingPathComponent(name)
            _ = try await VideoExporter.export(project: project, video: source, settings: ExportSettings(), to: out)
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: out))
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            return try await generator.image(at: CMTime(value: 15, timescale: 30)).image
        }
        func rgb(_ image: CGImage, _ x: Double, _ y: Double) -> [Int] {
            var px = [UInt8](repeating: 0, count: 4)
            let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(image.cropping(to: CGRect(x: Int(x), y: Int(y), width: 1, height: 1))!, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return px.prefix(3).map(Int.init)
        }
        let area = CGSize(width: project.source.pointWidth, height: project.source.pointHeight)
        let bubble = CameraLayout.bubbleRect(project.edits.camera, area: area)
        let k = 320 / area.width
        let shown = try await exported("with-camera.mp4")
        XCTAssertGreaterThan(rgb(shown, bubble.midX * k, bubble.midY * k)[0], 180, "the camera's red fills its bubble, at the project's place, y down")
        XCTAssertLessThan(rgb(shown, 300, 20)[0], 140, "and nowhere else")
        project.edits.camera.isVisible = false
        let hidden = try await exported("without-camera.mp4")
        XCTAssertLessThan(rgb(hidden, bubble.midX * k, bubble.midY * k)[0], 140, "a hidden camera is not drawn")
        project.edits.camera = CameraBubble(fullScreen: [CameraSpan(from: 0, to: 1)])
        let full = try await exported("full-camera.mp4")
        XCTAssertGreaterThan(rgb(full, 300, 20)[0], 180, "a full-screen span fills the whole picture with the camera")
    }
}
