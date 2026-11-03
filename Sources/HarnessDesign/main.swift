import AppKit
@testable import CornermarkDesign

setvbuf(stdout, nil, _IOLBF, 0)
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
app.finishLaunching()

print("accent: \(accentName)")
checkContrast()
checkStructure()
checkElevation()
checkComponents()
renderSpecimens()

print("\n\(passes) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
