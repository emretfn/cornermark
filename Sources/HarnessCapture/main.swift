import AppKit
import Foundation

try? FileManager.default.createDirectory(atPath: scratch, withIntermediateDirectories: true)
try? FileManager.default.createDirectory(atPath: multiScratch, withIntermediateDirectories: true)

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)

let previewing = ProcessInfo.processInfo.environment["CORNERMARK_PROJECT_PREVIEW"] != nil
DispatchQueue.global().asyncAfter(deadline: .now() + (previewing ? 900 : 90)) {
    print("FAIL harness timed out")
    exit(2)
}

Task { @MainActor in
    if let project = ProcessInfo.processInfo.environment["CORNERMARK_PROJECT_PREVIEW"],
       let out = ProcessInfo.processInfo.environment["CORNERMARK_PROJECT_PREVIEW_OUT"] {
        let unchanged = await ProjectPreview.run(project: URL(fileURLWithPath: project, isDirectory: true), out: URL(fileURLWithPath: out, isDirectory: true))
        print(unchanged ? "SOURCE UNCHANGED" : "SOURCE CHANGED OR PREVIEW FAILED")
        exit(unchanged ? 0 : 1)
    }
    observeWindowClosing()
    print("windows available: \(NSScreen.screens.count) screen(s), main backing scale \(NSScreen.main?.backingScaleFactor ?? 0)")
    runMachineTests()
    await runIntegrationTests()
    await runSpanTests()
    await runRecordingTests()
    await runProjectTimelineTests()
    let c = Checks.shared
    print("\nRESULT \(c.passed) passed, \(c.failed) failed")
    exit(c.failed == 0 ? 0 : 1)
}

app.run()
