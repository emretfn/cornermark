import AVFoundation
import CornermarkCore
import XCTest
@testable import CornermarkVideoEditor

/// Synthetic sound for the Voice cleanup tests: tones written to a file the way a recording writes its Microphone track.
enum TestSound {
    /// An AAC file at 48 kHz whose channel `c` is the sum of `tones[c]`, each a (frequency in Hz, amplitude) sine. `lossless` writes
    /// 32-bit float PCM instead (give the URL a .caf extension), for a test that must see every sample as the renderer made it.
    static func write(_ url: URL, seconds: Double, channels tones: [[(Double, Double)]], lossless: Bool = false,
                      extra: ((Int, Double) -> Float)? = nil) throws {
        let rate = 48_000.0
        let settings: [String: Any] = lossless
            ? [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: tones.count, AVLinearPCMBitDepthKey: 32,
               AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false]
            : [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: tones.count, AVEncoderBitRateKey: 128_000 * tones.count]
        let file = try AVAudioFile(forWriting: url, settings: settings)
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

    /// Whether this Mac has Apple's sound isolation unit. Only that decides whether a test can measure Noise removal: a render that
    /// reports the step unavailable while the unit is here is a failure, not a reason to skip.
    static var soundIsolationIsHere: Bool {
        var unit = NoiseRemoval.apple
        return AudioComponentFindNext(nil, &unit) != nil
    }

    static func decibels(_ ratio: Double) -> Double { 20 * log10(max(ratio, 1e-12)) }

    /// The highest peak of `samples`, between samples too: the largest value of the sound resampled to 8 times its rate by Core Audio's
    /// own converter.
    static func truePeak(_ samples: [Float], rate: Double) throws -> Float {
        let from = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!, to = AVAudioFormat(standardFormatWithSampleRate: rate * 8, channels: 1)!
        let converter = try XCTUnwrap(AVAudioConverter(from: from, to: to))
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        let input = AVAudioPCMBuffer(pcmFormat: from, frameCapacity: AVAudioFrameCount(samples.count))!
        input.frameLength = input.frameCapacity
        samples.withUnsafeBufferPointer { input.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        let output = AVAudioPCMBuffer(pcmFormat: to, frameCapacity: AVAudioFrameCount(samples.count * 8 + 4_096))!
        var given = false
        var error: NSError?
        _ = converter.convert(to: output, error: &error) { _, status in
            if given { status.pointee = .endOfStream; return nil }
            given = true
            status.pointee = .haveData
            return input
        }
        if let error { throw error }
        return UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)).map(abs).max() ?? 0
    }

    /// The root mean square of `samples` between `from` and `to` seconds: how loud everything there is together.
    static func rms(_ samples: [Float], rate: Double, from: Double, to: Double) -> Double {
        let range = Int(from * rate)..<min(Int(to * rate), samples.count)
        return (range.reduce(0.0) { $0 + Double(samples[$1] * samples[$1]) } / Double(max(range.count, 1))).squareRoot()
    }

    /// How loud the broadband noise is between `from` and `to` seconds, with low hum hardly counting: the RMS of the change from one
    /// sample to the next, which a slow sine barely has and noise has in full.
    static func noiseFloor(_ samples: [Float], rate: Double, from: Double, to: Double) -> Double {
        let range = max(Int(from * rate), 1)..<min(Int(to * rate), samples.count)
        let sum = range.reduce(0.0) { let d = Double(samples[$1] - samples[$1 - 1]); return $0 + d * d }
        return (sum / Double(max(range.count, 1)) / 2).squareRoot()
    }

    /// Steady broadband noise of about `amplitude` peak, the same on every run: a fan or a room, as a microphone hears it.
    static func noise(amplitude: Double) -> (Int, Double) -> Float {
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        return { _, _ in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Float(amplitude * (Double(state >> 11) / Double(1 << 53) * 2 - 1))
        }
    }
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

    private func onlyNoiseRemoval(strength: Double) -> VoiceCleanup {
        VoiceCleanup(isOn: true, lowCutOn: false, noiseRemovalOn: true, noiseRemovalStrength: strength, noiseGateOn: false, levelingOn: false)
    }

    func testNoiseRemovalLowersSteadyNoiseWhereNobodySpeaks() throws {
        let input = folder.appendingPathComponent("mic.m4a"), output = folder.appendingPathComponent("clean.m4a")
        // Fan noise throughout, a voice-like tone in the middle.
        let noise = TestSound.noise(amplitude: 0.05)
        try TestSound.write(input, seconds: 6, channels: [[]]) { c, t in noise(c, t) + (t > 2.5 && t < 3.5 ? Float(0.2 * sin(2 * .pi * 300 * t)) : 0) }
        try XCTSkipUnless(TestSound.soundIsolationIsHere, "this Mac has no sound isolation unit, so there is nothing to measure")
        let report = try VoiceCleanupRenderer.render(input, settings: onlyNoiseRemoval(strength: 1), to: output)
        XCTAssertFalse(report.noiseRemovalUnavailable, "the unit is here, so Noise removal runs")

        let before = try TestSound.read(input), after = try TestSound.read(output)
        let change = TestSound.decibels(TestSound.rms(after.channels[0], rate: 48_000, from: 4.5, to: 5.5)
                                        / TestSound.rms(before.channels[0], rate: 48_000, from: 4.5, to: 5.5))
        XCTAssertLessThan(change, -6, "steady noise where nobody speaks is clearly lower")
        XCTAssertEqual(after.channels[0].count, before.channels[0].count, "the cleaned track is as long as the recorded one")
    }

    func testNoiseRemovalAtStrengthZeroLeavesTheSoundAsItCameIn() throws {
        let input = folder.appendingPathComponent("mic.m4a"), output = folder.appendingPathComponent("clean.m4a")
        try TestSound.write(input, seconds: 3, channels: [[(300, 0.2)]], extra: TestSound.noise(amplitude: 0.05))
        let report = try VoiceCleanupRenderer.render(input, settings: onlyNoiseRemoval(strength: 0), to: output)

        XCTAssertFalse(report.noiseRemovalUnavailable)
        let before = try TestSound.read(input), after = try TestSound.read(output)
        let change = TestSound.decibels(TestSound.rms(after.channels[0], rate: 48_000, from: 0.5, to: 2.5) / TestSound.rms(before.channels[0], rate: 48_000, from: 0.5, to: 2.5))
        XCTAssertEqual(change, 0, accuracy: 0.5, "nothing is taken out")
        XCTAssertEqual(TestSound.decibels(TestSound.amplitude(of: 300, in: after.channels[0], rate: 48_000, from: 0.5, to: 2.5)
                                          / TestSound.amplitude(of: 300, in: before.channels[0], rate: 48_000, from: 0.5, to: 2.5)), 0, accuracy: 0.5)
    }

    func testNoiseRemovalAtHalfStrengthKeepsHalfTheSoundAsRecordedOnItsMoment() throws {
        let input = folder.appendingPathComponent("mic.m4a"), output = folder.appendingPathComponent("clean.m4a")
        let noise = TestSound.noise(amplitude: 0.05)
        // Steady noise with one loud knock at 3 s.
        try TestSound.write(input, seconds: 6, channels: [[]]) { c, t in noise(c, t) + (t >= 3 && t < 3.005 ? Float(0.8 * cos(2 * .pi * 2_000 * t)) : 0) }
        try XCTSkipUnless(TestSound.soundIsolationIsHere, "this Mac has no sound isolation unit, so there is nothing to measure")
        let half = try VoiceCleanupRenderer.render(input, settings: onlyNoiseRemoval(strength: 0.5), to: output)
        let full = folder.appendingPathComponent("full.m4a")
        let all = try VoiceCleanupRenderer.render(input, settings: onlyNoiseRemoval(strength: 1), to: full)
        XCTAssertEqual([half, all].map(\.noiseRemovalUnavailable), [false, false], "the unit is here, so Noise removal runs")

        let before = try TestSound.read(input).channels[0], halfway = try TestSound.read(output).channels[0], whole = try TestSound.read(full).channels[0]
        func noiseLevel(_ s: [Float]) -> Double { TestSound.rms(s, rate: 48_000, from: 4.5, to: 5.5) }
        XCTAssertLessThan(noiseLevel(halfway), noiseLevel(before) * 0.7, "half strength takes noise out")
        XCTAssertGreaterThan(noiseLevel(halfway), noiseLevel(whole) * 1.5, "but less than full strength")
        let knock = halfway.indices.first { $0 > 2 * 48_000 && abs(halfway[$0]) > 0.25 }.map { Double($0) / 48_000 }
        XCTAssertEqual(knock ?? 0, 3, accuracy: 0.001, "the sound stays on its moment however late the unit answers")
    }

    func testWithoutItsUnitNoiseRemovalIsReportedUnavailableAndTheOtherStepsStillClean() throws {
        let input = folder.appendingPathComponent("mic.m4a"), output = folder.appendingPathComponent("clean.m4a")
        try TestSound.write(input, seconds: 3, channels: [[(50, 0.3), (1_000, 0.3)]])
        var settings = onlyLowCut(at: 150)
        settings.noiseRemovalOn = true
        let missing = AudioComponentDescription(componentType: kAudioUnitType_Effect, componentSubType: 0x6E6F_6E65, componentManufacturer: 0x6E6F_6E65,
                                                componentFlags: 0, componentFlagsMask: 0)
        let report = try VoiceCleanupRenderer.render(input, settings: settings, to: output, soundIsolation: missing)

        XCTAssertTrue(report.noiseRemovalUnavailable, "the renderer says Noise removal could not run")
        let before = try TestSound.read(input), after = try TestSound.read(output)
        XCTAssertEqual(after.channels[0].count, before.channels[0].count, "the cleaned track is still whole")
        func level(_ f: Double, _ s: [Float]) -> Double { TestSound.amplitude(of: f, in: s, rate: 48_000, from: 1, to: 2.5) }
        XCTAssertLessThan(TestSound.decibels(level(50, after.channels[0]) / level(50, before.channels[0])), -20, "Low cut still runs")
        XCTAssertEqual(TestSound.decibels(level(1_000, after.channels[0]) / level(1_000, before.channels[0])), 0, accuracy: 1,
                       "the sound Noise removal would have changed passes as it came")
    }

    func testATrackCleanedWithoutItsNoiseRemovalIsMadeAgainOnceTheUnitRuns() throws {
        try XCTSkipUnless(TestSound.soundIsolationIsHere, "this Mac has no sound isolation unit, so it can never run")
        let mic = folder.appendingPathComponent("mic.m4a")
        try TestSound.write(mic, seconds: 3, channels: [[]], extra: TestSound.noise(amplitude: 0.05))
        let settings = onlyNoiseRemoval(strength: 1)
        let missing = AudioComponentDescription(componentType: kAudioUnitType_Effect, componentSubType: 0x6E6F_6E65, componentManufacturer: 0x6E6F_6E65,
                                                componentFlags: 0, componentFlagsMask: 0)
        let without = try VoiceCleanupCache.prepare(mic, settings: settings, soundIsolation: missing)
        XCTAssertTrue(without.report.noiseRemovalUnavailable, "the report says Noise removal could not run")
        let noise = TestSound.rms(try TestSound.read(without.url).channels[0], rate: 48_000, from: 1, to: 2.5)

        let with = try VoiceCleanupCache.prepare(mic, settings: settings)
        XCTAssertFalse(with.report.noiseRemovalUnavailable)
        XCTAssertLessThan(TestSound.rms(try TestSound.read(with.url).channels[0], rate: 48_000, from: 1, to: 2.5), noise / 2,
                          "the same settings, once the unit runs, are cleaned again and not served the track made without it")
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

    private let onlyLeveling = VoiceCleanup(isOn: true, lowCutOn: false, noiseRemovalOn: false, noiseGateOn: false, levelingOn: true)

    /// Speech-like sound: a 300 Hz voice with harmonics, in syllables of 150 ms with gaps, at `level` (dBFS of the loudest peak), with
    /// the stretch from `loud` seconds on 12 dB louder than the rest.
    private func speech(_ url: URL, level: Double, seconds: Double = 8, loud: Double = 4) throws {
        try TestSound.write(url, seconds: seconds, channels: [[]]) { _, t in
            let syllable = t.truncatingRemainder(dividingBy: 0.25) < 0.15 ? sin(.pi * t.truncatingRemainder(dividingBy: 0.25) / 0.15) : 0
            let voice = (0.6 * sin(2 * .pi * 300 * t) + 0.3 * sin(2 * .pi * 600 * t) + 0.1 * sin(2 * .pi * 1_200 * t)) * syllable
            return Float(voice * pow(10, (level - (t < loud ? 12 : 0)) / 20))
        }
    }

    func testLevelingBringsQuietAndLoudSpeechToMinus16LUFSWithoutClipping() throws {
        for level in [-40.0, -0.5] {
            let input = folder.appendingPathComponent("mic-\(Int(level)).m4a"), output = folder.appendingPathComponent("clean-\(Int(level)).m4a")
            try speech(input, level: level)
            try VoiceCleanupRenderer.render(input, settings: onlyLeveling, to: output)

            XCTAssertEqual(try Loudness.integrated(of: output), -16, accuracy: 1, "speech peaking at \(level) dB lands on -16 LUFS")
            let after = try TestSound.read(output)
            XCTAssertLessThan(after.channels[0].map(abs).max() ?? 1, 1, "speech peaking at \(level) dB never clips")
            XCTAssertEqual(try AVAudioFile(forReading: output).length, try AVAudioFile(forReading: input).length)
        }
    }

    func testLevelingCatchesASpikeBetweenSamplesUnderItsCeilingWithoutFlatteningIt() throws {
        let input = folder.appendingPathComponent("mic.caf"), output = folder.appendingPathComponent("clean.caf")
        // Quiet speech with one sharp 12 kHz spike at 3 s, a quarter of the rate and half way between samples, so every sample sits
        // 3 dB under the spike's real peak.
        let speech = folder.appendingPathComponent("speech.m4a")
        try self.speech(speech, level: -30, seconds: 6)
        let voice = try TestSound.read(speech).channels[0]
        try TestSound.write(input, seconds: 6, channels: [[]], lossless: true) { _, t in
            let i = Int(t * 48_000)
            return (i < voice.count ? voice[i] : 0) + (t >= 3 && t < 3.002 ? Float(0.5 * sin(2 * .pi * 12_000 * t + .pi / 4)) : 0)
        }
        try VoiceCleanupRenderer.render(input, settings: onlyLeveling, to: output)

        let after = try TestSound.read(output).channels[0]
        XCTAssertLessThanOrEqual(try TestSound.truePeak(after, rate: 48_000), Leveling.ceiling * 1.012,
                                 "the spike's peak between samples stays under the ceiling, within 0.1 dB")
        XCTAssertLessThan(after.filter { abs($0) >= Leveling.ceiling * 0.999 }.count, 3, "the limiter lowered the spike instead of cutting it flat")
    }

    func testLevelingBringsPeakySpeechToMinus16LUFS() throws {
        let input = folder.appendingPathComponent("mic.caf"), output = folder.appendingPathComponent("clean.m4a")
        // Speech whose every syllable starts with a sharp click 13 dB over the voice, as plosives close to the microphone make it: the
        // limiter has to pull the clicks down hard, which takes loudness out of the voice right after them.
        let speech = folder.appendingPathComponent("speech.m4a")
        try self.speech(speech, level: -30, seconds: 8, loud: 0)
        let voice = try TestSound.read(speech).channels[0]
        try TestSound.write(input, seconds: 8, channels: [[]], lossless: true) { _, t in
            let i = Int(t * 48_000), into = t.truncatingRemainder(dividingBy: 0.25)
            return (i < voice.count ? voice[i] : 0) + (into < 0.002 ? Float(0.15 * sin(2 * .pi * 3_000 * t)) : 0)
        }
        try VoiceCleanupRenderer.render(input, settings: onlyLeveling, to: output)

        XCTAssertEqual(try Loudness.integrated(of: output), -16, accuracy: 1, "peaky speech still lands on -16 LUFS")
    }

    func testLevelingRaisesANearlySilentTrackBy40dBAtMost() throws {
        let input = folder.appendingPathComponent("mic.m4a"), output = folder.appendingPathComponent("clean.m4a")
        // Speech so far from the microphone that it is barely there, more than 40 dB under -16 LUFS.
        try speech(input, level: -55, loud: 0)
        let before = try Loudness.integrated(of: input)
        XCTAssertLessThan(before, -60)
        try VoiceCleanupRenderer.render(input, settings: onlyLeveling, to: output)

        XCTAssertEqual(try Loudness.integrated(of: output) - before, 40, accuracy: 0.5, "a track this quiet is raised by 40 dB, not all the way")
    }

    func testLevelingEvensOutLoudAndSoftSpeech() throws {
        let input = folder.appendingPathComponent("mic.m4a"), output = folder.appendingPathComponent("clean.m4a")
        try speech(input, level: -10)
        try VoiceCleanupRenderer.render(input, settings: onlyLeveling, to: output)
        let after = try TestSound.read(output)
        func voice(_ from: Double) -> Double { TestSound.amplitude(of: 300, in: after.channels[0], rate: 48_000, from: from, to: from + 2) }
        XCTAssertLessThan(TestSound.decibels(voice(5.5) / voice(1.5)), 9, "a stretch spoken 12 dB louder ends up closer to the rest")
    }

    func testLevelingLeavesSilenceSilent() throws {
        let input = folder.appendingPathComponent("mic.m4a"), output = folder.appendingPathComponent("clean.m4a")
        try TestSound.write(input, seconds: 2, channels: [[]])
        try VoiceCleanupRenderer.render(input, settings: onlyLeveling, to: output)
        XCTAssertLessThan(try TestSound.read(output).channels[0].map(abs).max() ?? 1, 0.001)
    }

    func testStepsNotYetBuiltPassTheSoundThrough() throws {
        let input = folder.appendingPathComponent("mic.m4a"), output = folder.appendingPathComponent("clean.m4a")
        try TestSound.write(input, seconds: 2, channels: [[(50, 0.3), (1_000, 0.3)]])
        var settings = VoiceCleanup(isOn: true)
        settings.lowCutOn = false
        settings.noiseRemovalOn = false
        settings.levelingOn = false
        try VoiceCleanupRenderer.render(input, settings: settings, to: output)
        let before = try TestSound.read(input), after = try TestSound.read(output)
        for f in [50.0, 1_000] {
            let change = TestSound.decibels(TestSound.amplitude(of: f, in: after.channels[0], rate: 48_000, from: 0.5, to: 1.5)
                                            / TestSound.amplitude(of: f, in: before.channels[0], rate: 48_000, from: 0.5, to: 1.5))
            XCTAssertEqual(change, 0, accuracy: 1, "with Low cut, Noise removal and Leveling off, \(Int(f)) Hz passes Noise gate unchanged for now")
        }
    }
}
