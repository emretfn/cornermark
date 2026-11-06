import CoreGraphics
import XCTest
@testable import CornermarkCore

final class AfterRecordingEditsTests: XCTestCase {
    let area = CGSize(width: 1280, height: 720)

    func testTheGridRunsRowByRowAndPlacesOnTheMarginOrTheCentre() {
        XCTAssertEqual(GridPosition.allCases.map { "\($0.column)\($0.row)" }, ["00", "10", "20", "01", "11", "21", "02", "12", "22"])
        let box = CGSize(width: 100, height: 40)
        XCTAssertEqual(GridPosition.topLeft.place(box, in: area, margin: 10), CGRect(x: 10, y: 10, width: 100, height: 40))
        XCTAssertEqual(GridPosition.center.place(box, in: area, margin: 10), CGRect(x: 590, y: 340, width: 100, height: 40))
        XCTAssertEqual(GridPosition.bottomRight.place(box, in: area, margin: 10), CGRect(x: 1170, y: 670, width: 100, height: 40))
        for p in GridPosition.allCases { XCTAssertEqual(GridPosition(column: p.column, row: p.row), p) }
    }

    func testTheKeystrokeBadgeTakesEveryCellAndOldFilesKeepTheirPlace() throws {
        var frames: [CGRect] = []
        for p in GridPosition.allCases {
            let k = KeystrokeDisplay(isVisible: true, position: p)
            let f = InputOverlayPainter.badgeFrame(text: "⌘K", area: area, k)
            XCTAssertTrue(CGRect(origin: .zero, size: area).contains(f), "\(p)")
            frames.append(f)
        }
        XCTAssertEqual(Set(frames.map { "\($0.minX),\($0.minY)" }).count, 9, "nine different places")
        let old = try JSONDecoder().decode(KeystrokeDisplay.self, from: Data(#"{"position":"topCenter","isVisible":true}"#.utf8))
        XCTAssertEqual(old.position, .topCenter)
    }

    func testAudioLevelsDecodeToFullAndMixOnlyTheTracksThatPlay() throws {
        let old = try JSONDecoder().decode(RecordingProject.self, from: Data(#"{"source":{"microphone":"mic.m4a","systemAudio":"system.m4a"},"edits":{}}"#.utf8))
        XCTAssertEqual(old.edits.audio, AudioEdits())
        XCTAssertEqual(old.audioMix.map(\.file), ["mic.m4a", "system.m4a"])
        XCTAssertEqual(old.audioMix.map(\.gain), [1, 1])

        var project = old
        project.edits.audio.microphone = AudioTrackLevel(isOn: true, level: 0.5)
        project.edits.audio.systemAudio.isOn = false
        XCTAssertEqual(project.audioMix.map(\.track), [.microphone])
        XCTAssertEqual(project.audioMix.first?.gain, 0.5)
        XCTAssertEqual(try JSONDecoder().decode(RecordingProject.self, from: JSONEncoder().encode(project)), project)

        project.edits.audio.microphone.level = 3
        XCTAssertEqual(project.audioMix.first?.gain, 1, "a level past the range plays at full")
        project.edits.audio.microphone.level = 0
        XCTAssertTrue(project.audioMix.isEmpty, "a track at zero is left out of the mix")

        let damaged = try JSONDecoder().decode(AudioEdits.self, from: Data(#"{"microphone":{"level":"loud","isOn":false}}"#.utf8))
        XCTAssertEqual(damaged.microphone, AudioTrackLevel(isOn: false, level: 1))
        XCTAssertEqual(damaged.systemAudio, AudioTrackLevel())

        var silent = RecordingProject()
        silent.source.systemAudio = "system.m4a"
        XCTAssertEqual(silent.source.audioTracks, [.systemAudio])
    }

    func testTheFrameCarriesTheBadgeOnlyWhileShownAndForTheChosenKeys() {
        var project = RecordingProject(source: RecordingProject.Source(pointWidth: 1280, pointHeight: 720, duration: 10))
        project.events = RecordingProject.Events(keys: [KeyEvent(t: 1, label: "a", isCommand: false), KeyEvent(t: 4, label: "⌘S", isCommand: true)])
        XCTAssertNil(frameState(project, outputTime: 1.2).input.badge, "hidden by default")
        project.edits.keystrokes = KeystrokeDisplay(isVisible: true, keys: .all)
        XCTAssertEqual(frameState(project, outputTime: 1.2).input.badge?.text, "a")
        project.edits.keystrokes.keys = .shortcuts
        XCTAssertNil(frameState(project, outputTime: 1.2).input.badge, "typing is left out with shortcuts only")
        XCTAssertEqual(frameState(project, outputTime: 4.2).input.badge?.text, "⌘S")
    }

    func testAZoomMovesTheBadgeWithTheRecordingAndLeavesTheCameraInTheFrame() {
        var project = RecordingProject(source: RecordingProject.Source(pointWidth: 1280, pointHeight: 720, duration: 10))
        project.source.camera = "camera.mov"
        project.events = RecordingProject.Events(keys: [KeyEvent(t: 4, label: "⌘S", isCommand: true)])
        project.edits.keystrokes = KeystrokeDisplay(isVisible: true, keys: .shortcuts, position: .bottomRight)
        let plain = frameState(project, outputTime: 4.2)
        XCTAssertEqual(plain.crop, .full)
        project.edits.zooms = [Zoom(start: 3, end: 6, scale: 2, mode: .manual, center: ZoomPoint(x: 0.25, y: 0.25))]
        let zoomed = frameState(project, outputTime: 4.2)
        XCTAssertLessThan(zoomed.crop.width, 1, "the zoom crops the recording")
        XCTAssertEqual(zoomed.input, plain.input, "the badge is in the recording's points, so the renderers apply the crop to it as they do to the pointer")
        XCTAssertEqual(zoomed.camera, plain.camera, "the bubble is an overlay on the frame and ignores the crop")
        let badge = InputOverlayPainter.badgeFrame(text: "⌘S", area: area, project.edits.keystrokes)
        let (fx, fy) = (badge.midX / area.width, badge.midY / area.height)
        let crop = zoomed.crop
        XCTAssertFalse(fx >= crop.x && fx <= crop.x + crop.width && fy >= crop.y && fy <= crop.y + crop.height,
                       "a badge in the corner the crop leaves out is out of the zoomed picture")
    }
}
