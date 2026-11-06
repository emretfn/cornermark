import AppKit
import AVFoundation
import CornermarkCore
import CornermarkDesign
@testable import CornermarkVideoEditor
@testable import CornermarkShell

/// Films the Camera, Keystrokes and Audio sections for review: the real editor rendered offscreen, driven by scripted clicks and slider
/// moves on a project with the synthetic camera, the scripted keys and scripted sound, next to frames and sound levels read back from
/// exported files. No key events are sent and nothing is played. Run with `CORNERMARK_AFTER_FILM=<folder> swift run HarnessShell`.
@MainActor
enum VideoAfterRecordingFilm {
    static func run(out: URL) async -> Bool {
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let source: AfterRecordingWorld
        do { source = try AfterRecordingWorld() } catch { print("FILM failures=[\(error)]"); return false }
        defer { source.world.cleanup() }
        guard let folder = await source.record() else { print("FILM failures=[no project]"); return false }
        var ok = true
        for (name, scene) in [("B5", b5), ("B6", b6), ("B7", b7)] as [(String, (Film, EditorStage, URL, URL) async throws -> Void)] {
            guard let film = Film(url: out.appendingPathComponent("\(name).mp4")) else { return false }
            do {
                let stage = try await EditorStage(film, frames: 60)
                defer { stage.w.cleanup() }
                try await scene(film, stage, folder, out)
            } catch { film.failures.append("\(error)") }
            let written = await film.finish()
            print("FILM \(name).mp4 frames=\(written) failures=\(film.failures)")
            ok = ok && written > 0 && film.failures.isEmpty
        }
        return ok
    }

    // MARK: Scenes

    static func b5(_ f: Film, _ s: EditorStage, _ folder: URL, _ out: URL) async throws {
        f.title = "B5  Camera after recording: show or hide, shape, size, a 3 x 3 position grid, and mirror. Synthetic camera."
        let editor = try await open(folder, f, s)
        f.status = { [unowned editor] in
            let c = editor.state.project.edits.camera
            return "edits.camera: visible=\(c.isVisible) shape=\(c.shape.rawValue) size=\(c.size.rawValue) position=\(c.position.rawValue) mirrored=\(c.isMirrored) fullScreenSpans=\(c.fullScreen.count)  undo=\(editor.canUndo)"
        }
        await s.press(button("video.rail.camera", editor), in: editor, note: "Camera in the settings rail")
        f.hold(1.6, "The camera recorded beside the screen, as a bubble bottom left. Every setting can still change.")
        await s.press(button("video.camera.show", editor), in: editor, note: "Show camera off")
        f.hold(1.2, "Show camera off: the bubble leaves the preview and the export, its settings grey out.")
        await s.press(button("video.camera.show", editor), in: editor, note: "Show camera on")
        for (i, name) in ["Circle", "Square", "Rectangle"].enumerated().reversed() + [(0, "Circle")] {
            await segment("video.camera.shape", i, f, s, editor, "Shape: \(name)")
        }
        for (i, name) in ["Small", "Medium", "Large", "Medium"].enumerated().map({ ($0.offset == 3 ? 1 : $0.offset, $0.element) }) {
            await segment("video.camera.size", i, f, s, editor, "Size: \(name)")
        }
        for (i, p) in GridPosition.allCases.enumerated() {
            await s.press(button("video.camera.position.\(i)", editor), in: editor, note: "Position: \(p.title)")
            f.hold(0.9, "Position: \(p.title), the grid's cell \(i + 1) of 9.")
        }
        await s.press(button("video.camera.position.2", editor), in: editor, note: "Position: Top right")
        await s.press(button("video.camera.mirror", editor), in: editor, note: "Mirror camera")
        f.hold(1.6, "Mirror off: the label on the synthetic camera reads the right way round.")
        await play(editor, s, seconds: 1.5, note: "Playing: the camera's own picture follows the playhead.")
        f.dark = true
        f.refresh()
        f.hold(1.6, "The same in Dark appearance.")
        f.dark = false
        f.refresh()
        editor.undo()
        await settle(editor, s)
        f.hold(1.2, "Edit > Undo: mirroring comes back, one change per step.")
        editor.redo()
        await settle(editor, s)
        f.hold(1, "Edit > Redo.")
        try await export(editor, f, s, frames: [(1.0, "the exported file at 1.0 s: a round bubble top right, not mirrored")])
    }

    static func b6(_ f: Film, _ s: EditorStage, _ folder: URL, _ out: URL) async throws {
        f.title = "B6  Keystrokes after recording: show or hide, Shortcuts or All keys, size, style, and a 3 x 3 position grid."
        let editor = try await open(folder, f, s)
        f.status = { [unowned editor] in
            let k = editor.state.project.edits.keystrokes, t = editor.state.transport.time(at: s.clock.now)
            let badge = frameState(editor.state.project, outputTime: t).input.badge?.text ?? "none"
            return "edits.keystrokes: visible=\(k.isVisible) keys=\(k.keys.rawValue) size=\(k.size.rawValue) style=\(k.theme.rawValue) position=\(k.position.rawValue)  badge now: \(badge)  events.keys=\(editor.state.project.events.keys.count)"
        }
        await s.press(button("video.rail.keystrokes", editor), in: editor, note: "Keystrokes in the settings rail")
        f.hold(1.4, "The recording kept seven key presses: Shift-Command-4, h e l l o, Command-S.")
        await seek(editor, s, to: 3.2)
        f.hold(1.6, "At 0:03.2 the badge shows what was typed, hello.")
        await segment("video.keys.mode", 0, f, s, editor, "Show: Shortcuts")
        f.hold(1.8, "Shortcuts only: typing is left out, so no badge here.")
        await seek(editor, s, to: 4.8)
        f.hold(1.6, "At 0:04.8 Command-S still shows: it was pressed with Command.")
        await segment("video.keys.mode", 1, f, s, editor, "Show: All keys")
        await seek(editor, s, to: 3.2)
        for (i, name) in [(0, "Small"), (2, "Large"), (1, "Medium")] { await segment("video.keys.size", i, f, s, editor, "Size: \(name)") }
        await segment("video.keys.style", 1, f, s, editor, "Style: Light")
        await segment("video.keys.style", 0, f, s, editor, "Style: Dark")
        for (i, p) in GridPosition.allCases.enumerated() {
            await s.press(button("video.keys.position.\(i)", editor), in: editor, note: "Position: \(p.title)")
            f.hold(0.8, "Position: \(p.title).")
        }
        await s.press(button("video.keys.position.1", editor), in: editor, note: "Position: Top center")
        await seek(editor, s, to: 2.3)
        await play(editor, s, seconds: 2.8, note: "Playing: the badge grows in with each key and fades after the last.")
        await s.press(button("video.keys.show", editor), in: editor, note: "Show keystrokes off")
        f.hold(1.2, "Show keystrokes off: no badge, its settings grey out.")
        await s.press(button("video.keys.show", editor), in: editor, note: "Show keystrokes on")
        await seek(editor, s, to: 3.2)
        f.dark = true
        f.refresh()
        f.hold(1.6, "The same in Dark appearance.")
        f.dark = false
        editor.undo()
        await settle(editor, s)
        f.hold(1.2, "Edit > Undo: the badge goes back off. Redo turns it on again.")
        editor.redo()
        await settle(editor, s)
        try await export(editor, f, s, frames: [(3.2, "the exported file at 3.2 s: hello, top center"), (4.8, "the exported file at 4.8 s: Command-S")])
    }

    static func b7(_ f: Film, _ s: EditorStage, _ folder: URL, _ out: URL) async throws {
        f.title = "B7  Sound after recording: the microphone and system audio, each on or off at its own level. The export mixes what they say."
        let editor = try await open(folder, f, s)
        f.status = { [unowned editor] in
            let a = editor.state.project.edits.audio
            func t(_ l: AudioTrackLevel) -> String { l.isOn ? "\(Int((l.level * 100).rounded()))%" : "off" }
            return "edits.audio: microphone=\(t(a.microphone)) systemAudio=\(t(a.systemAudio))  mix=\(editor.state.project.audioMix.map { "\($0.file) x\(String(format: "%.2f", $0.gain))" }.joined(separator: " + "))  playsSound=\(editor.playsSound)"
        }
        await s.press(button("video.rail.audio", editor), in: editor, note: "Audio in the settings rail")
        f.hold(1.8, "The recording has mic.m4a and system.m4a. Both play at 100% until changed. The harness never plays them.")
        await s.press(button("video.audio.systemAudio", editor), in: editor, note: "System audio off")
        f.hold(1.4, "System audio off: its level greys out and it leaves the mix.")
        await s.press(button("video.audio.systemAudio", editor), in: editor, note: "System audio on")
        await slide("video.audio.microphone.level", through: [1, 0.2, 0.5], f, s, editor, "Microphone level")
        await slide("video.audio.systemAudio.level", through: [1, 0.25], f, s, editor, "System audio level")
        f.dark = true
        f.refresh()
        f.hold(1.6, "The same in Dark appearance.")
        f.dark = false
        editor.undo()
        await settle(editor, s)
        f.hold(1.4, "Edit > Undo: the whole system audio drag goes back in one step.")
        editor.redo()
        await settle(editor, s)
        f.hold(1, "Edit > Redo: system audio at 25% again.")
        try await export(editor, f, s, frames: [])
        guard let file = s.w.store.list().first(where: \.ownsVideo)?.video?.file else { throw FilmError.missing("the export") }
        try FileManager.default.copyItem(at: file, to: out.appendingPathComponent("B7-export-mic50-system25.mp4"))
        try await levels(f, s, folder: folder, exported: file, out: out)
    }

    // MARK: Sound levels

    /// Exports the project with chosen levels straight through `VideoExporter`, reads every file back, and shows each waveform with its RMS.
    private static func levels(_ f: Film, _ s: EditorStage, folder: URL, exported: URL, out: URL) async throws {
        guard let project = try? RecordingProjectFile.read(from: folder) else { throw FilmError.missing("the project") }
        var rows: [(String, URL)] = [("mic.m4a, as recorded", folder.appendingPathComponent("mic.m4a")),
                                     ("system.m4a, as recorded", folder.appendingPathComponent("system.m4a"))]
        for (name, mic, system) in [("export, microphone 100%, system off", 1.0, 0.0), ("export, microphone 50%, system off", 0.5, 0.0),
                                    ("export, microphone off, system 100%", 0.0, 1.0), ("export, microphone off, system 25%", 0.0, 0.25),
                                    ("export, both off", 0.0, 0.0)] {
            var p = project
            p.edits.audio = AudioEdits(microphone: AudioTrackLevel(isOn: mic > 0, level: max(mic, 1e-3)), systemAudio: AudioTrackLevel(isOn: system > 0, level: max(system, 1e-3)))
            let file = out.appendingPathComponent("B7-" + name.replacingOccurrences(of: ", ", with: "-").replacingOccurrences(of: " ", with: "-").replacingOccurrences(of: "%", with: "") + ".mp4")
            try? FileManager.default.removeItem(at: file)
            _ = try await VideoExporter.export(project: p, video: folder.appendingPathComponent(p.source.video), settings: ExportSettings(), to: file)
            rows.append((name, file))
        }
        rows.append(("the editor's export above, microphone 50%, system 25%", exported))
        var measured: [(String, SoundLevel?, [(Float, Float)])] = []
        for (label, url) in rows { measured.append((label, await SoundLevel.read(url), await waveform(url))) }
        for (label, level, _) in measured { print("RMS film \(label): \(level.map { "\($0)" } ?? "no sound track")") }
        guard let panel = soundPanel(measured) else { throw FilmError.missing("the sound panel") }
        if let png = AssetStore.pngData(from: panel) { try? png.write(to: out.appendingPathComponent("B7-levels.png")) }
        f.layers = { [(panel, CGRect(x: 40, y: 150, width: 1200, height: 640))] }
        f.status = { "Each file decoded with AVAssetReader to 48 kHz float stereo; RMS over every sample. Nothing is played." }
        f.refresh()
        f.hold(7, "Microphone 50%: 6.02 dB under 100%. System 25%: 12.04 dB under. Both off: no sound track.")
    }

    private static func waveform(_ url: URL, buckets: Int = 900) async -> [(Float, Float)] {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first, let reader = try? AVAssetReader(asset: asset) else { return [] }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false,
        ])
        reader.add(output)
        guard reader.startReading() else { return [] }
        var all: [Float] = []
        while let sample = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var floats = [Float](repeating: 0, count: length / 4)
            _ = floats.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
            all += floats
        }
        guard !all.isEmpty else { return [] }
        let per = max(1, all.count / buckets)
        return stride(from: 0, to: all.count, by: per).map { i in
            let slice = all[i..<min(i + per, all.count)]
            return (slice.min() ?? 0, slice.max() ?? 0)
        }
    }

    /// One row per file: its label and RMS on the left, its waveform on a fixed scale on the right.
    private static func soundPanel(_ rows: [(String, SoundLevel?, [(Float, Float)])]) -> CGImage? {
        let w = 2400, h = 1280
        let ctx = Pix.context(w, h)
        ctx.setFillColor(CGColor(gray: 0.1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let rowH = CGFloat(h - 80) / CGFloat(rows.count)
        let graphics = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        NSAttributedString(string: "Sound read back from the files (waveforms share one scale, full scale = row height)",
                           attributes: [.font: NSFont.systemFont(ofSize: 30, weight: .semibold), .foregroundColor: NSColor.white])
            .draw(at: CGPoint(x: 40, y: CGFloat(h) - 60))
        for (i, row) in rows.enumerated() {
            let top = CGFloat(h - 80) - CGFloat(i) * rowH
            let mid = top - rowH / 2
            NSAttributedString(string: row.0, attributes: [.font: NSFont.systemFont(ofSize: 24, weight: .medium), .foregroundColor: NSColor.white])
                .draw(at: CGPoint(x: 40, y: mid + 4))
            let level = row.1.map { String(format: "RMS %.4f  (%.2f dBFS)", $0.rms, $0.dBFS) } ?? "no sound track"
            NSAttributedString(string: level, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 22, weight: .regular), .foregroundColor: NSColor(white: 0.75, alpha: 1)])
                .draw(at: CGPoint(x: 40, y: mid - 30))
            let box = CGRect(x: 760, y: top - rowH + 10, width: CGFloat(w) - 800, height: rowH - 20)
            ctx.setFillColor(CGColor(gray: 0.16, alpha: 1))
            ctx.fill(box)
            ctx.setStrokeColor(CGColor(gray: 0.4, alpha: 1))
            ctx.stroke(CGRect(x: box.minX, y: box.midY, width: box.width, height: 0.5))
            guard !row.2.isEmpty else { continue }
            ctx.setStrokeColor(CGColor(srgbRed: 0.45, green: 0.75, blue: 1, alpha: 1))
            ctx.setLineWidth(1.5)
            let step = box.width / CGFloat(row.2.count)
            for (k, (lo, hi)) in row.2.enumerated() {
                let x = box.minX + CGFloat(k) * step
                ctx.move(to: CGPoint(x: x, y: box.midY + CGFloat(lo) * box.height / 2))
                ctx.addLine(to: CGPoint(x: x, y: box.midY + CGFloat(hi) * box.height / 2))
            }
            ctx.strokePath()
        }
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }

    // MARK: Steps

    private static func open(_ folder: URL, _ f: Film, _ s: EditorStage) async throws -> VideoEditorWindowController {
        // The project has sound, so the stage's decoder says so and the volume control is on, as with the app's own player.
        s.hasAudio = true
        guard let editor = s.w.coordinator.openVideoEditor(folder) else { throw FilmError.missing("the editor") }
        if let name = editor.state.project.source.camera { editor.cameraFrames = StillFrames(url: folder.appendingPathComponent(name)) }
        await s.show(editor)
        await seek(editor, s, to: 1.0)
        return editor
    }

    private static func button(_ id: String, _ editor: VideoEditorWindowController) -> NSButton {
        (editor.view(identifier: id) as? NSButton) ?? NSButton()
    }

    /// Decodes the camera's picture too, then lets the stage tick and redraw.
    private static func settle(_ editor: VideoEditorWindowController, _ s: EditorStage) async {
        let t = frameState(editor.state.project, outputTime: editor.state.transport.time(at: s.clock.now)).sourceTime
        await (editor.cameraFrames as? StillFrames)?.prepare(t)
        await s.settle(editor)
    }

    private static func seek(_ editor: VideoEditorWindowController, _ s: EditorStage, to t: Double) async {
        editor.seek(to: t)
        await settle(editor, s)
    }

    private static func play(_ editor: VideoEditorWindowController, _ s: EditorStage, seconds: Double, note: String) async {
        editor.togglePlayback()
        for _ in 0..<Int(seconds * Double(Film.fps)) {
            s.clock.now += 1 / Double(Film.fps)
            await settle(editor, s)
            s.film.hold(1 / Double(Film.fps), note)
        }
        editor.togglePlayback()
        await settle(editor, s)
    }

    private static func segment(_ id: String, _ index: Int, _ f: Film, _ s: EditorStage, _ editor: VideoEditorWindowController, _ note: String) async {
        guard let control = editor.view(identifier: id) as? NSSegmentedControl, let window = editor.window else { return f.failures.append("no \(id)") }
        f.glide(to: f.center(of: control, in: window, at: s.origin, segment: index), note, frames: 10)
        control.selectedSegment = index
        fire(control)
        await settle(editor, s)
        f.hold(1, note)
    }

    private static func slide(_ id: String, through values: [Double], _ f: Film, _ s: EditorStage, _ editor: VideoEditorWindowController, _ name: String) async {
        guard let slider = editor.view(identifier: id) as? NSSlider else { return f.failures.append("no \(id)") }
        func knob(_ v: Double) -> CGPoint {
            let r = slider.convert(slider.bounds, to: nil), k = (v - slider.minValue) / (slider.maxValue - slider.minValue)
            return CGPoint(x: s.origin.x + r.minX + 7 + CGFloat(k) * (r.width - 14), y: s.origin.y + r.midY)
        }
        f.glide(to: knob(slider.doubleValue), name)
        for (a, b) in zip(values, values.dropFirst()) {
            for i in 1...20 {
                let t = Double(i) / 20, e = t * t * (3 - 2 * t)
                slider.doubleValue = a + (b - a) * e
                fire(slider)
                await settle(editor, s)
                f.glide(to: knob(slider.doubleValue), "\(name) \(Int((slider.doubleValue * 100).rounded()))%", frames: 1)
            }
            f.hold(0.6, "\(name) \(Int((b * 100).rounded()))%")
        }
        (slider as? TrackingSlider)?.onTrackingEnd()
    }

    private static func export(_ editor: VideoEditorWindowController, _ f: Film, _ s: EditorStage, frames: [(Double, String)]) async throws {
        await s.press(button("video.export", editor), in: editor, note: "Export")
        await s.press(button("video.export.start", editor), in: editor, note: "Export")
        await VideoExportFilm.sample(f, s, editor, until: 1.01) { "Exporting: \(Int($0 * 100))%" }
        _ = await waitUntil(30) { s.w.store.list().contains(where: \.ownsVideo) }
        guard let file = s.w.store.list().first(where: \.ownsVideo)?.video?.file else { throw FilmError.missing("the export") }
        let sound = await SoundLevel.read(file)
        for (t, label) in frames { await f.show(file, label: label, at: t, extra: sound.map { String(format: ", sound RMS %.4f", $0.rms) } ?? ", no sound track") }
        f.layers = { [unowned s, unowned editor] in s.layers(editor) + f.resultLayers() }
        f.refresh()
        if !frames.isEmpty { f.hold(3.4, "Frames read back from the exported file: it matches the preview.") }
    }
}
