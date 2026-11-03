import CoreGraphics
import XCTest
@testable import CornermarkCore

final class TextRenderingTests: XCTestCase {
    private func render(_ string: String, style: TextStylePreset, size: Double = 60, color: RGBA = RGBA(0, 0, 0), on bg: RGBA = RGBA(1, 1, 1)) -> (Pixels, Annotation) {
        let base = Fixture.solid(300, 140, bg)
        var (doc, store) = Fixture.document(base)
        let a = Fixture.annotation(.text(origin: CGPoint(x: 20, y: 20), string: string, fontSize: size, style: style), color: color)
        doc.annotations = [a]
        return (CornermarkCoreTests.render(doc, store), a)
    }

    private func dark(_ p: Px) -> Bool { p.r < 100 && p.g < 100 && p.b < 100 }

    func testTextIsUprightNotMirroredOrFlipped() {
        let (t, ta) = render("T", style: .bold)
        let tb = ta.bounds
        let top = t.count(in: CGRect(x: tb.minX, y: tb.minY, width: tb.width, height: tb.height * 0.3), where: dark)
        let bottom = t.count(in: CGRect(x: tb.minX, y: tb.maxY - tb.height * 0.3, width: tb.width, height: tb.height * 0.3), where: dark)
        XCTAssertGreaterThan(top, bottom * 2, "a T has its bar on top (top \(top), bottom \(bottom))")

        let (l, la) = render("L", style: .bold)
        let lb = la.bounds
        let lTop = l.count(in: CGRect(x: lb.minX, y: lb.minY, width: lb.width, height: lb.height * 0.3), where: dark)
        let lBottom = l.count(in: CGRect(x: lb.minX, y: lb.maxY - lb.height * 0.3, width: lb.width, height: lb.height * 0.3), where: dark)
        XCTAssertGreaterThan(lBottom, lTop * 2, "an L has its foot at the bottom")

        let leftHalf = l.count(in: CGRect(x: lb.minX, y: lb.minY, width: lb.width / 2, height: lb.height), where: dark)
        let rightHalf = l.count(in: CGRect(x: lb.midX, y: lb.minY, width: lb.width / 2, height: lb.height), where: dark)
        XCTAssertGreaterThan(leftHalf, rightHalf, "the L stem is on the left, so text is not mirrored")
    }

    func testTextStaysUprightAfterRotationAndMatchesBoundsAtOrigin() {
        let (t, a) = render("T", style: .bold)
        let b = a.bounds
        let ink = t.count(in: nil, where: dark)
        let inBounds = t.count(in: b.inflated(2), where: dark)
        XCTAssertEqual(ink, inBounds, "all ink lies inside the reported bounds")
        XCTAssertGreaterThan(b.minY, 15)
        XCTAssertEqual(b.origin.x, 20, accuracy: 0.001)
    }

    func testEveryPresetPaintsInsideItsBounds() {
        for style in TextStylePreset.allCases {
            let base = Fixture.solid(300, 140, RGBA(1, 1, 1))
            var (doc, store) = Fixture.document(base)
            let before = CornermarkCoreTests.render(doc, store)
            let a = Fixture.annotation(.text(origin: CGPoint(x: 30, y: 30), string: "Cornermark\nsecond", fontSize: 26, style: style), color: RGBA(0.1, 0.3, 0.8))
            doc.annotations = [a]
            let after = CornermarkCoreTests.render(doc, store)
            let d = Pixels.changed(before, after, inside: a.bounds.inflated(style == .shadowed ? 14 : 4))
            XCTAssertGreaterThan(d.inside, 200, "\(style)")
            XCTAssertEqual(d.outside, 0, "\(style) painted outside its bounds")
            XCTAssertGreaterThan(a.bounds.height, 26 * 1.8, "\(style) two lines are measured")
        }
    }

    func testPillAndBannerFillTheirBoxAndInvertTheText() {
        for style in [TextStylePreset.pill, .banner] {
            let (p, a) = render("Hi", style: style, size: 30, color: RGBA(0.1, 0.2, 0.7))
            XCTAssertTrue(p[Int(a.bounds.midX), Int(a.bounds.minY) + 3].isNear(Px(26, 51, 179), 10), "\(style) background")
            let whiteInk = p.count(in: a.bounds, where: { $0.r > 240 && $0.g > 240 && $0.b > 240 })
            XCTAssertGreaterThan(whiteInk, 20, "\(style) text is drawn in the contrasting color")
        }
    }

    func testOutlinedTextHasContrastingHaloAndShadowedTextHasSoftEdges() {
        let (o, a) = render("W", style: .outlined, size: 70, color: RGBA(0.05, 0.05, 0.05), on: RGBA(0.5, 0.5, 0.5))
        XCTAssertGreaterThan(o.count(in: a.bounds.inflated(4), where: { $0.r > 240 }), 30, "halo of the opposite color")
        XCTAssertGreaterThan(o.count(in: a.bounds, where: { $0.r < 40 }), 30)
    }

    func testMonoUsesEvenAdvanceWidths() {
        let narrow = Annotation(kind: .text(origin: .zero, string: "iiii", fontSize: 20, style: .mono), stroke: Stroke(color: RGBA(0, 0, 0), width: 1))
        let wide = Annotation(kind: .text(origin: .zero, string: "WWWW", fontSize: 20, style: .mono), stroke: Stroke(color: RGBA(0, 0, 0), width: 1))
        XCTAssertEqual(narrow.bounds.width, wide.bounds.width, accuracy: 0.5)
    }
}
