import AppKit
import AVFoundation
import CornermarkCapture
import CornermarkCore
import CornermarkDesign
import IOKit.pwr_mgt
@testable import CornermarkShell

/// Films the recording controls for review. The left of each frame is the screen: the fixture display, drawn live at 62%, with the real
/// control bar, countdown, dimming and menu bar button rendered from the app's own views at the places the app computes. The right is
/// the video: frames lifted from the files the recordings wrote. A recording's frames arrive in step with the film, two per film frame.
/// Run with `CORNERMARK_CONTROLS_FILM=<folder> swift run HarnessShell`. With `CORNERMARK_RECOVERY_EVIDENCE=<folder>` holding a cut-off
/// recording copied from a killed instance and the recovered one, it also films R26.
@MainActor
enum ControlsFilm {
    static func run(out: URL, recovery: URL?) async -> Bool {
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var scenes: [(String, (Film) async throws -> Void)] = [
            ("R17-R21-R22-R29", bar), ("R20-R30", countdown), ("R23", dimming), ("R18-R19", exclusion), ("R24", displaySleep),
        ]
        if let recovery { scenes.append(("R26", { try await recovered($0, recovery) })) }
        var ok = true
        for (name, scene) in scenes {
            guard let film = Film(url: out.appendingPathComponent("\(name).mp4")) else { return false }
            do { try await scene(film) } catch { film.failures.append("\(error)") }
            let frames = await film.finish()
            print("FILM \(name).mp4 frames=\(frames) failures=\(film.failures)")
            ok = ok && frames > 0 && film.failures.isEmpty
        }
        return ok
    }

    // MARK: Scenes

    static func bar(_ f: Film) async throws {
        f.title = "R17 R21 R22 R29  The control bar and the menu bar time. Pause, resume, restart, stop. The bar is never in the video."
        let s = try Stage(f)
        defer { s.m.world.cleanup() }
        f.hold(1.2, "The screen before recording. Left: the screen. Right: frames from the recorded files.")
        try await s.start("display=1&x=80&y=120&width=960&height=540", note: "Record an area: cornermark://record?display=1&x=80&y=120&width=960&height=540")
        f.hold(1.0, "The bar enters under the area: 0.20 s fade and grow from 96%. The menu bar shows the record symbol and the time.")
        s.run(3, "Recording. The time counts in the bar and in the menu bar.")
        try s.press(\.pause, "Pause")
        s.run(2.5, "Paused: the red dot becomes a pause symbol, the time is muted and holds. Frames now are not recorded.")
        try s.press(\.resume, "Resume")
        s.run(2.5, "Recording again from where it paused.")
        let moved = CGPoint(x: 400, y: 40)
        s.glideBar(to: moved, "Dragging the bar by its background (scripted move of the real panel)")
        f.hold(1.2, "The bar stays where it was put: rememberedOrigin=\(s.c.controls.rememberedOrigin.map { "\(Int($0.x)),\(Int($0.y))" } ?? "nil")")
        try s.press(\.stop, "Stop")
        guard await waitUntil(10, { s.m.phase == .idle && s.w.store.list().count == 1 }), let video = s.w.store.list().first?.video else { throw FilmError.missing("the paused recording") }
        f.refresh()
        await f.show(video.file, label: "after pause and resume", at: 2.9, extra: "  duration \(String(format: "%.2f", video.duration)) s")
        f.hold(3, "The file runs \(String(format: "%.1f", video.duration)) s, the 2.5 s pause left out with no gap. At 2.9 s: just before the pause; no bar in it.")
        try await s.start("display=1", note: "Record the whole display: cornermark://record?display=1")
        f.hold(1.0, "A whole display: the bar returns to where it was dragged, over the recorded picture, and is still not filmed.")
        s.run(2, "Recording the full screen.")
        try s.press(\.restart, "Restart")
        s.run(1.2, "Restart throws the take away, so it asks once more in place: Discard take.")
        try s.press(\.confirmRestart, "Discard take")
        _ = await waitUntil { s.m.phase == .recording && s.c.recording.seconds == 0 }
        s.run(2, "Restart threw the first take away and began again at 0:00.")
        try s.press(\.stop, "Stop")
        guard await waitUntil(10, { s.m.phase == .idle && s.w.store.list().count == 2 }),
              let full = s.w.store.list().compactMap(\.video).first(where: { $0.location.lastPathComponent.hasSuffix(" 2") }) else { throw FilmError.missing("the restarted take") }
        f.refresh()
        await f.show(full.file, label: "full display after restart", at: 1.0, extra: "  duration \(String(format: "%.2f", full.duration)) s")
        f.hold(3.5, "Only the 2 s after the restart are in the file. The bar sat over this picture and is absent: sharingType=none.")
    }

    static func countdown(_ f: Film) async throws {
        f.title = "R20 R30  Countdown option and start and stop feedback. Countdown: Off, 3, 5 or 10 seconds. No sound."
        let s = try Stage(f)
        defer { s.m.world.cleanup() }
        try await s.openPane()
        f.choose("recording.countdown", 1, in: s.c.settingsWindow!, note: "Countdown: 3 seconds")
        s.layersWithoutSettings()
        // The countdown runs on its own task, so each number is filmed once the task has shown it.
        s.c.recording.countdownTick = 0.3
        _ = s.m.link("record?display=1&x=80&y=120&width=960&height=540")
        for n in [3, 2, 1] {
            _ = await waitUntil { s.m.phase == .countingDown(n) }
            s.c.controls.update()
            f.refresh()
            f.hold(1.0, "Countdown \(n): the card sits on the area. The bar offers Cancel only. Nothing is recorded yet.")
        }
        _ = await waitUntil(5) { s.m.phase == .recording }
        f.refresh()
        f.hold(0.8, "Recording starts: the card closes, the record symbol turns red in the bar and the menu bar.")
        s.run(2.5, "Recording.")
        try s.press(\.stop, "Stop")
        guard await waitUntil(10, { s.m.phase == .idle && s.w.store.list().count == 1 }), let video = s.w.store.list().first?.video else { throw FilmError.missing("the recording") }
        f.refresh()
        f.hold(1.0, "Stop: the bar and the dimming fade out in 0.15 s, the menu bar goes back to the viewfinder.")
        await f.show(video.file, label: "after a 3 s countdown", at: 0.1, extra: "  sounds played: \(s.w.sounds)")
        f.hold(3, "The file starts at the first frame after the countdown. No sound plays at start or stop: sounds played = \(s.w.sounds).")
        s.c.recording.countdownTick = 5
        _ = s.m.link("record?display=1&x=80&y=120&width=960&height=540")
        _ = await waitUntil { s.m.phase == .countingDown(3) }
        s.c.controls.update()
        f.refresh()
        f.hold(1.2, "Another countdown.")
        try s.press(\.stop, "Cancel")
        _ = await waitUntil(5) { s.m.phase == .idle }
        f.refresh()
        f.hold(2.5, "Cancel during the countdown: no file, no folder. History still has \(s.w.store.list().count) recording.")
    }

    static func dimming(_ f: Film) async throws {
        f.title = "R23  Dim outside the area while it records, with a setting to turn it off. The dimming is never in the video."
        let s = try Stage(f)
        defer { s.m.world.cleanup() }
        try await s.start("display=1&x=80&y=120&width=960&height=540", note: "Record an area with Dim outside the area on (the default)")
        s.run(2.5, "Everything outside the area is darkened with the scrim token and outlined. Clicks pass through.")
        try s.press(\.stop, "Stop")
        guard await waitUntil(10, { s.m.phase == .idle && s.w.store.list().count == 1 }), let dimmed = s.w.store.list().first?.video else { throw FilmError.missing("the dimmed take") }
        await f.show(dimmed.file, label: "dimming on", at: 1.0)
        f.hold(2, "The recorded area is clean: the dimming is outside it and is never filmed.")
        try await s.openPane()
        f.toggle("recording.dim", in: s.c.settingsWindow!, note: "Dim outside the area: off")
        s.layersWithoutSettings()
        try await s.start("display=1&x=80&y=120&width=960&height=540", note: "The same area with dimming off")
        s.run(2.5, "No darkening now. The bar is still there.")
        try s.press(\.stop, "Stop")
        guard await waitUntil(10, { s.m.phase == .idle && s.w.store.list().count == 2 }) else { throw FilmError.missing("the undimmed take") }
        if let plain = s.w.store.list().compactMap(\.video).first(where: { $0.location.lastPathComponent.hasSuffix(" 2") }) { await f.show(plain.file, label: "dimming off", at: 1.0) }
        f.hold(3, "Both files show the same clean area. Dimming changes the screen only.")
    }

    static func exclusion(_ f: Film) async throws {
        f.title = "R18 R19  Hide desktop icons and hide notifications. Test-owned fake windows on the fixture display, filtered by the same plan as the live filter."
        let s = try Stage(f, windows: SyntheticScene.otherWindows(on: FixtureFrameSource.displayFrame.size))
        defer { s.m.world.cleanup() }
        f.hold(2, "On screen: a fake banner (top right), three fake desktop icons, a fake Finder window. All are drawn by the test.")
        try await s.start("display=1", note: "Defaults: Hide notifications on, Hide desktop icons off")
        s.run(2, "Recording the whole display.")
        try s.press(\.stop, "Stop")
        guard await waitUntil(10, { s.m.phase == .idle && s.w.store.list().count == 1 }), let first = s.w.store.list().first?.video else { throw FilmError.missing("the default take") }
        await f.show(first.file, label: "defaults", at: 1.0, extra: "  plan: \(s.plan())")
        f.hold(3.5, "R19: the banner is on screen but not in the video. Notification Center's process is excluded; Focus is not touched.")
        try await s.openPane()
        f.toggle("recording.desktopIcons", in: s.c.settingsWindow!, note: "Hide desktop icons: on")
        s.layersWithoutSettings()
        try await s.start("display=1", note: "Hide desktop icons on")
        s.run(2, "Recording the whole display again.")
        try s.press(\.stop, "Stop")
        guard await waitUntil(10, { s.m.phase == .idle && s.w.store.list().count == 2 }),
              let second = s.w.store.list().compactMap(\.video).first(where: { $0.location.lastPathComponent.hasSuffix(" 2") }) else { throw FilmError.missing("the second take") }
        await f.show(second.file, label: "icons hidden", at: 1.0, extra: "  plan: \(s.plan())")
        f.hold(3.5, "R18: the icons are on screen but not in the video. Finder is excluded except its normal windows, so its window stays.")
        try await s.openPane()
        f.toggle("recording.notifications", in: s.c.settingsWindow!, note: "Hide notifications: off")
        s.layersWithoutSettings()
        try await s.start("display=1", note: "Hide notifications off")
        s.run(2, "Recording.")
        try s.press(\.stop, "Stop")
        guard await waitUntil(10, { s.m.phase == .idle && s.w.store.list().count == 3 }),
              let third = s.w.store.list().compactMap(\.video).first(where: { $0.location.lastPathComponent.hasSuffix(" 3") }) else { throw FilmError.missing("the third take") }
        await f.show(third.file, label: "notifications shown", at: 1.0, extra: "  plan: \(s.plan())")
        f.hold(3.5, "With the setting off the banner is filmed. No system setting, Focus state or Finder preference was changed.")
    }

    static func displaySleep(_ f: Film) async throws {
        f.title = "R24  The display stays awake while recording. The harness process's own power assertions, read live from pmset."
        let s = try Stage(f)
        defer { s.m.world.cleanup() }
        s.extra = { "pmset: " + pmsetLines() }
        f.hold(2, "Before recording: this process holds no display sleep assertion.")
        try await s.start("display=1&x=80&y=120&width=960&height=540", note: "Recording starts")
        s.run(2.5, "While recording: PreventUserIdleDisplaySleep named \"Recording the screen\".")
        try s.press(\.pause, "Pause")
        s.run(2, "A pause keeps it: the display must stay awake to resume.")
        try s.press(\.resume, "Resume")
        s.run(1, "Recording.")
        try s.press(\.stop, "Stop")
        _ = await waitUntil(10) { s.m.phase == .idle && s.w.store.list().count == 1 }
        f.refresh()
        f.hold(3, "After stop: the assertion is released. pmset lists nothing for this process.")
    }

    static func recovered(_ f: Film, _ dir: URL) async throws {
        f.title = "R26  Recovery after a crash, in an isolated Cornermark Dev: killed by its PID mid-recording, relaunched on the same root."
        let cut = dir.appendingPathComponent("r26-cut-off-copy/screen.mp4")
        let saved = try FileManager.default.contentsOfDirectory(at: dir.appendingPathComponent("r26-isolated/saved"), includingPropertiesForKeys: nil)
        guard let project = saved.first(where: { $0.lastPathComponent.hasSuffix("23.02.33") }) else { throw FilmError.missing("the recovered project") }
        let log = (try? String(contentsOf: dir.appendingPathComponent("r26-first-instance-app.log"), encoding: .utf8)) ?? ""
        let relaunch = (try? String(contentsOf: dir.appendingPathComponent("r26-isolated/app.log"), encoding: .utf8)) ?? ""
        let lines = (log + relaunch).split(separator: "\n").filter { $0.contains("recording started") || $0.contains("recover") || $0.contains("launch pid") || $0.contains("listed") || $0.contains("Recovered") }
            .map { line -> String in
                let text = String(line)
                guard let r = text.range(of: "[local.emretufan.cornermark:shell] ") else { return text }
                return String(text[text.index(text.startIndex, offsetBy: 11)..<text.index(text.startIndex, offsetBy: 23)]) + "  " + String(text[r.upperBound...])
            }
        let killed = "23:02:47.000  kill -9 98524 (the instance's own PID, binary checked), file still open"
        var shown: [String] = []
        f.layers = { [unowned f] in logLayer(shown) + f.resultLayers() }
        f.refresh()
        // The kill is the one event the app could not log, so it is placed by its time among the app's lines.
        for line in (lines + [killed]).sorted() {
            shown.append(line)
            f.refresh()
            f.hold(1.4, "The app's own log, in order.")
        }
        await f.show(cut, label: "cut off by the kill (copy taken before relaunch)", at: 13.5, extra: "  no project.json, fragmented")
        f.hold(3, "The writer closes an MP4 fragment every second, so the killed file still plays to its last second: 840 frames, 14.0 s.")
        await f.show(project.appendingPathComponent("screen.mp4"), label: "recovered at the next launch", at: 13.5, extra: "  + project.json, listed in History")
        f.hold(4, "At launch the journal names it: the file is rewritten without fragments, project.json is written, History lists it.")
    }

    // MARK: Pieces

    private static func pmsetLines() -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        p.arguments = ["-g", "assertions"]
        let pipe = Pipe()
        p.standardOutput = pipe
        try? p.run()
        p.waitUntilExit()
        let me = "pid \(ProcessInfo.processInfo.processIdentifier)("
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let mine = out.split(separator: "\n").filter { $0.contains(me) }.map { line in
            line.split(separator: "]").last.map { String($0).trimmingCharacters(in: .whitespaces) } ?? String(line)
        }
        return mine.isEmpty ? "no assertion held by pid \(ProcessInfo.processInfo.processIdentifier)" : mine.joined(separator: " | ")
    }

    private static func logLayer(_ lines: [String]) -> [(CGImage, CGRect)] {
        let box = CGRect(x: 16, y: 200, width: 860, height: 560)
        let s: CGFloat = 2
        let ctx = Pix.context(Int(box.width * s), Int(box.height * s))
        ctx.scaleBy(x: s, y: s)
        ctx.setFillColor(CGColor(gray: 0.08, alpha: 1))
        ctx.addPath(CGPath(roundedRect: CGRect(origin: .zero, size: box.size), cornerWidth: 10, cornerHeight: 10, transform: nil))
        ctx.fillPath()
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        ("Cornermark Dev log (isolated instance)" as NSString).draw(at: CGPoint(x: 14, y: box.height - 30), withAttributes: [.font: NSFont.systemFont(ofSize: 14, weight: .semibold), .foregroundColor: NSColor.white])
        let mono: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular), .foregroundColor: NSColor(white: 0.85, alpha: 1)]
        var y = box.height - 60
        for line in lines {
            let r = CGRect(x: 14, y: y - 34, width: box.width - 28, height: 44)
            (line as NSString).draw(with: r, options: [.usesLineFragmentOrigin], attributes: mono)
            y -= 52
        }
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage().map { [($0, box)] } ?? []
    }
}

/// The left half of a controls film: the fixture display, live, with the app's recording windows on it, and a menu bar strip.
@MainActor
private final class Stage {
    static let k: CGFloat = 0.62
    static let origin = CGPoint(x: 16, y: 226)
    static let menuHeight: CGFloat = 24

    let f: Film
    let m: ManualRecordingWorld
    var w: World { m.world }
    var c: AppCoordinator { w.coordinator }
    let windows: [FixtureWindow]
    var extra: () -> String = { "" }
    private var status: () -> String = { "" }
    private var time = 0.0
    private let statusButton = NSStatusBarButton(frame: CGRect(x: 0, y: 0, width: 120, height: 22))

    init(_ f: Film, windows: [FixtureWindow] = []) throws {
        self.f = f
        self.windows = windows
        m = try ManualRecordingWorld(windows: windows)
        c.recording.countdownTick = 0.05
        f.layers = { [unowned self] in layers() + f.resultLayers() }
        status = { [unowned self] in
            let st = c.controls.status
            let bar = c.controls.bar.map { "bar sharingType=\($0.sharingType == .none ? "none" : "readOnly") level=\($0.level.rawValue)" } ?? "no bar"
            let dim = c.controls.dim.map { "dim sharingType=\($0.sharingType == .none ? "none" : "readOnly")" } ?? "no dim"
            let more = extra()
            return "phase=\(st.phase) video=\(String(format: "%.2f", st.seconds)) s  \(bar)  \(dim)" + (more.isEmpty ? "" : "  \(more)")
        }
        f.status = status
        f.refresh()
    }

    func toStage(_ r: CGRect) -> CGRect {
        CGRect(x: Self.origin.x + r.minX * Self.k, y: Self.origin.y + r.minY * Self.k, width: r.width * Self.k, height: r.height * Self.k)
    }

    /// The display as the user sees it, a strip for the menu bar holding the real status button, and the app's recording windows.
    private func layers() -> [(CGImage, CGRect)] {
        let display = FixtureFrameSource.displayFrame
        var out: [(CGImage, CGRect)] = []
        if let screen = screenImage(display.size) { out.append((screen, toStage(display))) }
        if let dim = c.controls.dimView {
            dim.frame = CGRect(origin: .zero, size: display.size)
            dim.hole = c.recording.area ?? .zero
            if let image = viewImage(dim) { out.append((image, toStage(display))) }
        }
        if let view = c.controls.countdownView, let area = c.recording.area, let image = viewImage(view) {
            let size = view.frame.size
            out.append((image, toStage(CGRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2, width: size.width, height: size.height))))
        }
        if let bar = c.controls.bar, let view = c.controls.barView, let image = viewImage(view) {
            out.append((image, toStage(bar.frame)))
            // The bar again at full size, so its glyphs read in the film.
            out.append((image, CGRect(x: Self.origin.x, y: 150, width: view.frame.width, height: view.frame.height)))
        }
        applyStatusLabel(c.updates.state, recording: c.controls.status, to: statusButton)
        statusButton.sizeToFit()
        if let strip = menuStrip(width: display.width * Self.k) {
            out.append((strip, CGRect(x: Self.origin.x, y: Self.origin.y + display.height * Self.k, width: display.width * Self.k, height: Self.menuHeight)))
        }
        return out
    }

    private func screenImage(_ size: CGSize) -> CGImage? {
        let ctx = Pix.context(Int(size.width), Int(size.height))
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        SyntheticScene.draw(size: size, time: time)
        windows.forEach { $0.draw() }
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }

    private func menuStrip(width: CGFloat) -> CGImage? {
        let s: CGFloat = 2
        let h = Self.menuHeight
        let ctx = Pix.context(Int(width * s), Int(h * s))
        ctx.scaleBy(x: s, y: s)
        ctx.setFillColor(CGColor(gray: 0.15, alpha: 0.92))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: h))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        ("Menu bar (harness strip)" as NSString).draw(at: CGPoint(x: 8, y: 5), withAttributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor(white: 0.6, alpha: 1)])
        NSGraphicsContext.restoreGraphicsState()
        // An offscreen status bar button draws its image but not its title, so a plain button carries the same image, title and font.
        let copy = NSButton(frame: .zero)
        copy.isBordered = false
        copy.image = statusButton.image
        copy.title = statusButton.title
        copy.font = statusButton.font
        copy.imagePosition = statusButton.imagePosition
        copy.contentTintColor = .white
        copy.appearance = NSAppearance(named: .darkAqua)
        copy.sizeToFit()
        if let button = viewImage(copy) {
            let bw = copy.frame.width, bh = copy.frame.height
            ctx.draw(button, in: CGRect(x: width - bw - 12, y: (h - bh) / 2, width: bw, height: bh))
        }
        return ctx.makeImage()
    }

    func viewImage(_ view: NSView) -> CGImage? {
        let s: CGFloat = 2
        view.layoutSubtreeIfNeeded()
        guard view.bounds.width > 0, let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width * s), pixelsHigh: Int(view.bounds.height * s),
                                                                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                                                bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = view.bounds.size
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.cgImage
    }

    /// Film time passes, the display moves, and the source delivers two 60 fps frames per film frame.
    func run(_ seconds: Double, _ note: String) {
        for _ in 0..<Int(seconds * Double(Film.fps)) {
            time += 1 / Double(Film.fps)
            try? m.source?.advance(2)
            c.controls.update()
            f.refresh()
            f.hold(1 / Double(Film.fps), note)
        }
    }

    func start(_ query: String, note: String) async throws {
        f.hold(0.6, note)
        guard m.link("record?\(query)"), await waitUntil(5, { m.phase == .recording }) else { throw FilmError.missing("a recording for \(query)") }
        c.controls.update()
        f.refresh()
    }

    func press(_ button: KeyPath<RecordingBarView, some NSButton>, _ note: String) throws {
        guard let bar = c.controls.bar, let view = c.controls.barView else { throw FilmError.missing("the bar") }
        let target = view[keyPath: button]
        let r = toStage(CGRect(x: bar.frame.minX + target.frame.midX, y: bar.frame.minY + target.frame.midY, width: 0, height: 0))
        f.glide(to: r.origin, note, frames: 12)
        target.isHighlighted = true
        f.refresh()
        f.hold(0.2, note)
        target.isHighlighted = false
        target.performClick(nil)
        c.controls.update()
        f.refresh()
    }

    func glideBar(to origin: CGPoint, _ note: String) {
        guard let bar = c.controls.bar else { return }
        let a = bar.frame.origin
        for i in 1...20 {
            let t = CGFloat(i) / 20, e = t * t * (3 - 2 * t)
            bar.setFrameOrigin(CGPoint(x: a.x + (origin.x - a.x) * e, y: a.y + (origin.y - a.y) * e))
            time += 1 / Double(Film.fps)
            try? m.source?.advance(2)
            c.controls.update()
            f.refresh()
            f.glide(to: toStage(CGRect(origin: CGPoint(x: bar.frame.minX + 12, y: bar.frame.midY), size: .zero)).origin, note, frames: 1)
        }
    }

    func openPane() async throws {
        _ = try f.openRecordingPane(w)
        f.layers = { [unowned self] in layers() + f.windowLayer(c.settingsWindow!.window!, at: f.settingsOrigin) }
        f.status = status
        f.refresh()
    }

    func layersWithoutSettings() {
        c.settingsWindow?.window?.close()
        f.status = status
        f.layers = { [unowned self] in layers() + f.resultLayers() }
        f.refresh()
    }

    func plan() -> String {
        let e = w.settings.value.recording.options(for: .editing).exclusion
        let p = e.plan(apps: windows.map(\.app), windows: windows.map(\.window), ownPID: ProcessInfo.processInfo.processIdentifier)
        return "excluded pids \(p.excludedApps.sorted()) excepted windows \(p.exceptedWindows.sorted())"
    }
}
