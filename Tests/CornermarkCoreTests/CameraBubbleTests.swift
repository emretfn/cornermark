import CoreGraphics
import XCTest
@testable import CornermarkCore

final class CameraBubbleTests: XCTestCase {
    let area = CGSize(width: 1280, height: 720)

    func testEveryCellKeepsTheMarginFromTheEdgesItTouchesAndCentresOnTheOthers() {
        let m = CameraLayout.margin(area: area)
        for position in GridPosition.allCases {
            let r = CameraLayout.bubbleRect(CameraBubble(position: position), area: area)
            switch position.column {
            case 0: XCTAssertEqual(r.minX, m, "\(position)")
            case 1: XCTAssertEqual(r.midX, area.width / 2, accuracy: 0.5, "\(position)")
            default: XCTAssertEqual(area.width - r.maxX, m, "\(position)")
            }
            switch position.row {
            case 0: XCTAssertEqual(r.minY, m, "\(position)")
            case 1: XCTAssertEqual(r.midY, area.height / 2, accuracy: 0.5, "\(position)")
            default: XCTAssertEqual(area.height - r.maxY, m, "\(position)")
            }
        }
    }

    func testAFileFromBeforeTheGridKeepsItsCorner() throws {
        let old = try JSONDecoder().decode(CameraBubble.self, from: Data(#"{"corner":"topRight","shape":"square"}"#.utf8))
        XCTAssertEqual(old.position, .topRight)
        XCTAssertEqual(old.shape, .square)
        let centred = CameraBubble(position: .center)
        let encoded = String(decoding: try JSONEncoder().encode(centred), as: UTF8.self)
        XCTAssertTrue(encoded.contains(#""position":"center""#), encoded)
        XCTAssertEqual(try JSONDecoder().decode(CameraBubble.self, from: Data(encoded.utf8)), centred)
    }

    func testShapesAndSizes() {
        let circle = CameraLayout.bubbleRect(CameraBubble(shape: .circle, size: .medium), area: area)
        XCTAssertEqual(circle.height, (720 * 0.3).rounded())
        XCTAssertEqual(circle.width, circle.height)
        XCTAssertEqual(CameraLayout.cornerRadius(.circle, rect: circle), circle.height / 2)
        let square = CameraLayout.bubbleRect(CameraBubble(shape: .square, size: .medium), area: area)
        XCTAssertEqual(square.size, circle.size)
        XCTAssertLessThan(CameraLayout.cornerRadius(.square, rect: square), square.height / 2)
        let rectangle = CameraLayout.bubbleRect(CameraBubble(shape: .rectangle, size: .medium), area: area)
        XCTAssertEqual(rectangle.width, (rectangle.height * 4 / 3).rounded())
        let sizes = CameraBubble.Size.allCases.map { CameraLayout.bubbleRect(CameraBubble(size: $0), area: area).height }
        XCTAssertEqual(sizes, sizes.sorted())
        XCTAssertEqual(Set(sizes).count, 3)
    }

    func testFullScreenGrowsAndShrinksOverTheTransition() {
        let spans = [CameraSpan(from: 1, to: 3)]
        XCTAssertEqual(CameraLayout.fullScreenAmount(spans, at: 0.99), 0)
        XCTAssertEqual(CameraLayout.fullScreenAmount(spans, at: 1 + CameraLayout.transition / 2), 0.5, accuracy: 1e-9)
        XCTAssertEqual(CameraLayout.fullScreenAmount(spans, at: 2), 1)
        XCTAssertEqual(CameraLayout.fullScreenAmount(spans, at: 3 + CameraLayout.transition), 0)
        let full = CameraLayout.frame(CameraBubble(fullScreen: spans), area: area, at: 2)
        XCTAssertEqual(full?.rect, CGRect(origin: .zero, size: area))
        XCTAssertEqual(full?.cornerRadius, 0)
        var last = 0.0
        for k in 0...30 {
            let a = CameraLayout.fullScreenAmount(spans, at: 1 + Double(k) * 0.01)
            XCTAssertGreaterThanOrEqual(a, last)
            last = a
        }
    }

    func testAHiddenCameraOrAProjectWithoutOneHasNoCameraFrame() {
        XCTAssertNil(CameraLayout.frame(CameraBubble(isVisible: false), area: area, at: 0))
        var project = RecordingProject(source: .init(pointWidth: 1280, pointHeight: 720, duration: 2))
        XCTAssertNil(frameState(project, outputTime: 1).camera)
        project.source.camera = RecordingProjectFile.cameraName
        XCTAssertEqual(frameState(project, outputTime: 1).camera?.rect, CameraLayout.bubbleRect(CameraBubble(), area: area))
        project.edits.camera.isVisible = false
        XCTAssertNil(frameState(project, outputTime: 1).camera)
    }

    func testOlderProjectsAndDamagedFieldsDecodeToDefaults() throws {
        let old = try JSONDecoder().decode(RecordingProject.self, from: Data(#"{"source":{"video":"screen.mp4"},"edits":{}}"#.utf8))
        XCTAssertNil(old.source.camera)
        XCTAssertEqual(old.edits.camera, CameraBubble())
        let damaged = try JSONDecoder().decode(CameraBubble.self, from: Data(#"{"shape":"hexagon","isMirrored":false,"fullScreen":[{"from":2,"to":1},{"from":0,"to":1}]}"#.utf8))
        XCTAssertEqual(damaged.shape, .circle)
        XCTAssertFalse(damaged.isMirrored)
        XCTAssertEqual(damaged.fullScreen, [CameraSpan(from: 0, to: 1)])
        var project = RecordingProject()
        project.source.camera = "camera.mp4"
        project.edits.camera = CameraBubble(shape: .rectangle, position: .topRight, fullScreen: [CameraSpan(from: 1, to: 2)])
        XCTAssertEqual(try JSONDecoder().decode(RecordingProject.self, from: JSONEncoder().encode(project)), project)
    }

    func testTheNearestCornerFollowsTheQuarterTheCentreIsIn() {
        XCTAssertEqual(GridPosition.corner(nearest: CGPoint(x: 100, y: 100), area: area), .topLeft)
        XCTAssertEqual(GridPosition.corner(nearest: CGPoint(x: 1000, y: 100), area: area), .topRight)
        XCTAssertEqual(GridPosition.corner(nearest: CGPoint(x: 100, y: 600), area: area), .bottomLeft)
        XCTAssertEqual(GridPosition.corner(nearest: CGPoint(x: 1000, y: 600), area: area), .bottomRight)
    }

    func testThePainterMirrorsAndClipsToTheShape() throws {
        // A camera picture red on its left half and blue on its right.
        let src = CGContext(data: nil, width: 40, height: 20, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        src.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)); src.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        src.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)); src.fill(CGRect(x: 20, y: 0, width: 20, height: 20))
        let image = try XCTUnwrap(src.makeImage())
        func render(mirrored: Bool) -> (left: [UInt8], right: [UInt8], corner: [UInt8]) {
            var px = [UInt8](repeating: 0, count: 100 * 100 * 4)
            let ctx = CGContext(data: &px, width: 100, height: 100, bitsPerComponent: 8, bytesPerRow: 400, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.translateBy(x: 0, y: 100); ctx.scaleBy(x: 1, y: -1)
            CameraBubblePainter.draw(image, CameraFrame(rect: CGRect(x: 0, y: 0, width: 100, height: 100), cornerRadius: 50, isMirrored: mirrored, fill: 0), in: ctx)
            func at(_ x: Int, _ y: Int) -> [UInt8] { Array(px[(y * 100 + x) * 4..<(y * 100 + x) * 4 + 3]) }
            return (at(25, 50), at(75, 50), at(2, 2))
        }
        let plain = render(mirrored: false), mirrored = render(mirrored: true)
        XCTAssertGreaterThan(plain.left[0], 200); XCTAssertGreaterThan(plain.right[2], 200)
        XCTAssertGreaterThan(mirrored.left[2], 200); XCTAssertGreaterThan(mirrored.right[0], 200)
        XCTAssertLessThan(Int(plain.corner[0]) + Int(plain.corner[2]), 60, "outside the circle stays undrawn")
    }
}
