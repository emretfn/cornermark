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
        settings.levelingOn = false
        try VoiceCleanupRenderer.render(input, settings: settings, to: output)
        let before = try TestSound.read(input), after = try TestSound.read(output)
        for f in [50.0, 1_000] {
            let change = TestSound.decibels(TestSound.amplitude(of: f, in: after.channels[0], rate: 48_000, from: 0.5, to: 1.5)
                                            / TestSound.amplitude(of: f, in: before.channels[0], rate: 48_000, from: 0.5, to: 1.5))
            XCTAssertEqual(change, 0, accuracy: 1, "with Low cut and Leveling off, \(Int(f)) Hz passes Noise removal and Noise gate unchanged for now")
        }
    }
}
