#if DEBUG
import AppKit
import CornermarkCore

/// Scripted scenes a scripted instance plays in its own on-screen editor while it records that window, so the evidence is the
/// real window filmed by the real recorder. Input goes straight to the editor's views; nothing touches the system's mouse,
/// keyboard or cursor, and the window never takes focus.
extension VideoEditorWindowController {
    public typealias Scene = @MainActor (VideoEditorWindowController, _ note: @escaping (String) -> Void) async -> Void

    /// Scenes by name, as `record/test-window?editor=&scene=` names them. Another file adds its own.
    public static var scenes: [String: Scene] = [
        "E5": { editor, note in await Script(editor: editor, note: note).e5() },
        "E6": { editor, note in await Script(editor: editor, note: note).e6() },
    ]

    /// Orders the window in behind every other window without making it key, and starts the clock that draws its frames.
    public func showBehind(at origin: CGPoint) {
        guard let window else { return }
        window.setFrameOrigin(origin)
        window.orderBack(nil)
        startDisplayLink()
    }

    public func play(_ scene: Scene, note: @escaping (String) -> Void) async {
        timeline.showsResizeCursor = false
        defer { timeline.showsResizeCursor = true }
        await scene(self, note)
    }
}

@MainActor
struct Script {
    let editor: VideoEditorWindowController
    let note: (String) -> Void
    var timeline: TimelineView { editor.timeline }

    func e5() async {
        await hold(1.5, "one clip, the whole recording")
        editor.togglePlayback()
        await hold(2, "playing")
        editor.togglePlayback()
        await hold(1, "paused")
        key(11, .command)
        await hold(2, "Command-B split at the playhead")
        await scrub(to: 5)
        await hold(0.8, "playhead at 0:05")
        (editor.view(identifier: "video.split") as? NSButton)?.performClick(nil)
        await hold(2, "Split button: three clips")
        click(CGPoint(x: x(3.5), y: timeline.clipLaneRect.midY))
        await hold(2, "middle clip picked")
        key(51, [])
        await hold(2.5, "Delete removed the middle clip")
        let end = CGPoint(x: timeline.clipRects[0].maxX - 2, y: timeline.clipLaneRect.midY)
        await drag(from: end, to: CGPoint(x: end.x - CGFloat(0.8 * timeline.scale.pointsPerSecond), y: end.y), "dragging the first clip's end left")
        await hold(2, "first clip trimmed")
        let start = CGPoint(x: timeline.clipRects[1].minX + 2, y: timeline.clipLaneRect.midY)
        await drag(from: start, to: CGPoint(x: start.x - CGFloat(1.5 * timeline.scale.pointsPerSecond), y: start.y), "dragging the second clip's start left")
        await hold(2, "second clip brought back 1.5 s")
        key(6, .command)
        await hold(1.5, "Command-Z")
        key(6, .command)
        await hold(1.5, "Command-Z again")
        key(6, [.command, .shift])
        key(6, [.command, .shift])
        await hold(1.5, "Shift-Command-Z twice")
        timeline.window?.makeFirstResponder(timeline)
        for _ in 0..<6 {
            timeline.keyDown(with: keyEvent(124, .option))
            await hold(0.25, "Option-Right trims the clip's start a frame")
        }
        await hold(1.5, "keyboard trim")
        editor.seek(to: 0)
        editor.togglePlayback()
        await hold(3.5, "playing the trimmed video across the cut")
        editor.togglePlayback()
        await hold(2, "done")
    }

    func e6() async {
        await hold(1.5, "one clip, no cuts")
        for t in [2.0, 4.0, 7.5] {
            await scrub(to: t)
            key(11, .command)
            await hold(1.5, "Command-B: a cut mark at \(t) s")
        }
        await hold(2, "three cuts, three marks")
        click(CGPoint(x: x(3), y: timeline.clipLaneRect.midY))
        await hold(1.5, "second clip picked")
        key(51, [])
        await hold(2.5, "deleted: the marks follow the cuts left")
        editor.seek(to: 0)
        editor.togglePlayback()
        await hold(4.5, "playing across the cuts")
        editor.togglePlayback()
        await hold(1, "paused")
        editor.openExport()
        await hold(1.5, "export panel")
        editor.startExport()
        note("exporting")
        for _ in 0..<600 where editor.state.export != .closed { try? await Task.sleep(nanoseconds: 50_000_000) }
        await hold(2.5, "exported")
    }

    private func x(_ t: Double) -> CGFloat { CGFloat(timeline.scale.x(t)) }

    private func hold(_ seconds: Double, _ text: String) async {
        note(text)
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private func keyEvent(_ code: UInt16, _ mods: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime,
                         windowNumber: timeline.window?.windowNumber ?? 0, context: nil, characters: "", charactersIgnoringModifiers: "",
                         isARepeat: false, keyCode: code)!
    }

    private func key(_ code: UInt16, _ mods: NSEvent.ModifierFlags) { _ = editor.handleKey(keyEvent(code, mods)) }

    private func mouse(_ type: NSEvent.EventType, _ p: CGPoint) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: timeline.convert(p, to: nil), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: timeline.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    private func click(_ p: CGPoint) {
        timeline.mouseDown(with: mouse(.leftMouseDown, p))
        timeline.mouseUp(with: mouse(.leftMouseUp, p))
    }

    private func drag(from a: CGPoint, to b: CGPoint, _ text: String, steps: Int = 45) async {
        note(text)
        timeline.mouseDown(with: mouse(.leftMouseDown, a))
        for i in 1...steps {
            let k = CGFloat(i) / CGFloat(steps), e = k * k * (3 - 2 * k)
            timeline.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: a.x + (b.x - a.x) * e, y: a.y)))
            try? await Task.sleep(nanoseconds: 33_000_000)
        }
        timeline.mouseUp(with: mouse(.leftMouseUp, b))
    }

    private func scrub(to t: Double) async {
        let y = timeline.rulerRect.midY, from = x(editor.state.transport.time(at: CACurrentMediaTime())), to = x(t)
        timeline.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: from, y: y)))
        for i in 1...18 {
            let k = CGFloat(i) / 18
            timeline.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: from + (to - from) * k, y: y)))
            try? await Task.sleep(nanoseconds: 33_000_000)
        }
        timeline.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: to, y: y)))
    }
}
#endif
