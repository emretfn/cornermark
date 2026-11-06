import AppKit
import CornermarkCore
import CornermarkDesign
@testable import CornermarkVideoEditor
@testable import CornermarkShell

/// Films the aspect ratio for review: the real editor of a harness world, rendered offscreen and driven by scripted clicks, menu
/// picks and typed field values, next to frames read back from exported files. No key events are sent. The pointer arrow, the
/// captions and the list of menu items are drawn by the harness, since an open menu is not drawn offscreen.
/// Run with `CORNERMARK_ASPECT_FILM=<folder> swift run HarnessShell`.
@MainActor
enum VideoAspectFilm {
    /// Where each exported file is copied, named for its shape, so it can be probed after the world is gone.
    private static var exports: URL?

    static func run(out: URL) async -> Bool {
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        exports = out
        var ok = true
        for (name, scene) in [("B3", b3), ("B4", b4), ("X4", x4)] as [(String, (Film, EditorStage) async throws -> Void)] {
            guard let film = Film(url: out.appendingPathComponent("\(name).mp4")) else { return false }
            do {
                let stage = try await EditorStage(film, frames: 240)
                stage.area = "display=1&x=0&y=0&width=1280&height=720"
                defer { stage.w.cleanup() }
                try await scene(film, stage)
            } catch { film.failures.append("\(error)") }
            let written = await film.finish()
            print("FILM \(name).mp4 frames=\(written) failures=\(film.failures)")
            ok = ok && written > 0 && film.failures.isEmpty
        }
        return ok
    }

    // MARK: Scenes

    static func b3(_ f: Film, _ s: EditorStage) async throws {
        f.title = "B3  Ratio menu: Auto, 1:1, 5:4, 4:3, 3:2, 16:9, 4:5, 3:4, 9:16, and Custom with a width and a height."
        guard let editor = try await s.openProject() else { throw FilmError.missing("the editor") }
        status(f, s, editor)
        await s.press(editor.view(identifier: "video.rail.background") as! NSButton, in: editor, note: "Background in the settings rail")
        await pickFill("video.background.gradient.3", f, s, editor, "A gradient, so the video's shape shows around the recording.")
        let items = menuItems(editor)
        menuList(f, s, editor, items: items, highlight: nil)
        f.hold(2.4, "The Ratio menu's items, read from the app's menu. Separators split Auto, wide and square, tall, and Custom.")
        for option in VideoAspect.presets.dropFirst() + [VideoAspect.auto] {
            await choose(option, f, s, editor, items: items, note: "\(option.title): the video grows around the padded recording to \(option.title).")
        }
        await choose(.custom(width: 1, height: 1), f, s, editor, items: items, note: "Custom: two numbers whose ratio is the shape, starting at the video's own size.")
        f.layers = { [unowned s, unowned editor] in s.layers(editor) }
        await type("1080", into: "video.background.aspect.width", f, s, editor)
        await type("1350", into: "video.background.aspect.height", f, s, editor)
        f.hold(2, "1080 x 1350 typed: the video is now 4:5. Only the shape counts; Export picks the size.")
        editor.undo()
        await s.settle(editor)
        f.hold(1.6, "Edit > Undo: the height goes back. Each typed number is one step.")
        editor.redo()
        await s.settle(editor)
        f.hold(1.2, "Edit > Redo.")
        await choose(.ratio(width: 9, height: 16), f, s, editor, items: items, note: "9:16.")
        f.layers = { [unowned s, unowned editor] in s.layers(editor) }
        await pickFill("video.background.none", f, s, editor, "None with 9:16: no background to fill the rest, so black bars do, and the panel says so.")
        f.dark = true
        f.refresh()
        f.hold(2.4, "The same in Dark appearance. The bars are part of the video, so they stay black.")
        f.dark = false
        f.refresh()
        await choose(.auto, f, s, editor, items: items, note: "Auto: back to the recording's own shape.")
    }

    static func b4(_ f: Film, _ s: EditorStage) async throws {
        f.title = "B4  On a tall ratio the recording shrinks inside the frame, and zoom, the pointer and playback keep working."
        guard let editor = try await s.openProject() else { throw FilmError.missing("the editor") }
        status(f, s, editor)
        await s.press(editor.view(identifier: "video.rail.background") as! NSButton, in: editor, note: "Background in the settings rail")
        await pickFill("video.background.gradient.1", f, s, editor, "A gradient at Auto: a 16:9 recording in a 16:9 video.")
        await playing(f, s, editor, seconds: 1.2, note: "Playing at Auto.")
        let items = menuItems(editor)
        await choose(.ratio(width: 9, height: 16), f, s, editor, items: items, note: "9:16: the video grows tall around the padded recording, which stays centred.")
        f.layers = { [unowned s, unowned editor] in s.layers(editor) }
        f.refresh()
        await playing(f, s, editor, seconds: 2.4, note: "Playing at 9:16: the picture and the pointer stay inside the recording's rounded frame.")
        await slide("video.background.padding", through: [64, 0, 140, 64], f, s, editor, "Padding")
        editor.seek(to: 0)
        guard let zoom = editor.addZoom(from: 1, to: 3.2) else { throw FilmError.missing("a zoom") }
        editor.setZoomScale(2, of: zoom.id)
        editor.selectZoom(nil)
        await s.settle(editor)
        f.hold(2, "A 200% zoom from 1.0 s to 3.2 s on the zoom lane, added by the harness as the lane's + would.")
        await playing(f, s, editor, seconds: 3.4, note: "Playing at 9:16 through the zoom: the camera moves inside the recording's frame, which stays put.")
        await s.press(editor.view(identifier: "video.export") as! NSButton, in: editor, note: "Export")
        await chooseResolution(.shortSide(1080), f, s, editor)
        f.hold(2.4, "At 1080 the video is 1080 x 1920: the recording is drawn smaller to fit the tall frame.")
        let file = try await export(f, s, editor)
        let facts = await fileFacts(file)
        f.status = { "export: \(facts?.width ?? 0) x \(facts?.height ?? 0), \(facts?.frames ?? 0) frames" }
        for t in [0.5, 2.2] {
            editor.seek(to: t)
            await s.settle(editor)
            let plan = ExportPlan(project: editor.state.project, settings: ExportSettings(resolution: .shortSide(1080)))
            let preview = previewFrame(editor, size: CGSize(width: plan.width, height: plan.height))
            let frame = await decodedFrame(file, at: t)
            let diff = preview.flatMap { a in frame.flatMap { PixelDifference(a, $0, edge: 4) } }
            f.results.append(("preview at \(t) s", preview, "the editor's preview layers, 9:16"))
            f.results.append(("file at \(t) s", frame, diff.map { "\(facts?.width ?? 0) x \(facts?.height ?? 0) vs preview: \($0)" } ?? "unreadable"))
            f.layers = { [unowned s, unowned editor] in s.layers(editor) + f.resultLayers() }
            f.refresh()
            let zoomed = frameState(editor.state.project, outputTime: t).crop.scale
            f.hold(3.2, String(format: "At %.1f s, zoom %.0f%%: the preview and the exported frame, pointer included. %@", t, zoomed * 100,
                               diff.map { String(format: "PSNR %.1f dB.", $0.psnr) } ?? ""))
        }
        f.dark = true
        f.refresh()
        f.hold(2, "The same in Dark appearance.")
    }

    static func x4(_ f: Film, _ s: EditorStage) async throws {
        f.title = "X4  Wide, square and tall videos: one recording exported at 16:9, 1:1 and 9:16, each at 1080, read back from the files."
        guard let editor = try await s.openProject() else { throw FilmError.missing("the editor") }
        status(f, s, editor)
        await s.press(editor.view(identifier: "video.rail.background") as! NSButton, in: editor, note: "Background in the settings rail")
        await pickFill("video.background.wallpaper.\(VideoBackground.wallpapers[1])", f, s, editor, "A wallpaper behind the recording.")
        let items = menuItems(editor)
        var files: [(String, URL)] = []
        for option in [VideoAspect.ratio(width: 16, height: 9), .ratio(width: 1, height: 1), .ratio(width: 9, height: 16)] {
            await choose(option, f, s, editor, items: items, note: "\(option.title).")
            f.layers = { [unowned s, unowned editor] in s.layers(editor) + f.resultLayers() }
            f.refresh()
            await s.press(editor.view(identifier: "video.export") as! NSButton, in: editor, note: "Export")
            await chooseResolution(.shortSide(1080), f, s, editor)
            let plan = ExportPlan(project: editor.state.project, settings: editor.state.exportSettings)
            f.hold(1.6, "\(option.title) at 1080: the panel will write \(plan.width) x \(plan.height).")
            let file = try await export(f, s, editor)
            files.append((option.title, file))
            await f.show(file, label: "\(option.title) at 1.0 s", at: 1.0)
            f.refresh()
            f.hold(2.6, "The \(option.title) file, read back: its size, rate and frame count come from the file.")
        }
        for (title, file) in files {
            let facts = await fileFacts(file)
            print("X4 \(title) \(facts.map { "\($0.width)x\($0.height) frames=\($0.frames) fps=\($0.fps)" } ?? "unreadable") file=\(file.lastPathComponent)")
        }
        f.dark = true
        f.refresh()
        f.hold(2, "Dark appearance: the exported pictures do not follow it.")
    }

    // MARK: Steps

    /// Play, the clock runs, then Pause: the transport's own button, pressed twice.
    private static func playing(_ f: Film, _ s: EditorStage, _ editor: VideoEditorWindowController, seconds: Double, note: String) async {
        guard let play = editor.view(identifier: "video.play") as? NSButton else { return f.failures.append("no play button") }
        await s.press(play, in: editor, note: "Play")
        await s.play(editor, seconds: seconds, note: note)
        await s.press(play, in: editor, note: "Pause")
    }

    private static func status(_ f: Film, _ s: EditorStage, _ editor: VideoEditorWindowController) {
        f.status = { [unowned editor] in
            let b = editor.state.project.edits.background, plan = ExportPlan(project: editor.state.project, settings: ExportSettings())
            let shape: String
            if case .custom(let w, let h) = b.aspect { shape = "custom \(w):\(h)" } else { shape = b.aspect.title }
            return "ratio=\(shape) fill=\(b.fill == .none ? "none" : "set") padding=\(Int(b.padding))  video=\(plan.width)x\(plan.height)"
        }
    }

    private static func menuItems(_ editor: VideoEditorWindowController) -> [NSMenuItem] {
        (editor.view(identifier: "video.background.aspect") as? NSPopUpButton)?.itemArray ?? []
    }

    /// The menu's real items drawn as a list beside the popup, the picked one marked, the way the open menu would read.
    private static func menuList(_ f: Film, _ s: EditorStage, _ editor: VideoEditorWindowController, items: [NSMenuItem], highlight: String?) {
        guard let popup = editor.view(identifier: "video.background.aspect") else { return }
        let r = frameInWindow(popup)
        let row: CGFloat = 20, size = CGSize(width: 150, height: CGFloat(items.count) * row + 28)
        let ctx = Pix.context(Int(size.width * 2), Int(size.height * 2))
        ctx.scaleBy(x: 2, y: 2)
        ctx.setFillColor(CGColor(gray: 0.1, alpha: 0.95))
        ctx.addPath(CGPath(roundedRect: CGRect(origin: .zero, size: size), cornerWidth: 8, cornerHeight: 8, transform: nil))
        ctx.fillPath()
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        let small: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 9), .foregroundColor: NSColor(white: 0.7, alpha: 1)]
        ("menu items, read from the app" as NSString).draw(at: CGPoint(x: 10, y: size.height - 16), withAttributes: small)
        for (i, item) in items.enumerated() {
            let y = size.height - 28 - CGFloat(i + 1) * row
            if item.isSeparatorItem {
                ctx.setFillColor(CGColor(gray: 1, alpha: 0.25))
                ctx.fill(CGRect(x: 10, y: y + row / 2, width: size.width - 20, height: 1))
                continue
            }
            let on = item.title == highlight
            if on {
                ctx.setFillColor(CGColor(srgbRed: 0.85, green: 0.88, blue: 0.3, alpha: 1))
                ctx.addPath(CGPath(roundedRect: CGRect(x: 6, y: y + 1, width: size.width - 12, height: row - 2), cornerWidth: 4, cornerHeight: 4, transform: nil))
                ctx.fillPath()
            }
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: on ? .semibold : .regular),
                                                        .foregroundColor: on ? NSColor.black : NSColor.white]
            (item.title as NSString).draw(at: CGPoint(x: 14, y: y + 3), withAttributes: attrs)
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let image = ctx.makeImage() else { return }
        let box = CGRect(x: s.origin.x + r.maxX + 12, y: max(8, s.origin.y + r.maxY - size.height + 40), width: size.width, height: size.height)
        f.layers = { [unowned s, unowned editor] in s.layers(editor) + [(image, box)] }
        f.refresh()
    }

    private static func choose(_ option: VideoAspect, _ f: Film, _ s: EditorStage, _ editor: VideoEditorWindowController, items: [NSMenuItem], note: String) async {
        guard let popup = editor.view(identifier: "video.background.aspect") as? NSPopUpButton else { return f.failures.append("no ratio menu") }
        f.glide(to: s.point(of: popup, in: editor), "Ratio", frames: 10)
        menuList(f, s, editor, items: items, highlight: option.title)
        f.hold(0.5, "Ratio: \(option.title)")
        pickAspect(option, in: editor)
        await s.settle(editor)
        menuList(f, s, editor, items: items, highlight: option.title)
        f.hold(1.6, note)
    }

    /// Puts the digits in one by one, the way they would be typed, then ends editing, which commits the number.
    private static func type(_ text: String, into id: String, _ f: Film, _ s: EditorStage, _ editor: VideoEditorWindowController) async {
        guard let field = editor.view(identifier: id) as? NSTextField else { return f.failures.append("no \(id)") }
        f.glide(to: s.point(of: field, in: editor), field.accessibilityLabel() ?? id, frames: 10)
        for i in 1...text.count {
            field.stringValue = String(text.prefix(i))
            f.refresh()
            f.hold(0.18, "\(field.accessibilityLabel() ?? id): \(field.stringValue)")
        }
        fire(field)
        await s.settle(editor)
        f.hold(1, "\(field.accessibilityLabel() ?? id) \(text)")
    }

    private static func pickFill(_ id: String, _ f: Film, _ s: EditorStage, _ editor: VideoEditorWindowController, _ note: String) async {
        guard let tile = editor.view(identifier: id) as? NSButton else { return f.failures.append("no \(id)") }
        editor.window?.contentView?.layoutSubtreeIfNeeded()
        if let clip = tile.enclosingScrollView?.contentView, !clip.bounds.contains(tile.convert(tile.bounds, to: clip)) {
            tile.scrollToVisible(tile.bounds.insetBy(dx: 0, dy: -DS.Space.s16))
            await s.settle(editor)
        }
        await s.press(tile, in: editor, note: tile.accessibilityLabel() ?? id)
        f.hold(1.6, note)
    }

    private static func chooseResolution(_ choice: ExportResolution, _ f: Film, _ s: EditorStage, _ editor: VideoEditorWindowController) async {
        guard let popup = editor.view(identifier: "video.export.resolution") as? NSPopUpButton,
              let index = ExportResolution.choices(for: editor.state.project).firstIndex(of: choice) else { return f.failures.append("no resolution \(choice)") }
        f.glide(to: s.point(of: popup, in: editor), "Resolution", frames: 10)
        popup.selectItem(at: index)
        fire(popup)
        await s.settle(editor)
        f.hold(1, "Resolution: \(popup.titleOfSelectedItem ?? "?")")
    }

    private static func export(_ f: Film, _ s: EditorStage, _ editor: VideoEditorWindowController) async throws -> URL {
        func exported() -> Set<URL> { Set(s.w.store.list().filter(\.ownsVideo).compactMap { $0.video?.file }) }
        let before = exported()
        await s.press(editor.view(identifier: "video.export.start") as! NSButton, in: editor, note: "Export")
        await VideoExportFilm.sample(f, s, editor, until: 1.01) { "Exporting: \(Int($0 * 100))%" }
        _ = await waitUntil(20) { !exported().subtracting(before).isEmpty }
        guard let file = exported().subtracting(before).first else { throw FilmError.missing("the export") }
        if let exports {
            let b = editor.state.project.edits.background
            let name = "\(f.title.prefix(2))-export-\(b.aspect.title.replacingOccurrences(of: ":", with: "x")).mp4"
            try? FileManager.default.copyItem(at: file, to: exports.appendingPathComponent(name))
        }
        await s.settle(editor)
        return file
    }

    private static func slide(_ id: String, through values: [Double], _ f: Film, _ s: EditorStage, _ editor: VideoEditorWindowController, _ name: String) async {
        guard let slider = editor.view(identifier: id) as? NSSlider else { return f.failures.append("no \(id)") }
        func knob(_ v: Double) -> CGPoint {
            let r = slider.convert(slider.bounds, to: nil), k = (v - slider.minValue) / (slider.maxValue - slider.minValue)
            return CGPoint(x: s.origin.x + r.minX + 7 + CGFloat(k) * (r.width - 14), y: s.origin.y + r.midY)
        }
        f.glide(to: knob(slider.doubleValue), name)
        for (a, b) in zip(values, values.dropFirst()) {
            for i in 1...20 {
                let t = Double(i) / 20, e = t * t * (3 - 2 * t)
                slider.doubleValue = a + (b - a) * e
                fire(slider)
                await s.settle(editor)
                f.glide(to: knob(slider.doubleValue), "\(name) \(Int(slider.doubleValue.rounded()))", frames: 1)
            }
            f.hold(0.5, "\(name) \(Int(b)): the recording shrinks or grows inside the tall video, still centred.")
        }
        (slider as? TrackingSlider)?.onTrackingEnd()
    }
}
