import XCTest
@testable import CornermarkCore

final class RecordingProjectTests: XCTestCase {
    private func decode(_ json: String) throws -> RecordingProject {
        try JSONDecoder().decode(RecordingProject.self, from: Data(json.utf8))
    }

    private func project(duration: Double = 4, samples: [PointerSample]? = nil, cursor: CursorSettings = CursorSettings()) -> RecordingProject {
        let line = samples ?? [PointerSample(t: 0, x: 10, y: 20), PointerSample(t: 2, x: 110, y: 120), PointerSample(t: 4, x: 10, y: 20)]
        return RecordingProject(source: .init(pixelWidth: 960, pixelHeight: 540, pointWidth: 480, pointHeight: 270, fps: 60, duration: duration),
                                events: .init(pointer: line), edits: .init(cursor: cursor))
    }

    func testEmptyObjectDecodesToDefaults() throws {
        let p = try decode("{}")
        XCTAssertEqual(p, RecordingProject())
        XCTAssertEqual(p.source.video, "screen.mp4")
        XCTAssertTrue(p.edits.cursor.isVisible)
        XCTAssertEqual(p.edits.cursor.scale, 1)
        XCTAssertTrue(p.events.pointer.isEmpty)
    }

    func testMissingAndUnknownFieldsDoNotFail() throws {
        let p = try decode("""
        {"version": 7, "future": {"zooms": [1, 2]}, "source": {"video": "a.mp4", "duration": 3.5, "codec": "x"},
         "events": {"clicks": [], "pointer": [{"t": 1, "x": 5, "y": 6}]}, "edits": {"cursor": {"scale": 2}, "zooms": []}}
        """)
        XCTAssertEqual(p.version, 7)
        XCTAssertEqual(p.source.video, "a.mp4")
        XCTAssertEqual(p.source.duration, 3.5)
        XCTAssertEqual(p.source.fps, 60)
        XCTAssertEqual(p.events.pointer, [PointerSample(t: 1, x: 5, y: 6)])
        XCTAssertEqual(p.edits.cursor, CursorSettings(isVisible: true, scale: 2))
    }

    func testOneDamagedSampleCostsOnlyThatSample() throws {
        let p = try decode(#"{"events": {"pointer": [{"t": 2, "x": 1, "y": 1}, {"t": "late", "x": 1}, {"t": 1, "x": 0, "y": 0}]}}"#)
        XCTAssertEqual(p.events.pointer.map(\.t), [1, 2], "the broken entry is dropped and the rest is sorted")
    }

    func testRoundTripThroughTheFolder() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("RecordingProjectTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let original = project(cursor: CursorSettings(isVisible: false, scale: 2.5))
        try RecordingProjectFile.write(original, to: folder)
        XCTAssertEqual(try RecordingProjectFile.read(from: folder), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["project.json"])
    }

    func testFrameStateIsPureAndFollowsTheTrackLinearly() {
        let p = project()
        XCTAssertEqual(frameState(p, outputTime: 1), frameState(p, outputTime: 1))
        XCTAssertEqual(frameState(p, outputTime: 1).cursor, CursorFrame(x: 60, y: 70, scale: 1))
        XCTAssertEqual(frameState(p, outputTime: 1).sourceTime, 1)
        XCTAssertEqual(frameState(p, outputTime: 2).cursor, CursorFrame(x: 110, y: 120, scale: 1))
    }

    func testBeforeTheFirstSampleAndAfterTheLastThePointerStays() {
        let p = project(samples: [PointerSample(t: 1, x: 30, y: 40), PointerSample(t: 2, x: 50, y: 60)])
        XCTAssertEqual(frameState(p, outputTime: 0).cursor, CursorFrame(x: 30, y: 40, scale: 1))
        XCTAssertEqual(frameState(p, outputTime: 3.9).cursor, CursorFrame(x: 50, y: 60, scale: 1))
    }

    func testTimeOutsideTheVideoIsClamped() {
        let p = project(duration: 4)
        XCTAssertEqual(frameState(p, outputTime: -3).sourceTime, 0)
        XCTAssertEqual(frameState(p, outputTime: 99).sourceTime, 4)
    }

    func testStepByStepAtSixtyFramesNeverJumps() {
        let p = project()
        var previous: CursorFrame?
        var worst = 0.0
        for i in 0...240 {
            guard let now = frameState(p, outputTime: Double(i) / 60).cursor else { return XCTFail("a visible pointer with samples always draws") }
            if let previous { worst = max(worst, hypot(now.x - previous.x, now.y - previous.y)) }
            previous = now
        }
        let fastest = hypot(100.0, 100.0) / 2 / 60
        XCTAssertEqual(worst, fastest, accuracy: 1e-9, "no step is longer than the fastest segment allows")
    }

    func testCursorSettingsChangeTheDrawingAndNothingElse() {
        let a = frameState(project(cursor: CursorSettings(isVisible: true, scale: 1)), outputTime: 1.3)
        let b = frameState(project(cursor: CursorSettings(isVisible: true, scale: 3)), outputTime: 1.3)
        let hidden = frameState(project(cursor: CursorSettings(isVisible: false, scale: 3)), outputTime: 1.3)
        XCTAssertEqual(a.sourceTime, b.sourceTime)
        XCTAssertEqual(a.cursor?.x, b.cursor?.x)
        XCTAssertEqual(a.cursor?.y, b.cursor?.y)
        XCTAssertEqual(b.cursor?.scale, 3)
        XCTAssertNil(hidden.cursor)
        XCTAssertEqual(hidden.sourceTime, a.sourceTime)
    }

    func testScaleIsKeptInRangeAndNoSamplesMeansNoPointer() {
        XCTAssertEqual(frameState(project(cursor: CursorSettings(scale: 100)), outputTime: 1).cursor?.scale, 8)
        XCTAssertEqual(frameState(project(cursor: CursorSettings(scale: 0)), outputTime: 1).cursor?.scale, 0.25)
        XCTAssertNil(frameState(project(samples: []), outputTime: 1).cursor)
    }

    func testBuilderMovesReadingsOntoTheVideoTimeline() {
        var b = PointerTrackBuilder()
        for (t, x) in [(4.0, 1.0), (4.5, 2), (5.0, 3), (5.5, 4), (6.0, 5), (6.5, 6), (7.0, 7)] { b.add(time: t, x: x, y: 0) }
        let s = b.samples(firstFrameTime: 5.0, lastTime: 6.2)
        XCTAssertEqual(s.map(\.t), [0, 0.5, 1.0, 1.5], "starts at the reading at the first frame and ends at the first one past the last frame")
        XCTAssertEqual(s.map(\.x), [3, 4, 5, 6])
    }

    func testBuilderKeepsTheReadingJustBeforeTheFirstFrameAtItsNegativeTime() {
        var b = PointerTrackBuilder()
        b.add(time: 1.0, x: 0, y: 0); b.add(time: 1.9, x: 90, y: 0); b.add(time: 2.1, x: 110, y: 0)
        let s = b.samples(firstFrameTime: 2.0, lastTime: 3.0)
        XCTAssertEqual(s.map(\.t).map { ($0 * 10).rounded() / 10 }, [-0.1, 0.1])
        XCTAssertEqual(PointerTrack.position(s, at: 0)?.x ?? 0, 100, accuracy: 1e-9, "so the video's first frame sees the pointer where it was")
    }

    func testBuilderCollapsesAStillPointerToItsFirstAndLastReading() {
        var b = PointerTrackBuilder()
        b.add(time: 0, x: 0, y: 0)
        for i in 1...100 { b.add(time: Double(i), x: 50, y: 50) }
        b.add(time: 101, x: 60, y: 50)
        let s = b.samples(firstFrameTime: 0, lastTime: 200)
        XCTAssertEqual(s, [PointerSample(t: 0, x: 0, y: 0), PointerSample(t: 1, x: 50, y: 50), PointerSample(t: 100, x: 50, y: 50), PointerSample(t: 101, x: 60, y: 50)])
        XCTAssertEqual(PointerTrack.position(s, at: 50)?.x, 50, "the pointer sits still for the whole wait")
    }

    func testBuilderWithNothingGivesNothing() {
        XCTAssertEqual(PointerTrackBuilder().samples(firstFrameTime: 0, lastTime: 1), [])
    }
}
