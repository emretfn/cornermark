import AppKit
import KadrajCore
import KadrajEditor

setvbuf(stdout, nil, _IOLBF, 0)
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
app.finishLaunching()

let defaults = UserDefaults(suiteName: "kadraj.harness.editor")!
defaults.removePersistentDomain(forName: "kadraj.harness.editor")

checkShortcuts()
checkDrawing()
checkSelect()
checkText()
checkCrop()
checkBackgroundPanel()
checkPropertyBar()
checkOutputs()
checkDrop()
checkPerformance()
snapshotScenes()

print("\n\(passes) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
