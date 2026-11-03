import AppKit
import CornermarkCore
import CornermarkEditor

setvbuf(stdout, nil, _IOLBF, 0)
let app = NSApplication.shared
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
checkPerformance()
snapshotScenes()

print("\n\(passes) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
