import AppKit
import AVFoundation
@testable import CornermarkCapture
import CornermarkCore

struct AudioFacts {
    var rate: Double
    var channels: [[Float]]
    var duration: Double
    var codec: FourCharCode
}

/// Every sample of a file's first sound track, decoded the way a player does, encoder delay removed, one array per channel.
func readAudio(_ url: URL) async -> AudioFacts? {
    let asset = AVURLAsset(url: url)
    guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
          let format = (try? await track.load(.formatDescriptions))?.first,
          let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
          let file = try? AVAudioFile(forReading: url),
          let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
          (try? file.read(into: buffer)) != nil, let data = buffer.floatChannelData else { return nil }
    let channels = (0..<Int(buffer.format.channelCount)).map { Array(UnsafeBufferPointer(start: data[$0], count: Int(buffer.frameLength))) }
    return AudioFacts(rate: file.processingFormat.sampleRate, channels: channels, duration: Double(buffer.frameLength) / file.processingFormat.sampleRate,
                      codec: asbd.mFormatID)
}

/// The start of each full-white picture run, in seconds of the video.
func flashTimes(_ url: URL) async -> [Double] {
    let asset = AVURLAsset(url: url)
    guard let track = try? await asset.loadTracks(withMediaType: .video).first, let reader = try? AVAssetReader(asset: asset) else { return [] }
    let out = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
    reader.add(out)
    reader.startReading()
    var times: [Double] = []
    var wasWhite = false
    while let sample = out.copyNextSampleBuffer(), let pixels = CMSampleBufferGetImageBuffer(sample) {
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        let base = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self)
        let row = CVPixelBufferGetBytesPerRow(pixels), w = CVPixelBufferGetWidth(pixels), h = CVPixelBufferGetHeight(pixels)
        let white = [(0.1, 0.1), (0.5, 0.5), (0.9, 0.9)].allSatisfy { fx, fy in
            let o = Int(Double(h) * fy) * row + Int(Double(w) * fx) * 4
            return base[o] > 235 && base[o + 1] > 235 && base[o + 2] > 235
        }
        CVPixelBufferUnlockBaseAddress(pixels, .readOnly)
        if white, !wasWhite { times.append(CMSampleBufferGetPresentationTimeStamp(sample).seconds) }
        wasWhite = white
    }
    return times
}

/// Where each click starts: the first sample over 0.3 more than a tenth of a second after the last one. AAC smears a little sound
/// just ahead of a burst, so the quiet before it is judged by loud samples only.
func clickOnsets(_ samples: [Float], rate: Double) -> [Double] {
    var onsets: [Double] = []
    var last = -Int.max / 2
    for (i, v) in samples.enumerated() where abs(v) > 0.3 {
        if i - last > Int(rate * 0.1) { onsets.append(Double(i) / rate) }
        last = i
    }
    return onsets
}

/// Sound minus picture for each flash, in milliseconds, against the nearest click.
func syncOffsets(flashes: [Double], clicks: [Double]) -> [Double] {
    flashes.compactMap { f in clicks.min { abs($0 - f) < abs($1 - f) }.map { ($0 - f) * 1000 } }
}

private final class FailingAudio: AudioSource {
    func start(_ deliver: @escaping (AudioChunk) -> Void) throws { throw AudioUnavailable.notPermitted }
    func stop() {}
}

@MainActor
func runAudioTests() async {
    section("sound beside the video: placement on the video's timeline")
    let none = AudioPlacement.place(start: -0.5, frames: 48_000, rate: 48_000, pauses: [], until: 10)
    check(none.used == 48_000 && none.pieces == [.init(offset: 24_000, count: 24_000, videoTime: 0)],
          "sound before the first frame lands nowhere and the rest starts at video time 0", detail: "\(none)")
    let gap = AudioPlacement.place(start: 1, frames: 48_000, rate: 48_000, pauses: [RecordingPause(from: 1.25, to: 1.75)], until: 10)
    check(gap.pieces == [.init(offset: 0, count: 12_000, videoTime: 1), .init(offset: 36_000, count: 12_000, videoTime: 1.25)],
          "a pause removes its stretch, and the sound after it moves back by the pause's length", detail: "\(gap.pieces)")
    let wait = AudioPlacement.place(start: 2, frames: 4_800, rate: 48_000, pauses: [], until: 2.05)
    check(wait.used == 2_400 && wait.pieces.map(\.count) == [2_400], "sound past the settled end waits for the pictures", detail: "\(wait)")

    let dir = URL(fileURLWithPath: recordingScratch + "audio/", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    section("sound beside the video: offline sync to the frame")
    do {
        let origin = 1200.0
        let clicks = AudioPattern.Clicks(epoch: origin + 0.5, period: 1)
        var options = RecordingOptions()
        options.fps = 60
        let source = FixtureFrameSource(area: CGRect(x: 0, y: 0, width: 320, height: 180), options: options, pacing: .scripted(frames: 300, origin: origin))
        source.flash = clicks
        let system = ScriptedAudioSource(pattern: .clicks(clicks, channels: 2), pacing: .fixed(origin: origin - 0.2, seconds: 5.4))
        let mic = ScriptedAudioSource.microphone("scripted.interface", pacing: .fixed(origin: origin, seconds: 5))
        let video = dir.appendingPathComponent("offline.mp4")
        let recorder = Recorder(source: source, output: video,
                                microphone: AudioRecording(source: mic, output: dir.appendingPathComponent("offline-mic.m4a"), mono: false),
                                systemAudio: AudioRecording(source: system, output: dir.appendingPathComponent("offline-system.m4a")))
        try await recorder.start()
        let report = try await recorder.stop()
        let videoSeconds = report.duration + 1.0 / 60
        let sys = report.audio.first { $0.kind == .system }, micTrack = report.audio.first { $0.kind == .microphone }
        check(report.audio.count == 2 && sys?.channels == 2 && micTrack?.channels == 2, "a recording writes the microphone and the system sound as their own tracks",
              detail: "\(report.audio)")
        check(abs((sys?.duration ?? 0) - videoSeconds) < 0.001 && abs((micTrack?.duration ?? 0) - videoSeconds) < 0.001,
              "each track is as long as the video", detail: "video \(videoSeconds) system \(sys?.duration ?? 0) mic \(micTrack?.duration ?? 0)")
        check(report.project.source.microphone == "offline-mic.m4a" && report.project.source.systemAudio == "offline-system.m4a",
              "the project names both tracks")
        if let facts = await readAudio(dir.appendingPathComponent("offline-system.m4a")) {
            let flashes = await flashTimes(video)
            let offsets = syncOffsets(flashes: flashes, clicks: clickOnsets(facts.channels[0], rate: facts.rate))
            print("SYNC offline flashes=\(flashes.map { String(format: "%.4f", $0) }) offsetsMs=\(offsets.map { String(format: "%.2f", $0) })")
            check(facts.codec == kAudioFormatMPEG4AAC && abs(facts.duration - videoSeconds) < 0.001, "the file is AAC and decodes to exactly the video's length",
                  detail: "\(facts.duration)")
            check(flashes.count == 5 && offsets.count == 5 && offsets.allSatisfy { abs($0) <= 1 }, "every click sits within 1 ms of its white frame",
                  detail: "\(offsets)")
        } else { check(false, "the system track can be read") }
        if let facts = await readAudio(dir.appendingPathComponent("offline-mic.m4a")) {
            let left = AudioLevel.measure([facts.channels[0]]), right = AudioLevel.measure([facts.channels[1]])
            check(left.rms > 0.01 && right.peak < 0.001, "without mono, a voice on the first input stays on the left", detail: "left \(left) right \(right)")
        } else { check(false, "the microphone track can be read") }
    } catch { check(false, "the offline recording runs", detail: "\(error)") }

    section("sound beside the video: mono, silence and a refused microphone")
    do {
        var options = RecordingOptions()
        options.fps = 30
        let source = FixtureFrameSource(area: CGRect(x: 0, y: 0, width: 320, height: 180), options: options, pacing: .scripted(frames: 90, origin: 48))
        let mono = ScriptedAudioSource.microphone("scripted.interface", pacing: .fixed(origin: 48, seconds: 3))
        let muted = ScriptedAudioSource(pattern: AudioPattern(channels: 1) { _, _, _ in 0 }, pacing: .fixed(origin: 48, seconds: 3))
        let recorder = Recorder(source: source, output: dir.appendingPathComponent("mono.mp4"),
                                microphone: AudioRecording(source: mono, output: dir.appendingPathComponent("mono-mic.m4a"), mono: true),
                                systemAudio: AudioRecording(source: muted, output: dir.appendingPathComponent("muted.m4a")))
        try await recorder.start()
        let report = try await recorder.stop()
        let micFacts = await readAudio(dir.appendingPathComponent("mono-mic.m4a")), mutedFacts = await readAudio(dir.appendingPathComponent("muted.m4a"))
        check(micFacts?.channels.count == 1 && (micFacts.map { AudioLevel.measure($0.channels).rms } ?? 0) > 0.01,
              "mono mixes the interface's two inputs into one channel with the voice in it")
        check(mutedFacts.map { AudioLevel.measure($0.channels).peak < MicrophoneSilence.threshold } == true && abs((mutedFacts?.duration ?? 0) - 3) < 0.03,
              "a muted source still gives a track of the full length, all silence", detail: "\(mutedFacts?.duration ?? 0)")
        check(report.audio.count == 2, "both tracks are reported")

        let failing = Recorder(source: FixtureFrameSource(options: options, pacing: .scripted(frames: 30)), output: dir.appendingPathComponent("refused.mp4"),
                               microphone: AudioRecording(source: FailingAudio(), output: dir.appendingPathComponent("refused-mic.m4a")))
        try await failing.start()
        let refused = try await failing.stop()
        check(failing.audioFailures[.microphone] == .notPermitted && refused.audio.isEmpty && refused.framesWritten == 30
              && !FileManager.default.fileExists(atPath: dir.appendingPathComponent("refused-mic.m4a").path),
              "a microphone that cannot start leaves the video recording and writes no sound file")
    } catch { check(false, "the mono recording runs", detail: "\(error)") }

    section("sound beside the video: live clock with a pause")
    do {
        let start = recordingClockNow()
        let clicks = AudioPattern.Clicks(epoch: start + 0.4, period: 0.5)
        var options = RecordingOptions()
        options.fps = 60
        let source = FixtureFrameSource(area: CGRect(x: 0, y: 0, width: 320, height: 180), options: options, pacing: .realtime)
        source.flash = clicks
        let system = ScriptedAudioSource(pattern: .clicks(clicks, channels: 2))
        let video = dir.appendingPathComponent("live.mp4")
        let recorder = Recorder(source: source, output: video, systemAudio: AudioRecording(source: system, output: dir.appendingPathComponent("live-system.m4a")))
        try await recorder.start()
        try await Task.sleep(nanoseconds: 2_100_000_000)
        recorder.pause()
        try await Task.sleep(nanoseconds: 1_130_000_000)
        recorder.resume()
        try await Task.sleep(nanoseconds: 2_100_000_000)
        let report = try await recorder.stop()
        let videoSeconds = report.duration + 1.0 / 60
        guard let facts = await readAudio(dir.appendingPathComponent("live-system.m4a")), let track = report.audio.first else {
            return check(false, "the live system track can be read")
        }
        let flashes = await flashTimes(video)
        let offsets = syncOffsets(flashes: flashes, clicks: clickOnsets(facts.channels[0], rate: facts.rate))
        let pauseAt = report.pauses.first.map { $0.from } ?? 0
        let before = zip(flashes, offsets).filter { $0.0 < pauseAt }.map(\.1), after = zip(flashes, offsets).filter { $0.0 >= pauseAt }.map(\.1)
        print("SYNC live pauses=\(report.pauses) videoSeconds=\(String(format: "%.4f", videoSeconds)) track=\(String(format: "%.4f", track.duration)) filled=\(String(format: "%.4f", track.filled))")
        print("SYNC live offsetsMs before=\(before.map { String(format: "%.2f", $0) }) after=\(after.map { String(format: "%.2f", $0) })")
        // Where each click belongs on the video's timeline, worked out from the clock alone, against where the file has it.
        let onsets = clickOnsets(facts.channels[0], rate: facts.rate)
        let expected = (0..<20).compactMap { n -> Double? in
            RecordingPause.videoTime(clicks.epoch + Double(n) * clicks.period - report.firstFrameTime, skipping: report.pauses)
        }.filter { $0 > 0.05 && $0 < videoSeconds - 0.05 }
        let residuals = expected.compactMap { e in onsets.min { abs($0 - e) < abs($1 - e) }.map { ($0 - e) * 1000 } }
        print("SYNC live residualMs=\(residuals.map { String(format: "%.3f", $0) })")
        check(!residuals.isEmpty && residuals.allSatisfy { abs($0) < 0.1 }, "every click lands within 0.1 ms of where the clock puts it on the video's timeline",
              detail: "\(residuals)")
        check(report.pauses.count == 1 && abs(track.duration - videoSeconds) < 0.001, "after a pause the sound is exactly as long as the video",
              detail: "video \(videoSeconds) sound \(track.duration)")
        check(before.count >= 3 && after.count >= 3, "clicks flash on both sides of the pause", detail: "\(before.count) + \(after.count)")
        // A click falls between two frames, so its flash is the next frame: sound may lead the picture by up to one frame, never trail it.
        check((before + after).allSatisfy { $0 <= 1 && $0 >= -1000.0 / 60 - 1 }, "every click is within one frame before its flash, before and after the pause",
              detail: "\(offsets)")
    } catch { check(false, "the live recording runs", detail: "\(error)") }
}
