import XCTest
@testable import CornermarkCore

final class AudioLevelTests: XCTestCase {
    func testMeasureTakesEveryChannel() {
        let level = AudioLevel.measure([[0.5, -0.5], [0, 0]])
        XCTAssertEqual(level.peak, 0.5)
        XCTAssertEqual(level.rms, Float((0.5 * 0.5 / 2).squareRoot()), accuracy: 1e-6)
        XCTAssertEqual(AudioLevel.measure([]), .silence)
    }

    func testMeterUsesDecibels() {
        XCTAssertEqual(AudioLevel(rms: 1, peak: 1).meterFraction(), 1)
        XCTAssertEqual(AudioLevel(rms: 0.001, peak: 0.001).meterFraction(), 0, accuracy: 1e-6, "-60 dBFS is the floor")
        XCTAssertEqual(AudioLevel(rms: 0.0316, peak: 0.0316).meterFraction(), 0.5, accuracy: 0.01, "-30 dBFS is half way")
        XCTAssertEqual(AudioLevel.silence.meterFraction(), 0)
    }

    func testSilenceNeedsThreeQuietSeconds() {
        var s = MicrophoneSilence(start: 10)
        XCTAssertFalse(s.isSilent(at: 12.9))
        XCTAssertTrue(s.isSilent(at: 13), "nothing heard since the start")
        s.hear(AudioLevel(rms: 0.001, peak: 0.002), until: 13.1)
        XCTAssertFalse(s.isSilent(at: 13.2), "room noise at -54 dBFS is sound")
        s.hear(AudioLevel(rms: 0.00001, peak: 0.00005), until: 16)
        XCTAssertFalse(s.isSilent(at: 16.0))
        XCTAssertTrue(s.isSilent(at: 16.1), "under -80 dBFS for 3 s counts as silent")
        s.restart(at: 20)
        XCTAssertFalse(s.isSilent(at: 22.9), "a resume starts the wait over")
    }

    func testProjectNamesItsSoundTracks() throws {
        let p = try JSONDecoder().decode(RecordingProject.self, from: Data(#"{"source": {"microphone": "mic.m4a", "systemAudio": 3}}"#.utf8))
        XCTAssertEqual(p.source.microphone, "mic.m4a")
        XCTAssertNil(p.source.systemAudio, "a damaged name costs only that track")
        XCTAssertEqual(p.source.audioFiles, ["mic.m4a"])
        XCTAssertEqual(RecordingProject().source.audioFiles, [], "a project without sound has no tracks")
        var q = RecordingProject()
        q.source.microphone = RecordingProjectFile.microphoneName
        q.source.systemAudio = RecordingProjectFile.systemAudioName
        XCTAssertEqual(try JSONDecoder().decode(RecordingProject.self, from: JSONEncoder().encode(q)), q)
    }
}
