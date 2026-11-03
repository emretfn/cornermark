import AppKit

@MainActor
let allShots: [Shot] = [
    Shot(name: "hero") { try await heroShot() },
    Shot(name: "editor-dark") { try await editorDarkShot() },
    Shot(name: "capture") { try await captureShot().resized(toWidth: Compose.width) },
    Shot(name: "quick-access") { try await quickAccessShot() },
    Shot(name: "history") { try await historyShot() },
    Shot(name: "settings") { try await settingsShot() },
    Shot(name: "pin") { try await pinShot() },
]
