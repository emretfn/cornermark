import AppKit
import CornermarkCapture
import Foundation
import CornermarkDesign

try? FileManager.default.createDirectory(atPath: scratch, withIntermediateDirectories: true)
try? FileManager.default.createDirectory(atPath: multiScratch, withIntermediateDirectories: true)

let app = NSApplication.shared
SilentNoResponder.install()
app.setActivationPolicy(.prohibited)

let filming = ProcessInfo.processInfo.environment["CORNERMARK_OVERLAY_FILM"]
DispatchQueue.global().asyncAfter(deadline: .now() + (filming != nil ? 900 : 180)) {
    print("FAIL harness timed out")
    exit(2)
}

Task { @MainActor in
    if let filming {
        let ok = await OverlayFilm.run(out: URL(fileURLWithPath: filming, isDirectory: true))
        print(ok ? "FILM DONE" : "FILM FAILED")
        exit(ok ? 0 : 1)
    }
    observeWindowClosing()
    print("windows available: \(NSScreen.screens.count) screen(s), main backing scale \(NSScreen.main?.backingScaleFactor ?? 0)")
    runMachineTests()
    await runIntegrationTests()
    await runSpanTests()
    await runRecordOverlayTests()
    await runRecordingTests()
    await runGifTests()
    await runRecordingSettingsTests()
    await runRecordingControlTests()
    await runProjectTimelineTests()
    await runInputTests()
    await runCameraTests()
    await runAudioTests()
    check(LiveMicrophoneSource.sessionsOpened == 0 && MicrophoneAccess.requests == 0, "no real audio device was opened and microphone access was never requested")
    check(SilentNoResponder.count == 0, "no key fell through to a system beep", detail: SilentNoResponder.selectors.joined(separator: " "))
    let c = Checks.shared
    print("\nRESULT \(c.passed) passed, \(c.failed) failed")
    exit(c.failed == 0 ? 0 : 1)
}

app.run()
