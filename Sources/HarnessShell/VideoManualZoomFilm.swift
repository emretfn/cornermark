import AppKit
import CornermarkCore
@testable import CornermarkVideoEditor
@testable import CornermarkShell

/// Films picking a Manual zoom's target and the Animation Settings panel for review: the real editor of a harness world, rendered
/// offscreen, over the follow film's scripted pointer track. The charts, the orange box, the outline and the drawn menu are the
/// harness's drawings, not part of the app. Run with `CORNERMARK_MANUAL_ZOOM_FILM=<folder> swift run HarnessShell`.
@MainActor
enum VideoManualZoomFilm {
    static func run(out: URL) async -> Bool {
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var ok = true
        let scenes: [(String, (Film, EditorStage, VideoEditorWindowController) async throws -> Void)] = [("Z5-manual", z5), ("Z11", z11), ("Z12", z12)]
        let only = ProcessInfo.processInfo.environment["CORNERMARK_MANUAL_ZOOM_SCENES"].map { Set($0.split(separator: ",").map(String.init)) }
        for (name, scene) in scenes where only?.contains(name) ?? true {
            guard let film = Film(url: out.appendingPathComponent("\(name).mp4")) else { return false }
            do {
                let stage = try await EditorStage(film, frames: 600)
                stage.area = "display=1&x=0&y=0&width=1280&height=720"
                defer { stage.w.cleanup() }
                guard let editor = try await VideoFollowFilm.open(stage) else { throw FilmError.missing("the editor") }
                try await scene(film, stage, editor)
            } catch { film.failures.append("\(error)") }
            let written = await film.finish()
            print("FILM \(name).mp4 frames=\(written) failures=\(film.failures)")
            ok = ok && written > 0 && film.failures.isEmpty
        }
        return ok
    }

    // MARK: Scenes

    static func z5(_ f: Film, _ s: EditorStage, _ editor: VideoEditorWindowController) async throws {
        f.title = "Z5 (Manual half)  Mode: Manual shows the recording at the zoom's middle with the view as a frame. Drag the frame, click a spot, or use the arrow keys."
        let x = Extras()
        layers(f, s, editor, x)
        let (id, window, target) = try await pick(s, editor)
        guard let mode = editor.view(identifier: "video.zoom.mode") as? NSPopUpButton else { throw FilmError.missing("the mode menu") }
        editor.seek(to: 4.4)
        await s.settle(editor)
        f.hold(1.6, "One zoom at 200%, 1.0 s to 9.0 s, picked. It follows the cursor, so its panel has no target.")
        let chevron = { let c = f.center(of: mode, in: window, at: s.origin); return CGPoint(x: c.x + mode.bounds.width / 2 - 8, y: c.y) }
        f.glide(to: chevron(), "Choosing Manual in the Mode menu.")
        mode.selectItem(at: 1)
        fire(mode)
        await settleTarget(s, editor)
        f.hold(2.8, "Mode: Manual. The picture is the recording at the zoom's middle; the frame is the part the video shows.")
        let hand = TargetHand(view: target)
        let start = editor.state.project.edits.zooms.first { $0.id == id }?.center ?? .middle
        await drag(f, s, editor, hand, from: (start.x, start.y), to: (0.8, 0.32), "Dragging the frame to the upper right. The preview at 4.4 s follows.")
        f.hold(1.8, "The frame stays where it was let go; the preview shows that spot.")
        await VideoFollowFilm.play(f, s, editor, from: 0, to: 9.6, note: "Playing: the camera moves in to the picked spot and holds it while the pointer wanders.")
        f.hold(0.6, "Back at 100%.")
        editor.seek(to: 6.0)
        await s.settle(editor)
        f.glide(to: stage(s, hand, 0.28, 0.72), "A click outside the frame puts its centre there.", frames: 14)
        hand.click(0.28, 0.72)
        await s.settle(editor)
        f.hold(2, "The frame jumped to the lower left, and the preview at 6.0 s shows it.")
        await drag(f, s, editor, hand, from: (0.28, 0.72), to: (0.02, 0.99), "Dragging past the corner.")
        f.hold(1.8, "It stops at the picture's edge, so the video never shows past the recording.")
        f.glide(to: CGPoint(x: Film.stage.width - 30, y: 20), "", frames: 8)
        f.hold(0.6, "The picture has keyboard focus.")
        for _ in 0..<5 {
            target.keyDown(with: Synth.keyEvent(window, 124, ""))
            await s.settle(editor)
            f.hold(0.3, "Right arrow: a hundredth of the picture each press.")
        }
        for _ in 0..<2 {
            target.keyDown(with: Synth.keyEvent(window, 126, "", modifiers: .shift))
            await s.settle(editor)
            f.hold(0.45, "Shift-Up: a tenth of the picture.")
        }
        f.hold(1, "The arrow presses moved the frame up and right.")
        Synth.key(window, 6, "z", modifiers: .command)
        await s.settle(editor)
        f.hold(1.8, "Command-Z takes the whole run of presses back in one step.")
        f.dark = true
        f.refresh()
        f.hold(1.4, "The same in Dark appearance.")
        await VideoFollowFilm.play(f, s, editor, from: 4.6, to: 7.2, note: "The same in Dark appearance: the camera holds the picked spot.")
        f.hold(1, "The same in Dark appearance.")
    }

    static func z11(_ f: Film, _ s: EditorStage, _ editor: VideoEditorWindowController) async throws {
        f.title = "Z11  The zoom panel has an Animation Settings button. It opens how every zoom in this video moves; the zoom's right-click menu opens it too."
        let x = Extras()
        layers(f, s, editor, x)
        let (_, window, _) = try await pick(s, editor)
        guard let button = editor.view(identifier: "video.zoom.animationSettings") as? NSButton,
              let lane = editor.view(identifier: "video.zoomLane") as? ZoomLaneView else { throw FilmError.missing("the button") }
        s.outline = frameInWindow(button)
        f.refresh()
        f.hold(2.6, "A zoom is picked. Under its level and mode: Animation Settings (outlined by the harness).")
        s.outline = nil
        await s.press(button, in: editor, note: "Clicking Animation Settings.")
        f.hold(3.2, "The panel floats over the settings column beside its button, risen to keep the timeline clear, so the preview stays whole.")
        f.hold(1.6, "It opens on the defaults: 0.78 s moves, a 50% hold area and a 0.68 s catch-up.")
        Synth.key(window, 53, "\u{1b}")
        await s.settle(editor)
        f.hold(2, "Esc closes it; focus returns to the button and the zoom stays picked.")
        let hand = ZoomHand(lane: lane)
        let px = hand.x(5)
        f.glide(to: VideoZoomFilm.point(s, hand, px), "Right click on the zoom.", frames: 12)
        guard let menu = hand.menu(x: px) else { throw FilmError.missing("the zoom's menu") }
        x.menu = (VideoZoomFilm.menuImage(menu, open: nil, highlight: "Animation Settings\u{2026}"), lane.convert(CGPoint(x: px, y: lane.bounds.maxY), to: nil))
        f.refresh()
        f.hold(2.4, "The zoom's menu (drawn by the harness from the real menu's items) has Animation Settings too.")
        if menu.pick("Animation Settings\u{2026}") != true { f.failures.append("the menu item did not open the panel") }
        x.menu = nil
        await s.settle(editor)
        f.hold(2, "Choosing it opens the same panel.")
        f.dark = true
        f.refresh()
        f.hold(2.4, "The same in Dark appearance.")
        if let done = editor.view(identifier: "video.zoomAnimation.done") as? NSButton { await s.press(done, in: editor, note: "Done closes it.") }
        f.hold(1.4, "Done closes it.")
    }

    static func z12(_ f: Film, _ s: EditorStage, _ editor: VideoEditorWindowController) async throws {
        f.title = "Z12  Animation Settings, Cornermark's own choice: Duration of each move in and out, and Hold area and Catch-up for Follow Cursor zooms. Defaults keep the earlier camera."
        let x = Extras()
        layers(f, s, editor, x)
        let (_, window, _) = try await pick(s, editor)
        guard let button = editor.view(identifier: "video.zoom.animationSettings") as? NSButton,
              let duration = editor.view(identifier: "video.zoomAnimation.duration") as? TrackingSlider,
              let hold = editor.view(identifier: "video.zoomAnimation.holdArea") as? TrackingSlider,
              let catchUp = editor.view(identifier: "video.zoomAnimation.catchUp") as? TrackingSlider,
              let reset = editor.view(identifier: "video.zoomAnimation.reset") as? NSButton else { throw FilmError.missing("the panel's controls") }
        await s.press(button, in: editor, note: "Opening Animation Settings.")
        x.scaleChart = true
        f.refresh()
        f.hold(2.4, "Duration: how long each move into or out of a zoom takes. The chart is the camera's scale, drawn by the harness from frameState.")
        await VideoFollowFilm.play(f, s, editor, from: 0.6, to: 2.4, speed: 0.5, note: "At 0.78 s, at half speed: the move in.")
        await slide(f, s, editor, duration, to: 1.4, "Dragging Duration to 1.40 s. The chart's ramps grow.")
        await VideoFollowFilm.play(f, s, editor, from: 0.6, to: 2.8, speed: 0.5, note: "At 1.40 s, at half speed: the same move in, slower, still smooth at both ends.")
        await slide(f, s, editor, duration, to: 0.4, "Dragging Duration to 0.40 s.")
        await VideoFollowFilm.play(f, s, editor, from: 0.6, to: 2.0, speed: 0.5, note: "At 0.40 s: a quick move.")
        await slide(f, s, editor, duration, to: 0.78, "Back to 0.78 s.")
        x.scaleChart = false
        x.box = true
        x.speedChart = true
        f.refresh()
        f.hold(2.2, "Hold area: the share of the view the pointer moves in before a Follow Cursor zoom pans (orange box, drawn by the harness).")
        await slide(f, s, editor, hold, to: 0.25, "Dragging Hold area to 25%.")
        await VideoFollowFilm.play(f, s, editor, from: 1.4, to: 4.4, note: "25%: even the small wiggle in the middle pushes past the box, so the camera keeps moving.")
        await slide(f, s, editor, hold, to: 0.75, "Dragging Hold area to 75%.")
        await VideoFollowFilm.play(f, s, editor, from: 1.4, to: 4.4, note: "75%: the wiggle stays inside, and the camera moves only once the pointer travels far.")
        await slide(f, s, editor, hold, to: 0.5, "Back to 50%.")
        f.hold(1.4, "Catch-up: the time the camera takes to reach the pointer after it leaves the box.")
        await slide(f, s, editor, catchUp, to: 0.35, "Dragging Catch-up to 0.35 s.")
        await VideoFollowFilm.play(f, s, editor, from: 2.8, to: 4.6, speed: 0.5, note: "0.35 s, at half speed: a quick, tall speed curve.")
        await slide(f, s, editor, catchUp, to: 1.3, "Dragging Catch-up to 1.30 s.")
        await VideoFollowFilm.play(f, s, editor, from: 2.8, to: 4.6, speed: 0.5, note: "1.30 s, at half speed: a slow, low drift that never overshoots.")
        await s.press(reset, in: editor, note: "Reset to Defaults.")
        f.hold(2, "Reset to Defaults puts back 0.78 s, 50% and 0.68 s, and turns itself off.")
        Synth.key(window, 6, "z", modifiers: .command)
        await s.settle(editor)
        f.hold(2, "Command-Z brings back the chosen values. Each slider drag is one undo step.")
        f.dark = true
        f.refresh()
        await VideoFollowFilm.play(f, s, editor, from: 2.8, to: 4.6, speed: 0.5, note: "The same in Dark appearance.")
        f.hold(1, "The same in Dark appearance.")
    }

    // MARK: Helpers

    /// What the harness draws over the editor.
    final class Extras {
        var box = false
        var speedChart = false
        var scaleChart = false
        var menu: (CGImage?, CGPoint)?
    }

    static func layers(_ f: Film, _ s: EditorStage, _ editor: VideoEditorWindowController, _ x: Extras) {
        f.status = { [unowned editor, unowned s] in status(s, editor) }
        f.layers = { [unowned editor, unowned s] in
            var layers = s.layers(editor)
            if x.box, let box = VideoFollowFilm.box(s, editor) { layers.append(box) }
            // Charts sit on the preview's lower right, since Animation Settings covers the settings column.
            let chartRect: CGRect? = (editor.view(identifier: "video.preview") as? PreviewView).map { preview in
                let r = preview.convert(preview.pictureRect, to: nil)
                return CGRect(x: s.origin.x + r.maxX - 294, y: s.origin.y + r.minY + 8, width: 286, height: 150)
            }
            if x.speedChart, let chart = VideoFollowFilm.speedChart(s, editor), let r = chartRect { layers.append((chart, r)) }
            if x.scaleChart, let chart = s.chartImage(editor), let r = chartRect { layers.append((chart, r)) }
            if let (image, p) = x.menu, let image {
                let size = CGSize(width: CGFloat(image.width) / 2, height: CGFloat(image.height) / 2)
                layers.append((image, CGRect(x: min(s.origin.x + p.x - 120, Film.stage.width - size.width - 8), y: s.origin.y + p.y + 4, width: size.width, height: size.height)))
            }
            return layers
        }
        f.refresh()
    }

    static func status(_ s: EditorStage, _ editor: VideoEditorWindowController) -> String {
        let st = editor.state
        let t = st.transport.time(at: s.clock.now)
        let crop = frameState(st.project, outputTime: t).crop
        let a = st.project.edits.zoomAnimation
        let zoom = st.project.edits.zooms.first
        return String(format: "t=%@  mode=%@  centre=(%.2f, %.2f)  camera scale=%.3f x=%.3f y=%.3f  duration=%.2f s  hold=%d%%  catch-up=%.2f s  panel=%@",
                      Timecode.text(t), zoom?.mode.title ?? "none", zoom?.center.x ?? 0, zoom?.center.y ?? 0, crop.scale, crop.x, crop.y,
                      a.duration, Int((a.deadZone * 100).rounded()), a.settleTime, st.showsZoomAnimation ? "open" : "closed")
    }

    static func pick(_ s: EditorStage, _ editor: VideoEditorWindowController) async throws -> (UUID, NSWindow, ZoomTargetView) {
        guard let id = editor.state.project.edits.zooms.first?.id, let window = editor.window,
              let target = editor.view(identifier: "video.zoom.target") as? ZoomTargetView else { throw FilmError.missing("the zoom") }
        editor.selectZoom(id)
        window.contentView?.layoutSubtreeIfNeeded()
        await s.settle(editor)
        return (id, window, target)
    }

    static func settleTarget(_ s: EditorStage, _ editor: VideoEditorWindowController) async {
        editor.window?.contentView?.layoutSubtreeIfNeeded()
        await editor.zoomTargetSettled()
        await s.settle(editor)
    }

    /// A point of the target's picture on the film's stage.
    static func stage(_ s: EditorStage, _ hand: TargetHand, _ x: Double, _ y: Double) -> CGPoint {
        let p = hand.point(x, y)
        return CGPoint(x: s.origin.x + p.x, y: s.origin.y + p.y)
    }

    /// Drags through the target's own handlers, the film's arrow riding along and the preview redrawn at each step.
    static func drag(_ f: Film, _ s: EditorStage, _ editor: VideoEditorWindowController, _ hand: TargetHand, from a: (Double, Double), to b: (Double, Double),
                     _ note: String, steps: Int = 24) async {
        f.glide(to: stage(s, hand, a.0, a.1), note, frames: 12)
        hand.view.mouseDown(with: hand.event(.leftMouseDown, a.0, a.1))
        for i in 1...steps {
            let k = Double(i) / Double(steps), e = k * k * (3 - 2 * k)
            let p = (a.0 + (b.0 - a.0) * e, a.1 + (b.1 - a.1) * e)
            hand.view.mouseDragged(with: hand.event(.leftMouseDragged, p.0, p.1))
            await s.settle(editor)
            f.glide(to: stage(s, hand, p.0, p.1), note, frames: 1)
        }
        hand.view.mouseUp(with: hand.event(.leftMouseUp, b.0, b.1))
        await s.settle(editor)
    }

    /// Moves a slider to `value` in steps through its own action, as a drag would, then lets go.
    static func slide(_ f: Film, _ s: EditorStage, _ editor: VideoEditorWindowController, _ slider: TrackingSlider, to value: Double, _ note: String) async {
        let start = slider.doubleValue
        let knob = { () -> CGPoint in
            let r = slider.convert(slider.bounds, to: nil)
            let k = (slider.doubleValue - slider.minValue) / max(slider.maxValue - slider.minValue, 1e-9)
            return CGPoint(x: s.origin.x + r.minX + 8 + (r.width - 16) * CGFloat(k), y: s.origin.y + r.midY)
        }
        f.glide(to: knob(), note, frames: 10)
        for i in 1...18 {
            let k = Double(i) / 18, e = k * k * (3 - 2 * k)
            slider.doubleValue = start + (value - start) * e
            fire(slider)
            await s.settle(editor)
            f.glide(to: knob(), note, frames: 1)
        }
        slider.onTrackingEnd()
        f.hold(0.8, note)
    }
}
