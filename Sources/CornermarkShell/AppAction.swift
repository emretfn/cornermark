import AppKit
import CornermarkCapture
import CornermarkCore
import UniformTypeIdentifiers

enum ActionID: String, CaseIterable {
    case allInOne, area, window, fullscreen, previousArea, scrolling, ocr, timer, recordScreen
    case restoreOverlay, hideOverlays, history, settings, checkForUpdates, whatsNew, openFile, quit
    case record, stopRecording, recordTestWindow, pauseRecording, resumeRecording, restartRecording, editRecording, recordingCamera
}

/// What the recording controls do to a recording that is under way.
enum RecordingControl: Equatable { case pause, resume, restart }

/// One row per user intent. The menu, the global hotkeys and the URL scheme all read this table.
struct ActionSpec {
    let id: ActionID
    let title: String
    let symbol: String
    /// The name on a capture tile, where `title` would not fit.
    let shortTitle: String?
    let hotKey: HotKey?
    let urlPath: String?
    let menuGroup: Int?

    init(id: ActionID, title: String, symbol: String, shortTitle: String? = nil, hotKey: HotKey?, urlPath: String?, menuGroup: Int?) {
        self.id = id; self.title = title; self.symbol = symbol; self.shortTitle = shortTitle
        self.hotKey = hotKey; self.urlPath = urlPath; self.menuGroup = menuGroup
    }

    var tileTitle: String { shortTitle ?? title }
}

enum ActionTable {
    static let specs: [ActionSpec] = [
        ActionSpec(id: .allInOne, title: "Capture All-in-One", symbol: "camera.viewfinder", shortTitle: "All-in-One", hotKey: .ctrlShift(18), urlPath: "all-in-one", menuGroup: 0),
        ActionSpec(id: .area, title: "Capture Area", symbol: "rectangle.dashed", shortTitle: "Area", hotKey: .ctrlShift(19), urlPath: "capture-area", menuGroup: 0),
        ActionSpec(id: .window, title: "Capture Window", symbol: "macwindow", shortTitle: "Window", hotKey: .ctrlShift(20), urlPath: "capture-window", menuGroup: 0),
        ActionSpec(id: .fullscreen, title: "Capture Fullscreen", symbol: "macbook", shortTitle: "Screen", hotKey: .ctrlShift(21), urlPath: "capture-fullscreen", menuGroup: 0),
        ActionSpec(id: .previousArea, title: "Capture Previous Area", symbol: "arrow.counterclockwise", shortTitle: "Previous", hotKey: .ctrlShift(23), urlPath: "previous-area", menuGroup: 0),
        ActionSpec(id: .scrolling, title: "Capture Scrolling", symbol: "arrow.up.and.down.square", shortTitle: "Scroll", hotKey: .ctrlShift(22), urlPath: "scrolling", menuGroup: 0),
        ActionSpec(id: .ocr, title: "Capture Text (OCR)", symbol: "text.viewfinder", shortTitle: "Text", hotKey: .ctrlShift(26), urlPath: "ocr", menuGroup: 0),
        ActionSpec(id: .timer, title: "Capture with Timer", symbol: "timer", shortTitle: "Timer", hotKey: .ctrlShift(28), urlPath: "timer", menuGroup: 0),
        ActionSpec(id: .recordScreen, title: "Record Screen", symbol: "record.circle", shortTitle: "Record", hotKey: .ctrlShift(25), urlPath: "record-screen", menuGroup: 0),
        ActionSpec(id: .restoreOverlay, title: "Restore Last Overlay", symbol: "arrow.uturn.backward", hotKey: nil, urlPath: "restore-overlay", menuGroup: 1),
        ActionSpec(id: .hideOverlays, title: "Hide Overlays", symbol: "eye.slash", hotKey: nil, urlPath: "hide-overlays", menuGroup: 1),
        ActionSpec(id: .history, title: "Capture History\u{2026}", symbol: "clock", hotKey: nil, urlPath: "history", menuGroup: 2),
        ActionSpec(id: .settings, title: "Settings\u{2026}", symbol: "gearshape", hotKey: nil, urlPath: "settings", menuGroup: 2),
        ActionSpec(id: .checkForUpdates, title: "Check for Updates\u{2026}", symbol: "arrow.triangle.2.circlepath", hotKey: nil, urlPath: "check-for-updates", menuGroup: 2),
        ActionSpec(id: .whatsNew, title: "What's New\u{2026}", symbol: "sparkles", hotKey: nil, urlPath: "whats-new", menuGroup: 2),
        ActionSpec(id: .openFile, title: "Open Image", symbol: "photo", hotKey: nil, urlPath: "open", menuGroup: nil),
        ActionSpec(id: .record, title: "Record", symbol: "record.circle", hotKey: nil, urlPath: "record", menuGroup: nil),
        ActionSpec(id: .stopRecording, title: "Stop Recording", symbol: "stop.circle", hotKey: nil, urlPath: "record/stop", menuGroup: nil),
        ActionSpec(id: .pauseRecording, title: "Pause Recording", symbol: "pause.fill", hotKey: nil, urlPath: "record/pause", menuGroup: nil),
        ActionSpec(id: .resumeRecording, title: "Resume Recording", symbol: "play.fill", hotKey: nil, urlPath: "record/resume", menuGroup: nil),
        ActionSpec(id: .restartRecording, title: "Restart Recording", symbol: "arrow.counterclockwise", hotKey: nil, urlPath: "record/restart", menuGroup: nil),
        ActionSpec(id: .recordingCamera, title: "Camera Full Screen", symbol: "arrow.up.left.and.arrow.down.right", hotKey: nil, urlPath: "record/camera", menuGroup: nil),
        ActionSpec(id: .recordTestWindow, title: "Show Recording Test Window", symbol: "macwindow", hotKey: nil, urlPath: "record/test-window", menuGroup: nil),
        ActionSpec(id: .editRecording, title: "Edit Recording", symbol: "slider.horizontal.3", hotKey: nil, urlPath: "edit-recording", menuGroup: nil),
        ActionSpec(id: .quit, title: "Quit Cornermark", symbol: "power", hotKey: nil, urlPath: nil, menuGroup: 3),
    ]

    static func spec(_ id: ActionID) -> ActionSpec { specs.first { $0.id == id }! }
    static func spec(urlPath: String) -> ActionSpec? { specs.first { $0.urlPath == urlPath } }
}

enum AppAction: Equatable {
    case capture(CaptureMode)
    case captureOCR
    case openHistory
    case openSettings
    case checkForUpdates
    case whatsNew
    case restoreLastOverlay
    case hideOverlays
    case openFile(URL)
    case startRecording(RecordingTarget, RecordingStyle)
    case stopRecording
    case controlRecording(RecordingControl)
    case changeCamera(CameraChange)
    case openRecordingTestWindow
    /// A scripted instance shows the editor for a project as its test window and plays a scene in it while it is recorded.
    case filmVideoEditor(URL, scene: String)
    case openRecording(URL)
    case exportRecording(URL)
    case quit

    var id: ActionID {
        switch self {
        case .capture(let mode):
            switch mode {
            case .area: return .area
            case .window: return .window
            case .fullscreen: return .fullscreen
            case .allInOne: return .allInOne
            case .previousArea: return .previousArea
            case .timed: return .timer
            case .scrolling: return .scrolling
            case .recording: return .recordScreen
            }
        case .captureOCR: return .ocr
        case .openHistory: return .history
        case .openSettings: return .settings
        case .checkForUpdates: return .checkForUpdates
        case .whatsNew: return .whatsNew
        case .restoreLastOverlay: return .restoreOverlay
        case .hideOverlays: return .hideOverlays
        case .openFile: return .openFile
        case .startRecording: return .record
        case .stopRecording: return .stopRecording
        case .controlRecording(.pause): return .pauseRecording
        case .controlRecording(.resume): return .resumeRecording
        case .controlRecording(.restart): return .restartRecording
        case .changeCamera: return .recordingCamera
        case .openRecordingTestWindow, .filmVideoEditor: return .recordTestWindow
        case .openRecording, .exportRecording: return .editRecording
        case .quit: return .quit
        }
    }

    /// The action for a menu item or hotkey; nil for `.openFile`, `.record` and `.editRecording`, which need a URL.
    static func make(_ id: ActionID, timerSeconds: Int) -> AppAction? {
        switch id {
        case .allInOne: return .capture(.allInOne)
        case .area: return .capture(.area)
        case .window: return .capture(.window)
        case .fullscreen: return .capture(.fullscreen)
        case .previousArea: return .capture(.previousArea)
        case .scrolling: return .capture(.scrolling)
        case .timer: return .capture(.timed(seconds: timerSeconds))
        case .recordScreen: return .capture(.recording)
        case .ocr: return .captureOCR
        case .history: return .openHistory
        case .settings: return .openSettings
        case .checkForUpdates: return .checkForUpdates
        case .whatsNew: return .whatsNew
        case .restoreOverlay: return .restoreLastOverlay
        case .hideOverlays: return .hideOverlays
        case .quit: return .quit
        case .stopRecording: return .stopRecording
        case .recordTestWindow: return .openRecordingTestWindow
        case .pauseRecording: return .controlRecording(.pause)
        case .resumeRecording: return .controlRecording(.resume)
        case .restartRecording: return .controlRecording(.restart)
        case .recordingCamera: return .changeCamera(.toggleFullScreen)
        case .openFile, .record, .editRecording: return nil
        }
    }
}

enum URLCommandError: Error, Equatable {
    case wrongScheme
    case missingPath
    case unknownPath(String)
    case invalidFile(String)
    case invalidRecording(String)
    case invalidProject(String)
}

enum URLCommand {
    static var scheme: String { AppVariant.current.urlScheme }

    /// `cornermark://capture-area` and `cornermark:///capture-area` both name the path `capture-area`.
    static func parse(_ url: URL, timerSeconds: Int = 5) -> Result<AppAction, URLCommandError> {
        guard url.scheme?.lowercased() == scheme else { return .failure(.wrongScheme) }
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let parts = [comps?.host].compactMap { $0 }.filter { !$0.isEmpty } + (comps?.path.split(separator: "/").map(String.init) ?? [])
        let rawPath = parts.joined(separator: "/")
        guard !rawPath.isEmpty else { return .failure(.missingPath) }
        guard let spec = ActionTable.spec(urlPath: rawPath.lowercased()) else { return .failure(.unknownPath(rawPath)) }
        let query = Dictionary((comps?.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })

        if spec.id == .openFile {
            guard let path = query["path"], !path.isEmpty else { return .failure(.missingPath) }
            return validatedImageURL(path: path).map { .openFile($0) }
        }
        if spec.id == .editRecording {
            guard let path = query["path"], !path.isEmpty else { return .failure(.missingPath) }
            return validatedProjectFolder(path: path).map { query["export"] == "1" ? .exportRecording($0) : .openRecording($0) }
        }
        if spec.id == .recordTestWindow, let path = query["editor"] {
            return validatedProjectFolder(path: path).map { .filmVideoEditor($0, scene: query["scene"] ?? "") }
        }
        if spec.id == .record {
            // A link records for editing unless it asks for a plain video, which keeps older links meaning what they did.
            guard let style = query["style"].map(RecordingStyle.init(rawValue:)) ?? .editing else { return .failure(.invalidRecording("style")) }
            return recordingTarget(query).map { .startRecording($0, style) }
        }
        if spec.id == .recordingCamera { return CameraChange.parse(query).map { .changeCamera($0) } }
        let seconds = query["seconds"].flatMap(Int.init).map { min(max($0, 1), 60) } ?? timerSeconds
        return AppAction.make(spec.id, timerSeconds: seconds).map { .success($0) } ?? .failure(.unknownPath(rawPath))
    }

    /// `window=<id>` films one window. `style=video`, `style=editing` or `style=gif` says what it becomes. `display=<id>`, or `x`, `y`, `width` and `height`, or both, film a display or an area of it.
    /// A link that names no target is refused, so a stray link never starts filming the screen.
    static func recordingTarget(_ query: [String: String]) -> Result<RecordingTarget, URLCommandError> {
        let areaKeys = ["x", "y", "width", "height"]
        let named = areaKeys.filter { query[$0] != nil }
        if let window = query["window"] {
            guard query["display"] == nil, named.isEmpty else { return .failure(.invalidRecording("window excludes display and area")) }
            guard let id = UInt32(window), id != 0 else { return .failure(.invalidRecording("window")) }
            return .success(.window(CGWindowID(id)))
        }
        var area: CGRect?
        if !named.isEmpty {
            let values = areaKeys.map { query[$0].flatMap(Double.init) }
            guard named.count == 4, values.allSatisfy({ $0?.isFinite == true }), let w = values[2], let h = values[3], w > 0, h > 0 else {
                return .failure(.invalidRecording("area needs x, y, width and height, with a positive size"))
            }
            area = CGRect(x: values[0]!, y: values[1]!, width: w, height: h)
        }
        var display: CGDirectDisplayID?
        if let raw = query["display"] {
            guard let id = UInt32(raw), id != 0 else { return .failure(.invalidRecording("display")) }
            display = CGDirectDisplayID(id)
        }
        guard display != nil || area != nil else { return .failure(.invalidRecording("name a window, a display or an area")) }
        return .success(.display(display, area: area))
    }

    /// A recording's project folder: an absolute path to a folder that holds `project.json`.
    static func validatedProjectFolder(path rawPath: String) -> Result<URL, URLCommandError> {
        guard rawPath.hasPrefix("/") else { return .failure(.invalidProject(rawPath)) }
        let folder = URL(fileURLWithPath: rawPath, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isFolder), isFolder.boolValue,
              FileManager.default.fileExists(atPath: folder.appendingPathComponent(RecordingProjectFile.projectName).path) else {
            return .failure(.invalidProject(rawPath))
        }
        return .success(folder)
    }

    static func validatedImageURL(path rawPath: String) -> Result<URL, URLCommandError> {
        guard rawPath.hasPrefix("/") || rawPath.hasPrefix("file://") else { return .failure(.invalidFile(rawPath)) }
        let url = rawPath.hasPrefix("file://") ? URL(string: rawPath) : URL(fileURLWithPath: rawPath)
        guard let url, url.isFileURL else { return .failure(.invalidFile(rawPath)) }
        return validatedImageURL(url)
    }

    static func validatedImageURL(_ url: URL) -> Result<URL, URLCommandError> {
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        let values = try? resolved.resourceValues(forKeys: [.isRegularFileKey, .contentTypeKey])
        guard values?.isRegularFile == true, values?.contentType?.conforms(to: .image) == true else {
            return .failure(.invalidFile(url.path))
        }
        return .success(resolved)
    }
}
