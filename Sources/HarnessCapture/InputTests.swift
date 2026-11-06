import AppKit
import AVFoundation
import CornermarkCapture
import CornermarkCore

func frame(of url: URL, at seconds: Double) async -> CGImage? {
    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = .zero
    return try? await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
}

@MainActor
func lemon(in image: CGImage, y: Double, x0: Double, x1: Double) -> Bool {
    stride(from: x0, through: x1, by: 1).contains { x in
        let c = color(image, x / Double(image.width), y / Double(image.height))
        return c[0] > 180 && c[1] > 180 && c[2] < 120
    }
}

@MainActor
func runInputTests() async {
    section("clicks and keys")
    let fps = 60, width = 1280.0, height = 720.0
    let all = InputCapture(clicks: true, keys: .all)
    let script = InputScript(clicks: [.init(t: 0.45, x: 0.5, y: 0.2), .init(t: 1.9, x: 0.85, y: 0.2)],
                             keys: [KeyEvent(t: 0.45, label: "\u{2318}K", isCommand: true), KeyEvent(t: 1.2, label: "a", isCommand: false)])
    try? FileManager.default.createDirectory(atPath: recordingScratch, withIntermediateDirectories: true)

    func record(_ name: String, capture: InputCapture, marks: InputMarks?, frames: Int = 150, skipping: Set<Int> = [], origin: Double = 0, lead: Double = 0)
        async throws -> (RecordingReport, URL, (marked: Int, filled: Int)) {
        let url = URL(fileURLWithPath: recordingScratch + name + ".mp4")
        let input = ScriptedInputSource(script: script, capture: capture, pacing: .fixed(origin: origin - lead, seconds: 4))
        let source = FixtureFrameSource(options: RecordingOptions(fps: fps), pacing: .scripted(frames: frames, skipping: skipping, origin: origin))
        let recorder = Recorder(source: source, output: url, input: input, marks: marks)
        try await recorder.start()
        let report = try await recorder.stop()
        return (report, url, recorder.markedFrames)
    }

    do {
        let (report, _, marked) = try await record("input-project", capture: all, marks: nil, origin: 5, lead: 0.2)
        check(report.clicks.map { ($0.t * 1e6).rounded() / 1e6 } == [0.25, 1.7] && report.clicks.first?.x == 0.5 * width && report.clicks.first?.y == 0.2 * height,
              "clicks land on the video's timeline, measured from the first frame, in points of the area", detail: "\(report.clicks)")
        check(report.keys.map(\.label) == ["\u{2318}K", "a"] && abs((report.keys.first?.t ?? 0) - 0.25) < 1e-9, "keys too, with their labels", detail: "\(report.keys)")
        check(marked.marked == 0, "Record Project draws no marks into its picture: they stay editable in the project")
        check(report.project.events.clicks.count == 2 && report.project.events.keys.count == 2, "and the project carries both tracks")

        let early = try await record("input-early", capture: all, marks: nil, origin: 5, lead: 0.6)
        check(early.0.clicks.count == 1 && early.0.keys.count == 1, "an event before the first frame is left out", detail: "\(early.0.clicks) \(early.0.keys)")

        let shortcuts = try await record("input-shortcuts", capture: InputCapture(clicks: false, keys: .shortcuts), marks: nil)
        check(shortcuts.0.clicks.isEmpty && shortcuts.0.keys.map(\.label) == ["\u{2318}K"], "Shortcuts only never stores a typed key, and clicks off stores no click",
              detail: "\(shortcuts.0.keys)")
    } catch {
        check(false, "recording with input threw", detail: "\(error)")
    }

    let marks = InputMarks(clicks: ClickHighlight(isVisible: true), keystrokes: KeystrokeDisplay(isVisible: true, keys: .all))
    let ringY = 0.2 * height, ringX = 0.5 * width
    do {
        let (report, url, marked) = try await record("input-video", capture: all, marks: marks)
        check(marked.marked > 0 && marked.filled == 0, "Record MP4 draws marks into its picture, and a steady stream needs no filled slots", detail: "\(marked)")
        let before = await frame(of: url, at: 0.4), during = await frame(of: url, at: 0.5), after = await frame(of: url, at: 0.9)
        if let before, let during, let after {
            check(!lemon(in: before, y: ringY, x0: ringX + 8, x1: ringX + 22), "no ring before the click")
            check(lemon(in: during, y: ringY, x0: ringX + 8, x1: ringX + 22), "a lemon ring around the click 0.05 s after it")
            check(!lemon(in: after, y: ringY, x0: ringX + 8, x1: ringX + 22), "and none 0.45 s after it, past its 0.4 s life")
        } else { check(false, "frames of the marked video") }
        let badge = InputOverlayPainter.badgeFrame(text: "\u{2318}K", area: CGSize(width: width, height: height), marks.keystrokes)
        if let shown = await frame(of: url, at: 1.0), let gone = await frame(of: url, at: 2.4) {
            let c = color(shown, badge.midX / width, (badge.minY + 3) / height)
            check(c.allSatisfy { $0 < 60 }, "the keystroke badge sits at the bottom center 0.55 s after the shortcut", detail: "\(c) in \(badge)")
            let g = color(gone, badge.midX / width, (badge.minY + 3) / height)
            check(g != c, "and is gone once its hold and fade pass", detail: "\(g)")
        } else { check(false, "frames with the badge") }
        check(report.clicks.count == 2, "a video keeps no project, but the recorder still counted the clicks it drew")
    } catch {
        check(false, "a marked recording threw", detail: "\(error)")
    }

    do {
        let gap = Set(30..<90)
        let plain = try await record("input-gap-plain", capture: all, marks: nil, skipping: gap)
        let (_, url, marked) = try await record("input-gap", capture: all, marks: marks, skipping: gap)
        let plainFrames = try await inspectVideo(plain.1).frames, markedFrames = try await inspectVideo(url).frames
        check(plainFrames == 90, "without marks the file has only the 90 pictures that came", detail: "\(plainFrames)")
        check(marked.filled > 20 && markedFrames == 90 + marked.filled, "with marks, the slots in the gap where a mark changed are filled from the last picture",
              detail: "filled \(marked.filled), file \(markedFrames) frames")
        if let mid = await frame(of: url, at: 0.6), let cleared = await frame(of: url, at: 1.0) {
            check(lemon(in: mid, y: ringY, x0: ringX + 8, x1: ringX + 22), "so the ring still grows and fades while the screen is still")
            check(!lemon(in: cleared, y: ringY, x0: ringX + 8, x1: ringX + 22), "and a clean picture follows once it is gone, instead of a frozen ring")
        } else { check(false, "frames of the filled gap") }
    } catch {
        check(false, "the gap recording threw", detail: "\(error)")
    }

    section("live input boundary")
    let area = CGRect(x: 0, y: 0, width: 800, height: 600)
    let mainHeight = CGDisplayBounds(CGMainDisplayID()).height
    func key(_ code: CGKeyCode, _ flags: CGEventFlags, repeating: Bool = false) -> CGEvent? {
        let e = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true)
        e?.flags = flags
        if repeating { e?.setIntegerValueField(.keyboardEventAutorepeat, value: 1) }
        return e
    }
    func reading(_ e: CGEvent?, _ type: CGEventType, _ capture: InputCapture = all, secure: Bool = false) -> InputReading? {
        e.flatMap { LiveInputSource.reading($0, type: type, capture: capture, area: area, secureInput: secure, time: 3) }
    }
    if case .key(let k)? = reading(key(1, .maskCommand), .keyDown) {
        check(k.label == "\u{2318}S" && k.isCommand && k.t == 3, "a Command key press becomes a shortcut label", detail: "\(k)")
    } else { check(false, "a Command key press becomes a shortcut label") }
    check(reading(key(1, .maskCommand), .keyDown, secure: true) == nil, "no key is kept while secure input is on, as in a password field")
    check(reading(key(1, .maskCommand, repeating: true), .keyDown) == nil, "a held key's repeats are left out")
    check(reading(key(1, []), .keyDown, InputCapture(clicks: true, keys: .shortcuts)) == nil, "Shortcuts only leaves out a typed key at the source")
    check(reading(key(1, .maskCommand), .keyDown, InputCapture(clicks: true)) == nil, "keys off keeps no key")
    let inside = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: CGPoint(x: 100, y: mainHeight - 500), mouseButton: .left)
    check(reading(inside, .leftMouseDown) == .click(ClickEvent(t: 3, x: 100, y: 100)), "a click inside the area is kept in its points, top-left origin",
          detail: "\(String(describing: reading(inside, .leftMouseDown)))")
    let outside = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: CGPoint(x: 900, y: mainHeight - 500), mouseButton: .left)
    check(reading(outside, .leftMouseDown) == nil, "a click outside the area is left out")
    check(LiveInputSource.tapsCreated == 0, "no event tap was created in this run", detail: "\(LiveInputSource.tapsCreated)")
}
