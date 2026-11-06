import AppKit
import AVFoundation
import CornermarkCapture
import CornermarkCore
import CornermarkDesign
@testable import CornermarkShell

@MainActor
func checkRecordingCamera() async throws {
    section("camera settings")
    let d = RecordingPreferences()
    check(!d.camera.isVisible && d.camera.shape == .circle && d.camera.size == .medium && d.camera.position == .bottomLeft && d.camera.isMirrored,
          "defaults: camera off, a medium mirrored circle in the bottom-left corner")
    let old = try JSONDecoder().decode(Settings.self, from: Data(#"{"recording":{"fps":30}}"#.utf8))
    check(old.recording.camera == d.camera && old.recording.fps == 30, "settings saved before the camera decode with it off")
    var s = Settings()
    s.recording.camera = CameraBubble(isVisible: true, shape: .rectangle, size: .large, position: .topRight, isMirrored: false)
    check(try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(s)) == s, "the camera settings round-trip through JSON")

    section("camera links")
    func parse(_ q: String) -> Result<AppAction, URLCommandError> { URLCommand.parse(URL(string: "\(URLCommand.scheme)://record/camera\(q)")!) }
    check(parse("") == .success(.changeCamera(.toggleFullScreen)), "record/camera alone toggles full screen, as a click on the bubble does")
    check(parse("?shape=square&size=large&corner=topRight&mirror=0") == .success(.changeCamera(CameraChange(shape: .square, size: .large, corner: .topRight, mirrored: false))),
          "shape, size, corner and mirror change the look and leave full screen alone")
    check(parse("?full-screen=on") == .success(.changeCamera(CameraChange(fullScreen: .on))), "full-screen=on fills the picture")
    check(parse("?shape=hexagon") == .failure(.invalidRecording("camera shape")) && parse("?mirror=yes") == .failure(.invalidRecording("camera mirror")),
          "an unknown value is refused, naming the field")

    section("Camera settings pane")
    let (w, _) = try recordingWorld(frames: 120)
    defer { w.cleanup() }
    let c = w.coordinator
    var access = CameraAccess.notAsked
    var requests = 0
    var cameras: [ScriptedCameraSource] = []
    w.env.cameraAccess = { access }
    w.env.requestCameraAccess = { done in
        requests += 1
        access = .allowed
        done(true)
    }
    // Frames on the host clock, as a live stream stamps them, so a full-screen click lands inside the recording.
    w.env.frameSource = { target, options in
        let area: CGRect? = { if case .display(_, let a) = target { return a } else { return nil } }()
        return FixtureFrameSource(displayFrame: FixtureFrameSource.displayFrame, scale: 2, area: area, options: options, pacing: .realtime)
    }
    w.env.cameraSource = {
        let camera = ScriptedCameraSource(pacing: .manual(origin: recordingClockNow()))
        cameras.append(camera)
        return camera
    }
    c.perform(.openSettings)
    guard let sw = c.settingsWindow, let pane = sw.panes.first(where: { $0 is CameraPane }) else { return check(false, "the Camera pane exists") }
    sw.select(pane: pane)
    let page = pane.view
    let shape = findView("camera.shape", in: page) as? NSSegmentedControl
    let status = findView("camera.access", in: page) as? NSTextField
    let button = findView("camera.access.button", in: page) as? NSButton
    check(shape?.isEnabled == false && (findView("camera.size", in: page) as? NSControl)?.isEnabled == false, "with the camera off its look cannot be changed")
    check(status?.stringValue == "Not asked yet" && button?.title == "Allow Camera Access" && button?.isHidden == false,
          "camera access not asked yet offers to ask", detail: status?.stringValue ?? "nil")
    check(click("camera.show", in: page) && c.settings.value.recording.camera.isVisible && requests == 1,
          "turning the camera on asks for access once")
    check(status?.stringValue == "Allowed" && button?.isHidden == true && shape?.isEnabled == true, "and once allowed the look can be changed")
    if let shape { shape.selectedSegment = 2; fire(shape) }
    if let size = findView("camera.size", in: page) as? NSPopUpButton { size.selectItem(at: 0); fire(size) }
    check(c.settings.value.recording.camera.shape == .rectangle && c.settings.value.recording.camera.size == .small, "shape and size reach the settings")
    access = .denied
    pane.refresh()
    check(status?.stringValue == "Not allowed" && status?.textColor == DS.Color.dangerText && button?.title == "Open System Settings",
          "denied access with the camera on is a problem the pane says how to fix")
    check(click("camera.access.button", in: page) && w.opened.last == AppEnvironment.cameraPaneURL && requests == 1,
          "and opens the Camera privacy pane without asking again")
    access = .allowed
    c.settings.update { $0.recording.camera = CameraBubble(isVisible: true) }

    section("camera while recording")
    let area = CGRect(x: 0, y: 0, width: 640, height: 360)
    func start(_ style: String) async -> Bool {
        guard c.handle(url: URL(string: "\(URLCommand.scheme)://record?display=1&x=0&y=0&width=640&height=360&style=\(style)")!) else { return false }
        return await waitUntil { c.recording.phase == .recording }
    }
    func link(_ q: String) { _ = c.handle(url: URL(string: "\(URLCommand.scheme)://record/camera\(q)")!) }
    func stop() async -> CaptureRecord? {
        let before = Set(w.store.list().map(\.id))
        _ = c.handle(url: URL(string: "\(URLCommand.scheme)://record/stop")!)
        guard await waitUntil(10, { c.recording.phase == .idle && w.store.list().count > before.count }) else { return nil }
        return w.store.list().first { !before.contains($0.id) }
    }
    check(await start("editing"), "a recording with the camera starts")
    let bubble = c.controls.camera
    let rest = CameraLayout.frame(CameraBubble(), area: area.size, at: 0)!
    check(w.presented.contains { $0.title == "Recording Camera" } && bubble.panel?.sharingType == NSWindow.SharingType.none,
          "the camera's window is presented, and never appears in a recording or a screenshot")
    check(bubble.panel?.frame == CameraBubbleWindow.screenRect(rest, area: area) && bubble.view?.cornerRadius == CGFloat(rest.cornerRadius),
          "it sits over the bottom-left of the area, where the camera is in the picture", detail: "\(String(describing: bubble.panel?.frame))")
    check(cameras.count == 1, "the camera source was made once")
    cameras.last?.advance(3)
    check(await waitUntil { bubble.view?.image != nil }, "camera pictures reach the bubble on screen")
    link("?shape=square&corner=topRight&mirror=0")
    let square = CameraLayout.frame(CameraBubble(shape: .square, position: .topRight, isMirrored: false), area: area.size, at: 0)!
    check(bubble.panel?.frame == CameraBubbleWindow.screenRect(square, area: area) && bubble.view?.isMirrored == false,
          "a link moves and reshapes it, and turns mirroring off")
    try await Task.sleep(nanoseconds: 300_000_000)
    _ = bubble.view?.accessibilityPerformPress()
    check(bubble.panel?.frame == area && bubble.view?.isFullScreen == true && c.recording.cameraLook?.isFullScreen == true,
          "pressing the bubble fills the recorded area with the camera")
    try await Task.sleep(nanoseconds: 500_000_000)
    link("")
    check(bubble.panel?.frame == CameraBubbleWindow.screenRect(square, area: area) && bubble.view?.isFullScreen == false,
          "and toggling again brings the bubble back")
    if let view = bubble.view, let panel = bubble.panel {
        panel.setFrameOrigin(NSPoint(x: area.minX + 20, y: area.minY + 20))
        view.onDrop(CGPoint(x: panel.frame.midX, y: panel.frame.midY))
    }
    check(c.recording.cameraLook?.current.position == .bottomLeft && c.settings.value.recording.camera.position == .bottomLeft,
          "a drag settles in the nearest corner, and the next recording starts there")
    let record = await stop()
    check(bubble.panel == nil, "the camera's window closes with the recording")
    if let folder = record?.video?.location, let project = try? RecordingProjectFile.read(from: folder) {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.sorted() ?? []
        check(files == ["camera.mp4", "project.json", "screen.mp4"] && project.source.camera == "camera.mp4",
              "Record for Editing keeps the camera as its own file in the project", detail: "\(files)")
        check(project.edits.camera.shape == .square && project.edits.camera.position == .bottomLeft && !project.edits.camera.isMirrored
              && project.edits.camera.fullScreen.count == 1, "and the look at the end, with the full-screen stretch", detail: "\(project.edits.camera)")
    } else { check(false, "the project with a camera can be read") }

    check(await start("video"), "a video with the camera starts")
    if let r = await stop(), let file = r.video?.file {
        let folder = file.deletingLastPathComponent()
        check(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("camera.mp4").path), "Record Video leaves no camera file: the camera is in its picture")
    } else { check(false, "the video with a camera was saved") }

    access = .denied
    c.hud.show("waiting")
    let made = cameras.count
    check(await start("editing"), "without camera access a recording still starts")
    check(bubble.panel == nil && cameras.count == made && c.hud.lastMessage == "Allow camera access in Settings > Camera to show the camera",
          "but shows no camera, makes no camera source, and says why", detail: c.hud.lastMessage ?? "nil")
    if let folder = await stop()?.video?.location {
        check(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("camera.mp4").path), "and keeps no camera file")
    }
    check(requests == 1, "a recording never asks for camera access")
    link("")
    check(c.recording.cameraLook == nil, "a camera link with nothing recording is refused")

    section("camera from the keyboard")
    func cameraRow(_ full: Bool?) -> MenuPanelModel.Row? {
        let model = MenuPanelModel.make(settings: Settings(), update: .idle, overlaysHidden: false, canRestoreOverlay: false, pins: [], recording: .recording,
                                        cameraFullScreen: full, recent: [])
        for section in model.sections { if case .rows(let rows) = section, let row = rows.first(where: { $0.item == .action(.recordingCamera) }) { return row } }
        return nil
    }
    check(cameraRow(nil) == nil, "with no camera the menu panel offers no camera row")
    check(cameraRow(false)?.title == "Fill with Camera" && cameraRow(true)?.title == "Shrink Camera to Bubble",
          "while the camera shows, the menu panel offers its click by keyboard, named for what it does next")
    check(AppAction.make(.recordingCamera, timerSeconds: 5) == .changeCamera(.toggleFullScreen), "and the row toggles full screen")

    section("camera of an isolated instance")
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("CornermarkHarness-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let env = try AppEnvironment.isolated(root: root, defaults: MemoryDefaults())
    var granted: Bool?
    env.requestCameraAccess { granted = $0 }
    check(env.cameraSource() is ScriptedCameraSource && env.cameraAccess() == .allowed && granted == false,
          "a scripted instance films a synthetic camera, needs no access, and refuses to ask for it")
    env.recordingTestWindow?.close()
    check(LiveCameraSource.sessionsOpened == 0 && CameraAccess.requests == 0, "no real camera was opened and access was never asked for",
          detail: "sessions \(LiveCameraSource.sessionsOpened) requests \(CameraAccess.requests)")
}
