import AppKit
import KadrajCapture
import KadrajCore
import KadrajEditor
import ImageIO

/// Wires the pieces together. Every user intent enters through `perform(_:)`.
@MainActor
final class AppCoordinator {
    let env: AppEnvironment
    let settings: SettingsStore
    let capture: CaptureController
    let overlay: QuickAccessManager
    let pins: PinManager
    let hud: HUD
    let thumbnails = ThumbnailCache()
    private(set) var hotKeys: HotKeyManager?
    private(set) var history: HistoryWindowController?
    private(set) var settingsWindow: SettingsWindowController?
    private(set) var permissionWindow: PermissionWindowController?
    private(set) var editors: [UUID: EditorWindowController] = [:]
    private(set) var loginError: String?
    private var maintenanceTimer: Timer?

    init(env: AppEnvironment) {
        self.env = env
        settings = SettingsStore(defaults: env.defaults)
        capture = CaptureController(source: env.screen, presentation: env.presentation)
        let store = settings
        overlay = QuickAccessManager(env: env) { store.value }
        pins = PinManager(env: env)
        hud = HUD(env: env)

        overlay.perform = { [unowned self] action, card in cardAction(action, card) }
        pins.onCopied = { [unowned self] in hud.show("Copied") }
        settings.observe { [unowned self] old, new in settingsChanged(from: old, to: new) }
        applyCaptureSettings()
    }

    // MARK: Actions

    func perform(_ action: AppAction) {
        switch action {
        case .capture(let mode): beginCapture(mode) { [unowned self] out in handleCaptured(out) }
        case .captureOCR: beginCapture(.area) { [unowned self] out in runOCR(on: out.image) }
        case .openHistory: showHistory()
        case .openSettings: showSettings()
        case .restoreLastOverlay: if overlay.restoreLast() == nil { hud.show("No closed overlay to restore", symbol: "info.circle") }
        case .hideOverlays: overlay.toggleHidden()
        case .openFile(let url): importFile(url)
        case .quit: env.quit()
        }
    }

    func perform(id: ActionID) {
        if let action = AppAction.make(id, timerSeconds: settings.value.timerSeconds) { perform(action) }
    }

    /// Entry for `kadraj://` links. Anything unrecognized is logged and ignored.
    @discardableResult
    func handle(url: URL) -> Bool {
        switch URLCommand.parse(url, timerSeconds: settings.value.timerSeconds) {
        case .success(let action):
            perform(action)
            return true
        case .failure(let error):
            Log.shell.error("ignored URL \(url.absoluteString, privacy: .public): \(String(describing: error), privacy: .public)")
            return false
        }
    }

    // MARK: Capture

    private func beginCapture(_ mode: CaptureMode, onCaptured: @escaping (CaptureOutput) -> Void) {
        guard env.hasScreenPermission() else { return showPermissionWindow() }
        capture.begin(mode) { [unowned self] outcome in
            switch outcome {
            case .captured(let out): onCaptured(out)
            case .cancelled: break
            case .failed(.permissionDenied): showPermissionWindow()
            case .failed(let failure):
                Log.shell.error("capture failed: \(String(describing: failure), privacy: .public)")
                hud.show("Capture failed", symbol: "exclamationmark.triangle.fill")
            }
        }
    }

    func handleCaptured(_ out: CaptureOutput) {
        let record: CaptureRecord
        do {
            record = try env.store.add(out.image, kind: out.kind, pointScale: out.pointScale, now: env.clock())
        } catch {
            Log.shell.error("history write failed: \(error.localizedDescription, privacy: .public)")
            return hud.show("Could not store the capture", symbol: "exclamationmark.triangle.fill")
        }
        let s = settings.value
        if s.playSound { env.playSound() }
        if s.afterCapture.contains(.copy), ImageOutput.copy(out.image, to: env.pasteboard) {
            if !s.afterCapture.contains(.showOverlay) { hud.show("Copied to clipboard") }
        }
        if s.afterCapture.contains(.save) { save(out.image, announce: !s.afterCapture.contains(.showOverlay)) }
        if s.afterCapture.contains(.openEditor) { openEditor(record) }
        if s.afterCapture.contains(.showOverlay) { overlay.add(record: record, image: out.image) }
        history?.reload()
    }

    @discardableResult
    func save(_ image: CGImage, announce: Bool = true) -> URL? {
        let s = settings.value
        do {
            let url = try ImageOutput.save(image, format: s.imageFormat, folder: s.resolvedSaveFolder(default: env.defaultSaveFolder), date: env.clock())
            if announce { hud.show("Saved \(url.lastPathComponent)") }
            return url
        } catch {
            Log.shell.error("save failed: \(error.localizedDescription, privacy: .public)")
            hud.show("Could not save", symbol: "exclamationmark.triangle.fill")
            return nil
        }
    }

    // MARK: OCR

    func runOCR(on image: CGImage) {
        Task { [weak self] in
            do {
                let result = try await recognize(image)
                self?.finishOCR(result)
            } catch {
                self?.hud.show("Text recognition failed", symbol: "exclamationmark.triangle.fill")
            }
        }
    }

    func finishOCR(_ result: OCRResult) {
        guard !result.isEmpty else { return hud.show("No text found", symbol: "text.viewfinder") }
        ImageOutput.copy(text: result.clipboardText, to: env.pasteboard)
        if result.lines.isEmpty, let qr = result.qrPayloads.first {
            hud.show("Copied QR code: \(qr.prefix(40))", symbol: "qrcode")
        } else {
            let n = result.clipboardText.count
            hud.show("Copied \(n) character\(n == 1 ? "" : "s")", symbol: "text.viewfinder")
        }
    }

    // MARK: Quick Access cards

    private func cardAction(_ action: CardAction, _ card: QuickAccessCard) {
        switch action {
        case .copy:
            if ImageOutput.copy(card.image, to: env.pasteboard) { hud.show("Copied") }
        case .save:
            save(card.image)
        case .annotate:
            overlay.close(card)
            openEditor(card.record)
        case .pin:
            pins.pin(card.image, pointScale: card.record.pointScale)
            overlay.close(card)
        case .ocr:
            runOCR(on: card.image)
        case .close:
            overlay.close(card)
        }
    }

    // MARK: Editor and files

    @discardableResult
    func openEditor(_ record: CaptureRecord) -> EditorWindowController? {
        if let open = editors[record.id] {
            if env.isOnscreen { open.show() }
            return open
        }
        guard let (doc, assets) = try? env.store.openDocument(for: record) else {
            hud.show("Could not open the capture", symbol: "exclamationmark.triangle.fill")
            return nil
        }
        var callbacks = EditorCallbacks()
        weak var opened: EditorWindowController?
        callbacks.onSaveProject = { [unowned self] doc, assets in storeEdit(doc, assets, for: record) }
        callbacks.onPin = { [unowned self] image in pins.pin(image, pointScale: record.pointScale) }
        callbacks.onCopied = { [unowned self] in hud.show("Copied") }
        callbacks.onClose = { [unowned self] in
            if let e = opened, e.currentDocument != doc { storeEdit(e.currentDocument, e.assets, for: record) }
            editors[record.id] = nil
        }
        let editor = EditorWindowController(document: doc, assets: assets, callbacks: callbacks, defaults: env.defaults)
        opened = editor
        editor.pasteboard = env.pasteboard
        editors[record.id] = editor
        if env.isOnscreen {
            NSApp.activate(ignoringOtherApps: true)
            editor.show()
        }
        return editor
    }

    /// Edits live next to the original in the capture's history folder, so reopening it brings them back.
    private func storeEdit(_ doc: Document, _ assets: AssetStore, for record: CaptureRecord) {
        do { try env.store.saveDocument(doc, assets: assets, for: record) } catch {
            Log.shell.error("project save failed: \(error.localizedDescription, privacy: .public)")
        }
        thumbnails.invalidate(record.id, maxPixel: HistoryWindowController.thumbnailPixels)
    }

    /// The edited result when the capture has a saved project, else the original pixels.
    func currentImage(for record: CaptureRecord) -> CGImage? {
        if env.store.hasProject(record), let (doc, assets) = try? env.store.openDocument(for: record) {
            return Renderer.render(doc, assets: assets)
        }
        return CGImageSourceCreateWithURL(env.store.paths(for: record).image as CFURL, nil)
            .flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
    }

    func importFile(_ url: URL) {
        guard case .success(let file) = URLCommand.validatedImageURL(url) else {
            Log.shell.error("not an image file: \(url.path, privacy: .public)")
            return
        }
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return hud.show("Could not read the image", symbol: "exclamationmark.triangle.fill")
        }
        let dpi = ((CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])?[kCGImagePropertyDPIWidth] as? Double) ?? 72
        let scale = min(max((dpi / 72).rounded(), 1), 4)
        do {
            let record = try env.store.add(image, kind: .imported, pointScale: scale, now: env.clock())
            history?.reload()
            openEditor(record)
        } catch {
            hud.show("Could not import the image", symbol: "exclamationmark.triangle.fill")
        }
    }

    // MARK: Windows

    func showHistory() {
        if history == nil {
            let h = HistoryWindowController(env: env, thumbnails: thumbnails)
            h.actions = HistoryActions(
                restore: { [unowned self] r in
                    if let image = currentImage(for: r) { overlay.card(forRecord: r.id).map(overlay.close); overlay.add(record: r, image: image) }
                },
                edit: { [unowned self] r in openEditor(r) },
                copy: { [unowned self] r in
                    if let image = currentImage(for: r), ImageOutput.copy(image, to: env.pasteboard) { hud.show("Copied") }
                },
                reveal: { [unowned self] r in env.revealInFinder(env.store.paths(for: r).image) },
                delete: { [unowned self] r in deleteRecord(r) })
            history = h
        }
        history?.reload()
        env.present(history?.window)
    }

    func deleteRecord(_ record: CaptureRecord) {
        overlay.card(forRecord: record.id).map(overlay.close)
        editors[record.id]?.close()
        try? env.store.delete(record.id)
        history?.reload()
    }

    func showSettings() {
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController(ctx: SettingsContext(
                env: env, store: settings,
                hotKeyStatus: { [weak self] in self?.hotKeys?.status ?? [:] },
                loginError: { [weak self] in self?.loginError }))
        }
        settingsWindow?.refreshAll()
        env.present(settingsWindow?.window)
    }

    func showPermissionWindow() {
        if permissionWindow == nil { permissionWindow = PermissionWindowController(env: env) }
        env.present(permissionWindow?.window)
    }

    // MARK: Settings reactions

    private func applyCaptureSettings() {
        let s = settings.value
        capture.timerSeconds = s.timerSeconds
        capture.includeWindowShadow = s.windowShadow
    }

    private func settingsChanged(from old: Settings, to new: Settings) {
        applyCaptureSettings()
        if old.overlayCorner != new.overlayCorner || old.overlaySize != new.overlaySize || old.overlayAutoClose != new.overlayAutoClose {
            overlay.settingsChanged()
        }
        if old.customShortcuts != new.customShortcuts || old.disabledShortcuts != new.disabledShortcuts { hotKeys?.apply(new) }
        if old.launchAtLogin != new.launchAtLogin { applyLoginItem(new.launchAtLogin) }
        settingsWindow?.refreshAll()
    }

    private func applyLoginItem(_ wanted: Bool) {
        guard env.loginItem.isEnabled != wanted else { loginError = nil; return }
        do {
            try env.loginItem.setEnabled(wanted)
            loginError = nil
        } catch {
            settings.update { $0.launchAtLogin = !wanted }
            loginError = "Could not change login item: \(error.localizedDescription)"
        }
    }

    // MARK: Startup and upkeep

    func installHotKeys(backend: HotKeyBackend) {
        let manager = HotKeyManager(backend: backend) { [unowned self] id in perform(id: id) }
        manager.apply(settings.value)
        hotKeys = manager
    }

    /// Deletes captures older than the retention window and returns how many went.
    @discardableResult
    func prune() -> Int {
        let age = TimeInterval(settings.value.retentionDays) * 24 * 60 * 60
        guard let removed = try? env.store.prune(olderThan: age, now: env.clock()), !removed.isEmpty else { return 0 }
        for r in removed {
            overlay.card(forRecord: r.id).map(overlay.close)
            thumbnails.invalidate(r.id, maxPixel: HistoryWindowController.thumbnailPixels)
        }
        history?.reload()
        return removed.count
    }

    func startMaintenance() {
        prune()
        guard env.isOnscreen else { return }
        maintenanceTimer = Timer.scheduledTimer(withTimeInterval: 24 * 60 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.prune() }
        }
    }
}
