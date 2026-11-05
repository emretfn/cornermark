import AppKit
import Foundation

try? FileManager.default.createDirectory(atPath: scratch, withIntermediateDirectories: true)
try? FileManager.default.createDirectory(atPath: multiScratch, withIntermediateDirectories: true)

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)

let filming = ProcessInfo.processInfo.environment["CORNERMARK_OVERLAY_FILM"]
DispatchQueue.global().asyncAfter(deadline: .now() + (filming != nil ? 900 : 90)) {
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
    let c = Checks.shared
    print("\nRESULT \(c.passed) passed, \(c.failed) failed")
    exit(c.failed == 0 ? 0 : 1)
}

app.run()
