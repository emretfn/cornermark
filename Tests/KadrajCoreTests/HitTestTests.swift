import CoreGraphics
import XCTest
@testable import KadrajCore

final class HitTestTests: XCTestCase {
    private func ann(_ kind: AnnotationKind, width: Double = 4) -> Annotation { Fixture.annotation(kind, width: width) }

    func testStrokeShapesHitOnTheirOutlineNotTheirInterior() {
        let rect = ann(.rect(CGRect(x: 20, y: 20, width: 100, height: 60), filled: false, cornerRadius: 0))
        XCTAssertTrue(rect.hitTest(CGPoint(x: 70, y: 21), tolerance: 2))
        XCTAssertFalse(rect.hitTest(CGPoint(x: 70, y: 50), tolerance: 2))
        XCTAssertFalse(rect.hitTest(CGPoint(x: 200, y: 200), tolerance: 2))
        XCTAssertTrue(ann(.rect(CGRect(x: 20, y: 20, width: 100, height: 60), filled: true, cornerRadius: 0)).hitTest(CGPoint(x: 70, y: 50), tolerance: 0))

        let ellipse = ann(.ellipse(CGRect(x: 20, y: 20, width: 100, height: 60), filled: false))
        XCTAssertTrue(ellipse.hitTest(CGPoint(x: 70, y: 20), tolerance: 2))
        XCTAssertFalse(ellipse.hitTest(CGPoint(x: 70, y: 50), tolerance: 2))
        XCTAssertFalse(ellipse.hitTest(CGPoint(x: 22, y: 22), tolerance: 2), "bounding-box corner is outside the ellipse")
        XCTAssertTrue(ann(.ellipse(CGRect(x: 20, y: 20, width: 100, height: 60), filled: true)).hitTest(CGPoint(x: 70, y: 50), tolerance: 0))
    }

    func testLineArrowAndPencilHitWithinToleranceOfTheirPath() {
        let line = ann(.line(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 100, y: 0)))
        XCTAssertTrue(line.hitTest(CGPoint(x: 50, y: 5), tolerance: 4))
        XCTAssertFalse(line.hitTest(CGPoint(x: 50, y: 12), tolerance: 4))
        XCTAssertFalse(line.hitTest(CGPoint(x: 130, y: 0), tolerance: 4))

        let curved = ann(.arrow(from: CGPoint(x: 0, y: 100), to: CGPoint(x: 100, y: 100), control: CGPoint(x: 50, y: 0), style: .curved))
        XCTAssertTrue(curved.hitTest(CGPoint(x: 50, y: 50), tolerance: 3), "apex of the curve")
        XCTAssertFalse(curved.hitTest(CGPoint(x: 50, y: 100), tolerance: 3), "the chord is not part of a curved arrow")
        XCTAssertTrue(curved.hitTest(CGPoint(x: 98, y: 100), tolerance: 3), "near the head")

        let pencil = ann(.pencil(points: [CGPoint(x: 0, y: 0), CGPoint(x: 50, y: 50), CGPoint(x: 100, y: 0)]))
        XCTAssertTrue(pencil.hitTest(CGPoint(x: 25, y: 25), tolerance: 2))
        XCTAssertFalse(pencil.hitTest(CGPoint(x: 50, y: 10), tolerance: 2))
    }

    func testRegionTextAndCounterHits() {
        XCTAssertTrue(ann(.blur(CGRect(x: 10, y: 10, width: 40, height: 40), mode: .smooth)).hitTest(CGPoint(x: 30, y: 30), tolerance: 0))
        XCTAssertFalse(ann(.pixelate(CGRect(x: 10, y: 10, width: 40, height: 40), blockSize: 4, seed: 1)).hitTest(CGPoint(x: 80, y: 30), tolerance: 2))
        XCTAssertTrue(ann(.counter(center: CGPoint(x: 50, y: 50), number: 1, radius: 10)).hitTest(CGPoint(x: 58, y: 50), tolerance: 0))
        XCTAssertFalse(ann(.counter(center: CGPoint(x: 50, y: 50), number: 1, radius: 10)).hitTest(CGPoint(x: 70, y: 50), tolerance: 2))
        let text = ann(.text(origin: CGPoint(x: 10, y: 10), string: "Hello", fontSize: 20, style: .plain))
        XCTAssertTrue(text.hitTest(CGPoint(x: 20, y: 20), tolerance: 0))
        XCTAssertFalse(text.hitTest(CGPoint(x: 300, y: 20), tolerance: 0))
    }

    func testTranslatedMovesEverythingIncludingBoundsAndControlPoint() {
        let v = CGVector(dx: 13, dy: -7)
        let kinds: [AnnotationKind] = [
            .arrow(from: CGPoint(x: 5, y: 50), to: CGPoint(x: 90, y: 60), control: CGPoint(x: 40, y: 10), style: .curved),
            .line(from: CGPoint(x: 1, y: 2), to: CGPoint(x: 30, y: 40)),
            .rect(CGRect(x: 5, y: 5, width: 20, height: 10), filled: true, cornerRadius: 3),
            .ellipse(CGRect(x: 5, y: 5, width: 20, height: 10), filled: false),
            .text(origin: CGPoint(x: 9, y: 9), string: "hi", fontSize: 12, style: .pill),
            .counter(center: CGPoint(x: 20, y: 20), number: 4, radius: 9),
            .pencil(points: [CGPoint(x: 1, y: 1), CGPoint(x: 9, y: 4)]),
            .highlighter(points: [CGPoint(x: 1, y: 1), CGPoint(x: 9, y: 4)]),
            .blur(CGRect(x: 5, y: 5, width: 20, height: 10), mode: .secure),
            .pixelate(CGRect(x: 5, y: 5, width: 20, height: 10), blockSize: 4, seed: 9),
            .spotlight(CGRect(x: 5, y: 5, width: 20, height: 10)),
            .image(CGRect(x: 5, y: 5, width: 20, height: 10), asset: "a"),
        ]
        for kind in kinds {
            let original = ann(kind)
            let moved = original.translated(by: v)
            XCTAssertEqual(moved.id, original.id)
            XCTAssertEqual(moved.bounds.minX, original.bounds.minX + 13, accuracy: 1e-9, "\(kind)")
            XCTAssertEqual(moved.bounds.minY, original.bounds.minY - 7, accuracy: 1e-9, "\(kind)")
            XCTAssertEqual(moved.bounds.size, original.bounds.size, "\(kind)")
            XCTAssertEqual(moved.translated(by: CGVector(dx: -13, dy: 7)), original)
        }
    }

    func testDocumentPicksTheTopmostHit() {
        var doc = Document(base: "b", pixelSize: CGSize(width: 100, height: 100), pointScale: 1)
        let under = ann(.rect(CGRect(x: 0, y: 0, width: 100, height: 100), filled: true, cornerRadius: 0))
        let over = ann(.rect(CGRect(x: 20, y: 20, width: 30, height: 30), filled: true, cornerRadius: 0))
        doc.annotations = [under, over]
        XCTAssertEqual(doc.annotationID(at: CGPoint(x: 30, y: 30), tolerance: 1), over.id)
        XCTAssertEqual(doc.annotationID(at: CGPoint(x: 80, y: 80), tolerance: 1), under.id)
        XCTAssertNil(doc.annotationID(at: CGPoint(x: 300, y: 300), tolerance: 1))
    }
}
