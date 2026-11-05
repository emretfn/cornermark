import AppKit
import AVFoundation
import CornermarkCore
import CornermarkDesign
@testable import CornermarkVideoEditor
@testable import CornermarkShell

/// Films the zoom lane for review: the real editor rendered offscreen frame by frame, driven by scripted pointer events sent to the
/// lane's own handlers and by the editor's own menu actions. A system menu is not drawn offscreen, so the film draws the real menu's
/// item titles in a box the harness labels as its own. The chart of the camera's scale is the harness's too.
/// Run with `CORNERMARK_ZOOM_FILM=<folder> swift run HarnessShell`.
@MainActor
enum VideoZoomFilm {
    static func run(out: URL) async -> Bool {
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var ok = true
        let scenes: [(String, (Film, EditorStage) async throws -> Void)] = [("Z1", z1), ("Z2", z2), ("Z3", z3), ("Z4", z4), ("Z6-Z7", z6), ("Z14", z14)]
        for (name, scene) in scenes {
            guard let film = Film(url: out.appendingPathComponent("\(name).mp4")) else { return false }
            do {
                let stage = try await EditorStage(film, frames: 480)
                defer { stage.w.cleanup() }
                try await scene(film, stage)
            } catch { film.failures.append("\(error)") }
            let frames = await film.finish()
            print("FILM \(name).mp4 frames=\(frames) failures=\(film.failures)")
            ok = ok && frames > 0 && film.failures.isEmpty
        }
        return ok
    }

    // MARK: Scenes

    static func z1(_ f: Film, _ s: EditorStage) async throws {
        f.title = "Z1  The zoom lane: hovering empty lane shows where a click adds a zoom. A click adds one, a drag adds one over the dragged stretch."
        let (editor, hand, x) = try await open(f, s)
        f.hold(1.5, "The zoom lane under the ruler is empty.")
        await hover(f, s, editor, hand, 1.2, "Hovering the lane: a dashed outline where a click would add a zoom, and \"\(ZoomLaneView.hint)\".")
        f.hold(2.4, "Hovering the lane: a dashed outline where a click would add a zoom, and \"\(ZoomLaneView.hint)\".")
        hand.click(x: hand.x(1.2))
        await s.settle(editor)
        f.hold(2.6, "Click: a 2 s zoom at 200%, picked. The panel switches to the zoom's settings.")
        await hover(f, s, editor, hand, 5.0, "Hovering further along")
        f.hold(1.2, "Hovering further along")
        await drag(f, s, editor, hand, from: hand.x(4.6), to: hand.x(7.4), "Dragging across the lane")
        f.hold(2.6, "Drag: a zoom over the dragged stretch, 4.6 s to 7.4 s, picked.")
        editor.seek(to: 2)
        await s.settle(editor)
        f.hold(2, "At 0:02 the preview is zoomed to 200%.")
        f.dark = true
        f.refresh()
        f.hold(2.5, "The same in Dark appearance.")
    }

    static func z2(_ f: Film, _ s: EditorStage) async throws {
        f.title = "Z2  Each zoom shows its level. Dragging an edge changes its length, dragging its body moves it."
        let (editor, hand, x) = try await open(f, s)
        editor.addZoom(from: 1, to: 3)
        if let b = editor.addZoom(from: 5.5, to: 7.5) { editor.setZoomScale(3, of: b.id) }
        editor.selectZoom(nil)
        await s.settle(editor)
        f.hold(2.2, "Two zooms, labelled with their levels: 200% and 300%.")
        let lane = hand.lane
        func zoom(_ i: Int) -> Zoom { editor.state.project.edits.zooms[i] }
        await drag(f, s, editor, hand, from: hand.edge(zoom(0), .end), to: hand.x(4.2), "Dragging the first zoom's end")
        f.hold(1.8, "Its end edge made it longer: 1.0 s to 4.2 s.")
        await drag(f, s, editor, hand, from: hand.edge(zoom(0), .start), to: hand.x(0.4), "Dragging its start")
        f.hold(1.8, "Its start edge made it start earlier: 0.4 s.")
        await drag(f, s, editor, hand, from: CGFloat(lane.rect(of: zoom(0)).midX), to: CGFloat(lane.rect(of: zoom(0)).midX) + CGFloat(0.8 * lane.scale.pointsPerSecond),
                   "Dragging its body")
        f.hold(1.8, "Its body moved it 0.8 s later, same length.")
        await drag(f, s, editor, hand, from: hand.edge(zoom(0), .end), to: hand.x(7), "Dragging its end into the next zoom")
        f.hold(2, "It stops at the next zoom: zooms never overlap.")
        Synth.key(editor.window!, 6, "z", modifiers: .command)
        await s.settle(editor)
        f.hold(1.6, "Command-Z undoes that drag in one step.")
        f.dark = true
        f.refresh()
        f.hold(2.5, "The same in Dark appearance.")
    }

    static func z3(_ f: Film, _ s: EditorStage) async throws {
        f.title = "Z3  A zoom's right-click menu: Level, Apply Level to All Zooms, Mode, Split at Playhead, Duplicate, Remove, Remove All Zooms."
        let (editor, hand, x) = try await open(f, s)
        editor.addZoom(from: 1, to: 4)
        if let b = editor.addZoom(from: 5, to: 6.5) { editor.setZoomScale(1.5, of: b.id) }
        editor.selectZoom(nil)
        await s.settle(editor)
        f.hold(1.4, "Two zooms.")
        let at = hand.x(2.2)
        func step(_ path: [String], _ note: String, x px: CGFloat) async {
            glide(f, s, hand, px, "Right click on the zoom")
            guard let menu = hand.menu(x: px) else { return f.failures.append("no menu") }
            x.overlay = menuImage(menu, open: path.count > 1 ? path[0] : nil, highlight: path.last)
            await s.settle(editor)
            f.hold(1.8, "Right click: the zoom's menu. Choosing \(path.joined(separator: " > ")).")
            if !path.isEmpty, !pick(menu, path) { f.failures.append("could not pick \(path)") }
            x.overlay = nil
            await s.settle(editor)
            f.hold(2, note)
        }
        await step(["Level", "300%"], "Level 300%: the zoom reads 300%.", x: at)
        await step(["Apply Level to All Zooms"], "Apply Level to All Zooms: both read 300%.", x: at)
        await step(["Mode", "Manual"], "Mode: Manual. The panel shows it too.", x: at)
        editor.seek(to: 2.5)
        await s.settle(editor)
        f.hold(1, "Playhead at 0:02.50")
        await step(["Split at Playhead"], "Split at Playhead: two zooms meet at 0:02.50, both 300%, Manual.", x: at)
        await step(["Duplicate"], "Duplicate: a copy of the same length in the first gap that holds it.", x: hand.x(1.5))
        await step(["Remove"], "Remove: that zoom is gone.", x: hand.x(3))
        await step(["Remove All Zooms"], "Remove All Zooms: the lane is empty.", x: hand.x(1.5))
        Synth.key(editor.window!, 6, "z", modifiers: .command)
        await s.settle(editor)
        f.hold(2, "Command-Z brings every zoom back.")
        f.dark = true
        f.refresh()
        f.hold(2.5, "The same in Dark appearance.")
    }

    static func z4(_ f: Film, _ s: EditorStage) async throws {
        f.title = "Z4  Zoom levels: 100%, 150%, 200%, 300% and 400% in the menu and the panel, and a slider for everything between."
        let (editor, hand, x) = try await open(f, s)
        editor.addZoom(from: 0.5, to: 7.5)
        editor.seek(to: 4)
        await s.settle(editor)
        f.hold(1.6, "A zoom picked, the playhead inside it.")
        glide(f, s, hand, hand.x(3), "Right click")
        if let menu = hand.menu(x: hand.x(3)) {
            x.overlay = menuImage(menu, open: "Level", highlight: "200%")
            await s.settle(editor)
            f.hold(2.6, "The menu's Level lists 100%, 150%, 200%, 300% and 400%, with the zoom's own checked.")
            x.overlay = nil
        }
        guard let presets = editor.view(identifier: "video.zoom.presets") as? NSSegmentedControl,
              let slider = editor.view(identifier: "video.zoom.level") as? NSSlider else { throw FilmError.missing("the zoom panel") }
        for (i, level) in Zoom.levels.enumerated() {
            f.glide(to: f.center(of: presets, in: editor.window!, at: s.origin, segment: i), "Preset \(Zoom.percent(level))", frames: 10)
            presets.selectedSegment = i
            fire(presets)
            await s.settle(editor)
            f.hold(1.4, "Preset \(Zoom.percent(level)): the zoom and the preview follow.")
        }
        f.glide(to: s.point(of: slider, in: editor), "The slider")
        for v in stride(from: 4.0, through: 1.25, by: -0.05) {
            slider.doubleValue = v
            fire(slider)
            await s.settle(editor)
            f.hold(0.05, "Slider: \(Zoom.percent(editor.state.project.edits.zooms[0].scale))")
        }
        f.hold(1.6, "The slider reaches any whole percent between 100% and 400%.")
        f.dark = true
        f.refresh()
        f.hold(2.5, "The same in Dark appearance.")
    }

    static func z6(_ f: Film, _ s: EditorStage) async throws {
        f.title = "Z6, Z7  The camera moves in over 0.68 s and out over 0.68 s on a smootherstep curve: symmetric, fastest halfway, back to exactly 100%."
        let (editor, _, x) = try await open(f, s)
        editor.addZoom(from: 1.5, to: 4.5)
        editor.selectZoom(nil)
        editor.seek(to: 0.8)
        x.chart = true
        await s.settle(editor)
        f.hold(1.6, "One zoom, 1.5 s to 4.5 s at 200%. The chart is the camera's scale over time, drawn by the harness from frameState.")
        await s.play(editor, seconds: 4.4, note: "Playing at the recording's speed.")
        f.hold(1, "Back at 100%.")
        f.status = { [unowned editor, unowned s] in s.cameraText(editor) }
        for (from, label) in [(1.5, "in"), (4.5 - ZoomCurve.duration, "out")] {
            for k in 0...41 {
                editor.seek(to: from + Double(k) / 60)
                await s.settle(editor)
                f.hold(0.12, "Frame by frame through the move \(label): \(k)/41 frames, slowed down eight times.")
            }
            f.hold(1, "The move \(label) took 41 frames at 60 fps, 0.68 s.")
        }
        f.dark = true
        f.refresh()
        f.hold(2, "The same in Dark appearance.")
    }

    static func z14(_ f: Film, _ s: EditorStage) async throws {
        f.title = "Z14  Two zooms less than 1.36 s apart: the camera goes from the first straight to the second, without pulling back to 100%."
        let (editor, _, x) = try await open(f, s)
        editor.addZoom(from: 1, to: 3)
        if let b = editor.addZoom(from: 3.8, to: 6.2) {
            editor.setZoomScale(3, of: b.id)
        }
        editor.selectZoom(nil)
        editor.seek(to: 0.5)
        x.chart = true
        await s.settle(editor)
        f.hold(2, "Zooms at 1.0-3.0 s (200%) and 3.8-6.2 s (300%), 0.8 s apart.")
        await s.play(editor, seconds: 6.3, note: "Playing: in to 200%, it holds across the gap, then on to 300% and out.")
        f.hold(1.6, "The camera never went back to 100% between the two.")
        let second = editor.state.project.edits.zooms[1].id
        let lane = ZoomLane(editor.state.project.edits.zooms, duration: editor.state.transport.duration)
        editor.removeZoom(second)
        if let moved = lane.zoom(second) {
            editor.addZoom(from: 5, to: 7.4)
            if let id = editor.state.selectedZoom { editor.setZoomScale(moved.scale, of: id) }
        }
        editor.selectZoom(nil)
        editor.seek(to: 0.5)
        await s.settle(editor)
        f.hold(2, "Moved the second zoom to 5.0 s: now 2.0 s apart, more than 1.36 s.")
        await s.play(editor, seconds: 7.1, note: "Playing: each zoom now returns to 100% on its own.")
        f.dark = true
        f.refresh()
        f.hold(2, "The same in Dark appearance.")
    }

    // MARK: Helpers

    /// What the harness draws over the editor: a menu's items and the camera chart.
    final class Extras {
        var overlay: CGImage?
        var chart = false
    }

    private static func open(_ f: Film, _ s: EditorStage) async throws -> (VideoEditorWindowController, ZoomHand, Extras) {
        guard let editor = try await s.openProject(), let lane = editor.view(identifier: "video.zoomLane") as? ZoomLaneView else {
            throw FilmError.missing("the editor")
        }
        let extras = Extras()
        f.status = { [unowned editor, unowned s] in s.cameraText(editor) }
        f.layers = { [unowned editor, unowned s, unowned lane] in
            var layers = s.layers(editor)
            if let menu = extras.overlay {
                let p = lane.convert(CGPoint(x: lane.bounds.midX, y: lane.bounds.maxY), to: nil)
                let size = CGSize(width: CGFloat(menu.width) / 2, height: CGFloat(menu.height) / 2)
                layers.append((menu, CGRect(x: min(s.origin.x + p.x - 120, Film.stage.width - size.width - 8), y: s.origin.y + p.y + 4, width: size.width, height: size.height)))
            }
            if extras.chart, let chart = s.chartImage(editor) {
                layers.append((chart, CGRect(x: s.origin.x + 8, y: s.origin.y + 330, width: 286, height: 150)))
            }
            return layers
        }
        f.refresh()
        return (editor, ZoomHand(lane: lane), extras)
    }

    static func point(_ s: EditorStage, _ hand: ZoomHand, _ x: CGFloat) -> CGPoint {
        let p = hand.lane.convert(CGPoint(x: x, y: hand.lane.bounds.midY), to: nil)
        return CGPoint(x: s.origin.x + p.x, y: s.origin.y + p.y)
    }

    private static func glide(_ f: Film, _ s: EditorStage, _ hand: ZoomHand, _ x: CGFloat, _ note: String) {
        f.glide(to: point(s, hand, x), note, frames: 12)
    }

    private static func hover(_ f: Film, _ s: EditorStage, _ editor: VideoEditorWindowController, _ hand: ZoomHand, _ t: Double, _ note: String) async {
        f.glide(to: point(s, hand, hand.x(t)), note, frames: 14)
        hand.hover(x: hand.x(t))
        await s.settle(editor)
    }

    private static func drag(_ f: Film, _ s: EditorStage, _ editor: VideoEditorWindowController, _ hand: ZoomHand, from a: CGFloat, to b: CGFloat, _ note: String) async {
        f.glide(to: point(s, hand, a), note, frames: 12)
        var i = 0
        await hand.drag(from: a, to: b, steps: 24) {
            i += 1
            await s.settle(editor)
            f.glide(to: point(s, hand, a + (b - a) * CGFloat(i) / 24), note, frames: 1)
        }
        await s.settle(editor)
    }

    private static func pick(_ menu: NSMenu, _ path: [String]) -> Bool {
        switch path.count {
        case 1: return menu.pick(path[0])
        case 2: return menu.pick(path[0], path[1])
        default: return false
        }
    }

    /// The real menu's items, drawn by the harness: AppKit draws a context menu in a system window that an offscreen film cannot see.
    static func menuImage(_ menu: NSMenu, open: String?, highlight: String?) -> CGImage? {
        let rowH: CGFloat = 22, width: CGFloat = 230, pad: CGFloat = 6
        func height(_ m: NSMenu) -> CGFloat { m.items.reduce(2 * pad) { $0 + ($1.isSeparatorItem ? 9 : rowH) } + 20 }
        let sub = open.flatMap { t in menu.items.first { $0.title == t }?.submenu }
        let size = CGSize(width: width * (sub == nil ? 1 : 2) + 8, height: max(height(menu), sub.map(height) ?? 0))
        let ctx = Pix.context(Int(size.width * 2), Int(size.height * 2))
        ctx.scaleBy(x: 2, y: 2)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: 1, y: -1)
        func draw(_ m: NSMenu, x: CGFloat, highlight: String?, open: String?) {
            let box = CGRect(x: x, y: 0, width: width, height: height(m))
            NSColor(white: 0.97, alpha: 0.98).setFill()
            NSBezierPath(roundedRect: box, xRadius: 8, yRadius: 8).fill()
            NSColor(white: 0.75, alpha: 1).setStroke()
            NSBezierPath(roundedRect: box.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8).stroke()
            var y = pad
            for item in m.items {
                if item.isSeparatorItem {
                    NSColor(white: 0.8, alpha: 1).setFill()
                    CGRect(x: x + 10, y: y + 4, width: width - 20, height: 1).fill()
                    y += 9
                    continue
                }
                let row = CGRect(x: x + 4, y: y, width: width - 8, height: rowH)
                let lit = item.title == highlight || item.title == open
                if lit {
                    NSColor(white: 0.22, alpha: 1).setFill()
                    NSBezierPath(roundedRect: row, xRadius: 5, yRadius: 5).fill()
                }
                let color = lit ? NSColor.white : (item.isEnabled ? NSColor.black : NSColor(white: 0.6, alpha: 1))
                let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.menuFont(ofSize: 13), .foregroundColor: color]
                (item.title as NSString).draw(at: CGPoint(x: row.minX + 20, y: row.minY + 3), withAttributes: attrs)
                if item.state == .on { ("\u{2713}" as NSString).draw(at: CGPoint(x: row.minX + 5, y: row.minY + 3), withAttributes: attrs) }
                if item.submenu != nil { ("\u{203A}" as NSString).draw(at: CGPoint(x: row.maxX - 14, y: row.minY + 2), withAttributes: attrs) }
                y += rowH
            }
            ("Harness drawing of the real menu's items" as NSString).draw(at: CGPoint(x: x + 10, y: box.maxY - 18),
                                                                           withAttributes: [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor(srgbRed: 0.85, green: 0.4, blue: 0.05, alpha: 1)])
        }
        draw(menu, x: 0, highlight: sub == nil ? highlight : nil, open: open)
        if let sub { draw(sub, x: width + 8, highlight: highlight, open: nil) }
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }
}

extension EditorStage {
    func cameraText(_ editor: VideoEditorWindowController) -> String {
        let st = editor.state
        let t = st.transport.time(at: clock.now)
        let cam = frameState(st.project, outputTime: t).camera
        let zooms = st.project.edits.zooms.map { String(format: "%.2f-%.2f %@ %@", $0.start, $0.end, Zoom.percent($0.scale), $0.mode.rawValue) }.joined(separator: ", ")
        let picked = st.selectedZoom.flatMap { id in st.project.edits.zooms.firstIndex { $0.id == id } }.map { "\($0 + 1)" } ?? "none"
        return String(format: "t=%@ camera scale=%.3f x=%.3f y=%.3f  picked=%@  zooms=[%@]", Timecode.text(t), cam.scale, cam.x, cam.y, picked, zooms)
    }

    /// The camera's scale from 0 to the end, with a dot at the playhead. Drawn by the harness from `frameState`, not part of the app.
    func chartImage(_ editor: VideoEditorWindowController) -> CGImage? {
        let size = CGSize(width: 286, height: 150)
        let ctx = Pix.context(Int(size.width * 2), Int(size.height * 2))
        ctx.scaleBy(x: 2, y: 2)
        ctx.setFillColor(CGColor(gray: 0.08, alpha: 0.88))
        ctx.addPath(CGPath(roundedRect: CGRect(origin: .zero, size: size), cornerWidth: 8, cornerHeight: 8, transform: nil))
        ctx.fillPath()
        let project = editor.state.project, d = editor.state.transport.duration
        let plot = CGRect(x: 30, y: 16, width: size.width - 42, height: size.height - 46)
        func y(_ scale: Double) -> CGFloat { plot.minY + CGFloat((scale - 1) / 3) * plot.height }
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.25))
        for s in [1.0, 2.0, 3.0, 4.0] { ctx.move(to: CGPoint(x: plot.minX, y: y(s))); ctx.addLine(to: CGPoint(x: plot.maxX, y: y(s))) }
        ctx.strokePath()
        ctx.setStrokeColor(CGColor(srgbRed: 1, green: 0.55, blue: 0.1, alpha: 1))
        ctx.setLineWidth(2)
        for i in 0...240 {
            let t = d * Double(i) / 240
            let p = CGPoint(x: plot.minX + plot.width * CGFloat(i) / 240, y: y(ZoomCamera.rect(project.edits.zooms, at: t).scale))
            i == 0 ? ctx.move(to: p) : ctx.addLine(to: p)
        }
        ctx.strokePath()
        let now = editor.state.transport.time(at: clock.now)
        let dot = CGPoint(x: plot.minX + plot.width * CGFloat(now / max(d, 1e-9)), y: y(frameState(project, outputTime: now).camera.scale))
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: dot.x - 4, y: dot.y - 4, width: 8, height: 8))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 9, weight: .regular), .foregroundColor: NSColor(white: 1, alpha: 0.8)]
        for s in [1.0, 2.0, 3.0, 4.0] { (Zoom.percent(s) as NSString).draw(at: CGPoint(x: 2, y: y(s) - 6), withAttributes: attrs) }
        ("Harness chart: camera scale from frameState" as NSString).draw(at: CGPoint(x: 10, y: size.height - 18),
                                                                       withAttributes: [.font: NSFont.systemFont(ofSize: 10, weight: .semibold), .foregroundColor: NSColor.white])
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }
}

/// Exports a project made around a given video with the zooms given, for measuring the curve on a file Cornermark wrote.
/// `CORNERMARK_ZOOM_CURVE=<folder holding screen.mp4> CORNERMARK_ZOOMS="1-4@2,5.6-8@3" swift run HarnessShell` writes `<folder>/zoomed.mp4`.
enum ZoomCurveExport {
    static func run(folder: URL, spec: String) async -> Bool {
        let video = folder.appendingPathComponent(RecordingProjectFile.videoName)
        let asset = AVURLAsset(url: video)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first, let size = try? await track.load(.naturalSize),
              let rate = try? await track.load(.nominalFrameRate), let duration = try? await asset.load(.duration).seconds else { return false }
        let zooms: [Zoom] = spec.split(separator: ",").compactMap { part in
            let bits = part.split(separator: "@"), range = bits.first?.split(separator: "-") ?? []
            guard bits.count == 2, range.count == 2, let a = Double(range[0]), let b = Double(range[1]), let s = Double(bits[1]) else { return nil }
            return Zoom(start: a, end: b, scale: s, center: ZoomPoint(x: 0.4, y: 0.45))
        }
        let source = RecordingProject.Source(pixelWidth: Int(size.width), pixelHeight: Int(size.height), pointWidth: size.width, pointHeight: size.height,
                                             fps: Int(rate.rounded()), duration: duration)
        let project = RecordingProject(source: source, edits: .init(zooms: zooms))
        let out = folder.appendingPathComponent("zoomed.mp4")
        try? FileManager.default.removeItem(at: out)
        do {
            let report = try await VideoExporter.export(project: project, video: video, settings: ExportSettings(), to: out)
            print(String(format: "ZOOM CURVE %@ frames=%d seconds=%.3f hardware=%@ zooms=%@", out.path, report.framesWritten, report.duration,
                         report.usesHardware ? "true" : "false", zooms.map { String(format: "%.2f-%.2f@%.2f", $0.start, $0.end, $0.scale) }.joined(separator: ",")))
            return true
        } catch {
            print("ZOOM CURVE failed \(error)")
            return false
        }
    }
}
