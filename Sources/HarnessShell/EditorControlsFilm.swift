import AppKit
import CornermarkCore
@testable import CornermarkDesign
@testable import CornermarkVideoEditor
@testable import CornermarkShell

/// The editor's own controls in one film, each driven by scripted pointer and key events on the real views: the zoom level field
/// dragged across its detents, the zoom lane's end dragged while its ramps follow the move duration, the mode select opened and
/// picked from the keyboard, and the cursor style thumb sliding between choices. Offscreen frames of a harness instance, so nothing
/// reaches the screen. Run with `CORNERMARK_EDITOR_CONTROLS_FILM=<folder>`.
@MainActor
enum EditorControlsFilm {
    static func run(out: URL) async -> Bool {
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        guard let film = Film(url: out.appendingPathComponent("editor-controls.mp4")) else { return false }
        do {
            let stage = try await EditorStage(film, frames: 240)
            defer { stage.w.cleanup() }
            try await scenes(film, stage)
        } catch { film.failures.append("\(error)") }
        let frames = await film.finish()
        print("FILM editor-controls.mp4 frames=\(frames) failures=\(film.failures)")
        return frames > 0 && film.failures.isEmpty
    }

    private static func event(_ type: NSEvent.EventType, at point: CGPoint, in view: NSView) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: view.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    /// The film pointer on a point of `view`.
    private static func spot(_ point: CGPoint, in view: NSView, _ s: EditorStage) -> CGPoint {
        let p = view.convert(point, to: nil)
        return CGPoint(x: s.origin.x + p.x, y: s.origin.y + p.y)
    }

    private static func scenes(_ f: Film, _ s: EditorStage) async throws {
        f.title = "Editor controls: the level field, the zoom lane, the mode select and the segment track, driven by scripted events on the real views"
        guard let editor = try await s.openProject(), let window = editor.window else { throw FilmError.missing("the editor") }
        f.hold(1.0, "A recorded project in the editor.")

        guard let zoom = editor.addZoom(from: 0.4, to: 1.2) else { throw FilmError.missing("a zoom") }
        editor.selectZoom(zoom.id)
        await s.settle(editor)
        f.hold(1.2, "A zoom picked: the panel shows its level field, mode select and the lane block with its ramps.")

        // 1. The level field: press anywhere, drag across the detents, let go on one.
        guard let level = editor.view(identifier: "video.zoom.level") as? Slider else { throw FilmError.missing("the level field") }
        let y = level.bounds.midY
        let xs: [CGFloat] = stride(from: 0.1, through: 0.97, by: 0.025).map { level.bounds.width * CGFloat($0) }
            + stride(from: 0.97, through: 0.16, by: -0.03).map { level.bounds.width * CGFloat($0) }
        f.glide(to: spot(CGPoint(x: xs[0], y: y), in: level, s), "The level field: no knob to aim at, a press anywhere sets the level.")
        level.mouseDown(with: event(.leftMouseDown, at: CGPoint(x: xs[0], y: y), in: level))
        for x in xs.dropFirst() {
            level.mouseDragged(with: event(.leftMouseDragged, at: CGPoint(x: x, y: y), in: level))
            await s.settle(editor)
            f.glide(to: spot(CGPoint(x: x, y: y), in: level, s), "Dragging the level field: \(level.valueText ?? ""). The value stays readable at every fill.", frames: 2)
        }
        let detent = level.bounds.width * CGFloat((1.52 - level.minValue) / (level.maxValue - level.minValue))
        level.mouseDragged(with: event(.leftMouseDragged, at: CGPoint(x: detent, y: y), in: level))
        level.mouseUp(with: event(.leftMouseUp, at: CGPoint(x: detent, y: y), in: level))
        await s.settle(editor)
        f.glide(to: spot(CGPoint(x: detent, y: y), in: level, s), "Let go near the 150% tick: the level lands on the detent, \(level.valueText ?? "").", frames: 6)
        f.hold(1.4, "Let go near the 150% tick: the level lands on the detent, \(level.valueText ?? "").")
        if level.valueText != "150%" { f.failures.append("the level did not land on 150%: \(level.valueText ?? "nil")") }

        // 2. The zoom lane: drag the block's end; the ramps keep the move's length at the timeline's scale.
        guard let lane = editor.view(identifier: "video.zoomLane") as? ZoomLaneView, let block = lane.zooms.first.map(lane.rect(of:)) else { throw FilmError.missing("the zoom lane") }
        let ly = block.midY
        f.glide(to: spot(CGPoint(x: block.maxX - 2, y: ly), in: lane, s), "The 40 pt zoom lane: level, mode, handles, and ramps as long as the zoom's move in and out.")
        f.hold(1.6, "The ramps draw the move on its smootherstep curve, \(String(format: "%.2f", editor.state.project.edits.zoomAnimation.duration)) s each way.")
        lane.mouseDown(with: event(.leftMouseDown, at: CGPoint(x: block.maxX - 2, y: ly), in: lane))
        for i in 1...30 {
            let x = block.maxX - 2 + CGFloat(i) * 8
            lane.mouseDragged(with: event(.leftMouseDragged, at: CGPoint(x: x, y: ly), in: lane))
            await s.settle(editor)
            f.glide(to: spot(CGPoint(x: x, y: ly), in: lane, s), "Dragging the zoom's end handle: the ramps keep their length.", frames: 2)
        }
        lane.mouseUp(with: event(.leftMouseUp, at: CGPoint(x: block.maxX + 238, y: ly), in: lane))
        await s.settle(editor)
        f.hold(0.8, "The zoom now runs to \(Timecode.text(editor.state.project.edits.zooms.first?.end ?? 0)).")
        editor.openZoomAnimation()
        await s.settle(editor)
        if let duration = editor.view(identifier: "video.zoomAnimation.duration") as? Slider {
            let dy = duration.bounds.midY
            f.glide(to: spot(CGPoint(x: duration.bounds.width * 0.4, y: dy), in: duration, s), "Animation Settings: Duration is a field slider too.")
            duration.mouseDown(with: event(.leftMouseDown, at: CGPoint(x: duration.bounds.width * 0.4, y: dy), in: duration))
            for i in 0...24 {
                let x = duration.bounds.width * (0.4 + 0.5 * CGFloat(i) / 24)
                duration.mouseDragged(with: event(.leftMouseDragged, at: CGPoint(x: x, y: dy), in: duration))
                await s.settle(editor)
                f.glide(to: spot(CGPoint(x: x, y: dy), in: duration, s), "A longer move, \(duration.valueText ?? ""): the lane's ramps grow with it.", frames: 2)
            }
            duration.mouseUp(with: event(.leftMouseUp, at: CGPoint(x: duration.bounds.width * 0.9, y: dy), in: duration))
            await s.settle(editor)
            f.hold(1.6, "A longer move, \(duration.valueText ?? ""): the lane's ramps grow with it.")
        } else {
            f.failures.append("no duration field")
        }
        editor.closeZoomAnimation()
        await s.settle(editor)

        // 3. The mode select: a click opens Cornermark's own menu under the field; arrows and Return pick.
        guard let mode = editor.view(identifier: "video.zoom.mode") as? Select else { throw FilmError.missing("the mode select") }
        let mid = CGPoint(x: mode.bounds.midX, y: mode.bounds.midY)
        f.glide(to: spot(mid, in: mode, s), "The Mode select: a field, not the system popup.")
        mode.mouseDown(with: event(.leftMouseDown, at: mid, in: mode))
        mode.mouseUp(with: event(.leftMouseUp, at: mid, in: mode))
        await s.settle(editor)
        f.hold(1.4, "Its own menu opens under it, the picked mode checked on the right.")
        NSApp.sendEvent(Synth.keyEvent(window, 125))
        await s.settle(editor)
        f.hold(1.0, "Down arrow moves the highlight to Manual.")
        NSApp.sendEvent(Synth.keyEvent(window, 36, "\r"))
        await s.settle(editor)
        f.hold(1.6, "Return picks it: the mode is \(editor.state.project.edits.zooms.first?.mode.title ?? "?") and the frame picture appears.")
        if editor.state.project.edits.zooms.first?.mode != .manual { f.failures.append("the select did not pick Manual") }
        mode.performClick(nil)
        await s.settle(editor)
        f.hold(0.8, "Opened again from the keyboard.")
        NSApp.sendEvent(Synth.keyEvent(window, 53, "\u{1b}"))
        await s.settle(editor)
        f.hold(0.8, "Esc closes it and nothing else changes.")

        // 4. The segment track: the thumb slides to the clicked choice.
        editor.selectZoom(nil)
        editor.select(.cursor)
        await s.settle(editor)
        f.hold(1.0, "The Cursor section: Style and Motion are segment tracks with a neutral thumb.")
        // Rendering a film frame takes longer than the slide's 0.20 s, so the slide runs ten times slower here and the caption says so.
        Segments.slideDuration = DS.Motion.Duration.base * 10
        defer { Segments.slideDuration = DS.Motion.Duration.base }
        guard let style = editor.view(identifier: "video.cursor.style") as? Segments,
              let motion = editor.view(identifier: "video.cursor.motion") as? Segments else { throw FilmError.missing("the cursor segments") }
        for (control, index, name) in [(style, 1, "Black"), (style, 2, "Dot"), (motion, 1, "Smooth"), (style, 0, "White"), (motion, 0, "Natural")] {
            let tile = control.tile(index)
            let at = CGPoint(x: tile.midX, y: tile.midY)
            f.glide(to: spot(at, in: control, s), "Click \(name).", frames: 12)
            control.mouseDown(with: event(.leftMouseDown, at: at, in: control))
            control.mouseUp(with: event(.leftMouseUp, at: at, in: control))
            // Every film frame is a fresh render of the window while the real animation runs on the app's clock.
            let started = Date()
            while Date().timeIntervalSince(started) < Segments.slideDuration + 0.1 {
                try? await Task.sleep(nanoseconds: 4_000_000)
                f.refresh()
                f.frame("The thumb slides to \(name): 0.20 s ease-out, shown at a tenth of its speed.")
            }
            await s.settle(editor)
            f.hold(0.6, "\(name) picked.")
        }
        if editor.state.project.edits.cursor.style != .white || editor.state.project.edits.cursor.motion != .natural { f.failures.append("the segments did not end on White and Natural") }

        f.dark = true
        f.refresh()
        f.hold(1.6, "The same controls in Dark appearance.")
        let selectionStyle = style.tile(1)
        style.mouseDown(with: event(.leftMouseDown, at: CGPoint(x: selectionStyle.midX, y: selectionStyle.midY), in: style))
        style.mouseUp(with: event(.leftMouseUp, at: CGPoint(x: selectionStyle.midX, y: selectionStyle.midY), in: style))
        let started = Date()
        while Date().timeIntervalSince(started) < Segments.slideDuration + 0.1 {
            try? await Task.sleep(nanoseconds: 4_000_000)
            f.refresh()
            f.frame("Dark: the thumb slides to Black, at a tenth of its speed.")
        }
        await s.settle(editor)
        f.hold(1.4, "Dark: the raised thumb is the lighter step.")
    }
}
