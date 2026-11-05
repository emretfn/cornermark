import AppKit
import CornermarkCapture
import Foundation
@testable import CornermarkShell

try? FileManager.default.createDirectory(atPath: scratch, withIntermediateDirectories: true)

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
ShortcutRecorderView.playRefusedSound = {}

let filming = ProcessInfo.processInfo.environment["CORNERMARK_RESULTS_FILM"]
let editorFilming = ProcessInfo.processInfo.environment["CORNERMARK_EDITOR_FILM"]
let filmingControls = ProcessInfo.processInfo.environment["CORNERMARK_CONTROLS_FILM"]
let filmingGifs = ProcessInfo.processInfo.environment["CORNERMARK_GIF_FILM"]
let filmingInput = ProcessInfo.processInfo.environment["CORNERMARK_INPUT_FILM"]
DispatchQueue.global().asyncAfter(deadline: .now() + (filming == nil && editorFilming == nil && filmingControls == nil && filmingGifs == nil && filmingInput == nil ? 180 : 900)) {
    print("FAIL harness timed out")
    exit(2)
}

Task { @MainActor in
    if let editorFilming {
        let ok = await VideoEditorFilm.run(out: URL(fileURLWithPath: editorFilming, isDirectory: true))
        print(ok ? "FILM DONE" : "FILM FAILED")
        exit(ok ? 0 : 1)
    }
    if let filming {
        let ok = await ResultsFilm.run(out: URL(fileURLWithPath: filming, isDirectory: true))
        print(ok ? "FILM DONE" : "FILM FAILED")
        exit(ok ? 0 : 1)
    }
    if let filmingControls {
        let recovery = ProcessInfo.processInfo.environment["CORNERMARK_RECOVERY_EVIDENCE"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        let ok = await ControlsFilm.run(out: URL(fileURLWithPath: filmingControls, isDirectory: true), recovery: recovery)
        print(ok ? "FILM DONE" : "FILM FAILED")
        exit(ok ? 0 : 1)
    }
    if let filmingInput {
        let ok = await InputFilm.run(out: URL(fileURLWithPath: filmingInput, isDirectory: true))
        print(ok ? "FILM DONE" : "FILM FAILED")
        exit(ok ? 0 : 1)
    }
    if let filmingGifs {
        let instance = ProcessInfo.processInfo.environment["CORNERMARK_INSTANCE_GIF"].map { URL(fileURLWithPath: $0) }
        let ok = await GifFilm.run(out: URL(fileURLWithPath: filmingGifs, isDirectory: true), instanceGif: instance)
        print(ok ? "FILM DONE" : "FILM FAILED")
        exit(ok ? 0 : 1)
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
        try await checkVideoEditor()
        try await takeSnapshots()
    } catch {
        check(false, "harness threw", detail: "\(error)")
    }
    section("isolation")
    let standardKeysAfter = Set(UserDefaults.standard.dictionaryRepresentation().keys.filter { $0.hasPrefix("cornermark") })
    check(standardKeysBefore == standardKeysAfter, "standard UserDefaults gained no cornermark keys")
    check(nothingOnScreen(), "at the end no window was ever visible and the app never became active")
    check(NSApp.activationPolicy() == .prohibited, "activation policy still .prohibited")
    check(LiveInputSource.tapsCreated == 0, "no event tap was created in this run", detail: "\(LiveInputSource.tapsCreated)")
    let c = Checks.shared
    print("\nRESULT \(c.passed) passed, \(c.failed) failed")
    exit(c.failed == 0 ? 0 : 1)
}

app.run()
