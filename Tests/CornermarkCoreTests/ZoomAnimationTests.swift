import XCTest
@testable import CornermarkCore

final class ZoomAnimationTests: XCTestCase {
    private func project(_ zooms: [Zoom], pointer: [PointerSample] = [], animation: ZoomAnimation = ZoomAnimation()) -> RecordingProject {
        RecordingProject(source: .init(pointWidth: 1000, pointHeight: 1000, duration: 10), events: .init(pointer: pointer),
                         edits: .init(zooms: zooms, zoomAnimation: animation))
    }

    private func crop(_ p: RecordingProject, _ t: Double) -> ZoomRect { frameState(p, outputTime: t).crop }
    private func center(_ r: ZoomRect) -> (x: Double, y: Double) { (r.x + r.width / 2, r.y + r.height / 2) }
    private func track(_ position: (Double) -> (Double, Double)) -> [PointerSample] {
        stride(from: 0.0, through: 10, by: 1.0 / 120).map { t in let p = position(t); return PointerSample(t: t, x: p.0, y: p.1) }
    }

    func testDefaultsAreTheCameraOfEarlierVersions() {
        let d = ZoomAnimation()
        XCTAssertEqual(d.duration, 0.78)
        XCTAssertEqual(d.deadZone, 0.5)
        XCTAssertEqual(d.driftRate, 7)
        XCTAssertEqual(d.settleTime, 0.68, accuracy: 0.005, "the follow camera settles 95% of a move in 0.68 s")
    }

    func testAProjectWrittenBeforeAnimationSettingsReadsTheDefaults() throws {
        let json = #"{"version":1,"source":{"pointWidth":100,"pointHeight":100,"duration":5},"edits":{"zooms":[{"start":1,"end":3}]}}"#
        let p = try JSONDecoder().decode(RecordingProject.self, from: Data(json.utf8))
        XCTAssertEqual(p.edits.zoomAnimation, ZoomAnimation())
        XCTAssertEqual(p.edits.zooms.count, 1)
    }

    func testStoredSettingsRoundTripAndOutOfRangeValuesAreHeldInRange() throws {
        var p = project([Zoom(start: 1, end: 3)])
        p.edits.zoomAnimation = ZoomAnimation(duration: 1.2, deadZone: 0.3, driftRate: 12)
        let back = try JSONDecoder().decode(RecordingProject.self, from: JSONEncoder().encode(p))
        XCTAssertEqual(back.edits.zoomAnimation, p.edits.zoomAnimation)
        let wild = #"{"edits":{"zoomAnimation":{"duration":40,"deadZone":-1,"driftRate":"fast"}}}"#
        let odd = try JSONDecoder().decode(RecordingProject.self, from: Data(wild.utf8)).edits.zoomAnimation
        XCTAssertEqual(odd.duration, ZoomAnimation.durationRange.upperBound)
        XCTAssertEqual(odd.deadZone, 0)
        XCTAssertEqual(odd.driftRate, 7, "a value that is not a number keeps its default")
    }

    func testTheMoveDurationSetsHowLongTheCameraTakesToArrive() {
        let zoom = Zoom(start: 1, end: 6, scale: 2, mode: .manual)
        let slow = project([zoom], animation: ZoomAnimation(duration: 1.2))
        XCTAssertLessThan(crop(slow, 1 + 0.78).scale, 1.99, "at the default's end the longer move is still on its way")
        XCTAssertEqual(crop(slow, 1 + 0.6).scale, 2.0.squareRoot(), accuracy: 1e-9, "halfway in time is halfway in ratio")
        XCTAssertEqual(crop(slow, 1 + 1.2).scale, 2, accuracy: 1e-12)
        XCTAssertEqual(crop(slow, 6 - 0.6).scale, 2.0.squareRoot(), accuracy: 1e-9, "the move out mirrors it")
        XCTAssertEqual(crop(project([zoom]), 1 + 0.78).scale, 2, accuracy: 1e-12)
    }

    func testTwoZoomsHandOverWhenTheyAreCloserThanTwoMoves() {
        let a = Zoom(start: 0, end: 2, scale: 2, mode: .manual), b = Zoom(start: 4, end: 7, scale: 3, mode: .manual)
        XCTAssertEqual(crop(project([a, b]), 3).width, 1, "2 s apart is more than two default moves, so the camera returns to 100%")
        XCTAssertEqual(crop(project([a, b], animation: ZoomAnimation(duration: 1.2)), 3), ZoomCamera.target(a),
                       "with 1.2 s moves 2 s is less than two moves, so it waits on the first zoom")
    }

    func testTheHoldAreaSetsHowFarThePointerMovesBeforeTheCameraFollows() {
        // At 200% the view is half the picture. The pointer goes 0.15 of the picture right of centre, which is 30% of the view.
        let nudge = track { t in t < 2 ? (500, 500) : (650, 500) }
        let zoom = Zoom(start: 1, end: 6, scale: 2)
        let wide = project([zoom], pointer: nudge, animation: ZoomAnimation(deadZone: 0.8))
        let tight = project([zoom], pointer: nudge, animation: ZoomAnimation(deadZone: 0.2))
        XCTAssertEqual(center(crop(wide, 4)).x, 0.5, accuracy: 1e-9, "inside a hold area of 80% the camera stays")
        XCTAssertEqual(center(crop(tight, 4)).x, 0.65 - 0.2 / 2 * 0.5, accuracy: 1e-3,
                       "with 20% it follows until the pointer sits on the hold area's edge")
    }

    func testTheCatchUpRateSetsHowFastTheCameraSettles() {
        let jump = track { t in t < 2 ? (500, 500) : (900, 500) }
        let zoom = Zoom(start: 1, end: 9, scale: 2)
        func settled(_ rate: Double) -> Double {
            let p = project([zoom], pointer: jump, animation: ZoomAnimation(driftRate: rate))
            let goal = center(crop(p, 6)).x, from = 0.5
            let t = stride(from: 2.0, through: 6, by: 1.0 / 1000).first { abs(center(crop(p, $0)).x - goal) <= 0.05 * abs(goal - from) } ?? 99
            return t - 2
        }
        XCTAssertEqual(settled(7), ZoomAnimation(driftRate: 7).settleTime, accuracy: 0.01)
        XCTAssertEqual(settled(14), ZoomAnimation(driftRate: 14).settleTime, accuracy: 0.01)
        XCTAssertEqual(ZoomAnimation.driftRate(settling: ZoomAnimation(driftRate: 9).settleTime), 9, accuracy: 1e-9)
    }

    func testChangingTheSettingsChangesTheCameraOfTheSameProject() {
        let jump = track { t in t < 2 ? (500, 500) : (900, 500) }
        var p = project([Zoom(start: 1, end: 8, scale: 2)], pointer: jump)
        let before = crop(p, 2.3)
        p.edits.zoomAnimation.driftRate = 14
        XCTAssertNotEqual(crop(p, 2.3), before, "the shared path is built again for the new rate")
        p.edits.zoomAnimation.driftRate = 7
        XCTAssertEqual(crop(p, 2.3), before)
    }

    func testAManualZoomAimsAtTheCenterPickedForIt() {
        let zoom = Zoom(start: 1, end: 6, scale: 4, mode: .manual, center: ZoomPoint(x: 0.25, y: 0.7))
        let r = crop(project([zoom], pointer: track { _ in (900, 100) }), 3)
        XCTAssertEqual(center(r).x, 0.25, accuracy: 1e-12)
        XCTAssertEqual(center(r).y, 0.7, accuracy: 1e-12)
    }

    func testAReachableCenterKeepsTheViewInsideThePicture() {
        XCTAssertEqual(ZoomCamera.reachable(ZoomPoint(x: 0.95, y: -0.2), scale: 2), ZoomPoint(x: 0.75, y: 0.25))
        XCTAssertEqual(ZoomCamera.reachable(ZoomPoint(x: 0.4, y: 0.6), scale: 2), ZoomPoint(x: 0.4, y: 0.6))
        XCTAssertEqual(ZoomCamera.reachable(ZoomPoint(x: 0.9, y: 0.1), scale: 1), .middle, "at 100% the only view is the whole picture")
    }
}
