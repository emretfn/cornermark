import AppKit
import CornermarkCapture
import Foundation
import CornermarkDesign
import CornermarkL10n
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
let zoomFilming = ProcessInfo.processInfo.environment["CORNERMARK_ZOOM_FILM"]
let zoomCurve = ProcessInfo.processInfo.environment["CORNERMARK_ZOOM_CURVE"]
let cursorFilming = ProcessInfo.processInfo.environment["CORNERMARK_CURSOR_FILM"]
let cameraFilming = ProcessInfo.processInfo.environment["CORNERMARK_CAMERA_FILM"]
let backgroundFilming = ProcessInfo.processInfo.environment["CORNERMARK_BACKGROUND_FILM"]
let afterFilming = ProcessInfo.processInfo.environment["CORNERMARK_AFTER_FILM"]
let projectFilming = ProcessInfo.processInfo.environment["CORNERMARK_PROJECT_FILM"]
let aspectFilming = ProcessInfo.processInfo.environment["CORNERMARK_ASPECT_FILM"]
let blurFilming = ProcessInfo.processInfo.environment["CORNERMARK_BLUR_FILM"]
let followFilming = ProcessInfo.processInfo.environment["CORNERMARK_FOLLOW_FILM"]
let followExport = ProcessInfo.processInfo.environment["CORNERMARK_FOLLOW_EXPORT"]
let manualZoomFilming = ProcessInfo.processInfo.environment["CORNERMARK_MANUAL_ZOOM_FILM"]
let shortcutsFilming = ProcessInfo.processInfo.environment["CORNERMARK_SHORTCUTS_FILM"]
let panelSourcesFilming = ProcessInfo.processInfo.environment["CORNERMARK_PANEL_SOURCES_FILM"]
let panelRenders = ProcessInfo.processInfo.environment["CORNERMARK_PANEL_RENDERS"]
let playbackProbe = ProcessInfo.processInfo.environment["CORNERMARK_PLAYBACK_PROBE"]
let editorControlsFilming = ProcessInfo.processInfo.environment["CORNERMARK_EDITOR_CONTROLS_FILM"]
DispatchQueue.global().asyncAfter(deadline: .now() + ([filming, editorFilming, exportFilming, filmingControls, filmingGifs, filmingInput, trimFilming, zoomFilming, zoomCurve, cursorFilming, backgroundFilming, cameraFilming, afterFilming, projectFilming, aspectFilming, blurFilming, followFilming, followExport, manualZoomFilming, shortcutsFilming, panelSourcesFilming, panelRenders, playbackProbe, editorControlsFilming].allSatisfy { $0 == nil } ? 420 : 900)) {
    print("FAIL harness timed out")
    exit(2)
}

Task { @MainActor in
    if let playbackProbe {
        // `check` runs only the harness check for playing with sound; a folder of recordings is measured instead.
        let ok: Bool
        if playbackProbe == "check" {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("cornermark-playback-\(UUID().uuidString.prefix(6))", isDirectory: true)
            try? await checkVideoEditorPlaybackWithSound(root: root)
            ok = Checks.shared.failed == 0
        } else {
            ok = await PlaybackProbe.run(inputs: URL(fileURLWithPath: playbackProbe, isDirectory: true))
        }
        filmDone(ok)
    }
    if let editorControlsFilming {
        let ok = await EditorControlsFilm.run(out: URL(fileURLWithPath: editorControlsFilming, isDirectory: true))
        filmDone(ok)
    }
    if let panelRenders {
        let ok = await PanelRenders.run(out: URL(fileURLWithPath: panelRenders, isDirectory: true))
        filmDone(ok)
    }
    if let panelSourcesFilming {
        let ok = await PanelSourcesFilm.run(out: URL(fileURLWithPath: panelSourcesFilming, isDirectory: true))
        filmDone(ok)
    }
    if let shortcutsFilming {
        let ok = await VideoShortcutsFilm.run(out: URL(fileURLWithPath: shortcutsFilming, isDirectory: true))
        filmDone(ok)
    }
    if let blurFilming {
        let ok = await VideoMotionBlurFilm.run(out: URL(fileURLWithPath: blurFilming, isDirectory: true))
        filmDone(ok)
    }
    if let afterFilming {
        let ok = await VideoAfterRecordingFilm.run(out: URL(fileURLWithPath: afterFilming, isDirectory: true))
        filmDone(ok)
    }
    if let aspectFilming {
        let ok = await VideoAspectFilm.run(out: URL(fileURLWithPath: aspectFilming, isDirectory: true))
        filmDone(ok)
    }
    if let projectFilming {
        let ok = await VideoProjectFilm.run(out: URL(fileURLWithPath: projectFilming, isDirectory: true))
        filmDone(ok)
    }
    if let zoomCurve {
        let ok = await ZoomCurveExport.run(folder: URL(fileURLWithPath: zoomCurve, isDirectory: true),
                                           spec: ProcessInfo.processInfo.environment["CORNERMARK_ZOOMS"] ?? "1-4@2")
        filmDone(ok)
    }
    if let followFilming {
        let ok = await VideoFollowFilm.run(out: URL(fileURLWithPath: followFilming, isDirectory: true))
        filmDone(ok)
    }
    if let manualZoomFilming {
        let ok = await VideoManualZoomFilm.run(out: URL(fileURLWithPath: manualZoomFilming, isDirectory: true))
        filmDone(ok)
    }
    if let followExport {
        let ok = await FollowExport.run(folder: URL(fileURLWithPath: followExport, isDirectory: true))
        filmDone(ok)
    }
    if let zoomFilming {
        let ok = await VideoZoomFilm.run(out: URL(fileURLWithPath: zoomFilming, isDirectory: true))
        filmDone(ok)
    }
    if let cursorFilming {
        let ok = await CursorFilm.run(out: URL(fileURLWithPath: cursorFilming, isDirectory: true))
        filmDone(ok)
    }
    if let cameraFilming {
        let ok = await CameraFilm.run(out: URL(fileURLWithPath: cameraFilming, isDirectory: true))
        filmDone(ok)
    }
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
    check(L10n.language == .en && !L10n.isRightToLeft, "the harness starts in English whatever the Mac's language is", detail: L10n.language.rawValue)
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
        try await checkLocalization()
        try await checkSmallWindows()
        try await checkIsolatedEnvironment()
        try await checkRecording()
        try await checkRecordingResults()
        try await checkRecordingControls()
        try await checkRecordingRecovery()
        try await checkGifRecording()
        try await checkRecordingInput()
        try await checkRecordingCamera()
        try await checkRecordingAudio()
        try await checkRecordingSources()
        try await checkVideoEditor()
        try await checkVideoExport()
        try await checkVideoProjects()
        try await checkVideoZoom()
        try await checkVideoManualZoom()
        try await checkVideoAfterRecording()
        try await checkVideoMotionBlur()
        try await checkVideoShortcuts()
        try await checkLocalizedWindows()
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
