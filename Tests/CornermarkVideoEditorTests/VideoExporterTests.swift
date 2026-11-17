import AVFoundation
import CornermarkCore
import XCTest
@testable import CornermarkVideoEditor

final class VideoExporterTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("cornermark-export-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }

    /// A source of `frames` solid frames whose grey level steps up, so a frame's level tells which source frame it was.
    private func makeSource(width: Int = 320, height: Int = 180, fps: Int = 30, frames: Int = 30, name: String = "screen.mp4",
                            pixel: ((Int) -> [UInt8])? = nil) async throws -> (URL, RecordingProject) {
        let url = folder.appendingPathComponent(name)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for i in 0..<frames {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
            CVPixelBufferLockBaseAddress(buffer!, [])
            if let pixel {
                let bgra = pixel(i), base = CVPixelBufferGetBaseAddress(buffer!)!.assumingMemoryBound(to: UInt8.self)
                for o in stride(from: 0, to: CVPixelBufferGetDataSize(buffer!), by: 4) { for k in 0..<4 { base[o + k] = bgra[k] } }
            } else {
                memset(CVPixelBufferGetBaseAddress(buffer!), Int32(i * 8), CVPixelBufferGetDataSize(buffer!))
            }
            CVPixelBufferUnlockBaseAddress(buffer!, [])
            adaptor.append(buffer!, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: CMTimeScale(fps)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed)
        let duration = Double(frames) / Double(fps)
        let project = RecordingProject(source: .init(pixelWidth: width, pixelHeight: height, pointWidth: Double(width) / 2, pointHeight: Double(height) / 2,
                                                     fps: fps, duration: duration),
                                       events: .init(pointer: [PointerSample(t: 0, x: 10, y: 10), PointerSample(t: duration, x: 150, y: 80)]))
        return (url, project)
    }

    func testTheExportIsAsLongAsTheProjectAndPlaysItsFrames() async throws {
        let (source, project) = try await makeSource()
        let out = folder.appendingPathComponent("export.mp4")
        let report = try await VideoExporter.export(project: project, video: source, settings: ExportSettings(), to: out)
        XCTAssertEqual(report.duration, project.source.duration, accuracy: 1.0 / 30, "the file is as long as the project")
        XCTAssertEqual(report.framesWritten, 30)
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.path))
        XCTAssertGreaterThan(report.bytes, 0)
        let track = try await AVURLAsset(url: out).loadTracks(withMediaType: .video).first
        let size = try await track?.load(.naturalSize)
        XCTAssertEqual(size, CGSize(width: 320, height: 180))
        XCTAssertEqual((try FileManager.default.contentsOfDirectory(atPath: folder.path)).sorted(), ["export.mp4", "screen.mp4"], "no partial file is left")
    }

    private func levels(_ url: URL) async throws -> [Int] {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var out: [Int] = []
        while let sample = output.copyNextSampleBuffer(), let buffer = CMSampleBufferGetImageBuffer(sample) {
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            let p = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
            let row = CVPixelBufferGetBytesPerRow(buffer)
            out.append(Int(p[CVPixelBufferGetHeight(buffer) / 2 * row + 40 * 4 + 1]))
            CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
        }
        return out
    }

    func testATrimmedExportIsAsLongAsItsClipsAndCutsOnTheirFrames() async throws {
        var (source, project) = try await makeSource()
        project.events = .init()
        project.edits.clips = [Clip(start: 0, end: 0.5), Clip(start: 0.7, end: 0.9)]
        let out = folder.appendingPathComponent("trimmed.mp4")
        let report = try await VideoExporter.export(project: project, video: source, settings: ExportSettings(), to: out)
        XCTAssertEqual(report.framesWritten, 21)
        XCTAssertEqual(report.duration, 0.7, accuracy: 0.5 / 30, "the file is as long as what the clips keep")
        let shown = try await levels(out)
        let expected = (Array(0..<15) + Array(21..<27)).map { $0 * 8 }
        XCTAssertEqual(shown.count, expected.count)
        for (k, (got, want)) in zip(shown, expected).enumerated() {
            XCTAssertEqual(got, want, accuracy: 4, "output frame \(k) shows source frame \(want / 8)")
        }
        XCTAssertEqual(shown[14], 14 * 8, accuracy: 4, "the last frame before the cut is source frame 14")
        XCTAssertEqual(shown[15], 21 * 8, accuracy: 4, "the first frame after the cut is source frame 21, not 15")
    }

    /// A screen recording gets a frame only when the screen changes, so a clip can start long after the frame it shows.
    func testAClipStartingInAStillStretchShowsTheFrameBeforeIt() async throws {
        let url = folder.appendingPathComponent("screen.mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 180])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 180,
        ])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for (t, level) in [(0.0, 0), (0.1, 80), (0.9, 160)] {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
            CVPixelBufferLockBaseAddress(buffer!, [])
            memset(CVPixelBufferGetBaseAddress(buffer!), Int32(level), CVPixelBufferGetDataSize(buffer!))
            CVPixelBufferUnlockBaseAddress(buffer!, [])
            adaptor.append(buffer!, withPresentationTime: CMTime(seconds: t, preferredTimescale: 600))
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(seconds: 1, preferredTimescale: 600))
        await writer.finishWriting()
        var project = RecordingProject(source: .init(pixelWidth: 320, pixelHeight: 180, pointWidth: 160, pointHeight: 90, fps: 30, duration: 1))
        project.edits.clips = [Clip(start: 0.5, end: 1)]
        let out = folder.appendingPathComponent("still.mp4")
        _ = try await VideoExporter.export(project: project, video: url, settings: ExportSettings(), to: out)
        let shown = try await levels(out)
        XCTAssertEqual(shown.count, 15)
        XCTAssertEqual(shown.first ?? -1, 80, accuracy: 4, "at 0.5 s the screen still shows the frame from 0.1 s, not the one from 0.9 s")
        XCTAssertEqual(shown[11], 80, accuracy: 4, "source 0.867 s is still the 0.1 s frame")
        XCTAssertEqual(shown[12], 160, accuracy: 4, "source 0.9 s is the new frame")
    }

    /// A mono AAC track of `seconds` with a short full-scale burst at each of `clicks` seconds and silence elsewhere.
    private func makeSound(_ name: String, seconds: Double, clicks: [Double]) throws -> URL {
        let url = folder.appendingPathComponent(name)
        let rate = 48_000.0
        let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1])
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(seconds * rate))!
        buffer.frameLength = buffer.frameCapacity
        let samples = buffer.floatChannelData![0]
        for i in 0..<Int(buffer.frameLength) { samples[i] = 0 }
        for c in clicks { for i in 0..<240 { samples[Int(c * rate) + i] = Float(0.9 * cos(2 * .pi * 2000 * Double(i) / rate)) } }
        try file.write(from: buffer)
        return url
    }

    /// Where each burst starts in a file's sound, in seconds: the first loud sample more than a tenth of a second after the last.
    private func bursts(_ url: URL) throws -> (onsets: [Double], seconds: Double) {
        let file = try AVAudioFile(forReading: url)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        let rate = file.processingFormat.sampleRate, samples = buffer.floatChannelData![0]
        var onsets: [Double] = [], last = -Int.max / 2
        for i in 0..<Int(buffer.frameLength) where abs(samples[i]) > 0.3 {
            if i - last > Int(rate / 10) { onsets.append(Double(i) / rate) }
            last = i
        }
        return (onsets, Double(buffer.frameLength) / rate)
    }

    func testTheExportCarriesTheProjectSoundCutByTheSameClips() async throws {
        var (source, project) = try await makeSource(frames: 60)
        _ = try makeSound("mic.m4a", seconds: 2, clicks: [0.25, 1.25, 1.75])
        project.source.microphone = "mic.m4a"
        let whole = folder.appendingPathComponent("whole.mp4")
        let full = try await VideoExporter.export(project: project, video: source, settings: ExportSettings(), to: whole)
        let wholeSound = try bursts(whole)
        XCTAssertTrue(full.hasAudio)
        XCTAssertEqual(wholeSound.seconds, 2, accuracy: 0.03, "the sound is as long as the video")
        XCTAssertEqual(wholeSound.onsets.count, 3)
        for (got, want) in zip(wholeSound.onsets, [0.25, 1.25, 1.75]) { XCTAssertEqual(got, want, accuracy: 0.001, "a burst stays on its moment") }

        project.edits.clips = [Clip(start: 0, end: 0.5), Clip(start: 1.5, end: 2)]
        let cut = folder.appendingPathComponent("cut.mp4")
        let report = try await VideoExporter.export(project: project, video: source, settings: ExportSettings(), to: cut)
        let cutSound = try bursts(cut)
        XCTAssertEqual(report.duration, 1, accuracy: 1.0 / 30)
        XCTAssertEqual(cutSound.seconds, 1, accuracy: 0.03, "the sound keeps only what the clips keep")
        XCTAssertEqual(cutSound.onsets.count, 2, "the burst inside the removed stretch is gone")
        for (got, want) in zip(cutSound.onsets, [0.25, 0.75]) { XCTAssertEqual(got, want, accuracy: 0.001, "a burst after a cut moves with its clip") }
    }

    /// A Microphone track of 50 Hz hum and a 1 kHz voice-like tone, with a short loud burst at each of `bursts` seconds.
    private func makeHummingMicrophone(seconds: Double, tones: [(Double, Double)] = [(50, 0.1), (1_000, 0.1)], bursts: [Double] = []) throws -> URL {
        let url = folder.appendingPathComponent("mic.m4a")
        try TestSound.write(url, seconds: seconds, channels: [tones]) { _, t in
            bursts.contains { t >= $0 && t < $0 + 0.005 } ? Float(0.8 * cos(2 * .pi * 2_000 * t)) : 0
        }
        return url
    }

    private func level(_ frequency: Double, in url: URL, from: Double, to: Double) throws -> Double {
        let sound = try TestSound.read(url)
        return TestSound.amplitude(of: frequency, in: sound.channels[0], rate: sound.rate, from: from, to: to)
    }

    /// A Microphone track as a room records it: 50 Hz mains hum and steady fan noise throughout, and a short spoken sentence from
    /// 0.4 s that ends before 2.4 s.
    private func makeNoisyMicrophone(seconds: Double) throws -> URL {
        let url = folder.appendingPathComponent("mic.m4a")
        let noise = TestSound.noise(amplitude: 0.03)
        let voice = try TestSound.speech("Hello, testing the microphone.", in: folder).prefix(2 * 48_000)
        let start = Int(0.4 * 48_000)
        try TestSound.write(url, seconds: seconds, channels: [[(50, 0.1)]]) { c, t in
            let i = Int((t * 48_000).rounded()) - start
            return noise(c, t) + (voice.indices.contains(i) ? 0.5 * voice[i] : 0)
        }
        return url
    }

    func testVoiceCleanupAtItsDefaultsTakesHumAndNoiseOutOfTheExport() async throws {
        var (source, project) = try await makeSource(frames: 120)
        let mic = try makeNoisyMicrophone(seconds: 4)
        let recorded = try Data(contentsOf: mic)
        project.source.microphone = "mic.m4a"

        let raw = folder.appendingPathComponent("raw.mp4")
        _ = try await VideoExporter.export(project: project, video: source, settings: ExportSettings(), to: raw)
        project.edits.audio.voiceCleanup = VoiceCleanup(isOn: true)
        let clean = folder.appendingPathComponent("clean.mp4")
        let report = try await VideoExporter.export(project: project, video: source, settings: ExportSettings(), to: clean)

        XCTAssertTrue(report.hasAudio)
        XCTAssertEqual(report.voiceCleanup.noiseRemovalUnavailable, !TestSound.soundIsolationIsHere, "the export says whether Noise removal ran")
        let before = try TestSound.read(raw), after = try TestSound.read(clean)
        // Where nobody speaks.
        let hum = TestSound.decibels(TestSound.amplitude(of: 50, in: after.channels[0], rate: after.rate, from: 2.5, to: 3.5)
                                     / TestSound.amplitude(of: 50, in: before.channels[0], rate: before.rate, from: 2.5, to: 3.5))
        let floor = TestSound.decibels(TestSound.noiseFloor(after.channels[0], rate: after.rate, from: 2.5, to: 3.5)
                                       / TestSound.noiseFloor(before.channels[0], rate: before.rate, from: 2.5, to: 3.5))
        let loudness = try Loudness.integrated(of: clean)
        XCTAssertEqual(loudness, -16, accuracy: 1, "Leveling brings the exported voice to -16 LUFS")
        if TestSound.soundIsolationIsHere {
            XCTAssertLessThan(hum, -12, "the hum is clearly reduced")
            XCTAssertLessThan(floor, -6, "the fan noise is clearly reduced")
        } else {
            // Leveling raises the hum and the fan noise alike, and without Noise removal the noise stays, so the hum is measured
            // against it.
            XCTAssertLessThan(hum - floor, -12, "without Noise removal on this Mac the hum is still clearly reduced, and the export works")
        }

        project.edits.clips = [Clip(start: 0, end: 0.5), Clip(start: 2.5, end: 3.5)]
        let cutFile = folder.appendingPathComponent("cut.mp4")
        _ = try await VideoExporter.export(project: project, video: source, settings: ExportSettings(), to: cutFile)
        let cut = try TestSound.read(cutFile)
        XCTAssertEqual(Double(cut.channels[0].count) / cut.rate, 1.5, accuracy: 0.03, "the cleaned sound keeps only what the clips keep")
        // The same cleaned track, cut: the second clip's hum is the uncut export's at that moment, whatever Leveling made of it.
        func humLevel(_ sound: (channels: [[Float]], rate: Double), from: Double) -> Double {
            TestSound.amplitude(of: 50, in: sound.channels[0], rate: sound.rate, from: from, to: from + 0.8)
        }
        XCTAssertEqual(humLevel(cut, from: 0.6), humLevel(after, from: 2.6), accuracy: 0.25 * humLevel(before, from: 2.6), "the second clip carries the cleaned sound")
        XCTAssertEqual(try Data(contentsOf: mic), recorded, "the recorded microphone file is never changed")
    }

    func testWithVoiceCleanupOnTheExportCarriesTheCleanedMicrophoneTrackCutByTheSameClips() async throws {
        var (source, project) = try await makeSource(frames: 60)
        let mic = try makeHummingMicrophone(seconds: 2, bursts: [0.25, 1.25, 1.75])
        let recorded = try Data(contentsOf: mic)
        project.source.microphone = "mic.m4a"
        project.edits.clips = [Clip(start: 0, end: 0.5), Clip(start: 1.5, end: 2)]

        let raw = folder.appendingPathComponent("raw.mp4")
        _ = try await VideoExporter.export(project: project, video: source, settings: ExportSettings(), to: raw)
        // Knocks and pure tones are not speech, so Noise removal would take them out: this one follows the cut with Low cut alone.
        project.edits.audio.voiceCleanup = VoiceCleanup(isOn: true)
        project.edits.audio.voiceCleanup.noiseRemovalOn = false
        project.edits.audio.voiceCleanup.levelingOn = false
        let clean = folder.appendingPathComponent("clean.mp4")
        let report = try await VideoExporter.export(project: project, video: source, settings: ExportSettings(), to: clean)

        XCTAssertTrue(report.hasAudio)
        let hum = TestSound.decibels(try level(50, in: clean, from: 0.1, to: 0.9) / level(50, in: raw, from: 0.1, to: 0.9))
        let voice = TestSound.decibels(try level(1_000, in: clean, from: 0.1, to: 0.9) / level(1_000, in: raw, from: 0.1, to: 0.9))
        XCTAssertLessThan(hum, -10, "hum below the 80 Hz Low cut is clearly reduced")
        XCTAssertEqual(voice, 0, accuracy: 1, "the voice stays as it was")
        let cut = try bursts(clean)
        XCTAssertEqual(cut.seconds, 1, accuracy: 0.03, "the cleaned sound keeps only what the clips keep")
        XCTAssertEqual(cut.onsets.count, 2, "the burst inside the removed stretch is gone")
        for (got, want) in zip(cut.onsets, [0.25, 0.75]) { XCTAssertEqual(got, want, accuracy: 0.001, "a burst after a cut moves with its clip") }
        XCTAssertEqual(try Data(contentsOf: mic), recorded, "the recorded microphone file is never changed")
    }

    func testWithVoiceCleanupOffTheExportCarriesTheMicrophoneAsRecorded() async throws {
        var (source, project) = try await makeSource(frames: 60)
        _ = try makeHummingMicrophone(seconds: 2)
        project.source.microphone = "mic.m4a"
        // As the project saved before Voice cleanup: no Voice cleanup in its file at all.
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(project)) as? [String: Any])
        var edits = try XCTUnwrap(json["edits"] as? [String: Any]), audio = try XCTUnwrap(edits["audio"] as? [String: Any])
        audio["voiceCleanup"] = nil
        edits["audio"] = audio
        json["edits"] = edits
        let before = try JSONDecoder().decode(RecordingProject.self, from: JSONSerialization.data(withJSONObject: json))
        let today = folder.appendingPathComponent("today.mp4")
        _ = try await VideoExporter.export(project: before, video: source, settings: ExportSettings(), to: today)

        var cleanup = VoiceCleanup(isOn: false)
        cleanup.lowCutFrequency = 200
        project.edits.audio.voiceCleanup = cleanup
        let out = folder.appendingPathComponent("export.mp4")
        _ = try await VideoExporter.export(project: project, video: source, settings: ExportSettings(), to: out)
        XCTAssertEqual(try TestSound.read(out).channels, try TestSound.read(today).channels,
                       "Voice cleanup off mixes exactly the sound a project without it does, sample for sample")
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        XCTAssertEqual(Set(files), ["screen.mp4", "mic.m4a", "today.mp4", "export.mp4"], "nothing is cleaned while Voice cleanup is off")
    }

    func testAChangedSettingIsNeverServedFromTheOldCleanedTrack() async throws {
        var (source, project) = try await makeSource(frames: 60)
        _ = try makeHummingMicrophone(seconds: 2, tones: [(150, 0.2)])
        project.source.microphone = "mic.m4a"
        var cleanup = VoiceCleanup(isOn: true)
        cleanup.lowCutFrequency = 60
        cleanup.levelingOn = false
        project.edits.audio.voiceCleanup = cleanup
        let low = folder.appendingPathComponent("low.mp4")
        _ = try await VideoExporter.export(project: project, video: source, settings: ExportSettings(), to: low)
        project.edits.audio.voiceCleanup.lowCutFrequency = 200
        let high = folder.appendingPathComponent("high.mp4")
        _ = try await VideoExporter.export(project: project, video: source, settings: ExportSettings(), to: high)
        let change = TestSound.decibels(try level(150, in: high, from: 0.5, to: 1.5) / level(150, in: low, from: 0.5, to: 1.5))
        XCTAssertLessThan(change, -6, "150 Hz passes a 60 Hz Low cut and is cut by a 200 Hz one")
        project.edits.audio.voiceCleanup.lowCutFrequency = 60
        let again = folder.appendingPathComponent("again.mp4")
        _ = try await VideoExporter.export(project: project, video: source, settings: ExportSettings(), to: again)
        XCTAssertEqual(TestSound.decibels(try level(150, in: again, from: 0.5, to: 1.5) / level(150, in: low, from: 0.5, to: 1.5)), 0, accuracy: 0.5,
                       "going back to 60 Hz cleans for 60 Hz again")
    }

    func testTheCleanedMicrophoneAnExportMixesStaysWhileNewerSettingsAreRendered() async throws {
        var (_, project) = try await makeSource(frames: 30)
        let mic = try makeHummingMicrophone(seconds: 1)
        project.source.microphone = "mic.m4a"
        project.edits.audio.voiceCleanup = VoiceCleanup(isOn: true)
        project.edits.audio.voiceCleanup.levelingOn = false
        let (files, _, leases) = try await VideoExporter.soundFiles(project, in: folder)
        let mixed = try XCTUnwrap(files.first { $0.url.lastPathComponent.hasPrefix(VoiceCleanupCache.prefix) }?.url, "the export mixes the cleaned copy")

        var newer = project.edits.audio.voiceCleanup
        newer.lowCutFrequency = 200
        let previewed = try await VoiceCleanupRenders.shared.cleaned(mic, settings: newer).url
        XCTAssertTrue(FileManager.default.fileExists(atPath: mixed.path), "the preview's newer render leaves the file the export still mixes")

        leases.forEach(VoiceCleanupRenders.shared.release)
        await VoiceCleanupRenders.shared.removed()
        XCTAssertFalse(FileManager.default.fileExists(atPath: mixed.path), "once the export is done with it, the older copy goes")
        XCTAssertTrue(FileManager.default.fileExists(atPath: previewed.path))
    }

    func testAMissingCleanedMicrophoneFailsTheMixInsteadOfLeavingTheMicrophoneOut() async throws {
        let mic = try makeHummingMicrophone(seconds: 1)
        let gone = folder.appendingPathComponent(VoiceCleanupCache.prefix + "0000").appendingPathExtension("m4a")
        do {
            _ = try await AudioMixReader(files: [(mic, 1), (gone, 1)], duration: 1)
            XCTFail("a mix without the cleaned microphone must not be made")
        } catch {
            XCTAssertEqual(error as? CornermarkVideoEditor.ExportError, .writer("the cleaned microphone sound is missing"))
        }
    }

    func testWithVoiceCleanupOnTheExportedMicrophoneSitsAtMinus16LUFSAndTrackLevelStillApplies() async throws {
        var (source, project) = try await makeSource(frames: 60)
        // Quiet speech: Noise removal keeps a voice, where it would take pure tones out.
        let voice = try TestSound.speech("Hello, testing the microphone.", in: folder).prefix(2 * 48_000 - 4_800)
        try TestSound.write(folder.appendingPathComponent("mic.m4a"), seconds: 2, channels: [[]]) { _, t in
            let i = Int((t * 48_000).rounded()) - 4_800
            return voice.indices.contains(i) ? 0.05 * voice[i] : 0
        }
        project.source.microphone = "mic.m4a"
        project.edits.audio.voiceCleanup = VoiceCleanup(isOn: true)
        let full = folder.appendingPathComponent("full.mp4")
        _ = try await VideoExporter.export(project: project, video: source, settings: ExportSettings(), to: full)
        XCTAssertEqual(try Loudness.integrated(of: full), -16, accuracy: 1, "a quiet microphone is leveled to -16 LUFS at Track level 100%")

        project.edits.audio.microphone.level = 0.5
        let half = folder.appendingPathComponent("half.mp4")
        _ = try await VideoExporter.export(project: project, video: source, settings: ExportSettings(), to: half)
        XCTAssertEqual(try Loudness.integrated(of: half), -22, accuracy: 1, "Track level 50% lowers the leveled microphone by 6 dB")
    }

    func testCancellingLeavesNoFile() async throws {
        let (source, project) = try await makeSource(frames: 90)
        let out = folder.appendingPathComponent("export.mp4")
        // Progress arrives on the export's own thread, so the job is cancelled from outside, the way the editor's Cancel does.
        final class Job: @unchecked Sendable { var task: Task<ExportReport, Error>? }
        let job = Job()
        let task = Task { try await VideoExporter.export(project: project, video: source, settings: ExportSettings(), to: out) { fraction in
            if fraction > 0.2 { job.task?.cancel() }
        } }
        job.task = task
        do {
            _ = try await task.value
            XCTFail("a cancelled export must not finish")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["screen.mp4"], "nothing but the source is left")
    }

    func testFramesFollowThePointerTrack() throws {
        let project = RecordingProject(source: .init(pixelWidth: 200, pixelHeight: 100, pointWidth: 100, pointHeight: 50, fps: 30, duration: 1),
                                       events: .init(pointer: [PointerSample(t: 0, x: 20, y: 10)]))
        let renderer = ExportFrameRenderer(plan: ExportPlan(project: project, settings: ExportSettings()), project: project, folder: nil)
        let image = try XCTUnwrap(renderer.image(frameState(project, outputTime: 0), source: nil))
        let pixels = try XCTUnwrap(image.dataProvider?.data as Data?)
        func grey(_ x: Int, _ y: Int) -> UInt8 { pixels[y * image.bytesPerRow + x * 4 + 1] }
        XCTAssertGreaterThan(grey(20 * 2 + 3, 10 * 2 + 12), 200, "the pointer's white body is just below and right of its tip, y down")
        XCTAssertEqual(grey(150, 80), 0, "the rest is the black backdrop of a frame without a picture")
    }

    func testABlurredFrameIsTheAverageOfItsDrawings() throws {
        let pointer = (0...30).map { PointerSample(t: Double($0) / 30, x: 10 + Double($0) * 2.5, y: 20) }
        let project = RecordingProject(source: .init(pixelWidth: 200, pixelHeight: 100, pointWidth: 100, pointHeight: 50, fps: 30, duration: 1),
                                       events: .init(pointer: pointer), edits: .init(motionBlur: MotionBlur(shutterAngle: 360)))
        let renderer = ExportFrameRenderer(plan: ExportPlan(project: project, settings: ExportSettings()), project: project, folder: nil)
        let samples = frameSamples(project, outputTime: 0.5, fps: 30, pixelsAcross: renderer.frameRect.width)
        XCTAssertEqual(samples.count, 16)
        let blurred = try XCTUnwrap(renderer.image(samples, source: nil).flatMap { $0.dataProvider?.data as Data? })
        let drawings = try samples.map { try XCTUnwrap(renderer.image($0, source: nil)?.dataProvider?.data as Data?) }
        var worst = 0
        for i in 0..<blurred.count {
            let mean = (drawings.reduce(0.0) { $0 + Double($1[i]) } / Double(drawings.count)).rounded()
            worst = max(worst, abs(Int(blurred[i]) - Int(mean)))
        }
        XCTAssertLessThanOrEqual(worst, 1, "the accumulator matches a plain average of the separate drawings")
        let sharp = try XCTUnwrap(renderer.image(frameState(project, outputTime: 0.5), source: nil)?.dataProvider?.data as Data?)
        XCTAssertNotEqual(blurred, sharp)
        let one = try XCTUnwrap(renderer.image([samples[0]], source: nil)?.dataProvider?.data as Data?)
        XCTAssertEqual(one, drawings[0], "one sample is drawn as the sharp frame is")
    }

    func testAZoomMovesThePointerAndLeavesTheCameraBubbleInTheFrame() throws {
        let zoom = Zoom(start: 0, end: 1, scale: 2, center: ZoomPoint(x: 0.25, y: 0.25))
        var project = RecordingProject(source: .init(pixelWidth: 400, pixelHeight: 200, pointWidth: 100, pointHeight: 50, fps: 30, duration: 1),
                                       events: .init(pointer: [PointerSample(t: 0, x: 20, y: 10)]), edits: .init(zooms: [zoom]))
        project.source.camera = RecordingProjectFile.cameraName
        let renderer = ExportFrameRenderer(plan: ExportPlan(project: project, settings: ExportSettings()), project: project, folder: nil)
        let red = try XCTUnwrap(solidImage(red: 255))
        func pixels(_ project: RecordingProject, at t: Double) throws -> (CGImage, Data) {
            let image = try XCTUnwrap(renderer.image(frameState(project, outputTime: t), source: nil, camera: red))
            return (image, try XCTUnwrap(image.dataProvider?.data as Data?))
        }
        var plain = project
        plain.edits.zooms = []
        let (zoomedImage, zoomed) = try pixels(project, at: 0.5)
        let (_, whole) = try pixels(plain, at: 0.5)
        func level(_ image: CGImage, _ data: Data, _ x: Int, _ y: Int, channel: Int) -> UInt8 { data[y * image.bytesPerRow + x * 4 + channel] }
        let area = CGSize(width: 100, height: 50)
        let bubble = CameraLayout.bubbleRect(project.edits.camera, area: area)
        let bx = Int(bubble.midX * 4), by = Int(bubble.midY * 4)
        XCTAssertEqual(level(zoomedImage, zoomed, bx, by, channel: 2), 255, "the bubble's red is where it is without the zoom")
        XCTAssertEqual(level(zoomedImage, zoomed, bx, by, channel: 2), level(zoomedImage, whole, bx, by, channel: 2))
        // The crop is the top-left half, so the pointer's tip, at (20, 10) points, is at (40, 20) points of the frame, 4 pixels per point.
        XCTAssertGreaterThan(level(zoomedImage, zoomed, 40 * 4 + 6, 20 * 4 + 20, channel: 1), 200, "the pointer moved with the picture, twice as far from the corner")
        XCTAssertLessThan(level(zoomedImage, zoomed, 20 * 4 + 6, 10 * 4 + 20, channel: 1), 60, "and is not where it was")
        XCTAssertGreaterThan(level(zoomedImage, whole, 20 * 4 + 6, 10 * 4 + 20, channel: 1), 200, "without the zoom it is there")
    }

    private func solidImage(red: UInt8) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: CGFloat(red) / 255, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        return ctx.makeImage()
    }

    func testTheExportDrawsTheCameraFromItsOwnFileWhereTheProjectPlacesIt() async throws {
        var (source, project) = try await makeSource()
        _ = try await makeSource(name: RecordingProjectFile.cameraName) { _ in [0x20, 0x20, 0xE0, 0xFF] }
        project.source.camera = RecordingProjectFile.cameraName
        func exported(_ name: String) async throws -> CGImage {
            let out = folder.appendingPathComponent(name)
            _ = try await VideoExporter.export(project: project, video: source, settings: ExportSettings(), to: out)
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: out))
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            return try await generator.image(at: CMTime(value: 15, timescale: 30)).image
        }
        func rgb(_ image: CGImage, _ x: Double, _ y: Double) -> [Int] {
            var px = [UInt8](repeating: 0, count: 4)
            let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(image.cropping(to: CGRect(x: Int(x), y: Int(y), width: 1, height: 1))!, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return px.prefix(3).map(Int.init)
        }
        let area = CGSize(width: project.source.pointWidth, height: project.source.pointHeight)
        let bubble = CameraLayout.bubbleRect(project.edits.camera, area: area)
        let k = 320 / area.width
        let shown = try await exported("with-camera.mp4")
        XCTAssertGreaterThan(rgb(shown, bubble.midX * k, bubble.midY * k)[0], 180, "the camera's red fills its bubble, at the project's place, y down")
        XCTAssertLessThan(rgb(shown, 300, 20)[0], 140, "and nowhere else")
        project.edits.camera.isVisible = false
        let hidden = try await exported("without-camera.mp4")
        XCTAssertLessThan(rgb(hidden, bubble.midX * k, bubble.midY * k)[0], 140, "a hidden camera is not drawn")
        project.edits.camera = CameraBubble(fullScreen: [CameraSpan(from: 0, to: 1)])
        let full = try await exported("full-camera.mp4")
        XCTAssertGreaterThan(rgb(full, 300, 20)[0], 180, "a full-screen span fills the whole picture with the camera")
    }
}
