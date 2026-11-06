import AppKit
import AVFoundation
import CornermarkCapture
import CornermarkCore
@testable import CornermarkShell

@MainActor
enum InputFilm {
    private static var out: URL!
    private static let screen = CGRect(x: 120, y: 120, width: 1040, height: 585)

    static func run(out: URL) async -> Bool {
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        self.out = out
        var ok = true
        for (name, scene) in [("R12", r12), ("R13", r13), ("R14", r14), ("R15", r15)] as [(String, (Film) async throws -> Void)] {
            guard let film = Film(url: out.appendingPathComponent("\(name).mp4")) else { return false }
            do { try await scene(film) } catch { film.failures.append("\(error)") }
            let frames = await film.finish()
            print("FILM \(name).mp4 frames=\(frames) failures=\(film.failures)")
            ok = ok && frames > 0 && film.failures.isEmpty
        }
        return ok
    }

    static func r12(_ f: Film) async throws {
        f.title = "R12  Click highlight: a ring where you click, in five colors, outline or filled, three sizes, animated or still."
        let (w, _) = try recordingWorld(scale: 1, frames: 150)
        defer { w.cleanup() }
        let sw = try openInputSettings(f, w, at: "recording.clicks")
        keepPage(sw, as: "R12-pane")
        f.hold(1.5, "Settings > Recording > Clicks. Highlight clicks is off by default.")
        f.toggle("recording.clicks", in: sw, note: "Highlight clicks: on")
        f.hold(1.2, "Ring options wake up: color, style and size, and Animate clicks.")
        try await recordAndPlay(f, w, "display=1&style=video", keep: "R12-default", seconds: 2.5,
                                note: "Record MP4 with the defaults: an animated lemon outline ring at each scripted click.")
        f.layers = { [unowned f] in f.windowLayer(sw.window!, at: f.settingsOrigin) }
        f.refresh()
        f.choose("recording.clickColor", 3, in: sw, note: "Color: Red")
        f.choose("recording.clickStyle", 1, in: sw, note: "Style: Filled")
        f.choose("recording.clickSize", 2, in: sw, note: "Size: Large")
        try await recordAndPlay(f, w, "display=1&style=video", keep: "R12-red-filled-large", seconds: 2.5,
                                note: "The next video: large filled red rings.")
        f.layers = { [unowned f] in f.windowLayer(sw.window!, at: f.settingsOrigin) }
        f.refresh()
        f.choose("recording.clickColor", 1, in: sw, note: "Color: White")
        f.choose("recording.clickStyle", 0, in: sw, note: "Style: Outline")
        f.choose("recording.clickSize", 0, in: sw, note: "Size: Small")
        f.toggle("recording.clickAnimation", in: sw, note: "Animate clicks: off")
        try await recordAndPlay(f, w, "display=1&style=video", keep: "R12-white-still", seconds: 2.5, slow: true,
                                note: "Small white rings that keep their size, shown at a quarter speed.")
        f.layers = { [unowned f] in f.windowLayer(sw.window!, at: f.settingsOrigin) }
        f.dark = true
        f.refresh()
        f.hold(2.5, "The same pane in Dark appearance.")
    }

    static func r13(_ f: Film) async throws {
        f.title = "R13  A click ring is short-lived: it grows and fades within 0.4 s of the press."
        let (w, _) = try recordingWorld(scale: 1, frames: 330)
        defer { w.cleanup() }
        let sw = try openInputSettings(f, w, at: "recording.clicks")
        f.toggle("recording.cursor", in: sw, note: "Show cursor: off, so only the ring changes the picture for the measurement")
        scrollPane(sw, to: "recording.clicks")
        f.refresh()
        f.toggle("recording.clicks", in: sw, note: "Highlight clicks: on, animated, the default")
        try await recordAndPlay(f, w, "display=1&style=video", keep: "R13-recorded", seconds: 5.5,
                                note: "Record MP4 of the whole fixture display. Clicks at 0.3, 1.9, 3.5 and 5.1 s.")
        try await replay(f, "R13-recorded", from: 1.7, to: 2.5, speed: 0.1,
                         note: "The click at 1.9 s at a tenth of the speed: the ring grows from 60% and fades out by 2.3 s.")
    }

    static func r14(_ f: Film) async throws {
        f.title = "R14  Keystrokes: position, size, dark or light style, all keys or shortcuts only."
        let (w, _) = try recordingWorld(scale: 1, frames: 330)
        defer { w.cleanup() }
        let sw = try openInputSettings(f, w, at: "recording.keys")
        keepPage(sw, as: "R14-pane")
        f.hold(1.5, "Settings > Recording > Keystrokes. Off by default; when on, Shortcuts only.")
        f.toggle("recording.keys", in: sw, note: "Show keystrokes: on")
        try await recordAndPlay(f, w, "display=1&style=video", keep: "R14-shortcuts", seconds: 5.5,
                                note: "Shortcuts only: the scripted ⇧⌘4 and ⌘S show; the typed word hello does not.")
        f.layers = { [unowned f] in f.windowLayer(sw.window!, at: f.settingsOrigin) }
        f.refresh()
        f.choose("recording.keyMode", 1, in: sw, note: "Keys: All keys")
        f.choose("recording.keyPosition", 3, in: sw, note: "Position: Top center")
        f.choose("recording.keySize", 2, in: sw, note: "Size: Large")
        f.choose("recording.keyStyle", 1, in: sw, note: "Style: Light")
        try await recordAndPlay(f, w, "display=1&style=video", keep: "R14-all-top-large-light", seconds: 5.5,
                                note: "All keys, top center, large, light: the typed word joins one badge.")
        f.layers = { [unowned f] in f.windowLayer(sw.window!, at: f.settingsOrigin) }
        f.refresh()
        f.choose("recording.keyPosition", 2, in: sw, note: "Position: Bottom right")
        f.choose("recording.keySize", 0, in: sw, note: "Size: Small")
        f.choose("recording.keyStyle", 0, in: sw, note: "Style: Dark")
        try await recordAndPlay(f, w, "display=1&style=video", keep: "R14-all-bottom-right-small-dark", seconds: 5.5,
                                note: "Bottom right, small, dark.")
        try await recordProject(f, w, note: "Record Project keeps the keys as a track in project.json, with these settings, and no badge in its video.")
        f.layers = { [unowned f] in f.windowLayer(sw.window!, at: f.settingsOrigin) }
        f.dark = true
        f.refresh()
        f.hold(2.5, "The same pane in Dark appearance.")
    }

    static func r15(_ f: Film) async throws {
        f.title = "R15  A keystroke badge grows in, stays about 1.6 s, then fades."
        let (w, _) = try recordingWorld(scale: 1, frames: 390)
        defer { w.cleanup() }
        let sw = try openInputSettings(f, w, at: "recording.keys")
        f.toggle("recording.cursor", in: sw, note: "Show cursor: off, so only the badge changes the picture for the measurement")
        scrollPane(sw, to: "recording.keys")
        f.refresh()
        f.toggle("recording.keys", in: sw, note: "Show keystrokes: on, Shortcuts only, the default")
        try await recordAndPlay(f, w, "display=1&style=video", keep: "R15-recorded", seconds: 6.5,
                                note: "Record MP4. Shortcuts at 0.9 s (⇧⌘4) and 4.6 s (⌘S).")
        try await replay(f, "R15-recorded", from: 0.8, to: 1.3, speed: 0.1,
                         note: "The entry at a tenth of the speed: it grows from 90% to full size in 0.2 s.")
        try await replay(f, "R15-recorded", from: 2.3, to: 2.9, speed: 0.25,
                         note: "The exit at a quarter speed: fully shown until 2.5 s, 1.6 s after the key, then gone by 2.7 s.")
    }

    private static func openInputSettings(_ f: Film, _ w: World, at id: String) throws -> SettingsWindowController {
        let sw = try f.openRecordingPane(w)
        f.status = { [unowned f] in
            let r = w.settings.value.recording
            return "clicks: \(r.clicks.isVisible ? "on" : "off") \(r.clicks.color.rawValue) \(r.clicks.style.rawValue) \(r.clicks.size.rawValue) animates=\(r.clicks.animates)"
                + "   keys: \(r.keystrokes.isVisible ? "on" : "off") \(r.keystrokes.keys.rawValue) \(r.keystrokes.position.rawValue) \(r.keystrokes.size.rawValue) \(r.keystrokes.theme.rawValue)"
                + "   cursor=\(r.showCursor)  results: \(f.results.count)"
        }
        scrollPane(sw, to: id)
        f.layers = { [unowned f] in f.windowLayer(sw.window!, at: f.settingsOrigin) }
        f.refresh()
        return sw
    }

    private static func scrollPane(_ sw: SettingsWindowController, to id: String) {
        guard let window = sw.window, let scroll = findView("settings.scroll", in: window.contentView) as? NSScrollView,
              let page = scroll.documentView, let target = findView(id, in: page) else { return }
        let y = target.convert(target.bounds, to: page).minY
        let top = page.isFlipped ? y - 110 : page.bounds.height - y - 110
        scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, top)))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    private static func keepPage(_ sw: SettingsWindowController, as name: String) {
        let page = sw.selectedPane.view
        for dark in [false, true] {
            page.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            page.layoutSubtreeIfNeeded()
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(page.bounds.width * 2), pixelsHigh: Int(page.bounds.height * 2), bitsPerSample: 8,
                                             samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { continue }
            rep.size = page.bounds.size
            let ctx = NSGraphicsContext(bitmapImageRep: rep)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = ctx
            (dark ? NSColor(white: 0.12, alpha: 1) : NSColor(white: 0.98, alpha: 1)).setFill()
            page.bounds.fill()
            NSGraphicsContext.restoreGraphicsState()
            page.cacheDisplay(in: page.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png"))
        }
        page.appearance = nil
    }

    private static func recordAndPlay(_ f: Film, _ w: World, _ query: String, keep name: String, seconds: Double, slow: Bool = false, note: String) async throws {
        f.hold(0.8, "Recording: cornermark://record?\(query)")
        guard let record = await recordOnce(w, query), let file = record.video?.file else { throw FilmError.missing("the recording \(name)") }
        let kept = out.appendingPathComponent("\(name).mp4")
        try? FileManager.default.removeItem(at: kept)
        try FileManager.default.copyItem(at: file, to: kept)
        let facts = await fileFacts(kept)
        print("RESULT \(name): \(facts.map { "\($0.width)x\($0.height) \($0.frames) frames \(Int($0.fps.rounded())) fps" } ?? "unreadable")")
        try await replay(f, name, from: 0, to: seconds, speed: slow ? 0.25 : 1, note: note)
    }

    private static func recordProject(_ f: Film, _ w: World, note: String) async throws {
        guard let record = await recordOnce(w, "display=1"), let folder = record.video?.location,
              let project = try? RecordingProjectFile.read(from: folder) else { throw FilmError.missing("the project") }
        let k = project.edits.keystrokes
        let keys = project.events.keys.map { String(format: "%.2f %@", $0.t, $0.label) }.joined(separator: ", ")
        f.status = { "project.json events.keys: \(keys)   edits.keystrokes: \(k.keys.rawValue) \(k.position.rawValue) \(k.size.rawValue) \(k.theme.rawValue)" }
        await f.show(record.video!.file, label: "Record Project", at: 3.0, extra: "  keys in project.json: \(project.events.keys.count), clicks: \(project.events.clicks.count)")
        f.layers = { [unowned f] in f.resultLayers() }
        f.refresh()
        f.hold(4, note)
    }

    private static func replay(_ f: Film, _ name: String, from: Double, to: Double, speed: Double, note: String) async throws {
        let file = out.appendingPathComponent("\(name).mp4")
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: file))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.maximumSize = CGSize(width: screen.width * 2, height: screen.height * 2)
        let previous = f.status
        f.glide(to: CGPoint(x: 1240, y: 40), note, frames: 8)
        let step = speed / Double(Film.fps)
        var t = from
        while t < to {
            guard let image = try? await generator.image(at: CMTime(seconds: t, preferredTimescale: 600)).image else { break }
            let box = playerCard(image, label: "\(name).mp4  \(String(format: "%.3f", t)) s\(speed < 1 ? String(format: "  (%.2gx speed)", speed) : "")")
            f.layers = { [(box, screen.insetBy(dx: -10, dy: -40).offsetBy(dx: 0, dy: 15))] }
            f.status = { "playing the recorded file at \(speed == 1 ? "full" : String(format: "%.2g", speed) + "x") speed, frame time \(String(format: "%.3f", t)) s" }
            f.refresh()
            f.hold(1 / Double(Film.fps), note)
            t += step
        }
        f.status = previous
    }

    private static func playerCard(_ frame: CGImage, label: String) -> CGImage {
        let size = CGSize(width: screen.width + 20, height: screen.height + 80)
        let s: CGFloat = 2
        let ctx = Pix.context(Int(size.width * s), Int(size.height * s))
        ctx.scaleBy(x: s, y: s)
        ctx.setFillColor(CGColor(gray: 0.06, alpha: 0.96))
        ctx.addPath(CGPath(roundedRect: CGRect(origin: .zero, size: size), cornerWidth: 12, cornerHeight: 12, transform: nil))
        ctx.fillPath()
        ctx.interpolationQuality = .high
        ctx.draw(frame, in: CGRect(x: 10, y: 10, width: screen.width, height: screen.height))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        ("Recorded file: \(label)" as NSString).draw(in: CGRect(x: 14, y: size.height - 52, width: size.width - 28, height: 24),
                                                     withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 15, weight: .semibold), .foregroundColor: NSColor.white])
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()!
    }
}
