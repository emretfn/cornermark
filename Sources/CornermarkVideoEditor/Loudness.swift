import AVFoundation

/// Integrated loudness in LUFS as ITU-R BS.1770-4 measures it: K-weighted, in 400 ms blocks every 100 ms, gated at -70 LUFS and then
/// 10 LU below the mean. Every channel weighs 1, and a one-channel file counts on both speakers, as a finished video plays it.
enum Loudness {
    /// The loudness of deinterleaved `channels` at `rate`, minus infinity for silence.
    static func integrated(_ channels: [[Float]], rate: Double) -> Double {
        let meter = LoudnessMeter(channels: channels.count, rate: rate)
        let count = channels.first?.count ?? 0
        let copies = channels.map { samples -> UnsafeMutablePointer<Float> in
            let copy = UnsafeMutablePointer<Float>.allocate(capacity: max(count, 1))
            copy.initialize(from: samples, count: count)
            return copy
        }
        defer { copies.forEach { $0.deallocate() } }
        meter.add(copies, count: count)
        return meter.integrated
    }

    /// The loudness of a sound file, or of a video's sound track.
    static func integrated(of url: URL) throws -> Double {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let meter = LoudnessMeter(format: file.processingFormat)
        try meter.add(file)
        return meter.integrated
    }
}

/// Measures loudness as sound streams through it, a chunk at a time, so a whole track never has to be in memory.
final class LoudnessMeter {
    /// The two K-weighting stages for any rate, worked out from their analog prototypes; at 48 kHz they are BS.1770's coefficients.
    private static func kWeighting(rate: Double) -> [Biquad] {
        // Stage 1: a high shelf, +4 dB above about 1.7 kHz, for the head.
        var k = tan(.pi * 1_681.974_450_955_533 / rate), q = 0.707_175_236_955_419_6
        let vh = pow(10, 3.999_843_853_973_347 / 20), vb = pow(vh, 0.499_666_774_154_541_6)
        var a0 = 1 + k / q + k * k
        let shelf = Biquad(b0: (vh + vb * k / q + k * k) / a0, b1: 2 * (k * k - vh) / a0, b2: (vh - vb * k / q + k * k) / a0,
                           a1: 2 * (k * k - 1) / a0, a2: (1 - k / q + k * k) / a0)
        // Stage 2: a high-pass at about 38 Hz.
        k = tan(.pi * 38.135_470_876_024_44 / rate)
        q = 0.500_327_037_323_877_3
        a0 = 1 + k / q + k * k
        let highPass = Biquad(b0: 1, b1: -2, b2: 1, a1: 2 * (k * k - 1) / a0, a2: (1 - k / q + k * k) / a0)
        return [shelf, highPass]
    }

    private var filters: [[Biquad]]
    /// How much a channel's power counts: 1 each, 2 for a lone channel that plays on both speakers.
    private let weight: Double
    /// Frames in a 100 ms step; a gating block is four steps.
    private let step: Int
    private var stepPower = 0.0, stepFrames = 0
    /// The last four steps' weighted power sums, oldest first.
    private var recent: [Double] = []
    /// Every gating block's mean weighted power.
    private var blocks: [Double] = []

    init(channels: Int, rate: Double) {
        filters = Array(repeating: Self.kWeighting(rate: rate), count: channels)
        weight = channels == 1 ? 2 : 1
        step = max(1, Int((rate / 10).rounded()))
    }

    convenience init(format: AVAudioFormat) { self.init(channels: Int(format.channelCount), rate: format.sampleRate) }

    /// Reads the rest of `file` in, a chunk at a time. Run in a task, it stops at the next chunk once the task is cancelled.
    func add(_ file: AVAudioFile) throws {
        let chunk = VoiceCleanupRenderer.chunk
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk) else { throw VoiceCleanupError.unreadable }
        while file.framePosition < file.length {
            try Task.checkCancellation()
            try file.read(into: buffer, frameCount: min(chunk, AVAudioFrameCount(file.length - file.framePosition)))
            guard buffer.frameLength > 0 else { break }
            add(buffer)
        }
    }

    func add(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData else { return }
        add((0..<filters.count).map { data[$0] }, count: Int(buffer.frameLength))
    }

    func add(_ channels: [UnsafeMutablePointer<Float>], count: Int) {
        for i in 0..<count {
            var power = 0.0
            for c in filters.indices {
                var x = Double(channels[c][i])
                for s in filters[c].indices { x = filters[c][s].run(x) }
                power += x * x
            }
            stepPower += power * weight
            stepFrames += 1
            if stepFrames == step {
                recent.append(stepPower)
                if recent.count > 4 { recent.removeFirst() }
                if recent.count == 4 { blocks.append(recent.reduce(0, +) / Double(4 * step)) }
                stepPower = 0
                stepFrames = 0
            }
        }
    }

    /// The gated loudness of everything added so far, in LUFS; minus infinity when nothing is louder than the absolute gate.
    var integrated: Double {
        func lufs(_ power: Double) -> Double { -0.691 + 10 * log10(power) }
        let audible = blocks.filter { lufs($0) > -70 }
        guard !audible.isEmpty else { return -.infinity }
        let relative = lufs(audible.reduce(0, +) / Double(audible.count)) - 10
        let kept = audible.filter { lufs($0) > relative }
        return lufs(kept.reduce(0, +) / Double(kept.count))
    }
}
