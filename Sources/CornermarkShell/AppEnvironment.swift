import AppKit
import CornermarkCapture
import CornermarkCore
import os

enum Log {
    static let shell = Logger(subsystem: "local.emretufan.cornermark", category: "shell")
}

protocol LoginItemControlling: AnyObject {
    var isEnabled: Bool { get }
    func setEnabled(_ enabled: Bool) throws
}

/// Finds, downloads and installs newer releases. The harness swaps in a fake that never touches the network.
protocol UpdateServicing: AnyObject {
    var currentVersion: AppVersion? { get }
    /// Nil when the project has no release yet.
    func latestRelease() async throws -> AppRelease?
    /// The published releases, newest first.
    func releaseHistory() async throws -> [ReleaseEntry]
    func stage(_ release: AppRelease) async throws -> StagedUpdate
    func installAndRelaunch(_ staged: StagedUpdate) throws
    func discard(_ staged: StagedUpdate)
}

/// Every collaborator a feature touches. The app builds the live one, the harness a headless one,
/// so both run the same feature code.
@MainActor
final class AppEnvironment {
    var screen: ScreenSource
    var store: CaptureStore
    var defaults: UserDefaults
    var pasteboard: NSPasteboard
    var presentation: OverlayPresentation
    var clock: () -> Date
    /// Visible frame (menu bar and Dock excluded) of the display holding the cursor, in global points.
    var cursorScreenFrame: () -> CGRect
    var hasScreenPermission: () -> Bool
    var requestScreenPermission: () -> Void
    var openURL: (URL) -> Void
    var revealInFinder: (URL) -> Void
    var playSound: () -> Void
    var pickFolder: (@escaping (URL?) -> Void) -> Void
    var loginItem: LoginItemControlling
    var updateService: UpdateServicing
    var defaultSaveFolder: URL
    /// Scratch space for files handed to other apps through drag and drop.
    var dragDirectory: URL
    var quit: () -> Void
    /// Asks whether to install a release. The live one is a modal alert.
    var confirmUpdate: (AppRelease) -> Bool = { _ in false }
    /// Shows a failed update step; returns true when the user asks for the release page.
    var presentUpdateAlert: (UpdateAlert) -> Bool = { _ in false }
    /// Called for every window the app asks to show, whether or not it is really ordered in.
    var willPresent: (NSWindow) -> Void = { _ in }
    /// Makes the picture source for a recording, or throws `RecordingRefusal`. The scripted instance only films its own test window.
    var frameSource: (RecordingTarget, RecordingOptions) throws -> FrameSource = { _, _ in throw RecordingRefusal.unavailable }
    /// Where the pointer comes from during a recording. Nil means nothing watches it. A scripted instance replays a path and never reads the real pointer.
    var pointerSource: () -> PointerSource? = { nil }
    var inputSource: (InputCapture) -> InputSource? = { _ in nil }
    var hasInputPermission: () -> Bool = { false }
    /// Shows the system's Input Monitoring prompt and returns whether input may be watched now. Only the live app has one, and only a
    /// toggle in the recording panel calls it.
    var requestInputPermission: () -> Bool = { false }
    /// The camera for a recording. A scripted instance draws a synthetic one and never opens a real camera.
    var cameraSource: () -> CameraSource? = { nil }
    /// Reads camera access without asking.
    var cameraAccess: () -> CameraAccess = { .denied }
    /// Shows the system's camera prompt. Only the live app has one, and only a click in Settings calls it.
    var requestCameraAccess: (@escaping (Bool) -> Void) -> Void = { $0(false) }
    /// The microphones a recording can use. Listing them never asks for access.
    var microphones: () -> [MicrophoneDevice] = { [] }
    /// Read without asking, so it never shows the system prompt.
    var microphoneAccess: () -> MicrophoneAccess = { .notAsked }
    /// Shows the system prompt. Only the live app does, when someone turns the microphone on.
    var requestMicrophoneAccess: (@escaping (Bool) -> Void) -> Void = { $0(false) }
    /// A microphone's sound, the default input's for nil. Nil means none can be recorded. A scripted instance plays a script.
    var microphoneSource: (String?) -> AudioSource? = { _ in nil }
    /// What the Mac plays while `FrameSource` films. Nil means it cannot be recorded.
    var systemAudioSource: (FrameSource) -> AudioSource? = { _ in nil }
    /// The window a scripted instance films. Nil in a normal instance.
    var recordingTestWindow: RecordingTestWindowHosting?
    /// Where recordings in progress are noted, so one cut off by a crash is finished at the next launch. Nil keeps no notes.
    var recordingJournal: RecordingJournal?

    var isOnscreen: Bool { presentation == .onscreen }

    init(screen: ScreenSource, store: CaptureStore, defaults: UserDefaults, pasteboard: NSPasteboard,
         presentation: OverlayPresentation, clock: @escaping () -> Date, cursorScreenFrame: @escaping () -> CGRect,
         hasScreenPermission: @escaping () -> Bool, requestScreenPermission: @escaping () -> Void,
         openURL: @escaping (URL) -> Void, revealInFinder: @escaping (URL) -> Void, playSound: @escaping () -> Void,
         pickFolder: @escaping (@escaping (URL?) -> Void) -> Void, loginItem: LoginItemControlling, updateService: UpdateServicing,
         defaultSaveFolder: URL, dragDirectory: URL, quit: @escaping () -> Void) {
        self.screen = screen; self.store = store; self.defaults = defaults; self.pasteboard = pasteboard
        self.presentation = presentation; self.clock = clock; self.cursorScreenFrame = cursorScreenFrame
        self.hasScreenPermission = hasScreenPermission; self.requestScreenPermission = requestScreenPermission
        self.openURL = openURL; self.revealInFinder = revealInFinder; self.playSound = playSound
        self.pickFolder = pickFolder; self.loginItem = loginItem; self.updateService = updateService; self.defaultSaveFolder = defaultSaveFolder
        self.dragDirectory = dragDirectory; self.quit = quit
    }

    /// Windows are only ever ordered in through here, so an offscreen environment cannot flash anything.
    func present(_ window: NSWindow?, activate: Bool = true) {
        guard let window else { return }
        willPresent(window)
        guard isOnscreen else { return }
        if activate { NSApp.activate(ignoringOtherApps: true) }
        window.makeKeyAndOrderFront(nil)
    }
}
