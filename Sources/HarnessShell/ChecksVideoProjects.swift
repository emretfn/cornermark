import AppKit
import AVFoundation
import CornermarkCore
@testable import CornermarkVideoEditor
@testable import CornermarkShell

@MainActor
func checkVideoProjects() async throws {
    try await checkOpeningVideoFiles()
    try await checkSavingProjects()
    checkProjectDocumentTypes()
}

@MainActor
private func checkOpeningVideoFiles() async throws {
    section("video projects: opening a video file")
    let (w, _) = try recordingWorld(frames: 60)
    defer { w.cleanup() }
    let c = w.coordinator
    let inbox = w.root.appendingPathComponent("in", isDirectory: true)
    try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
    let movie = inbox.appendingPathComponent("synthetic clip.mov")
    try await SyntheticMovie.write(to: movie)
    let movieHash = sha256OrUnreadable(movie)

    func link(_ path: String) -> URL { URL(string: "\(URLCommand.scheme)://open?path=\(path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!)")! }
    check(URLCommand.parse(link(movie.path)) == .success(.openFile(movie.standardizedFileURL.resolvingSymlinksInPath())), "an open link to a MOV file asks to open it")
    check(URLCommand.parse(link(inbox.appendingPathComponent("missing.mp4").path)) == .failure(.invalidFile(inbox.appendingPathComponent("missing.mp4").path)),
          "an open link to a video that is not there is refused")

    let saveFolder = c.settings.value.resolvedSaveFolder(default: w.env.defaultSaveFolder)
    let before = Set(w.store.list().map(\.id))
    c.perform(.openFile(movie))
    check(await waitUntil(10) { !c.videoEditors.isEmpty }, "opening a video file opens the video editor")
    let package = saveFolder.appendingPathComponent("synthetic clip.cornermarkvideo", isDirectory: true)
    let key = package.standardizedFileURL.resolvingSymlinksInPath()
    guard let editor = c.videoEditors[key] else { return check(false, "the editor edits a new package in the save folder", detail: "\(c.videoEditors.keys.map(\.path))") }
    await editor.ready()
    let names = Set((try? FileManager.default.contentsOfDirectory(atPath: package.path)) ?? [])
    check(names == ["synthetic clip.mov", RecordingProjectFile.projectName], "the package holds the video under its own name and project.json, nothing else", detail: "\(names)")
    check(sha256OrUnreadable(package.appendingPathComponent("synthetic clip.mov")) == movieHash, "the video in the package is the original's bytes: copied, not encoded again")
    check(sha256OrUnreadable(movie) == movieHash && FileManager.default.fileExists(atPath: movie.path), "the original file is left where it was, unchanged")
    let project = editor.state.project
    check(project.source.origin == .file && project.source.video == "synthetic clip.mov", "the project says it came from a file and names its video")
    check(project.source.pixelWidth == 640 && project.source.pixelHeight == 360 && project.source.fps == 30 && abs(project.source.duration - 2) < 0.05,
          "and reads the video's size, frame rate and length", detail: "\(project.source)")
    check(project.events == RecordingProject.Events(), "a video from a file has no pointer, click or key track")
    check(editor.window?.title == "synthetic clip", "the window is titled with the video's name", detail: editor.window?.title ?? "nil")
    let listed = w.store.list().first { !before.contains($0.id) }
    check(listed?.video?.format == .project && listed?.kind == .imported && listed?.video?.file.lastPathComponent == "synthetic clip.mov",
          "History lists the new project, so it opens again from there", detail: "\(String(describing: listed?.video))")
    check(listed?.opensVideoEditor == true, "and its Edit opens the video editor")

    func note(_ section: EditorSection) -> String? {
        editor.select(section)
        return (editor.view(identifier: "video.panel.note") as? NSTextField).flatMap { $0.isHiddenOrHasHiddenAncestor ? nil : $0.stringValue }
    }
    check(note(.cursor) == InspectorView.note(.cursor, origin: .file) && (editor.view(identifier: "video.cursor.show")?.isHiddenOrHasHiddenAncestor ?? false),
          "Cursor says the pointer is part of the picture and hides the pointer settings", detail: note(.cursor) ?? "nil")
    check(note(.keystrokes) == "This video was opened from a file, so no keystrokes were recorded with it.", "Keystrokes says why it has none")
    check(note(.audio) == "This video plays and exports with its own sound.", "Audio says the video's own sound is kept", detail: note(.audio) ?? "nil")
    editor.select(.background)
    check(editor.view(identifier: "video.background.gradient.0")?.isHiddenOrHasHiddenAncestor == false, "the background settings work as for a recording")

    editor.openExport()
    editor.startExport()
    check(await waitUntil(20) { w.store.list().contains(where: \.ownsVideo) }, "the project exports")
    if let file = w.store.list().first(where: \.ownsVideo)?.video?.file {
        let asset = AVURLAsset(url: file)
        let sound = (try? await asset.loadTracks(withMediaType: .audio))?.count ?? 0
        let seconds = (try? await asset.load(.duration).seconds) ?? 0
        check(sound == 1 && abs(seconds - 2) < 0.1, "the export carries the video's own sound for its whole length", detail: "audio tracks \(sound), \(seconds) s")
    }
    c.closeAllEditors()

    c.perform(.openFile(movie))
    check(await waitUntil(10) { c.videoEditors.keys.contains { $0.lastPathComponent == "synthetic clip 2.cornermarkvideo" } }, "opening the same file again makes a second project and never overwrites the first")
    c.closeAllEditors()

    check(URLCommand.parse(link(package.path)) == .success(.openRecording(key)), "an open link to a project package opens it as a project")
    c.perform(.openFile(package))
    check(c.videoEditors[key] != nil, "a package handed to the app opens in the video editor")
    c.closeAllEditors()

    let junk = inbox.appendingPathComponent("not a video.mp4")
    try Data("not a movie".utf8).write(to: junk)
    let count = w.store.list().count
    c.perform(.openFile(junk))
    check(await waitUntil(5) { c.hud.lastMessage?.hasPrefix("Could not open the video") == true }, "a file that is not a video is refused with a message", detail: c.hud.lastMessage ?? "nil")
    check(!FileManager.default.fileExists(atPath: saveFolder.appendingPathComponent("not a video.cornermarkvideo").path) && w.store.list().count == count,
          "and leaves no package and no History entry behind")

    let turned = inbox.appendingPathComponent("turned.mp4")
    try await SyntheticMovie.write(to: turned, SyntheticMovie.Spec(frames: 10, sound: false, fileType: .mp4, turned: true))
    c.perform(.openFile(turned))
    check(await waitUntil(5) { c.hud.lastMessage == AppCoordinator.importFailure(VideoImportError.turned) }, "a video stored turned on its side is refused and says why", detail: c.hud.lastMessage ?? "nil")
    check(!FileManager.default.fileExists(atPath: saveFolder.appendingPathComponent("turned.cornermarkvideo").path), "and leaves no package behind")

    let silent = inbox.appendingPathComponent("silent.mp4")
    try await SyntheticMovie.write(to: silent, SyntheticMovie.Spec(frames: 15, sound: false, fileType: .mp4))
    c.perform(.openFile(silent))
    check(await waitUntil(10) { c.videoEditors.keys.contains { $0.lastPathComponent == "silent.cornermarkvideo" } }, "an MP4 file opens too")
    if let quiet = c.videoEditors.values.first(where: { $0.folder.lastPathComponent == "silent.cornermarkvideo" }) {
        await quiet.ready()
        quiet.select(.audio)
        check((quiet.view(identifier: "video.panel.note") as? NSTextField)?.stringValue == "This video has no sound.", "Audio says a silent video has no sound")
    }
    c.closeAllEditors()
}

@MainActor
private func checkSavingProjects() async throws {
    section("video projects: save, save as and closing")
    let (w, _) = try recordingWorld(frames: 120)
    defer { w.cleanup() }
    let c = w.coordinator
    guard let record = await recordOnce(w, "display=1&x=0&y=0&width=640&height=360"), let folder = record.video?.location else {
        return check(false, "a project is recorded from the fixture display")
    }
    check(folder.pathExtension == RecordingProjectFile.packageExtension, "a recording for editing is saved as a package", detail: folder.lastPathComponent)
    let videoHash = sha256OrUnreadable(folder.appendingPathComponent(RecordingProjectFile.videoName))
    guard let editor = c.openVideoEditor(folder), let window = editor.window else { return check(false, "the editor opens") }
    await editor.ready()
    let status = editor.view(identifier: "video.document.status") as? NSTextField
    check(status?.isHidden == true && !window.isDocumentEdited, "a project just opened says nothing about saving")
    let onDisk = try RecordingProjectFile.read(from: folder)

    var background = editor.state.project.edits.background
    background.fill = .gradient(index: 3)
    editor.setBackground(background)
    editor.seek(to: 1)
    editor.splitAtPlayhead()
    var cursor = editor.state.project.edits.cursor
    cursor.scale = 2
    editor.setCursor(cursor)
    check(status?.isHidden == false && status?.stringValue == "Edited" && window.isDocumentEdited, "an edit shows Edited and marks the window edited")
    check(try RecordingProjectFile.read(from: folder) == onDisk, "and the project file is not written yet")

    Synth.key(window, 1, "s", modifiers: .command)
    let stored = try RecordingProjectFile.read(from: folder)
    check(stored == editor.state.project, "Command-S writes every edit to project.json")
    check(status?.stringValue == "Saved" && !window.isDocumentEdited, "and the header says Saved")
    check(sha256OrUnreadable(folder.appendingPathComponent(RecordingProjectFile.videoName)) == videoHash, "saving never touches the source video")
    check(editor.canUndo, "undo still has the edits after saving")
    editor.undo()
    check(status?.stringValue == "Edited" && editor.state.project.edits.cursor.scale != 2, "undo after saving takes back the last edit and shows Edited")
    editor.redo()
    check(editor.state.project == stored && status?.stringValue == "Saved" && !window.isDocumentEdited, "redo brings it back, matching the saved file again")

    background.fill = .gradient(index: 5)
    editor.setBackground(background)
    let expected = editor.state.project
    check(editor.windowShouldClose(window), "closing with unsaved edits needs no question")
    window.close()
    check(window.attachedSheet == nil && NSApp.modalWindow == nil, "no sheet or alert appears")
    check(try c.videoEditors.isEmpty && RecordingProjectFile.read(from: folder) == expected, "closing saves the edits and forgets the editor")

    guard let again = c.openVideoEditor(folder) else { return check(false, "the project reopens") }
    await again.ready()
    let restored = again.state.project
    check(restored == expected, "reopening restores every edit: clips, background, cursor")
    check(restored.timeline.clips.count == 2 && restored.edits.background.fill == .gradient(index: 5) && restored.edits.cursor.scale == 2,
          "the split, the gradient and the pointer size are all back", detail: "clips \(restored.timeline.clips.count) fill \(restored.edits.background.fill)")
    check((again.view(identifier: "video.document.status") as? NSTextField)?.isHidden == true, "and the header has nothing to say until the next edit")

    var corners = again.state.project.edits.background
    corners.cornerRadius = 30
    again.setBackground(corners)
    let copy = c.settings.value.resolvedSaveFolder(default: w.env.defaultSaveFolder).appendingPathComponent("Copy for review")
    let listed = w.store.list().count
    try again.saveAs(to: copy)
    let copyPackage = copy.appendingPathExtension(RecordingProjectFile.packageExtension).standardizedFileURL.resolvingSymlinksInPath()
    check(again.folder.path == copyPackage.path, "Save As adds the package extension and edits the copy from then on", detail: again.folder.path)
    check(again.window?.title == "Copy for review" && c.videoEditors.count == 1 && c.openVideoEditor(copyPackage) === again, "the window takes the copy's name and the app tracks it by its new folder")
    check((try RecordingProjectFile.read(from: copyPackage)) == again.state.project, "the copy holds the edits, the unsaved one included")
    check((try RecordingProjectFile.read(from: folder)) == expected, "the project it left keeps what was last saved there")
    check(sha256OrUnreadable(copyPackage.appendingPathComponent(RecordingProjectFile.videoName)) == videoHash, "the copy's video is the same bytes")
    check(await waitUntil(5) { w.store.list().count == listed + 1 } && w.store.list().contains { $0.video?.location.lastPathComponent == "Copy for review.cornermarkvideo" },
          "History lists the copy", detail: "\(w.store.list().compactMap { $0.video?.location.lastPathComponent })")
    check(!FileManager.default.contentsOfDirectorySafe(copyPackage.deletingLastPathComponent()).contains { $0.hasPrefix(".") && $0.hasSuffix(".cornermarkvideo") },
          "no hidden staging copy is left beside it")

    Synth.key(again.window!, 1, "S", modifiers: [.command, .shift])
    check(again.folder.lastPathComponent == "Copy for review copy.cornermarkvideo", "Shift-Command-S saves a copy; a scripted instance names it beside the project without a panel", detail: again.folder.lastPathComponent)

    corners.cornerRadius = 10
    again.setBackground(corners)
    let locked = again.folder
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
    let refused: Bool = { if case .failed = again.save() { return true } else { return false } }()
    check(refused && (again.view(identifier: "video.document.status") as? NSTextField)?.stringValue == "Edited", "saving into a folder that cannot be written fails and the header still says Edited")
    check(c.hud.lastMessage == "Could not save the edits. Choose File > Save As to keep them somewhere else.", "and says where to keep the edits instead", detail: c.hud.lastMessage ?? "nil")
    check(!again.windowShouldClose(again.window!) && c.videoEditors.values.contains { $0 === again }, "a close the viewer asks for then keeps the window open, so the edits are not lost")
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
    check(again.save() == .saved && (again.view(identifier: "video.document.status") as? NSTextField)?.stringValue == "Saved", "once the folder can be written, Save works")
    c.closeAllEditors()

    section("video projects: older project folders")
    let old = w.root.appendingPathComponent("Old Recording", isDirectory: true)
    try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
    for name in [RecordingProjectFile.videoName, RecordingProjectFile.projectName] {
        try FileManager.default.copyItem(at: folder.appendingPathComponent(name), to: old.appendingPathComponent(name))
    }
    let oldKey = old.standardizedFileURL.resolvingSymlinksInPath()
    check(URLCommand.parse(URL(string: "\(URLCommand.scheme)://edit-recording?path=\(old.path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!)")!) == .success(.openRecording(oldKey)),
          "an edit-recording link still opens a plain project folder")
    guard let legacy = c.openVideoEditor(old) else { return check(false, "a plain project folder opens") }
    check(legacy.window?.title == "Old Recording" && legacy.state.project == expected, "it opens with its edits and its folder's name")
    var cursorOff = legacy.state.project.edits.cursor
    cursorOff.isVisible = false
    legacy.setCursor(cursorOff)
    check(try legacy.save() == .saved && RecordingProjectFile.read(from: old).edits.cursor.isVisible == false, "Save writes into the plain folder")
    check(Set(try FileManager.default.contentsOfDirectory(atPath: old.path)) == [RecordingProjectFile.videoName, RecordingProjectFile.projectName], "and leaves it a plain folder")
    c.closeAllEditors()
}

/// The app bundle's Info.plist names the package so Finder shows it as one document and opens it here, and offers the app for MP4 and MOV.
@MainActor
private func checkProjectDocumentTypes() {
    section("video projects: document types")
    let plist = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Resources/Info.plist")
    guard let data = try? Data(contentsOf: plist), let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
        return check(false, "Info.plist is readable", detail: plist.path)
    }
    let exported = (info["UTExportedTypeDeclarations"] as? [[String: Any]])?.first { $0["UTTypeIdentifier"] as? String == VideoEditorWindowController.packageType.identifier }
    let tags = (exported?["UTTypeTagSpecification"] as? [String: Any])?["public.filename-extension"] as? [String]
    check(tags == [RecordingProjectFile.packageExtension] && (exported?["UTTypeConformsTo"] as? [String])?.contains("com.apple.package") == true,
          "the project type is declared as a package with the cornermarkvideo extension")
    let documents = info["CFBundleDocumentTypes"] as? [[String: Any]] ?? []
    let project = documents.first { ($0["LSItemContentTypes"] as? [String])?.contains(VideoEditorWindowController.packageType.identifier) == true }
    check(project?["LSTypeIsPackage"] as? Bool == true && project?["CFBundleTypeRole"] as? String == "Editor", "the app edits project packages")
    let video = documents.first { ($0["LSItemContentTypes"] as? [String])?.contains("public.mpeg-4") == true }
    check((video?["LSItemContentTypes"] as? [String])?.contains("com.apple.quicktime-movie") == true && video?["LSHandlerRank"] as? String == "Alternate",
          "MP4 and MOV list the app as an alternate, never taking over the default player")
    // The system player declares video as a viewer only, so an editor of any rank becomes the default app that opens a double-clicked MP4.
    check(video?["CFBundleTypeRole"] as? String == "Viewer", "MP4 and MOV declare the viewer role, so a double-clicked video still opens in the system player")
}

private extension FileManager {
    func contentsOfDirectorySafe(_ url: URL) -> [String] { (try? contentsOfDirectory(atPath: url.path)) ?? [] }
}
