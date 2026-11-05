import AppKit
import Foundation
@testable import CornermarkShell

try? FileManager.default.createDirectory(atPath: scratch, withIntermediateDirectories: true)

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
ShortcutRecorderView.playRefusedSound = {}

DispatchQueue.global().asyncAfter(deadline: .now() + 180) {
    print("FAIL harness timed out")
    exit(2)
}

Task { @MainActor in
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
        try await takeSnapshots()
    } catch {
        check(false, "harness threw", detail: "\(error)")
    }
    section("isolation")
    let standardKeysAfter = Set(UserDefaults.standard.dictionaryRepresentation().keys.filter { $0.hasPrefix("cornermark") })
    check(standardKeysBefore == standardKeysAfter, "standard UserDefaults gained no cornermark keys")
    check(nothingOnScreen(), "at the end no window was ever visible and the app never became active")
    check(NSApp.activationPolicy() == .prohibited, "activation policy still .prohibited")
    let c = Checks.shared
    print("\nRESULT \(c.passed) passed, \(c.failed) failed")
    exit(c.failed == 0 ? 0 : 1)
}

app.run()
