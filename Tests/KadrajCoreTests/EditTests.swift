import CoreGraphics
import XCTest
@testable import KadrajCore

final class EditTests: XCTestCase {
    private func base() -> Document {
        Document(base: "b", pixelSize: CGSize(width: 100, height: 80), pointScale: 2)
    }

    private func mark(_ n: Int) -> Annotation {
        Fixture.annotation(.counter(center: CGPoint(x: n, y: n), number: n, radius: 5))
    }

    func testAddUpdateRemoveReorder() {
        var doc = base()
        let a = mark(1), b = mark(2), c = mark(3)
        for x in [a, b, c] { doc = doc.applying(.add(x)) }
        XCTAssertEqual(doc.annotations.map(\.id), [a.id, b.id, c.id])

        var moved = a; moved.kind = .counter(center: CGPoint(x: 50, y: 50), number: 1, radius: 5)
        doc = doc.applying(.update(moved))
        XCTAssertEqual(doc.annotations[0].kind, moved.kind)
        XCTAssertEqual(doc.applying(.update(mark(9))), doc, "updating an unknown id changes nothing")

        doc = doc.applying(.reorder(a.id, toIndex: 2))
        XCTAssertEqual(doc.annotations.map(\.id), [b.id, c.id, a.id])
        doc = doc.applying(.reorder(a.id, toIndex: 99))
        XCTAssertEqual(doc.annotations.map(\.id), [b.id, c.id, a.id])
        doc = doc.applying(.reorder(a.id, toIndex: -5))
        XCTAssertEqual(doc.annotations.map(\.id), [a.id, b.id, c.id])

        doc = doc.applying(.remove(b.id))
        XCTAssertEqual(doc.annotations.map(\.id), [a.id, c.id])
        XCTAssertEqual(doc.applying(.add(c)).annotations.count, 2, "re-adding an existing id replaces it")
    }

    func testCropClampsAndNormalizes() {
        var doc = base()
        doc = doc.applying(.setCrop(CGRect(x: -10, y: 10.4, width: 60.2, height: 200)))
        XCTAssertEqual(doc.crop, CGRect(x: 0, y: 10, width: 51, height: 70))
        XCTAssertEqual(doc.applying(.setCrop(CGRect(x: 0, y: 0, width: 100, height: 80))).crop, nil, "full-image crop is no crop")
        XCTAssertEqual(doc.applying(.setCrop(CGRect(x: 500, y: 500, width: 10, height: 10))), doc, "off-image crop is ignored")
        XCTAssertEqual(doc.applying(.setCrop(nil)).crop, nil)
    }

    func testOutputScaleIsValidatedAndClamped() {
        let doc = base()
        XCTAssertEqual(doc.applying(.setOutputScale(0.5)).outputScale, 0.5)
        XCTAssertEqual(doc.applying(.setOutputScale(0)), doc)
        XCTAssertEqual(doc.applying(.setOutputScale(.nan)), doc)
        XCTAssertEqual(doc.applying(.setOutputScale(100)).outputScale, 8)
    }

    func testFourRotationsAndDoubleFlipsAreIdentity() {
        var doc = base()
        for _ in 0..<4 { doc = doc.applying(.rotateClockwise) }
        XCTAssertEqual(doc, base())
        var rotated = base().applying(.rotateClockwise)
        let once = rotated.applying(.flipHorizontal)
        rotated = once.applying(.flipHorizontal)
        XCTAssertEqual(rotated, base().applying(.rotateClockwise))
    }

    func testFlipsMirrorTheCurrentOnScreenResultEvenAfterRotating() {
        let image = Fixture.detail(90, 60)
        let (plain, store) = Fixture.document(image)
        for startTurns in 0..<4 {
            var start = plain
            for _ in 0..<startTurns { start = start.applying(.rotateClockwise) }
            let shown = render(start, store)

            let h = render(start.applying(.flipHorizontal), store)
            let v = render(start.applying(.flipVertical), store)
            for (x, y) in [(0, 0), (3, 7), (shown.width - 1, 2), (shown.width / 2, shown.height - 1)] {
                XCTAssertEqual(h[shown.width - 1 - x, y], shown[x, y], "flipH after \(startTurns) turns")
                XCTAssertEqual(v[x, shown.height - 1 - y], shown[x, y], "flipV after \(startTurns) turns")
            }
        }
    }

    func testHistoryUndoRedoRoundTrip() {
        var history = EditHistory(base())
        XCTAssertFalse(history.canUndo); XCTAssertFalse(history.canRedo)
        let a = mark(1)
        history.apply(.add(a))
        history.apply(.rotateClockwise)
        history.apply(.setOutputScale(0.5))
        let final = history.present
        XCTAssertEqual(history.past.count, 3)

        XCTAssertTrue(history.undo()); XCTAssertTrue(history.undo()); XCTAssertTrue(history.undo())
        XCTAssertEqual(history.present, base())
        XCTAssertFalse(history.canUndo); XCTAssertTrue(history.canRedo)
        XCTAssertFalse(history.undo())

        XCTAssertTrue(history.redo()); XCTAssertTrue(history.redo()); XCTAssertTrue(history.redo())
        XCTAssertEqual(history.present, final)
        XCTAssertFalse(history.canRedo)
        XCTAssertFalse(history.redo())
    }

    func testNewEditAfterUndoDropsRedoAndNoOpsDoNotRecord() {
        var history = EditHistory(base())
        history.apply(.rotateClockwise)
        history.apply(.flipVertical)
        history.undo()
        XCTAssertTrue(history.canRedo)
        history.apply(.setOutputScale(2))
        XCTAssertFalse(history.canRedo)

        let count = history.past.count
        history.apply(.setOutputScale(2))
        history.apply(.remove(UUID()))
        XCTAssertEqual(history.past.count, count)
    }

    func testCoalescingFoldsASliderDragIntoOneUndoStep() {
        var history = EditHistory(base())
        for i in 1...20 { history.apply(.setOutputScale(1 + Double(i) * 0.05), coalescing: "scale") }
        XCTAssertEqual(history.present.outputScale, 2, accuracy: 1e-9)
        XCTAssertEqual(history.past.count, 1)
        history.undo()
        XCTAssertEqual(history.present.outputScale, 1)
        history.redo()
        XCTAssertEqual(history.present.outputScale, 2, accuracy: 1e-9)
    }

    func testCoalescingKeysAndBarriers() {
        var history = EditHistory(base())
        history.apply(.setOutputScale(2), coalescing: "scale")
        history.apply(.setOutputScale(3), coalescing: "scale")
        history.apply(.rotateClockwise, coalescing: "other")
        history.apply(.setOutputScale(4), coalescing: "scale")
        XCTAssertEqual(history.past.count, 3, "a different key closes the group")

        history.endCoalescing()
        history.apply(.setOutputScale(5), coalescing: "scale")
        XCTAssertEqual(history.past.count, 4, "endCoalescing starts a new group even with the same key")

        history.undo()
        history.apply(.setOutputScale(6), coalescing: "scale")
        history.apply(.setOutputScale(7), coalescing: "scale")
        XCTAssertEqual(history.past.count, 4, "undo closes the group; the next apply begins one")
    }

    func testCoalescedDragBackToTheStartLeavesNoUndoEntry() {
        var history = EditHistory(base())
        history.apply(.setOutputScale(2), coalescing: "scale")
        history.apply(.setOutputScale(1), coalescing: "scale")
        XCTAssertFalse(history.canUndo)
        XCTAssertEqual(history.present, base())
    }

    func testHistoryLimitDropsOldestSteps() {
        var history = EditHistory(base(), limit: 3)
        for i in 1...6 { history.apply(.setOutputScale(Double(i))) }
        XCTAssertEqual(history.past.count, 3)
        for _ in 0..<5 { history.undo() }
        XCTAssertEqual(history.present.outputScale, 3)
    }
}
