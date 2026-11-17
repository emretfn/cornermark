import AVFoundation
import CornermarkCore
import CryptoKit

/// Makes the cleaned Microphone track: the recorded file through the Voice cleanup steps, written as a new file of the same length,
/// sample rate and channels. It runs offline, as fast as the machine allows, and never changes the recorded file.
public enum VoiceCleanupRenderer {
    /// Frames read, cleaned and written at a time.
    static let chunk: AVAudioFrameCount = 16_384

    /// Writes `input` cleaned as `settings` say to `output`, replacing a file already there. Every channel is cleaned the same way,
    /// so a microphone in one channel of two stays where it was. `settings.isOn` is the caller's business: this cleans either way.
    public static func render(_ input: URL, settings: VoiceCleanup, to output: URL) throws {
        let source = try AVAudioFile(forReading: input, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = source.processingFormat
        try? FileManager.default.removeItem(at: output)
        let target = try AVAudioFile(forWriting: output, settings: outputSettings(like: source.fileFormat), commonFormat: .pcmFormatFloat32, interleaved: false)
        let steps = chain(settings, format: format)
        guard let leveling = steps.last as? Leveling else { return try run(source, through: steps, into: target) }
        // Leveling needs the loudness of the whole track before it can set any of it, so the sound goes through two temporary files:
        // the steps (Leveling measuring), then Leveling's compressor (measuring again), then its normalization into `target`.
        let measured = temporaryFile(), compressed = temporaryFile()
        defer { try? FileManager.default.removeItem(at: measured); try? FileManager.default.removeItem(at: compressed) }
        try run(source, through: steps, into: measured, format: format)
        try run(AVAudioFile(forReading: measured, commonFormat: .pcmFormatFloat32, interleaved: false), through: [leveling.compressor()], into: compressed, format: format)
        try leveling.normalize(AVAudioFile(forReading: compressed, commonFormat: .pcmFormatFloat32, interleaved: false), into: target)
    }

    /// Runs `source` through `steps` into a new uncompressed float file at `url`, so a pass in between loses nothing. The file is
    /// closed when this returns.
    private static func run(_ source: AVAudioFile, through steps: [CleanupStep], into url: URL, format: AVAudioFormat) throws {
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try run(source, through: steps, into: file)
    }

    private static func temporaryFile() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("cornermark-leveling-\(UUID().uuidString).caf")
    }

    /// Reads all of `source`, a chunk at a time, through `steps` into `target`.
    private static func run(_ source: AVAudioFile, through steps: [CleanupStep], into target: AVAudioFile) throws {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: chunk) else { throw ExportError.writer("the sound could not be read") }
        while source.framePosition < source.length {
            try source.read(into: buffer, frameCount: min(chunk, AVAudioFrameCount(source.length - source.framePosition)))
            guard buffer.frameLength > 0 else { break }
            for step in steps { step.process(buffer) }
            try target.write(from: buffer)
        }
    }

    /// The steps that are on, always in this order: Low cut, Noise removal, Noise gate, Leveling. Track level comes later, in the mix.
    static func chain(_ settings: VoiceCleanup, format: AVAudioFormat) -> [CleanupStep] {
        var steps: [CleanupStep] = []
        if settings.lowCutOn { steps.append(LowCut(frequency: settings.lowCutFrequency, format: format)) }
        if settings.noiseRemovalOn { steps.append(PassThrough()) }
        if settings.noiseGateOn { steps.append(PassThrough()) }
        if settings.levelingOn { steps.append(Leveling(format: format)) }
        return steps
    }

    /// The recorded file's encoding, rate and channels. AAC keeps a cleaned track about as small as the recorded one.
    private static func outputSettings(like format: AVAudioFormat) -> [String: Any] {
        var settings = format.settings
        if (settings[AVFormatIDKey] as? NSNumber)?.uint32Value == kAudioFormatMPEG4AAC {
            settings[AVEncoderBitRateKey] = 128_000 * Int(format.channelCount)
        }
        return settings
    }
}

/// One Voice cleanup step: a transform of the sound, fed the file chunk after chunk from start to end. A step keeps whatever it needs
/// between chunks, so one instance cleans one file.
protocol CleanupStep: AnyObject {
    /// Changes `buffer`'s deinterleaved float samples in place, keeping its length.
    func process(_ buffer: AVAudioPCMBuffer)
}

/// A step whose cleaning is not built yet. It leaves the sound as it is.
final class PassThrough: CleanupStep {
    func process(_ buffer: AVAudioPCMBuffer) {}
}

/// Low cut: a 24 dB per octave Butterworth high-pass at `frequency`, two biquads in a row, so hum an octave below is about 24 dB down
/// and speech above it stays as it was.
final class LowCut: CleanupStep {
    private struct Biquad {
        var b0 = 0.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0

        /// A high-pass at `frequency` with quality `q`, from Robert Bristow-Johnson's Audio EQ Cookbook.
        init(highPass frequency: Double, q: Double, rate: Double) {
            let w = 2 * Double.pi * min(frequency, rate * 0.45) / rate
            let alpha = sin(w) / (2 * q), cosw = cos(w), a0 = 1 + alpha
            b0 = (1 + cosw) / 2 / a0
            b1 = -(1 + cosw) / a0
            b2 = b0
            a1 = -2 * cosw / a0
            a2 = (1 - alpha) / a0
        }

        mutating func run(_ samples: UnsafeMutablePointer<Float>, count: Int) {
            for i in 0..<count {
                let x = Double(samples[i])
                let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
                x2 = x1; x1 = x; y2 = y1; y1 = y
                samples[i] = Float(y)
            }
        }
    }

    /// The qualities of the two sections of a fourth-order Butterworth filter.
    private static let qualities = [0.541_196_100_146_197, 1.306_562_964_876_376_6]
    /// One pair of sections per channel, since each channel has its own history.
    private var sections: [[Biquad]]

    init(frequency: Double, format: AVAudioFormat) {
        let one = Self.qualities.map { Biquad(highPass: frequency, q: $0, rate: format.sampleRate) }
        sections = Array(repeating: one, count: Int(format.channelCount))
    }

    func process(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData else { return }
        let count = Int(buffer.frameLength)
        for c in sections.indices where c < Int(buffer.format.channelCount) {
            for s in sections[c].indices { sections[c][s].run(data[c], count: count) }
        }
    }
}

/// Leveling: a compressor that evens out loud and soft speech, then the whole track brought to -16 LUFS under a peak ceiling, so it
/// never clips. In the chain it only measures; `render` then runs `compressor()` and `normalize` over the whole track in turn.
final class Leveling: CleanupStep {
    /// The loudness the track ends at, the common target for streamed speech.
    static let target = -16.0
    /// The highest sample allowed, 1.5 dB under full scale, which leaves room for the peaks between samples and for the AAC encoder.
    static let ceiling = Float(pow(10, -1.5 / 20))

    private let format: AVAudioFormat
    private let meter: LoudnessMeter
    private var compressing: Compressor?

    init(format: AVAudioFormat) {
        self.format = format
        meter = LoudnessMeter(format: format)
    }

    func process(_ buffer: AVAudioPCMBuffer) { meter.add(buffer) }

    /// The second pass: the sound raised or lowered to the target first, so the compressor's threshold sits at the same place in
    /// every voice, then its loud stretches pulled down.
    func compressor() -> CleanupStep {
        let compressor = Compressor(gain: Self.gain(from: meter.integrated), format: format)
        compressing = compressor
        return compressor
    }

    /// The last pass: `source`, the compressor's output, brought to the target and written to `target`. A limiter that looks 5 ms
    /// ahead lowers the gain smoothly before any peak that would pass the ceiling, so no sample does.
    func normalize(_ source: AVAudioFile, into target: AVAudioFile) throws {
        let gain = Float(Self.gain(from: compressing?.loudness ?? -.infinity)), ceiling = Self.ceiling
        let channels = Int(format.channelCount), look = max(1, Int(format.sampleRate * 0.005))
        let release = 1 - exp(-1 / (format.sampleRate * 0.1))
        guard let input = AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: VoiceCleanupRenderer.chunk),
              let output = AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: VoiceCleanupRenderer.chunk),
              let out = output.floatChannelData else { throw ExportError.writer("the sound could not be read") }
        // Frames read but not yet written, by frame number modulo `look`.
        var delay = [[Float]](repeating: [Float](repeating: 0, count: look), count: channels)
        // The gain each read frame needs to stay under the ceiling, increasing from front to back, so the front is the lowest needed
        // over the next `look` frames.
        var needed: [(frame: Int, gain: Double)] = [], front = 0
        // The last `look` lowest gains, averaged, so the gain glides down over `look` frames and reaches each peak's need in time.
        var recent = [Double](repeating: 1, count: look), sum = Double(look), level = 1.0
        var read = 0, written = 0
        output.frameLength = 0

        func emit() throws {
            while needed[front].frame < written { front += 1 }
            let slot = written % look
            sum += needed[front].gain - recent[slot]
            recent[slot] = needed[front].gain
            let glide = sum / Double(look)
            level = glide < level ? glide : level + (glide - level) * release
            let n = Int(output.frameLength)
            for c in 0..<channels { out[c][n] = max(-ceiling, min(ceiling, delay[c][slot] * Float(level))) }
            output.frameLength += 1
            written += 1
            if output.frameLength == output.frameCapacity {
                try target.write(from: output)
                output.frameLength = 0
            }
            if front > 4_096 {
                needed.removeFirst(front)
                front = 0
            }
        }

        while source.framePosition < source.length {
            try source.read(into: input, frameCount: min(VoiceCleanupRenderer.chunk, AVAudioFrameCount(source.length - source.framePosition)))
            guard input.frameLength > 0, let data = input.floatChannelData else { break }
            for i in 0..<Int(input.frameLength) {
                var peak: Float = 0
                for c in 0..<channels {
                    let v = data[c][i] * gain
                    delay[c][read % look] = v
                    peak = max(peak, abs(v))
                }
                let need = peak > ceiling ? Double(ceiling / peak) : 1
                while needed.count > front, needed[needed.count - 1].gain >= need { needed.removeLast() }
                needed.append((read, need))
                read += 1
                if read >= look { try emit() }
            }
        }
        while written < read { try emit() }
        if output.frameLength > 0 { try target.write(from: output) }
    }

    /// The gain that brings sound measured at `loudness` to the target; none for silence.
    private static func gain(from loudness: Double) -> Double { loudness.isFinite ? pow(10, (target - loudness) / 20) : 1 }
}

/// Leveling's compressor: the sound times `gain`, then 3:1 above -20 dBFS with a soft knee, following the level in 5 ms and letting
/// go in 150 ms, the same on every channel. It measures what it puts out.
final class Compressor: CleanupStep {
    private let gain: Float
    private let attack: Double, release: Double
    private var envelope = 0.0
    private let meter: LoudnessMeter
    private static let threshold = -20.0, ratio = 3.0, knee = 6.0

    init(gain: Double, format: AVAudioFormat) {
        self.gain = Float(gain)
        attack = 1 - exp(-1 / (format.sampleRate * 0.005))
        release = 1 - exp(-1 / (format.sampleRate * 0.15))
        meter = LoudnessMeter(format: format)
    }

    var loudness: Double { meter.integrated }

    func process(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData else { return }
        let channels = Int(buffer.format.channelCount)
        for i in 0..<Int(buffer.frameLength) {
            var power = 0.0
            for c in 0..<channels {
                data[c][i] *= gain
                power = max(power, Double(data[c][i] * data[c][i]))
            }
            envelope += (power - envelope) * (power > envelope ? attack : release)
            let over = 10 * log10(envelope + 1e-20) - Self.threshold
            let slope = 1 / Self.ratio - 1
            let reduction = over <= -Self.knee / 2 ? 0
                : over < Self.knee / 2 ? slope * (over + Self.knee / 2) * (over + Self.knee / 2) / (2 * Self.knee)
                : slope * over
            let scale = Float(pow(10, reduction / 20))
            for c in 0..<channels { data[c][i] *= scale }
        }
        meter.add(buffer)
    }
}

/// The cleaned Microphone track kept inside the project folder beside the recorded one. It is a cache: its name is made from the
/// settings, the recorded file and `version`, so a file made for anything else is never used, and it can always be made again.
enum VoiceCleanupCache {
    /// Bump when a step starts sounding different, so files cleaned by an older build are made again.
    static let version = 2
    static let prefix = "voice-cleanup-"

    /// Where the cleaned copy of `microphone` for `settings` lives, whether or not it has been made.
    static func file(for microphone: URL, settings: VoiceCleanup) -> URL {
        var steps = settings
        steps.isOn = true
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let attributes = try? FileManager.default.attributesOfItem(atPath: microphone.path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let key = "\(version)|\(microphone.lastPathComponent)|\(size)|\(modified)|" + String(decoding: (try? encoder.encode(steps)) ?? Data(), as: UTF8.self)
        let digest = SHA256.hash(data: Data(key.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        return microphone.deletingLastPathComponent().appendingPathComponent(prefix + digest).appendingPathExtension(microphone.pathExtension)
    }

    /// The cleaned copy of `microphone` for `settings`, made first unless it is already there. Copies cleaned for other settings are
    /// removed once the new one is in place, so the project keeps one.
    static func prepare(_ microphone: URL, settings: VoiceCleanup) throws -> URL {
        let fm = FileManager.default
        let target = file(for: microphone, settings: settings)
        guard !fm.fileExists(atPath: target.path) else { return target }
        let folder = microphone.deletingLastPathComponent()
        // Made under a hidden name and moved in whole, so a half-written file never carries a settings name.
        let partial = folder.appendingPathComponent(".\(prefix)\(UUID().uuidString)").appendingPathExtension(microphone.pathExtension)
        do {
            try VoiceCleanupRenderer.render(microphone, settings: settings, to: partial)
            if fm.fileExists(atPath: target.path) { try fm.removeItem(at: partial) } else { try fm.moveItem(at: partial, to: target) }
        } catch {
            try? fm.removeItem(at: partial)
            throw error
        }
        for name in (try? fm.contentsOfDirectory(atPath: folder.path)) ?? [] where name.hasPrefix(prefix) && name != target.lastPathComponent {
            try? fm.removeItem(at: folder.appendingPathComponent(name))
        }
        return target
    }
}
