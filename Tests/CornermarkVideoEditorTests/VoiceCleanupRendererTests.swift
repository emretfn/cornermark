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
        let report = try VoiceCleanupRenderer.render(input, settings: onlyNoiseRemoval(strength: 1), to: output)
        try XCTSkipIf(report.noiseRemovalUnavailable, "the sound isolation unit cannot run on this Mac, so there is nothing to measure")

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
        let half = try VoiceCleanupRenderer.render(input, settings: onlyNoiseRemoval(strength: 0.5), to: output)
        try XCTSkipIf(half.noiseRemovalUnavailable, "the sound isolation unit cannot run on this Mac, so there is nothing to measure")
        let full = folder.appendingPathComponent("full.m4a")
        try VoiceCleanupRenderer.render(input, settings: onlyNoiseRemoval(strength: 1), to: full)

        let before = try TestSound.read(input).channels[0], halfway = try TestSound.read(output).channels[0], all = try TestSound.read(full).channels[0]
        func noiseLevel(_ s: [Float]) -> Double { TestSound.rms(s, rate: 48_000, from: 4.5, to: 5.5) }
        XCTAssertLessThan(noiseLevel(halfway), noiseLevel(before) * 0.7, "half strength takes noise out")
        XCTAssertGreaterThan(noiseLevel(halfway), noiseLevel(all) * 1.5, "but less than full strength")
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
        settings.noiseRemovalOn = false
        try VoiceCleanupRenderer.render(input, settings: settings, to: output)
        let before = try TestSound.read(input), after = try TestSound.read(output)
        for f in [50.0, 1_000] {
            let change = TestSound.decibels(TestSound.amplitude(of: f, in: after.channels[0], rate: 48_000, from: 0.5, to: 1.5)
                                            / TestSound.amplitude(of: f, in: before.channels[0], rate: 48_000, from: 0.5, to: 1.5))
            XCTAssertEqual(change, 0, accuracy: 1, "with Low cut and Noise removal off, \(Int(f)) Hz passes Noise gate and Leveling unchanged for now")
        }
    }
}
