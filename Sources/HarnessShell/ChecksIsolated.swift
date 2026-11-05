import AppKit
import CornermarkCapture
@testable import CornermarkShell

@MainActor
func checkIsolatedEnvironment() async throws {
    section("isolated environment")
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("CornermarkHarness-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let env = try AppEnvironment.isolated(root: root, defaults: MemoryDefaults())
    var presented: [NSWindow] = []
    env.willPresent = { presented.append($0) }
    env.hasScreenPermission = { true }
    let c = AppCoordinator(env: env)
    func link(_ path: String) -> URL { URL(string: "\(URLCommand.scheme)://\(path)")! }

    check(try await env.screen.displays().isEmpty, "it has no display to image")
    check([env.store.root, env.defaultSaveFolder, env.dragDirectory].allSatisfy { $0.path.hasPrefix(root.path + "/") }, "history, saves and drags stay inside its root")
    for spec in ActionTable.specs where spec.menuGroup == 0 {
        c.hud.show("waiting")
        check(c.handle(url: link(spec.urlPath!)), "\(spec.urlPath!) is a known link")
        check(await waitUntil { c.hud.lastMessage == "Capture failed" }, "and ends as a failed capture", detail: c.hud.lastMessage ?? "nil")
    }
    check(env.store.list().isEmpty, "no capture link stored an image")

    for path in ["history", "settings", "whats-new"] {
        presented = []
        check(c.handle(url: link(path)) && presented.count == 1, "\(path) presents one window")
        check(presented.first?.isVisible == false && nothingOnScreen(), "and it stays off screen with the app inactive")
    }

    let image = try ImageOutput.save(Pix.flat(120, 80, r: 0.9, g: 0.4, b: 0.1), format: .png, folder: root.appendingPathComponent("fixture", isDirectory: true), date: Date())
    check(c.handle(url: link("open?path=\(image.path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!)")), "an image link is accepted")
    check(env.store.list().count == 1 && c.editors.count == 1, "it reaches the isolated history and an editor")
    check(c.editors.values.first?.window?.isVisible != true && nothingOnScreen(), "and the editor stays off screen with the app inactive")
    c.closeAllEditors()
}
