import AppKit
import CornermarkCapture
import CornermarkCore
@testable import CornermarkShell

private func pixelRect(_ r: CGRect) -> CGRect { CGRect(x: r.minX * 2, y: r.minY * 2, width: r.width * 2, height: r.height * 2) }

/// Crops of the sample windows, the same pictures a person would have captured from the sample desktop.
enum Crops {
    static func chart() -> CGImage { SampleScene.dashboardWindow().cropped(pixelRect(Dashboard.chartCard)) }
    static func table() -> CGImage { SampleScene.dashboardWindow().cropped(pixelRect(Dashboard.tableCard)) }
    static func chartAndTable() -> CGImage { SampleScene.dashboardWindow().cropped(pixelRect(Dashboard.chartCard.union(Dashboard.tableCard))) }
    static func kpiAndChart() -> CGImage { SampleScene.dashboardWindow().cropped(pixelRect(Dashboard.kpiCards[0].union(Dashboard.chartCard))) }
    static func overview() -> CGImage {
        SampleScene.dashboardWindow().cropped(pixelRect(CGRect(x: Dashboard.sidebarWidth, y: Dashboard.titleBarHeight, width: Dashboard.size.width - Dashboard.sidebarWidth, height: 348)))
    }
    static func codeSnippet() -> CGImage {
        SampleScene.codeWindow().cropped(pixelRect(CGRect(x: 0, y: 70, width: SampleScene.codeFrame.width, height: 292)))
    }
    static func codeFile() -> CGImage {
        let size = CGSize(width: SampleScene.codeFrame.width, height: 1100)
        return SampleScene.codeWindow(size: size).cropped(pixelRect(CGRect(x: 0, y: 70, width: size.width, height: size.height - 70 - CodeWindow.statusBarHeight)))
    }
    static func codeLowerHalf() -> CGImage {
        let size = CGSize(width: SampleScene.codeFrame.width, height: 1100)
        return SampleScene.codeWindow(size: size).cropped(pixelRect(CGRect(x: 0, y: 436, width: size.width, height: 304)))
    }
    static func dashboardWithShadow() -> CGImage { SampleScene.shadowedCapture(SampleScene.dashboardWindow()) }
    static func codeWithShadow() -> CGImage { SampleScene.shadowedCapture(SampleScene.codeWindow()) }
}

@MainActor
func quickAccessShot() async throws -> CGImage {
    let desktop = SampleScene.desktop()
    let rig = try Rig(desktop: desktop)
    defer { rig.cleanup() }
    let coordinator = rig.coordinator
    for (image, kind) in [(Crops.codeSnippet(), CaptureKind.area), (Crops.overview(), .area), (Crops.dashboardWithShadow(), .window)] {
        coordinator.handleCaptured(CaptureOutput(image: image, kind: kind, pointScale: 2))
    }
    let cards = coordinator.overlay.stack
    guard cards.count == 3 else { throw ShotError("expected three cards, got \(cards.count)") }
    coordinator.overlay.setHovering(cards[0], true)
    coordinator.overlay.cardView(for: cards[0])?.setHovering(true)

    let c = Canvas(size: SampleScene.desktopSize)
    c.drawImage(desktop, in: CGRect(origin: .zero, size: SampleScene.desktopSize))
    for card in cards.reversed() {
        guard let panel = coordinator.overlay.panel(for: card), let view = coordinator.overlay.cardView(for: card) else { throw ShotError("card has no panel") }
        view.appearance = NSAppearance(named: .aqua)
        guard let image = image(of: view) else { throw ShotError("card snapshot failed") }
        let frame = panel.frame
        let origin = CGPoint(x: frame.minX, y: SampleScene.desktopSize.height - frame.maxY)
        let rect = CGRect(origin: origin, size: frame.size)
        c.shadowed(dy: 12, blur: 28, alpha: 0.38) { c.drawImage(image, in: rect) }
        c.shadowed(dy: 1, blur: 3, alpha: 0.25) { c.drawImage(image, in: rect) }
    }
    return c.image().resized(toWidth: Compose.width)
}

@MainActor
func historyShot() async throws -> CGImage {
    let rig = try Rig()
    defer { rig.cleanup() }
    let hour: TimeInterval = 3600, day: TimeInterval = 86_400
    let plan: [(CGImage, CaptureKind, TimeInterval)] = [
        (Crops.chartAndTable(), .area, -hour * 0.7),
        (Crops.codeWithShadow(), .window, -hour * 3),
        (Crops.codeFile(), .scrolling, -hour * 5),
        (SampleScene.desktop(), .fullscreen, -day - hour * 2),
        (Crops.kpiAndChart(), .area, -day - hour * 4),
        (Crops.codeSnippet(), .timed, -day * 3),
        (Crops.dashboardWithShadow(), .window, -day * 5),
        (Crops.codeLowerHalf(), .imported, -day * 12),
    ]
    var records: [CaptureRecord] = []
    for (image, kind, offset) in plan {
        records.append(try rig.store.add(image, kind: kind, pointScale: 2, now: Rig.now.addingTimeInterval(offset)))
    }
    rig.coordinator.perform(.openHistory)
    guard let history = rig.coordinator.history, let window = history.window else { throw ShotError("history window missing") }
    let grid = history.collectionView
    func itemsInstantiated() -> Bool {
        (0..<grid.numberOfSections).allSatisfy { s in
            (0..<grid.numberOfItems(inSection: s)).allSatisfy { grid.item(at: IndexPath(item: $0, section: s)) != nil }
        }
    }
    // Thumbnails load only for items that exist, so every item is created in a tall window before the real size is set.
    window.setContentSize(NSSize(width: 960, height: 2000))
    window.contentView?.layoutSubtreeIfNeeded()
    grid.layoutSubtreeIfNeeded()
    let created = await waitUntil { itemsInstantiated() }
    let pixels = HistoryWindowController.thumbnailPixels
    let loaded = await waitUntil(15) { history.records.allSatisfy { history.thumbnails.cached($0.id, maxPixel: pixels) != nil } }
    guard created, loaded else { throw ShotError("history thumbnails never finished loading") }
    let scroll = grid.enclosingScrollView
    let chrome = 2000 - (scroll?.contentSize.height ?? 0)
    window.setContentSize(NSSize(width: 960, height: chrome + grid.collectionViewLayout!.collectionViewContentSize.height))
    grid.reloadData()
    window.contentView?.layoutSubtreeIfNeeded()
    grid.layoutSubtreeIfNeeded()
    let ready = await waitUntil { grid.visibleItems().count >= 8 }
    guard ready else { throw ShotError("history items never appeared") }
    history.select(recordIDs: [records[1].id])
    guard let shot = snapshot(window: window) else { throw ShotError("history snapshot failed") }
    return Compose.windowOnWallpaper(Compose.rounded(shot, radiusPoints: 16))
}

@MainActor
func settingsShot() async throws -> CGImage {
    let rig = try Rig()
    defer { rig.cleanup() }
    rig.coordinator.installHotKeys(backend: IdleHotKeys())
    rig.coordinator.perform(.openSettings)
    guard let controller = rig.coordinator.settingsWindow, let window = controller.window,
          let pane = controller.panes.first(where: { $0 is ShortcutsPane }) else { throw ShotError("settings window missing") }
    controller.refreshAll()
    controller.select(pane: pane)
    // The list scrolls; 534pt ends the window on a row divider instead of cutting the ninth row's text in half.
    window.setContentSize(NSSize(width: 760, height: 534))
    window.layoutIfNeeded()
    settle(0.1)
    guard let shot = snapshot(window: window) else { throw ShotError("settings snapshot failed") }
    return Compose.windowOnWallpaper(Compose.rounded(shot, radiusPoints: 16))
}

@MainActor
func pinShot() async throws -> CGImage {
    let code = CGRect(x: 640, y: 128, width: 700, height: 560)
    let desktop = SampleScene.desktop(code: code, withDashboard: false)
    let rig = try Rig(desktop: desktop)
    defer { rig.cleanup() }
    let pin = rig.coordinator.pins.pin(Crops.chart(), pointScale: 2)
    let view = pin.window.contentView!
    view.appearance = NSAppearance(named: .aqua)
    guard let image = image(of: view) else { throw ShotError("pin snapshot failed") }
    let size = view.bounds.size
    let c = Canvas(size: SampleScene.desktopSize)
    c.drawImage(desktop, in: CGRect(origin: .zero, size: SampleScene.desktopSize))
    let rect = CGRect(x: 150, y: 330, width: size.width, height: size.height)
    c.shadowed(dy: 20, blur: 44, alpha: 0.45) { c.drawImage(image, in: rect) }
    c.shadowed(dy: 2, blur: 6, alpha: 0.3) { c.drawImage(image, in: rect) }
    return c.image().resized(toWidth: Compose.width)
}
