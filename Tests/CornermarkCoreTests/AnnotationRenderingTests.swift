import CoreGraphics
import XCTest
@testable import CornermarkCore

final class AnnotationRenderingTests: XCTestCase {
    private let size = (w: 260, h: 170)

    /// Paints `kind` over `base` and returns the pixel diff against the untouched render, split by
    /// whether it lands inside the annotation's own reported bounds (plus `margin`).
    private func diff(_ kind: AnnotationKind, base: CGImage? = nil, color: RGBA = RGBA(0.9, 0.1, 0.1), width: Double = 4,
                      margin: CGFloat = 3, extra: ((AssetStore) -> Void)? = nil) -> (inside: Int, outside: Int, annotation: Annotation, after: Pixels, before: Pixels) {
        let image = base ?? Fixture.detail(size.w, size.h)
        let (plain, store) = Fixture.document(image)
        extra?(store)
        var doc = plain
        let a = Fixture.annotation(kind, color: color, width: width)
        doc.annotations = [a]
        let before = render(plain, store), after = render(doc, store)
        let d = Pixels.changed(before, after, inside: a.bounds.inflated(margin))
        return (d.inside, d.outside, a, after, before)
    }

    private func assertLocal(_ kind: AnnotationKind, minChanged: Int = 40, margin: CGFloat = 3, width: Double = 4,
                             file: StaticString = #filePath, line: UInt = #line) {
        let d = diff(kind, width: width, margin: margin)
        XCTAssertGreaterThanOrEqual(d.inside, minChanged, "\(kind) barely changed anything", file: file, line: line)
        XCTAssertEqual(d.outside, 0, "\(kind) painted outside its bounds", file: file, line: line)
    }

    func testArrowStylesPaintInsideTheirBounds() {
        for style in ArrowStyle.allCases {
            assertLocal(.arrow(from: CGPoint(x: 30, y: 150), to: CGPoint(x: 220, y: 110), control: CGPoint(x: 120, y: 160), style: style), minChanged: 150)
        }
    }

    func testCurvedArrowFollowsItsControlPointWhileOtherStylesIgnoreIt() {
        let from = CGPoint(x: 30, y: 150), to = CGPoint(x: 230, y: 150)
        let straightBase = Fixture.solid(260, 170, RGBA(1, 1, 1))
        func rendered(_ style: ArrowStyle, control: CGPoint?) -> Pixels {
            var (doc, store) = Fixture.document(straightBase)
            doc.annotations = [Fixture.annotation(.arrow(from: from, to: to, control: control, style: style))]
            return render(doc, store)
        }
        let curved = rendered(.curved, control: CGPoint(x: 130, y: 50))
        // The apex of the quadratic is halfway between the chord and the control point.
        let apex = (0..<8).contains(where: { dy in curved[130, 100 + dy].maxDiff(.white) > 100 })
        XCTAssertTrue(apex, "curved shaft should pass through the apex near y=100")
        XCTAssertLessThan(curved[130, 150].maxDiff(.white), 10, "the chord itself is not drawn")
        let classicBent = rendered(.classic, control: CGPoint(x: 130, y: 50))
        let classicStraight = rendered(.classic, control: nil)
        XCTAssertEqual(Pixels.changed(classicBent, classicStraight, inside: .zero).outside, 0)
    }

    func testLineRectEllipseVariants() {
        assertLocal(.line(from: CGPoint(x: 20, y: 20), to: CGPoint(x: 240, y: 60)))
        assertLocal(.rect(CGRect(x: 40, y: 40, width: 120, height: 80), filled: false, cornerRadius: 0))
        assertLocal(.rect(CGRect(x: 40, y: 40, width: 120, height: 80), filled: true, cornerRadius: 0))
        assertLocal(.rect(CGRect(x: 40, y: 40, width: 120, height: 80), filled: false, cornerRadius: 24))
        assertLocal(.rect(CGRect(x: 40, y: 40, width: 120, height: 80), filled: true, cornerRadius: 24))
        assertLocal(.ellipse(CGRect(x: 40, y: 40, width: 120, height: 80), filled: false))
        assertLocal(.ellipse(CGRect(x: 40, y: 40, width: 120, height: 80), filled: true))
    }

    func testRectOutlineVersusFill() {
        let base = Fixture.solid(260, 170, RGBA(1, 1, 1))
        let red = Px(230, 26, 26)
        let outline = diff(.rect(CGRect(x: 40, y: 40, width: 120, height: 80), filled: false, cornerRadius: 0), base: base).after
        XCTAssertTrue(outline[100, 40].isNear(red, 12), "edge is stroked")
        XCTAssertEqual(outline[100, 80], .white, "interior of an outline stays untouched")
        let filled = diff(.rect(CGRect(x: 40, y: 40, width: 120, height: 80), filled: true, cornerRadius: 0), base: base).after
        XCTAssertTrue(filled[100, 80].isNear(red, 12), "fill covers the interior")
        let rounded = diff(.rect(CGRect(x: 40, y: 40, width: 120, height: 80), filled: true, cornerRadius: 30), base: base).after
        XCTAssertEqual(rounded[41, 41], .white, "rounded corner leaves the corner pixel alone")
        XCTAssertTrue(rounded[100, 41].isNear(red, 12))
    }

    func testEllipseFillLeavesBoundingBoxCornerAlone() {
        let base = Fixture.solid(260, 170, RGBA(1, 1, 1))
        let a = diff(.ellipse(CGRect(x: 40, y: 40, width: 120, height: 80), filled: true), base: base).after
        XCTAssertTrue(a[100, 80].isNear(Px(230, 26, 26), 12))
        XCTAssertEqual(a[42, 42], .white)
    }

    func testCounterDrawsCenteredDisc() {
        let base = Fixture.solid(260, 170, RGBA(1, 1, 1))
        let d = diff(.counter(center: CGPoint(x: 130, y: 85), number: 7, radius: 22), base: base)
        XCTAssertEqual(d.outside, 0)
        XCTAssertTrue(d.after[130 + 19, 85].isNear(Px(230, 26, 26), 12), "disc fill near the rim")
        XCTAssertEqual(d.after[130 + 30, 85], .white)

        var sx = 0.0, sy = 0.0, n = 0.0
        for y in 63...107 { for x in 108...152 where d.after[x, y].r > 200 && d.after[x, y].g > 200 && d.after[x, y].b > 200 {
            if hypot(Double(x - 130), Double(y - 85)) < 16 { sx += Double(x); sy += Double(y); n += 1 }
        } }
        XCTAssertGreaterThan(n, 10, "digit ink (white on the disc) exists")
        XCTAssertEqual(sx / n, 130, accuracy: 4, "digit is centered horizontally")
        XCTAssertEqual(sy / n, 85, accuracy: 4, "digit is centered vertically")
    }

    func testPencilSmoothsThroughPointsAndHighlighterMultiplies() {
        let zigzag = (0..<9).map { CGPoint(x: 20 + $0 * 28, y: $0 % 2 == 0 ? 40 : 120) }
        assertLocal(.pencil(points: zigzag), minChanged: 300)
        assertLocal(.pencil(points: [CGPoint(x: 100, y: 100)]), minChanged: 6)

        let base = Fixture.image(width: 260, height: 170) { ctx in
            ctx.setFillColor(RGBA(0.86, 0.86, 0.86).cgColor); ctx.fill(CGRect(x: 0, y: 0, width: 260, height: 170))
            ctx.setFillColor(RGBA(0, 0, 0).cgColor); ctx.fill(CGRect(x: 100, y: 70, width: 60, height: 20))
        }
        let d = diff(.highlighter(points: [CGPoint(x: 20, y: 80), CGPoint(x: 240, y: 80)]), base: base, color: RGBA(1, 1, 0, 1), width: 28)
        XCTAssertEqual(d.outside, 0)
        XCTAssertEqual(d.before[40, 80], Px(219, 219, 219), accuracy: 2)
        let tinted = d.after[40, 80]
        XCTAssertGreaterThan(tinted.r, 200, "red channel survives multiplication by yellow")
        XCTAssertLessThan(tinted.b, 140, "blue channel is pulled down")
        XCTAssertGreaterThan(tinted.b, 60, "highlighter stays translucent rather than opaque yellow")
        XCTAssertEqual(d.after[130, 80], .black, "ink underneath remains fully dark under multiply")
    }

    func testBlurSmoothChangesRegionOnly() {
        let rect = CGRect(x: 10, y: 10, width: 110, height: 60)
        let d = diff(.blur(rect, mode: .smooth), margin: 0)
        XCTAssertGreaterThan(d.inside, 500)
        XCTAssertEqual(d.outside, 0)
        let stripesBefore = (13..<100).reduce(0) { $0 + abs(d.before[$1, 30].r - d.before[$1 + 1, 30].r) }
        let stripesAfter = (13..<100).reduce(0) { $0 + abs(d.after[$1, 30].r - d.after[$1 + 1, 30].r) }
        XCTAssertLessThan(stripesAfter * 4, stripesBefore, "edge energy drops sharply")
    }

    func testPixelateProducesUniformBlocksAndIsLocal() {
        let rect = CGRect(x: 8, y: 60, width: 120, height: 60)
        let d = diff(.pixelate(rect, blockSize: 10, seed: 42), margin: 0)
        XCTAssertGreaterThan(d.inside, 500)
        XCTAssertEqual(d.outside, 0)
        for (bx, by) in [(0, 0), (3, 2), (11, 5)] {
            let x0 = 8 + bx * 10, y0 = 60 + by * 10
            let first = d.after[x0, y0]
            for y in y0..<(y0 + 10) { for x in x0..<min(x0 + 10, 128) { XCTAssertEqual(d.after[x, y], first, "block (\(bx),\(by)) is not flat") } }
        }
    }

    func testPixelateIsDeterministicPerSeedAndDiffersAcrossSeeds() {
        let rect = CGRect(x: 8, y: 60, width: 120, height: 60)
        let a1 = diff(.pixelate(rect, blockSize: 10, seed: 7), margin: 0).after
        let a2 = diff(.pixelate(rect, blockSize: 10, seed: 7), margin: 0).after
        let b = diff(.pixelate(rect, blockSize: 10, seed: 8), margin: 0).after
        XCTAssertEqual(Pixels.changed(a1, a2, inside: rect).inside + Pixels.changed(a1, a2, inside: rect).outside, 0)
        let across = Pixels.changed(a1, b, inside: rect)
        XCTAssertGreaterThan(across.inside, 2000, "most pixels of the region change with the seed")
        XCTAssertEqual(across.outside, 0)
    }

    func testPixelateJitterStaysNearTheBlockAverage() {
        let flat = Fixture.solid(100, 100, RGBA(0.5, 0.5, 0.5))
        let d = diff(.pixelate(CGRect(x: 0, y: 0, width: 100, height: 100), blockSize: 20, seed: 99), base: flat, margin: 0)
        var distinct = Set<Int>()
        for by in 0..<5 { for bx in 0..<5 {
            let p = d.after[bx * 20 + 3, by * 20 + 3]
            XCTAssertLessThanOrEqual(abs(p.r - 128), 14)
            distinct.insert(p.r * 1000 + p.g * 10 + p.b)
        } }
        XCTAssertGreaterThan(distinct.count, 8, "blocks over identical content still get different values")
    }

    func testSecureBlurDestroysHighFrequencyDetailAndSmoothBlurKeepsMore() {
        func stripes(phase: Int) -> CGImage {
            Fixture.image(width: 200, height: 100) { ctx in
                ctx.setFillColor(RGBA(1, 1, 1).cgColor); ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
                ctx.setFillColor(RGBA(0, 0, 0).cgColor)
                for x in stride(from: phase, to: 200, by: 2) { ctx.fill(CGRect(x: x, y: 0, width: 1, height: 100)) }
            }
        }
        let rect = CGRect(x: 20, y: 10, width: 160, height: 80)
        func energy(_ p: Pixels) -> Int { (30..<170).reduce(0) { $0 + abs(p[$1, 50].r - p[$1 + 1, 50].r) } }

        let before = diff(.blur(rect, mode: .secure), base: stripes(phase: 0), margin: 0)
        XCTAssertGreaterThan(energy(before.before), 30_000)
        XCTAssertLessThan(energy(before.after), 400, "secure blur leaves essentially no 1px detail")

        let shifted = diff(.blur(rect, mode: .secure), base: stripes(phase: 1), margin: 0)
        let maxDelta = (30..<170).map { abs(before.after[$0, 50].r - shifted.after[$0, 50].r) }.max()!
        XCTAssertLessThanOrEqual(maxDelta, 3, "two inputs that differ only in fine detail redact to the same output")

        let smooth = diff(.blur(rect, mode: .smooth), base: stripes(phase: 0), margin: 0)
        XCTAssertLessThan(energy(smooth.after), energy(smooth.before) / 4)
    }

    func testSpotlightDimsEverythingOutsideTheRect() {
        let rect = CGRect(x: 70, y: 40, width: 100, height: 70)
        let base = Fixture.solid(260, 170, RGBA(1, 1, 1))
        let d = diff(.spotlight(rect), base: base)
        XCTAssertEqual(d.after[120, 70], .white, "inside the spotlight is untouched")
        XCTAssertLessThan(d.after[10, 10].r, 140)
        XCTAssertLessThan(d.after[250, 160].r, 140)
        XCTAssertEqual(d.after[10, 10], d.after[250, 160])
        XCTAssertGreaterThan(d.after[10, 10].r, 60, "dim, not black")
    }

    func testImageAnnotationCompositesAssetIntoItsRect() {
        let patch = Fixture.image(width: 8, height: 4) { ctx in
            ctx.setFillColor(RGBA(0, 0, 1).cgColor); ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 2))
            ctx.setFillColor(RGBA(0, 1, 0).cgColor); ctx.fill(CGRect(x: 0, y: 2, width: 8, height: 2))
        }
        let rect = CGRect(x: 60, y: 40, width: 80, height: 40)
        let d = diff(.image(rect, asset: "patch"), base: Fixture.solid(260, 170, RGBA(1, 1, 1)), margin: 0) { $0.add(image: patch, id: "patch") }
        XCTAssertEqual(d.outside, 0)
        XCTAssertTrue(d.after[100, 45].isNear(.blue, 4), "top half of the asset is on top")
        XCTAssertTrue(d.after[100, 75].isNear(.green, 4), "bottom half of the asset is at the bottom")
    }

    func testRedactionSeesAnnotationsPaintedBeforeIt() {
        let base = Fixture.solid(100, 60, RGBA(1, 1, 1))
        var (doc, store) = Fixture.document(base)
        let marker = Fixture.annotation(.rect(CGRect(x: 10, y: 10, width: 80, height: 40), filled: true, cornerRadius: 0), color: RGBA(0, 0, 0))
        let redact = Fixture.annotation(.pixelate(CGRect(x: 0, y: 0, width: 100, height: 60), blockSize: 50, seed: 1))
        doc.annotations = [marker, redact]
        let covered = render(doc, store)
        doc.annotations = [redact, marker]
        let afterwards = render(doc, store)
        XCTAssertTrue((40..<130).contains(covered[50, 30].r), "pixelate after the marker averages the marker in")
        XCTAssertTrue(afterwards[50, 30].isNear(.black, 2), "pixelate before the marker leaves the marker crisp")
    }

    func testExcludingSkipsOneAnnotation() {
        let base = Fixture.solid(100, 60, RGBA(1, 1, 1))
        var (doc, store) = Fixture.document(base)
        let a = Fixture.annotation(.rect(CGRect(x: 10, y: 10, width: 40, height: 40), filled: true, cornerRadius: 0), color: RGBA(0, 0, 0))
        let b = Fixture.annotation(.rect(CGRect(x: 50, y: 10, width: 40, height: 40), filled: true, cornerRadius: 0), color: RGBA(0, 0, 0))
        doc.annotations = [a, b]
        let ctx = Bitmap.makeContext(width: 100, height: 60, yDown: true)!
        Renderer.draw(doc, assets: store, in: ctx, excluding: a.id)
        let p = Pixels(ctx.makeImage()!)
        XCTAssertEqual(p[30, 30], .white)
        XCTAssertTrue(p[70, 30].isNear(.black, 2))
    }

    func testDrawIntoCallerContextMatchesRender() {
        let (plain, store) = Fixture.document(Fixture.detail())
        var doc = plain
        doc.annotations = [Fixture.annotation(.arrow(from: CGPoint(x: 20, y: 150), to: CGPoint(x: 200, y: 100), control: nil, style: .classic))]
        doc.crop = CGRect(x: 10, y: 20, width: 200, height: 120)
        doc.geometry.quarterTurns = 1
        var bg = BackgroundStyle(); bg.padding = 20; bg.shadow = true
        doc.background = bg
        let reference = render(doc, store)

        let size = Renderer.canvasSize(doc, assets: store)
        let ctx = Bitmap.makeContext(width: Int(size.width), height: Int(size.height), yDown: true)!
        Renderer.draw(doc, assets: store, in: ctx)
        let viaDraw = Pixels(ctx.makeImage()!)
        XCTAssertEqual(Pixels.changed(reference, viaDraw, inside: .zero).outside, 0)

        let yUp = Bitmap.makeContext(width: Int(size.width), height: Int(size.height), yDown: false)!
        Renderer.draw(doc, assets: store, in: yUp, yDown: false)
        let viaYUp = Pixels(yUp.makeImage()!)
        XCTAssertEqual(Pixels.changed(reference, viaYUp, inside: .zero).outside, 0)
    }
}

private func XCTAssertEqual(_ a: Px, _ b: Px, accuracy: Int, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertLessThanOrEqual(a.maxDiff(b), accuracy, "\(a) vs \(b)", file: file, line: line)
}
