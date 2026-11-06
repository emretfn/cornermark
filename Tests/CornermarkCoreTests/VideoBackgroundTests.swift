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

    func testAutoKeepsTheShapeTheRecordingAndPaddingGive() {
        XCTAssertEqual(project(VideoBackground(fill: .gradient(index: 0), padding: 40, aspect: .auto)).canvas,
                       project(VideoBackground(fill: .gradient(index: 0), padding: 40)).canvas)
        XCTAssertNil(VideoAspect.auto.value)
    }

    func testARatioGrowsTheVideoAroundThePaddedRecordingAndCentresIt() {
        let square = project(VideoBackground(fill: .gradient(index: 0), padding: 40, aspect: .ratio(width: 1, height: 1))).canvas
        XCTAssertEqual(square.size, CGSize(width: 720, height: 720))
        XCTAssertEqual(square.frame, CGRect(x: 40, y: 180, width: 640, height: 360))
        let tall = project(VideoBackground(fill: .gradient(index: 0), padding: 40, aspect: .ratio(width: 9, height: 16))).canvas
        XCTAssertEqual(tall.size, CGSize(width: 720, height: 1280))
        XCTAssertEqual(tall.frame, CGRect(x: 40, y: 460, width: 640, height: 360))
        let wide = project(VideoBackground(fill: .gradient(index: 0), padding: 0, aspect: .ratio(width: 16, height: 9))).canvas
        XCTAssertEqual(wide.size, CGSize(width: 640, height: 360), "a recording already at the ratio gains nothing")
    }

    func testWithoutAFillARatioPutsBlackBarsBesideTheRecording() {
        let canvas = project(VideoBackground(fill: .none, padding: 120, shadow: 80, cornerRadius: 30, aspect: .ratio(width: 9, height: 16))).canvas
        XCTAssertEqual(canvas.size, CGSize(width: 640, height: 1138), "padding still does nothing")
        XCTAssertEqual(canvas.frame, CGRect(x: 0, y: 389, width: 640, height: 360))
        XCTAssertEqual(canvas.cornerRadius, 0)
        XCTAssertEqual(canvas.shadow, 0)
        XCTAssertFalse(canvas.hasBackdrop, "nothing is painted: export's black shows through")
    }

    func testExportSizesFollowTheShapeExactly() {
        let tall = project(VideoBackground(fill: .gradient(index: 0), padding: 64, aspect: .ratio(width: 9, height: 16)))
        XCTAssertEqual(ExportResolution.choices(for: tall), [.original, .shortSide(1440), .shortSide(1080), .shortSide(720), .shortSide(480)])
        let p1080 = ExportPlan(project: tall, settings: ExportSettings(resolution: .shortSide(1080)))
        XCTAssertEqual([p1080.width, p1080.height], [1080, 1920])
        let square = ExportPlan(project: project(VideoBackground(fill: .none, aspect: .ratio(width: 1, height: 1))), settings: ExportSettings())
        XCTAssertEqual([square.width, square.height], [1280, 1280])
        let portrait = ExportPlan(project: project(VideoBackground(fill: .solid(color: RGBA(1, 1, 1)), aspect: .ratio(width: 4, height: 5))),
                                  settings: ExportSettings(resolution: .shortSide(1080)))
        XCTAssertEqual([portrait.width, portrait.height], [1080, 1350])
    }

    func testBarsAndBackgroundAroundTheRecordingBarelyGrowTheEstimate() {
        let plain = ExportPlan(project: project(), settings: ExportSettings(), sourceBytes: 1_000_000)
        let tall = ExportPlan(project: project(VideoBackground(fill: .none, aspect: .ratio(width: 9, height: 16))), settings: ExportSettings(), sourceBytes: 1_000_000)
        XCTAssertEqual(plain.estimatedBytes, tall.estimatedBytes, accuracy: 1_000_000 / 100)
    }

    func testCustomKeepsSidesAndShapeInRange() {
        XCTAssertEqual(VideoAspect.custom(1080, 1350), .custom(width: 1080, height: 1350))
        XCTAssertEqual(VideoAspect.custom(1080, 1350).value, 0.8)
        XCTAssertEqual(VideoAspect.custom(0, -5), .custom(width: 1, height: 1))
        XCTAssertEqual(VideoAspect.custom(100, 1), .custom(width: 100, height: 25))
        XCTAssertEqual(VideoAspect.custom(1, 100), .custom(width: 25, height: 100))
        XCTAssertEqual(VideoAspect.custom(width: 1, height: 1000).value, VideoAspect.limit.lowerBound, "a damaged file is held to the limit too")
        XCTAssertEqual(VideoAspect.presets.map(\.title), ["Auto", "1:1", "5:4", "4:3", "3:2", "16:9", "4:5", "3:4", "9:16"])
    }

    func testTheShapeSurvivesTheProjectFileAndOlderFilesAreAuto() throws {
        for aspect in [VideoAspect.auto, .ratio(width: 9, height: 16), .custom(width: 1080, height: 1350)] {
            let bg = VideoBackground(fill: .gradient(index: 2), aspect: aspect)
            XCTAssertEqual(try JSONDecoder().decode(RecordingProject.self, from: JSONEncoder().encode(project(bg))).edits.background.aspect, aspect)
        }
        let json = #"{"version":1,"edits":{"background":{"fill":{"gradient":{"index":2}},"padding":10}}}"#
        XCTAssertEqual(try JSONDecoder().decode(RecordingProject.self, from: Data(json.utf8)).edits.background.aspect, .auto)
    }
}
