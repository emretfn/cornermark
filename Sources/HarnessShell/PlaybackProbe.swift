import AppKit
import AVFoundation
import CornermarkCore
@testable import CornermarkVideoEditor

/// Plays real recordings in the editor for a few seconds each, never on screen and never audible, and prints what the preview got:
/// new frames per second, the longest wait between ticks, the main thread's cost per tick, CPU, and how often the player was put back in step.
/// `CORNERMARK_PLAYBACK_PROBE` names a folder holding the inputs; every package it makes goes into a temporary folder beside them.
@MainActor
enum PlaybackProbe {
    struct Result {
        var label: String
        var seconds: Double
        var ticks: Int
        var shown: Int
        var syncs: Int
        var worstGap: Double
        var medianCost: Double
        var p95Cost: Double
        var cpu: Double
        var drift: Double
        var fps: Double { Double(shown) / seconds }
        var line: String {
            String(format: "PROBE %@: shown=%d in %.1fs (%.1f/s) ticks=%d syncs=%d worstGap=%.1fms cost median=%.2fms p95=%.2fms cpu=%.0f%% maxDrift=%.0fms",
                   label, shown, seconds, fps, ticks, syncs, worstGap * 1000, medianCost, p95Cost, cpu * 100, drift * 1000)
        }
    }

    static func run(inputs: URL) async -> Bool {
        let work = inputs.appendingPathComponent("probe-\(UUID().uuidString.prefix(6))", isDirectory: true)
        let seconds = Double(ProcessInfo.processInfo.environment["CORNERMARK_PROBE_SECONDS"] ?? "") ?? 6
        var cases: [(String, URL)] = []
        do {
            for (name, file) in [("mp4 with sound 2560x1440", "lag-recording.mp4"), ("mp4 with sound 1280x720", "small.mp4")]
            where FileManager.default.fileExists(atPath: inputs.appendingPathComponent(file).path) {
                cases.append((name, try await VideoImport.makeProject(from: inputs.appendingPathComponent(file), in: work).folder))
            }
            for (name, screen, mic) in [("project screen+mic 2560x1440", "screen.mp4", "mic.m4a" as String?), ("project screen only 2560x1440", "screen.mp4", nil),
                                         ("project screen+mic 1280x720", "small-screen.mp4", "mic.m4a"), ("project screen only 1280x720", "small-screen.mp4", nil)]
            where FileManager.default.fileExists(atPath: inputs.appendingPathComponent(screen).path) {
                cases.append((name, try await package(screen: inputs.appendingPathComponent(screen), mic: mic.map { inputs.appendingPathComponent($0) }, in: work)))
            }
        } catch {
            print("FAIL probe inputs: \(error)")
            return false
        }
        let only = ProcessInfo.processInfo.environment["CORNERMARK_PROBE_ONLY"]
        for (name, folder) in cases where only.map({ name.contains($0) }) ?? true {
            for audible in [false, true] {
                guard let r = await measure(folder: folder, label: "\(name) \(audible ? "unmuted vol0" : "muted")", unmuted: audible, seconds: seconds) else { return false }
                print(r.line)
            }
        }
        return true
    }

    /// A recording's package as the recorder writes it: the picture without sound, and the microphone beside it.
    static func package(screen: URL, mic: URL?, in work: URL) async throws -> URL {
        let imported = try await VideoImport.makeProject(from: screen, in: work)
        var project = imported.project
        if let mic {
            try FileManager.default.copyItem(at: mic, to: imported.folder.appendingPathComponent(RecordingProjectFile.microphoneName))
            project.source.microphone = RecordingProjectFile.microphoneName
            project.source.origin = .recording
        }
        try RecordingProjectFile.write(project, to: imported.folder)
        return imported.folder
    }

    /// Plays `folder` for `seconds` with a 60 Hz tick on the main run loop, as the display link drives it on screen.
    /// `unmuted` plays the sound at volume 0 instead of muted, the closest silent stand-in for an editor that plays sound.
    static func measure(folder: URL, label: String, unmuted: Bool, seconds: Double) async -> Result? {
        guard let editor = try? VideoEditorWindowController.open(folder: folder), let window = editor.window,
              let live = editor.sourceFrames as? PlayerFrames else {
            print("FAIL probe could not open \(folder.lastPathComponent)")
            return nil
        }
        defer { editor.window?.close() }
        window.setContentSize(NSSize(width: 1200, height: 760))
        window.contentView?.layoutSubtreeIfNeeded()
        await editor.ready()
        if unmuted {
            live.player.volume = 0
            live.player.isMuted = false
        }
        precondition(live.player.isMuted || live.player.volume == 0, "the probe never plays sound")
        _ = await waitUntil(3) { editor.tick(); return editor.previewImage != nil }

        var costs: [Double] = []
        var gaps: [Double] = []
        var shown = 0
        var drift = 0.0
        var lastImage = editor.previewImage
        let cpu0 = cpuSeconds()
        editor.togglePlayback()
        let begin = CACurrentMediaTime()
        var last = begin
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { timer in
                MainActor.assumeIsolated {
                    let t0 = CACurrentMediaTime()
                    gaps.append(t0 - last)
                    last = t0
                    editor.tick()
                    CATransaction.flush()
                    costs.append((CACurrentMediaTime() - t0) * 1000)
                    if let image = editor.previewImage, image !== lastImage { shown += 1; lastImage = image }
                    if t0 - begin > 1 {
                        let expected = editor.state.transport.time(at: t0)
                        drift = max(drift, abs(live.player.currentTime().seconds - expected))
                    }
                    if t0 - begin >= seconds {
                        timer.invalidate()
                        done.resume()
                    }
                }
            }
            RunLoop.main.add(timer, forMode: .common)
        }
        let wall = CACurrentMediaTime() - begin
        let cpu = (cpuSeconds() - cpu0) / wall
        editor.togglePlayback()
        let sorted = costs.sorted()
        return Result(label: label, seconds: wall, ticks: costs.count, shown: shown, syncs: live.syncs, worstGap: gaps.dropFirst().max() ?? 0,
                      medianCost: sorted[sorted.count / 2], p95Cost: sorted[Int(Double(sorted.count - 1) * 0.95)], cpu: cpu, drift: drift)
    }

    static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func s(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1e6 }
        return s(usage.ru_utime) + s(usage.ru_stime)
    }
}

/// Playing a recording with sound shows every frame. A player with a sound track blocked the main thread for about 100 ms when its time was
/// read right after it was put in step; the editor took that late reading for a jump, put it in step again, and the preview stuttered.
@MainActor
func checkVideoEditorPlaybackWithSound(root: URL) async throws {
    section("video editor: playing a recording with sound")
    let work = root.appendingPathComponent("sound-playback", isDirectory: true)
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    let spec = SyntheticMovie.Spec(size: CGSize(width: 1280, height: 720), fps: 60, frames: 240, sound: true, fileType: .mp4)
    let withSound = work.appendingPathComponent("with-sound.mp4"), screen = work.appendingPathComponent("screen.mp4"), mic = work.appendingPathComponent("mic.m4a")
    try await SyntheticMovie.write(to: withSound, spec)
    var silent = spec
    silent.sound = false
    try await SyntheticMovie.write(to: screen, silent)
    guard let export = AVAssetExportSession(asset: AVURLAsset(url: withSound), presetName: AVAssetExportPresetAppleM4A) else { return check(false, "the microphone file is made") }
    try await export.export(to: mic, as: .m4a)
    let cases = [("an MP4 with its sound", try await VideoImport.makeProject(from: withSound, in: work).folder),
                 ("a project with mic.m4a beside screen.mp4", try await PlaybackProbe.package(screen: screen, mic: mic, in: work)),
                 ("a project without sound", try await PlaybackProbe.package(screen: screen, mic: nil, in: work))]
    for (name, folder) in cases {
        guard let r = await PlaybackProbe.measure(folder: folder, label: name, unmuted: false, seconds: 2.5) else { return check(false, "\(name) opens") }
        print(r.line)
        check(r.syncs == 1, "playing \(name) puts the player in step once, when playing starts", detail: "\(r.syncs) syncs")
        check(Double(r.shown) >= Double(r.ticks) * 0.9 && r.ticks >= 135, "playing \(name) shows a new frame on nearly every 60 Hz tick",
              detail: String(format: "%d new frames in %d ticks over %.1f s, longest wait %.0f ms", r.shown, r.ticks, r.seconds, r.worstGap * 1000))
    }
    check(nothingOnScreen(), "playing with sound put nothing on screen")
}
