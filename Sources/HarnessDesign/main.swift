import AppKit
@testable import CornermarkDesign

setvbuf(stdout, nil, _IOLBF, 0)
let app = NSApplication.shared
SilentNoResponder.install()
app.setActivationPolicy(.prohibited)
app.finishLaunching()

print("accent: \(accentName)")
checkContrast()
checkStructure()
checkElevation()
checkComponents()
renderSpecimens()

if SilentNoResponder.isSilent {
    let caught = SilentNoResponder.catching { NSWindow().noResponder(for: #selector(NSResponder.keyDown(with:))) }
    check("an unhandled key is counted instead of beeping", caught == ["keyDown:"], "\(caught)")
} else {
    check("every responder class answers noResponder(for:) with the silent version", false)
}
if SilentNoResponder.count > 0 {
    failures += 1
    print("FAIL a key fell through to a system beep: \(SilentNoResponder.selectors.joined(separator: " "))")
}
print("\n\(passes) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
