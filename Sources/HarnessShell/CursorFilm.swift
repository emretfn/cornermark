import AppKit
import CornermarkCore
@testable import CornermarkVideoEditor
@testable import CornermarkShell

/// Films the cursor settings for review: the real editor of a harness world, rendered offscreen and driven by scripted presses on its
/// own controls and keys sent to its window. The project is recorded from the fixture display, then given a scripted pointer track
/// with a shaking hand, rests, clicks and a typed word, so every setting has something to change. The pointer arrow, the caption strip and the
/// orange trails are drawn by the harness. Run with `CORNERMARK_CURSOR_FILM=<folder> swift run HarnessShell`.
@MainActor
enum CursorFilm {
    static var folder = URL(fileURLWithPath: NSTemporaryDirectory())

    static func run(out: URL) async -> Bool {
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        folder = out
        var ok = true
        let scenes: [(String, (Film, EditorStage, VideoEditorWindowController) async throws -> Void)] =
            [("C1", c1), ("C2", c2), ("C3", c3), ("C4", c4), ("C5", c5), ("C6", c6), ("C7", c7)]
        let only = ProcessInfo.processInfo.environment["CORNERMARK_CURSOR_SCENES"].map { Set($0.split(separator: ",").map(String.init)) }
        for (name, scene) in scenes where only?.contains(name) ?? true {
            guard let film = Film(url: out.appendingPathComponent("\(name).mp4")) else { return false }
            do {
                let stage = try await EditorStage(film, frames: 600)
                stage.area = "display=1&x=0&y=0&width=1280&height=720"
                defer { stage.w.cleanup() }
                guard let editor = try await openScripted(stage) else { throw FilmError.missing("the editor") }
                try await scene(film, stage, editor)
            } catch { film.failures.append("\(error)") }
            let written = await film.finish()
            print("FILM \(name).mp4 frames=\(written) failures=\(film.failures)")
            ok = ok && written > 0 && film.failures.isEmpty
        }
        return ok
    }

    // MARK: The scripted track

    static let clickTimes = [1.62, 2.6, 3.4, 3.55, 5.3, 6.05]

    /// Moves 0 to 1.6 s, rests until 4.6 s, moves until 6 s, rests while "types" is typed from 6.4 s, moves 8 to 9.4 s, then rests.
    static let keys = ["t", "y", "p", "e", "s"].enumerated().map { KeyEvent(t: 6.4 + 0.2 * Double($0.offset), label: $0.element, isCommand: false) }

    static func track(width w: Double, height h: Double) -> [PointerSample] {
        var seed: UInt64 = 0x2545F4914F6CDD1D
        func shake() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double(seed >> 33) / Double(1 << 31) - 1
        }
        let legs: [(t0: Double, t1: Double, a: (Double, Double), b: (Double, Double))] = [
            (0, 1.6, (0.15, 0.30), (0.45, 0.62)), (4.6, 6.0, (0.45, 0.62), (0.78, 0.30)), (8.0, 9.4, (0.78, 0.30), (0.28, 0.72)),
        ]
        var out: [PointerSample] = []
        for leg in legs {
            let n = Int((leg.t1 - leg.t0) * 120)
            for i in 0...n {
                let u = Double(i) / Double(n), e = u * u * (3 - 2 * u)
                let wobble = i == 0 || i == n ? 0 : 5.0
                out.append(PointerSample(t: leg.t0 + Double(i) / 120, x: w * (leg.a.0 + (leg.b.0 - leg.a.0) * e) + wobble * shake(),
                                         y: h * (leg.a.1 + (leg.b.1 - leg.a.1) * e) + wobble * shake()))
            }
        }
        out.append(PointerSample(t: 10, x: w * 0.28, y: h * 0.72))
        return out
    }

    static func openScripted(_ s: EditorStage) async throws -> VideoEditorWindowController? {
        guard let record = try await s.recordProject(), let folder = record.video?.location else { return nil }
        var project = try RecordingProjectFile.read(from: folder)
        project.events.pointer = track(width: project.source.pointWidth, height: project.source.pointHeight)
        project.events.keys = keys
        project.events.clicks = clickTimes.map { t in
            let at = PointerTrack.position(project.events.pointer, at: t) ?? (0, 0)
            return ClickEvent(t: t, x: at.x, y: at.y)
        }
        try RecordingProjectFile.write(project, to: folder)
        guard let editor = s.w.coordinator.openVideoEditor(folder) else { return nil }
        await s.show(editor)
        s.film.status = { [unowned s, unowned editor] in status(s, editor) }
        return editor
    }

    static func status(_ s: EditorStage, _ editor: VideoEditorWindowController) -> String {
        let t = editor.state.transport.time(at: s.clock.now)
        let c = editor.state.project.edits.cursor
        let drawn = editor.previewState?.cursor
        let typed = keys.filter { $0.t <= t }.map(\.label).joined()
        return String(format: "t=%@  cursor: visible=%@ scale=%.1f style=%@ motion=%@ hideIdle=%@ hideTyping=%@  drawn: %@  typed: \"%@\"  undo=%@",
                      Timecode.text(t), "\(c.isVisible)", c.scale, c.style.rawValue, c.motion.rawValue, "\(c.hidesWhenIdle)", "\(c.hidesWhenTyping)",
                      drawn.map { String(format: "x=%.1f y=%.1f opacity=%.2f", $0.x, $0.y, $0.opacity) } ?? "none", typed, "\(editor.canUndo)")
    }

    // MARK: Driving

    static func choose(_ f: Film, _ s: EditorStage, _ editor: VideoEditorWindowController, _ id: String, _ index: Int, note: String) async {
        guard let control = editor.view(identifier: id) as? NSSegmentedControl, let window = editor.window else { return f.failures.append("no \(id)") }
        f.glide(to: f.center(of: control, in: window, at: s.origin, segment: index), note, frames: 12)
        control.selectedSegment = index
        fire(control)
        await s.settle(editor)
        f.hold(0.2, note)
    }

    static func button(_ editor: VideoEditorWindowController, _ id: String) throws -> NSButton {
        guard let b = editor.view(identifier: id) as? NSButton else { throw FilmError.missing(id) }
        return b
    }

    static func seek(_ s: EditorStage, _ editor: VideoEditorWindowController, to t: Double) async {
        editor.seek(to: t)
        await s.settle(editor)
    }

    /// Plays on the scripted clock at `speed` times the recording's own.
    static func play(_ f: Film, _ s: EditorStage, _ editor: VideoEditorWindowController, from: Double, to: Double, speed: Double = 1, note: String) async {
        await seek(s, editor, to: from)
        let steps = Int((to - from) / speed * Double(Film.fps))
        for i in 1...max(steps, 1) {
            editor.seek(to: from + (to - from) * Double(i) / Double(max(steps, 1)))
            await s.settle(editor)
            f.hold(1 / Double(Film.fps), note)
        }
    }

    // MARK: Trails

    /// Where `project` puts the pointer over the last `span` seconds, as a line over the preview. Drawn by the harness, not the app.
    static func trail(_ s: EditorStage, _ editor: VideoEditorWindowController, projects: [(RecordingProject, CGColor, CGFloat)], span: Double = 0.9) -> [(CGImage, CGRect)] {
        guard let preview = editor.view(identifier: "video.preview") as? PreviewView else { return [] }
        let r = preview.convert(preview.pictureRect, to: nil)
        let source = editor.state.project.source
        guard r.width > 0, source.pointWidth > 0, source.pointHeight > 0 else { return [] }
        let ctx = Pix.context(Int(r.width * 2), Int(r.height * 2))
        ctx.scaleBy(x: 2, y: 2)
        let now = editor.state.transport.time(at: s.clock.now)
        for (project, color, width) in projects {
            let points = stride(from: max(0, now - span), through: now, by: 1.0 / 120).compactMap { t -> CGPoint? in
                guard let c = frameState(project, outputTime: t).cursor ?? frameState(visible(project), outputTime: t).cursor else { return nil }
                return CGPoint(x: c.x / source.pointWidth * r.width, y: r.height - c.y / source.pointHeight * r.height)
            }
            guard points.count > 1 else { continue }
            ctx.setStrokeColor(color)
            ctx.setLineWidth(width)
            ctx.setLineJoin(.round)
            ctx.addLines(between: points)
            ctx.strokePath()
        }
        guard let image = ctx.makeImage() else { return [] }
        return [(image, r.offsetBy(dx: s.origin.x, dy: s.origin.y))]
    }

    static func visible(_ project: RecordingProject) -> RecordingProject {
        var p = project
        p.edits.cursor.isVisible = true
        p.edits.cursor.hidesWhenIdle = false
        p.edits.cursor.hidesWhenTyping = false
        return p
    }

    static let orange = CGColor(srgbRed: 1, green: 0.55, blue: 0.1, alpha: 1)
    static let cyan = CGColor(srgbRed: 0.2, green: 0.85, blue: 1, alpha: 0.9)

    // MARK: Scenes

    static func c1(_ f: Film, _ s: EditorStage, _ editor: VideoEditorWindowController) async throws {
        f.title = "C1  Show cursor: the pointer is a layer drawn from the project's track, so it can be turned off and on after recording."
        let show = try button(editor, "video.cursor.show")
        f.hold(1.4, "The Cursor panel. Show cursor is on.")
        await play(f, s, editor, from: 0, to: 1.6, note: "Playing: the pointer moves across the recording.")
        await s.press(show, in: editor, note: "Show cursor: off")
        f.hold(1, "Off. The other cursor settings turn off with it.")
        await play(f, s, editor, from: 4.4, to: 6.0, note: "Playing with Show cursor off: no pointer. The recorded picture never had one.")
        await s.press(show, in: editor, note: "Show cursor: on")
        f.hold(1.4, "On again: the pointer is back where the track puts it.")
        Synth.key(editor.window!, 6, "z", modifiers: .command)
        await s.settle(editor)
        f.hold(1.6, "Command-Z: Show cursor is off again.")
        Synth.key(editor.window!, 6, "Z", modifiers: [.command, .shift])
        await s.settle(editor)
        f.hold(1.6, "Shift-Command-Z: on.")
        f.dark = true
        f.refresh()
        f.hold(2, "The same in Dark appearance.")
        await s.press(show, in: editor, note: "Show cursor: off")
        editor.window?.close()
        let stored = try RecordingProjectFile.read(from: editor.folder)
        f.layers = { [] }
        f.status = { "project.json after closing: cursor.isVisible=\(stored.edits.cursor.isVisible)" }
        f.refresh()
        f.hold(2.2, "Closing writes the choice to project.json.")
    }

    static func c2(_ f: Film, _ s: EditorStage, _ editor: VideoEditorWindowController) async throws {
        f.title = "C2  Size: the slider scales the pointer in the preview as it moves, from 0.5x to 4x. One drag is one undo step."
        guard let size = editor.view(identifier: "video.cursor.size") as? NSSlider else { throw FilmError.missing("Size") }
        await seek(s, editor, to: 0.9)
        f.hold(1.2, "Paused while the pointer crosses the picture. Size 1.0x.")
        f.glide(to: s.point(of: size, in: editor), "Size")
        for v in stride(from: 1.0, through: 3.0, by: 0.1) {
            size.doubleValue = v
            fire(size)
            await s.settle(editor)
            f.hold(0.07, String(format: "Size: %.1fx", v))
        }
        f.hold(1.6, "3.0x: three times the pointer's size, read out next to the slider.")
        await play(f, s, editor, from: 4.6, to: 6.0, note: "Playing at 3.0x.")
        Synth.key(editor.window!, 6, "z", modifiers: .command)
        await s.settle(editor)
        f.hold(1.8, "Command-Z: the whole drag is undone in one step, back to 1.0x.")
        Synth.key(editor.window!, 6, "Z", modifiers: [.command, .shift])
        await s.settle(editor)
        f.hold(1.4, "Shift-Command-Z: 3.0x again.")
        for v in stride(from: 3.0, through: 1.5, by: -0.1) {
            size.doubleValue = v
            fire(size)
            await s.settle(editor)
            f.hold(0.06, String(format: "Size: %.1fx", v))
        }
        f.hold(1.2, "1.5x")
        f.dark = true
        f.refresh()
        f.hold(2, "The same in Dark appearance.")
    }

    static func c3(_ f: Film, _ s: EditorStage, _ editor: VideoEditorWindowController) async throws {
        f.title = "C3  Style: a white arrow, a black arrow, or a translucent dot centred on the pointer's spot. Preview and export draw the same three."
        guard let size = editor.view(identifier: "video.cursor.size") as? NSSlider else { throw FilmError.missing("Size") }
        size.doubleValue = 2
        fire(size)
        await seek(s, editor, to: 6.0)
        f.hold(1.4, "Size 2.0x so the shapes read. Style: White.")
        await choose(f, s, editor, "video.cursor.style", 1, note: "Style: Black")
        f.hold(1.8, "Black: a dark arrow with a light edge.")
        await choose(f, s, editor, "video.cursor.style", 2, note: "Style: Dot")
        f.hold(2.2, "Dot: a translucent round dot. The picture shows through it.")
        await play(f, s, editor, from: 8.0, to: 9.6, note: "Playing with the dot.")
        await choose(f, s, editor, "video.cursor.style", 0, note: "Style: White")
        f.hold(1.4, "White again.")
        Synth.key(editor.window!, 6, "z", modifiers: .command)
        await s.settle(editor)
        f.hold(1.6, "Command-Z: back to the dot.")
        f.dark = true
        f.refresh()
        f.hold(2, "The same in Dark appearance. The pointer is content, so it does not change with the appearance.")
    }

    static func c4(_ f: Film, _ s: EditorStage, _ editor: VideoEditorWindowController) async throws {
        f.title = "C4  Motion: Natural draws the path as recorded, shake included. Smooth steadies it. Orange: the last 0.9 s of the drawn pointer (harness)."
        f.layers = { [unowned s, unowned editor] in
            s.layers(editor) + trail(s, editor, projects: [(editor.state.project, orange, 2.5)])
        }
        f.refresh()
        f.hold(1.4, "Motion: Natural. The scripted hand shakes by a few points.")
        await play(f, s, editor, from: 0, to: 1.9, note: "Natural: the drawn path keeps every wobble of the hand.")
        await play(f, s, editor, from: 4.5, to: 6.3, note: "Natural")
        await choose(f, s, editor, "video.cursor.motion", 1, note: "Motion: Smooth")
        f.hold(1, "Smooth")
        await play(f, s, editor, from: 0, to: 1.9, note: "Smooth: the same track, steadied. It trails the hand a little and lands on the stop.")
        await play(f, s, editor, from: 4.5, to: 6.3, note: "Smooth")
        await choose(f, s, editor, "video.cursor.motion", 0, note: "Motion: Natural")
        await seek(s, editor, to: 5.4)
        f.hold(1.4, "Natural, paused mid-move.")
        await choose(f, s, editor, "video.cursor.motion", 1, note: "Motion: Smooth")
        f.hold(1.6, "Smooth, same moment: the preview redraws through the spring without playing.")
        f.dark = true
        f.refresh()
        f.hold(2, "The same in Dark appearance.")
    }

    static func c5(_ f: Film, _ s: EditorStage, _ editor: VideoEditorWindowController) async throws {
        f.title = String(format: "C5  Smooth is a critically damped spring, %.0f rad/s: lag 2/w = %.2f s on a steady move, no overshoot at a stop. Own choice: no source.",
                         CursorTrack.springRate, 2 / CursorTrack.springRate)
        await choose(f, s, editor, "video.cursor.motion", 1, note: "Motion: Smooth")
        var natural = editor.state.project
        natural.edits.cursor.motion = .natural
        f.layers = { [unowned s, unowned editor] in
            s.layers(editor) + trail(s, editor, projects: [(natural, cyan, 1.5), (editor.state.project, orange, 3)], span: 1.4)
        }
        let p = editor.state.project
        let stop = (x: track(width: p.source.pointWidth, height: p.source.pointHeight).last { $0.t <= 6.0 }!.x, t: 6.0)
        let past = stride(from: 4.6, through: 7.5, by: 1.0 / 240).compactMap { frameState(p, outputTime: $0).cursor?.x }.max() ?? 0
        let after = stride(from: 0.1, through: 0.5, by: 0.1).map { abs((frameState(p, outputTime: stop.t + $0).cursor?.x ?? 0) - stop.x) }
        print(String(format: "C5 stop x=%.2f furthest smoothed x=%.2f distance after the stop at 0.1..0.5 s: %@", stop.x, past,
                     after.map { String(format: "%.2f", $0) }.joined(separator: " ")))
        f.status = { [unowned s, unowned editor] in
            status(s, editor) + String(format: "  stop x=%.1f, furthest smoothed x=%.1f", stop.x, past)
        }
        f.refresh()
        f.hold(1.6, "Cyan: the recorded path. Orange: the smoothed pointer. Both drawn by the harness.")
        await play(f, s, editor, from: 4.4, to: 6.8, speed: 0.25, note: "A quarter of real speed: the spring irons out the shake and closes in on the stop without passing it.")
        f.hold(2, String(format: "Distance left to the stop 0.1 s after it: %.1f pt, 0.3 s: %.2f pt, 0.5 s: %.3f pt.", after[0], after[2], after[4]))
        await play(f, s, editor, from: 7.8, to: 9.8, note: "Real speed.")
        f.dark = true
        f.refresh()
        f.hold(2, "The same in Dark appearance.")
    }

    static func clickStatus(_ s: EditorStage, _ editor: VideoEditorWindowController) -> String {
        let t = editor.state.transport.time(at: s.clock.now)
        let k = editor.state.project.edits.clicks, c = editor.state.project.edits.cursor
        let state = editor.previewState
        let rings = state?.input.rings.map { String(format: "r=%.1f a=%.2f", $0.radius, $0.opacity) }.joined(separator: " ") ?? ""
        return String(format: "t=%@  press=%@ ripple=%@ color=%@ size=%@ style=%@ motion=%@  cursor: visible=%@ motion=%@  drawn: scale=%@ rings=[%@]  undo=%@",
                      Timecode.text(t), "\(c.pressesOnClick)", "\(k.isVisible)", k.color.rawValue, k.size.rawValue, k.style.rawValue, k.animates ? "grow" : "still",
                      "\(c.isVisible)", c.motion.rawValue, state?.cursor.map { String(format: "%.2f", $0.scale) } ?? "none", rings, "\(editor.canUndo)")
    }

    static func clickPoints(_ s: EditorStage, _ editor: VideoEditorWindowController) -> [(CGImage, CGRect)] {
        guard let preview = editor.view(identifier: "video.preview") as? PreviewView else { return [] }
        let r = preview.convert(preview.pictureRect, to: nil)
        let p = editor.state.project
        guard r.width > 0, p.source.pointWidth > 0 else { return [] }
        let now = editor.state.transport.time(at: s.clock.now)
        let live = p.events.clicks.filter { now >= $0.t && now - $0.t < ClickHighlight.lifetime }
        guard !live.isEmpty else { return [] }
        let ctx = Pix.context(Int(r.width * 2), Int(r.height * 2))
        ctx.scaleBy(x: 2, y: 2)
        ctx.setStrokeColor(cyan)
        ctx.setLineWidth(2)
        for c in live {
            let x = c.x / p.source.pointWidth * r.width, y = r.height - c.y / p.source.pointHeight * r.height
            ctx.move(to: CGPoint(x: x - 7, y: y)); ctx.addLine(to: CGPoint(x: x + 7, y: y))
            ctx.move(to: CGPoint(x: x, y: y - 7)); ctx.addLine(to: CGPoint(x: x, y: y + 7))
        }
        ctx.strokePath()
        guard let image = ctx.makeImage() else { return [] }
        return [(image, r.offsetBy(dx: s.origin.x, dy: s.origin.y))]
    }

    static func pick(_ f: Film, _ s: EditorStage, _ editor: VideoEditorWindowController, color index: Int, note: String) async {
        guard let popup = editor.view(identifier: "video.clicks.color") as? NSPopUpButton else { return f.failures.append("no color menu") }
        f.glide(to: s.point(of: popup, in: editor), note, frames: 12)
        popup.selectItem(at: index)
        fire(popup)
        await s.settle(editor)
        f.hold(0.2, note)
    }

    static func c6(_ f: Film, _ s: EditorStage, _ editor: VideoEditorWindowController) async throws {
        f.title = String(format: "C6  Clicks: the press effect shrinks the pointer for %.2f s at each click, and the ripple draws a ring that grows and fades in %.1f s. Preview and export draw both.",
                         CursorTrack.pressLength, ClickHighlight.lifetime)
        f.status = { [unowned s, unowned editor] in clickStatus(s, editor) }
        await seek(s, editor, to: 1.2)
        await s.press(try button(editor, "video.rail.clicks"), in: editor, note: "Clicks")
        f.hold(1.8, "The Clicks section. Both effects start as the recording's settings had them: off. The ring's look is off with Ripple.")
        await s.press(try button(editor, "video.clicks.ripple"), in: editor, note: "Ripple: on")
        f.hold(1, "Ripple: on. Color, Size, Style and Motion turn on with it.")
        await play(f, s, editor, from: 1.2, to: 4.0, note: "Playing: a ring at each click, at rest and for both halves of a double click.")
        await play(f, s, editor, from: 2.5, to: 3.1, speed: 0.2, note: String(format: "A fifth of real speed: the ring grows from 60%% of its size and fades out by %.1f s.", ClickHighlight.lifetime))
        await seek(s, editor, to: 2.75)
        f.hold(1.6, "Paused 0.15 s after a click: the preview redraws the ring at that moment without playing.")
        await pick(f, s, editor, color: 2, note: "Color: Orange")
        await choose(f, s, editor, "video.clicks.size", 2, note: "Size: Large")
        await choose(f, s, editor, "video.clicks.style", 1, note: "Style: Filled")
        f.hold(1.4, "Orange, large, filled. The swatches are the ring's own colors.")
        await choose(f, s, editor, "video.clicks.motion", 1, note: "Motion: Still")
        await play(f, s, editor, from: 2.5, to: 3.1, speed: 0.25, note: "Still: the ring shows at full size, then goes.")
        await choose(f, s, editor, "video.clicks.motion", 0, note: "Motion: Grow")

        await s.press(try button(editor, "video.rail.cursor"), in: editor, note: "Cursor")
        guard let size = editor.view(identifier: "video.cursor.size") as? NSSlider else { throw FilmError.missing("Size") }
        f.glide(to: s.point(of: size, in: editor), "Size")
        for v in stride(from: 1.0, through: 3.0, by: 0.2) {
            size.doubleValue = v
            fire(size)
            await s.settle(editor)
            f.hold(0.05, String(format: "Size: %.1fx so the press reads", v))
        }
        await s.press(try button(editor, "video.rail.clicks"), in: editor, note: "Clicks")
        await s.press(try button(editor, "video.clicks.press"), in: editor, note: "Press effect: on")
        f.hold(1, "Press effect: on")
        await play(f, s, editor, from: 2.45, to: 2.95, speed: 0.1, note: String(format: "A tenth of real speed: the pointer drops to %.0f%% in %.2f s and grows back in %.2f s, inside the ring.",
                                                                               CursorTrack.pressDepth * 100, CursorTrack.pressDown, CursorTrack.pressRelease))
        await seek(s, editor, to: 2.6 + CursorTrack.pressDown)
        f.hold(1.6, "Paused at the bottom of the press.")
        await play(f, s, editor, from: 3.3, to: 3.9, speed: 0.25, note: "A double click presses twice.")
        await play(f, s, editor, from: 1.2, to: 4.0, note: "Both effects at real speed.")

        await s.press(try button(editor, "video.rail.cursor"), in: editor, note: "Cursor")
        await choose(f, s, editor, "video.cursor.motion", 1, note: "Motion: Smooth")
        await s.press(try button(editor, "video.rail.clicks"), in: editor, note: "Clicks")
        f.layers = { [unowned s, unowned editor] in s.layers(editor) + clickPoints(s, editor) }
        await play(f, s, editor, from: 1.45, to: 2.1, speed: 0.15, note: "Smooth: the pointer is still landing at the click. The ring sits on the drawn pointer. Cyan cross: the recorded click point (harness).")
        await play(f, s, editor, from: 5.9, to: 6.5, speed: 0.15, note: "The same after the second stop.")
        f.layers = { [unowned s, unowned editor] in s.layers(editor) }
        f.refresh()

        await s.press(try button(editor, "video.rail.cursor"), in: editor, note: "Cursor")
        await s.press(try button(editor, "video.cursor.show"), in: editor, note: "Show cursor: off")
        await s.press(try button(editor, "video.rail.clicks"), in: editor, note: "Clicks")
        f.hold(1.8, "With Show cursor off the press effect is off and says why. Ripple stays.")
        await play(f, s, editor, from: 2.4, to: 3.9, note: "No pointer: the rings still mark each click on the recording.")
        Synth.key(editor.window!, 6, "z", modifiers: .command)
        await s.settle(editor)
        f.hold(1.6, "Command-Z: the cursor is back.")
        Synth.key(editor.window!, 6, "z", modifiers: .command)
        await s.settle(editor)
        f.hold(1.6, "Command-Z: Motion is Natural again.")
        Synth.key(editor.window!, 6, "Z", modifiers: [.command, .shift])
        await s.settle(editor)
        f.hold(1.4, "Shift-Command-Z: Smooth.")
        f.dark = true
        f.refresh()
        await play(f, s, editor, from: 2.4, to: 3.0, speed: 0.25, note: "The same in Dark appearance. The rings are content, so they keep their colors.")
        f.dark = false
        f.refresh()

        let out = folder.appendingPathComponent("C6-export.mp4")
        f.hold(0.8, "Exporting the project")
        let report = try await VideoExporter.export(project: editor.state.project, video: editor.videoURL, settings: ExportSettings(), to: out)
        print("C6 export \(out.path) frames=\(report.plan.frameCount)")
        await f.show(out, label: "the export 0.12 s after the click at 2.6 s", at: 2.72)
        await f.show(out, label: "the export at the bottom of the press at 2.6 s", at: 2.6 + CursorTrack.pressDown)
        f.layers = { [unowned s, unowned editor] in s.layers(editor) + f.resultLayers() }
        await seek(s, editor, to: 2.72)
        f.hold(3.4, "Frames read back from the exported file: the same ring and pressed pointer as the preview.")
        var bare = editor.state.project
        bare.edits.cursor.isVisible = false
        bare.edits.clicks = ClickHighlight(isVisible: true)
        let lifetime = folder.appendingPathComponent("C6-lifetime.mp4")
        _ = try await VideoExporter.export(project: bare, video: editor.videoURL, settings: ExportSettings(), to: lifetime)
        print("C6 lifetime export \(lifetime.path) clicks=\(bare.events.clicks.map { String(format: "%.2f@%.0f,%.0f", $0.t, $0.x, $0.y) })")
        editor.window?.close()
        let stored = try RecordingProjectFile.read(from: editor.folder)
        f.layers = { [] }
        f.status = { "project.json after closing: cursor.pressesOnClick=\(stored.edits.cursor.pressesOnClick) clicks=\(stored.edits.clicks)" }
        f.refresh()
        f.hold(2.2, "Closing writes both effects to project.json.")
    }

    static func c7(_ f: Film, _ s: EditorStage, _ editor: VideoEditorWindowController) async throws {
        f.title = String(format: "C7  Hide when not moving: the pointer fades %.1f s into a rest and is back as it moves. Hide when typing: gone at the first key until it moves.",
                         CursorTrack.idleDelay)
        await s.press(try button(editor, "video.cursor.hideIdle"), in: editor, note: "Hide when not moving: on")
        f.hold(1, "Hide when not moving: on")
        await play(f, s, editor, from: 1.0, to: 5.2, note: "The pointer rests from 1.6 s. 1.5 s later it fades out, and it fades in just before it moves at 4.6 s.")
        await seek(s, editor, to: 3.5)
        f.hold(1.6, "Paused mid-rest: no pointer.")
        await s.press(try button(editor, "video.cursor.hideIdle"), in: editor, note: "Hide when not moving: off")
        f.hold(1.4, "Off: the resting pointer shows again.")
        await s.press(try button(editor, "video.cursor.hideTyping"), in: editor, note: "Hide when typing: on")
        await play(f, s, editor, from: 5.6, to: 8.6, note: "From 6.4 s \"types\" is typed: the pointer fades at the first key and returns when it moves at 8 s.")
        await play(f, s, editor, from: 6.2, to: 7.0, speed: 0.25, note: "A quarter of real speed around the first key press.")
        await s.press(try button(editor, "video.cursor.hideIdle"), in: editor, note: "Both options on")
        await play(f, s, editor, from: 0, to: 10, note: "Both on, the whole recording.")
        f.dark = true
        f.refresh()
        await play(f, s, editor, from: 1.4, to: 5.0, note: "The same in Dark appearance.")
        editor.window?.close()
        let stored = try RecordingProjectFile.read(from: editor.folder)
        f.layers = { [] }
        f.status = { "project.json after closing: hidesWhenIdle=\(stored.edits.cursor.hidesWhenIdle) hidesWhenTyping=\(stored.edits.cursor.hidesWhenTyping) keys=\(stored.events.keys.count)" }
        f.refresh()
        f.hold(2.2, "Closing writes both options to project.json.")
    }
}
