import XCTest
@testable import CornermarkCore

final class ZoomFollowTests: XCTestCase {
    /// A square area, so a pointer in points over 1000 is a fraction of the picture.
    private func project(_ pointer: [PointerSample], _ zooms: [Zoom], duration: Double = 10, clips: [Clip] = []) -> RecordingProject {
        var p = RecordingProject(source: .init(pointWidth: 1000, pointHeight: 1000, duration: duration), events: .init(pointer: pointer),
                                 edits: .init(zooms: zooms))
        if !clips.isEmpty { p.edits.clips = clips }
        return p
    }

    /// Samples at 120 a second of `position` over `from`...`to`.
    private func track(_ from: Double = 0, _ to: Double = 10, _ position: (Double) -> (Double, Double)) -> [PointerSample] {
        stride(from: from, through: to, by: 1.0 / 120).map { t in let p = position(t); return PointerSample(t: t, x: p.0, y: p.1) }
    }

    private func crop(_ p: RecordingProject, _ t: Double) -> ZoomRect { frameState(p, outputTime: t).crop }
    private func center(_ r: ZoomRect) -> (x: Double, y: Double) { (r.x + r.width / 2, r.y + r.height / 2) }

    /// The biggest change of the camera's velocity from one sample to the next, against the fastest it went. A jump in speed shows
    /// as a change close to the speed itself; a smooth camera changes by its acceleration times the sample spacing.
    private func speedJump(_ p: RecordingProject, _ a: Double, _ b: Double, h: Double = 1.0 / 600) -> (jump: Double, peak: Double) {
        let n = Int(((b - a) / h).rounded())
        let c = (0...n).map { center(crop(p, a + Double($0) * h)) }
        let v = zip(c, c.dropFirst()).map { (($1.x - $0.x) / h, ($1.y - $0.y) / h) }
        let jump = zip(v, v.dropFirst()).map { hypot($1.0 - $0.0, $1.1 - $0.1) }.max() ?? 0
        return (jump, v.map { hypot($0.0, $0.1) }.max() ?? 0)
    }

    private func smoothstep(_ u: Double) -> Double { let x = min(max(u, 0), 1); return x * x * (3 - 2 * x) }

    /// Still at the centre until 2 s, then across to (900, 700) over half a second, then still.
    private var leaves: [PointerSample] {
        track { t in let e = self.smoothstep((t - 2) / 0.5); return (500 + 400 * e, 500 + 200 * e) }
    }

    func testThePointerInsideTheMiddleOfTheViewLeavesTheCameraStill() {
        // At 200% the view is half the picture, so the pointer may travel 0.125 of the picture from where the camera aims.
        let wiggle = track { t in t < 1.5 ? (500, 500) : (500 + 110 * sin(7 * (t - 1.5)), 500 + 100 * sin(5 * (t - 1.5))) }
        let p = project(wiggle, [Zoom(start: 1, end: 6, scale: 2)])
        let held = crop(p, 1 + ZoomCurve.duration)
        XCTAssertEqual(center(held).x, 0.5, accuracy: 1e-12)
        XCTAssertEqual(center(held).y, 0.5, accuracy: 1e-12)
        for k in 0...400 {
            let t = 1 + ZoomCurve.duration + Double(k) / 400 * (5 - 2 * ZoomCurve.duration)
            let r = crop(p, t)
            XCTAssertEqual(r.x, held.x, accuracy: 1e-12, "the camera holds at \(t) s while the pointer moves inside the middle of the view")
            XCTAssertEqual(r.y, held.y, accuracy: 1e-12)
        }
    }

    func testTheCameraStartsOnceThePointerLeavesTheMiddleAndItsSpeedNeverJumps() {
        let p = project(leaves, [Zoom(start: 1, end: 7, scale: 2)])
        // The pointer reaches 0.625, the middle's edge, a third of the way through its move.
        let still = crop(p, 2.1), leaving = 2 + 0.5 * 0.4
        XCTAssertEqual(crop(p, 2.0), still)
        XCTAssertEqual(crop(p, leaving - 0.02), still, "the camera holds until the pointer reaches the middle's edge")
        XCTAssertGreaterThan(center(crop(p, leaving + 0.1)).x, center(still).x + 1e-4, "and drifts once it pushes past")
        let (jump, peak) = speedJump(p, 0.9, 7.1)
        XCTAssertGreaterThan(peak, 0.1)
        XCTAssertLessThan(jump / peak, 0.03, "the camera's speed changes smoothly through the move in, the drift and the move out")
        let rest = center(crop(p, 4.5))
        XCTAssertEqual(rest.x, 0.75, accuracy: 1e-6, "it settles where the view meets the picture's edge, not past it")
        XCTAssertEqual(rest.y, 0.7 - 0.125, accuracy: 1e-6, "it stops a quarter of the view short of the pointer")
    }

    func testTheDriftSettlesInAboutTheLengthOfAZoomMove() {
        let step = track { t in t < 2 ? (500, 500) : (800, 500) }
        let p = project(step, [Zoom(start: 1, end: 6, scale: 2)])
        let from = 0.5, to = 0.8 - 0.125
        let reached = stride(from: 2.0, to: 4, by: 1.0 / 1000).first { center(crop(p, $0)).x >= from + 0.95 * (to - from) } ?? 0
        XCTAssertEqual(reached - 2, 0.68, accuracy: 0.03, "95% of a sudden change in about 0.68 s")
        XCTAssertLessThanOrEqual(stride(from: 2.0, to: 6, by: 1.0 / 240).map { center(crop(p, $0)).x }.max() ?? 1, to + 1e-9, "and it never overshoots")
    }

    func testANewTargetDuringADriftBendsTheMoveWithoutAJolt() {
        // Out to the right, then back to the left while the camera is still on its way.
        let turn = track { t in
            if t < 2 { return (500, 500) }
            if t < 2.3 { return (500 + 300 * self.smoothstep((t - 2) / 0.3), 500) }
            return (800 - 550 * self.smoothstep((t - 2.3) / 0.5), 500)
        }
        let p = project(turn, [Zoom(start: 1, end: 6, scale: 2)])
        let xs = stride(from: 2.0, to: 4, by: 1.0 / 240).map { center(crop(p, $0)).x }
        XCTAssertGreaterThan(xs.max() ?? 0, 0.55, "it was heading right")
        XCTAssertLessThan(xs.last ?? 1, 0.45, "and turned to follow the pointer left")
        let (jump, peak) = speedJump(p, 1.9, 4)
        XCTAssertLessThan(jump / peak, 0.03, "the turn bends the move: no jump in speed")
    }

    func testTheViewNeverShowsPastTheRecordingsEdge() {
        var seed: UInt64 = 7
        func random() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double(seed >> 11) / Double(1 << 53)
        }
        var at = (500.0, 500.0)
        let wander = stride(from: 0.0, through: 12, by: 1.0 / 60).map { t -> PointerSample in
            at = (min(max(at.0 + (random() - 0.5) * 120, -300), 1300), min(max(at.1 + (random() - 0.5) * 120, -300), 1300))
            return PointerSample(t: t, x: at.0, y: at.1)
        }
        let zooms = [Zoom(start: 0.5, end: 2.5, scale: 4), Zoom(start: 3, end: 5, scale: 1.5), Zoom(start: 5.2, end: 7, scale: 3),
                     Zoom(start: 7.4, end: 9, scale: 2, mode: .manual, center: ZoomPoint(x: 0.95, y: 0.05)), Zoom(start: 9.5, end: 11.5, scale: 4)]
        let p = project(wander, zooms, duration: 12)
        for k in 0...1200 {
            let r = crop(p, Double(k) / 100)
            XCTAssertTrue(r.x >= -1e-12 && r.y >= -1e-12 && r.x + r.width <= 1 + 1e-12 && r.y + r.height <= 1 + 1e-12, "in bounds at \(Double(k) / 100) s: \(r)")
        }
        let (jump, peak) = speedJump(p, 0.4, 11.6, h: 1.0 / 480)
        XCTAssertLessThan(jump / peak, 0.06, "handovers between levels and to a zoom aimed by hand keep the speed smooth too")
    }

    func testTheCameraIsTheSameWhicheverFramesWereAskedForBefore() {
        let p = project(leaves, [Zoom(start: 1, end: 3, scale: 2), Zoom(start: 3.5, end: 7, scale: 3)])
        let shared = (0...84).map { Double($0) / 12 }
        let first = shared.map { crop(p, $0) }
        _ = stride(from: 7.0, through: 0, by: -1.0 / 24).map { crop(p, $0) }
        _ = stride(from: 0.0, through: 7, by: 1.0 / 60).map { crop(p, $0) }
        XCTAssertEqual(shared.map { crop(p, $0) }, first, "24 fps, 60 fps or backwards: the same moment gives the same picture")
        let fresh = FollowPath(zooms: p.edits.zooms) { t in
            let at = PointerTrack.position(p.events.pointer, at: t) ?? (0, 0)
            return (at.x / 1000, at.y / 1000)
        }
        let built = shared.map { ZoomCamera.rect(p.edits.zooms, at: $0, follow: fresh) }
        XCTAssertEqual(built, first, "a path built again gives the same answers")
    }

    func testAManualZoomKeepsItsStoredCenter() {
        let zoom = Zoom(start: 1, end: 6, scale: 2, mode: .manual, center: ZoomPoint(x: 0.3, y: 0.6))
        let p = project(leaves, [zoom])
        for t in stride(from: 0.0, through: 7, by: 0.1) { XCTAssertEqual(crop(p, t), ZoomCamera.rect([zoom], at: t)) }
    }

    func testWithoutAPointerTheCameraHoldsTheStoredCenter() {
        let zoom = Zoom(start: 1, end: 6, scale: 2, center: ZoomPoint(x: 0.3, y: 0.6))
        let p = project([], [zoom])
        for t in stride(from: 0.0, through: 7, by: 0.1) { XCTAssertEqual(crop(p, t), ZoomCamera.rect([zoom], at: t)) }
    }

    func testThePointerIsReadThroughTheClips() {
        let zoom = Zoom(start: 0.5, end: 5, scale: 2)
        let trimmed = project(leaves, [zoom], clips: [Clip(start: 1, end: 10)])
        let shifted = project(leaves.map { PointerSample(t: $0.t - 1, x: $0.x, y: $0.y) }.filter { $0.t >= 0 }, [zoom], duration: 9)
        for t in stride(from: 0.0, through: 5.5, by: 0.05) {
            let a = center(crop(trimmed, t)), b = center(crop(shifted, t))
            XCTAssertEqual(a.x, b.x, accuracy: 1e-9, "zooms are on output time, the pointer on source time, at \(t) s")
            XCTAssertEqual(a.y, b.y, accuracy: 1e-9)
        }
    }

    func testAJumpAtACutBetweenClipsIsFollowedWithoutAJolt() {
        let jumps = track { t in t < 3 ? (400, 500) : (700, 500) }
        let p = project(jumps, [Zoom(start: 1, end: 5, scale: 2)], clips: [Clip(start: 0, end: 2), Clip(start: 4, end: 9)])
        XCTAssertGreaterThan(center(crop(p, 4)).x, center(crop(p, 1.9)).x + 0.1, "the camera catches up with the pointer after the cut")
        let coarse = speedJump(p, 0.9, 5.1), fine = speedJump(p, 0.9, 5.1, h: 1.0 / 1200)
        XCTAssertLessThan(coarse.jump / coarse.peak, 0.05)
        XCTAssertLessThan(fine.jump, 0.6 * coarse.jump, "halving the spacing halves the change, so the speed is continuous through the cut")
    }

    func testSplittingAFollowingZoomChangesNothingOnScreen() throws {
        // Both parts are longer than two moves, so neither shortens its move in or out.
        let zoom = Zoom(start: 1, end: 6, scale: 2)
        let whole = project(leaves, [zoom])
        let split = try XCTUnwrap(ZoomLane([zoom], duration: 10).splitting(zoom.id, at: 3.37))
        let parts = project(leaves, split.lane.zooms)
        for t in stride(from: 0.0, through: 7, by: 1.0 / 120) {
            let a = crop(whole, t), b = crop(parts, t)
            XCTAssertEqual(a.x, b.x, accuracy: 1e-6, "at \(t) s")
            XCTAssertEqual(a.y, b.y, accuracy: 1e-6)
            XCTAssertEqual(a.width, b.width, accuracy: 1e-12)
        }
    }

    func testTheMoveInAimsWhereThePointerIsAndEndsWhole() {
        let p = project(track { _ in (850, 150) }, [Zoom(start: 1, end: 4, scale: 2)])
        XCTAssertEqual(crop(p, 0.99), .full)
        XCTAssertEqual(crop(p, 4), .full)
        let held = crop(p, 2.5)
        XCTAssertEqual(held.x, 0.5, accuracy: 1e-12, "a pointer near the corner puts the view against the corner")
        XCTAssertEqual(held.y, 0, accuracy: 1e-12)
    }
}
