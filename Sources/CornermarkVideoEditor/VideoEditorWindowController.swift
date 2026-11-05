import AppKit
import AVFoundation
import CornermarkCore
import CornermarkDesign

/// What the editor shows and plays. The project is the document; everything else is how it is being looked at.
public struct VideoEditorState: Equatable {
    public var project: RecordingProject
    public var transport: Transport
    public var section = EditorSection.cursor
    /// The preview fills the window and the editing columns step aside.
    public var isPreviewOnly = false
    public var volume: Float = 1
    public var isMuted = false
    public var export = ExportPhase.closed
    public var exportSettings = ExportSettings()

    public init(project: RecordingProject) {
        self.project = project
        transport = Transport(duration: project.source.duration)
    }
}

public enum ExportEvent: Equatable {
    case started(ExportPlan)
    case finished(ExportReport)
    /// At this fraction of the frames, with no file left behind.
    case cancelled(Double)
    case failed(String)
    /// The edits could not be written to the project file first, so nothing was exported.
    case notSaved(String)
}

public enum VideoEditorError: Error, Equatable {
    case noProject(String)
    case noVideo(String)
}

final class VideoEditorWindow: NSWindow {
    weak var editor: VideoEditorWindowController?

    /// Space plays and pauses wherever focus is, the way it does in a player, so a focused button never takes it.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, editor?.handleKey(event) == true { return }
        super.sendEvent(event)
    }
}

/// Opens a recording's project folder: settings on the left, the preview with playback in the middle, the timeline below.
/// The source video is only read. Edits are written to the project file when the window closes.
@MainActor
public final class VideoEditorWindowController: NSWindowController, NSWindowDelegate {
    public let folder: URL
    public private(set) var state: VideoEditorState
    public enum Closed: Equatable {
        case unchanged, saved
        case failed(String)
    }

    /// Called once as the window closes, after the project file was written if it changed.
    public var onClose: (Closed) -> Void = { _ in }
    /// Where a finished export is written.
    public var exportFolder: () -> URL = { FileManager.default.temporaryDirectory }
    public var onExport: (ExportEvent) -> Void = { _ in }

    private var saved: RecordingProject
    private var frames: SourceFrames
    private let clock: () -> Double
    private let preview = PreviewView()
    private let transportBar = TransportBar()
    private let timeline = TimelineView()
    private let inspector = InspectorView()
    private let header = HeaderBar()
    private let exportPanel = ExportPanel()
    private var exportJob: Task<ExportReport, Error>?
    private let bottomRule = Separator(axis: .horizontal)
    private var editingConstraints: [NSLayoutConstraint] = []
    private var previewOnlyConstraints: [NSLayoutConstraint] = []
    private var displayLink: CADisplayLink?
    /// Host time of the last move while paused. The link runs until the new picture arrives, or for half a second at most,
    /// since parking on the picture already shown brings no new one.
    private var awaitingSince: Double?
    static let frameWait = 0.5
    private var resumeAfterScrub = false
    private var enteredFullScreenForPreview = false
    private var preparation: Task<Void, Never>?

    /// Reads `project.json` from `folder`. Throws when the folder holds no project or its video is missing.
    public static func open(folder: URL) throws -> VideoEditorWindowController {
        let project: RecordingProject
        do { project = try RecordingProjectFile.read(from: folder) } catch { throw VideoEditorError.noProject(folder.lastPathComponent) }
        let video = folder.appendingPathComponent(project.source.video)
        guard FileManager.default.fileExists(atPath: video.path) else { throw VideoEditorError.noVideo(project.source.video) }
        return VideoEditorWindowController(folder: folder, project: project, frames: PlayerFrames(url: video))
    }

    /// `frames` decodes the source and `clock` is the host clock in seconds; a harness passes its own of both.
    public init(folder: URL, project: RecordingProject, frames: SourceFrames, clock: @escaping () -> Double = CACurrentMediaTime) {
        self.folder = folder
        self.saved = project
        self.frames = frames
        self.clock = clock
        state = VideoEditorState(project: project)
        let window = VideoEditorWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 780),
                                       styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.editor = self
        window.delegate = self
        window.title = folder.lastPathComponent
        window.minSize = NSSize(width: 900, height: 600)
        window.isReleasedWhenClosed = false
        window.backgroundColor = DS.Color.bgSurface
        window.collectionBehavior.insert(.fullScreenPrimary)
        buildContent(in: window)
        wire()
        window.center()
        refresh()
        preparation = Task { [weak self] in await self?.prepare() }
    }

    public required init?(coder: NSCoder) { fatalError("VideoEditorWindowController is created in code") }

    /// Waits for what the editor reads once: whether the source has sound, and the clip lane's pictures.
    public func ready() async { await preparation?.value }

    public var videoURL: URL { folder.appendingPathComponent(state.project.source.video) }
    /// Read once: the source is never written after recording.
    private lazy var sourceBytes: Int64? = ((try? FileManager.default.attributesOfItem(atPath: videoURL.path))?[.size] as? NSNumber)?.int64Value

    /// Finds a control by accessibility identifier anywhere in the window.
    public func view(identifier: String) -> NSView? {
        func find(_ v: NSView) -> NSView? {
            if v.accessibilityIdentifier() == identifier { return v }
            for s in v.subviews { if let hit = find(s) { return hit } }
            return nil
        }
        return window?.contentView.flatMap(find)
    }

    public func show() {
        window?.makeKeyAndOrderFront(nil)
        startDisplayLink()
    }

    // MARK: Layout

    private func buildContent(in window: NSWindow) {
        let content = NSView()
        window.contentView = content
        for v in [header, inspector, preview, transportBar, bottomRule, timeline, exportPanel] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        exportPanel.isHidden = true
        preview.pointSize = CGSize(width: max(state.project.source.pointWidth, 1), height: max(state.project.source.pointHeight, 1))
        timeline.duration = state.project.source.duration
        timeline.frameStep = 1 / Double(max(state.project.source.fps, 1))
        timeline.aspect = state.project.source.pointHeight > 0 ? CGFloat(state.project.source.pointWidth / state.project.source.pointHeight) : 16 / 9
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: content.topAnchor),
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            inspector.topAnchor.constraint(equalTo: header.bottomAnchor),
            inspector.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            preview.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            exportPanel.topAnchor.constraint(equalTo: header.bottomAnchor, constant: DS.Space.s4 - ExportPanel.inset),
            exportPanel.trailingAnchor.constraint(equalTo: header.exportButton.trailingAnchor, constant: ExportPanel.inset),
            transportBar.topAnchor.constraint(equalTo: preview.bottomAnchor),
            transportBar.leadingAnchor.constraint(equalTo: preview.leadingAnchor),
            transportBar.trailingAnchor.constraint(equalTo: preview.trailingAnchor),
            bottomRule.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bottomRule.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            timeline.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            timeline.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            timeline.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            timeline.heightAnchor.constraint(equalToConstant: TimelineView.Metrics.height),
        ])
        editingConstraints = [
            preview.topAnchor.constraint(equalTo: header.bottomAnchor),
            inspector.bottomAnchor.constraint(equalTo: bottomRule.topAnchor),
            preview.leadingAnchor.constraint(equalTo: inspector.trailingAnchor),
            transportBar.bottomAnchor.constraint(equalTo: bottomRule.topAnchor),
            bottomRule.bottomAnchor.constraint(equalTo: timeline.topAnchor),
        ]
        previewOnlyConstraints = [
            preview.topAnchor.constraint(equalTo: content.topAnchor),
            preview.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            transportBar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ]
        NSLayoutConstraint.activate(editingConstraints)
    }

    private func wire() {
        inspector.onSelect = { [unowned self] in select($0) }
        inspector.onCursor = { [unowned self] in setCursor($0) }
        transportBar.onCommand = { [unowned self] command in
            switch command {
            case .start: seek(to: 0)
            case .toggle: togglePlayback()
            case .end: seek(to: state.transport.duration)
            case .mute: setMuted(!state.isMuted)
            case .previewOnly: setPreviewOnly(!state.isPreviewOnly)
            }
        }
        transportBar.onVolume = { [unowned self] in setVolume($0) }
        header.exportButton.onPress { [unowned self] in state.export == .closed ? openExport() : closeExport() }
        exportPanel.onSettings = { [unowned self] in setExportSettings($0) }
        exportPanel.onExport = { [unowned self] in startExport() }
        exportPanel.onCancel = { [unowned self] in state.export.isExporting ? cancelExport() : closeExport() }
        timeline.onScrub = { [unowned self] t, phase in scrub(to: t, phase) }
    }

    private func prepare() async {
        await frames.load()
        let source = state.project.source
        let duration = source.duration
        if duration > 0 {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: videoURL))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 240, height: 240)
            let count = 24
            var images: [CGImage] = []
            for i in 0..<count {
                if Task.isCancelled { return }
                let t = duration * (Double(i) + 0.5) / Double(count)
                if let image = try? await generator.image(at: CMTime(seconds: t, preferredTimescale: 600)).image { images.append(image) }
            }
            timeline.thumbnails = images
        }
        refresh()
    }

    // MARK: Actions

    public func togglePlayback() {
        state.transport.toggle(now: clock())
        awaitFrame()
        tick()
    }

    public func seek(to t: Double) {
        state.transport.seek(to: t, now: clock())
        awaitFrame()
        tick()
    }

    public func select(_ section: EditorSection) {
        state.section = section
        refresh()
    }

    public func setCursor(_ cursor: CursorSettings) {
        state.project.edits.cursor = cursor
        refresh()
        tick()
    }

    public func setVolume(_ level: Float) {
        state.volume = min(max(level, 0), 1)
        state.isMuted = state.volume == 0
        applyVolume()
    }

    public func setMuted(_ muted: Bool) {
        state.isMuted = muted
        if !muted && state.volume == 0 { state.volume = 1 }
        applyVolume()
    }

    /// Hides the editing columns so the preview fills the window, and takes the window full screen when it is on screen.
    public func setPreviewOnly(_ on: Bool) {
        guard on != state.isPreviewOnly, let window else { return }
        state.isPreviewOnly = on
        applyLayout()
        let isFull = window.styleMask.contains(.fullScreen)
        if window.isVisible && on != isFull && (on || enteredFullScreenForPreview) {
            enteredFullScreenForPreview = on
            window.toggleFullScreen(nil)
        }
        refresh()
    }

    func handleKey(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
        guard mods.isEmpty else { return false }
        switch event.keyCode {
        case 49:
            togglePlayback()
            return true
        case 53 where state.isPreviewOnly:
            setPreviewOnly(false)
            return true
        default:
            return false
        }
    }

    private func scrub(to t: Double, _ phase: TimelineView.Scrub) {
        let now = clock()
        if phase == .began {
            resumeAfterScrub = state.transport.isPlaying
            state.transport.pause(now: now)
        }
        state.transport.seek(to: t, now: now)
        // Letting go at the end stays there instead of starting over from the beginning.
        if phase == .ended && resumeAfterScrub && t < state.transport.duration { state.transport.play(now: now) }
        awaitFrame()
        tick()
    }

    private func awaitFrame() { awaitingSince = clock() }

    private func applyVolume() {
        frames.volume = state.isMuted ? 0 : state.volume
        refresh()
    }

    private func applyLayout() {
        let on = state.isPreviewOnly
        NSLayoutConstraint.deactivate(on ? editingConstraints : previewOnlyConstraints)
        NSLayoutConstraint.activate(on ? previewOnlyConstraints : editingConstraints)
        if on { closeExport() }
        for v in [header, inspector, timeline, bottomRule] as [NSView] { v.isHidden = on }
        preview.inset = on ? 0 : DS.Space.s16
        // Watching is a dark surface, like the capture overlay: the letterbox and the playback row recede behind the picture.
        window?.appearance = on ? NSAppearance(named: .darkAqua) : nil
        window?.contentView?.layoutSubtreeIfNeeded()
    }

    // MARK: Export

    public func openExport() {
        guard state.export == .closed, !state.isPreviewOnly else { return }
        state.export = .choosing
        refresh()
        setPanelVisible(true)
        window?.makeFirstResponder(exportPanel.firstControl)
    }

    public func closeExport() {
        guard state.export == .choosing else { return }
        state.export = .closed
        refresh()
        setPanelVisible(false)
        window?.makeFirstResponder(header.exportButton)
    }

    public func setExportSettings(_ settings: ExportSettings) {
        state.exportSettings = settings
        refresh()
    }

    /// Writes changed edits to the project file, then renders the project as it is now. Edits made while it runs go into the next export.
    public func startExport() {
        guard state.export == .choosing else { return }
        if state.project != saved {
            do { try saveProject() } catch { return onExport(.notSaved(error.localizedDescription)) }
        }
        let project = state.project, settings = state.exportSettings, video = videoURL
        let output = Self.uniqueFile(in: exportFolder(), name: folder.lastPathComponent)
        state.export = .exporting(0)
        refresh()
        onExport(.started(ExportPlan(project: project, settings: settings, sourceBytes: sourceBytes)))
        let job = Task.detached {
            try await VideoExporter.export(project: project, video: video, settings: settings, to: output) { [weak self] fraction in
                Task { @MainActor in self?.exportProgressed(fraction) }
            }
        }
        exportJob = job
        Task { [weak self] in
            let result = await job.result
            self?.exportEnded(result)
        }
    }

    /// The file it was writing is removed.
    public func cancelExport() { exportJob?.cancel() }

    private func exportProgressed(_ fraction: Double) {
        guard case .exporting(let shown) = state.export, fraction > shown else { return }
        state.export = .exporting(fraction)
        exportPanel.show(state.export, settings: state.exportSettings, project: state.project, sourceBytes: sourceBytes)
    }

    private func exportEnded(_ result: Result<ExportReport, Error>) {
        guard case .exporting(let reached) = state.export else { return }
        exportJob = nil
        switch result {
        case .success(let report):
            state.export = .closed
            refresh()
            setPanelVisible(false)
            window?.makeFirstResponder(header.exportButton)
            announce("Export finished")
            onExport(.finished(report))
        case .failure(let error):
            state.export = .choosing
            refresh()
            window?.makeFirstResponder(exportPanel.firstControl)
            let cancelled = error is CancellationError
            announce(cancelled ? "Export cancelled" : "Export failed")
            onExport(cancelled ? .cancelled(reached) : .failed(String(describing: error)))
        }
    }

    private func announce(_ text: String) {
        NSAccessibility.post(element: exportPanel, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    static func uniqueFile(in folder: URL, name: String) -> URL {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var url = folder.appendingPathComponent("\(name).mp4")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(name) \(n).mp4")
            n += 1
        }
        return url
    }

    private func setPanelVisible(_ on: Bool) {
        guard let layer = exportPanel.layer ?? { exportPanel.wantsLayer = true; return exportPanel.layer }() else { return }
        guard window?.isVisible == true else { exportPanel.isHidden = !on; return }
        exportPanel.isHidden = false
        layer.removeAllAnimations()
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = on ? 0 : 1
        fade.toValue = on ? 1 : 0
        fade.duration = on ? DS.Motion.Duration.base : DS.Motion.Duration.fast
        fade.timingFunction = DS.Motion.Curve.easeOut
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, !on, state.export == .closed else { return }
            exportPanel.isHidden = true
        }
        layer.add(fade, forKey: "fade")
        if on && !DS.Motion.isReduced {
            let grow = CABasicAnimation(keyPath: "transform")
            let corner = CGPoint(x: layer.bounds.width - ExportPanel.inset, y: layer.bounds.height - ExportPanel.inset)
            var t = CATransform3DMakeTranslation(corner.x, corner.y, 0)
            t = CATransform3DScale(t, DS.Motion.enterScale, DS.Motion.enterScale, 1)
            t = CATransform3DTranslate(t, -corner.x, -corner.y, 0)
            grow.fromValue = t
            grow.toValue = CATransform3DIdentity
            grow.duration = DS.Motion.Duration.base
            grow.timingFunction = DS.Motion.Curve.easeOut
            layer.add(grow, forKey: "grow")
        }
        CATransaction.commit()
    }

    // MARK: Frames

    /// One display frame: the playhead from the clock, the frame `frameState` names, and every readout that follows it.
    public func tick() {
        let now = clock()
        state.transport.settle(now: now)
        let t = state.transport.time(at: now)
        let frame = frameState(state.project, outputTime: t)
        frames.follow(sourceTime: frame.sourceTime, playing: state.transport.isPlaying)
        if let image = frames.frame(at: frame.sourceTime) {
            preview.image = image
            if !state.transport.isPlaying { awaitingSince = nil }
        }
        preview.state = frame
        timeline.time = t
        updateTransportBar(t)
        let waiting = awaitingSince.map { now - $0 < Self.frameWait } ?? false
        if !waiting { awaitingSince = nil }
        displayLink?.isPaused = !(state.transport.isPlaying || waiting)
    }

    /// The picture the preview shows now, nil before the first frame arrives.
    public var previewImage: CGImage? { preview.image }
    /// The frame the preview drew last.
    public var previewState: FrameState? { preview.state }

    private func refresh() {
        inspector.show(state.section, cursor: state.project.edits.cursor)
        header.show(state.export)
        exportPanel.show(state.export, settings: state.exportSettings, project: state.project, sourceBytes: sourceBytes)
        updateTransportBar(state.transport.time(at: clock()))
    }

    private func updateTransportBar(_ t: Double) {
        transportBar.update(time: t, duration: state.transport.duration, playing: state.transport.isPlaying, hasAudio: frames.hasAudio,
                            muted: state.isMuted, volume: state.volume, previewOnly: state.isPreviewOnly)
    }

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        let link = preview.displayLink(target: self, selector: #selector(displayTick))
        link.add(to: .main, forMode: .common)
        displayLink = link
        awaitFrame()
        tick()
    }

    @objc private func displayTick() { tick() }

    // MARK: Window

    public func windowWillClose(_ notification: Notification) {
        preparation?.cancel()
        exportJob?.cancel()
        displayLink?.invalidate()
        displayLink = nil
        state.transport.pause(now: clock())
        frames.follow(sourceTime: state.transport.time(at: clock()), playing: false)
        guard state.project != saved else { return onClose(.unchanged) }
        do {
            try saveProject()
            onClose(.saved)
        } catch {
            onClose(.failed(error.localizedDescription))
        }
    }

    private func saveProject() throws {
        try RecordingProjectFile.write(state.project, to: folder)
        saved = state.project
    }

    public func windowDidExitFullScreen(_ notification: Notification) {
        guard enteredFullScreenForPreview else { return }
        enteredFullScreenForPreview = false
        if state.isPreviewOnly {
            state.isPreviewOnly = false
            applyLayout()
            refresh()
        }
    }
}
