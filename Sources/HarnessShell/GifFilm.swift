import AppKit
import CornermarkCapture
import CornermarkCore
import ImageIO
@testable import CornermarkShell

/// Films GIF recording and conversion for review, with the same stage as the controls film: the real control bar, Quick Access cards
/// and History rendered offscreen over the fixture display, and the GIFs they wrote played back frame by frame at their own delays.
/// Run with `CORNERMARK_GIF_FILM=<folder> swift run HarnessShell`. `CORNERMARK_INSTANCE_GIF=<file>` adds a GIF that a scripted
/// instance recorded, played back at the end of R7.
@MainActor
enum GifFilm {
    /// Where the film keeps a copy of each GIF it shows, since the harness world deletes its own files.
    private static var kept: URL?

    static func run(out: URL, instanceGif: URL?) async -> Bool {
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        kept = out
        var ok = true
        for (name, scene) in [("R7", { try await record($0, instanceGif) }), ("X8", convert)] as [(String, (Film) async throws -> Void)] {
            guard let film = Film(url: out.appendingPathComponent("\(name).mp4")) else { return false }
            do { try await scene(film) } catch { film.failures.append("\(error)") }
            let frames = await film.finish()
            print("FILM \(name).mp4 frames=\(frames) failures=\(film.failures)")
            ok = ok && frames > 0 && film.failures.isEmpty
        }
        return ok
    }

    static func record(_ f: Film, _ instanceGif: URL?) async throws {
        f.title = "R7  Record GIF. It films like a video, with the same controls, and ends as an animated GIF without the paused part."
        let s = try Stage(f)
        defer { s.m.world.cleanup() }
        let w = s.w, c = s.c
        f.hold(1.2, "The screen before recording. Left: the screen. Right: the GIF that the recording wrote.")
        try await s.start("display=1&x=80&y=120&width=960&height=540&style=gif",
                          note: "Record GIF (Option-Return in the overlay): cornermark://record?display=1&x=80&y=120&width=960&height=540&style=gif")
        let pending = w.env.recordingJournal?.entries().first
        s.extra = { "journal: \(pending.map { "\($0.format.rawValue) \($0.location.lastPathComponent)" } ?? "none")" }
        s.run(2.5, "Recording a GIF. The control bar and the menu bar time work as for a video.")
        try s.press(\.pause, "Pause")
        s.run(2, "Paused for 2 s. Nothing is filmed.")
        try s.press(\.resume, "Resume")
        s.run(2, "Recording again.")
        try s.press(\.stop, "Stop")
        f.hold(0.4, "Stopped. The GIF is made from the filmed video.")
        guard await waitUntil(15, { s.m.phase == .idle && w.store.list().count == 1 }), let record = w.store.list().first, let video = record.video,
              let facts = gifFileFacts(video.file) else { throw FilmError.missing("the GIF") }
        keep(video.file, as: "R7-recorded.gif")
        let saved = (try? FileManager.default.contentsOfDirectory(atPath: w.saveDir.path)) ?? []
        s.extra = { "save folder: \(saved.joined(separator: ", "))  journal entries: \(w.env.recordingJournal?.entries().count ?? -1)" }
        f.refresh()
        f.play(gif: video.file, label: "Record GIF", facts: describe(video.file, facts), seconds: 6,
               note: "\(facts.frames) frames, \(String(format: "%.2f", facts.duration)) s: the 4.5 s recorded, the 2 s pause left out. Loops forever.")

        f.layers = { f.cardLayers(w) + f.magnified(w) }
        f.status = { "history: \(w.store.list().count) entry, format=\(video.format.rawValue) location=\(video.location.lastPathComponent)  cards: \(c.overlay.stack.count)" }
        f.refresh()
        f.hold(2, "Its Quick Access card: the first frame, GIF, the length and the size.")
        if let card = c.overlay.card(forRecord: record.id), let view = c.overlay.cardView(for: card), let panel = c.overlay.panel(for: card) {
            f.glide(to: CGPoint(x: panel.frame.midX, y: panel.frame.midY), "Pointing at the card")
            view.mouseEntered(with: Synth.enterExit(.mouseEntered, in: panel))
            f.refresh()
            f.hold(1.5, "Copy, Play, Reveal in Finder and Close. A GIF is already a GIF, so there is no Convert to GIF.")
            f.press(view.buttons[.copy]!, in: panel, note: "Copy")
            let copied = (w.pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL])?.first?.lastPathComponent ?? "nothing"
            f.hold(1.6, "Copied: the pasteboard holds the file \(copied)")
            f.press(view.buttons[.play]!, in: panel, note: "Play")
            f.hold(1.4, "Play opens \(w.opened.last?.lastPathComponent ?? "nothing") in the default viewer.")
            view.mouseExited(with: Synth.enterExit(.mouseExited, in: panel))
        } else { f.failures.append("no card for the GIF") }
        try await showHistory(f, w, select: record.id, note: "History lists it as GIF with a stack glyph on its picture.")

        if let instanceGif, let facts = gifFileFacts(instanceGif) {
            f.layers = { f.resultLayers() }
            f.status = { "file from the scripted Cornermark Dev instance: \(instanceGif.lastPathComponent)" }
            f.refresh()
            f.play(gif: instanceGif, label: "Cornermark Dev instance", facts: describe(instanceGif, facts), seconds: 6,
                   note: "The same link sent to a running Cornermark Dev instance with link.sh wrote this GIF of its synthetic display.")
        }
    }

    static func convert(_ f: Film) async throws {
        f.title = "X8  Convert a finished recording to GIF, from its Quick Access card or from History. The video stays as it is."
        let (w, _) = try recordingWorld(frames: 90)
        defer { w.cleanup() }
        let c = w.coordinator
        f.layers = { f.cardLayers(w) + f.magnified(w) }
        f.status = { "history: \(w.store.list().count) entries  cards: \(c.overlay.stack.count)  converting: \(c.makingGifs.count)" }
        f.hold(1.2, "The desktop. Nothing is recording.")
        await f.record(w, "display=1&x=0&y=0&width=960&height=540&style=video", label: nil, note: "Record Video runs, then stops")
        guard let video = w.store.list().first, let file = video.video?.file, let card = c.overlay.card(forRecord: video.id),
              let view = c.overlay.cardView(for: card), let panel = c.overlay.panel(for: card) else { throw FilmError.missing("the video card") }
        let hash = sha256(file)
        f.hold(1.5, "A video's card.")
        f.glide(to: CGPoint(x: panel.frame.midX, y: panel.frame.midY), "Pointing at the card")
        view.mouseEntered(with: Synth.enterExit(.mouseEntered, in: panel))
        f.refresh()
        f.hold(1.5, "Hovering shows Copy, Play, Convert to GIF and Reveal in Finder.")
        f.press(view.buttons[.makeGif]!, in: panel, note: "Convert to GIF")
        f.hold(0.5, "HUD: \(c.hud.lastMessage ?? "none")")
        await converting(f, c)
        view.mouseExited(with: Synth.enterExit(.mouseExited, in: panel))
        f.glide(to: CGPoint(x: 600, y: 420), "Moving away")
        guard let gif = w.store.list().first(where: { $0.video?.format == .gif }), let gifFile = gif.video?.file, let facts = gifFileFacts(gifFile) else {
            throw FilmError.missing("the converted GIF")
        }
        keep(gifFile, as: "X8-converted.gif")
        f.refresh()
        f.hold(2.2, "The GIF gets its own card above the video's: GIF, its length and size.")
        f.layers = { f.cardLayers(w) + f.resultLayers() }
        f.status = { "video \(file.lastPathComponent) sha256 \(String(hash?.prefix(12) ?? "?")) before, \(String(sha256(file)?.prefix(12) ?? "?")) after   GIF \(gifFile.lastPathComponent)" }
        f.refresh()
        f.play(gif: gifFile, label: "Converted from the card", facts: describe(gifFile, facts), seconds: 5,
               note: "\(facts.frames) frames, 15 fps, \(facts.width) x \(facts.height), beside the video under the same name. The video's hash is unchanged.")

        let project = await recordOnce(w, "display=1&x=0&y=0&width=960&height=540")
        f.refresh()
        f.hold(1.5, "A Record for Editing project: its card has no Convert to GIF, because its pointer is not in its video.")
        try await showHistory(f, w, select: video.id, note: "History: the video selected. Convert to GIF is on.")
        guard let h = c.history, let hw = h.window, let button = h.actionButtons["gif"] else { throw FilmError.missing("Convert to GIF in History") }
        f.glide(to: f.center(of: button, in: hw, at: f.historyOrigin), "Convert to GIF in the action bar")
        button.isHighlighted = true
        f.refresh()
        f.hold(0.2, "Convert to GIF")
        button.isHighlighted = false
        button.performClick(nil)
        await converting(f, c)
        h.reload()
        if let second = w.store.list().first(where: { $0.video?.location.lastPathComponent.hasSuffix(" 2.gif") == true }) { h.select(recordIDs: [second.id]) }
        f.refresh()
        _ = await waitUntil(3) { h.records.allSatisfy { c.thumbnails.cached($0.id, maxPixel: HistoryWindowController.thumbnailPixels) != nil } }
        f.refresh()
        f.hold(2.5, "A second GIF, named \" 2\" so the first is kept. With a GIF selected, Convert to GIF is off.")
        if let project { h.select(recordIDs: [project.id]) }
        f.refresh()
        f.hold(2, "With the project selected it is off too.")
        f.dark = true
        f.refresh()
        f.hold(2.5, "The same in Dark appearance.")
    }

    /// Films while a conversion runs. The film's frames are drawn on the main actor, so it sleeps between them to let the conversion finish.
    private static func converting(_ f: Film, _ c: AppCoordinator) async {
        while !c.makingGifs.isEmpty {
            f.hold(0.1, "Converting to GIF")
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private static func showHistory(_ f: Film, _ w: World, select id: UUID, note: String) async throws {
        let c = w.coordinator
        c.perform(.openHistory)
        guard let h = c.history, let hw = h.window else { throw FilmError.missing("History") }
        hw.setContentSize(NSSize(width: 920, height: 640))
        f.historyOrigin = CGPoint(x: 120, y: 90)
        f.layers = { f.cardLayers(w) + f.windowLayer(hw, at: f.historyOrigin) }
        h.reload()
        _ = await waitUntil(3) { h.records.allSatisfy { c.thumbnails.cached($0.id, maxPixel: HistoryWindowController.thumbnailPixels) != nil } }
        h.reload()
        h.select(recordIDs: [id])
        f.status = { "History: \(h.records.map { $0.video.map { "\($0.format.rawValue) \($0.location.lastPathComponent)" } ?? "picture" }.joined(separator: " | "))" }
        f.refresh()
        f.hold(2.5, note)
    }

    private static func keep(_ file: URL, as name: String) {
        guard let kept else { return }
        let to = kept.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: to)
        try? FileManager.default.copyItem(at: file, to: to)
    }

    private static func describe(_ url: URL, _ facts: GifFileFacts) -> String {
        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        return "\(facts.width) x \(facts.height), \(facts.frames) frames, \(String(format: "%.2f", facts.duration)) s, loop \(facts.loopCount.map { $0 == 0 ? "forever" : "\($0)" } ?? "once"), \(bytes / 1024) KB"
    }
}

extension Film {
    /// Shows a GIF in the results column, one GIF frame after another at the GIF's own delays, looping, for `seconds` of film.
    func play(gif url: URL, label: String, facts: String, seconds: Double, note: String) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return failures.append("no GIF at \(url.lastPathComponent)") }
        let n = CGImageSourceGetCount(source)
        var starts: [Double] = [], total = 0.0
        for i in 0..<n {
            starts.append(total)
            let gif = (CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [CFString: Any])?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            total += (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double) ?? 0.1
        }
        print("RESULT \(label): \(url.lastPathComponent) \(facts)")
        results.append((label, CGImageSourceCreateImageAtIndex(source, 0, nil), facts))
        var shown = 0
        for k in 0..<Int(seconds * Double(Self.fps)) {
            let t = (Double(k) / Double(Self.fps)).truncatingRemainder(dividingBy: max(total, 0.01))
            let i = starts.lastIndex { $0 <= t } ?? 0
            if i != shown {
                results[results.count - 1].frame = CGImageSourceCreateImageAtIndex(source, i, nil)
                refresh()
                shown = i
            }
            frame("\(note)   [GIF frame \(i + 1) of \(n)]")
        }
    }
}
