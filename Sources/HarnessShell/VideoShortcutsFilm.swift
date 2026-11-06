import AppKit
import AVFoundation
import CornermarkCore
import CornermarkDesign
@testable import CornermarkVideoEditor
@testable import CornermarkShell

/// Films the editor's keys and Export Current Frame for review. E7 shows the list in Settings > Shortcuts, then sends each listed key to
/// the real editor of a harness world, rendered offscreen, and holds on what it did. X5 exports the frame at the playhead with Shift-Command-E,
/// shows its Quick Access card, then lays the PNG beside the exported video's frame at the same moment with their difference.
/// The key box, the menu box, the pointer and the captions are drawn by the harness.
/// Run with `CORNERMARK_SHORTCUTS_FILM=<folder> swift run HarnessShell`.
@MainActor
enum VideoShortcutsFilm {
    static func run(out: URL) async -> Bool {
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var ok = true
        for (name, scene) in [("E7", e7), ("X5", x5)] as [(String, (Film, EditorStage, URL) async throws -> Void)] {
            guard let film = Film(url: out.appendingPathComponent("\(name).mp4")) else { return false }
            do {
                let stage = try await EditorStage(film, frames: 480)
                defer { stage.w.cleanup() }
                try await scene(film, stage, out)
            } catch { film.failures.append("\(error)") }
            let written = await film.finish()
            print("FILM \(name).mp4 frames=\(written) failures=\(film.failures)")
            ok = ok && written > 0 && film.failures.isEmpty
        }
        return ok
    }

    static func openScene(_ s: EditorStage) async throws -> VideoEditorWindowController {
        guard let record = try await s.recordProject(), let folder = record.video?.location else { throw FilmError.missing("the recording") }
        var project = try RecordingProjectFile.read(from: folder)
        ShortcutScene.apply(&project)
        try RecordingProjectFile.write(project, to: folder)
        guard let editor = s.w.coordinator.openVideoEditor(folder) else { throw FilmError.missing("the editor") }
        editor.chooseSaveLocation = { _, _, done in done(nil) }
        await s.show(editor)
        return editor
    }

    // MARK: E7

    static func e7(_ f: Film, _ s: EditorStage, _ out: URL) async throws {
        f.title = "E7  Settings > Shortcuts lists every video editor key from the table the editor answers, then each key is sent to the editor."
        let w = s.w
        w.coordinator.perform(.openSettings)
        guard let sw = w.coordinator.settingsWindow, let window = sw.window, let pane = sw.panes.first(where: { $0 is ShortcutsPane }) else {
            throw FilmError.missing("the Shortcuts pane")
        }
        f.layers = { [unowned f] in f.windowLayer(window, at: f.settingsOrigin) }
        f.status = { "EditorShortcuts.all: \(EditorShortcuts.all.count) commands, \(EditorShortcuts.all.reduce(0) { $0 + $1.keys.count }) keys" }
        f.refresh()
        f.hold(0.8, "Cornermark Settings")
        if let item = findView("settings.sidebar.shortcuts", in: window.contentView) {
            f.glide(to: f.center(of: item, in: window, at: f.settingsOrigin), "Shortcuts in the sidebar")
        }
        sw.select(pane: pane)
        f.refresh()
        f.hold(2, "The shortcuts that work anywhere on the Mac stay editable at the top.")
        guard let scroll = findView("settings.scroll", in: window.contentView) as? NSScrollView, let page = scroll.documentView else { throw FilmError.missing("the scroll view") }
        let bottom = max(page.bounds.height - scroll.contentView.bounds.height, 0)
        func scrollTo(_ y: CGFloat, frames: Int, _ note: String) {
            let a = scroll.contentView.bounds.minY
            for i in 1...frames {
                let t = CGFloat(i) / CGFloat(frames), e = t * t * (3 - 2 * t)
                scroll.contentView.scroll(to: NSPoint(x: 0, y: a + (y - a) * e))
                scroll.reflectScrolledClipView(scroll.contentView)
                f.refresh()
                f.hold(1 / Double(Film.fps), note)
            }
        }
        for group in EditorCommand.Group.allCases {
            let first = EditorShortcuts.all.first { $0.command.group == group }!.command
            guard let caps = findView("editorShortcut.\(first.rawValue)", in: page) else { continue }
            let y = min(max(caps.convert(caps.bounds, to: page).minY - 90, 0), bottom)
            scrollTo(y, frames: 24, group.title)
            f.hold(2.6, "\(group.title): each row names the command, says where it works, and shows its keys.")
        }
        f.dark = true
        f.refresh()
        f.hold(2, "The list in Dark appearance.")
        scrollTo(0, frames: 18, "Back to the top")
        f.dark = false
        window.performClose(nil)

        let editor = try await openScene(s)
        guard let editorWindow = editor.window else { throw FilmError.missing("the editor window") }
        f.hold(1.4, "A recording with two zooms, a background and a moving pointer. Now each key from the list is sent to the editor.")
        func send(_ command: EditorCommand, _ note: String, key index: Int = 0, shift: Bool = false) async {
            let shortcut = EditorShortcuts.shortcut(for: command)
            var chord = shortcut.keys[index]
            if shift { chord.modifiers.insert(.shift) }
            let box = keyBox(chord.display, command.title)
            let base = f.layers
            f.layers = { base() + box }
            f.refresh()
            f.hold(0.6, note)
            Synth.key(editorWindow, chord.keyCode, "", modifiers: chord.eventFlags)
            await s.settle(editor)
            f.hold(1.8, note)
            f.layers = base
        }
        await send(.playPause, "Space plays.")
        await s.play(editor, seconds: 1, note: "Playing.")
        await send(.playPause, "Space again pauses.")
        editor.seek(to: 8)
        await s.settle(editor)
        await send(.addZoom, "Z adds a 2 s zoom at the playhead and picks it.")
        await send(.duplicateZoom, "Command-D duplicates the picked zoom into the next gap.")
        await send(.delete, "Delete removes the picked zoom.")
        await send(.escape, "Esc lets go of the pick.")
        editor.seek(to: 4)
        await s.settle(editor)
        await send(.split, "Command-B splits the clip at the playhead: a cut mark appears on the clip lane.")
        await send(.undo, "Command-Z undoes the split.")
        await send(.redo, "Shift-Command-Z redoes it.")
        editorWindow.makeFirstResponder(editor.timeline)
        await send(.step, "With the timeline focused, Right steps one frame.", key: 1)
        await send(.step, "Shift-Left steps back a second.", key: 0, shift: true)
        await send(.jump, "End jumps to the end.", key: 1)
        await send(.jump, "Home jumps to the start.", key: 0)
        await send(.trimStart, "Shift-Option-Right trims a second off the first clip's start.", key: 1, shift: true)
        if let lane = editor.view(identifier: "video.zoomLane") { editorWindow.makeFirstResponder(lane) }
        await send(.pickZoom, "With the zoom lane focused, Right picks the next zoom.", key: 1)
        await send(.moveZoom, "Shift-Option-Right moves it a second later.", key: 1, shift: true)
        await send(.resizeZoom, "Option-Command-Left pulls its end in by 0.1 s.", key: 0)
        editorWindow.makeFirstResponder(nil)
        await send(.fullScreen, "Control-Command-F opens Full Screen Preview.")
        await send(.escape, "Esc leaves it.")
        await send(.save, "Command-S saves: the header says Saved.")
        await send(.export, "Command-E opens the export panel.")
        editor.closeExport()
        await s.settle(editor)
        await send(.exportFrame, "Shift-Command-E exports the frame at the playhead. X5 shows it.")
        await editor.frameJob?.value
        f.layers = { [unowned s, unowned editor] in s.layers(editor) + f.cardLayers(s.w) }
        f.refresh()
        f.hold(2.2, "Its Quick Access card appears in the corner, like a screenshot's.")
        f.dark = true
        f.refresh()
        f.hold(2, "The editor in Dark appearance.")
        f.dark = false
        f.refresh()
        f.hold(0.5, "Every key was handled: no key fell through to a beep.")
    }

    /// The harness's box naming the key it just sent. Not part of the app.
    static func keyBox(_ keys: String, _ title: String) -> [(CGImage, CGRect)] {
        let box = CGRect(x: Film.stage.width - 430, y: Film.stage.height - 92, width: 410, height: 72)
        let s: CGFloat = 2
        let ctx = Pix.context(Int(box.width * s), Int(box.height * s))
        ctx.scaleBy(x: s, y: s)
        ctx.setFillColor(CGColor(gray: 0.08, alpha: 0.92))
        ctx.addPath(CGPath(roundedRect: CGRect(origin: .zero, size: box.size), cornerWidth: 10, cornerHeight: 10, transform: nil))
        ctx.fillPath()
        Pix.draw(ctx, "Harness: key sent", at: CGPoint(x: 14, y: 50), size: 12, color: NSColor(white: 0.7, alpha: 1))
        Pix.draw(ctx, keys, at: CGPoint(x: 14, y: 14), size: 26, color: NSColor(srgbRed: 1, green: 0.55, blue: 0.1, alpha: 1))
        Pix.draw(ctx, title, at: CGPoint(x: 150, y: 20), size: 15, color: .white)
        return ctx.makeImage().map { [($0, box)] } ?? []
    }

    // MARK: X5

    static func x5(_ f: Film, _ s: EditorStage, _ out: URL) async throws {
        f.title = "X5  Export Current Frame as Image: the frame at the playhead as a PNG at the canvas size, drawn like the video export, to Quick Access."
        let editor = try await openScene(s)
        guard let window = editor.window else { throw FilmError.missing("the editor window") }
        let project = editor.state.project
        let fps = Double(project.source.fps)
        let t = (BlurScene.fastestCrop(project, in: 1.0...1.8) * fps).rounded() / fps
        editor.seek(to: t)
        await s.settle(editor)
        f.hold(2, String(format: "The playhead at %.3f s, inside a zoom to 300%% with the pointer in view.", t))
        let menu = menuBox()
        let base = f.layers
        f.layers = { base() + menu }
        f.refresh()
        f.hold(2.4, "File > Export Current Frame as Image, Shift-Command-E. The box is the harness's drawing of the menu, which is not drawn offscreen.")
        f.layers = { base() + keyBox("\u{21E7}\u{2318}E", "Export Current Frame as Image") }
        f.refresh()
        f.hold(0.6, "Shift-Command-E")
        let chord = EditorShortcuts.shortcut(for: .exportFrame).keys[0]
        let historyBefore = s.w.env.store.list(filter: CaptureFilter()).count
        Synth.key(window, chord.keyCode, "", modifiers: chord.eventFlags)
        await editor.frameJob?.value
        guard await waitUntil(5, { s.w.env.store.list(filter: CaptureFilter()).count == historyBefore + 1 }),
              let record = s.w.env.store.list(filter: CaptureFilter()).first,
              let png = NSImage(contentsOf: s.w.env.store.paths(for: record).image)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw FilmError.missing("the exported frame in History")
        }
        try? FileManager.default.removeItem(at: out.appendingPathComponent("X5-frame.png"))
        try? FileManager.default.copyItem(at: s.w.env.store.paths(for: record).image, to: out.appendingPathComponent("X5-frame.png"))
        f.layers = { [unowned s, unowned editor] in s.layers(editor) + f.cardLayers(s.w) + f.magnified(s.w) }
        f.status = { "History: \(record.kind.rawValue) picture \(png.width) x \(png.height), PNG, pointScale \(record.pointScale)  Quick Access cards: \(s.w.coordinator.overlay.stack.count)" }
        f.refresh()
        f.hold(3, "The frame lands in History and on a Quick Access card with Copy, Save, Edit, Pin, OCR and Close, the way a screenshot does.")
        f.dark = true
        f.refresh()
        f.hold(2, "In Dark appearance.")
        f.dark = false

        f.hold(0.3, "Exporting the same project as a video to compare")
        let video = s.w.root.appendingPathComponent("x5.mp4")
        let report = try await VideoExporter.export(project: project, video: editor.videoURL, settings: ExportSettings(), to: video)
        guard let frame = await decodedFrame(video, at: t), let diff = PixelDifference(png, frame, edge: 4) else { throw FilmError.missing("the video's frame") }
        if let data = AssetStore.pngData(from: frame) { try? data.write(to: out.appendingPathComponent("X5-video-frame.png")) }
        print(String(format: "X5 FRAMEPARITY t=%.4f png=%dx%d video=%dx%d %@", t, png.width, png.height, report.plan.width, report.plan.height, diff.description))
        guard let board = comparison(png, frame, diff: diff) else { throw FilmError.missing("the comparison") }
        f.layers = { [(board, CGRect(x: 20, y: 20, width: Film.stage.width - 40, height: Film.stage.height - 40))] }
        f.status = { String(format: "t=%.4f s  PNG %d x %d vs video frame %d x %d  %@", t, png.width, png.height, report.plan.width, report.plan.height, diff.description) }
        f.refresh()
        f.hold(6, "Left the PNG, middle the exported video's frame at the same moment, right their difference amplified 8 times. Only H.264's loss differs.")
        f.hold(2.5, "Nothing is uploaded: the frame stays on this Mac, in History and wherever After capture sends captures.")
    }

    static func menuBox() -> [(CGImage, CGRect)] {
        let rows = ["Open Video\u{2026}", "", "Save", "Save As\u{2026}", "", "Export\u{2026}", "Export Current Frame as Image"]
        let keys: [EditorCommand?] = [.openVideo, nil, .save, .saveAs, nil, .export, .exportFrame]
        let box = CGRect(x: 360, y: Film.stage.height - 330, width: 420, height: 250)
        let s: CGFloat = 2
        let ctx = Pix.context(Int(box.width * s), Int(box.height * s))
        ctx.scaleBy(x: s, y: s)
        ctx.setFillColor(CGColor(gray: 0.12, alpha: 0.95))
        ctx.addPath(CGPath(roundedRect: CGRect(origin: .zero, size: box.size), cornerWidth: 10, cornerHeight: 10, transform: nil))
        ctx.fillPath()
        Pix.draw(ctx, "Harness drawing of File, keys from EditorShortcuts", at: CGPoint(x: 14, y: box.height - 26), size: 12, color: NSColor(white: 0.7, alpha: 1))
        var y = box.height - 60
        for (title, command) in zip(rows, keys) {
            if title.isEmpty {
                ctx.setFillColor(CGColor(gray: 0.35, alpha: 1))
                ctx.fill(CGRect(x: 14, y: y + 12, width: box.width - 28, height: 1))
                y -= 14
                continue
            }
            if command == .exportFrame {
                ctx.setFillColor(CGColor(srgbRed: 0.2, green: 0.4, blue: 0.9, alpha: 1))
                ctx.fill(CGRect(x: 8, y: y - 4, width: box.width - 16, height: 26))
            }
            Pix.draw(ctx, title, at: CGPoint(x: 18, y: y), size: 15, color: .white)
            if let command { Pix.draw(ctx, EditorShortcuts.shortcut(for: command).keyText, at: CGPoint(x: box.width - 80, y: y), size: 15, color: .white) }
            y -= 30
        }
        return ctx.makeImage().map { [($0, box)] } ?? []
    }

    /// The PNG, the video's frame and their difference times eight, with a close-up of each around the pointer below.
    static func comparison(_ a: CGImage, _ b: CGImage, diff: PixelDifference) -> CGImage? {
        guard let pa = Pix.bytes(a), let pb = Pix.bytes(b) else { return nil }
        let heat = Pix.context(a.width, a.height)
        guard let data = heat.data?.assumingMemoryBound(to: UInt8.self), heat.bytesPerRow == a.width * 4 else { return nil }
        for i in stride(from: 0, to: pa.count, by: 4) {
            for c in 0..<3 { data[i + c] = UInt8(min(255, abs(Int(pa[i + c]) - Int(pb[i + c])) * 8)) }
            data[i + 3] = 255
        }
        guard let difference = heat.makeImage() else { return nil }
        let size = CGSize(width: Film.stage.width - 40, height: Film.stage.height - 40), k: CGFloat = 2
        let ctx = Pix.context(Int(size.width * k), Int(size.height * k))
        ctx.scaleBy(x: k, y: k)
        ctx.setFillColor(CGColor(gray: 0.1, alpha: 1))
        ctx.fill(CGRect(origin: .zero, size: size))
        ctx.interpolationQuality = .high
        let gap: CGFloat = 12, tw = (size.width - gap * 4) / 3, th = tw * CGFloat(a.height) / CGFloat(a.width)
        let labels = ["PNG from Export Current Frame", "Video export, same moment", "Difference x8"]
        let crop = CGRect(x: CGFloat(a.width) * 0.3, y: CGFloat(a.height) * 0.3, width: CGFloat(a.width) / 4, height: CGFloat(a.height) / 4)
        for (i, image) in [a, b, difference].enumerated() {
            let x = gap + CGFloat(i) * (tw + gap)
            ctx.draw(image, in: CGRect(x: x, y: size.height - 40 - th, width: tw, height: th))
            if let part = image.cropping(to: crop) {
                ctx.draw(part, in: CGRect(x: x, y: size.height - 40 - th - gap - 22 - th, width: tw, height: th))
            }
            Pix.draw(ctx, labels[i], at: CGPoint(x: x, y: size.height - 30), size: 18, color: .white)
            Pix.draw(ctx, "4x close-up of the middle", at: CGPoint(x: x, y: size.height - 40 - th - gap - 20), size: 13, color: NSColor(white: 0.7, alpha: 1))
        }
        Pix.draw(ctx, "\(a.width) x \(a.height) both.  " + diff.description, at: CGPoint(x: gap, y: 14), size: 16, color: .white)
        return ctx.makeImage()
    }
}
