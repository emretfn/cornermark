import AppKit
import CornermarkCore
import CornermarkDesign
@testable import CornermarkVideoEditor
@testable import CornermarkShell

/// Films the Background section for review: the real editor of a harness world, rendered offscreen and driven by scripted clicks
/// and slider moves, next to frames read back from an exported file. No key events are sent. The pointer arrow and the captions
/// are drawn by the harness. Run with `CORNERMARK_BACKGROUND_FILM=<folder> swift run HarnessShell`.
@MainActor
enum VideoBackgroundFilm {
    static func run(out: URL) async -> Bool {
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var ok = true
        for (name, scene) in [("B1", b1), ("B2", b2)] as [(String, (Film, EditorStage) async throws -> Void)] {
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

    static func b1(_ f: Film, _ s: EditorStage) async throws {
        f.title = "B1  Background: None, Gradients (Show more / Show less), Wallpapers with Add image, plain Colour."
        guard let editor = try await s.openProject() else { throw FilmError.missing("the editor") }
        status(f, s, editor)
        await s.press(editor.view(identifier: "video.rail.background") as! NSButton, in: editor, note: "Background in the settings rail")
        f.hold(2, "No background: the recording fills the video, as recorded.")
        for i in [0, 3, 6] { await pick("video.background.gradient.\(i)", f, s, editor, "\(BuiltinBackgrounds.all[i].name) gradient: the recording sits on it, framed.") }
        await s.press(editor.view(identifier: "video.background.more") as! NSButton, in: editor, note: "Show more")
        f.hold(1.6, "Show more: all \(BuiltinBackgrounds.all.count) gradients.")
        await pick("video.background.gradient.17", f, s, editor, "\(BuiltinBackgrounds.all[17].name) gradient, from the extra rows.")
        await s.press(editor.view(identifier: "video.background.more") as! NSButton, in: editor, note: "Show less")
        f.hold(1.4, "Show less folds them back.")
        for i in VideoBackground.wallpapers.prefix(3) {
            await pick("video.background.wallpaper.\(i)", f, s, editor, "\(BuiltinBackgrounds.background(at: i).name) wallpaper.")
        }
        let picture = s.w.root.appendingPathComponent("my-picture.png")
        try writeBackgroundPicture(to: picture)
        editor.chooseImage = { _, done in done(picture) }
        await pick("video.background.add", f, s, editor, "Add image: the file the viewer picks is copied into the project. The open panel is skipped by the harness.")
        f.hold(1, "The picture gets its own tile, picked.")
        await pick("video.background.color.0", f, s, editor, "White.")
        await pick("video.background.color.2", f, s, editor, "Graphite.")
        if let well = editor.view(identifier: "video.background.color.custom") as? NSColorWell {
            f.glide(to: s.point(of: well, in: editor), "Custom colour")
            well.color = NSColor(srgbRed: 0.18, green: 0.42, blue: 0.86, alpha: 1)
            fire(well)
            await s.settle(editor)
            f.hold(2, "Custom colour: a colour from the system colour panel. The harness sets it; the panel is not shown.")
        }
        await pick("video.background.image", f, s, editor, "Your picture again: it stays in the list after another fill.")
        await s.play(editor, seconds: 1.5, note: "Playing on the background.")
        f.dark = true
        f.refresh()
        f.hold(2, "The same in Dark appearance.")
        f.dark = false
        await pick("video.background.none", f, s, editor, "None: back to the recording alone.")
    }

    static func b2(_ f: Film, _ s: EditorStage) async throws {
        f.title = "B2  Padding, Shadow and Corners change the preview live. The export follows, at the size the padding gives."
        guard let editor = try await s.openProject() else { throw FilmError.missing("the editor") }
        status(f, s, editor)
        await s.press(editor.view(identifier: "video.rail.background") as! NSButton, in: editor, note: "Background in the settings rail")
        await pick("video.background.gradient.1", f, s, editor, "Ocean gradient. Padding 64, Shadow 50, Corners 12 to start.")
        await slide("video.background.padding", through: [64, 180, 0, 96], f, s, editor, "Padding")
        await slide("video.background.shadow", through: [50, 0, 100, 70], f, s, editor, "Shadow")
        await slide("video.background.corners", through: [12, 0, 64, 24], f, s, editor, "Corners")
        f.hold(1.4, "Every move redraws the preview through the painter export uses.")
        editor.undo()
        await s.settle(editor)
        f.hold(1.6, "Edit > Undo: the whole Corners drag goes back in one step.")
        editor.redo()
        await s.settle(editor)
        f.hold(1.2, "Edit > Redo.")
        f.dark = true
        f.refresh()
        f.hold(2, "The same settings in Dark appearance.")
        f.dark = false
        f.refresh()
        await s.press(editor.view(identifier: "video.export") as! NSButton, in: editor, note: "Export")
        let plan = ExportPlan(project: editor.state.project, settings: ExportSettings(), video: editor.videoURL)
        let source = editor.state.project.source
        f.hold(2.4, "The export panel offers \(plan.width) x \(plan.height): the recording's \(source.pixelWidth) x \(source.pixelHeight) plus the padding on each side.")
        await s.press(editor.view(identifier: "video.export.start") as! NSButton, in: editor, note: "Export")
        await VideoExportFilm.sample(f, s, editor, until: 1.01) { "Exporting: \(Int($0 * 100))%" }
        _ = await waitUntil(20) { s.w.store.list().contains(where: \.ownsVideo) }
        guard let file = s.w.store.list().first(where: \.ownsVideo)?.video?.file else { throw FilmError.missing("the export") }
        let facts = await fileFacts(file)
        f.status = { "export: \(facts?.width ?? 0) x \(facts?.height ?? 0), \(facts?.frames ?? 0) frames" }
        await f.show(file, label: "the exported file at 1.0 s", at: 1.0)
        f.layers = { [unowned s, unowned editor] in s.layers(editor) + f.resultLayers() }
        f.refresh()
        f.hold(3, "A frame read back from the file: the same padding, shadow and corners as the preview.")
    }

    // MARK: Steps

    private static func status(_ f: Film, _ s: EditorStage, _ editor: VideoEditorWindowController) {
        f.status = { [unowned editor] in
            let b = editor.state.project.edits.background, plan = ExportPlan(project: editor.state.project, settings: ExportSettings())
            return "fill=\(describe(b.fill)) padding=\(Int(b.padding)) shadow=\(Int(b.shadow)) corners=\(Int(b.cornerRadius))  video=\(plan.width)x\(plan.height)"
        }
    }

    private static func describe(_ fill: VideoBackground.Fill) -> String {
        switch fill {
        case .none: return "none"
        case .gradient(let i): return "gradient \(BuiltinBackgrounds.all[i].name)"
        case .wallpaper(let i): return "wallpaper \(BuiltinBackgrounds.all[i].name)"
        case .solid(let c): return String(format: "colour #%02X%02X%02X", Int(c.r * 255), Int(c.g * 255), Int(c.b * 255))
        case .image: return "image"
        }
    }

    private static func pick(_ id: String, _ f: Film, _ s: EditorStage, _ editor: VideoEditorWindowController, _ note: String) async {
        guard let tile = editor.view(identifier: id) as? NSButton else { return f.failures.append("no \(id)") }
        // The fills scroll under the fixed frame settings, so the tile is brought into view the way a viewer would scroll to it.
        editor.window?.contentView?.layoutSubtreeIfNeeded()
        if let clip = tile.enclosingScrollView?.contentView, !clip.bounds.contains(tile.convert(tile.bounds, to: clip)) {
            tile.scrollToVisible(tile.bounds.insetBy(dx: 0, dy: -DS.Space.s16))
            await s.settle(editor)
            f.hold(0.5, "Scrolling the fills")
        }
        await s.press(tile, in: editor, note: tile.accessibilityLabel() ?? id)
        f.hold(1.6, note)
    }

    /// Drags the knob through each value in turn, a film frame per step, the way a hand would.
    private static func slide(_ id: String, through values: [Double], _ f: Film, _ s: EditorStage, _ editor: VideoEditorWindowController, _ name: String) async {
        guard let slider = editor.view(identifier: id) as? NSSlider else { return f.failures.append("no \(id)") }
        func knob(_ v: Double) -> CGPoint {
            let r = slider.convert(slider.bounds, to: nil), k = (v - slider.minValue) / (slider.maxValue - slider.minValue)
            return CGPoint(x: s.origin.x + r.minX + 7 + CGFloat(k) * (r.width - 14), y: s.origin.y + r.midY)
        }
        f.glide(to: knob(slider.doubleValue), name)
        for (a, b) in zip(values, values.dropFirst()) {
            let steps = 24
            for i in 1...steps {
                let t = Double(i) / Double(steps), e = t * t * (3 - 2 * t)
                slider.doubleValue = a + (b - a) * e
                fire(slider)
                await s.settle(editor)
                f.glide(to: knob(slider.doubleValue), "\(name) \(Int(slider.doubleValue.rounded()))", frames: 1)
            }
            f.hold(0.6, "\(name) \(Int(b))")
        }
        (slider as? TrackingSlider)?.onTrackingEnd()
    }
}
