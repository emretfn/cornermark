import AVFoundation
import CornermarkCore
import XCTest
@testable import CornermarkVideoEditor

/// Synthetic sound for the Voice cleanup tests: tones written to a file the way a recording writes its Microphone track.
enum TestSound {
    /// An AAC file at 48 kHz whose channel `c` is the sum of `tones[c]`, each a (frequency in Hz, amplitude) sine.
    static func write(_ url: URL, seconds: Double, channels tones: [[(Double, Double)]], extra: ((Int, Double) -> Float)? = nil) throws {
        let rate = 48_000.0
        let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: tones.count,
                                                              AVEncoderBitRateKey: 128_000 * tones.count])
        let frames = Int(seconds * rate)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = buffer.frameCapacity
        for (c, sines) in tones.enumerated() {
            let samples = buffer.floatChannelData![c]
            for i in 0..<frames {
                let t = Double(i) / rate
                samples[i] = Float(sines.reduce(0) { $0 + $1.1 * sin(2 * .pi * $1.0 * t) }) + (extra?(c, t) ?? 0)
            }
        }
        try file.write(from: buffer)
    }

    /// Every channel of a sound file, or of the sound track of a video, as 48 kHz floats.
    static func read(_ url: URL) throws -> (channels: [[Float]], rate: Double) {
        let file = try AVAudioFile(forReading: url)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        let channels = (0..<Int(buffer.format.channelCount)).map { Array(UnsafeBufferPointer(start: buffer.floatChannelData![$0], count: Int(buffer.frameLength))) }
        return (channels, file.processingFormat.sampleRate)
    }

    /// The amplitude of the `frequency` sine in `samples` between `from` and `to` seconds, measured by correlation, so other
    /// frequencies hardly count.
    static func amplitude(of frequency: Double, in samples: [Float], rate: Double, from: Double, to: Double) -> Double {
        // A whole number of periods, so the other tones average out.
        let periods = ((to - from) * frequency).rounded(.down)
        let start = Int(from * rate), count = Int(periods / frequency * rate)
        var s = 0.0, c = 0.0
        for i in start..<min(start + count, samples.count) {
            let phase = 2 * .pi * frequency * Double(i) / rate
            s += Double(samples[i]) * sin(phase)
            c += Double(samples[i]) * cos(phase)
        }
        return 2 * (s * s + c * c).squareRoot() / Double(count)
    }

    static func decibels(_ ratio: Double) -> Double { 20 * log10(max(ratio, 1e-12)) }
}

final class VoiceCleanupRendererTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("cornermark-voice-cleanup-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }

    private func onlyLowCut(at frequency: Double) -> VoiceCleanup {
        VoiceCleanup(isOn: true, lowCutOn: true, lowCutFrequency: frequency, noiseRemovalOn: false, noiseGateOn: false, levelingOn: false)
    }

    func testLowCutRemovesSoundBelowItsFrequencyAndKeepsTheRest() throws {
        let input = folder.appendingPathComponent("mic.m4a"), output = folder.appendingPathComponent("clean.m4a")
        try TestSound.write(input, seconds: 3, channels: [[(50, 0.3), (1_000, 0.3)]])
        try VoiceCleanupRenderer.render(input, settings: onlyLowCut(at: 150), to: output)

        let before = try TestSound.read(input), after = try TestSound.read(output)
        func level(_ f: Double, _ s: [Float]) -> Double { TestSound.amplitude(of: f, in: s, rate: 48_000, from: 1, to: 2.5) }
        let hum = TestSound.decibels(level(50, after.channels[0]) / level(50, before.channels[0]))
        let voice = TestSound.decibels(level(1_000, after.channels[0]) / level(1_000, before.channels[0]))
        XCTAssertLessThan(hum, -20, "50 Hz is well below a 150 Hz Low cut")
        XCTAssertEqual(voice, 0, accuracy: 1, "1 kHz is far above it and stays as it was")
    }

    private func onlyNoiseGate(at threshold: Double) -> VoiceCleanup {
        VoiceCleanup(isOn: true, lowCutOn: false, noiseRemovalOn: false, noiseGateOn: true, noiseGateThreshold: threshold, levelingOn: false)
    }

    func testNoiseGateSilencesSoundBelowItsThresholdAndKeepsSoundAbove() throws {
        let input = folder.appendingPathComponent("mic.m4a"), output = folder.appendingPathComponent("clean.m4a")
        // A breath-like 1 kHz at -60 dBFS for the first second, then a voice-like 1 kHz at -40 dBFS for the next.
        try TestSound.write(input, seconds: 2.5, channels: [[]]) { _, t in
            Float((t < 1 ? 0.001 : t < 2 ? 0.01 : 0) * sin(2 * .pi * 1_000 * t))
        }
        try VoiceCleanupRenderer.render(input, settings: onlyNoiseGate(at: -50), to: output)

        let before = try TestSound.read(input), after = try TestSound.read(output)
        func change(from: Double, to: Double) -> Double {
            TestSound.decibels(TestSound.amplitude(of: 1_000, in: after.channels[0], rate: 48_000, from: from, to: to)
                               / TestSound.amplitude(of: 1_000, in: before.channels[0], rate: 48_000, from: from, to: to))
        }
        XCTAssertLessThan(change(from: 0.2, to: 0.9), -40, "-60 dBFS stays below a -50 dB Noise gate and goes silent")
        XCTAssertEqual(change(from: 1.1, to: 1.9), 0, accuracy: 1, "-40 dBFS is above it and stays as it was")
    }

    /// The RMS of `samples` between `from` and `to` seconds.
    private func rms(_ samples: [Float], from: Double, to: Double) -> Double {
        let part = samples[Int(from * 48_000)..<min(Int(to * 48_000), samples.count)]
        return (part.reduce(0) { $0 + Double($1) * Double($1) } / Double(part.count)).squareRoot()
    }

    /// Gaussian noise with an RMS of `level`, the same each run, as fans, hiss and breaths make it: peaks well above the average.
    private func noise(rms level: Double) -> () -> Float {
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        func uniform() -> Double {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return (Double(seed >> 11) + 0.5) / Double(1 << 53)
        }
        return { Float(level * (-2 * log(uniform())).squareRoot() * cos(2 * .pi * uniform())) }
    }

    func testNoiseGateSilencesNoiseWhoseLevelStaysBelowItsThreshold() throws {
        let input = folder.appendingPathComponent("mic.m4a"), output = folder.appendingPathComponent("clean.m4a")
        // A fan-like hiss at -60 dBFS RMS: its level is 10 dB under a -50 dB Noise gate, though its single peaks reach above it.
        let hiss = noise(rms: 0.001)
        try TestSound.write(input, seconds: 2, channels: [[]]) { _, _ in hiss() }
        try VoiceCleanupRenderer.render(input, settings: onlyNoiseGate(at: -50), to: output)

        let before = try TestSound.read(input), after = try TestSound.read(output)
        XCTAssertGreaterThan(before.channels[0][Int(0.2 * 48_000)..<Int(1.9 * 48_000)].map(abs).max() ?? 0, 0.00316, "the hiss peaks above the threshold")
        let change = TestSound.decibels(rms(after.channels[0], from: 0.2, to: 1.9) / rms(before.channels[0], from: 0.2, to: 1.9))
        XCTAssertLessThan(change, -40, "noise whose level stays below the Noise gate threshold goes silent")
    }

    func testNoiseGateClosesAgainAfterLouderSound() throws {
        let input = folder.appendingPathComponent("mic.m4a"), output = folder.appendingPathComponent("clean.m4a")
        // A voice-like 1 kHz at -40 dBFS for the first second, then -60 dBFS RMS hiss, as when a sentence ends and the fan goes on.
        let hiss = noise(rms: 0.001)
        try TestSound.write(input, seconds: 2.5, channels: [[]]) { _, t in Float(t < 1 ? 0.01 * sin(2 * .pi * 1_000 * t) : 0) + hiss() }
        try VoiceCleanupRenderer.render(input, settings: onlyNoiseGate(at: -50), to: output)

        let before = try TestSound.read(input), after = try TestSound.read(output)
        let voice = TestSound.decibels(TestSound.amplitude(of: 1_000, in: after.channels[0], rate: 48_000, from: 0.2, to: 0.9)
                                       / TestSound.amplitude(of: 1_000, in: before.channels[0], rate: 48_000, from: 0.2, to: 0.9))
        XCTAssertEqual(voice, 0, accuracy: 1, "the voice comes through")
        // Hold and release are over well before 1.3 s.
        let tail = TestSound.decibels(rms(after.channels[0], from: 1.3, to: 2.4) / rms(before.channels[0], from: 1.3, to: 2.4))
        XCTAssertLessThan(tail, -40, "once the voice stops, the Noise gate closes and the hiss goes silent")
    }

    func testNoiseGateKeepsTheStartOfAWordAfterSilence() throws {
        let input = folder.appendingPathComponent("mic.m4a"), output = folder.appendingPathComponent("clean.m4a")
        // Silence, then a word-like 500 Hz at -20 dBFS starting at once at 1 s.
        try TestSound.write(input, seconds: 2, channels: [[]]) { _, t in Float(t < 1 ? 0 : 0.1 * sin(2 * .pi * 500 * t)) }
        try VoiceCleanupRenderer.render(input, settings: onlyNoiseGate(at: -50), to: output)

        let before = try TestSound.read(input), after = try TestSound.read(output)
        let onset = TestSound.decibels(TestSound.amplitude(of: 500, in: after.channels[0], rate: 48_000, from: 1, to: 1.02)
                                       / TestSound.amplitude(of: 500, in: before.channels[0], rate: 48_000, from: 1, to: 1.02))
        XCTAssertEqual(onset, 0, accuracy: 1, "the first 20 ms of the word come through")
    }

    func testNoiseGateKeepsTheStartOfAWordJustAboveItsThreshold() throws {
        let input = folder.appendingPathComponent("mic.m4a"), output = folder.appendingPathComponent("clean.m4a")
        // Silence, then a quiet word-like 500 Hz at -44 dBFS RMS, 6 dB over a -50 dB Noise gate, starting at once at 1 s.
        try TestSound.write(input, seconds: 2, channels: [[]]) { _, t in Float(t < 1 ? 0 : 0.0089 * sin(2 * .pi * 500 * t)) }
        try VoiceCleanupRenderer.render(input, settings: onlyNoiseGate(at: -50), to: output)

        let before = try TestSound.read(input), after = try TestSound.read(output)
        let onset = TestSound.decibels(TestSound.amplitude(of: 500, in: after.channels[0], rate: 48_000, from: 1, to: 1.02)
                                       / TestSound.amplitude(of: 500, in: before.channels[0], rate: 48_000, from: 1, to: 1.02))
        XCTAssertEqual(onset, 0, accuracy: 1, "the first 20 ms of a quiet word come through")
        XCTAssertEqual(after.channels[0].count, before.channels[0].count, "the cleaned track keeps its length")
    }

    func testNoiseGateJudgesTheSoundAfterLowCut() throws {
        let input = folder.appendingPathComponent("mic.m4a"), output = folder.appendingPathComponent("clean.m4a")
        // A -30 dBFS hum that Low cut removes, under a -60 dBFS 1 kHz breath that the Noise gate should then silence.
        try TestSound.write(input, seconds: 2, channels: [[(50, 0.03), (1_000, 0.001)]])
        var settings = onlyNoiseGate(at: -50)
        settings.lowCutOn = true
        settings.lowCutFrequency = 150
        try VoiceCleanupRenderer.render(input, settings: settings, to: output)

        let before = try TestSound.read(input), after = try TestSound.read(output)
        let breath = TestSound.decibels(TestSound.amplitude(of: 1_000, in: after.channels[0], rate: 48_000, from: 0.5, to: 1.5)
                                        / TestSound.amplitude(of: 1_000, in: before.channels[0], rate: 48_000, from: 0.5, to: 1.5))
        XCTAssertLessThan(breath, -40, "with the hum cut first, nothing is left above the Noise gate threshold")
    }

    func testTheCleanedFileKeepsTheLengthRateAndChannelsAndLeavesTheRecordedFileAlone() throws {
        let input = folder.appendingPathComponent("mic.m4a"), output = folder.appendingPathComponent("clean.m4a")
        // A microphone in the first of two channels, as an audio interface records it.
        try TestSound.write(input, seconds: 2, channels: [[(60, 0.3), (440, 0.3)], []])
        let recorded = try Data(contentsOf: input)
        try VoiceCleanupRenderer.render(input, settings: onlyLowCut(at: 120), to: output)

        let inFile = try AVAudioFile(forReading: input), outFile = try AVAudioFile(forReading: output)
        XCTAssertEqual(outFile.length, inFile.length)
        XCTAssertEqual(outFile.fileFormat.sampleRate, inFile.fileFormat.sampleRate)
        XCTAssertEqual(outFile.fileFormat.channelCount, 2)
        let after = try TestSound.read(output)
        XCTAssertGreaterThan(TestSound.amplitude(of: 440, in: after.channels[0], rate: 48_000, from: 0.5, to: 1.5), 0.25, "the voice stays in its channel")
        XCTAssertLessThan(after.channels[1].map(abs).max() ?? 1, 0.01, "the silent channel stays silent")
        XCTAssertEqual(try Data(contentsOf: input), recorded, "the recorded file is never changed")
    }

    func testStepsNotYetBuiltPassTheSoundThrough() throws {
        let input = folder.appendingPathComponent("mic.m4a"), output = folder.appendingPathComponent("clean.m4a")
        try TestSound.write(input, seconds: 2, channels: [[(50, 0.3), (1_000, 0.3)]])
        var settings = VoiceCleanup(isOn: true)
        settings.lowCutOn = false
        try VoiceCleanupRenderer.render(input, settings: settings, to: output)
        let before = try TestSound.read(input), after = try TestSound.read(output)
        for f in [50.0, 1_000] {
            let change = TestSound.decibels(TestSound.amplitude(of: f, in: after.channels[0], rate: 48_000, from: 0.5, to: 1.5)
                                            / TestSound.amplitude(of: f, in: before.channels[0], rate: 48_000, from: 0.5, to: 1.5))
            XCTAssertEqual(change, 0, accuracy: 1, "with Low cut off, \(Int(f)) Hz passes Noise removal, Noise gate and Leveling unchanged for now")
        }
    }
}
