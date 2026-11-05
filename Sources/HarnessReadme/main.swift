import AppKit
import Foundation
import CornermarkDesign

struct Shot {
    let name: String
    let render: @MainActor () async throws -> CGImage
}

// The History window formats dates with Locale.current, which is read from the argument domain at launch, so the shots stay English on any machine.
if !CommandLine.arguments.contains("-AppleLocale") {
    let arguments = CommandLine.arguments + ["-AppleLocale", "en_US", "-AppleLanguages", "(en)"]
    execv(CommandLine.arguments[0], arguments.map { strdup($0) } + [nil])
}

setvbuf(stdout, nil, _IOLBF, 0)
let app = NSApplication.shared
SilentNoResponder.install()
app.setActivationPolicy(.prohibited)
app.appearance = NSAppearance(named: .aqua)

DispatchQueue.global().asyncAfter(deadline: .now() + 300) {
    print("FAIL timed out")
    exit(2)
}

let outputDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("docs/screenshots", isDirectory: true)

Task { @MainActor in
    let wanted = Set(CommandLine.arguments.dropFirst().prefix { !$0.hasPrefix("-Apple") })
    var failures = 0
    do { try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true) } catch {
        print("FAIL cannot create \(outputDirectory.path): \(error)")
        exit(1)
    }
    for shot in allShots where wanted.isEmpty || wanted.contains(shot.name) {
        do {
            let image = try await shot.render()
            guard let png = Compose.png(image) else { throw ShotError("PNG encoding failed") }
            let url = outputDirectory.appendingPathComponent(shot.name + ".png")
            try png.write(to: url, options: .atomic)
            print("WROTE docs/screenshots/\(shot.name).png \(image.width)x\(image.height) \(png.count / 1024) KB")
        } catch {
            failures += 1
            print("FAIL \(shot.name): \(error)")
        }
    }
    if NSApp.windows.contains(where: \.isVisible) || NSApp.isActive {
        print("FAIL a window was ordered on screen or the app became active")
        failures += 1
    }
    if SilentNoResponder.count > 0 {
        print("FAIL a key fell through to a system beep: \(SilentNoResponder.selectors.joined(separator: " "))")
        failures += 1
    }
    exit(failures == 0 ? 0 : 1)
}

app.run()
