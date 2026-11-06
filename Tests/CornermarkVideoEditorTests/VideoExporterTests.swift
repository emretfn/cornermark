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

    /// A screen recording gets a frame only when the screen changes, so a clip can start long after the frame it shows.
    func testAClipStartingInAStillStretchShowsTheFrameBeforeIt() async throws {
        let url = folder.appendingPathComponent("screen.mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 180])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 180,
        ])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for (t, level) in [(0.0, 0), (0.1, 80), (0.9, 160)] {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
            CVPixelBufferLockBaseAddress(buffer!, [])
            memset(CVPixelBufferGetBaseAddress(buffer!), Int32(level), CVPixelBufferGetDataSize(buffer!))
            CVPixelBufferUnlockBaseAddress(buffer!, [])
            adaptor.append(buffer!, withPresentationTime: CMTime(seconds: t, preferredTimescale: 600))
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(seconds: 1, preferredTimescale: 600))
        await writer.finishWriting()
        var project = RecordingProject(source: .init(pixelWidth: 320, pixelHeight: 180, pointWidth: 160, pointHeight: 90, fps: 30, duration: 1))
        project.edits.clips = [Clip(start: 0.5, end: 1)]
        let out = folder.appendingPathComponent("still.mp4")
        _ = try await VideoExporter.export(project: project, video: url, settings: ExportSettings(), to: out)
        let shown = try await levels(out)
        XCTAssertEqual(shown.count, 15)
        XCTAssertEqual(shown.first ?? -1, 80, accuracy: 4, "at 0.5 s the screen still shows the frame from 0.1 s, not the one from 0.9 s")
        XCTAssertEqual(shown[11], 80, accuracy: 4, "source 0.867 s is still the 0.1 s frame")
        XCTAssertEqual(shown[12], 160, accuracy: 4, "source 0.9 s is the new frame")
    }

    /// A mono AAC track of `seconds` with a short full-scale burst at each of `clicks` seconds and silence elsewhere.
    private func makeSound(_ name: String, seconds: Double, clicks: [Double]) throws -> URL {
        let url = folder.appendingPathComponent(name)
        let rate = 48_000.0
        let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1])
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(seconds * rate))!
        buffer.frameLength = buffer.frameCapacity
        let samples = buffer.floatChannelData![0]
        for i in 0..<Int(buffer.frameLength) { samples[i] = 0 }
        for c in clicks { for i in 0..<240 { samples[Int(c * rate) + i] = Float(0.9 * cos(2 * .pi * 2000 * Double(i) / rate)) } }
        try file.write(from: buffer)
        return url
    }

    /// Where each burst starts in a file's sound, in seconds: the first loud sample more than a tenth of a second after the last.
    private func bursts(_ url: URL) throws -> (onsets: [Double], seconds: Double) {
        let file = try AVAudioFile(forReading: url)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        let rate = file.processingFormat.sampleRate, samples = buffer.floatChannelData![0]
        var onsets: [Double] = [], last = -Int.max / 2
        for i in 0..<Int(buffer.frameLength) where abs(samples[i]) > 0.3 {
            if i - last > Int(rate / 10) { onsets.append(Double(i) / rate) }
            last = i
        }
        return (onsets, Double(buffer.frameLength) / rate)
    }

    func testTheExportCarriesTheProjectSoundCutByTheSameClips() async throws {
        var (source, project) = try await makeSource(frames: 60)
        _ = try makeSound("mic.m4a", seconds: 2, clicks: [0.25, 1.25, 1.75])
        project.source.microphone = "mic.m4a"
        let whole = folder.appendingPathComponent("whole.mp4")
        let full = try await VideoExporter.export(project: project, video: source, settings: ExportSettings(), to: whole)
        let wholeSound = try bursts(whole)
        XCTAssertTrue(full.hasAudio)
        XCTAssertEqual(wholeSound.seconds, 2, accuracy: 0.03, "the sound is as long as the video")
        XCTAssertEqual(wholeSound.onsets.count, 3)
        for (got, want) in zip(wholeSound.onsets, [0.25, 1.25, 1.75]) { XCTAssertEqual(got, want, accuracy: 0.001, "a burst stays on its moment") }

        project.edits.clips = [Clip(start: 0, end: 0.5), Clip(start: 1.5, end: 2)]
        let cut = folder.appendingPathComponent("cut.mp4")
        let report = try await VideoExporter.export(project: project, video: source, settings: ExportSettings(), to: cut)
        let cutSound = try bursts(cut)
        XCTAssertEqual(report.duration, 1, accuracy: 1.0 / 30)
        XCTAssertEqual(cutSound.seconds, 1, accuracy: 0.03, "the sound keeps only what the clips keep")
        XCTAssertEqual(cutSound.onsets.count, 2, "the burst inside the removed stretch is gone")
        for (got, want) in zip(cutSound.onsets, [0.25, 0.75]) { XCTAssertEqual(got, want, accuracy: 0.001, "a burst after a cut moves with its clip") }
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
        let renderer = ExportFrameRenderer(plan: ExportPlan(project: project, settings: ExportSettings()), project: project, folder: nil)
        let image = try XCTUnwrap(renderer.image(frameState(project, outputTime: 0), source: nil))
        let pixels = try XCTUnwrap(image.dataProvider?.data as Data?)
        func grey(_ x: Int, _ y: Int) -> UInt8 { pixels[y * image.bytesPerRow + x * 4 + 1] }
        XCTAssertGreaterThan(grey(20 * 2 + 3, 10 * 2 + 12), 200, "the pointer's white body is just below and right of its tip, y down")
        XCTAssertEqual(grey(150, 80), 0, "the rest is the black backdrop of a frame without a picture")
    }

    func testAZoomMovesThePointerAndLeavesTheCameraBubbleInTheFrame() throws {
        let zoom = Zoom(start: 0, end: 1, scale: 2, center: ZoomPoint(x: 0.25, y: 0.25))
        var project = RecordingProject(source: .init(pixelWidth: 400, pixelHeight: 200, pointWidth: 100, pointHeight: 50, fps: 30, duration: 1),
                                       events: .init(pointer: [PointerSample(t: 0, x: 20, y: 10)]), edits: .init(zooms: [zoom]))
        project.source.camera = RecordingProjectFile.cameraName
        let renderer = ExportFrameRenderer(plan: ExportPlan(project: project, settings: ExportSettings()), project: project, folder: nil)
        let red = try XCTUnwrap(solidImage(red: 255))
        func pixels(_ project: RecordingProject, at t: Double) throws -> (CGImage, Data) {
            let image = try XCTUnwrap(renderer.image(frameState(project, outputTime: t), source: nil, camera: red))
            return (image, try XCTUnwrap(image.dataProvider?.data as Data?))
        }
        var plain = project
        plain.edits.zooms = []
        let (zoomedImage, zoomed) = try pixels(project, at: 0.5)
        let (_, whole) = try pixels(plain, at: 0.5)
        func level(_ image: CGImage, _ data: Data, _ x: Int, _ y: Int, channel: Int) -> UInt8 { data[y * image.bytesPerRow + x * 4 + channel] }
        let area = CGSize(width: 100, height: 50)
        let bubble = CameraLayout.bubbleRect(project.edits.camera, area: area)
        let bx = Int(bubble.midX * 4), by = Int(bubble.midY * 4)
        XCTAssertEqual(level(zoomedImage, zoomed, bx, by, channel: 2), 255, "the bubble's red is where it is without the zoom")
        XCTAssertEqual(level(zoomedImage, zoomed, bx, by, channel: 2), level(zoomedImage, whole, bx, by, channel: 2))
        // The crop is the top-left half, so the pointer's tip, at (20, 10) points, is at (40, 20) points of the frame, 4 pixels per point.
        XCTAssertGreaterThan(level(zoomedImage, zoomed, 40 * 4 + 6, 20 * 4 + 20, channel: 1), 200, "the pointer moved with the picture, twice as far from the corner")
        XCTAssertLessThan(level(zoomedImage, zoomed, 20 * 4 + 6, 10 * 4 + 20, channel: 1), 60, "and is not where it was")
        XCTAssertGreaterThan(level(zoomedImage, whole, 20 * 4 + 6, 10 * 4 + 20, channel: 1), 200, "without the zoom it is there")
    }

    private func solidImage(red: UInt8) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: CGFloat(red) / 255, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        return ctx.makeImage()
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
