import AppKit
import CornermarkCapture
import UniformTypeIdentifiers

enum ActionID: String, CaseIterable {
    case allInOne, area, window, fullscreen, previousArea, scrolling, ocr, timer
    case restoreOverlay, hideOverlays, history, settings, checkForUpdates, whatsNew, openFile, quit
}

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
        ActionSpec(id: .restoreOverlay, title: "Restore Last Overlay", symbol: "arrow.uturn.backward", hotKey: nil, urlPath: "restore-overlay", menuGroup: 1),
        ActionSpec(id: .hideOverlays, title: "Hide Overlays", symbol: "eye.slash", hotKey: nil, urlPath: "hide-overlays", menuGroup: 1),
        ActionSpec(id: .history, title: "Capture History\u{2026}", symbol: "clock", hotKey: nil, urlPath: "history", menuGroup: 2),
        ActionSpec(id: .settings, title: "Settings\u{2026}", symbol: "gearshape", hotKey: nil, urlPath: "settings", menuGroup: 2),
        ActionSpec(id: .checkForUpdates, title: "Check for Updates\u{2026}", symbol: "arrow.triangle.2.circlepath", hotKey: nil, urlPath: "check-for-updates", menuGroup: 2),
        ActionSpec(id: .whatsNew, title: "What's New\u{2026}", symbol: "sparkles", hotKey: nil, urlPath: "whats-new", menuGroup: 2),
        ActionSpec(id: .openFile, title: "Open Image", symbol: "photo", hotKey: nil, urlPath: "open", menuGroup: nil),
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
            }
        case .captureOCR: return .ocr
        case .openHistory: return .history
        case .openSettings: return .settings
        case .checkForUpdates: return .checkForUpdates
        case .whatsNew: return .whatsNew
        case .restoreLastOverlay: return .restoreOverlay
        case .hideOverlays: return .hideOverlays
        case .openFile: return .openFile
        case .quit: return .quit
        }
    }

    /// The action for a menu item or hotkey; nil for `.openFile`, which needs a URL.
    static func make(_ id: ActionID, timerSeconds: Int) -> AppAction? {
        switch id {
        case .allInOne: return .capture(.allInOne)
        case .area: return .capture(.area)
        case .window: return .capture(.window)
        case .fullscreen: return .capture(.fullscreen)
        case .previousArea: return .capture(.previousArea)
        case .scrolling: return .capture(.scrolling)
        case .timer: return .capture(.timed(seconds: timerSeconds))
        case .ocr: return .captureOCR
        case .history: return .openHistory
        case .settings: return .openSettings
        case .checkForUpdates: return .checkForUpdates
        case .whatsNew: return .whatsNew
        case .restoreOverlay: return .restoreLastOverlay
        case .hideOverlays: return .hideOverlays
        case .quit: return .quit
        case .openFile: return nil
        }
    }
}

enum URLCommandError: Error, Equatable {
    case wrongScheme
    case missingPath
    case unknownPath(String)
    case invalidFile(String)
}

enum URLCommand {
    static var scheme: String { AppVariant.current.urlScheme }

    /// `cornermark://capture-area` and `cornermark:///capture-area` both name the path `capture-area`.
    static func parse(_ url: URL, timerSeconds: Int = 5) -> Result<AppAction, URLCommandError> {
        guard url.scheme?.lowercased() == scheme else { return .failure(.wrongScheme) }
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let rawPath = (comps?.host?.isEmpty == false ? comps?.host : nil)
            ?? comps?.path.split(separator: "/").first.map(String.init) ?? ""
        guard !rawPath.isEmpty else { return .failure(.missingPath) }
        guard let spec = ActionTable.spec(urlPath: rawPath.lowercased()) else { return .failure(.unknownPath(rawPath)) }
        let query = Dictionary((comps?.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })

        if spec.id == .openFile {
            guard let path = query["path"], !path.isEmpty else { return .failure(.missingPath) }
            return validatedImageURL(path: path).map { .openFile($0) }
        }
        let seconds = query["seconds"].flatMap(Int.init).map { min(max($0, 1), 60) } ?? timerSeconds
        return AppAction.make(spec.id, timerSeconds: seconds).map { .success($0) } ?? .failure(.unknownPath(rawPath))
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
