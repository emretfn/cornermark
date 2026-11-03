import CoreGraphics
import ImageIO
import XCTest
@testable import CornermarkCore

final class ExporterAndAssetTests: XCTestCase {
    private func properties(_ data: Data) -> [CFString: Any] {
        let source = CGImageSourceCreateWithData(data as CFData, nil)!
        return CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as! [CFString: Any]
    }

    private func decode(_ data: Data) -> Pixels { Pixels(AssetStore.decode(data)!) }

    func testPNGRoundTripsPixelsAndCarriesDPIFromPointScale() throws {
        var (doc, store) = Fixture.document(Fixture.detail(80, 50), pointScale: 2)
        let data = try Exporter.data(for: doc, assets: store, format: .png)
        XCTAssertEqual(Exporter.dpi(for: doc), 144)
        let props = properties(data)
        XCTAssertEqual(props[kCGImagePropertyPixelWidth] as? Int, 80)
        XCTAssertEqual(props[kCGImagePropertyDPIWidth] as? Double ?? 0, 144, accuracy: 0.5)
        XCTAssertEqual(props[kCGImagePropertyDPIHeight] as? Double ?? 0, 144, accuracy: 0.5)
        XCTAssertEqual(Pixels.changed(decode(data), render(doc, store), inside: .zero).outside, 0, "PNG is lossless")

        doc.outputScale = 0.5
        XCTAssertEqual(Exporter.dpi(for: doc), 72, "halving the pixels at 2x capture gives 1x density")
        let half = try Exporter.data(for: doc, assets: store, format: .png)
        XCTAssertEqual(properties(half)[kCGImagePropertyPixelWidth] as? Int, 40)
        XCTAssertEqual(properties(half)[kCGImagePropertyDPIWidth] as? Double ?? 0, 72, accuracy: 0.5)
    }

    func testJPEGQualityControlsSizeAndTransparencyFlattensToWhite() throws {
        let image = Fixture.randomRows(width: 120, height: 120, seed: 4)
        let high = try Exporter.data(from: image, format: .jpeg, quality: 0.95)
        let low = try Exporter.data(from: image, format: .jpeg, quality: 0.1)
        XCTAssertLessThan(low.count * 2, high.count)
        XCTAssertEqual(properties(high)[kCGImagePropertyPixelWidth] as? Int, 120)
        XCTAssertEqual(properties(high)[kCGImagePropertyDPIWidth] as? Double ?? 0, 72, accuracy: 0.5)

        let clear = Bitmap.makeContext(width: 20, height: 20, yDown: false)!.makeImage()!
        let flat = decode(try Exporter.data(from: clear, format: .jpeg, quality: 1))
        XCTAssertTrue(flat[10, 10].isNear(.white, 3), "transparent pixels become white, not black: \(flat[10, 10])")
    }

    func testTIFFAndHEICEncodeWhenAvailable() throws {
        let image = Fixture.detail(64, 40)
        let tiff = try Exporter.data(from: image, format: .tiff, dpi: 216)
        XCTAssertEqual(properties(tiff)[kCGImagePropertyPixelWidth] as? Int, 64)
        XCTAssertEqual(properties(tiff)[kCGImagePropertyDPIWidth] as? Double ?? 0, 216, accuracy: 0.5)
        if let heic = try? Exporter.data(from: image, format: .heic, quality: 0.8) {
            XCTAssertEqual(properties(heic)[kCGImagePropertyPixelWidth] as? Int, 64)
        }
    }

    func testExportWritesFileThatDecodesToTheRender() throws {
        let (doc, store) = Fixture.document(Fixture.detail(50, 30))
        let url = try tempDirectory().appendingPathComponent("out.png")
        try Exporter.export(doc, assets: store, format: .png, to: url)
        let back = Pixels(AssetStore.decode(try Data(contentsOf: url))!)
        XCTAssertEqual(Pixels.changed(back, render(doc, store), inside: .zero).outside, 0)
    }

    func testAssetStoreKeepsBytesAndCachesDecodedImages() throws {
        let store = AssetStore()
        let png = AssetStore.pngData(from: Fixture.detail(30, 20))!
        let id = store.add(png: png, id: "x")
        XCTAssertEqual(store.data(for: id), png)
        let first = try XCTUnwrap(store.image(for: id))
        XCTAssertTrue(first === store.image(for: id), "decode happens once")
        XCTAssertEqual(store.pixelSize(of: id), CGSize(width: 30, height: 20))
        XCTAssertNil(store.image(for: "nope"))

        store.add(png: AssetStore.pngData(from: Fixture.solid(5, 5, RGBA(1, 0, 0)))!, id: "x")
        XCTAssertEqual(store.pixelSize(of: "x"), CGSize(width: 5, height: 5), "replacing bytes invalidates the cache")

        store.remove("x")
        XCTAssertFalse(store.contains("x"))
        XCTAssertNil(store.image(for: "x"))
    }

    func testAddEncodedNormalizesNonPNGAndLeavesPNGUntouched() throws {
        let store = AssetStore()
        let jpeg = try Exporter.data(from: Fixture.detail(40, 30), format: .jpeg)
        let id = try XCTUnwrap(store.add(encoded: jpeg))
        XCTAssertTrue(AssetStore.isPNG(try XCTUnwrap(store.data(for: id))))
        XCTAssertEqual(store.pixelSize(of: id), CGSize(width: 40, height: 30))

        let png = AssetStore.pngData(from: Fixture.detail(10, 10))!
        let pid = try XCTUnwrap(store.add(encoded: png))
        XCTAssertEqual(store.data(for: pid), png)
        XCTAssertNil(store.add(encoded: Data([1, 2, 3])))
    }

    func testCopyIsIndependent() {
        let a = AssetStore()
        a.add(png: AssetStore.pngData(from: Fixture.solid(4, 4, RGBA(1, 1, 1)))!, id: "a")
        let b = a.copy()
        b.remove("a")
        XCTAssertTrue(a.contains("a"))
    }
}
