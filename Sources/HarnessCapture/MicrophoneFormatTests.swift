import AVFoundation
@testable import CornermarkCapture
import CornermarkCore

/// The format a device sends its buffers in for `seconds`.
struct DeviceFormat {
    var rate: Double
    var channels: Int
    var int16 = false
    var interleaved = false
    var seconds: Double
    var name: String { "\(Int(rate)) Hz \(channels) ch \(int16 ? "int16" : "float32")\(interleaved ? " interleaved" : "")" }
}

/// A microphone that sends real sample buffers, 10 ms each, through the live microphone's own reading code. They are stamped on a device
/// clock 500 s behind the recording clock that also runs 200 ppm fast, as an audio device's clock does. The first buffer starts `delay`
/// seconds after `origin`, as a headset that takes a moment to open, and `gap` seconds of nothing separate two formats, as a headset
/// switching profile. Every sample is `signal` at the moment it was heard on the recording clock.
final class DeviceBufferSource: AudioSource {
    static let clockRate = 1.0002
    let formats: [DeviceFormat]
    let origin: Double
    let delay: Double
    let gap: Double
    let signal: (Double) -> Float
    let clock: CMTimebase
    private(set) var made = 0
    private(set) var delivered = 0

    init(_ formats: [DeviceFormat], origin: Double, delay: Double = 0, gap: Double = 0, signal: @escaping (Double) -> Float) {
        self.formats = formats; self.origin = origin; self.delay = delay; self.gap = gap; self.signal = signal
        var timebase: CMTimebase?
        CMTimebaseCreateWithSourceClock(allocator: nil, sourceClock: CMClockGetHostTimeClock(), timebaseOut: &timebase)
        clock = timebase!
        CMTimebaseSetRateAndAnchorTime(clock, rate: Self.clockRate, anchorTime: Self.time(origin - 500), immediateSourceTime: Self.time(origin))
    }

    private static func time(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 1_000_000_000) }

    /// Device time from recording time, and back.
    func device(_ t: Double) -> Double { origin - 500 + (t - origin) * Self.clockRate }
    func recording(_ d: Double) -> Double { origin + (d - (origin - 500)) / Self.clockRate }

    func start(_ deliver: @escaping (AudioChunk) -> Void) throws {
        var at = device(origin + delay)
        for format in formats {
            let frames = Int(format.rate / 100)
            for n in 0..<Int(format.seconds * 100) {
                let first = at + Double(n * frames) / format.rate
                let buffer = makeBuffer(format, frames: frames, first: first)
                made += 1
                if let chunk = LiveMicrophoneSource.chunk(buffer, clock: clock) {
                    delivered += 1
                    deliver(chunk)
                }
            }
            at += format.seconds + gap
        }
    }

    func stop() {}

    private func makeBuffer(_ f: DeviceFormat, frames: Int, first: Double) -> CMSampleBuffer {
        let format = AVAudioFormat(commonFormat: f.int16 ? .pcmFormatInt16 : .pcmFormatFloat32, sampleRate: f.rate,
                                   channels: AVAudioChannelCount(f.channels), interleaved: f.interleaved)!
        let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        pcm.frameLength = AVAudioFrameCount(frames)
        for i in 0..<frames {
            let v = signal(recording(first + Double(i) / f.rate))
            for c in 0..<f.channels {
                let slot = f.interleaved ? (0, i * f.channels + c) : (c, i)
                if f.int16 { pcm.int16ChannelData![slot.0][slot.1] = Int16(max(-1, min(1, v)) * 32767) } else { pcm.floatChannelData![slot.0][slot.1] = v }
            }
        }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(f.rate)), presentationTimeStamp: Self.time(first),
                                        decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreate(allocator: nil, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil, refcon: nil, formatDescription: format.formatDescription,
                             sampleCount: frames, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil,
                             sampleBufferOut: &sample)
        CMSampleBufferSetDataBufferFromAudioBufferList(sample!, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, bufferList: pcm.audioBufferList)
        return sample!
    }
}

@MainActor
func runMicrophoneFormatTests() async {
    let dir = URL(fileURLWithPath: recordingScratch + "microphone-formats/", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let origin = 1200.0
    let clicks = AudioPattern.Clicks(epoch: origin + 0.5, period: 1)
    let amplitude: Float = 0.1
    let voice: (Double) -> Float = { t in clicks.value(at: t) ?? amplitude * Float(sin(2 * .pi * 180 * t)) }
    let expectedRMS = amplitude / Float(2).squareRoot()

    let cases: [(String, [DeviceFormat], Double, Double)] = [
        ("16 kHz mono", [DeviceFormat(rate: 16_000, channels: 1, seconds: 5.2)], 0, 0),
        ("24 kHz mono, a Bluetooth headset", [DeviceFormat(rate: 24_000, channels: 1, seconds: 5.2)], 0, 0),
        ("44.1 kHz mono", [DeviceFormat(rate: 44_100, channels: 1, seconds: 5.2)], 0, 0),
        ("48 kHz stereo", [DeviceFormat(rate: 48_000, channels: 2, seconds: 5.2)], 0, 0),
        ("24 kHz mono int16 interleaved", [DeviceFormat(rate: 24_000, channels: 1, int16: true, interleaved: true, seconds: 5.2)], 0, 0),
        ("48 kHz stereo turning into 24 kHz mono, opened late",
         [DeviceFormat(rate: 48_000, channels: 2, seconds: 1.8), DeviceFormat(rate: 24_000, channels: 1, seconds: 3.2)], 0.4, 0.2),
    ]
    for (index, (name, formats, delay, gap)) in cases.enumerated() {
        section("a microphone at any input format: \(name)")
        do {
            var options = RecordingOptions()
            options.fps = 60
            let source = FixtureFrameSource(area: CGRect(x: 0, y: 0, width: 320, height: 180), options: options, pacing: .scripted(frames: 300, origin: origin))
            let mic = DeviceBufferSource(formats, origin: origin, delay: delay, gap: gap, signal: voice)
            let file = dir.appendingPathComponent("microphone-\(index).m4a")
            let recorder = Recorder(source: source, output: dir.appendingPathComponent("video.mp4"),
                                    microphone: AudioRecording(source: mic, output: file, mono: true))
            try await recorder.start()
            let report = try await recorder.stop()
            let videoSeconds = report.duration + 1.0 / 60
            check(mic.made > 0 && mic.delivered == mic.made, "every buffer becomes sound", detail: "\(mic.delivered) of \(mic.made)")
            guard let track = report.audio.first, let facts = await readAudio(file) else {
                check(false, "the microphone track is written", detail: "failure \(recorder.audioFailures[.microphone].map { "\($0)" } ?? "none")")
                continue
            }
            let samples = facts.channels[0]
            func level(_ from: Double, _ to: Double) -> AudioLevel {
                let a = max(0, Int(from * facts.rate)), b = min(samples.count, Int(to * facts.rate))
                return AudioLevel.measure([b > a ? Array(samples[a..<b]) : []])
            }
            print("FORMAT \(name) track rate=\(Int(track.rate)) seconds=\(String(format: "%.4f", track.duration)) filled=\(String(format: "%.4f", track.filled)) video=\(String(format: "%.4f", videoSeconds))")
            check(abs(facts.duration - videoSeconds) < 0.001 && abs(track.duration - videoSeconds) < 0.001, "the track is exactly as long as the video",
                  detail: "file \(facts.duration) report \(track.duration) video \(videoSeconds)")
            let voiced = [1.0, 2.0, 3.0, 4.0].map { level($0, $0 + 0.3).rms }
            print("FORMAT \(name) rms=\(voiced.map { String(format: "%.4f", $0) }) expected=\(String(format: "%.4f", expectedRMS))")
            check(voiced.allSatisfy { abs($0 - expectedRMS) / expectedRMS < 0.1 }, "the voice keeps its level, within 10%", detail: "\(voiced)")
            let onsets = clickOnsets(samples, rate: facts.rate)
            let expected = (0..<5).map { clicks.epoch + Double($0) * clicks.period - report.firstFrameTime }
            let residuals = expected.compactMap { e in onsets.min { abs($0 - e) < abs($1 - e) }.map { ($0 - e) * 1000 } }
            print("FORMAT \(name) clickResidualMs=\(residuals.map { String(format: "%.3f", $0) })")
            check(residuals.count == 5 && residuals.allSatisfy { abs($0) < 1 }, "every click lands within 1 ms of where the clock puts it", detail: "\(residuals)")
            if delay > 0 {
                let before = level(0.05, delay - 0.05).peak, between = level(delay + formats[0].seconds + 0.03, delay + formats[0].seconds + gap - 0.03).peak
                check(before < 0.001 && between < 0.001, "the moment before the device opened and the switch between formats are silence",
                      detail: "before \(before) between \(between)")
            }
        } catch { check(false, "the recording runs", detail: "\(error)") }
    }
}
