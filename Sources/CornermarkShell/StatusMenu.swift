import AppKit

/// The menu bar menu, generated from the action table, plus the list of pinned screenshots.
@MainActor
final class StatusMenuBuilder: NSObject, NSMenuDelegate {
    private unowned let coordinator: AppCoordinator

    init(coordinator: AppCoordinator) { self.coordinator = coordinator }

    func build() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        populate(menu)
        return menu
    }

    func populate(_ menu: NSMenu) {
        menu.removeAllItems()
        let s = coordinator.settings.value
        var lastGroup: Int?
        for spec in ActionTable.specs {
            guard let group = spec.menuGroup else { continue }
            if let last = lastGroup, last != group {
                if last == 1 { addPinned(to: menu) }
                menu.addItem(.separator())
            }
            lastGroup = group
            let update = coordinator.updates.state
            let title = switch spec.id {
            case .hideOverlays where coordinator.overlay.isHidden: "Show Overlays"
            case .checkForUpdates: update.menuTitle
            default: spec.title
            }
            let item = BlockMenuItem(title) { [coordinator] in coordinator.perform(id: spec.id) }
            item.identifier = NSUserInterfaceItemIdentifier(spec.id.rawValue)
            if let key = s.hotKey(for: spec.id), let char = key.menuCharacter {
                item.keyEquivalent = char
                item.keyEquivalentModifierMask = key.modifierFlags
            }
            if spec.id == .restoreOverlay { item.isEnabled = !coordinator.overlay.recentlyClosed.isEmpty }
            if spec.id == .checkForUpdates { item.isEnabled = update.menuEnabled }
            menu.addItem(item)
        }
    }

    private func addPinned(to menu: NSMenu) {
        let pinned = coordinator.pins.menuItems()
        guard !pinned.isEmpty else { return }
        menu.addItem(.separator())
        let header = NSMenuItem(title: "Pinned Screenshots", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        pinned.forEach(menu.addItem)
    }

    func menuNeedsUpdate(_ menu: NSMenu) { populate(menu) }
}
