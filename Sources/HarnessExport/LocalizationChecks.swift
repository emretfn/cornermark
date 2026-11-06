import AppKit
import AVFoundation
import CornermarkCore
import CornermarkDesign
import CornermarkL10n
@testable import CornermarkVideoEditor

// HarnessExport check
// Builds the video editor window without showing it and walks its views in a pseudo language, to prove that every text follows the
// language, that a right-to-left language mirrors the chrome and not the media, and that switching keeps what the viewer was doing.

@MainActor
private enum Tally {
    static var passed = 0
    static var failed = 0
}

@MainActor
private func check(_ ok: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
    if ok {
        Tally.passed += 1
        print("PASS \(name)")
    } else {
        Tally.failed += 1
        let more = detail()
        print("FAIL \(name)" + (more.isEmpty ? "" : "\n     \(more)"))
    }
}

@MainActor
private final class StubFrames: SourceFrames {
    var hasAudio = true
    var volume: Float = 1
    func follow(sourceTime: Double, playing: Bool, now: Double) {}
    func frame(at sourceTime: Double) -> CGImage? { nil }
    func load() async {}
}

private func writeMovie(to url: URL, width: Int, height: Int, fps: Int, frames: Int) async throws {
    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
    ])
    writer.add(input)
    writer.startWriting()
    writer.startSession(atSourceTime: .zero)
    for i in 0..<frames {
        while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
        CVPixelBufferLockBaseAddress(buffer!, [])
        memset(CVPixelBufferGetBaseAddress(buffer!), Int32(i * 4 % 255), CVPixelBufferGetDataSize(buffer!))
        CVPixelBufferUnlockBaseAddress(buffer!, [])
        adaptor.append(buffer!, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: CMTimeScale(fps)))
    }
    input.markAsFinished()
    await writer.finishWriting()
}

/// A recording with everything the editor can show: a camera, both sound tracks, keystrokes, clicks and two zooms.
private func editorProject(duration: Double, width: Int = 640, height: Int = 360, fps: Int = 30, video: String = RecordingProjectFile.videoName) -> RecordingProject {
    let source = RecordingProject.Source(video: video, pixelWidth: width, pixelHeight: height, pointWidth: Double(width) / 2, pointHeight: Double(height) / 2,
                                         fps: fps, duration: duration, microphone: "mic.m4a", systemAudio: "system.m4a", camera: "camera.mp4")
    let pointer = stride(from: 0.0, through: duration, by: 0.25).map { PointerSample(t: $0, x: 40 + $0 * 20, y: 60 + $0 * 8) }
    var edits = RecordingProject.Edits()
    edits.zooms = [Zoom(start: 1, end: 3, scale: 2, mode: .manual), Zoom(start: 4, end: 6, scale: 1.5)]
    return RecordingProject(source: source, events: .init(pointer: pointer, clicks: [ClickEvent(t: 1.5, x: 80, y: 90)],
                                                          keys: [KeyEvent(t: 2, label: "\u{2318}B", isCommand: true)]), edits: edits)
}

@MainActor
private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

private struct Item: Hashable {
    var kind: String
    var text: String
}

/// Every text a person can read in the window: labels, button titles, segments, menu items, tooltips and accessibility labels and help.
@MainActor
private func visibleTexts(_ root: NSView) -> [Item] {
    var out: [Item] = []
    func add(_ kind: String, _ text: String?) {
        if let text, !text.isEmpty { out.append(Item(kind: kind, text: text)) }
    }
    for view in descendants(root) where !view.isHiddenOrHasHiddenAncestor {
        switch view {
        case let input as TextInput: add("placeholder", input.placeholderString)
        case let field as NSTextField: add("text", field.stringValue)
        case let segments as NSSegmentedControl:
            for i in 0..<segments.segmentCount {
                add("segment", segments.label(forSegment: i))
                add("segment image", segments.image(forSegment: i)?.accessibilityDescription)
                add("segment tooltip", segments.toolTip(forSegment: i))
            }
        case let popUp as NSPopUpButton: popUp.itemTitles.forEach { add("menu item", $0) }
        case let button as NSButton where !(button is IconButton): add("button", button.title)
        default: break
        }
        add("tooltip", view.toolTip)
        if view.isAccessibilityElement() {
            add("accessibility label", view.accessibilityLabel())
            add("accessibility help", view.accessibilityHelp())
        }
        if let lane = view as? ZoomLaneView {
            for child in lane.accessibilityChildren() ?? [] { add("zoom label", (child as? NSAccessibilityElement)?.accessibilityLabel()) }
        }
    }
    return out
}

@MainActor
private func menuTexts(_ menu: NSMenu?) -> [Item] {
    guard let menu else { return [] }
    return [Item(kind: "menu title", text: menu.title)] + menu.items.flatMap { item in
        [Item(kind: "menu item", text: item.title)] + menuTexts(item.submenu)
    }
}

/// Wrapped once, with nothing readable left over outside the wraps, so a word glued on in code shows. Text with no letters is exempt.
private func isWrapped(_ text: String) -> Bool {
    guard text.contains(where: \.isLetter) else { return true }
    guard text.hasPrefix("\u{2039}"), text.hasSuffix("\u{203A}") else { return false }
    var rest = text
    while let range = rest.range(of: "\u{2039}[^\u{2039}\u{203A}]*\u{203A}", options: .regularExpression) { rest.replaceSubrange(range, with: "") }
    return !rest.contains(where: \.isLetter)
}

private func unwrapped(_ items: [Item]) -> [String] {
    var seen = Set<Item>()
    return items.filter { !isWrapped($0.text) && seen.insert($0).inserted }.map { "\($0.kind): \($0.text)" }
}

@MainActor
private func directionProblems(_ root: NSView, rtl: Bool) -> [String] {
    var problems: [String] = []
    func walk(_ view: NSView, keepsLeftToRight: Bool) {
        let keeps = keepsLeftToRight || view is KeepsLeftToRight || view is PositionGrid
        let expected: NSUserInterfaceLayoutDirection = rtl && !keeps ? .rightToLeft : .leftToRight
        // A text field and the label inside it take their direction from the writing direction and do not hold the property.
        if view is NSTextField { return }
        if view.userInterfaceLayoutDirection != expected { problems.append("\(type(of: view)) in \(type(of: view.superview)) \(view.superview?.accessibilityIdentifier() ?? "") \(view.accessibilityIdentifier()) is not \(expected == .rightToLeft ? "rtl" : "ltr")") }
        for sub in view.subviews { walk(sub, keepsLeftToRight: keeps) }
    }
    walk(root, keepsLeftToRight: false)
    return problems
}

private struct EditorState: Equatable {
    var section: EditorSection
    var clip: Int?
    var zoom: UUID?
    var time: Double
    var project: RecordingProject
    var canUndo: Bool
    var frame: CGRect
    var previewOnly: Bool
    var export: ExportPhase
    var exportSettings: ExportSettings
    var animationOpen: Bool
    var scroll: CGFloat?
}

@MainActor
private func scrollView(of editor: VideoEditorWindowController) -> NSScrollView? {
    editor.view(identifier: "video.background").flatMap { descendants($0).compactMap { $0 as? NSScrollView }.first }
}

@MainActor
private func state(of editor: VideoEditorWindowController) -> EditorState {
    let s = editor.state
    return EditorState(section: s.section, clip: s.selectedClip, zoom: s.selectedZoom, time: s.transport.time(at: 100), project: s.project, canUndo: editor.canUndo,
                       frame: editor.window?.frame ?? .zero, previewOnly: s.isPreviewOnly, export: s.export, exportSettings: s.exportSettings,
                       animationOpen: s.showsZoomAnimation, scroll: s.section == .background ? scrollView(of: editor)?.contentView.bounds.origin.y : nil)
}

@MainActor
private func settle(_ editor: VideoEditorWindowController) { editor.window?.contentView?.layoutSubtreeIfNeeded() }

private let pseudo: (String) -> String = { "\u{2039}\($0)\u{203A}" }

/// Switches to Arabic in the pseudo language, runs `inRight`, switches back to English, and runs `inEnglish`.
@MainActor
private func throughArabic(_ editor: VideoEditorWindowController, name: String, texts extra: (() -> [Item])? = nil) {
    let english = visibleTexts(editor.window!.contentView!) + (extra?() ?? [])
    let before = state(of: editor)

    L10n.setPseudoLanguage(.ar, transform: pseudo)
    settle(editor)
    let arabic = visibleTexts(editor.window!.contentView!) + (extra?() ?? [])
    let loose = unwrapped(arabic)
    check(loose.isEmpty, "\(name): every text follows the language", loose.prefix(6).joined(separator: "\n     "))
    check(arabic.count == english.count, "\(name): no text appears or goes missing", "\(english.count) in English, \(arabic.count) in Arabic")
    let wrong = directionProblems(editor.window!.contentView!, rtl: true)
    check(wrong.isEmpty && editor.window!.contentView!.userInterfaceLayoutDirection == .rightToLeft,
          "\(name): the chrome mirrors and the media stays left to right", wrong.prefix(6).joined(separator: "\n     "))
    check(state(of: editor) == before, "\(name): the editor keeps its state", "\(before)\n     \(state(of: editor))")

    L10n.setLanguage(.en)
    settle(editor)
    let back = visibleTexts(editor.window!.contentView!) + (extra?() ?? [])
    check(back == english, "\(name): English comes back unchanged", zip(back, english).first { $0 != $1 }.map { "\($0.0) vs \($0.1)" } ?? "\(back.count) vs \(english.count)")
    let leftover = directionProblems(editor.window!.contentView!, rtl: false)
    check(leftover.isEmpty, "\(name): the layout is left to right again", leftover.prefix(4).joined(separator: "\n     "))
    check(state(of: editor) == before, "\(name): the editor keeps its state going back")
}

@MainActor
func localizationChecks() async -> Bool {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.prohibited)
    L10n.setLanguage(.en)
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cornermark-l10n-\(UUID().uuidString.prefix(6))", isDirectory: true)
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }

    let editor = VideoEditorWindowController(folder: folder, project: editorProject(duration: 8), frames: StubFrames(), clock: { 100 })
    await editor.ready()
    guard let window = editor.window, window.contentView != nil else {
        check(false, "the editor builds its window")
        return false
    }
    window.setContentSize(NSSize(width: 1200, height: 780))
    settle(editor)

    editor.seek(to: 2.5)
    editor.splitAtPlayhead()
    editor.selectClip(1)
    for section in EditorSection.allCases {
        editor.select(section)
        throughArabic(editor, name: "the \(section.title) section")
    }

    editor.select(.background)
    (editor.view(identifier: "video.background.more") as? NSButton)?.performClick(nil)
    settle(editor)
    let fills = scrollView(of: editor)
    let room = fills.map { ($0.documentView?.frame.height ?? 0) - $0.contentView.bounds.height } ?? 0
    check(room > 80, "the background fills are taller than their window, so a scroll position can be kept", "\(room)")
    fills?.contentView.scroll(to: NSPoint(x: 0, y: 70))
    fills?.reflectScrolledClipView(fills!.contentView)
    let panelBefore = state(of: editor)
    throughArabic(editor, name: "the background section scrolled with all gradients")
    check(panelBefore.scroll == 70, "the background section keeps its scroll position", "\(String(describing: panelBefore.scroll))")
    check(editor.view(identifier: "video.background.gradient.19")?.isHiddenOrHasHiddenAncestor == false && editor.view(identifier: "video.background.gradient.19")?.window != nil,
          "the gradients stay open after the switch")

    guard let manual = editor.state.project.edits.zooms.first(where: { $0.mode == .manual }) else { return false }
    editor.selectZoom(manual.id)
    settle(editor)
    throughArabic(editor, name: "a manual zoom's settings and target frame", texts: { menuTexts(editor.zoomMenu(for: manual.id)) })

    editor.openZoomAnimation()
    settle(editor)
    throughArabic(editor, name: "Animation Settings over the zoom settings")
    check(editor.state.showsZoomAnimation && editor.view(identifier: "video.zoomAnimation.panel")?.isHiddenOrHasHiddenAncestor == false,
          "Animation Settings stays open after the switch")
    editor.closeZoomAnimation()
    editor.selectZoom(nil)

    editor.openExport()
    settle(editor)
    editor.setExportSettings(ExportSettings(resolution: .original, quality: .low))
    throughArabic(editor, name: "the export panel while choosing")
    check(editor.state.export == .choosing && editor.view(identifier: "video.export.panel")?.isHiddenOrHasHiddenAncestor == false,
          "the export panel stays open after the switch")
    editor.closeExport()

    editor.setPreviewOnly(true)
    settle(editor)
    throughArabic(editor, name: "the full screen preview")
    editor.setPreviewOnly(false)

    focusChecks(editor)
    layoutChecks(editor)
    digitChecks(editor)
    await exportChecks()
    L10n.setLanguage(.en)

    print("")
    print("RESULT \(Tally.passed) passed, \(Tally.failed) failed")
    return Tally.failed == 0
}

@MainActor
private func focusChecks(_ editor: VideoEditorWindowController) {
    editor.select(.cursor)
    settle(editor)
    guard let box = editor.view(identifier: "video.cursor.hideIdle") else { return check(false, "the cursor settings have their checkboxes") }
    editor.window?.makeFirstResponder(box)
    L10n.setPseudoLanguage(.ar, transform: pseudo)
    settle(editor)
    let focused = (editor.window?.firstResponder as? NSView)?.accessibilityIdentifier()
    L10n.setLanguage(.en)
    check(focused == "video.cursor.hideIdle", "the focused control keeps the focus through a language switch", "\(String(describing: focused))")
}

@MainActor
private func layoutChecks(_ editor: VideoEditorWindowController) {
    editor.select(.cursor)
    settle(editor)
    func center(_ id: String) -> CGPoint? {
        editor.view(identifier: id).map { let f = $0.convert($0.bounds, to: nil); return CGPoint(x: f.midX, y: f.midY) }
    }
    guard let railEnglish = center("video.rail"), let previewEnglish = center("video.preview"), let startEnglish = center("video.start"), let endEnglish = center("video.end"),
          let exportEnglish = center("video.export"), let timeEnglish = center("video.time") else { return check(false, "the editor's landmarks exist") }
    check(railEnglish.x < previewEnglish.x && exportEnglish.x > previewEnglish.x && timeEnglish.x < previewEnglish.x, "in English the settings are left of the preview and Export is at the right")

    L10n.setPseudoLanguage(.ar, transform: pseudo)
    settle(editor)
    guard let rail = center("video.rail"), let preview = center("video.preview"), let start = center("video.start"), let end = center("video.end"),
          let export = center("video.export"), let time = center("video.time") else { return check(false, "the landmarks exist in Arabic") }
    check(rail.x > preview.x && export.x < preview.x && time.x > preview.x, "in Arabic the settings move to the right of the preview and Export to the left", "\(rail) \(preview) \(export) \(time)")
    check(startEnglish.x < endEnglish.x && start.x < end.x, "go to start stays left of go to end, since media time runs left to right")
    check(editor.view(identifier: "video.timeline")?.userInterfaceLayoutDirection == .leftToRight
          && editor.view(identifier: "video.preview")?.userInterfaceLayoutDirection == .leftToRight
          && editor.view(identifier: "video.zoomLane")?.userInterfaceLayoutDirection == .leftToRight, "the preview, the timeline and the zoom lane stay left to right")
    L10n.setLanguage(.en)
    settle(editor)
}

@MainActor
private func digitChecks(_ editor: VideoEditorWindowController) {
    check(Timecode.text(61.5) == "1:01.50" && Timecode.label(5, step: 5) == "0:05", "time codes keep their shape and Latin digits in English")
    L10n.setPseudoLanguage(.fa, transform: pseudo)
    settle(editor)
    check(Timecode.text(61.5) == "\u{06F1}:\u{06F0}\u{06F1}.\u{06F5}\u{06F0}" && Timecode.label(5, step: 5) == "\u{06F0}:\u{06F0}\u{06F5}",
          "time codes keep their shape and take the language's digits", Timecode.text(61.5))
    let readout = editor.view(identifier: "video.time") as? NSTextField
    editor.seek(to: 0)
    check(readout.map { $0.baseWritingDirection == .leftToRight && $0.stringValue.contains("\u{06F0}:\u{06F0}\u{06F0}.\u{06F0}\u{06F0}") } ?? false,
          "the time readout under the preview reads left to right in the language's digits", readout?.stringValue ?? "no readout")
    L10n.setLanguage(.en)
    check(Digits.percent(1.5) == "150%" && Digits.fixed(0.5, 2) == "0.50" && ExportPanel.bytes(1_234_567) == "1.2 MB", "English numbers are as they were")
}

@MainActor
private func exportChecks() async {
    let width = 320, height = 180, fps = 30, frames = 90
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cornermark-l10n-export-\(UUID().uuidString.prefix(6))", isDirectory: true)
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    do { try await writeMovie(to: folder.appendingPathComponent(RecordingProjectFile.videoName), width: width, height: height, fps: fps, frames: frames) } catch {
        return check(false, "the export check can write its movie", "\(error)")
    }
    var project = editorProject(duration: Double(frames) / Double(fps), width: width, height: height, fps: fps)
    project.source.microphone = nil
    project.source.systemAudio = nil
    project.source.camera = nil
    let editor = VideoEditorWindowController(folder: folder, project: project, frames: StubFrames(), clock: { 100 })
    await editor.ready()
    editor.exportFolder = { folder }
    editor.openExport()
    settle(editor)
    let finished = AsyncStream<ExportEvent> { continuation in
        editor.onExport = { event in
            if case .started = event { return }
            continuation.yield(event)
            continuation.finish()
        }
    }
    editor.startExport()
    guard case .exporting = editor.state.export else { return check(false, "the export starts") }
    settle(editor)

    L10n.setPseudoLanguage(.ar, transform: pseudo)
    settle(editor)
    let loose = unwrapped(visibleTexts(editor.window!.contentView!))
    check(loose.isEmpty, "the export panel writes its progress in the new language while exporting", loose.prefix(6).joined(separator: "\n     "))
    check(editor.view(identifier: "video.export.progress")?.isHiddenOrHasHiddenAncestor == false && editor.view(identifier: "video.export.panel")?.isHiddenOrHasHiddenAncestor == false,
          "the export panel keeps showing its progress after the switch")
    L10n.setLanguage(.en)
    settle(editor)
    check((editor.view(identifier: "video.export.title") as? NSTextField)?.stringValue == "Exporting video", "the export panel is back in English while exporting")

    var result: ExportEvent?
    for await event in finished { result = event }
    if case .finished(let report)? = result {
        check(report.framesWritten == frames && FileManager.default.fileExists(atPath: report.url.path), "the export that was running through the language switches finishes with every frame", "\(report.framesWritten) of \(frames)")
    } else {
        check(false, "the export that was running through the language switches finishes with every frame", "\(String(describing: result))")
    }
    check(editor.state.export == .closed, "the export panel closes when the export ends")
}
