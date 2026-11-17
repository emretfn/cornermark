import AVFoundation
import CornermarkCore

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
