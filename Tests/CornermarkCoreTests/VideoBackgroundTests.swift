import XCTest
@testable import CornermarkCore

final class VideoBackgroundTests: XCTestCase {
    private func project(_ background: VideoBackground = VideoBackground()) -> RecordingProject {
        var p = RecordingProject(source: .init(pixelWidth: 1280, pixelHeight: 720, pointWidth: 640, pointHeight: 360, fps: 60, duration: 2))
        p.edits.background = background
        return p
    }

    func testWithoutAFillTheRecordingIsTheWholeVideo() {
        let canvas = project(VideoBackground(fill: .none, padding: 120, shadow: 80, cornerRadius: 30)).canvas
        XCTAssertEqual(canvas.size, CGSize(width: 640, height: 360))
        XCTAssertEqual(canvas.frame, CGRect(x: 0, y: 0, width: 640, height: 360))
        XCTAssertEqual(canvas.cornerRadius, 0)
        XCTAssertFalse(canvas.hasBackdrop)
        let plan = ExportPlan(project: project(), settings: ExportSettings())
        XCTAssertEqual([plan.width, plan.height], [1280, 720])
    }

    func testPaddingGrowsTheVideoOnEverySide() {
        let canvas = project(VideoBackground(fill: .gradient(index: 0), padding: 40)).canvas
        XCTAssertEqual(canvas.size, CGSize(width: 720, height: 440))
        XCTAssertEqual(canvas.frame, CGRect(x: 40, y: 40, width: 640, height: 360))
        let plan = ExportPlan(project: project(VideoBackground(fill: .gradient(index: 0), padding: 40)), settings: ExportSettings())
        XCTAssertEqual([plan.width, plan.height], [1440, 880])
    }

    func testSmallerSizesAreNamedByTheCanvasShortSide() {
        let p = project(VideoBackground(fill: .solid(color: RGBA(1, 1, 1)), padding: 100))
        XCTAssertEqual(ExportResolution.choices(for: p), [.original, .shortSide(1080), .shortSide(720), .shortSide(480)])
        let plan = ExportPlan(project: p, settings: ExportSettings(resolution: .shortSide(720)))
        XCTAssertEqual([plan.width, plan.height], [1080, 720])
    }

    func testOutOfRangeSettingsAreClamped() {
        let canvas = project(VideoBackground(fill: .gradient(index: 0), padding: 999, shadow: 500, cornerRadius: 900)).canvas
        XCTAssertEqual(canvas.frame.minX, VideoBackground.paddingRange.upperBound)
        XCTAssertEqual(canvas.shadow, 1)
        XCTAssertEqual(canvas.cornerRadius, VideoBackground.cornerRange.upperBound)
    }

    func testABackgroundBarelyGrowsTheEstimate() {
        let plain = ExportPlan(project: project(), settings: ExportSettings(), sourceBytes: 1_000_000)
        let framed = ExportPlan(project: project(VideoBackground(fill: .gradient(index: 0), padding: 100)), settings: ExportSettings(), sourceBytes: 1_000_000)
        XCTAssertEqual(plain.estimatedBytes, framed.estimatedBytes, accuracy: 1)
        XCTAssertGreaterThan(framed.bitRate, plain.bitRate)
    }

    func testAProjectWithoutABackgroundDecodesToNone() throws {
        let json = #"{"version":1,"edits":{"cursor":{"isVisible":true,"scale":1}}}"#
        let p = try JSONDecoder().decode(RecordingProject.self, from: Data(json.utf8))
        XCTAssertEqual(p.edits.background, VideoBackground())
        XCTAssertEqual(p.edits.background.fill, .none)
    }

    func testABackgroundSurvivesTheProjectFile() throws {
        let bg = VideoBackground(fill: .wallpaper(index: 6), padding: 32, shadow: 10, cornerRadius: 8, image: "background-1.png")
        let data = try JSONEncoder().encode(project(bg))
        XCTAssertEqual(try JSONDecoder().decode(RecordingProject.self, from: data).edits.background, bg)
    }

    func testTheBackdropPaintsTheFillAndTheShadowUnderTheFrame() throws {
        let canvas = project(VideoBackground(fill: .solid(color: RGBA(1, 1, 1)), padding: 40, shadow: 100, cornerRadius: 0)).canvas
        let image = try XCTUnwrap(VideoBackdrop.image(canvas, width: 720, height: 440, picture: nil))
        let pixels = try XCTUnwrap(PixelBuffer(image: image))
        func gray(_ x: Int, _ y: Int) -> Int { Int(pixels.bytes[(y * pixels.width + x) * 4]) }
        XCTAssertEqual(gray(2, 2), 255, "the fill reaches the corners")
        XCTAssertLessThan(gray(360, 420), 200, "the shadow falls below the frame")
        XCTAssertLessThan(gray(360, 420), gray(360, 20), "and is darker below than above, since it falls down")
        XCTAssertNil(VideoBackdrop.image(project().canvas, width: 10, height: 10, picture: nil))
    }
}
