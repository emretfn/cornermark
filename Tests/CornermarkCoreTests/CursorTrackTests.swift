import XCTest
@testable import CornermarkCore

final class CursorTrackTests: XCTestCase {
    private func project(_ samples: [PointerSample], keys: [KeyEvent] = [], duration: Double = 10, cursor: CursorSettings) -> RecordingProject {
        RecordingProject(source: .init(pixelWidth: 1600, pixelHeight: 900, pointWidth: 800, pointHeight: 450, fps: 60, duration: duration),
                         events: .init(pointer: samples, keys: keys), edits: .init(cursor: cursor))
    }

    private func smooth(_ samples: [PointerSample], duration: Double = 10) -> RecordingProject {
        project(samples, duration: duration, cursor: CursorSettings(motion: .smooth))
    }

    private func x(_ p: RecordingProject, _ t: Double) -> Double { frameState(p, outputTime: t).cursor?.x ?? .nan }

    /// A step a hand makes in 10 ms, then a long rest.
    private let step = [PointerSample(t: 1, x: 0, y: 0), PointerSample(t: 1.01, x: 100, y: 0), PointerSample(t: 5, x: 100, y: 0)]

    func testSmoothNeverPassesAStop() {
        let p = smooth(step)
        var last = -Double.infinity
        for i in 0...5000 {
            let v = x(p, Double(i) / 1000)
            XCTAssertLessThanOrEqual(v, 100, "at \(Double(i) / 1000) s")
            XCTAssertGreaterThanOrEqual(v, last - 1e-9, "it closes in without turning back")
            last = v
        }
        XCTAssertEqual(x(p, 1.01 + 0.5), 100, accuracy: 1, "half a second after the stop it has arrived")
        XCTAssertEqual(x(p, 1.01 + 0.05), 15, accuracy: 15, "50 ms after the stop it is still on its way")
    }

    func testSmoothStaysInsideWhereThePointerHasBeen() {
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<20 {
            var t = 0.0, px = 400.0, py = 200.0
            var samples: [PointerSample] = []
            for _ in 0..<200 {
                samples.append(PointerSample(t: t, x: px, y: py))
                t += Double.random(in: 0.002...0.05, using: &rng)
                px += Double.random(in: -40...40, using: &rng)
                py += Double.random(in: -40...40, using: &rng)
            }
            let p = smooth(samples, duration: t + 1)
            var lowX = Double.infinity, highX = -Double.infinity, lowY = Double.infinity, highY = -Double.infinity
            var k = 0
            for i in 0...Int((t + 1) * 1000) {
                let now = Double(i) / 1000
                while k < samples.count, samples[k].t <= now {
                    lowX = min(lowX, samples[k].x); highX = max(highX, samples[k].x)
                    lowY = min(lowY, samples[k].y); highY = max(highY, samples[k].y)
                    k += 1
                }
                if k < samples.count, k > 0 {
                    lowX = min(lowX, samples[k].x); highX = max(highX, samples[k].x)
                    lowY = min(lowY, samples[k].y); highY = max(highY, samples[k].y)
                }
                guard let c = frameState(p, outputTime: now).cursor else { return XCTFail("a pointer at \(now)") }
                XCTAssert(c.x >= lowX - 1e-6 && c.x <= highX + 1e-6 && c.y >= lowY - 1e-6 && c.y <= highY + 1e-6,
                          "at \(now) s the smoothed pointer (\(c.x), \(c.y)) left the box the recorded one reached")
            }
        }
    }

    /// Nothing carries over from one frame to the next, so a 24 fps export, a 240 fps scrub and a backward scrub agree at every moment.
    func testSmoothDependsOnlyOnTheMoment() {
        let samples = (0...300).map { i -> PointerSample in
            let t = Double(i) / 120
            return PointerSample(t: t, x: 400 + 200 * sin(3 * t) + (i % 2 == 0 ? 3 : -3), y: 200 + 100 * cos(2 * t))
        }
        let p = smooth(samples, duration: 3)
        let moments = (0...60).map { Double($0) / 24 }
        let forward = moments.map { frameState(p, outputTime: $0) }
        for k in 0...720 { _ = frameState(p, outputTime: Double(k) / 240) }
        let backward = moments.reversed().map { frameState(p, outputTime: $0) }
        XCTAssertEqual(forward, Array(backward.reversed()))
        XCTAssertEqual(forward, moments.map { frameState(smooth(samples, duration: 3), outputTime: $0) }, "a copy of the project answers the same")
        let jittery = forward.compactMap(\.cursor).map(\.x)
        let raw = moments.map { PointerTrack.position(samples, at: $0)!.x }
        func roughness(_ v: [Double]) -> Double { zip(v, v.dropFirst()).map { abs($0 - $1) }.reduce(0, +) }
        XCTAssertLessThan(roughness(jittery), roughness(raw), "the shake is gone from the smoothed path")
    }

    /// The spring as a differential equation, stepped finely by brute force, against the closed form.
    func testSmoothSolvesTheSpring() {
        let samples = (0...60).map { i -> PointerSample in
            let t = Double(i) / 30
            return PointerSample(t: t, x: Double((i * 37) % 300), y: Double((i * 11) % 90))
        }
        let p = smooth(samples, duration: 3)
        let w = CursorTrack.springRate, dt = 1e-5
        var px = samples[0].x, vx = 0.0, t = samples[0].t
        var worst = 0.0
        for check in stride(from: 0.1, through: 2.9, by: 0.1) {
            while t < check - dt / 2 {
                let target = PointerTrack.position(samples, at: t)!.x
                vx += (w * w * (target - px) - 2 * w * vx) * dt
                px += vx * dt
                t += dt
            }
            worst = max(worst, abs(px - x(p, check)))
        }
        XCTAssertLessThan(worst, 0.05, "the closed form follows the spring within a twentieth of a point")
    }

    func testSmoothLagsAMovingPointerByTwoOverTheRate() {
        let samples = [PointerSample(t: 0, x: 0, y: 0), PointerSample(t: 2, x: 400, y: 0)]
        let p = smooth(samples, duration: 3)
        XCTAssertEqual(x(p, 1.5), 300 - 200 * 2 / CursorTrack.springRate, accuracy: 0.01)
    }

    func testNaturalIsTheRecordedPath() {
        let p = project(step, cursor: CursorSettings())
        XCTAssertEqual(x(p, 1.005), 50, accuracy: 1e-9)
        XCTAssertEqual(x(p, 2), 100)
    }

    // MARK: Hiding

    /// Moves until 1 s, rests until 5 s, moves until 6 s.
    private let rest = [PointerSample(t: 0, x: 0, y: 0), PointerSample(t: 1, x: 100, y: 0), PointerSample(t: 5, x: 100, y: 0),
                        PointerSample(t: 6, x: 300, y: 100), PointerSample(t: 8, x: 300, y: 100)]

    private func opacity(_ p: RecordingProject, _ t: Double) -> Double { frameState(p, outputTime: t).cursor?.opacity ?? 0 }

    func testHideWhenNotMovingFadesOutAfterTheDelayAndIsBackWhenItMoves() {
        let p = project(rest, cursor: CursorSettings(hidesWhenIdle: true))
        XCTAssertEqual(opacity(p, 0.5), 1, "moving")
        XCTAssertEqual(opacity(p, 1 + CursorTrack.idleDelay), 1, "still, but not for long enough yet")
        let mid = opacity(p, 1 + CursorTrack.idleDelay + CursorTrack.idleFade / 2)
        XCTAssert(mid > 0.2 && mid < 0.8, "half way through the fade: \(mid)")
        XCTAssertNil(frameState(p, outputTime: 3).cursor, "hidden while it rests")
        XCTAssertNil(frameState(p, outputTime: 5 - CursorTrack.returnFade).cursor)
        XCTAssertEqual(opacity(p, 5), 1, "whole again as it starts to move")
        XCTAssertEqual(opacity(p, 5.5), 1)
        XCTAssertEqual(opacity(p, 6 + CursorTrack.idleDelay / 2), 1)
        XCTAssertNil(frameState(p, outputTime: 9).cursor, "the rest after the last move hides too")
        XCTAssertEqual(project(rest, cursor: CursorSettings()).edits.cursor.hidesWhenIdle, false, "off unless chosen")
        XCTAssertEqual(opacity(project(rest, cursor: CursorSettings()), 3), 1)
    }

    func testAShortPauseNeverHides() {
        let pause = [PointerSample(t: 0, x: 0, y: 0), PointerSample(t: 1, x: 100, y: 0), PointerSample(t: 2.2, x: 100, y: 0), PointerSample(t: 3, x: 0, y: 0)]
        let p = project(pause, cursor: CursorSettings(hidesWhenIdle: true))
        for i in 0...3000 { XCTAssertEqual(opacity(p, Double(i) / 1000), 1, "at \(Double(i) / 1000) s") }
    }

    func testHidingNeverJumps() {
        let keys = [KeyEvent(t: 1.4, label: "a", isCommand: false), KeyEvent(t: 1.45, label: "b", isCommand: false)]
        let p = project(rest, keys: keys, cursor: CursorSettings(hidesWhenIdle: true, hidesWhenTyping: true))
        var last = opacity(p, 0)
        for i in 1...9000 {
            let now = opacity(p, Double(i) / 1000)
            XCTAssertLessThan(abs(now - last), 0.02, "at \(Double(i) / 1000) s")
            last = now
        }
    }

    func testTypingHidesUntilThePointerMoves() {
        let keys = [KeyEvent(t: 2, label: "h", isCommand: false), KeyEvent(t: 2.1, label: "i", isCommand: false)]
        let p = project(rest, keys: keys, cursor: CursorSettings(hidesWhenTyping: true))
        XCTAssertEqual(opacity(p, 1.99), 1)
        XCTAssertNil(frameState(p, outputTime: 2 + CursorTrack.typingFade).cursor, "gone a moment after the first key")
        XCTAssertNil(frameState(p, outputTime: 4.5).cursor, "still gone after the typing stops, while the pointer rests")
        XCTAssertEqual(opacity(p, 5), 1, "back as it moves")
        XCTAssertEqual(opacity(p, 3, keys: [KeyEvent(t: 2, label: "\u{2318}C", isCommand: true)]), 1, "a shortcut is not typing")
        XCTAssertEqual(opacity(p, 0.8, keys: [KeyEvent(t: 0.5, label: "a", isCommand: false)]), 1, "a key while the pointer moves does not hide it")
        XCTAssertEqual(opacity(project(rest, keys: keys, cursor: CursorSettings()), 3), 1, "off unless chosen")
    }

    private func opacity(_ p: RecordingProject, _ t: Double, keys: [KeyEvent]) -> Double {
        var p = p
        p.events.keys = keys
        return opacity(p, t)
    }

    // MARK: Look and the file

    func testTheFrameCarriesTheStyleAndClampsTheSize() {
        let p = project(rest, cursor: CursorSettings(scale: 20, style: .dot))
        XCTAssertEqual(frameState(p, outputTime: 0.5).cursor, CursorFrame(x: 50, y: 0, scale: CursorSettings.scaleRange.upperBound, style: .dot, opacity: 1))
    }

    func testSettingsSurviveTheFileAndOldFilesReadAsBefore() throws {
        let chosen = CursorSettings(isVisible: true, scale: 2, style: .black, motion: .smooth, hidesWhenIdle: true, hidesWhenTyping: true)
        let data = try JSONEncoder().encode(chosen)
        XCTAssertEqual(try JSONDecoder().decode(CursorSettings.self, from: data), chosen)
        let old = try JSONDecoder().decode(CursorSettings.self, from: Data(#"{"isVisible": false, "scale": 1.5}"#.utf8))
        XCTAssertEqual(old, CursorSettings(isVisible: false, scale: 1.5, style: .white, motion: .natural, hidesWhenIdle: false, hidesWhenTyping: false))
        let later = try JSONDecoder().decode(CursorSettings.self, from: Data(#"{"style": "sparkle", "motion": "bouncy", "scale": 3}"#.utf8))
        XCTAssertEqual(later, CursorSettings(scale: 3), "a style or motion this version does not know reads as the default")
    }

    func testEveryStyleDrawsAtTheHotSpot() {
        for style in CursorStyle.allCases {
            let ctx = CGContext(data: nil, width: 80, height: 80, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            PointerShape.draw(CursorFrame(x: 40, y: 40, scale: 1, style: style), in: ctx)
            let pixels = ctx.data!.assumingMemoryBound(to: UInt8.self)
            func alpha(_ x: Int, _ y: Int) -> UInt8 { pixels[(y * 80 + x) * 4 + 3] }
            XCTAssertGreaterThan(alpha(41, 38), 0, "\(style) covers the pixel next to the hot spot")
            XCTAssertEqual(alpha(5, 5), 0, "\(style) stays near the hot spot")
            let faded = CGContext(data: nil, width: 80, height: 80, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            PointerShape.draw(CursorFrame(x: 40, y: 40, scale: 1, style: style, opacity: 0.5), in: faded)
            let half = faded.data!.assumingMemoryBound(to: UInt8.self)[(38 * 80 + 41) * 4 + 3]
            XCTAssertEqual(Double(half), Double(alpha(41, 38)) / 2, accuracy: 2, "\(style) at half opacity")
        }
    }
}
