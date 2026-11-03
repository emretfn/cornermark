import CoreGraphics
import XCTest
@testable import KadrajCore

final class StitcherTests: XCTestCase {
    private func slice(_ page: PixelBuffer, rows: Range<Int>) -> PixelBuffer {
        PixelBuffer(width: page.width, height: rows.count, bytes: Array(page.bytes[(rows.lowerBound * page.width * 4)..<(rows.upperBound * page.width * 4)]))
    }

    private func assertSameImage(_ image: CGImage?, _ expected: PixelBuffer, file: StaticString = #filePath, line: UInt = #line) {
        guard let image, let got = PixelBuffer(image: image) else { return XCTFail("no image", file: file, line: line) }
        XCTAssertEqual(got.width, expected.width, file: file, line: line)
        XCTAssertEqual(got.height, expected.height, "stitched height", file: file, line: line)
        XCTAssertTrue(got.bytes == expected.bytes, "stitched pixels differ from the source page", file: file, line: line)
    }

    private let page = PixelBuffer(image: Fixture.randomRows(width: 60, height: 1000, seed: 11))!

    func testReconstructsTallImageFromOverlappingSlices() {
        var s = ScrollStitcher()
        let offsets = [0, 140, 300, 390, 600, 700]
        var outcomes: [ScrollStitcher.Outcome] = []
        for o in offsets { outcomes.append(s.add(slice(page, rows: o..<(o + 300)).makeImage()!)) }
        XCTAssertEqual(outcomes, [.started, .appended(lines: 140), .appended(lines: 160), .appended(lines: 90), .appended(lines: 210), .appended(lines: 100)])
        assertSameImage(s.image, slice(page, rows: 0..<1000))
        XCTAssertEqual(s.lineCount, 1000)
    }

    func testStickyHeaderAndFooterAppearOnceAtTheEnds() {
        let header = PixelBuffer(image: Fixture.randomRows(width: 60, height: 40, seed: 100))!
        let footer = PixelBuffer(image: Fixture.randomRows(width: 60, height: 30, seed: 200))!
        func frame(_ offset: Int) -> PixelBuffer {
            let body = slice(page, rows: offset..<(offset + 230))
            return PixelBuffer(width: 60, height: 300, bytes: header.bytes + body.bytes + footer.bytes)
        }
        var s = ScrollStitcher()
        let offsets = [0, 150, 300, 450, 520]
        for o in offsets { s.add(frame(o).makeImage()!) }
        let expected = PixelBuffer(width: 60, height: 40 + 750 + 30,
                                   bytes: header.bytes + slice(page, rows: 0..<750).bytes + footer.bytes)
        assertSameImage(s.image, expected)
    }

    func testHeaderThatEndsInPlainPaddingStillStitches() {
        let bar = PixelBuffer(image: Fixture.randomRows(width: 60, height: 30, seed: 300))!
        let padding = [UInt8](repeating: 255, count: 60 * 12 * 4)
        let header = bar.bytes + padding
        func frame(_ offset: Int) -> PixelBuffer {
            PixelBuffer(width: 60, height: 300, bytes: header + slice(page, rows: offset..<(offset + 258)).bytes)
        }
        var s = ScrollStitcher()
        for o in [0, 120, 240, 400] { XCTAssertNotEqual(s.add(frame(o).makeImage()!), .noOverlap, "offset \(o)") }
        assertSameImage(s.image, PixelBuffer(width: 60, height: 42 + 658, bytes: header + slice(page, rows: 0..<658).bytes))
    }

    func testManualStickyRegionsSkipDetection() {
        let header = PixelBuffer(image: Fixture.randomRows(width: 60, height: 40, seed: 100))!
        func frame(_ offset: Int) -> PixelBuffer {
            PixelBuffer(width: 60, height: 260, bytes: header.bytes + slice(page, rows: offset..<(offset + 220)).bytes)
        }
        var options = ScrollStitcher.Options()
        options.stickyStart = 40; options.stickyEnd = 0
        var s = ScrollStitcher(options: options)
        for o in [0, 100, 200] { s.add(frame(o).makeImage()!) }
        assertSameImage(s.image, PixelBuffer(width: 60, height: 40 + 420, bytes: header.bytes + slice(page, rows: 0..<420).bytes))
    }

    func testRepeatedFrameIsANoOp() {
        var s = ScrollStitcher()
        let f = slice(page, rows: 0..<300).makeImage()!
        XCTAssertEqual(s.add(f), .started)
        let before = s.image
        XCTAssertEqual(s.add(f), .noMovement)
        XCTAssertEqual(s.add(f), .noMovement)
        XCTAssertEqual(s.lineCount, 300)
        assertSameImage(s.image, PixelBuffer(image: before!)!)

        s.add(slice(page, rows: 120..<420).makeImage()!)
        XCTAssertEqual(s.add(slice(page, rows: 120..<420).makeImage()!), .noMovement)
        assertSameImage(s.image, slice(page, rows: 0..<420))
    }

    func testScrollingBackIsIgnoredAndForwardScrollResumesWithoutDuplicates() {
        var s = ScrollStitcher()
        s.add(slice(page, rows: 0..<300).makeImage()!)
        s.add(slice(page, rows: 200..<500).makeImage()!)
        XCTAssertEqual(s.add(slice(page, rows: 120..<420).makeImage()!), .scrolledBackward)
        XCTAssertEqual(s.lineCount, 500)
        XCTAssertEqual(s.add(slice(page, rows: 350..<650).makeImage()!), .appended(lines: 150))
        assertSameImage(s.image, slice(page, rows: 0..<650))
    }

    func testUnrelatedOrMismatchedFramesAreRejectedWithoutDamage() {
        var s = ScrollStitcher()
        s.add(slice(page, rows: 0..<300).makeImage()!)
        let other = PixelBuffer(image: Fixture.randomRows(width: 60, height: 300, seed: 999))!
        XCTAssertEqual(s.add(other.makeImage()!), .noOverlap)
        XCTAssertEqual(s.add(Fixture.randomRows(width: 60, height: 200, seed: 1)), .sizeMismatch)
        assertSameImage(s.image, slice(page, rows: 0..<300))
        XCTAssertEqual(s.add(slice(page, rows: 100..<400).makeImage()!), .appended(lines: 100))
    }

    func testBlankHeavyPagesStillMatchOnTheirContent() {
        var bytes = [UInt8](repeating: 255, count: 80 * 600 * 4)
        for y in stride(from: 230, to: 250, by: 1) { for x in 10..<70 {
            let i = (y * 80 + x) * 4; bytes[i] = UInt8(y % 200); bytes[i + 1] = UInt8(x * 3); bytes[i + 2] = 40
        } }
        let tall = PixelBuffer(width: 80, height: 600, bytes: bytes)
        func slice(_ o: Int) -> CGImage {
            PixelBuffer(width: 80, height: 300, bytes: Array(tall.bytes[(o * 320)..<((o + 300) * 320)])).makeImage()!
        }
        var s = ScrollStitcher()
        s.add(slice(0)); s.add(slice(100)); s.add(slice(200))
        XCTAssertEqual(s.lineCount, 500)
        assertSameImage(s.image, PixelBuffer(width: 80, height: 500, bytes: Array(tall.bytes[0..<(500 * 320)])))
    }

    func testHorizontalAxisStitchesColumns() {
        let wide = PixelBuffer(image: Fixture.randomRows(width: 900, height: 50, seed: 21))!
        func slice(_ cols: Range<Int>) -> CGImage {
            var bytes: [UInt8] = []
            for y in 0..<50 { bytes += wide.bytes[((y * 900 + cols.lowerBound) * 4)..<((y * 900 + cols.upperBound) * 4)] }
            return PixelBuffer(width: cols.count, height: 50, bytes: bytes).makeImage()!
        }
        var options = ScrollStitcher.Options()
        options.axis = .horizontal
        var s = ScrollStitcher(options: options)
        XCTAssertEqual(s.add(slice(0..<300)), .started)
        XCTAssertEqual(s.add(slice(180..<480)), .appended(lines: 180))
        XCTAssertEqual(s.add(slice(180..<480)), .noMovement)
        XCTAssertEqual(s.add(slice(400..<700)), .appended(lines: 220))
        XCTAssertEqual(s.add(slice(300..<600)), .scrolledBackward)
        var expected: [UInt8] = []
        for y in 0..<50 { expected += wide.bytes[((y * 900) * 4)..<((y * 900 + 700) * 4)] }
        assertSameImage(s.image, PixelBuffer(width: 700, height: 50, bytes: expected))
    }

    func testSmallNoiseInOverlapDoesNotBreakTheMatch() {
        var s = ScrollStitcher()
        s.add(slice(page, rows: 0..<400).makeImage()!)
        var second = slice(page, rows: 150..<550)
        for r in [30, 200] { for i in 0..<(60 * 4) { second.bytes[r * 240 + i] ^= 0x55 } }
        XCTAssertEqual(s.add(second.makeImage()!), .appended(lines: 150))
        XCTAssertEqual(s.lineCount, 550)
    }
}
