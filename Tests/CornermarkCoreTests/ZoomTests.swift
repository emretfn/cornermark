import XCTest
@testable import CornermarkCore

final class ZoomCurveTests: XCTestCase {
    private let zoom = Zoom(start: 1, end: 5, scale: 2, center: ZoomPoint(x: 0.3, y: 0.6))

    private func scale(_ t: Double, _ zooms: [Zoom]? = nil) -> Double { ZoomCamera.rect(zooms ?? [zoom], at: t).scale }

    func testTheMoveInMirrorsTheMoveOut() {
        let d = ZoomCurve.duration
        for k in 0...68 {
            let u = Double(k) / 68 * d
            XCTAssertEqual(scale(zoom.start + u), scale(zoom.end - u), accuracy: 1e-12, "in at +\(u) s equals out at -\(u) s")
        }
    }

    func testTheMoveTakesExactlyItsDurationAndIsFastestHalfway() {
        let d = ZoomCurve.duration, step = 1.0 / 600
        XCTAssertEqual(scale(zoom.start), 1)
        XCTAssertEqual(scale(zoom.start + d), 2, accuracy: 1e-12)
        XCTAssertLessThan(scale(zoom.start + d - step), 2)
        var fastest = (t: 0.0, speed: 0.0)
        var t = zoom.start
        while t < zoom.start + d {
            // The picture grows by a ratio each frame, so its speed is the change of the scale's logarithm.
            let speed = (log(scale(t + step)) - log(scale(t))) / step
            XCTAssertGreaterThanOrEqual(speed, -1e-9, "the move in never reverses")
            if speed > fastest.speed { fastest = (t + step / 2, speed) }
            t += step
        }
        XCTAssertEqual(fastest.t - zoom.start, d / 2, accuracy: step, "the speed peaks at the middle of the move")
        XCTAssertEqual((scale(zoom.start + step) - 1) / step, 0, accuracy: 0.01, "it leaves the whole picture at rest")
    }

    func testTheCameraReturnsExactlyToTheWholePicture() {
        XCTAssertEqual(ZoomCamera.rect([zoom], at: zoom.end), .full)
        XCTAssertEqual(ZoomCamera.rect([zoom], at: zoom.end + 0.01), .full)
        XCTAssertEqual(ZoomCamera.rect([zoom], at: zoom.start - 0.01), .full)
        XCTAssertEqual(ZoomCamera.rect([zoom], at: zoom.end - 1e-9).width, 1, accuracy: 1e-9)
    }

    func testItHoldsTheLevelAroundTheStoredCenter() {
        let held = ZoomCamera.rect([zoom], at: 3)
        XCTAssertEqual(held.x, 0.05, accuracy: 1e-12)
        XCTAssertEqual(held.y, 0.35, accuracy: 1e-12)
        XCTAssertEqual(held.width, 0.5)
        let corner = ZoomCamera.target(Zoom(start: 0, end: 1, scale: 4, center: ZoomPoint(x: 1, y: 0)))
        XCTAssertEqual(corner, ZoomRect(x: 0.75, y: 0, width: 0.25, height: 0.25), "a center at the edge stops the camera inside the picture")
    }

    func testEveryFrameOfAMoveStaysInsideThePicture() {
        let zooms = [Zoom(start: 0, end: 2, scale: 4, center: ZoomPoint(x: 0.95, y: 0.05)), Zoom(start: 2.5, end: 4, scale: 1.5, center: ZoomPoint(x: 0.1, y: 0.9))]
        var t = 0.0
        while t < 4.5 {
            let r = ZoomCamera.rect(zooms, at: t)
            XCTAssert(r.x >= -1e-12 && r.y >= -1e-12 && r.x + r.width <= 1 + 1e-12 && r.y + r.height <= 1 + 1e-12, "inside at \(t): \(r)")
            t += 1.0 / 120
        }
    }

    func testAZoomShorterThanTwoMovesSplitsItsLengthBetweenThem() {
        let short = Zoom(start: 0, end: 1, scale: 3)
        XCTAssertEqual(ZoomCurve.ramp(short), 0.5)
        XCTAssertEqual(scale(0.5, [short]), 3, accuracy: 1e-12)
        XCTAssertEqual(scale(0.25, [short]), scale(0.75, [short]), accuracy: 1e-12)
    }

    func testCloseZoomsHandOverWithoutLeavingTheZoom() {
        let a = Zoom(start: 0, end: 2, scale: 2, center: ZoomPoint(x: 0.25, y: 0.25))
        let b = Zoom(start: 2.5, end: 5, scale: 3, center: ZoomPoint(x: 0.75, y: 0.75))
        var lowest = Double.infinity
        var t = 1.0
        while t <= 3.5 { lowest = min(lowest, scale(t, [a, b])); t += 1.0 / 120 }
        XCTAssertEqual(lowest, 2, accuracy: 1e-9, "the camera never pulls back to the whole picture between them")
        XCTAssertEqual(ZoomCamera.rect([a, b], at: 2.2), ZoomCamera.target(a), "it waits on the first zoom across the gap")
        XCTAssertEqual(ZoomCamera.rect([a, b], at: 2.5 + ZoomCurve.duration), ZoomCamera.target(b))
        XCTAssertEqual(scale(2.5 + ZoomCurve.duration / 2, [a, b]), (2.0 * 3).squareRoot(), accuracy: 1e-12, "the handover is the same curve, halfway in ratio")

        let apart = Zoom(start: 2 + ZoomCurve.joinGap, end: 6, scale: 3)
        XCTAssertEqual(scale(2 + ZoomCurve.joinGap / 2, [a, apart]), 1, "zooms far apart each return to the whole picture")
    }

    func testFrameStateCarriesTheCamera() {
        let project = RecordingProject(source: .init(pointWidth: 100, pointHeight: 50, duration: 6), edits: .init(zooms: [zoom]))
        XCTAssertEqual(frameState(project, outputTime: 3).camera, ZoomCamera.rect([zoom], at: 3))
        XCTAssertEqual(frameState(project, outputTime: 0).camera, .full)
    }
}

final class ZoomLaneTests: XCTestCase {
    private func lane(_ zooms: [Zoom] = []) -> ZoomLane { ZoomLane(zooms, duration: 10) }

    func testAClickAddsTheDefaultLengthMovedInsideTheGap() throws {
        let added = try XCTUnwrap(lane().adding(from: 3))
        XCTAssertEqual([added.zoom.start, added.zoom.end], [3, 5])
        XCTAssertEqual(added.zoom.scale, 2)
        let late = try XCTUnwrap(lane().adding(from: 9.5))
        XCTAssertEqual([late.zoom.start, late.zoom.end], [8, 10], "a click near the end still gets the full length")
        let squeezed = try XCTUnwrap(lane([Zoom(start: 0, end: 4), Zoom(start: 5, end: 9)]).adding(from: 4.2))
        XCTAssertEqual([squeezed.zoom.start, squeezed.zoom.end], [4, 5], "a short gap gets what it has")
        XCTAssertNil(lane([Zoom(start: 0, end: 4), Zoom(start: 4.3, end: 9)]).adding(from: 4.1), "no zoom fits under the shortest length")
        XCTAssertNil(lane([Zoom(start: 0, end: 4)]).adding(from: 2), "a click on a zoom adds nothing")
    }

    func testADragAddsItsRangeStoppingAtNeighbours() throws {
        let l = lane([Zoom(start: 6, end: 8)])
        let dragged = try XCTUnwrap(l.adding(from: 4, to: 1))
        XCTAssertEqual([dragged.zoom.start, dragged.zoom.end], [1, 4])
        let long = try XCTUnwrap(l.adding(from: 2, to: 9))
        XCTAssertEqual([long.zoom.start, long.zoom.end], [2, 6])
        let tiny = try XCTUnwrap(l.adding(from: 2, to: 2.1))
        XCTAssertEqual(tiny.zoom.duration, Zoom.minimumDuration, accuracy: 1e-12)
    }

    func testMoveAndResizeStopAtNeighboursAndTheEnds() {
        let a = Zoom(start: 1, end: 3), b = Zoom(start: 5, end: 7)
        let l = lane([a, b])
        XCTAssertEqual(l.moving(b.id, to: 2).zoom(b.id).map { [$0.start, $0.end] }, [3, 5])
        XCTAssertEqual(l.moving(b.id, to: 9).zoom(b.id).map { [$0.start, $0.end] }, [8, 10])
        XCTAssertEqual(l.moving(a.id, to: -4).zoom(a.id)?.start, 0)
        XCTAssertEqual(l.resizing(a.id, .end, to: 6).zoom(a.id)?.end, 5)
        XCTAssertEqual(l.resizing(a.id, .end, to: 0).zoom(a.id)?.end, 1 + Zoom.minimumDuration)
        XCTAssertEqual(l.resizing(b.id, .start, to: 0).zoom(b.id)?.start, 3)
        XCTAssertEqual(l.resizing(b.id, .end, to: 20).zoom(b.id)?.end, 10)
    }

    func testSplitDuplicateAndRemove() throws {
        let a = Zoom(start: 1, end: 4, scale: 3, mode: .manual), b = Zoom(start: 6, end: 7)
        let l = lane([a, b])
        let split = try XCTUnwrap(l.splitting(a.id, at: 2))
        XCTAssertEqual(split.lane.zooms.map { [$0.start, $0.end] }, [[1, 2], [2, 4], [6, 7]])
        XCTAssertEqual(split.lane.zooms[1].scale, 3)
        XCTAssertEqual(split.lane.zooms[1].mode, .manual)
        XCTAssertNotEqual(split.second.id, a.id)
        XCTAssertNil(l.splitting(a.id, at: 1.2), "a part shorter than the shortest zoom is refused")
        let copy = try XCTUnwrap(l.duplicating(a.id))
        XCTAssertEqual([copy.copy.start, copy.copy.end], [7, 10], "the copy goes to the first gap that holds it")
        XCTAssertNil(lane([Zoom(start: 0, end: 6)]).duplicating(lane([Zoom(start: 0, end: 6)]).zooms[0].id))
        XCTAssertEqual(l.removing(a.id).zooms, [b])
        XCTAssertEqual(l.settingScale(9).zooms.map(\.scale), [4, 4])
    }

    func testAShorterVideoCutsItsZoomsAtTheEnd() {
        let l = ZoomLane([Zoom(start: 1, end: 4), Zoom(start: 5, end: 9)], duration: 7)
        XCTAssertEqual(l.zooms.map { [$0.start, $0.end] }, [[1, 4], [5, 7]])
        XCTAssertEqual(ZoomLane([Zoom(start: 6.8, end: 8)], duration: 7).zooms, [], "less than the shortest zoom is left out")
    }

    func testDecodingKeepsGoodZoomsAndDropsBrokenOnes() throws {
        let p = try JSONDecoder().decode(RecordingProject.self, from: Data("""
        {"edits": {"zooms": [{"start": 4, "end": 6, "scale": 9, "mode": "later"}, {"start": 2, "end": 1}, {"start": 0, "end": 1, "center": {"x": 0.2, "y": 0.4}}]}}
        """.utf8))
        XCTAssertEqual(p.edits.zooms.map(\.start), [0, 4])
        XCTAssertEqual(p.edits.zooms[1].scale, 4)
        XCTAssertEqual(p.edits.zooms[1].mode, .followCursor)
        XCTAssertEqual(p.edits.zooms[0].center, ZoomPoint(x: 0.2, y: 0.4))
        let again = try JSONDecoder().decode(RecordingProject.self, from: JSONEncoder().encode(p))
        XCTAssertEqual(again, p)
    }
}
