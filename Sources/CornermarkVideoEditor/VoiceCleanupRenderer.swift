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
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { throw ExportError.writer("the sound could not be read") }
        while source.framePosition < source.length {
            // A render run in a task stops at the next chunk once a newer one supersedes it.
            try Task.checkCancellation()
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
        if settings.levelingOn { steps.append(PassThrough()) }
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

/// The cleaned Microphone track kept inside the project folder beside the recorded one. It is a cache: its name is made from the
/// settings, the recorded file and `version`, so a file made for anything else is never used, and it can always be made again.
enum VoiceCleanupCache {
    /// Bump when a step starts sounding different, so files cleaned by an older build are made again.
    static let version = 1
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

    /// The cleaned copy of `microphone` for `settings`, made first unless it is already there. Copies cleaned for other settings stay:
    /// `VoiceCleanupRenders` removes the ones nobody holds.
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
        return target
    }

    /// Removes the cleaned copies of `microphone` but the ones in `keeping`.
    static func prune(beside microphone: URL, keeping: Set<URL>) {
        let fm = FileManager.default, folder = microphone.deletingLastPathComponent()
        let kept = Set(keeping.map(\.lastPathComponent))
        for name in (try? fm.contentsOfDirectory(atPath: folder.path)) ?? [] where name.hasPrefix(prefix) && !kept.contains(name) {
            try? fm.removeItem(at: folder.appendingPathComponent(name))
        }
    }
}
