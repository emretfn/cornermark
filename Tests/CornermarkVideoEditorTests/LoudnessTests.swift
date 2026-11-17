import AVFoundation
import XCTest
@testable import CornermarkVideoEditor

/// The loudness meter against the reference signals of EBU Tech 3341, the conformance tests for ITU-R BS.1770 meters.
final class LoudnessTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("cornermark-loudness-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }

    /// 1 kHz on every channel, `levels` (dBFS of the sine's peak, seconds) one after another.
    private func sine(channels: Int, _ levels: [(Double, Double)]) -> [[Float]] {
        let rate = 48_000.0
        var samples: [Float] = []
        for (level, seconds) in levels {
            let amplitude = pow(10, level / 20)
            for _ in 0..<Int(seconds * rate) { samples.append(Float(amplitude * sin(2 * .pi * 1_000 * Double(samples.count) / rate))) }
        }
        return Array(repeating: samples, count: channels)
    }

    func testAStereoSineAtMinus23DecibelsMeasuresMinus23LUFS() {
        // EBU Tech 3341 case 1.
        XCTAssertEqual(Loudness.integrated(sine(channels: 2, [(-23, 20)]), rate: 48_000), -23, accuracy: 0.1)
        // Case 2.
        XCTAssertEqual(Loudness.integrated(sine(channels: 2, [(-33, 20)]), rate: 48_000), -33, accuracy: 0.1)
    }

    func testQuietStretchesBelowTheRelativeGateDoNotCount() {
        // EBU Tech 3341 case 3, shortened: -36, -23, -36 dB reads -23 LUFS. The few blocks that straddle a change of level count, which
        // a 60 s middle hides and a 6 s one does not, hence the wider tolerance.
        XCTAssertEqual(Loudness.integrated(sine(channels: 2, [(-36, 2), (-23, 6), (-36, 2)]), rate: 48_000), -23, accuracy: 0.3)
        XCTAssertEqual(Loudness.integrated(sine(channels: 2, [(-72, 2), (-23, 6), (-72, 2)]), rate: 48_000), -23, accuracy: 0.3,
                       "silence below the absolute gate does not count")
    }

    func testAMonoTrackMeasuresAsItPlaysOnBothSpeakers() {
        XCTAssertEqual(Loudness.integrated(sine(channels: 1, [(-23, 10)]), rate: 48_000), -23, accuracy: 0.1)
    }

    func testSilenceHasNoLoudness() {
        XCTAssertEqual(Loudness.integrated([[Float](repeating: 0, count: 48_000)], rate: 48_000), -.infinity)
    }

    func testAFileIsMeasuredLikeItsSamples() throws {
        let url = folder.appendingPathComponent("sine.caf")
        let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 2,
                                                              AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true])
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 44_100 * 5)!
        buffer.frameLength = buffer.frameCapacity
        for c in 0..<2 { for i in 0..<Int(buffer.frameLength) { buffer.floatChannelData![c][i] = Float(pow(10, -23.0 / 20) * sin(2 * .pi * 1_000 * Double(i) / 44_100)) } }
        try file.write(from: buffer)
        XCTAssertEqual(try Loudness.integrated(of: url), -23, accuracy: 0.1, "K-weighting is worked out for 44.1 kHz too")
    }
}
