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
        editor.onClose = { [unowned self] closed in
            Log.shell.notice("video editor closed project=\(key.lastPathComponent, privacy: .public) result=\(String(describing: closed), privacy: .public)")
            if case .failed = closed { hud.show("Could not save the edits. Check that the recording's folder can be written to.", symbol: "exclamationmark.triangle.fill") }
            videoEditors[key] = nil
        }
        videoEditors[key] = editor
        let source = editor.state.project.source
        Log.shell.notice("video editor opened project=\(key.lastPathComponent, privacy: .public) seconds=\(String(format: "%.3f", source.duration), privacy: .public) size=\(source.pixelWidth, privacy: .public)x\(source.pixelHeight, privacy: .public) pointerSamples=\(editor.state.project.events.pointer.count, privacy: .public)")
        env.present(editor.window)
        if env.isOnscreen { editor.show() }
        return editor
    }

    /// What went wrong and where to look, since the folder lives where the user saved it.
    static func openFailure(_ error: Error) -> String {
        switch error as? VideoEditorError {
        case .noVideo: return "Could not open the recording: its video is missing. Look for it in the save folder."
        default: return "Could not open the recording: its project file is missing or damaged."
        }
    }
}
