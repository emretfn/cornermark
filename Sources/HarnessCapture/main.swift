import AppKit
import Foundation

try? FileManager.default.createDirectory(atPath: scratch, withIntermediateDirectories: true)
try? FileManager.default.createDirectory(atPath: multiScratch, withIntermediateDirectories: true)

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)

DispatchQueue.global().asyncAfter(deadline: .now() + 90) {
    print("FAIL harness timed out")
    exit(2)
}

Task { @MainActor in
    observeWindowClosing()
    print("windows available: \(NSScreen.screens.count) screen(s), main backing scale \(NSScreen.main?.backingScaleFactor ?? 0)")
    runMachineTests()
    await runIntegrationTests()
    await runSpanTests()
    let c = Checks.shared
    print("\nRESULT \(c.passed) passed, \(c.failed) failed")
    exit(c.failed == 0 ? 0 : 1)
}

app.run()
