import XCTest
@testable import CornermarkCore

final class DocumentTests: XCTestCase {
    func testDocumentRoundTripsThroughJSON() throws {
        var doc = Document(base: "base", pixelSize: CGSize(width: 10, height: 10), pointScale: 2)
        doc.annotations = [Annotation(kind: .counter(center: .zero, number: 1, radius: 8), stroke: Stroke(color: RGBA(1, 0, 0), width: 2))]
        let copy = try JSONDecoder().decode(Document.self, from: JSONEncoder().encode(doc))
        XCTAssertEqual(copy, doc)
    }
}
