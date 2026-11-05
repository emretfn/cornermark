import XCTest
@testable import CornermarkCore

final class VideoExportPlanTests: XCTestCase {
    private func project(width: Int = 1280, height: Int = 720, fps: Int = 60, duration: Double = 2) -> RecordingProject {
        RecordingProject(source: .init(pixelWidth: width, pixelHeight: height, pointWidth: Double(width) / 2, pointHeight: Double(height) / 2,
                                       fps: fps, duration: duration))
    }

    func testOriginalKeepsTheRecordingsPixels() {
        let plan = ExportPlan(project: project(), settings: ExportSettings())
        XCTAssertEqual([plan.width, plan.height, plan.fps], [1280, 720, 60])
    }

    func testTheVideoIsAsLongAsTheProjectToTheFrame() {
        for duration in [2.0, 1.234, 0.01, 12.991] {
            let plan = ExportPlan(project: project(duration: duration), settings: ExportSettings())
            XCTAssertEqual(plan.duration, duration, accuracy: 0.5 / 60 + 1e-9, "duration \(duration)")
        }
        XCTAssertEqual(ExportPlan(project: project(duration: 2), settings: ExportSettings()).frameCount, 120)
        XCTAssertEqual(ExportPlan(project: project(duration: 0), settings: ExportSettings()).frameCount, 1, "an empty project still writes a frame")
    }

    func testASizeIsNamedByItsShortSideAndNeverEnlarges() {
        let wide = ExportPlan(project: project(width: 2560, height: 1440), settings: ExportSettings(resolution: .shortSide(1080)))
        XCTAssertEqual([wide.width, wide.height], [1920, 1080])
        let tall = ExportPlan(project: project(width: 1440, height: 2560), settings: ExportSettings(resolution: .shortSide(720)))
        XCTAssertEqual([tall.width, tall.height], [720, 1280])
        let small = ExportPlan(project: project(width: 640, height: 360), settings: ExportSettings(resolution: .shortSide(1080)))
        XCTAssertEqual([small.width, small.height], [640, 360])
    }

    func testSidesAreEven() {
        let plan = ExportPlan(project: project(width: 1001, height: 563), settings: ExportSettings(resolution: .shortSide(480)))
        XCTAssertEqual(plan.width % 2, 0)
        XCTAssertEqual(plan.height % 2, 0)
        XCTAssertEqual(plan.height, 480)
    }

    func testChoicesOfferOnlySmallerSizes() {
        XCTAssertEqual(ExportResolution.choices(for: project().source), [.original, .shortSide(480)])
        XCTAssertEqual(ExportResolution.choices(for: project(width: 3840, height: 2160).source), [.original, .shortSide(1440), .shortSide(1080), .shortSide(720), .shortSide(480)])
    }

    func testHigherQualityAndSizeCostMoreBytes() {
        let p = project(width: 1920, height: 1080, duration: 10)
        let sizes = ExportQuality.allCases.map { ExportPlan(project: p, settings: ExportSettings(quality: $0)).estimatedBytes }
        XCTAssertEqual(sizes, sizes.sorted())
        XCTAssertEqual(Set(sizes).count, 3)
        let smaller = ExportPlan(project: p, settings: ExportSettings(resolution: .shortSide(720))).estimatedBytes
        XCTAssertLessThan(smaller, ExportPlan(project: p, settings: ExportSettings()).estimatedBytes)
    }

    func testTheEstimateFollowsTheBitRate() {
        let plan = ExportPlan(project: project(duration: 4), settings: ExportSettings(quality: .medium))
        XCTAssertEqual(plan.bitRate, Int(1280 * 720 * 60 * 0.1))
        XCTAssertEqual(plan.estimatedBytes, Int64(Double(plan.bitRate) * 4 / 8), "with no source size the estimate is the bit rate's ceiling")
    }

    func testTheRecordingsOwnSizeSaysWhatAStillPictureNeeds() {
        let p = project(duration: 4)
        let original = ExportPlan(project: p, settings: ExportSettings(), sourceBytes: 400_000)
        XCTAssertEqual(original.estimatedBytes, 400_000, "the same pictures at the same size need what the recording needed")
        let low = ExportPlan(project: p, settings: ExportSettings(quality: .low), sourceBytes: 400_000)
        XCTAssertEqual(low.estimatedBytes, 400_000, "a still picture under every cap costs the same at any quality")
        let smaller = ExportPlan(project: p, settings: ExportSettings(resolution: .shortSide(480)), sourceBytes: 400_000)
        XCTAssertEqual(Double(smaller.estimatedBytes), 400_000 * (854.0 * 480 / (1280 * 720)).squareRoot(), accuracy: 1)
        let busy = ExportPlan(project: p, settings: ExportSettings(quality: .low), sourceBytes: 50_000_000)
        XCTAssertEqual(busy.estimatedBytes, Int64(Double(busy.bitRate) * 4 / 8), "a busy picture is capped by the bit rate")
    }
}
