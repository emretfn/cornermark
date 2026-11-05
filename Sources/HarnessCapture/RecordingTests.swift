import AppKit
import AVFoundation
import CornermarkCapture
import CornermarkCore

let recordingScratch = scratch + "recording/"

struct VideoFacts {
    var duration: Double
    var width: Int
    var height: Int
    var frames: Int
    var isH264: Bool
    var firstFrame: CGImage?
}

func inspectVideo(_ url: URL) async throws -> VideoFacts {
    let asset = AVURLAsset(url: url)
    guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw RecordingError.noFrames }
    let size = try await track.load(.naturalSize)
    let formats = try await track.load(.formatDescriptions)
    let reader = try AVAssetReader(asset: asset)
    let out = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
    reader.add(out)
    reader.startReading()
    var frames = 0
    while out.copyNextSampleBuffer() != nil { frames += 1 }
    let generator = AVAssetImageGenerator(asset: asset)
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = .zero
    let first = try? await generator.image(at: .zero).image
    return VideoFacts(duration: try await asset.load(.duration).seconds, width: Int(size.width), height: Int(size.height), frames: frames,
                      isH264: formats.contains { CMFormatDescriptionGetMediaSubType($0) == kCMVideoCodecType_H264 }, firstFrame: first)
}

@MainActor
func recordFixture(_ name: String, area: CGRect?, fps: Int, pacing: FixtureFrameSource.Pacing) async throws -> (RecordingReport, VideoFacts) {
    try? FileManager.default.createDirectory(atPath: recordingScratch, withIntermediateDirectories: true)
    let url = URL(fileURLWithPath: recordingScratch + name + ".mp4")
    let recorder = Recorder(source: FixtureFrameSource(area: area, fps: fps, pacing: pacing), output: url)
    try await recorder.start()
    let report = try await recorder.stop()
    return (report, try await inspectVideo(url))
}

/// RGB of the pixel at a fraction of the image, top-left origin.
@MainActor
func color(_ image: CGImage, _ fx: Double, _ fy: Double) -> [Int] {
    let px = Pixels.rgba(image)
    let x = min(image.width - 1, Int(Double(image.width) * fx)), y = min(image.height - 1, Int(Double(image.height) * fy))
    let o = (y * image.width + x) * 4
    return [Int(px[o]), Int(px[o + 1]), Int(px[o + 2])]
}

@MainActor
func dominant(_ rgb: [Int], is channel: Int) -> Bool {
    rgb[channel] > 120 && rgb.enumerated().allSatisfy { $0.offset == channel || rgb[channel] > $0.element + 50 }
}

@MainActor
func runRecordingTests() async {
    section("recording engine")
    do {
        let (report, video) = try await recordFixture("full-90f", area: nil, fps: 30, pacing: .scripted(frames: 90))
        check(video.isH264, "the file holds H.264 video")
        check(video.width == 1280 && video.height == 720, "the file is 1280x720", detail: "\(video.width)x\(video.height)")
        check(video.frames == 90 && report.framesWritten == 90, "90 scripted frames make 90 frames in the file", detail: "file \(video.frames), report \(report.framesWritten)")
        check(abs(video.duration - 3.0) < 0.05, "at 30 fps they last 3.0 s", detail: "\(video.duration)")
        check(report.framesDropped == 0 && report.dropRate == 0, "no frame counts as dropped", detail: "\(report.framesDropped)")
        check(report.fileBytes > 0 && report.fileBytes == (try? FileManager.default.attributesOfItem(atPath: report.url.path)[.size] as? Int), "the report carries the real file size")

        if let frame = video.firstFrame {
            check(dominant(color(frame, 0.03, 0.04), is: 0), "the top-left corner of the picture is red")
            check(dominant(color(frame, 0.97, 0.04), is: 1), "the top-right corner is green")
            check(dominant(color(frame, 0.03, 0.96), is: 2), "the bottom-left corner is blue")
            let br = color(frame, 0.97, 0.96)
            check(br[0] > 150 && br[1] > 150 && br[2] < 100, "the bottom-right corner is yellow", detail: "\(br)")
        } else {
            check(false, "the first frame can be read back")
        }

        let (holes, holesVideo) = try await recordFixture("holes-60f", area: nil, fps: 60, pacing: .scripted(frames: 60, skipping: [10, 11, 40]))
        check(holes.framesWritten == 57 && holesVideo.frames == 57, "three skipped frames leave 57 in the file", detail: "report \(holes.framesWritten), file \(holesVideo.frames)")
        check(holes.framesDropped == 3 && abs(holes.dropRate - 0.05) < 0.0001, "and the report counts exactly those three as dropped", detail: "\(holes.framesDropped), rate \(holes.dropRate)")

        let area = CGRect(x: 0, y: 0, width: 320, height: 180)
        let (cropReport, cropVideo) = try await recordFixture("area-bottom-left", area: area, fps: 30, pacing: .scripted(frames: 15))
        check(cropVideo.width == 320 && cropVideo.height == 180 && cropReport.format.width == 320, "an area records at its own size", detail: "\(cropVideo.width)x\(cropVideo.height)")
        if let frame = cropVideo.firstFrame {
            check(dominant(color(frame, 0.03, 0.96), is: 2), "the bottom-left area of the display starts with the blue corner at its own bottom-left")
            check(!dominant(color(frame, 0.03, 0.04), is: 0), "and has no red corner, which belongs to the display's top-left")
        } else {
            check(false, "the area's first frame can be read back")
        }

        let (odd, oddVideo) = try await recordFixture("odd-area", area: CGRect(x: 10, y: 10, width: 301, height: 151), fps: 30, pacing: .scripted(frames: 6))
        check(oddVideo.width == 300 && oddVideo.height == 150 && odd.format.height == 150, "an odd area is rounded down to even sides", detail: "\(oddVideo.width)x\(oddVideo.height)")
    } catch {
        check(false, "recording a fixture threw", detail: "\(error)")
    }

    do {
        let url = URL(fileURLWithPath: recordingScratch + "empty.mp4")
        let recorder = Recorder(source: FixtureFrameSource(pacing: .scripted(frames: 0)), output: url)
        try await recorder.start()
        _ = try await recorder.stop()
        check(false, "a recording with no frames fails")
    } catch {
        check((error as? RecordingError) == .noFrames, "a recording with no frames fails with noFrames", detail: "\(error)")
        check(!FileManager.default.fileExists(atPath: recordingScratch + "empty.mp4"), "and leaves no file behind")
    }

    do {
        let url = URL(fileURLWithPath: recordingScratch + "outside.mp4")
        let recorder = Recorder(source: FixtureFrameSource(area: CGRect(x: 5000, y: 5000, width: 100, height: 100), pacing: .scripted(frames: 3)), output: url)
        try await recorder.start()
        check(false, "an area outside the display is refused")
    } catch {
        check(!FileManager.default.fileExists(atPath: recordingScratch + "outside.mp4"), "an area outside the display is refused and writes nothing", detail: "\(error)")
    }

    do {
        let recorder = Recorder(source: FixtureFrameSource(fps: 60, pacing: .realtime), output: URL(fileURLWithPath: recordingScratch + "realtime.mp4"))
        try await recorder.start()
        try await Task.sleep(nanoseconds: 1_000_000_000)
        let report = try await recorder.stop()
        let video = try await inspectVideo(report.url)
        check(video.frames == report.framesWritten && report.framesWritten > 30, "a real-time fixture for one second fills the file", detail: "file \(video.frames), \(report.framesWritten) frames in \(report.duration) s, dropped \(report.framesDropped)")
        check(report.duration > 0.8 && report.duration < 1.3, "and the clock is real", detail: "\(report.duration)")
    } catch {
        check(false, "real-time fixture threw", detail: "\(error)")
    }

    section("stream geometry")
    let main = CGRect(x: 0, y: 0, width: 1440, height: 900)
    check(StreamGeometry.sourceRect(area: CGRect(x: 100, y: 50, width: 200, height: 100), displayFrame: main) == CGRect(x: 100, y: 750, width: 200, height: 100),
          "an area flips from bottom-left to top-left display points")
    let right = CGRect(x: 1440, y: -100, width: 1920, height: 1080)
    check(StreamGeometry.sourceRect(area: CGRect(x: 1500, y: 900, width: 100, height: 200), displayFrame: right) == CGRect(x: 60, y: 0, width: 100, height: 80),
          "a display with an offset origin gets display-local points, clipped at its top edge")
    check(StreamGeometry.sourceRect(area: CGRect(x: -50, y: -50, width: 100, height: 100), displayFrame: main) == CGRect(x: 0, y: 850, width: 50, height: 50),
          "an area sticking out is clipped to the display")
    check(StreamGeometry.sourceRect(area: CGRect(x: 3000, y: 0, width: 10, height: 10), displayFrame: main) == nil, "an area off the display gives nothing")
    check(StreamGeometry.format(of: CGRect(x: 0, y: 0, width: 100.5, height: 50), scale: 2, fps: 60) == FrameFormat(width: 200, height: 100, fps: 60), "a Retina area doubles in pixels with even sides")
}

@MainActor
func runProjectTimelineTests() async {
    section("recording project timeline")
    let area = CGRect(x: 1440, y: -100, width: 200, height: 100)
    check(PointerGeometry.local(CGPoint(x: 1450, y: -10), in: area) == CGPoint(x: 10, y: 10), "a global point near the top-left of an area is near (0, 0) of it")
    check(PointerGeometry.local(CGPoint(x: 1640, y: -100), in: area) == CGPoint(x: 200, y: 100), "and its bottom-right corner is its far corner")
    check(PointerScript.tour.position(at: 0.3).map { $0.x == 0.15 && $0.y == 0.2 } == true && PointerScript.tour.position(at: 7.0 + 0.3).map { $0.x == 0.15 && $0.y == 0.2 } == true,
          "the default pointer script rests at its first stop and starts over after a lap")
    do {
        // Frames start at 5.0 s on the source clock and the pointer script starts 0.25 s earlier, both at exact times.
        let firstFrame = 5.0, lead = 0.25, fps = 30, frames = 90
        let width = 1280.0, height = 720.0
        let script = PointerScript([.init(t: 0, x: 0.1, y: 0.1), .init(t: 1, x: 0.9, y: 0.2), .init(t: 2, x: 0.5, y: 0.9), .init(t: 4, x: 0.2, y: 0.3)])
        let pointer = ScriptedPointerSource(script: script, rate: 120, pacing: .fixed(origin: firstFrame - lead, count: 120 * 6))
        try? FileManager.default.createDirectory(atPath: recordingScratch, withIntermediateDirectories: true)
        let url = URL(fileURLWithPath: recordingScratch + "timeline.mp4")
        let recorder = Recorder(source: FixtureFrameSource(fps: fps, pacing: .scripted(frames: frames, origin: firstFrame)), output: url, pointer: pointer)
        try await recorder.start()
        let report = try await recorder.stop()
        let video = try await inspectVideo(url)

        check(report.firstFrameTime == firstFrame, "the report carries the first frame's time on the source clock", detail: "\(report.firstFrameTime)")
        check(abs(video.duration - 3.0) < 0.05 && video.frames == frames, "while the file itself starts at 0 and lasts 3.0 s", detail: "\(video.duration) s, \(video.frames) frames")
        check(report.area == CGRect(x: 0, y: 0, width: width, height: height), "and the report says which area was filmed", detail: "\(report.area)")
        guard let first = report.pointer.first, let last = report.pointer.last else { return check(false, "the pointer track has samples") }
        check(first.t == 0, "the pointer track starts at the first frame, not at the pointer's own start", detail: "\(first.t)")
        check(last.t >= report.duration && last.t < report.duration + 1.0 / 120 + 1e-9, "and stops at the first reading past the last frame", detail: "\(last.t) vs \(report.duration)")
        let exact = report.pointer.allSatisfy { sample in
            guard let at = script.position(at: sample.t + lead) else { return false }
            return abs(sample.x - at.x * width) < 1e-6 && abs(sample.y - at.y * height) < 1e-6
        }
        check(exact, "every sample sits where the script put the pointer at that moment, offset by the 0.25 s lead")

        let project = report.project
        let worst = (0..<frames).map { i -> Double in
            let t = Double(i) / Double(fps)
            guard let want = script.position(at: t + lead), let got = frameState(project, outputTime: t).cursor else { return .infinity }
            return hypot(got.x - want.x * width, got.y - want.y * height)
        }.max() ?? .infinity
        check(worst < 1.0, "frameState puts the pointer within one point of the script at every output frame", detail: "worst \(worst) pt")
        check(project.source.duration > report.duration && abs(project.source.duration - 3.0) < 1e-9, "the project lasts as long as the file", detail: "\(project.source.duration)")
    } catch {
        check(false, "the timeline check threw", detail: "\(error)")
    }
}
