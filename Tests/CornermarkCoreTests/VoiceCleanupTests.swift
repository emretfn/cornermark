import XCTest
@testable import CornermarkCore

final class VoiceCleanupTests: XCTestCase {
    private func decode(_ json: String) throws -> RecordingProject {
        try JSONDecoder().decode(RecordingProject.self, from: Data(json.utf8))
    }

    func testAProjectWithoutVoiceCleanupDecodesToOff() throws {
        let p = try decode(#"{"source":{"microphone":"mic.m4a"},"edits":{"audio":{"microphone":{"level":0.5}}}}"#)
        XCTAssertFalse(p.edits.audio.voiceCleanup.isOn)
        XCTAssertFalse(try decode("{}").edits.audio.voiceCleanup.isOn)
    }

    func testANewRecordingWithAMicrophoneStartsWithVoiceCleanupOnAtTheDefaults() {
        let withMic = RecordingProject.newRecording(source: .init(duration: 3, microphone: "mic.m4a", systemAudio: "system.m4a"))
        let cleanup = withMic.edits.audio.voiceCleanup
        XCTAssertTrue(cleanup.isOn)
        XCTAssertTrue(cleanup.lowCutOn)
        XCTAssertEqual(cleanup.lowCutFrequency, 80)
        XCTAssertTrue(cleanup.noiseRemovalOn)
        XCTAssertEqual(cleanup.noiseRemovalStrength, 1)
        XCTAssertTrue(cleanup.noiseGateOn)
        XCTAssertEqual(cleanup.noiseGateThreshold, -50)
        XCTAssertTrue(cleanup.levelingOn)

        let withoutMic = RecordingProject.newRecording(source: .init(duration: 3, systemAudio: "system.m4a"))
        XCTAssertFalse(withoutMic.edits.audio.voiceCleanup.isOn, "there is nothing to clean without a Microphone track")
    }

    func testSettingsRoundTripThroughTheProjectFolder() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("VoiceCleanupTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var project = RecordingProject.newRecording(source: .init(duration: 3, microphone: "mic.m4a"))
        project.edits.audio.voiceCleanup = VoiceCleanup(isOn: true, lowCutOn: false, lowCutFrequency: 150, noiseRemovalOn: true, noiseRemovalStrength: 0.4,
                                                        noiseGateOn: false, noiseGateThreshold: -42, levelingOn: false)
        try RecordingProjectFile.write(project, to: folder)
        XCTAssertEqual(try RecordingProjectFile.read(from: folder).edits.audio.voiceCleanup, project.edits.audio.voiceCleanup)
    }

    func testOutOfRangeValuesAreClamped() throws {
        let high = try decode(#"{"edits":{"audio":{"voiceCleanup":{"isOn":true,"lowCutFrequency":500,"noiseRemovalStrength":3,"noiseGateThreshold":10}}}}"#)
            .edits.audio.voiceCleanup
        XCTAssertTrue(high.isOn)
        XCTAssertEqual(high.lowCutFrequency, 200)
        XCTAssertEqual(high.noiseRemovalStrength, 1)
        XCTAssertEqual(high.noiseGateThreshold, -20)

        let low = try decode(#"{"edits":{"audio":{"voiceCleanup":{"lowCutFrequency":10,"noiseRemovalStrength":-1,"noiseGateThreshold":-500}}}}"#)
            .edits.audio.voiceCleanup
        XCTAssertEqual(low.lowCutFrequency, 60)
        XCTAssertEqual(low.noiseRemovalStrength, 0)
        XCTAssertEqual(low.noiseGateThreshold, -80)

        var set = VoiceCleanup()
        set.lowCutFrequency = 20
        XCTAssertEqual(set.lowCutFrequency, 60, "a value set in code is kept in range too")
        let damaged = try decode(#"{"edits":{"audio":{"voiceCleanup":{"isOn":true,"lowCutFrequency":"high","levelingOn":false}}}}"#).edits.audio.voiceCleanup
        XCTAssertEqual(damaged, VoiceCleanup(isOn: true, levelingOn: false), "a damaged value costs only that value")
    }
}
