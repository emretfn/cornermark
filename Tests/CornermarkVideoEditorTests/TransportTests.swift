import XCTest
@testable import CornermarkVideoEditor

final class TransportTests: XCTestCase {
    func testStartsPausedAtZero() {
        let t = Transport(duration: 2)
        XCTAssertFalse(t.isPlaying)
        XCTAssertEqual(t.time(at: 100), 0)
    }

    func testPlayingAdvancesWithTheClockAndStopsAtTheEnd() {
        var t = Transport(duration: 2)
        t.play(now: 10)
        XCTAssertEqual(t.time(at: 10.5), 0.5, accuracy: 1e-9)
        XCTAssertEqual(t.time(at: 13), 2)
        XCTAssertTrue(t.settle(now: 13))
        XCTAssertEqual(t.state, .paused(at: 2))
        XCTAssertFalse(t.settle(now: 14))
    }

    func testPauseKeepsThePlayhead() {
        var t = Transport(duration: 2)
        t.play(now: 0)
        t.pause(now: 0.75)
        XCTAssertEqual(t.time(at: 5), 0.75, accuracy: 1e-9)
    }

    func testToggleAtTheEndPlaysFromTheStart() {
        var t = Transport(duration: 2)
        t.seek(to: 2, now: 0)
        t.toggle(now: 1)
        XCTAssertTrue(t.isPlaying)
        XCTAssertEqual(t.time(at: 1.25), 0.25, accuracy: 1e-9)
    }

    func testSeekKeepsPlayingAndClamps() {
        var t = Transport(duration: 2)
        t.play(now: 0)
        t.seek(to: 1.5, now: 1)
        XCTAssertTrue(t.isPlaying)
        XCTAssertEqual(t.time(at: 1.25), 1.75, accuracy: 1e-9)
        t.seek(to: -3, now: 2)
        XCTAssertEqual(t.time(at: 2), 0)
        t.pause(now: 2)
        t.seek(to: 9, now: 2)
        XCTAssertEqual(t.state, .paused(at: 2))
    }

    func testAnEmptyRecordingNeverPlays() {
        var t = Transport(duration: 0)
        t.play(now: 0)
        XCTAssertFalse(t.isPlaying)
    }

    func testTimecode() {
        XCTAssertEqual(Timecode.text(0), "0:00.00")
        XCTAssertEqual(Timecode.text(1.259), "0:01.25")
        XCTAssertEqual(Timecode.text(61.5), "1:01.50")
        XCTAssertEqual(Timecode.label(5, step: 5), "0:05")
        XCTAssertEqual(Timecode.label(0.25, step: 0.25), "0:00.25")
    }

    func testScaleMapsTimeAndBack() {
        let s = TimelineScale(duration: 4, start: 36, end: 436)
        XCTAssertEqual(s.x(0), 36)
        XCTAssertEqual(s.x(4), 436)
        XCTAssertEqual(s.x(9), 436)
        XCTAssertEqual(s.time(236), 2, accuracy: 1e-9)
        XCTAssertEqual(s.time(0), 0)
        XCTAssertEqual(s.time(1000), 4)
    }

    func testRulerKeepsLabelsApart() {
        let s = TimelineScale(duration: 2, start: 0, end: 1000)
        XCTAssertEqual(s.majorStep(minSpacing: 72), 0.25)
        XCTAssertEqual(s.ticks(minSpacing: 72), [0, 0.25, 0.5, 0.75, 1, 1.25, 1.5, 1.75, 2])
        let long = TimelineScale(duration: 600, start: 0, end: 1000)
        XCTAssertEqual(long.majorStep(minSpacing: 72), 60)
    }

    func testAnEditChangesTheLengthAndMovesThePlayhead() {
        var t = Transport(duration: 4)
        t.play(now: 0)
        t.setDuration(2, playheadAt: 1.5, now: 1)
        XCTAssertTrue(t.isPlaying, "playing goes on from the new place")
        XCTAssertEqual(t.time(at: 1.25), 1.75, accuracy: 1e-9)
        XCTAssertEqual(t.time(at: 9), 2, "and stops at the new end")
        t.setDuration(1, playheadAt: 3, now: 2)
        XCTAssertEqual(t.state, .paused(at: 1), "a playhead past the new end waits at it")
    }
}
