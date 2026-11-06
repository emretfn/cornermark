import AppKit
import CornermarkCore
import CornermarkVideoEditor

extension CaptureRecord {
    /// A recording for editing has a project and opens in the video editor. A plain video only plays.
    var opensVideoEditor: Bool { video?.format == .project }
}

extension AppCoordinator {
    /// Opens a recording's project folder in the video editor, or brings forward the editor that has it open.
    @discardableResult
    func openVideoEditor(_ folder: URL) -> VideoEditorWindowController? {
        // The same key whichever way the folder was named, so one project never has two editors whose saves overwrite each other.
        let key = folder.standardizedFileURL.resolvingSymlinksInPath()
        if let open = videoEditors[key] {
            Log.shell.notice("video editor reopened project=\(key.lastPathComponent, privacy: .public)")
            env.present(open.window)
            if env.isOnscreen { open.show() }
            return open
        }
        let editor: VideoEditorWindowController
        do { editor = try makeVideoEditor(key) } catch {
            Log.shell.error("video editor refused \(key.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)")
            hud.show(Self.openFailure(error), symbol: "exclamationmark.triangle.fill")
            return nil
        }
        editor.exportFolder = { [unowned self] in env.store.incomingDirectory }
        // Save As moves the editor to another folder, so each callback asks the editor where it is now.
        editor.onExport = { [weak editor, unowned self] event in handleExport(event, project: editor?.folder ?? key) }
        editor.onClose = { [weak editor, unowned self] closed in
            let folder = editor?.folder ?? key
            Log.shell.notice("video editor closed project=\(folder.lastPathComponent, privacy: .public) result=\(String(describing: closed), privacy: .public)")
            if case .failed = closed { hud.show("Could not save the edits. Check that the project's folder can be written to.", symbol: "exclamationmark.triangle.fill") }
            videoEditors[folder] = nil
        }
        editor.onSave = { [weak editor, unowned self] result in
            Log.shell.notice("video project saved project=\((editor?.folder ?? key).lastPathComponent, privacy: .public) result=\(String(describing: result), privacy: .public)")
            if case .failed = result { hud.show("Could not save the edits. Choose File > Save As to keep them somewhere else.", symbol: "exclamationmark.triangle.fill") }
        }
        editor.onSaveAs = { [weak editor, unowned self] from, to in
            guard let editor else { return }
            videoEditors[from] = nil
            videoEditors[to] = editor
            Log.shell.notice("video project saved as project=\(to.lastPathComponent, privacy: .public) from=\(from.lastPathComponent, privacy: .public)")
            let kind = env.store.list(filter: CaptureFilter(recordings: true)).first { $0.video?.location.standardizedFileURL.resolvingSymlinksInPath().path == from.path }?.kind
            let project = editor.state.project
            Task { [self] in await self.listProject(to, project: project, kind: kind ?? .imported) }
        }
        // A scripted instance never shows a panel, so Save As writes a copy beside the project.
        if !env.isOnscreen { editor.chooseSaveLocation = { _, name, done in done(Self.uniquePackage(in: key.deletingLastPathComponent(), name: "\(name) copy")) } }
        videoEditors[key] = editor
        let source = editor.state.project.source
        Log.shell.notice("video editor opened project=\(key.lastPathComponent, privacy: .public) seconds=\(String(format: "%.3f", source.duration), privacy: .public) size=\(source.pixelWidth, privacy: .public)x\(source.pixelHeight, privacy: .public) pointerSamples=\(editor.state.project.events.pointer.count, privacy: .public)")
        env.present(editor.window)
        if env.isOnscreen { editor.show() }
        return editor
    }

    /// Makes a project from a video file and opens it. The project lands in the save folder and in History, which lists recent projects.
    func openVideo(_ file: URL) async {
        let folder = settings.value.resolvedSaveFolder(default: env.defaultSaveFolder)
        let made: (folder: URL, project: RecordingProject)
        do { made = try await VideoImport.makeProject(from: file, in: folder) } catch {
            Log.shell.error("video not opened file=\(file.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)")
            return hud.show(Self.importFailure(error), symbol: "exclamationmark.triangle.fill")
        }
        let s = made.project.source
        Log.shell.notice("video opened from file file=\(file.lastPathComponent, privacy: .public) project=\(made.folder.lastPathComponent, privacy: .public) seconds=\(String(format: "%.3f", s.duration), privacy: .public) size=\(s.pixelWidth, privacy: .public)x\(s.pixelHeight, privacy: .public) fps=\(s.fps, privacy: .public)")
        await listProject(made.folder, project: made.project, kind: .imported)
        openVideoEditor(made.folder)
    }

    /// Asks for a video file to open. A scripted instance has no panel to show and says so.
    func chooseAndOpenVideo() {
        guard env.isOnscreen else { return Log.shell.error("open video refused: this instance shows no panels") }
        chooseVideo { [unowned self] url in if let url { Task { await openVideo(url) } } }
    }

    private func listProject(_ folder: URL, project: RecordingProject, kind: CaptureKind) async {
        let video = RecordedVideo(location: folder, format: .project, duration: project.outputDuration)
        let size = CGSize(width: project.source.pixelWidth, height: project.source.pixelHeight)
        let poster = await VideoPoster.image(of: video) ?? VideoPoster.placeholder(size)
        do { _ = try env.store.addRecording(video, poster: poster, kind: kind, pixelSize: size, now: env.clock()) } catch {
            return Log.shell.error("history write failed for a project: \(error.localizedDescription, privacy: .public)")
        }
        history?.reload()
    }

    static func uniquePackage(in folder: URL, name: String) -> URL {
        let ext = RecordingProjectFile.packageExtension
        var url = folder.appendingPathComponent("\(name).\(ext)", isDirectory: true)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(name) \(n).\(ext)", isDirectory: true)
            n += 1
        }
        return url
    }

    static func importFailure(_ error: Error) -> String {
        switch error as? VideoImportError {
        case .notAVideo?: return "Could not open the file. Choose an MP4 or MOV video."
        case .noPicture?: return "Could not open the video: it has no picture. Choose a video that plays in a player."
        case .turned?: return "Could not open the video: it is stored turned on its side. Turn it upright in another app, then open it again."
        case nil: return "Could not open the video. Check that it plays and that the save folder can be written to, then try again."
        }
    }

    func handleExport(_ event: ExportEvent, project folder: URL) {
        let name = folder.lastPathComponent
        switch event {
        case .started(let plan):
            Log.shell.notice("video export started project=\(name, privacy: .public) size=\(plan.width, privacy: .public)x\(plan.height, privacy: .public) fps=\(plan.fps, privacy: .public) frames=\(plan.frameCount, privacy: .public) bitRate=\(plan.bitRate, privacy: .public) estimatedBytes=\(plan.estimatedBytes, privacy: .public)")
        case .finished(let report):
            Task { await exportFinished(report, project: folder) }
        case .cancelled(let fraction):
            let left = (try? FileManager.default.contentsOfDirectory(atPath: env.store.incomingDirectory.path))?.count ?? 0
            Log.shell.notice("video export cancelled project=\(name, privacy: .public) at=\(String(format: "%.2f", fraction), privacy: .public) filesLeft=\(left, privacy: .public)")
        case .notSaved(let message):
            Log.shell.error("video export refused project=\(name, privacy: .public): edits not saved: \(message, privacy: .public)")
            hud.show("Could not save the edits, so nothing was exported. Check that the recording's folder can be written to.", symbol: "exclamationmark.triangle.fill")
        case .failed(let message):
            Log.shell.error("video export failed project=\(name, privacy: .public): \(message, privacy: .public)")
            hud.show("Could not export the video. Check that the disk has free space, then export again.", symbol: "exclamationmark.triangle.fill")
        }
    }

    private func exportFinished(_ report: ExportReport, project folder: URL) async {
        let size = CGSize(width: report.plan.width, height: report.plan.height)
        let poster = await VideoPoster.image(of: report.url) ?? VideoPoster.placeholder(size)
        let kind = env.store.list(filter: CaptureFilter(recordings: true)).first { $0.video?.location.standardizedFileURL.resolvingSymlinksInPath().path == folder.path }?.kind ?? .area
        let record: CaptureRecord
        do {
            record = try env.store.addOwnedVideo(moving: report.url, duration: report.duration, poster: poster, kind: kind, pixelSize: size, now: env.clock())
        } catch {
            Log.shell.error("video export not listed: \(error.localizedDescription, privacy: .public)")
            return hud.show("Could not keep the exported video. Check that the disk has free space, then export again.", symbol: "exclamationmark.triangle.fill")
        }
        history?.reload()
        Log.shell.notice("video exported project=\(folder.lastPathComponent, privacy: .public) record=\(record.id.uuidString, privacy: .public) file=\(record.video?.file.lastPathComponent ?? "", privacy: .public) size=\(report.plan.width, privacy: .public)x\(report.plan.height, privacy: .public) frames=\(report.framesWritten, privacy: .public) seconds=\(String(format: "%.3f", report.duration), privacy: .public) projectSeconds=\(String(format: "%.3f", report.plan.duration), privacy: .public) bytes=\(report.bytes, privacy: .public) estimatedBytes=\(report.plan.estimatedBytes, privacy: .public) hardware=\(report.usesHardware, privacy: .public) encoder=\(report.encoderID, privacy: .public) renderSeconds=\(String(format: "%.3f", report.renderSeconds), privacy: .public) card=\(self.settings.value.recording.showQuickAccess, privacy: .public)")
        if settings.value.recording.showQuickAccess { overlay.add(record: record, image: poster) } else { hud.show("Exported \(record.video?.file.lastPathComponent ?? "the video")") }
    }

    @discardableResult
    func saveVideo(_ record: CaptureRecord) -> URL? {
        guard let video = videoFile(record) else { return nil }
        let folder = settings.value.resolvedSaveFolder(default: env.defaultSaveFolder)
        let base = video.file.deletingPathExtension().lastPathComponent
        var target = folder.appendingPathComponent(video.file.lastPathComponent)
        var n = 2
        while FileManager.default.fileExists(atPath: target.path) {
            target = folder.appendingPathComponent("\(base) \(n).mp4")
            n += 1
        }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: video.file, to: target)
        } catch {
            Log.shell.error("video save failed: \(error.localizedDescription, privacy: .public)")
            hud.show("Could not save", symbol: "exclamationmark.triangle.fill")
            return nil
        }
        Log.shell.notice("video saved record=\(record.id.uuidString, privacy: .public) file=\(target.lastPathComponent, privacy: .public)")
        hud.show("Saved \(target.lastPathComponent)")
        return target
    }

    /// What went wrong and where to look, since the folder lives where the user saved it.
    static func openFailure(_ error: Error) -> String {
        switch error as? VideoEditorError {
        case .noVideo: return "Could not open the recording: its video is missing. Look for it in the save folder."
        default: return "Could not open the recording: its project file is missing or damaged."
        }
    }
}
