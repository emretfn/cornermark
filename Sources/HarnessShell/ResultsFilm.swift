import AppKit
import AVFoundation
import CornermarkCapture
import CornermarkCore
@testable import CornermarkShell

/// Films the recording results for review: the real Settings, Quick Access and History views of a harness world, rendered offscreen
/// frame by frame over the synthetic desktop, driven by scripted clicks on their controls. Recordings come from the fixture display.
/// The pointer arrow, the caption strip and the frames lifted from each recorded file are drawn by this harness.
/// Run with `CORNERMARK_RESULTS_FILM=<folder> swift run HarnessShell`.
@MainActor
enum ResultsFilm {
    static func run(out: URL) async -> Bool {
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var ok = true
        for (name, scene) in [("R8", r8), ("R16", r16), ("R27", r27)] as [(String, (Film) async throws -> Void)] {
            guard let film = Film(url: out.appendingPathComponent("\(name).mp4")) else { return false }
            do { try await scene(film) } catch { film.failures.append("\(error)") }
            let frames = await film.finish()
            print("FILM \(name).mp4 frames=\(frames) failures=\(film.failures)")
            ok = ok && frames > 0 && film.failures.isEmpty
        }
        return ok
    }

    // MARK: Scenes

    static func r8(_ f: Film) async throws {
        f.title = "R8  Recording settings: frame rate, quality and resolution, with a largest-size limit. Each change reaches the next file."
        let (w, _) = try recordingWorld(frames: 45)
        defer { w.cleanup() }
        let sw = try f.openRecordingPane(w)
        f.hold(1.5, "Settings > Recording. Defaults: 60 fps, High, Retina, No limit.")
        await f.record(w, "display=1&x=0&y=0&width=960&height=540&style=video", label: "Defaults", note: "Record MP4 of a 960 x 540 pt area on a 2x display")
        f.hold(2.5, "Retina keeps every pixel: 1920 x 1080 at 60 fps.")
        f.choose("recording.fps", 0, in: sw, note: "Frame rate: 30 fps")
        f.choose("recording.quality", 2, in: sw, note: "Quality: Low")
        f.choose("recording.resolution", 1, in: sw, note: "Resolution: Standard")
        await f.record(w, "display=1&x=0&y=0&width=960&height=540&style=video", label: "30 fps, Low, Standard", note: "The same area again")
        f.hold(3, "Standard: one pixel per point, 960 x 540. 30 fps. Low quality asks the encoder for a quarter of the bit rate.")
        f.choose("recording.resolution", 0, in: sw, note: "Resolution: Retina again")
        f.choose("recording.limit", 4, in: sw, note: "Largest size: 720p")
        await f.record(w, "display=1&style=video", label: "Retina, 720p limit", note: "The whole 1280 x 720 pt display, 2560 x 1440 pixels")
        f.hold(3, "The 720p limit scales the 2560 x 1440 picture down to 1280 x 720, keeping its proportions.")
        f.dark = true
        f.refresh()
        f.hold(2.5, "The same pane in Dark appearance.")
    }

    static func r16(_ f: Film) async throws {
        f.title = "R16  Show or hide the cursor. Record MP4 draws it into the picture; Record Project keeps it as a track that starts shown or hidden."
        let (w, _) = try recordingWorld(frames: 45)
        defer { w.cleanup() }
        let sw = try f.openRecordingPane(w)
        f.hold(1.5, "Settings > Recording > Show cursor is on.")
        await f.record(w, "display=1&x=0&y=0&width=320&height=180&style=video", label: "Show cursor on", note: "Record MP4 with the cursor shown", at: 0.3)
        f.hold(2.5, "The cursor is part of the video's picture.")
        f.toggle("recording.cursor", in: sw, note: "Show cursor: off")
        await f.record(w, "display=1&x=0&y=0&width=320&height=180&style=video", label: "Show cursor off", note: "Record MP4 with the cursor hidden", at: 0.3)
        f.hold(2.5, "Same moment, same scene, no cursor in the picture.")
        await f.record(w, "display=1&x=0&y=0&width=320&height=180", label: "Project, cursor off", note: "Record Project with the cursor hidden", at: 0.3)
        f.hold(3, "Record Project never films the cursor. Its project starts with the cursor hidden and keeps the track to show later.")
        f.toggle("recording.cursor", in: sw, note: "Show cursor: on again")
        await f.record(w, "display=1&x=0&y=0&width=320&height=180", label: "Project, cursor on", note: "Record Project with the cursor shown", at: 0.3)
        f.hold(3, "Now its project starts with the cursor shown. The video itself is still cursor-free.")
        f.dark = true
        f.refresh()
        f.hold(2.5, "The same pane in Dark appearance.")
    }

    static func r27(_ f: Film) async throws {
        f.title = "R27  A finished recording shows a Quick Access card: its first frame, length and size, with Copy, Play, Reveal in Finder and Close."
        let (w, _) = try recordingWorld(frames: 150)
        defer { w.cleanup() }
        let c = w.coordinator
        f.layers = { f.cardLayers(w) + f.magnified(w) }
        f.hold(1.2, "The desktop. Nothing is recording.")
        await f.record(w, "display=1&x=0&y=0&width=960&height=540&style=video", label: nil, note: "Record MP4 runs, then stops")
        guard let video = w.store.list(filter: CaptureFilter(recordings: true)).first, let card = c.overlay.card(forRecord: video.id),
              let view = c.overlay.cardView(for: card), let panel = c.overlay.panel(for: card) else { throw FilmError.missing("the video card") }
        f.status = { "history: \(w.store.list().count) entries, newest video=\(video.video!.format.rawValue) \(ImageOutput.durationText(video.video!.duration))  cards: \(c.overlay.stack.count)" }
        f.hold(2, "The card appears in the corner: the first frame, 0:02, 1920 x 1080.")
        f.glide(to: CGPoint(x: panel.frame.midX, y: panel.frame.midY), "Pointing at the card")
        view.mouseEntered(with: Synth.enterExit(.mouseEntered, in: panel))
        f.refresh()
        f.hold(1.2, "Hovering shows its actions. The countdown pauses.")
        f.press(view.buttons[.copy]!, in: panel, note: "Copy")
        let copied = (w.pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL])?.first?.lastPathComponent ?? "nothing"
        f.hold(1.6, "Copied: the pasteboard holds the file \(copied)")
        f.press(view.buttons[.play]!, in: panel, note: "Play")
        f.hold(1.4, "Play opens \(w.opened.last?.lastPathComponent ?? "nothing") in the default player.")
        f.press(view.buttons[.reveal]!, in: panel, note: "Reveal in Finder")
        f.hold(1.4, "Reveal in Finder selects \(w.revealed.last?.lastPathComponent ?? "nothing").")
        view.mouseExited(with: Synth.enterExit(.mouseExited, in: panel))
        f.glide(to: CGPoint(x: 600, y: 420), "Moving away")
        f.refresh()
        await f.record(w, "display=1&x=0&y=0&width=960&height=540", label: nil, note: "Record Project runs, then stops")
        f.hold(2.2, "A second card stacks above the first. Record Project offers Edit instead of Play and shows its project folder.")

        c.perform(.openHistory)
        guard let h = c.history, let hw = h.window else { throw FilmError.missing("History") }
        hw.setContentSize(NSSize(width: 920, height: 640))
        f.historyOrigin = CGPoint(x: 120, y: 90)
        f.layers = { f.cardLayers(w) + f.windowLayer(hw, at: f.historyOrigin) }
        f.refresh()
        _ = await waitUntil(3) { h.records.allSatisfy { c.thumbnails.cached($0.id, maxPixel: HistoryWindowController.thumbnailPixels) != nil } }
        f.refresh()
        f.hold(1.6, "Capture History lists the recordings with their first frame, a length badge and Recording in the title.")
        let filter = findView("history.filter", in: hw.contentView) as! NSSegmentedControl
        f.glide(to: f.center(of: filter, in: hw, at: f.historyOrigin, segment: HistoryFilter.recordings.rawValue), "Filter: Recordings")
        filter.selectedSegment = HistoryFilter.recordings.rawValue
        fire(filter)
        f.refresh()
        f.hold(1.6, "The Recordings filter shows recordings only. The Area filter lists pictures.")
        h.select(recordIDs: [video.id])
        f.refresh()
        f.hold(2, "A plain video selected: Copy, Show Overlay and Reveal work on it. Edit is for a recording made for editing.")
        f.status = { "index.json: kind=\(video.kind.rawValue) video.format=\(video.video!.format.rawValue) duration=\(String(format: "%.3f", video.video!.duration)) location=\(video.video!.location.lastPathComponent)" }
        f.hold(2, "The stored entry carries the video: its format, length and file.")
        f.dark = true
        f.refresh()
        f.hold(3, "Cards and History follow Dark appearance.")
    }
}

enum FilmError: Error { case missing(String) }

/// One film: a stage of the synthetic desktop in global points, layers of real views on it, a pointer and a caption.
@MainActor
final class Film {
    static let stage = CGSize(width: 1280, height: 800)
    static let scale: CGFloat = 1.25
    static let captionHeight = 140
    static let fps: Int32 = 30

    var title = ""
    var dark = false
    var failures: [String] = []
    var layers: () -> [(CGImage, CGRect)] = { [] }
    var status: () -> String = { "" }
    var settingsOrigin = CGPoint(x: 120, y: 160)
    var historyOrigin = CGPoint(x: 120, y: 90)
    /// Frames lifted from the files recorded in this film, newest last, each with its facts.
    var results: [(label: String, frame: CGImage?, facts: String)] = []
    private var cached: [(CGImage, CGRect)] = []
    private let width: Int
    private let height: Int
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let desktop = Pix.fixtureDisplay().image
    private var pointer = CGPoint(x: 640, y: 400)
    private var frames = 0

    init?(url: URL) {
        try? FileManager.default.removeItem(at: url)
        width = Int(Self.stage.width * Self.scale)
        height = Int(Self.stage.height * Self.scale) + Self.captionHeight
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mp4) else { return nil }
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 8_000_000],
        ])
        input.expectsMediaDataInRealTime = false
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        guard writer.startWriting() else { return nil }
        writer.startSession(atSourceTime: .zero)
        self.writer = writer
    }

    // MARK: Driving

    func openRecordingPane(_ w: World) throws -> SettingsWindowController {
        w.coordinator.perform(.openSettings)
        guard let sw = w.coordinator.settingsWindow, let window = sw.window, let pane = sw.panes.first(where: { $0 is RecordingPane }) else {
            throw FilmError.missing("the Recording pane")
        }
        layers = { [unowned self] in windowLayer(window, at: settingsOrigin) + resultLayers() }
        status = { [unowned self] in
            let r = w.settings.value.recording
            return "settings.recording: fps=\(r.fps) quality=\(r.quality.rawValue) resolution=\(r.density.rawValue) limit=\(r.limit.rawValue) showCursor=\(r.showCursor)  results so far: \(results.count)"
        }
        refresh()
        hold(0.8, "Cornermark Settings")
        if let item = findView("settings.sidebar.recording", in: window.contentView) {
            glide(to: center(of: item, in: window, at: settingsOrigin), "Recording in the sidebar")
        }
        sw.select(pane: pane)
        refresh()
        return sw
    }

    func choose(_ id: String, _ index: Int, in sw: SettingsWindowController, note: String) {
        guard let window = sw.window, let popup = findView(id, in: sw.selectedPane.view) as? NSPopUpButton else { return failures.append("no \(id)") }
        glide(to: center(of: popup, in: window, at: settingsOrigin), note)
        popup.selectItem(at: index)
        fire(popup)
        refresh()
        hold(0.7, note)
    }

    func toggle(_ id: String, in sw: SettingsWindowController, note: String) {
        guard let window = sw.window, let box = findView(id, in: sw.selectedPane.view) as? NSButton else { return failures.append("no \(id)") }
        glide(to: center(of: box, in: window, at: settingsOrigin), note)
        box.performClick(nil)
        refresh()
        hold(0.7, note)
    }

    /// Clicks a card button the way the user would: pointer on it, pressed for a moment, then its action.
    func press(_ button: NSButton, in panel: NSPanel, note: String) {
        let r = button.convert(button.bounds, to: nil)
        glide(to: CGPoint(x: panel.frame.minX + r.midX, y: panel.frame.minY + r.midY), note, frames: 12)
        button.isHighlighted = true
        refresh()
        hold(0.2, note)
        button.isHighlighted = false
        button.performClick(nil)
        refresh()
    }

    /// Starts a recording through its link, stops it, and, when `label` is given, shows a frame of the file with what it measures.
    func record(_ w: World, _ query: String, label: String?, note: String, at time: Double = 0.2) async {
        hold(0.6, "\(note): cornermark://record?\(query)")
        guard let record = await recordOnce(w, query), let video = record.video else { return failures.append("no recording for \(query)") }
        refresh()
        guard let label else { return }
        var extra = ""
        if video.format == .project, let project = try? RecordingProjectFile.read(from: video.location) {
            extra = "  project.json cursor.isVisible=\(project.edits.cursor.isVisible) pointer samples=\(project.events.pointer.count)"
        }
        await show(video.file, label: label, at: time, extra: extra)
    }

    /// Lifts a frame at `time` from a recorded file and shows it with what the file measures.
    func show(_ file: URL, label: String, at time: Double, extra: String = "") async {
        let asset = AVURLAsset(url: file)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let frame = try? await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image
        let facts = await fileFacts(file)
        let rate = (try? await asset.loadTracks(withMediaType: .video).first?.load(.estimatedDataRate)).flatMap { $0 } ?? 0
        let bytes = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
        let text = (facts.map { "\($0.width) x \($0.height), \(Int($0.fps.rounded())) fps, \($0.frames) frames, \(bytes / 1024) KB, \(Int(rate / 1000)) kbit/s" } ?? "unreadable") + extra
        print("RESULT \(label): \(file.lastPathComponent) \(text)")
        results.append((label, frame, text))
        refresh()
    }

    func refresh() { cached = layers() }

    func hold(_ seconds: Double, _ note: String) {
        for _ in 0..<max(1, Int(seconds * Double(Self.fps))) { frame(note) }
    }

    func glide(to p: CGPoint, _ note: String, frames n: Int = 16) {
        let a = pointer
        for i in 1...n {
            let t = CGFloat(i) / CGFloat(n), e = t * t * (3 - 2 * t)
            pointer = CGPoint(x: a.x + (p.x - a.x) * e, y: a.y + (p.y - a.y) * e)
            frame(note)
        }
    }

    // MARK: Layers

    func center(of view: NSView, in window: NSWindow, at origin: CGPoint, segment: Int? = nil) -> CGPoint {
        var r = view.convert(view.bounds, to: nil)
        if let segment, let control = view as? NSSegmentedControl, control.segmentCount > 0 {
            let w = r.width / CGFloat(control.segmentCount)
            r = CGRect(x: r.minX + w * CGFloat(segment), y: r.minY, width: w, height: r.height)
        }
        return CGPoint(x: origin.x + r.midX, y: origin.y + r.midY)
    }

    func windowLayer(_ window: NSWindow, at origin: CGPoint) -> [(CGImage, CGRect)] {
        guard let image = windowImage(window, dark: dark) else { failures.append("could not render \(window.title)"); return [] }
        return [(image, CGRect(origin: origin, size: window.frame.size))]
    }

    func cardLayers(_ w: World) -> [(CGImage, CGRect)] {
        w.coordinator.overlay.stack.compactMap { card in
            guard let panel = w.coordinator.overlay.panel(for: card), let view = panel.contentView else { return nil }
            panel.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            view.appearance = panel.appearance
            view.layoutSubtreeIfNeeded()
            view.displayIfNeeded()
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width * 2), pixelsHigh: Int(view.bounds.height * 2), bitsPerSample: 8,
                                             samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
            rep.size = view.bounds.size
            view.cacheDisplay(in: view.bounds, to: rep)
            return rep.cgImage.map { ($0, panel.frame) }
        }
    }

    /// The newest card again at twice its size, labelled, so its glyphs read in the film.
    func magnified(_ w: World) -> [(CGImage, CGRect)] {
        guard let (card, frame) = cardLayers(w).last.map({ ($0.0, $0.1) }) else { return [] }
        let box = CGRect(x: 560, y: 90, width: frame.width * 2 + 20, height: frame.height * 2 + 44)
        let s: CGFloat = 2
        let ctx = Pix.context(Int(box.width * s), Int(box.height * s))
        ctx.scaleBy(x: s, y: s)
        ctx.setFillColor(CGColor(gray: 0.08, alpha: 0.9))
        ctx.addPath(CGPath(roundedRect: CGRect(origin: .zero, size: box.size), cornerWidth: 10, cornerHeight: 10, transform: nil))
        ctx.fillPath()
        ctx.interpolationQuality = .high
        ctx.draw(card, in: CGRect(x: 10, y: 10, width: frame.width * 2, height: frame.height * 2))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        ("Harness zoom: the newest card at 2x" as NSString).draw(in: CGRect(x: 10, y: box.height - 28, width: box.width - 20, height: 20),
                                                                 withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.white])
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage().map { [($0, box)] } ?? []
    }

    /// The recorded files' frames, side by side along the right edge, newest at the top.
    func resultLayers() -> [(CGImage, CGRect)] {
        results.suffix(2).reversed().enumerated().compactMap { i, r in
            let box = CGRect(x: 900, y: 470 - CGFloat(i) * 300, width: 360, height: 280)
            return resultCard(r, size: box.size).map { ($0, box) }
        }
    }

    private func resultCard(_ r: (label: String, frame: CGImage?, facts: String), size: CGSize) -> CGImage? {
        let s: CGFloat = 2
        let ctx = Pix.context(Int(size.width * s), Int(size.height * s))
        ctx.scaleBy(x: s, y: s)
        ctx.setFillColor(CGColor(gray: 0.08, alpha: 0.94))
        ctx.addPath(CGPath(roundedRect: CGRect(origin: .zero, size: size), cornerWidth: 10, cornerHeight: 10, transform: nil))
        ctx.fillPath()
        if let frame = r.frame {
            let area = CGRect(x: 10, y: 70, width: size.width - 20, height: size.height - 104)
            let k = min(area.width / CGFloat(frame.width), area.height / CGFloat(frame.height))
            let fw = CGFloat(frame.width) * k, fh = CGFloat(frame.height) * k
            ctx.interpolationQuality = .high
            ctx.draw(frame, in: CGRect(x: area.midX - fw / 2, y: area.midY - fh / 2, width: fw, height: fh))
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        let head: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.white]
        let body: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular), .foregroundColor: NSColor(white: 0.8, alpha: 1)]
        ("Recorded file: \(r.label)" as NSString).draw(in: CGRect(x: 10, y: size.height - 26, width: size.width - 20, height: 18), withAttributes: head)
        (r.facts as NSString).draw(in: CGRect(x: 10, y: 6, width: size.width - 20, height: 60), withAttributes: body)
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }

    // MARK: Pictures

    func frame(_ note: String) {
        var buffer: CVPixelBuffer?
        if let pool = adaptor.pixelBufferPool { CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) }
        guard let buffer else { return failures.append("no pixel buffer") }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return }
        let caption = CGFloat(Self.captionHeight), k = Self.scale
        func place(_ r: CGRect) -> CGRect { CGRect(x: r.minX * k, y: caption + r.minY * k, width: r.width * k, height: r.height * k) }
        ctx.interpolationQuality = .high
        ctx.draw(desktop, in: place(CGRect(origin: .zero, size: Self.stage)))
        for (image, rect) in cached {
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 24, color: CGColor(gray: 0, alpha: 0.35))
            ctx.draw(image, in: place(rect))
            ctx.restoreGState()
        }
        drawPointer(ctx, at: CGPoint(x: pointer.x * k, y: caption + pointer.y * k))
        ctx.setFillColor(CGColor(gray: 0.08, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: caption))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        let small: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 18, weight: .medium), .foregroundColor: NSColor(white: 0.62, alpha: 1)]
        let big: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 25, weight: .semibold), .foregroundColor: NSColor.white]
        let mono: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 15, weight: .regular), .foregroundColor: NSColor(white: 0.78, alpha: 1)]
        (title as NSString).draw(in: CGRect(x: 24, y: 100, width: CGFloat(width) - 48, height: 30), withAttributes: small)
        (note as NSString).draw(in: CGRect(x: 24, y: 56, width: CGFloat(width) - 48, height: 36), withAttributes: big)
        let line = status() + "   [harness render, \(dark ? "dark" : "light")]"
        (line as NSString).draw(in: CGRect(x: 24, y: 16, width: CGFloat(width) - 48, height: 34), withAttributes: mono)
        NSGraphicsContext.restoreGraphicsState()
        let time = CMTime(value: CMTimeValue(frames), timescale: Self.fps)
        while !input.isReadyForMoreMediaData { RunLoop.current.run(until: Date().addingTimeInterval(0.002)) }
        if adaptor.append(buffer, withPresentationTime: time) { frames += 1 } else { failures.append("append failed at \(frames)") }
    }

    private func drawPointer(_ ctx: CGContext, at p: CGPoint) {
        let s: CGFloat = 1.5
        let shape: [CGPoint] = [(0, 0), (0, -17), (4, -13), (7, -20), (10, -19), (7, -12), (12, -12)].map { CGPoint(x: p.x + $0.0 * s, y: p.y + $0.1 * s) }
        let path = CGMutablePath()
        path.addLines(between: shape)
        path.closeSubpath()
        ctx.addPath(path)
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 1))
        ctx.setLineWidth(2)
        ctx.drawPath(using: .fillStroke)
    }

    func finish() async -> Int {
        input.markAsFinished()
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in writer.finishWriting { done.resume() } }
        if writer.status != .completed { failures.append("writer: \(String(describing: writer.error))") }
        return frames
    }
}
