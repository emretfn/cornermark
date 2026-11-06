import AppKit
import CornermarkCapture
import CornermarkCore
import CornermarkEditor
import CornermarkVideoEditor
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
    let updates: UpdateController
    let recording: RecordingController
    let controls: RecordingControls
    let thumbnails = ThumbnailCache()
    private(set) var hotKeys: HotKeyManager?
    private(set) var history: HistoryWindowController?
    private(set) var settingsWindow: SettingsWindowController?
    private(set) var permissionWindow: PermissionWindowController?
    private(set) var whatsNewWindow: WhatsNewWindowController?
    private(set) var editors: [UUID: EditorWindowController] = [:]
    var videoEditors: [URL: VideoEditorWindowController] = [:]
    /// Builds the video editor for a project folder. A harness swaps it to decode frames on its own clock.
    var makeVideoEditor: (URL) throws -> VideoEditorWindowController = VideoEditorWindowController.open(folder:)
    private(set) var loginError: String?
    private var maintenanceTimer: Timer?
    /// Recordings a GIF is being made from.
    private(set) var makingGifs: Set<UUID> = []

    init(env: AppEnvironment) {
        self.env = env
        settings = SettingsStore(defaults: env.defaults)
        capture = CaptureController(source: env.screen, presentation: env.presentation)
        let store = settings
        overlay = QuickAccessManager(env: env) { store.value }
        pins = PinManager(env: env)
        hud = HUD(env: env)
        updates = UpdateController(env: env, hud: hud)
        recording = RecordingController(env: env) { store.value.resolvedSaveFolder(default: env.defaultSaveFolder) }
        controls = RecordingControls(env: env, recording: recording)
        // A corner the bubble was dragged to is where the next recording starts it.
        controls.camera.onCorner = { corner in store.update { $0.recording.camera.position = corner } }

        recording.onSaved = { [weak self] finished in Task { await self?.recordingFinished(finished) } }
        recording.onFailed = { [unowned self] message in hud.show(message, symbol: "exclamationmark.triangle.fill") }
        recording.onNotice = { [unowned self] message in hud.show(message, symbol: "exclamationmark.triangle.fill") }
        overlay.perform = { [unowned self] action, card in cardAction(action, card) }
        pins.onCopied = { [unowned self] in hud.show("Copied") }
        updates.closeEditors = { [unowned self] in closeAllEditors() }
        settings.observe { [unowned self] old, new in settingsChanged(from: old, to: new) }
        applyCaptureSettings()
        #if DEBUG
        (env.recordingTestWindow as? RecordingTestWindow)?.stage = { [weak self] in self?.testStage() }
        #endif
    }

    #if DEBUG
    private func testStage() -> NSView? {
        guard let root = AppEnvironment.isolatedRoot, let file = RecordingTestStageFile.read(root: root), file.stage == "audio" else { return nil }
        let ctx = SettingsContext(env: env, store: settings, hotKeyStatus: { [:] }, loginError: { nil })
        Log.shell.notice("test stage audio tour=\(file.tour ?? false, privacy: .public)")
        return AudioTestStage(ctx: ctx, recording: recording, controls: controls, tour: file.tour ?? false)
    }
    #endif

    // MARK: Actions

    func perform(_ action: AppAction) {
        switch action {
        case .capture(.recording) where recording.phase != .idle:
            // The same shortcut and tile that start a recording stop it.
            recording.stop()
        case .capture(let mode): beginCapture(mode) { [unowned self] out in handleCaptured(out) }
        case .captureOCR: beginCapture(.area) { [unowned self] out in runOCR(on: out.image) }
        case .openHistory: showHistory()
        case .openSettings: showSettings()
        case .checkForUpdates: Task { await updates.perform() }
        case .whatsNew: showWhatsNew()
        case .restoreLastOverlay: if overlay.restoreLast() == nil { hud.show("No closed overlay to restore", symbol: "info.circle") }
        case .hideOverlays: overlay.toggleHidden()
        case .openFile(let url): importFile(url)
        case .openRecording(let folder): openVideoEditor(folder)
        case .exportRecording(let folder): openVideoEditor(folder).map { $0.openExport(); $0.startExport() }
        case .startRecording(let target, let style): startRecording(target, style)
        case .stopRecording: recording.stop()
        case .controlRecording(.pause): recording.pause()
        case .controlRecording(.resume): recording.resume()
        case .controlRecording(.restart): recording.restart()
        case .changeCamera(let change): recording.changeCamera(change)
        case .openRecordingTestWindow: openRecordingTestWindow()
        case .filmVideoEditor(let folder, let scene): filmVideoEditor(folder, scene: scene)
        case .quit: env.quit()
        }
    }

    func perform(id: ActionID) {
        if let action = AppAction.make(id, timerSeconds: settings.value.timerSeconds) { perform(action) }
    }

    /// Entry for `cornermark://` links. Anything unrecognized is logged and ignored.
    @discardableResult
    func handle(url: URL) -> Bool {
        switch URLCommand.parse(url, timerSeconds: settings.value.timerSeconds) {
        case .success(let action):
            #if DEBUG
            Log.shell.notice("handled URL \(url.absoluteString, privacy: .public)")
            #endif
            perform(action)
            return true
        case .failure(let error):
            Log.shell.error("ignored URL \(url.absoluteString, privacy: .public): \(String(describing: error), privacy: .public)")
            return false
        }
    }

    // MARK: Recording

    private func startRecording(_ target: RecordingTarget, _ style: RecordingStyle) {
        guard env.hasScreenPermission() else { return showPermissionWindow() }
        recording.start(target, style: style, preferences: settings.value.recording)
    }

    /// Finishes every recording a crash cut off, lists it, and says so. A recording already listed is not listed twice.
    func recoverRecordings() async {
        guard let journal = env.recordingJournal else { return }
        for entry in journal.entries() {
            do {
                let finished = try await RecordingRecovery.finish(entry)
                let listed = env.store.list().contains { $0.video?.location.standardizedFileURL.path == entry.location.standardizedFileURL.path }
                if !listed { await recordingFinished(finished) }
                Log.shell.notice("recording recovered location=\(entry.location.lastPathComponent, privacy: .public) format=\(entry.format.rawValue, privacy: .public) seconds=\(String(format: "%.3f", finished.video.duration), privacy: .public) size=\(Int(finished.pixelSize.width), privacy: .public)x\(Int(finished.pixelSize.height), privacy: .public) alreadyListed=\(listed, privacy: .public)")
                hud.show("Recovered a recording that was cut off", symbol: "arrow.uturn.backward.circle.fill")
            } catch {
                Log.shell.error("recording not recovered location=\(entry.location.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)")
            }
            journal.close(entry)
        }
    }

    /// Lists the recording in history and shows its card. The video stays where the recorder saved it.
    func recordingFinished(_ finished: FinishedRecording) async {
        let name = finished.video.location.lastPathComponent
        let poster = await VideoPoster.image(of: finished.video) ?? VideoPoster.placeholder(finished.pixelSize)
        let record: CaptureRecord
        do {
            record = try env.store.addRecording(finished.video, poster: poster, kind: finished.kind, pixelSize: finished.pixelSize, now: env.clock())
        } catch {
            Log.shell.error("history write failed for a recording: \(error.localizedDescription, privacy: .public)")
            return hud.show("Saved \(name)")
        }
        history?.reload()
        Log.shell.notice("recording listed record=\(record.id.uuidString, privacy: .public) format=\(finished.video.format.rawValue, privacy: .public) seconds=\(String(format: "%.3f", finished.video.duration), privacy: .public) card=\(self.settings.value.recording.showQuickAccess, privacy: .public)")
        if settings.value.recording.showQuickAccess { overlay.add(record: record, image: poster) } else { hud.show("Saved \(name)") }
    }

    /// The recording's file, or nil after saying it is gone.
    func videoFile(_ record: CaptureRecord) -> RecordedVideo? {
        guard let video = record.video else { return nil }
        guard FileManager.default.fileExists(atPath: video.file.path) else {
            hud.show("Recording not found. Look for it in the save folder.", symbol: "exclamationmark.triangle.fill")
            return nil
        }
        return video
    }

    func play(_ record: CaptureRecord) { if let video = videoFile(record) { env.openURL(video.file) } }

    /// A recording copies as its file. A picture copies as its pixels.
    func copy(_ record: CaptureRecord, image: @autoclosure () -> CGImage?) {
        if record.isRecording {
            if let video = videoFile(record), ImageOutput.copy(file: video.file, to: env.pasteboard) { hud.show("Copied") }
        } else if let image = image(), ImageOutput.copy(image, to: env.pasteboard) {
            hud.show("Copied")
        }
    }

    /// Makes a GIF beside a finished video and lists it as its own recording, with its own card. A second request for the same video
    /// while one runs is ignored.
    func makeGif(from record: CaptureRecord) {
        guard record.video?.format == .video, !makingGifs.contains(record.id), let video = videoFile(record) else { return }
        makingGifs.insert(record.id)
        Log.shell.notice("gif requested record=\(record.id.uuidString, privacy: .public) from=\(video.location.lastPathComponent, privacy: .public)")
        hud.show("Converting to GIF", symbol: RecordedVideo.Format.gif.symbol)
        Task {
            defer { makingGifs.remove(record.id) }
            do {
                await recordingFinished(try await RecordingOutput.makeGif(from: video.file, to: RecordingOutput.gifBeside(video.file), kind: record.kind))
            } catch {
                Log.shell.error("gif not written record=\(record.id.uuidString, privacy: .public): \(String(describing: error), privacy: .public)")
                hud.show("Could not convert to GIF. Check that the video plays, then try again.", symbol: "exclamationmark.triangle.fill")
            }
        }
    }

    /// Finder shows a project folder itself, or the video file selected in its folder.
    func reveal(_ record: CaptureRecord) {
        if record.isRecording {
            if let video = videoFile(record) { env.revealInFinder(video.location) }
        } else {
            env.revealInFinder(env.store.paths(for: record).image)
        }
    }

    /// Only a scripted instance has one. Anywhere else the link is refused and nothing is drawn.
    private func openRecordingTestWindow() {
        guard let host = env.recordingTestWindow else {
            return Log.shell.error("recording refused: \(String(describing: RecordingRefusal.unavailable), privacy: .public)")
        }
        host.show()
    }

    /// Shows the editor for `folder` as the scripted instance's test window, then plays `scene` in it once a recording of that window
    /// runs, and stops the recording when the scene ends. Anywhere but a scripted debug instance the link is refused.
    private func filmVideoEditor(_ folder: URL, scene name: String) {
        #if DEBUG
        guard let host = env.recordingTestWindow, let scene = VideoEditorWindowController.scenes[name],
              let editor = openVideoEditor(folder), let window = editor.window else {
            return Log.shell.error("recording refused: no film of the video editor here, scene=\(name, privacy: .public)")
        }
        window.setContentSize(NSSize(width: 1100, height: 690))
        guard host.adopt(window) != nil else { return }
        editor.showBehind(at: window.frame.origin)
        Task { @MainActor [weak self, weak editor] in
            for _ in 0..<1200 where self?.recording.phase != .recording { try? await Task.sleep(nanoseconds: 50_000_000) }
            guard let self, let editor, recording.phase == .recording else {
                return Log.shell.error("film \(name, privacy: .public) gave up: no recording of the editor started")
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            Log.shell.notice("film \(name, privacy: .public) started")
            await editor.play(scene) { Log.shell.notice("film step \($0, privacy: .public)") }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            Log.shell.notice("film \(name, privacy: .public) done clips=\(editor.state.project.edits.clips.map { String(format: "%.3f-%.3f", $0.start, $0.end) }.joined(separator: ","), privacy: .public)")
            recording.stop()
        }
        #else
        Log.shell.error("recording refused: no film of the video editor in a release build")
        #endif
    }

    // MARK: Capture

    private func beginCapture(_ mode: CaptureMode, onCaptured: @escaping (CaptureOutput) -> Void) {
        guard env.hasScreenPermission() else { return showPermissionWindow() }
        capture.begin(mode) { [unowned self] outcome in
            switch outcome {
            case .captured(let out): onCaptured(out)
            case .record(let target, let style): startRecording(target, style)
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
            copy(card.record, image: card.image)
        case .play:
            play(card.record)
        case .makeGif:
            makeGif(from: card.record)
        case .edit:
            overlay.close(card)
            openEditor(card.record)
        case .reveal:
            reveal(card.record)
        case .save:
            if card.record.ownsVideo { saveVideo(card.record) } else { save(card.image) }
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
        // The editor edits pictures. A recording for editing opens in the video editor and a plain video plays.
        if record.isRecording {
            if record.opensVideoEditor, let video = videoFile(record) { openVideoEditor(video.location) } else { play(record) }
            return nil
        }
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
                copy: { [unowned self] r in copy(r, image: currentImage(for: r)) },
                reveal: { [unowned self] r in reveal(r) },
                makeGif: { [unowned self] r in makeGif(from: r) },
                delete: { [unowned self] r in deleteRecord(r) })
            history = h
        }
        history?.reload()
        env.present(history?.window)
    }

    /// Each editor stores unsaved edits as it closes.
    func closeAllEditors() {
        for editor in Array(editors.values) { editor.window?.close() }
        for editor in Array(videoEditors.values) { editor.window?.close() }
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

    func showWhatsNew() {
        if whatsNewWindow == nil { whatsNewWindow = WhatsNewWindowController(env: env) }
        whatsNewWindow?.reload()
        env.present(whatsNewWindow?.window)
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

    func checkForUpdatesIfWanted() {
        guard settings.value.checkForUpdatesAutomatically else { return }
        Task { await updates.checkAutomatically() }
    }

    /// Says so after an update, then remembers the running version. A first run has nothing to compare with.
    func announceUpdateIfNeeded() {
        guard let current = env.updateService.currentVersion else { return }
        if let previous = settings.value.lastRunVersion.flatMap(AppVersion.init), current > previous {
            hud.show("Updated to Cornermark \(current)")
        }
        settings.update { $0.lastRunVersion = current.description }
    }

    func startMaintenance() {
        Task { await recoverRecordings() }
        announceUpdateIfNeeded()
        prune()
        checkForUpdatesIfWanted()
        guard env.isOnscreen else { return }
        maintenanceTimer = Timer.scheduledTimer(withTimeInterval: 24 * 60 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                _ = self?.prune()
                self?.checkForUpdatesIfWanted()
            }
        }
    }
}
