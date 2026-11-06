import XCTest
@testable import CornermarkCore

final class MotionBlurTests: XCTestCase {
    /// A zoom moving in from 1 s, and a pointer crossing the area from 4 s to 5 s, then resting.
    private func project(_ blur: MotionBlur) -> RecordingProject {
        let pointer = (0...60).map { PointerSample(t: 4 + Double($0) / 60, x: 10 + Double($0) * 3, y: 25) }
        return RecordingProject(source: .init(pointWidth: 200, pointHeight: 100, fps: 60, duration: 8), events: .init(pointer: pointer),
                                edits: .init(zooms: [Zoom(start: 1, end: 3, scale: 2, mode: .manual, center: ZoomPoint(x: 0.3, y: 0.3))], motionBlur: blur))
    }

    func testANewProjectBlursZoomsAndThePointerAtHalfAFrame() {
        XCTAssertEqual(RecordingProject().edits.motionBlur, MotionBlur(scope: .zoomsAndCursor, shutterAngle: 180))
        XCTAssertEqual(MotionBlur().sampleCount, 8)
        XCTAssertEqual(MotionBlur(shutterAngle: 360).sampleCount, 16)
        XCTAssertEqual(MotionBlur(shutterAngle: 30).sampleCount, 2)
    }

    func testAProjectWrittenBeforeBlurReadsTheDefault() throws {
        let json = #"{"edits":{"cursor":{"isVisible":true}}}"#.data(using: .utf8)!
        XCTAssertEqual(try JSONDecoder().decode(RecordingProject.self, from: json).edits.motionBlur, MotionBlur())
        let saved = try JSONEncoder().encode(project(MotionBlur(scope: .zooms, shutterAngle: 270)))
        XCTAssertEqual(try JSONDecoder().decode(RecordingProject.self, from: saved).edits.motionBlur, MotionBlur(scope: .zooms, shutterAngle: 270))
    }

    func testTheShutterWindowIsCentredOnTheFrameAndEvenlySpaced() {
        let times = MotionBlur(shutterAngle: 180).sampleTimes(at: 2, fps: 60)
        XCTAssertEqual(times.count, 8)
        XCTAssertEqual(times.reduce(0, +) / 8, 2, accuracy: 1e-12, "the smear sits around the sharp frame's moment")
        XCTAssertEqual(times.last! - times.first!, 0.5 / 60 * 7 / 8, accuracy: 1e-12, "180 degrees spans half a frame")
        let gaps = zip(times.dropFirst(), times).map { $0 - $1 }
        XCTAssertEqual(gaps.max()! - gaps.min()!, 0, accuracy: 1e-12)
        XCTAssertLessThan(MotionBlur(shutterAngle: 360).sampleTimes(at: 2, fps: 60).last!, 2 + 0.5 / 60, "the window never reaches the next frame's moment")
    }

    func testOffAndStillFramesAreTheSharpFrame() {
        let off = project(MotionBlur(scope: .off))
        for t in [0.5, 1.2, 4.5] { XCTAssertEqual(frameSamples(off, outputTime: t, fps: 60, pixelsAcross: 400), [frameState(off, outputTime: t)]) }
        let on = project(MotionBlur())
        XCTAssertEqual(frameSamples(on, outputTime: 0.5, fps: 60, pixelsAcross: 400), [frameState(on, outputTime: 0.5)], "nothing moves before the zoom")
        XCTAssertEqual(frameSamples(on, outputTime: 2, fps: 60, pixelsAcross: 400), [frameState(on, outputTime: 2)], "the zoom holds still between its moves")
    }

    func testAZoomMoveSpreadsTheCropOverTheShutter() {
        let p = project(MotionBlur())
        let samples = frameSamples(p, outputTime: 1.3, fps: 60, pixelsAcross: 400)
        XCTAssertEqual(samples.count, 8)
        let times = p.edits.motionBlur.sampleTimes(at: 1.3, fps: 60)
        for (sample, t) in zip(samples, times) {
            XCTAssertEqual(sample.crop, frameState(p, outputTime: t).crop, "each sample takes the crop of its own moment")
            XCTAssertEqual(sample.sourceTime, frameState(p, outputTime: 1.3).sourceTime, "the recording's picture is the frame's own")
        }
        XCTAssertLessThan(samples.first!.crop.scale, samples.last!.crop.scale, "the camera is closing in")
        let wide = frameSamples(project(MotionBlur(shutterAngle: 360)), outputTime: 1.3, fps: 60, pixelsAcross: 400)
        XCTAssertGreaterThan(wide.last!.crop.scale - wide.first!.crop.scale, samples.last!.crop.scale - samples.first!.crop.scale)
    }

    func testAFasterMoveGetsMoreSamplesSoNoCopiesShowApart() {
        let p = project(MotionBlur())
        let slow = frameSamples(p, outputTime: 4.5, fps: 60, pixelsAcross: 400)
        let fast = frameSamples(p, outputTime: 4.5, fps: 60, pixelsAcross: 4000)
        XCTAssertEqual(slow.count, 8, "a slow move keeps the angle's own count")
        XCTAssertGreaterThan(fast.count, slow.count, "the same move drawn ten times wider needs more samples")
        let gaps = zip(fast.dropFirst(), fast).map { abs(($0.cursor?.x ?? 0) - ($1.cursor?.x ?? 0)) * 4000 / 200 }
        XCTAssertLessThanOrEqual(gaps.max() ?? 0, MotionBlur.sampleSpacing + 0.01, "neighbouring drawings land at most 1.5 output pixels apart")
        XCTAssertEqual(frameSamples(p, outputTime: 4.5, fps: 60, pixelsAcross: 400_000).count, MotionBlur.maxSamples)
    }

    func testThePointerBlursOnlyWhenTheScopeCoversIt() throws {
        let both = frameSamples(project(MotionBlur()), outputTime: 4.5, fps: 60, pixelsAcross: 400)
        XCTAssertEqual(both.count, 8)
        XCTAssertLessThan(try XCTUnwrap(both.first?.cursor?.x), try XCTUnwrap(both.last?.cursor?.x))
        let zooms = project(MotionBlur(scope: .zooms))
        XCTAssertEqual(frameSamples(zooms, outputTime: 4.5, fps: 60, pixelsAcross: 400), [frameState(zooms, outputTime: 4.5)], "a pointer moving under a still camera is sharp")
        let zoomed = frameSamples(zooms, outputTime: 1.3, fps: 60, pixelsAcross: 400)
        XCTAssertEqual(Set(zoomed.map { $0.cursor?.x }).count, 1, "the pointer stays where it is in the recording and moves only with the camera")
    }

    func testThePointerDoesNotSmearAcrossACut() throws {
        var p = project(MotionBlur())
        p.edits.zooms = []
        p.edits.clips = [Clip(start: 0, end: 4.5), Clip(start: 6, end: 8)]
        let t = 4.5 - 1.0 / 480
        let samples = frameSamples(p, outputTime: t, fps: 60, pixelsAcross: 400)
        let times = p.edits.motionBlur.sampleTimes(at: t, fps: 60)
        let sharp = try XCTUnwrap(frameState(p, outputTime: t).cursor)
        XCTAssertEqual(samples.count, 8, "the pointer is moving in the frame's own clip")
        for (sample, at) in zip(samples, times) {
            let x = try XCTUnwrap(sample.cursor?.x)
            if at >= 4.5 { XCTAssertEqual(x, sharp.x, "past the cut the sample keeps the frame's pointer") } else { XCTAssertLessThan(abs(x - sharp.x), 2) }
        }
        XCTAssertGreaterThan(try XCTUnwrap(frameState(p, outputTime: 4.5).cursor?.x) - sharp.x, 50, "the next clip starts with the pointer far away")
    }
}
