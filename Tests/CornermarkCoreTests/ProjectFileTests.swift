import CoreGraphics
import XCTest
@testable import CornermarkCore

final class ProjectFileTests: XCTestCase {
    private func richDocument() -> (Document, AssetStore) {
        let store = AssetStore()
        let base = store.add(image: Fixture.detail(120, 90), id: "base")!
        let patch = store.add(image: Fixture.solid(8, 8, RGBA(0, 0.5, 1)), id: "patch-1")!
        let wall = store.add(image: Fixture.randomRows(width: 16, height: 16, seed: 3), id: "wall_2")!
        var doc = Document(base: base, pixelSize: CGSize(width: 120, height: 90), pointScale: 2)
        doc.annotations = [
            Fixture.annotation(.arrow(from: CGPoint(x: 1.25, y: 2.5), to: CGPoint(x: 100.125, y: 70.0625), control: CGPoint(x: 50.1, y: 3.3), style: .curved)),
            Fixture.annotation(.pixelate(CGRect(x: 10, y: 10, width: 40, height: 30), blockSize: 6, seed: UInt64.max)),
            Fixture.annotation(.text(origin: CGPoint(x: 5, y: 60), string: "héllo \u{1F600}\nline2", fontSize: 14.5, style: .pill)),
            Fixture.annotation(.image(CGRect(x: 60, y: 10, width: 30, height: 30), asset: patch)),
            Fixture.annotation(.pencil(points: [CGPoint(x: 0.1, y: 0.2), CGPoint(x: 1.0 / 3.0, y: 2.0 / 3.0)])),
            Fixture.annotation(.blur(CGRect(x: 0, y: 0, width: 20, height: 20), mode: .secure)),
        ]
        doc.crop = CGRect(x: 4, y: 3, width: 100, height: 80)
        doc.geometry.quarterTurns = 3; doc.geometry.flipH = true
        doc.outputScale = 1.5
        var bg = BackgroundStyle()
        bg.fill = .image(asset: wall); bg.padding = 33.3; bg.aspectRatio = 16.0 / 9.0; bg.autoBalance = true
        doc.background = bg
        return (doc, store)
    }

    func testRoundTripIsExactForDocumentAndAssetBytes() throws {
        let (doc, store) = richDocument()
        let dir = try tempDirectory().appendingPathComponent("shot.cornermark", isDirectory: true)
        try ProjectFile.write(doc, assets: store, to: dir)

        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("project.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("assets/patch-1.png").path))

        let (back, backStore) = try ProjectFile.read(from: dir)
        XCTAssertEqual(back, doc)
        XCTAssertEqual(Set(backStore.ids), doc.referencedAssets)
        for id in doc.referencedAssets {
            XCTAssertEqual(backStore.data(for: id), store.data(for: id), "asset \(id) bytes changed")
        }
        let a = render(doc, store), b = render(back, backStore)
        XCTAssertEqual(Pixels.changed(a, b, inside: .zero).outside, 0)
    }

    func testRewriteIsIdempotentAndDropsAssetsNoLongerReferenced() throws {
        var (doc, store) = richDocument()
        let dir = try tempDirectory()
        try ProjectFile.write(doc, assets: store, to: dir)
        try ProjectFile.write(doc, assets: store, to: dir)
        XCTAssertEqual(try ProjectFile.read(from: dir).document, doc)

        doc.annotations.removeAll { if case .image = $0.kind { return true }; return false }
        try ProjectFile.write(doc, assets: store, to: dir)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("assets/patch-1.png").path))
        XCTAssertEqual(try ProjectFile.read(from: dir).document, doc)
    }

    func testWritingBesideOtherFilesLeavesThemAlone() throws {
        let (doc, store) = richDocument()
        let dir = try tempDirectory()
        let sibling = dir.appendingPathComponent("image.png")
        try Data([1, 2, 3]).write(to: sibling)
        try ProjectFile.write(doc, assets: store, to: dir)
        XCTAssertEqual(try Data(contentsOf: sibling), Data([1, 2, 3]))
    }

    func testMissingAssetsAndBadInputsThrow() throws {
        let (doc, store) = richDocument()
        let empty = AssetStore()
        let dir = try tempDirectory()
        XCTAssertThrowsError(try ProjectFile.write(doc, assets: empty, to: dir)) {
            guard case ProjectFileError.missingAsset = $0 else { return XCTFail("\($0)") }
        }

        try ProjectFile.write(doc, assets: store, to: dir)
        try FileManager.default.removeItem(at: dir.appendingPathComponent("assets/patch-1.png"))
        XCTAssertThrowsError(try ProjectFile.read(from: dir)) { XCTAssertEqual($0 as? ProjectFileError, .missingAsset("patch-1")) }

        XCTAssertThrowsError(try ProjectFile.read(from: try tempDirectory())) {
            guard case ProjectFileError.notAProject = $0 else { return XCTFail("\($0)") }
        }

        var hostile = doc
        hostile.base = "../../escape"
        XCTAssertThrowsError(try ProjectFile.write(hostile, assets: store, to: try tempDirectory())) {
            XCTAssertEqual($0 as? ProjectFileError, .invalidAssetID("../../escape"))
        }
    }
}
