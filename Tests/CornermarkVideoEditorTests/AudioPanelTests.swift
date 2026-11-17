import AppKit
import CornermarkCore
import XCTest
@testable import CornermarkVideoEditor

@MainActor
final class AudioPanelTests: XCTestCase {
    private func control(_ id: String, in view: NSView) -> NSControl? {
        if view.accessibilityIdentifier() == id { return view as? NSControl }
        return view.subviews.lazy.compactMap { self.control(id, in: $0) }.first
    }

    func testNoiseRemovalThatCannotRunIsGreyedOutButStillShowsWhatTheProjectSaysAndWhy() throws {
        let panel = AudioPanel(frame: NSRect(x: 0, y: 0, width: 300, height: 600))
        var audio = AudioEdits()
        audio.voiceCleanup = VoiceCleanup(isOn: true)
        panel.show(audio, tracks: [.microphone])
        let box = try XCTUnwrap(control("video.audio.voiceCleanup.noiseRemoval", in: panel) as? NSButton)
        let normalTip = box.toolTip

        panel.noiseRemovalAvailable = false
        XCTAssertFalse(box.isEnabled)
        XCTAssertEqual(box.state, .on, "a greyed-out step keeps showing it is on, as a section whose switch is off does")
        XCTAssertEqual(box.toolTip, "Not available on this Mac")
        XCTAssertEqual(box.accessibilityHelp(), "Not available on this Mac", "VoiceOver says why it is greyed out")

        panel.noiseRemovalAvailable = true
        if VoiceCleanupRenderer.noiseRemovalAvailable {
            XCTAssertTrue(box.isEnabled)
            XCTAssertEqual(box.toolTip, normalTip, "the usual tip comes back once it can run")
            XCTAssertEqual(box.accessibilityHelp(), normalTip)
        }
    }
}
