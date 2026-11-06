import XCTest
@testable import CornermarkCore

final class ClickEffectsTests: XCTestCase {
    private let still = [PointerSample(t: 0, x: 200, y: 100), PointerSample(t: 10, x: 200, y: 100)]
    private let arriving = (0...120).map { PointerSample(t: Double($0) / 120, x: 100 + 300 * Double($0) / 120, y: 100) } + [PointerSample(t: 10, x: 400, y: 100)]

    private func project(_ pointer: [PointerSample], clicks: [ClickEvent], cursor: CursorSettings = CursorSettings(),
                         highlight: ClickHighlight = ClickHighlight(isVisible: true)) -> RecordingProject {
        RecordingProject(source: .init(pixelWidth: 1600, pixelHeight: 900, pointWidth: 800, pointHeight: 450, fps: 60, duration: 10),
                         events: .init(pointer: pointer, clicks: clicks), edits: .init(cursor: cursor, clicks: highlight))
    }

    private func scale(_ p: RecordingProject, _ t: Double) -> Double { frameState(p, outputTime: t).cursor?.scale ?? .nan }

    func testThePressShrinksThePointerAndLetsItGo() {
        let p = project(still, clicks: [ClickEvent(t: 2, x: 200, y: 100)], cursor: CursorSettings(scale: 2, pressesOnClick: true))
        XCTAssertEqual(scale(p, 1.99), 2, "before the click the pointer has its own size")
        XCTAssertEqual(scale(p, 2 + CursorTrack.pressDown), 2 * CursorTrack.pressDepth, accuracy: 1e-9, "at the bottom of the press")
        XCTAssertLessThan(scale(p, 2.02), 2, "the press starts at once")
        XCTAssertEqual(scale(p, 2 + CursorTrack.pressLength), 2, accuracy: 1e-9, "and is over in a quarter of a second")
        var last = 0.0
        for i in 0...20 {
            let s = scale(p, 2 + CursorTrack.pressDown + CursorTrack.pressRelease * Double(i) / 20)
            XCTAssertGreaterThanOrEqual(s, last - 1e-12, "the release only grows")
            last = s
        }
    }

    func testThePressIsOffByDefaultAndOverlappingClicksTakeTheDeeper() {
        let clicks = [ClickEvent(t: 2, x: 200, y: 100), ClickEvent(t: 2.1, x: 200, y: 100)]
        XCTAssertEqual(scale(project(still, clicks: clicks), 2.05), 1, "a new project does not press")
        let p = project(still, clicks: clicks, cursor: CursorSettings(pressesOnClick: true))
        XCTAssertEqual(scale(p, 2.1 + CursorTrack.pressDown), CursorTrack.pressDepth, accuracy: 1e-9, "a double click presses again from its second click")
    }

    func testTheRingCentresOnTheDrawnPointer() {
        let click = ClickEvent(t: 1, x: 400, y: 100)
        let natural = project(arriving, clicks: [click])
        let ring = frameState(natural, outputTime: 1.1).input.rings.first
        XCTAssertEqual(ring?.x ?? 0, 400, accuracy: 1e-9)
        var smooth = natural
        smooth.edits.cursor.motion = .smooth
        let pointer = CursorTrack.anchor(click, in: smooth)
        XCTAssertLessThan(pointer.x, 390, "the spring trails the hand when it stops")
        XCTAssertEqual(frameState(smooth, outputTime: 1.1).input.rings.first?.x ?? 0, pointer.x, accuracy: 1e-9,
                       "under Smooth the ring is where the pointer was drawn at the click, not where the hand stopped")
        XCTAssertEqual(frameState(smooth, outputTime: 1.3).input.rings.first?.x, frameState(smooth, outputTime: 1.1).input.rings.first?.x,
                       "the ring stays where it started while the pointer settles")
        XCTAssertEqual(frameState(project([], clicks: [click]), outputTime: 1.1).input.rings.first?.x, 400, "without a track the ring is at the click point")
    }

    func testTheRingLivesForItsLifetimeWhetherOrNotThePointerShows() {
        let click = ClickEvent(t: 3, x: 200, y: 100)
        var p = project(still, clicks: [click], cursor: CursorSettings(isVisible: false))
        XCTAssertEqual(frameState(p, outputTime: 2.99).input.rings.count, 0)
        XCTAssertEqual(frameState(p, outputTime: 3).input.rings.count, 1, "a hidden pointer still shows its clicks")
        XCTAssertEqual(frameState(p, outputTime: 3 + ClickHighlight.lifetime - 0.01).input.rings.count, 1)
        XCTAssertEqual(frameState(p, outputTime: 3 + ClickHighlight.lifetime + 0.001).input.rings.count, 0)
        XCTAssertTrue((0.27...0.5).contains(ClickHighlight.lifetime), "the measured lifetime of a ring")
        p.edits.clicks.isVisible = false
        XCTAssertEqual(frameState(p, outputTime: 3.1).input.rings.count, 0, "Ripple off draws no ring")
        p.edits.clicks.isVisible = true
        p.edits.cursor = CursorSettings(hidesWhenIdle: true)
        XCTAssertNil(frameState(p, outputTime: 3.1).cursor, "the resting pointer has faded")
        XCTAssertEqual(frameState(p, outputTime: 3.1).input.rings.count, 1, "and the ring shows anyway")
    }

    func testTheRingsMatchTheRecordingOverlayForAStillPointer() {
        let clicks = (0..<30).map { ClickEvent(t: 0.5 + 0.13 * Double($0), x: 200, y: 100) }
        let p = project(still, clicks: clicks)
        for i in 0..<500 {
            let t = Double(i) / 100
            let reference = InputOverlay.state(clicks: clicks, keys: [], highlight: p.edits.clicks, keystrokes: KeystrokeDisplay(), at: t).rings
            XCTAssertEqual(p.clickRings(at: t), reference, "at \(t) s")
        }
    }

    func testThePressSettingRoundTripsAndOldFilesDecodeWithoutIt() throws {
        var p = project(still, clicks: [], cursor: CursorSettings(pressesOnClick: true))
        p.edits.clicks = ClickHighlight(isVisible: true, color: .orange, style: .filled, size: .large, animates: false)
        let back = try JSONDecoder().decode(RecordingProject.self, from: JSONEncoder().encode(p))
        XCTAssertEqual(back.edits.cursor, p.edits.cursor)
        XCTAssertEqual(back.edits.clicks, p.edits.clicks)
        let old = try JSONDecoder().decode(CursorSettings.self, from: Data(#"{"isVisible":true,"scale":1.5}"#.utf8))
        XCTAssertFalse(old.pressesOnClick)
        XCTAssertEqual(old.scale, 1.5)
    }
}
