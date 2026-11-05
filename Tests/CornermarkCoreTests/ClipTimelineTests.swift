import XCTest
@testable import CornermarkCore

final class ClipTimelineTests: XCTestCase {
    private let source = RecordingProject.Source(pixelWidth: 640, pixelHeight: 360, pointWidth: 320, pointHeight: 180, fps: 60, duration: 4)

    private func timeline(_ clips: [(Double, Double)]) -> ClipTimeline {
        ClipTimeline(clips: clips.map { Clip(start: $0.0, end: $0.1) }, source: source)
    }

    private func ranges(_ t: ClipTimeline) -> [[Double]] { t.clips.map { [$0.start, $0.end] } }

    func testAProjectWrittenBeforeClipsKeepsTheWholeRecording() throws {
        let old = #"{"source": {"duration": 2.5, "fps": 30}, "edits": {"cursor": {"scale": 2}}}"#
        let p = try JSONDecoder().decode(RecordingProject.self, from: Data(old.utf8))
        XCTAssertEqual(p.edits.clips, [Clip(start: 0, end: 2.5)])
        XCTAssertEqual(p.outputDuration, 2.5)
        XCTAssertEqual(p.edits.cursor.scale, 2, "the rest of the edits still decode")
    }

    func testStoredClipsRoundTripAndDamagedOnesAreDropped() throws {
        var p = RecordingProject(source: source)
        p.edits.clips = [Clip(start: 0, end: 1), Clip(start: 2, end: 3.5)]
        let data = try JSONEncoder().encode(p)
        XCTAssertEqual(try JSONDecoder().decode(RecordingProject.self, from: data), p)
        let damaged = #"{"source": {"duration": 4}, "edits": {"clips": [{"start": 1, "end": 2}, {"start": "x"}, {"start": 3, "end": 9}]}}"#
        let q = try JSONDecoder().decode(RecordingProject.self, from: Data(damaged.utf8))
        XCTAssertEqual(q.edits.clips, [Clip(start: 1, end: 2), Clip(start: 3, end: 4)], "a broken entry costs that entry; one past the end is cut at the end")
    }

    func testClipsArePutInOrderApartAndInsideTheSource() {
        XCTAssertEqual(ranges(timeline([(2, 3), (-1, 1), (0.5, 2.5), (5, 6)])), [[0, 1], [1, 2.5], [2.5, 3]],
                       "sorted, clamped to the source, an overlap starts where the clip before ends, a piece outside is dropped")
        XCTAssertEqual(ranges(timeline([(0, 2), (1, 1.5)])), [[0, 2]], "a clip inside the one before is dropped")
        XCTAssertEqual(ranges(timeline([])), [[0, 4]])
        XCTAssertEqual(ranges(timeline([(5, 6)])), [[0, 4]], "nothing left inside the source keeps the whole recording")
        XCTAssertEqual(ClipTimeline(clips: [], source: .init()).duration, 0)
    }

    func testOutputTimeRunsOverTheClipsInOrder() {
        let t = timeline([(0, 1), (2, 3.5)])
        XCTAssertEqual(t.duration, 2.5)
        XCTAssertEqual(t.starts, [0, 1])
        XCTAssertEqual(t.cuts, [1])
        XCTAssertEqual(t.sourceTime(at: 0.5), 0.5)
        XCTAssertEqual(t.sourceTime(at: 1), 2, "a cut belongs to the clip it starts")
        XCTAssertEqual(t.sourceTime(at: 1 - 1.0 / 60), 1 - 1.0 / 60, accuracy: 1e-12)
        XCTAssertEqual(t.sourceTime(at: 2), 3)
        XCTAssertEqual(t.clipIndex(at: 0.99), 0)
        XCTAssertEqual(t.clipIndex(at: 1), 1)
        XCTAssertEqual(t.sourceTime(at: -1), 0)
    }

    func testTheEndShowsTheLastKeptFrameAndNeverTheOneAfter() {
        let t = timeline([(0, 1), (2, 3)])
        XCTAssertEqual(t.sourceTime(at: 2), 3 - 0.5 / 60, accuracy: 1e-12)
        XCTAssertEqual(t.sourceTime(at: 99), 3 - 0.5 / 60, accuracy: 1e-12)
    }

    func testASourceMomentMapsBackOrIsCutOut() {
        let t = timeline([(0, 1), (2, 3.5)])
        XCTAssertEqual(t.outputTime(ofSource: 0.25), 0.25)
        XCTAssertEqual(t.outputTime(ofSource: 2.5), 1.5)
        XCTAssertNil(t.outputTime(ofSource: 1.5), "the removed middle plays nowhere")
        XCTAssertNil(t.outputTime(ofSource: 3.9))
        for out in stride(from: 0.0, to: t.duration, by: 0.05) {
            XCTAssertEqual(t.outputTime(ofSource: t.sourceTime(at: out)) ?? -1, out, accuracy: 1e-9, "output \(out) maps there and back")
        }
    }

    func testSplitCutsAtTheNearestFrame() throws {
        let t = timeline([(0, 4)])
        let split = try XCTUnwrap(t.splitting(at: 1.004))
        XCTAssertEqual(ranges(split), [[0, 1], [1, 4]], "1.004 s is nearer frame 60 than frame 61")
        XCTAssertEqual(split.duration, 4, "splitting keeps every frame")
        let again = try XCTUnwrap(split.splitting(at: 2.5))
        XCTAssertEqual(ranges(again), [[0, 1], [1, 2.5], [2.5, 4]])
        XCTAssertEqual(again.cuts, [1, 2.5])
    }

    func testSplitRefusesAPieceShorterThanAFrame() {
        let t = timeline([(0, 1), (2, 3)])
        XCTAssertNil(t.splitting(at: 0), "at a clip's start")
        XCTAssertNil(t.splitting(at: 1), "on a cut")
        XCTAssertNil(t.splitting(at: 1 + 0.2 / 60), "within a frame of a cut")
        XCTAssertNil(t.splitting(at: 2 - 0.2 / 60), "within a frame of the end")
        XCTAssertNotNil(t.splitting(at: 1 + 1.0 / 60), "one frame in is a clip")
    }

    func testDeleteRemovesAClipButNeverTheLast() throws {
        let t = timeline([(0, 1), (1, 2), (2, 4)])
        let without = try XCTUnwrap(t.deleting(1))
        XCTAssertEqual(ranges(without), [[0, 1], [2, 4]])
        XCTAssertEqual(without.duration, 3)
        XCTAssertEqual(without.sourceTime(at: 1), 2, "after the removed middle the next clip plays")
        XCTAssertNil(timeline([(0, 4)]).deleting(0))
        XCTAssertNil(t.deleting(5))
    }

    func testTrimMovesAnEdgeOnTheFrameGridWithinItsNeighbours() {
        let t = timeline([(0, 1), (2, 3)])
        XCTAssertEqual(ranges(t.trimming(1, .start, to: 2.504)), [[0, 1], [2.5, 3]])
        XCTAssertEqual(ranges(t.trimming(1, .start, to: 1.5)), [[0, 1], [1.5, 3]], "trimming out brings back what was cut")
        XCTAssertEqual(ranges(t.trimming(1, .start, to: 0.2)), [[0, 1], [1, 3]], "but stops at the clip before")
        XCTAssertEqual(ranges(t.trimming(0, .end, to: 9)), [[0, 2], [2, 3]], "an end stops at the next clip")
        XCTAssertEqual(ranges(t.trimming(1, .end, to: 9)), [[0, 1], [2, 4]], "the last clip's end stops at the source's end")
        let short = t.trimming(1, .start, to: 3.5)
        XCTAssertEqual(short.clips[1].duration, 1.0 / 60, accuracy: 1e-12, "a clip keeps at least a frame")
        XCTAssertEqual(ranges(t.trimming(0, .start, to: -3)), [[0, 1], [2, 3]])
        let odd = ClipTimeline(clips: [], source: .init(fps: 60, duration: 2.004))
        XCTAssertEqual(odd.trimming(0, .end, to: 2.0).clips[0].end, 2.0, "an end off the grid can stop on the last frame before it")
        XCTAssertEqual(odd.trimming(0, .end, to: 2.009).clips[0].end, 2.004, "and lands on the source's end past that")
    }

    func testFrameStateMapsThePointerThroughTheClips() {
        var p = RecordingProject(source: source, events: .init(pointer: [PointerSample(t: 0, x: 0, y: 0), PointerSample(t: 4, x: 400, y: 40)]))
        p.edits.clips = [Clip(start: 0, end: 1), Clip(start: 3, end: 4)]
        let state = frameState(p, outputTime: 1.5)
        XCTAssertEqual(state.sourceTime, 3.5)
        XCTAssertEqual(state.cursor?.x ?? 0, 350, accuracy: 1e-9, "the pointer is where it was at the source moment shown")
        XCTAssertEqual(frameState(p, outputTime: 0.5).cursor?.x ?? 0, 50, accuracy: 1e-9)
    }

    func testExportLengthFollowsTheClips() {
        var p = RecordingProject(source: source)
        p.edits.clips = [Clip(start: 0, end: 1), Clip(start: 2.5, end: 3)]
        let plan = ExportPlan(project: p, settings: ExportSettings())
        XCTAssertEqual(plan.frameCount, 90)
        XCTAssertEqual(plan.duration, 1.5, accuracy: 1e-9)
        XCTAssertLessThan(ExportPlan(project: p, settings: ExportSettings(), sourceBytes: 4_000_000).estimatedBytes,
                          ExportPlan(project: RecordingProject(source: source), settings: ExportSettings(), sourceBytes: 4_000_000).estimatedBytes,
                          "a shorter video is estimated smaller")
    }

    func testUndoHistoryWalksAnyValue() {
        var history = UndoHistory([Clip(start: 0, end: 4)])
        history.record([Clip(start: 0, end: 1), Clip(start: 1, end: 4)])
        history.record([Clip(start: 0, end: 1)], coalescing: "trim")
        history.record([Clip(start: 0, end: 1.5)], coalescing: "trim")
        XCTAssertEqual(history.past.count, 2, "a drag's steps fold into one")
        history.undo()
        XCTAssertEqual(history.present, [Clip(start: 0, end: 1), Clip(start: 1, end: 4)])
        history.redo()
        XCTAssertEqual(history.present, [Clip(start: 0, end: 1.5)])
    }
}
