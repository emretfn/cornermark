import AppKit
import CornermarkCore
import CornermarkEditor
import CornermarkDesign

setvbuf(stdout, nil, _IOLBF, 0)
let app = NSApplication.shared
SilentNoResponder.install()
app.setActivationPolicy(.prohibited)
app.finishLaunching()

let defaults = UserDefaults(suiteName: "cornermark.harness.editor")!
defaults.removePersistentDomain(forName: "cornermark.harness.editor")

checkShortcuts()
checkDrawing()
checkSelect()
checkText()
checkCrop()
checkBackgroundPanel()
checkPropertyBar()
checkPropertyBarAlignment()
checkResizePanelLayout()
checkColourWell()
checkOutputs()
checkDrop()
checkLanguageSwitch()
checkPerformance()
snapshotScenes()

if SilentNoResponder.count > 0 {
    failures += 1
    print("FAIL a key fell through to a system beep: \(SilentNoResponder.selectors.joined(separator: " "))")
}
print("\n\(passes) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
