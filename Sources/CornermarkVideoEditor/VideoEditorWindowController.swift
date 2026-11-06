import AppKit
import AVFoundation
import CornermarkCore
import CornermarkDesign
import UniformTypeIdentifiers

/// What the editor shows and plays. The project is the document; everything else is how it is being looked at.
public struct VideoEditorState: Equatable {
    public var project: RecordingProject
    public var transport: Transport
    public var section = EditorSection.cursor
    /// The zoom picked on the timeline. Its settings take the panel over until it is let go.
    public var selectedZoom: UUID?
    /// The preview fills the window and the editing columns step aside.
    public var isPreviewOnly = false
    public var volume: Float = 1
    public var isMuted = false
    public var export = ExportPhase.closed
    public var exportSettings = ExportSettings()
    /// The clip Delete removes, picked on the clip lane. Without one, Delete removes the clip under the playhead.
    public var selectedClip: Int?

    public init(project: RecordingProject) {
        self.project = project
        transport = Transport(duration: project.outputDuration)
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

public struct FrameExport: Equatable {
    public var image: CGImage
    /// Seconds into the finished video.
    public var outputTime: Double
    /// Pixels per recorded point, so the picture keeps the recording's density.
    public var pointScale: Double
}

public enum FrameExportEvent: Equatable {
    case finished(FrameExport)
    case failed(String)
}

public enum VideoEditorError: Error, Equatable {
    case noProject(String)
    case noVideo(String)
}

final class VideoEditorWindow: NSWindow {
    weak var editor: VideoEditorWindowController?

    // The window answers the Edit menu's Undo and Redo before its controller would, so it hands them to the editor's history.
    @objc(undo:) func undoEdit(_ sender: Any?) { editor?.undo() }
    @objc(redo:) func redoEdit(_ sender: Any?) { editor?.redo() }
    @objc(saveDocument:) func saveDocument(_ sender: Any?) { editor?.save() }
    @objc(saveDocumentAs:) func saveDocumentAs(_ sender: Any?) { editor?.chooseAndSaveAs() }
    @objc(exportVideo:) func exportVideo(_ sender: Any?) { editor?.perform(.export) }
    @objc(exportCurrentFrame:) func exportCurrentFrame(_ sender: Any?) { editor?.perform(.exportFrame) }

    override func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case Selector(("undo:")): return editor?.canUndo ?? false
        case Selector(("redo:")): return editor?.canRedo ?? false
        case Selector(("saveDocument:")), Selector(("saveDocumentAs:")): return editor != nil
        case Selector(("exportVideo:")): return editor.map { !$0.state.isPreviewOnly } ?? false
        case Selector(("exportCurrentFrame:")): return editor != nil
        default: return super.validateMenuItem(item)
        }
    }

    /// Space plays and pauses wherever focus is, the way it does in a player, so a focused button never takes it.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, editor?.handleKey(event) == true { return }
        super.sendEvent(event)
    }
}

/// Opens a project: settings on the left, the preview with playback in the middle, the timeline below. The source video is only read.
/// Edits are written to the project file by Save, before an export, and when the window closes, so closing never asks and never loses them.
@MainActor
public final class VideoEditorWindowController: NSWindowController, NSWindowDelegate {
    /// The project's folder. Save As moves the editor to the copy.
    public private(set) var folder: URL
    public private(set) var state: VideoEditorState
    public enum SaveResult: Equatable {
        case unchanged, saved
        case failed(String)
    }

    /// Called once as the window closes, after the project file was written if it changed.
    public var onClose: (SaveResult) -> Void = { _ in }
    /// Called after Save, and after a close the window refused because the edits could not be written.
    public var onSave: (SaveResult) -> Void = { _ in }
    /// Called after Save As wrote the copy, with the folder the editor left and the one it now edits.
    public var onSaveAs: (_ from: URL, _ to: URL) -> Void = { _, _ in }
    /// Asks where Save As writes, offering `name`, and hands back the package to write, or nothing when the viewer cancels.
    public var chooseSaveLocation: (NSWindow?, String, @escaping (URL?) -> Void) -> Void = { window, name, done in
        let panel = NSSavePanel()
        panel.allowedContentTypes = [VideoEditorWindowController.packageType]
        panel.nameFieldStringValue = name
        panel.canCreateDirectories = true
        guard let window else { return done(panel.runModal() == .OK ? panel.url : nil) }
        panel.beginSheetModal(for: window) { done($0 == .OK ? panel.url : nil) }
    }

    public nonisolated static let packageType = UTType(exportedAs: "local.emretufan.cornermark.video-project", conformingTo: .package)
    /// Where a finished export is written.
    public var exportFolder: () -> URL = { FileManager.default.temporaryDirectory }
    public var onExport: (ExportEvent) -> Void = { _ in }
    /// Called with the picture Export Current Frame drew, or why it could not.
    public var onExportFrame: (FrameExportEvent) -> Void = { _ in }
    /// The latest Export Current Frame, for a check to wait on.
    public private(set) var frameJob: Task<Void, Never>?
    /// Asks for a picture to put behind the recording and hands back its file, or nothing when the viewer cancels.
    public var chooseImage: (NSWindow?, @escaping (URL?) -> Void) -> Void = { window, done in
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        guard let window else { return done(panel.runModal() == .OK ? panel.url : nil) }
        panel.beginSheetModal(for: window) { done($0 == .OK ? panel.url : nil) }
    }

    private var saved: RecordingProject
    /// Whether Save has written this session, so the header can say the edits are saved rather than say nothing.
    private var hasSaved = false
    private var history: UndoHistory<RecordingProject.Edits>
    /// The added background picture as last read, keyed by its file name.
    private var backgroundPicture: (file: String?, image: CGImage?) = (nil, nil)
    private var frames: SourceFrames
    /// The camera file's pictures, when the recording has a camera. A harness can set its own.
    public var cameraFrames: SourceFrames? { didSet { cameraFrames?.isSilent = true } }
    /// Whether playback may make sound. Off until the app turns it on for an editor on screen, so an editor in a harness or a scripted
    /// instance never plays the recording's sound.
    public var playsSound = false { didSet { applyVolume() } }
    /// The decoder of the source, for a check to read.
    public var sourceFrames: SourceFrames { frames }
    private let clock: () -> Double
    private let preview = PreviewView()
    private let transportBar = TransportBar()
    let timeline = TimelineView()
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
    /// A drag on the ruler under way. The paused preview waits for its end to draw a blurred frame, which costs several full drawings.
    private var isScrubbing = false
    private var enteredFullScreenForPreview = false
    private var preparation: Task<Void, Never>?

    /// Reads `project.json` from `folder`. Throws when the folder holds no project or its video is missing.
    public static func open(folder: URL) throws -> VideoEditorWindowController {
        let project: RecordingProject
        do { project = try RecordingProjectFile.read(from: folder) } catch { throw VideoEditorError.noProject(folder.lastPathComponent) }
        let video = folder.appendingPathComponent(project.source.video)
        guard FileManager.default.fileExists(atPath: video.path) else { throw VideoEditorError.noVideo(project.source.video) }
        var sound: [AudioTrack: URL] = [:]
        for track in project.source.audioTracks {
            if let name = project.source.file(for: track) { sound[track] = folder.appendingPathComponent(name) }
        }
        let editor = VideoEditorWindowController(folder: folder, project: project, frames: PlayerFrames(url: video, sound: sound))
        if let name = project.source.camera, FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path) {
            let camera = PlayerFrames(url: folder.appendingPathComponent(name))
            camera.volume = 0
            editor.cameraFrames = camera
        }
        return editor
    }

    /// `frames` decodes the source and `clock` is the host clock in seconds; a harness passes its own of both.
    public init(folder: URL, project: RecordingProject, frames: SourceFrames, clock: @escaping () -> Double = CACurrentMediaTime) {
        self.folder = folder
        self.saved = project
        history = UndoHistory(project.edits)
        self.frames = frames
        self.clock = clock
        state = VideoEditorState(project: project)
        let window = VideoEditorWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 780),
                                       styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.editor = self
        window.delegate = self
        window.title = RecordingProjectFile.displayName(of: folder)
        window.minSize = NSSize(width: 900, height: 600)
        window.isReleasedWhenClosed = false
        window.backgroundColor = DS.Color.bgSurface
        window.collectionBehavior.insert(.fullScreenPrimary)
        frames.isSilent = true
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
        timeline.timeline = state.project.timeline
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
        inspector.onCursorSizeEnd = { [unowned self] in history.endCoalescing() }
        inspector.onClicks = { [unowned self] in setClickHighlight($0) }
        inspector.backgroundPanel.onChange = { [unowned self] in setBackground($0, coalescing: $1) }
        inspector.backgroundPanel.onSliderEnd = { [unowned self] in history.endCoalescing() }
        inspector.backgroundPanel.onAddImage = { [unowned self] in addBackgroundImage() }
        inspector.cameraPanel.onChange = { [unowned self] in setCamera($0) }
        inspector.keystrokesPanel.onChange = { [unowned self] in setKeystrokes($0) }
        inspector.audioPanel.onChange = { [unowned self] in setAudio($0, coalescing: $1) }
        inspector.audioPanel.onSliderEnd = { [unowned self] in history.endCoalescing() }
        inspector.motionBlurPanel.onChange = { [unowned self] in setMotionBlur($0, coalescing: $1) }
        inspector.motionBlurPanel.onSliderEnd = { [unowned self] in history.endCoalescing() }
        transportBar.onCommand = { [unowned self] command in
            switch command {
            case .start: seek(to: 0)
            case .toggle: togglePlayback()
            case .end: seek(to: state.transport.duration)
            case .mute: setMuted(!state.isMuted)
            case .previewOnly: setPreviewOnly(!state.isPreviewOnly)
            case .split: splitAtPlayhead()
            case .delete: deleteClip()
            }
        }
        transportBar.onVolume = { [unowned self] in setVolume($0) }
        header.exportButton.onPress { [unowned self] in state.export == .closed ? openExport() : closeExport() }
        exportPanel.onSettings = { [unowned self] in setExportSettings($0) }
        exportPanel.onExport = { [unowned self] in startExport() }
        exportPanel.onCancel = { [unowned self] in state.export.isExporting ? cancelExport() : closeExport() }
        timeline.onScrub = { [unowned self] t, phase in scrub(to: t, phase) }
        timeline.onSelect = { [unowned self] in selectClip($0) }
        timeline.onTrim = { [unowned self] trim, moved, phase in trimmed(trim, to: moved, phase) }
        timeline.onNudge = { [unowned self] edge, seconds in nudge(edge, by: seconds) }
        let lane = timeline.zoomLane
        lane.onAdd = { [unowned self] from, to in addZoom(from: from, to: to) }
        lane.onSelect = { [unowned self] in selectZoom($0) }
        lane.onGesture = { [unowned self] gesture, phase in dragZoom(gesture, phase) }
        lane.menuForZoom = { [unowned self] in zoomMenu(for: $0) }
        lane.onKey = { [unowned self] in zoomKey($0) }
        inspector.zoomPanel.onChange = { [unowned self] in zoomPanelChanged($0) }
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
            // Each clip shows pictures of its own stretch, so a picture may be off by half a slot at most, not by a keyframe interval.
            let slack = CMTime(seconds: duration / Double(count) / 2, preferredTimescale: 600)
            generator.requestedTimeToleranceBefore = slack
            generator.requestedTimeToleranceAfter = slack
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
        state.selectedZoom = nil
        refresh()
    }

    /// A run of size changes, such as one slider drag, is one undo step.
    public func setCursor(_ cursor: CursorSettings) {
        var edits = state.project.edits
        var sameButSize = cursor
        sameButSize.scale = edits.cursor.scale
        let sizeOnly = sameButSize == edits.cursor
        edits.cursor = cursor
        commit(edits, coalescing: sizeOnly ? "cursor.scale" : nil)
    }

    /// The camera's look, kept apart from the full-screen moments the recording made.
    public func setCamera(_ camera: CameraBubble) {
        var edits = state.project.edits
        var next = camera
        next.fullScreen = edits.camera.fullScreen
        edits.camera = next
        commit(edits)
    }

    public func setKeystrokes(_ keystrokes: KeystrokeDisplay) {
        var edits = state.project.edits
        edits.keystrokes = keystrokes
        commit(edits)
    }

    /// `key` folds one level drag into one undo step.
    public func setAudio(_ audio: AudioEdits, coalescing key: CoalescingKey? = nil) {
        var edits = state.project.edits
        edits.audio = audio
        commit(edits, coalescing: key)
    }

    public func setMotionBlur(_ blur: MotionBlur, coalescing key: CoalescingKey? = nil) {
        var edits = state.project.edits
        edits.motionBlur = blur
        commit(edits, coalescing: key)
    }

    public func setClickHighlight(_ clicks: ClickHighlight) {
        var edits = state.project.edits
        edits.clicks = clicks
        commit(edits)
    }

    // MARK: Clips

    /// Cuts the clip under the playhead in two at the playhead. Nothing happens within a frame of the clip's ends.
    public func splitAtPlayhead() {
        let t = state.transport.time(at: clock())
        guard let next = state.project.timeline.splitting(at: t) else { return }
        commit(clips: next, playhead: t)
    }

    /// Removes the picked clip, or the one under the playhead. The video keeps at least one clip.
    public func deleteClip() {
        let timeline = state.project.timeline
        let index = target(in: timeline)
        guard let next = timeline.deleting(index) else { return }
        commit(clips: next, playhead: timeline.starts[index])
    }

    public func selectClip(_ index: Int?) {
        state.selectedClip = index.flatMap { state.project.timeline.clips.indices.contains($0) ? $0 : nil }
        if state.selectedClip != nil { state.selectedZoom = nil }
        timeline.selection = state.selectedClip
        refresh()
    }

    /// `key` folds a run of changes, such as one slider drag, into one undo step.
    public func setBackground(_ background: VideoBackground, coalescing key: CoalescingKey? = nil) {
        var edits = state.project.edits
        edits.background = background
        commit(edits, coalescing: key)
    }

    /// Asks for a picture, copies it into the project folder and puts it behind the recording.
    public func addBackgroundImage() {
        chooseImage(window) { [weak self] url in
            guard let self, let url else { return }
            do { try useBackgroundImage(at: url) } catch { inspector.backgroundPanel.showProblem("\(url.lastPathComponent) could not be added. Choose another image.") }
        }
    }

    /// The copy keeps the original's bytes under a name of its own, so undo can go back to an earlier picture.
    public func useBackgroundImage(at url: URL) throws {
        let ext = url.pathExtension.isEmpty ? "png" : url.pathExtension.lowercased()
        let name = "background-\(UUID().uuidString.prefix(8).lowercased()).\(ext)"
        try FileManager.default.copyItem(at: url, to: folder.appendingPathComponent(name))
        var background = state.project.edits.background
        background.image = name
        background.fill = .image
        setBackground(background)
    }

    // MARK: Zooms

    private var zoomLane: ZoomLane { ZoomLane(state.project.edits.zooms, duration: state.transport.duration) }
    private var playhead: Double { state.transport.time(at: clock()) }

    /// Adds a zoom from `from` to `to`, or of the default length at `from` when `to` is nil, aimed where the pointer was halfway
    /// through it, and picks it.
    @discardableResult
    public func addZoom(from: Double, to: Double? = nil) -> Zoom? {
        guard let added = zoomLane.adding(from: from, to: to) else { return nil }
        let zoom = added.zoom
        let center = pointerCenter(at: (zoom.start + zoom.end) / 2)
        let lane = added.lane.updating(zoom.id) { $0.center = center }
        state.selectedZoom = zoom.id
        state.selectedClip = nil
        timeline.selection = nil
        commitZooms(lane)
        return lane.zoom(zoom.id)
    }

    public func addZoomAtPlayhead() { addZoom(from: playhead) }

    /// Nil lets go of the picked zoom, and the panel returns to the section.
    public func selectZoom(_ id: UUID?) {
        state.selectedZoom = id.flatMap { zoomLane.zoom($0) != nil ? $0 : nil }
        if state.selectedZoom != nil {
            state.selectedClip = nil
            timeline.selection = nil
        }
        refresh()
    }

    public func setZoomScale(_ scale: Double, of id: UUID, dragging: Bool = false) {
        let s = min(max(scale, Zoom.scaleRange.lowerBound), Zoom.scaleRange.upperBound)
        commitZooms(zoomLane.updating(id) { $0.scale = s }, coalescing: dragging ? CoalescingKey("zoom.scale-\(id)") : nil)
    }

    public func setZoomMode(_ mode: ZoomMode, of id: UUID) { commitZooms(zoomLane.updating(id) { $0.mode = mode }) }

    public func applyZoomLevelToAll(from id: UUID) {
        guard let zoom = zoomLane.zoom(id) else { return }
        commitZooms(zoomLane.settingScale(zoom.scale))
    }

    /// Cuts the zoom at the playhead in two and picks the second part.
    public func splitZoom(_ id: UUID) {
        guard let split = zoomLane.splitting(id, at: playhead) else { return }
        state.selectedZoom = split.second.id
        commitZooms(split.lane)
    }

    public func duplicateZoom(_ id: UUID) {
        guard let copy = zoomLane.duplicating(id) else { return }
        state.selectedZoom = copy.copy.id
        commitZooms(copy.lane)
    }

    public func removeZoom(_ id: UUID) { commitZooms(zoomLane.removing(id)) }

    /// Command-B splits the picked zoom at the playhead, else the clip under it.
    public func splitSelection() {
        if let id = state.selectedZoom { splitZoom(id) } else { splitAtPlayhead() }
    }

    private func zoomKey(_ key: ZoomLaneView.KeyCommand) {
        let lane = zoomLane
        guard !lane.zooms.isEmpty else { return }
        let picked = state.selectedZoom.flatMap { lane.index(of: $0) }
        switch key {
        case .pick(let step):
            let next = picked.map { min(max($0 + step, 0), lane.zooms.count - 1) }
                ?? (step > 0 ? lane.zooms.firstIndex { $0.end > playhead } ?? lane.zooms.count - 1 : lane.zooms.lastIndex { $0.start < playhead } ?? 0)
            selectZoom(lane.zooms[next].id)
        case .move(let by):
            guard let i = picked else { return }
            let zoom = lane.zooms[i]
            commitZooms(lane.moving(zoom.id, to: zoom.start + by), coalescing: CoalescingKey("zoom.key.move-\(zoom.id)"))
        case .resizeEnd(let by):
            guard let i = picked else { return }
            let zoom = lane.zooms[i]
            commitZooms(lane.resizing(zoom.id, .end, to: zoom.end + by), coalescing: CoalescingKey("zoom.key.end-\(zoom.id)"))
        }
    }

    /// Delete removes the picked zoom, else the picked clip or the one under the playhead.
    public func deleteSelection() {
        if let id = state.selectedZoom { removeZoom(id) } else { deleteClip() }
    }

    public func removeAllZooms() { commitZooms(ZoomLane([], duration: state.transport.duration)) }

    private func dragZoom(_ gesture: ZoomLaneView.Gesture, _ phase: TimelineView.Scrub) {
        switch gesture {
        case .move(let id, let start): commitZooms(zoomLane.moving(id, to: start), coalescing: "zoom.drag")
        case .resize(let id, let edge, let t): commitZooms(zoomLane.resizing(id, edge, to: t), coalescing: "zoom.drag")
        }
        if phase == .ended { history.endCoalescing() }
    }

    private func zoomPanelChanged(_ change: ZoomPanel.Change) {
        guard let id = state.selectedZoom else { return }
        switch change {
        case .scale(let s, let dragging): setZoomScale(s, of: id, dragging: dragging)
        case .mode(let mode): setZoomMode(mode, of: id)
        case .applyToAll: applyZoomLevelToAll(from: id)
        case .remove: removeZoom(id)
        }
    }

    /// The pointer's place at `t` as fractions of the picture, or the middle when the recording has no pointer.
    private func pointerCenter(at t: Double) -> ZoomPoint {
        let source = state.project.source
        guard source.pointWidth > 0, source.pointHeight > 0,
              let p = PointerTrack.position(state.project.events.pointer, at: frameState(state.project, outputTime: t).sourceTime) else { return .middle }
        return ZoomPoint(x: min(max(p.x / source.pointWidth, 0), 1), y: min(max(p.y / source.pointHeight, 0), 1))
    }

    /// The zoom's right-click menu. Its items act on that zoom, whichever is picked when one is chosen.
    func zoomMenu(for id: UUID) -> NSMenu? {
        guard let zoom = zoomLane.zoom(id) else { return nil }
        let menu = NSMenu(title: "Zoom")
        menu.autoenablesItems = false
        func item(_ title: String, enabled: Bool = true, state on: Bool = false, _ action: @escaping () -> Void) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.onPick(action)
            item.isEnabled = enabled
            item.state = on ? .on : .off
            return item
        }
        let level = NSMenuItem(title: "Level", action: nil, keyEquivalent: "")
        level.submenu = NSMenu(title: "Level")
        for s in Zoom.levels {
            level.submenu?.addItem(item(Zoom.percent(s), state: abs(s - zoom.scale) < 0.005) { [unowned self] in setZoomScale(s, of: id) })
        }
        menu.addItem(level)
        menu.addItem(item("Apply Level to All", enabled: zoomLane.zooms.count > 1) { [unowned self] in applyZoomLevelToAll(from: id) })
        let mode = NSMenuItem(title: "Mode", action: nil, keyEquivalent: "")
        mode.submenu = NSMenu(title: "Mode")
        for m in ZoomMode.allCases {
            mode.submenu?.addItem(item(m.title, state: m == zoom.mode) { [unowned self] in setZoomMode(m, of: id) })
        }
        menu.addItem(mode)
        menu.addItem(.separator())
        menu.addItem(item("Split at Playhead", enabled: zoomLane.splitting(id, at: playhead) != nil) { [unowned self] in splitZoom(id) })
        menu.addItem(item("Duplicate", enabled: zoomLane.duplicating(id) != nil) { [unowned self] in duplicateZoom(id) })
        menu.addItem(.separator())
        menu.addItem(item("Remove Zoom") { [unowned self] in removeZoom(id) })
        menu.addItem(item("Remove All Zooms") { [unowned self] in removeAllZooms() })
        return menu
    }

    private func commitZooms(_ lane: ZoomLane, coalescing key: CoalescingKey? = nil) {
        var edits = state.project.edits
        edits.zooms = lane.zooms
        commit(edits, coalescing: key)
    }

    // MARK: Undo

    public var canUndo: Bool { history.canUndo }
    public var canRedo: Bool { history.canRedo }

    public func undo() {
        timeline.cancelTrim()
        guard history.undo() else { return }
        show(history.present, playhead: state.transport.time(at: clock()))
    }

    public func redo() {
        timeline.cancelTrim()
        guard history.redo() else { return }
        show(history.present, playhead: state.transport.time(at: clock()))
    }

    private func target(in clips: ClipTimeline) -> Int {
        state.selectedClip.flatMap { clips.clips.indices.contains($0) ? $0 : nil } ?? clips.clipIndex(at: state.transport.time(at: clock()))
    }

    /// The playhead rides on the dragged edge, so the preview shows the frame the clip now starts or ends on.
    private func trimmed(_ trim: TimelineView.Trim, to moved: ClipTimeline, _ phase: TimelineView.Scrub) {
        if phase == .began { state.transport.pause(now: clock()) }
        let clip = moved.clips[trim.index], start = moved.starts[trim.index]
        let edge = trim.edge == .start ? start : start + clip.duration - moved.frame
        var edits = state.project.edits
        edits.clips = moved.clips
        commit(edits, coalescing: "trim", keeping: trim.index, playhead: edge)
        if phase == .ended { history.endCoalescing() }
    }

    /// Moves an edge of the picked clip, or of the clip under the playhead, from the keyboard. Presses in a row on one edge are one undo step.
    public func nudge(_ edge: ClipTimeline.Edge, by seconds: Double) {
        timeline.cancelTrim()
        let clips = state.project.timeline
        let index = target(in: clips)
        let clip = clips.clips[index]
        // Whole frames from the edge, so an edge off the grid, like the end of a recording, still stops on the frame next to it.
        let at = (edge == .start ? clip.start : clip.end) * clips.fps, steps = abs(seconds) * clips.fps
        let frame = seconds < 0 ? (at - 1e-6).rounded(.up) - steps : (at + 1e-6).rounded(.down) + steps
        let moved = clips.trimming(index, edge, to: frame / clips.fps)
        let start = moved.starts[index]
        var edits = state.project.edits
        edits.clips = moved.clips
        state.transport.pause(now: clock())
        commit(edits, coalescing: CoalescingKey("nudge-\(index)-\(edge)"), keeping: index,
               playhead: edge == .start ? start : start + moved.clips[index].duration - moved.frame)
    }

    private func commit(clips next: ClipTimeline, playhead: Double) {
        timeline.cancelTrim()
        var edits = state.project.edits
        edits.clips = next.clips
        commit(edits, playhead: playhead)
    }

    private func commit(_ edits: RecordingProject.Edits, coalescing key: CoalescingKey? = nil, keeping: Int? = nil, playhead: Double? = nil) {
        history.record(edits, coalescing: key)
        show(history.present, keeping: keeping, playhead: playhead ?? state.transport.time(at: clock()))
    }

    private func show(_ edits: RecordingProject.Edits, keeping: Int? = nil, playhead: Double) {
        let clipsChanged = edits.clips != state.project.edits.clips
        state.project.edits = edits
        if let id = state.selectedZoom, !edits.zooms.contains(where: { $0.id == id }) { state.selectedZoom = nil }
        if clipsChanged {
            let clips = state.project.timeline
            state.transport.setDuration(clips.duration, playheadAt: playhead, now: clock())
            // Indices move when clips come and go, so only an edge edit keeps its clip picked.
            state.selectedClip = keeping.flatMap { clips.clips.indices.contains($0) ? $0 : nil }
            timeline.selection = state.selectedClip
            timeline.timeline = clips
            awaitFrame()
        }
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
        // A field being typed in keeps Space, Delete and Esc, so Delete takes back a digit instead of a clip.
        if event.modifierFlags.intersection([.command, .control, .option]).isEmpty, window?.firstResponder is NSText { return false }
        guard let press = EditorShortcuts.match(event, in: .window) else { return false }
        return perform(press.command)
    }

    /// Runs a command the window answers. The timeline and the zoom lane answer their own keys from the same table.
    @discardableResult
    public func perform(_ command: EditorCommand) -> Bool {
        switch command {
        case .playPause: togglePlayback()
        case .escape: return escape()
        case .fullScreen: setPreviewOnly(!state.isPreviewOnly)
        case .split: splitSelection()
        case .delete: deleteSelection()
        case .addZoom: addZoomAtPlayhead()
        case .duplicateZoom:
            guard let id = state.selectedZoom else { return false }
            duplicateZoom(id)
        case .undo: undo()
        case .redo: redo()
        case .save: save()
        case .saveAs: chooseAndSaveAs()
        case .export: openExport()
        case .exportFrame: exportFrame()
        case .step, .jump, .trimStart, .trimEnd, .pickZoom, .moveZoom, .resizeZoom, .openVideo: return false
        }
        return true
    }

    private func escape() -> Bool {
        if state.isPreviewOnly { setPreviewOnly(false); return true }
        if state.selectedZoom != nil { selectZoom(nil); return true }
        guard state.selectedClip != nil else { return false }
        selectClip(nil)
        return true
    }

    private func scrub(to t: Double, _ phase: TimelineView.Scrub) {
        let now = clock()
        if phase == .began {
            resumeAfterScrub = state.transport.isPlaying
            state.transport.pause(now: now)
        }
        state.transport.seek(to: t, now: now)
        isScrubbing = phase != .ended
        // Letting go at the end stays there instead of starting over from the beginning.
        if phase == .ended && resumeAfterScrub && t < state.transport.duration { state.transport.play(now: now) }
        awaitFrame()
        tick()
    }

    private func awaitFrame() { awaitingSince = clock() }

    private func applyVolume() {
        frames.volume = state.isMuted ? 0 : state.volume
        frames.isSilent = !playsSound
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
        let output = Self.uniqueFile(in: exportFolder(), name: RecordingProjectFile.displayName(of: folder))
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

    /// Draws the frame at the playhead the way export would, sharp and at the original size, and hands it to `onExportFrame`.
    public func exportFrame() {
        let project = state.project, video = videoURL, t = state.transport.time(at: clock())
        let source = project.source
        let pointScale = source.pixelWidth > 0 ? Double(source.pixelWidth) / max(source.pointWidth, 1) : 1
        frameJob = Task { [weak self] in
            let result: FrameExportEvent
            do {
                let image = try await VideoExporter.frame(project: project, video: video, at: t)
                result = .finished(FrameExport(image: image, outputTime: t, pointScale: pointScale))
            } catch {
                result = .failed(String(describing: error))
            }
            guard let self else { return }
            if case .finished = result { announce("Frame exported") } else { announce("Could not export the frame") }
            onExportFrame(result)
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
        if let cameraFrames, frame.camera != nil {
            cameraFrames.follow(sourceTime: frame.sourceTime, playing: state.transport.isPlaying)
            if let image = cameraFrames.frame(at: frame.sourceTime) { preview.cameraImage = image }
        }
        preview.keystrokes = state.project.edits.keystrokes
        preview.highlight = state.project.edits.clicks
        preview.state = frame
        preview.canvas = state.project.canvas
        showStill(at: t, frame)
        timeline.time = t
        updateTransportBar(t)
        let waiting = awaitingSince.map { now - $0 < Self.frameWait } ?? false
        if !waiting { awaitingSince = nil }
        displayLink?.isPaused = !(state.transport.isPlaying || waiting)
    }

    /// Paused on a frame that motion blur averages, the preview shows export's drawing of it at the stage's size once it is drawn. Playing,
    /// it shows the sharp frame: averaging every frame live would cost several full drawings per tick.
    private func showStill(at t: Double, _ frame: FrameState) {
        let project = state.project
        func clear() { _ = still.latest.next(); preview.still = nil; still.key = nil }
        guard !state.transport.isPlaying, !isScrubbing, let source = preview.image else { return clear() }
        let size = preview.stagePixelSize
        guard project.edits.motionBlur.scope != .off, size.width > 0, size.height > 0 else { return clear() }
        if still.renderer?.width != size.width || still.renderer?.height != size.height || still.edits != project.edits {
            still.renderer = ExportFrameRenderer(width: size.width, height: size.height, project: project, folder: folder)
            still.edits = project.edits
        }
        guard let renderer = still.renderer else { return clear() }
        let samples = frameSamples(project, outputTime: t, fps: max(project.source.fps, 1), pixelsAcross: renderer.frameRect.width)
        guard samples.count > 1 else { return clear() }
        let camera = frame.camera == nil ? nil : preview.cameraImage
        let key = StillKey(samples: samples, source: ObjectIdentifier(source), camera: camera.map(ObjectIdentifier.init), width: size.width, height: size.height,
                           edits: project.edits)
        guard key != still.key else { return }
        // A new moment shows its sharp layers until its blurred frame is ready; a new blur setting keeps the last blurred frame meanwhile.
        if still.key?.samples.first != samples.first { preview.still = nil }
        still.key = key
        let generation = still.latest.next(), latest = still.latest, accumulator = still.accumulator
        // Several full drawings take tens of milliseconds, so they run off the main thread, and a request already replaced is skipped.
        stillQueue.async { [weak self] in
            guard latest.isCurrent(generation) else { return }
            let started = Date()
            let image = renderer.image(samples, source: source, camera: camera, accumulator: accumulator)
            let milliseconds = Date().timeIntervalSince(started) * 1000
            DispatchQueue.main.async {
                guard let self, latest.isCurrent(generation) else { return }
                self.preview.still = image
                self.stillMilliseconds = milliseconds
            }
        }
    }

    /// Returns once the blurred frame asked for so far is on the preview, or was skipped.
    public func previewSettled() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in stillQueue.async { DispatchQueue.main.async { done.resume() } } }
    }

    /// How long the last blurred frame took to draw.
    public private(set) var stillMilliseconds: Double?
    private let stillQueue = DispatchQueue(label: "video.preview.still", qos: .userInitiated)

    final class Generation: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func next() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
        func isCurrent(_ n: Int) -> Bool { lock.lock(); defer { lock.unlock() }; return value == n }
    }

    struct StillKey: Equatable {
        var samples: [FrameState]
        var source: ObjectIdentifier
        var camera: ObjectIdentifier?
        var width: Int
        var height: Int
        var edits: RecordingProject.Edits
    }
    private var still: (key: StillKey?, renderer: ExportFrameRenderer?, edits: RecordingProject.Edits?, accumulator: SampleAccumulator, latest: Generation) =
        (nil, nil, nil, SampleAccumulator(), Generation())

    /// The picture the preview shows now, nil before the first frame arrives.
    public var previewImage: CGImage? { preview.image }
    /// The frame the preview drew last.
    public var previewState: FrameState? { preview.state }
    /// The blurred frame the paused preview shows over its layers, nil when it shows them.
    public var previewStill: CGImage? { preview.still }
    /// How many click rings the preview shows, one layer each.
    public var previewRingLayerCount: Int { preview.visibleRingCount }

    private func refresh() {
        let background = state.project.edits.background
        if backgroundPicture.file != background.image {
            backgroundPicture = (background.image, background.picture(in: folder))
            preview.backgroundPicture = backgroundPicture.image
        }
        let project = state.project
        inspector.available = Set([project.source.camera == nil ? nil : EditorSection.camera, project.events.keys.isEmpty ? nil : .keystrokes,
                                   project.source.audioTracks.isEmpty ? nil : .audio].compactMap { $0 })
        inspector.cameraPanel.show(project.edits.camera)
        inspector.keystrokesPanel.show(project.edits.keystrokes)
        inspector.audioPanel.show(project.edits.audio, tracks: project.source.audioTracks)
        inspector.motionBlurPanel.show(project.edits.motionBlur)
        frames.setGains(Dictionary(uniqueKeysWithValues: AudioTrack.allCases.map { ($0, project.edits.audio[$0].gain) }))
        let size = ExportPlan(project: project, settings: ExportSettings())
        inspector.backgroundPanel.videoSize = CGSize(width: size.width, height: size.height)
        let zooms = project.edits.zooms
        inspector.show(state.section, cursor: project.edits.cursor, clicks: project.edits.clicks, hasClicks: !project.events.clicks.isEmpty,
                       background: background, picture: backgroundPicture.image,
                       zoom: zooms.first { $0.id == state.selectedZoom }, zoomCount: zooms.count,
                       origin: project.source.origin, hasAudio: frames.hasAudio)
        timeline.zoomLane.zooms = zooms
        timeline.zoomLane.selection = state.selectedZoom
        header.show(state.export)
        let edited = state.project != saved
        header.show(document: edited ? .edited : hasSaved ? .saved : .unchanged)
        window?.isDocumentEdited = edited
        exportPanel.show(state.export, settings: state.exportSettings, project: state.project, sourceBytes: sourceBytes)
        updateTransportBar(state.transport.time(at: clock()))
    }

    private func updateTransportBar(_ t: Double) {
        let clips = state.project.timeline
        transportBar.update(time: t, duration: state.transport.duration, playing: state.transport.isPlaying, hasAudio: frames.hasAudio,
                            muted: state.isMuted, volume: state.volume, previewOnly: state.isPreviewOnly,
                            canSplit: clips.splitting(at: t) != nil, canDelete: clips.clips.count > 1)
    }

    func startDisplayLink() {
        guard displayLink == nil else { return }
        let link = preview.displayLink(target: self, selector: #selector(displayTick))
        link.add(to: .main, forMode: .common)
        displayLink = link
        awaitFrame()
        tick()
    }

    @objc private func displayTick() { tick() }

    // MARK: Window

    // MARK: Saving

    /// Writes the edits to the project file now. Undo and redo keep working across it.
    @discardableResult
    public func save() -> SaveResult {
        let result = writeIfChanged()
        refresh()
        // The header's word changes without moving focus, so VoiceOver hears the outcome too.
        if case .failed = result { announce("Could not save the edits") } else { announce("Saved") }
        onSave(result)
        return result
    }

    /// Asks where to write a copy of the project, then writes it there and goes on editing the copy.
    public func chooseAndSaveAs() {
        chooseSaveLocation(window, RecordingProjectFile.displayName(of: folder)) { [weak self] url in
            guard let self, let url else { return }
            do { try saveAs(to: url) } catch { onSave(.failed(error.localizedDescription)) }
        }
    }

    /// Copies the project, edits included, to the package `target` and edits the copy from now on. The project it leaves keeps what
    /// was last saved there.
    public func saveAs(to target: URL) throws {
        var target = target.standardizedFileURL
        if target.pathExtension.lowercased() != RecordingProjectFile.packageExtension {
            target = target.appendingPathExtension(RecordingProjectFile.packageExtension)
        }
        let from = folder, here = folder.standardizedFileURL.resolvingSymlinksInPath().path
        let there = target.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath().appendingPathComponent(target.lastPathComponent).path
        guard there != here else { save(); return }
        guard !there.hasPrefix(here + "/") else { throw CocoaError(.fileWriteInvalidFileName) }
        try RecordingProjectFile.copy(state.project, from: from, to: target)
        // Named the way the app names an open project, so opening the copy again finds this editor.
        let resolved = target.standardizedFileURL.resolvingSymlinksInPath()
        folder = resolved
        saved = state.project
        hasSaved = true
        window?.title = RecordingProjectFile.displayName(of: resolved)
        refresh()
        onSaveAs(from, resolved)
    }

    /// A close the viewer asked for stays open when the edits cannot be written, so they are never lost to a folder that cannot be written.
    public func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard case .failed = writeIfChanged() else { return true }
        refresh()
        onSave(.failed("the project file could not be written"))
        return false
    }

    public func windowWillClose(_ notification: Notification) {
        preparation?.cancel()
        exportJob?.cancel()
        displayLink?.invalidate()
        displayLink = nil
        state.transport.pause(now: clock())
        frames.follow(sourceTime: state.transport.time(at: clock()), playing: false)
        onClose(writeIfChanged())
    }

    private func writeIfChanged() -> SaveResult {
        guard state.project != saved else { return .unchanged }
        do {
            try saveProject()
            return .saved
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private func saveProject() throws {
        try RecordingProjectFile.write(state.project, to: folder)
        saved = state.project
        hasSaved = true
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

extension NSMenuItem {
    func onPick(_ handler: @escaping () -> Void) {
        let target = MenuTarget(handler)
        representedObject = target
        self.target = target
        action = #selector(MenuTarget.fire)
    }
}

private final class MenuTarget: NSObject {
    let handler: () -> Void
    init(_ handler: @escaping () -> Void) { self.handler = handler }
    @objc func fire() { handler() }
}
