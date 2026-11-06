import AppKit
import CornermarkCapture
import Foundation
import CornermarkDesign
@testable import CornermarkShell

try? FileManager.default.createDirectory(atPath: scratch, withIntermediateDirectories: true)

let app = NSApplication.shared
SilentNoResponder.install()
app.setActivationPolicy(.prohibited)
ShortcutRecorderView.playRefusedSound = {}

let filming = ProcessInfo.processInfo.environment["CORNERMARK_RESULTS_FILM"]
let editorFilming = ProcessInfo.processInfo.environment["CORNERMARK_EDITOR_FILM"]
let exportFilming = ProcessInfo.processInfo.environment["CORNERMARK_EXPORT_FILM"]
let filmingControls = ProcessInfo.processInfo.environment["CORNERMARK_CONTROLS_FILM"]
let filmingGifs = ProcessInfo.processInfo.environment["CORNERMARK_GIF_FILM"]
let filmingInput = ProcessInfo.processInfo.environment["CORNERMARK_INPUT_FILM"]
let trimFilming = ProcessInfo.processInfo.environment["CORNERMARK_TRIM_FILM"]
let backgroundFilming = ProcessInfo.processInfo.environment["CORNERMARK_BACKGROUND_FILM"]
DispatchQueue.global().asyncAfter(deadline: .now() + ([filming, editorFilming, exportFilming, filmingControls, filmingGifs, filmingInput, trimFilming, backgroundFilming].allSatisfy { $0 == nil } ? 180 : 900)) {
    print("FAIL harness timed out")
    exit(2)
}

Task { @MainActor in
    if let backgroundFilming {
        let ok = await VideoBackgroundFilm.run(out: URL(fileURLWithPath: backgroundFilming, isDirectory: true))
        filmDone(ok)
    }
    if let trimFilming {
        let ok = await VideoTrimFilm.run(out: URL(fileURLWithPath: trimFilming, isDirectory: true))
        filmDone(ok)
    }
    if let exportFilming {
        let ok = await VideoExportFilm.run(out: URL(fileURLWithPath: exportFilming, isDirectory: true))
        filmDone(ok)
    }
    if let editorFilming {
        let ok = await VideoEditorFilm.run(out: URL(fileURLWithPath: editorFilming, isDirectory: true))
        filmDone(ok)
    }
    if let filming {
        let ok = await ResultsFilm.run(out: URL(fileURLWithPath: filming, isDirectory: true))
        filmDone(ok)
    }
    if let filmingControls {
        let recovery = ProcessInfo.processInfo.environment["CORNERMARK_RECOVERY_EVIDENCE"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        let ok = await ControlsFilm.run(out: URL(fileURLWithPath: filmingControls, isDirectory: true), recovery: recovery)
        filmDone(ok)
    }
    if let filmingInput {
        let ok = await InputFilm.run(out: URL(fileURLWithPath: filmingInput, isDirectory: true))
        filmDone(ok)
    }
    if let filmingGifs {
        let instance = ProcessInfo.processInfo.environment["CORNERMARK_INSTANCE_GIF"].map { URL(fileURLWithPath: $0) }
        let ok = await GifFilm.run(out: URL(fileURLWithPath: filmingGifs, isDirectory: true), instanceGif: instance)
        filmDone(ok)
    }
    let standardKeysBefore = Set(UserDefaults.standard.dictionaryRepresentation().keys.filter { $0.hasPrefix("cornermark") })
    print("screens: \(NSScreen.screens.count), activation policy prohibited: \(NSApp.activationPolicy() == .prohibited)")
    check(NSApp.activationPolicy() == .prohibited, "activation policy is .prohibited")
    do {
        try await checkActionTable()
        try await checkURLScheme()
        try await checkSettingsModel()
        try await checkHotKeys()
        try await checkImageOutput()
        try await checkCaptureFlow()
        try await checkAfterCaptureRouting()
        try await checkPermission()
        try await checkCardActions()
        try await checkOCRFlow()
        try await checkOCR()
        try await checkOverlayLifecycle()
        try await checkPins()
        try await checkHistory()
        try await checkHistoryChrome()
        try await checkPrune()
        try await checkImportAndEditorRoundTrip()
        try await checkUpdates()
        try await checkMenuPanel()
        try await checkSettingsWindow()
        try await checkSmallWindows()
        try await checkIsolatedEnvironment()
        try await checkRecording()
        try await checkRecordingResults()
        try await checkRecordingControls()
        try await checkRecordingRecovery()
        try await checkGifRecording()
        try await checkRecordingInput()
        try await checkRecordingAudio()
        try await checkVideoEditor()
        try await checkVideoExport()
        try await checkVideoProjects()
        try await takeSnapshots()
    } catch {
        check(false, "harness threw", detail: "\(error)")
    }
    section("isolation")
    let standardKeysAfter = Set(UserDefaults.standard.dictionaryRepresentation().keys.filter { $0.hasPrefix("cornermark") })
    check(standardKeysBefore == standardKeysAfter, "standard UserDefaults gained no cornermark keys")
    check(nothingOnScreen(), "at the end no window was ever visible and the app never became active")
    check(NSApp.activationPolicy() == .prohibited, "activation policy still .prohibited")
    check(SilentNoResponder.count == 0, "no key fell through to a system beep", detail: SilentNoResponder.selectors.joined(separator: " "))
    check(LiveInputSource.tapsCreated == 0, "no event tap was created in this run", detail: "\(LiveInputSource.tapsCreated)")
    check(LiveMicrophoneSource.sessionsOpened == 0 && MicrophoneAccess.requests == 0, "no real audio device was opened and microphone access was never requested",
          detail: "devices \(LiveMicrophoneSource.sessionsOpened), requests \(MicrophoneAccess.requests)")
    let c = Checks.shared
    print("\nRESULT \(c.passed) passed, \(c.failed) failed")
    exit(c.failed == 0 ? 0 : 1)
}

/// A film passes only when every key it sent was handled, since an unhandled one would have beeped.
func filmDone(_ ok: Bool) -> Never {
    let silent = SilentNoResponder.count == 0
    if !silent { print("FAIL a key fell through to a system beep: \(SilentNoResponder.selectors.joined(separator: " "))") }
    print(ok && silent ? "FILM DONE" : "FILM FAILED")
    exit(ok && silent ? 0 : 1)
}

app.run()
