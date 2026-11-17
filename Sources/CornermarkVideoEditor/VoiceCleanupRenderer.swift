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
    /// A step that cannot run on this Mac is skipped and named in the report; the others still clean the sound.
    @discardableResult
    public static func render(_ input: URL, settings: VoiceCleanup, to output: URL) throws -> VoiceCleanupReport {
        try render(input, settings: settings, to: output, soundIsolation: NoiseRemoval.apple)
    }

    /// `render`, with Noise removal done by the audio unit `soundIsolation` describes, so a test can name one that is not there.
    static func render(_ input: URL, settings: VoiceCleanup, to output: URL, soundIsolation: AudioComponentDescription) throws -> VoiceCleanupReport {
        let steps = try write(input, settings: settings, to: output, soundIsolation: soundIsolation)
        let noiseRemoval = steps.lazy.compactMap { $0 as? NoiseRemoval }.first
        guard settings.runsNoiseRemoval, noiseRemoval?.failed != false else { return VoiceCleanupReport() }
        if noiseRemoval != nil {
            // The unit failed part way: the file is cleaned again from the start without it, so no stretch carries half a step.
            var without = settings
            without.noiseRemovalOn = false
            try write(input, settings: without, to: output, soundIsolation: soundIsolation)
        }
        return VoiceCleanupReport(noiseRemovalUnavailable: true)
    }

    /// Cleans `input` into `output` and hands back the steps that ran, so the caller can ask how they went.
    @discardableResult
    private static func write(_ input: URL, settings: VoiceCleanup, to output: URL, soundIsolation: AudioComponentDescription) throws -> [CleanupStep] {
        let source = try AVAudioFile(forReading: input, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = source.processingFormat
        try? FileManager.default.removeItem(at: output)
        let target = try AVAudioFile(forWriting: output, settings: outputSettings(like: source.fileFormat), commonFormat: .pcmFormatFloat32, interleaved: false)
        let steps = chain(settings, format: format, soundIsolation: soundIsolation)
        guard let leveling = steps.last as? Leveling else {
            try run(source, through: steps, into: target)
            return steps
        }
        // Leveling needs the loudness of the whole track before it can set any of it, so the sound goes through two temporary files:
        // the steps (Leveling measuring), then Leveling's compressor (measuring again), then its normalization into `target`.
        let measured = temporaryFile(), compressed = temporaryFile()
        defer { try? FileManager.default.removeItem(at: measured); try? FileManager.default.removeItem(at: compressed) }
        try run(source, through: steps, into: measured, format: format)
        try run(AVAudioFile(forReading: measured, commonFormat: .pcmFormatFloat32, interleaved: false), through: [leveling.compressor()], into: compressed, format: format)
        try leveling.normalize(AVAudioFile(forReading: compressed, commonFormat: .pcmFormatFloat32, interleaved: false), into: target)
        return steps
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
        // Steps that look ahead give their sound back late. The first frames out are dropped and as many silent frames are fed in
        // after the end, so the cleaned track keeps the recorded one's length and stays in sync with the video.
        let delay = steps.reduce(0) { $0 + $1.delay }
        var skip = delay, tail = delay
        func clean() throws {
            for step in steps { step.process(buffer) }
            let dropped = min(skip, Int(buffer.frameLength))
            skip -= dropped
            if dropped > 0, let data = buffer.floatChannelData {
                let kept = Int(buffer.frameLength) - dropped
                for c in 0..<Int(source.processingFormat.channelCount) { data[c].update(from: data[c] + dropped, count: kept) }
                buffer.frameLength = AVAudioFrameCount(kept)
            }
            if buffer.frameLength > 0 { try target.write(from: buffer) }
        }
        while source.framePosition < source.length {
            try source.read(into: buffer, frameCount: min(chunk, AVAudioFrameCount(source.length - source.framePosition)))
            guard buffer.frameLength > 0 else { break }
            try clean()
        }
        while tail > 0, let data = buffer.floatChannelData {
            let count = min(Int(chunk), tail)
            tail -= count
            for c in 0..<Int(source.processingFormat.channelCount) { data[c].update(repeating: 0, count: count) }
            buffer.frameLength = AVAudioFrameCount(count)
            try clean()
        }
    }

    /// The steps that are on, always in this order: Low cut, Noise removal, Noise gate, Leveling. Track level comes later, in the mix.
    /// Noise removal at strength 0 is left out, so the sound is exactly as it came in; when its unit cannot be made, it is left out too.
    static func chain(_ settings: VoiceCleanup, format: AVAudioFormat, soundIsolation: AudioComponentDescription = NoiseRemoval.apple) -> [CleanupStep] {
        var steps: [CleanupStep] = []
        if settings.lowCutOn { steps.append(LowCut(frequency: settings.lowCutFrequency, format: format)) }
        if settings.runsNoiseRemoval, let step = NoiseRemoval(strength: settings.noiseRemovalStrength, format: format, unit: soundIsolation) { steps.append(step) }
        if settings.noiseGateOn { steps.append(NoiseGate(threshold: settings.noiseGateThreshold, format: format)) }
        if settings.levelingOn { steps.append(Leveling(format: format)) }
        return steps
    }

    /// Whether Noise removal can run on this Mac: Apple's sound isolation unit is there. The audio panel greys the step out when it
    /// is not, or when a render reported it could not run.
    public static var noiseRemovalAvailable: Bool { NoiseRemoval.available }

    /// The recorded file's encoding, rate and channels. AAC keeps a cleaned track about as small as the recorded one.
    private static func outputSettings(like format: AVAudioFormat) -> [String: Any] {
        var settings = format.settings
        if (settings[AVFormatIDKey] as? NSNumber)?.uint32Value == kAudioFormatMPEG4AAC {
            settings[AVEncoderBitRateKey] = 128_000 * Int(format.channelCount)
        }
        return settings
    }
}

/// What a render had to leave out.
public struct VoiceCleanupReport: Equatable, Sendable {
    /// Noise removal was asked for, but Apple's sound isolation unit could not be made or failed, so the sound skipped that step.
    public var noiseRemovalUnavailable = false
}

/// One Voice cleanup step: a transform of the sound, fed the file chunk after chunk from start to end. A step keeps whatever it needs
/// between chunks, so one instance cleans one file.
protocol CleanupStep: AnyObject {
    /// How many frames late the step gives its sound back, so it can look that far ahead. The renderer takes it out again.
    var delay: Int { get }
    /// Changes `buffer`'s deinterleaved float samples in place, keeping its length.
    func process(_ buffer: AVAudioPCMBuffer)
}

extension CleanupStep {
    var delay: Int { 0 }
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

/// Noise removal: Apple's sound isolation audio unit, run offline, keeps the voice and drops steady background noise. Strength mixes
/// its answer with the sound as it came in. The unit answers `delay` frames late, which the renderer takes back out.
final class NoiseRemoval: CleanupStep {
    /// Apple's sound isolation unit, on every Mac since macOS 13.
    static let apple = AudioComponentDescription(componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_AUSoundIsolation,
                                                 componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
    /// Frames handed to the unit at a time.
    private static let slice: AVAudioFrameCount = 4_096

    /// Whether Apple's unit is on this Mac. A file it could not clean says so in its own report and leaves the next file to try.
    static var available: Bool {
        var description = apple
        return AudioComponentFindNext(nil, &description) != nil
    }

    /// The sound waiting to go into the unit, read by its input block. A class of its own, so the engine does not hold the step.
    private final class Feed {
        var samples: [[Float]]
        let buffer: AVAudioPCMBuffer
        var short = false
        init?(format: AVAudioFormat) {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: NoiseRemoval.slice) else { return nil }
            samples = Array(repeating: [], count: Int(format.channelCount))
            self.buffer = buffer
        }
    }

    let delay: Int
    /// The unit stopped answering part way. What it wrote is not to be trusted.
    private(set) var failed = false
    private let engine = AVAudioEngine()
    private let strength: Float
    private let feed: Feed
    private let output: AVAudioPCMBuffer
    /// The sound as it came in, `delay` frames late, so it lines up with the unit's answer for the mix.
    private var dry: [[Float]]

    /// Nil when the unit cannot be made or started for `format`.
    init?(strength: Double, format: AVAudioFormat, unit description: AudioComponentDescription) {
        var find = description
        guard AudioComponentFindNext(nil, &find) != nil, let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: Self.slice),
              let feed = Feed(format: format) else { return nil }
        let unit = AVAudioUnitEffect(audioComponentDescription: description)
        // The high-quality voice model where the OS has it, the standard one before.
        let voice: Int
        if #available(macOS 15, *) { voice = kAUSoundIsolationSoundType_HighQualityVoice } else { voice = kAUSoundIsolationSoundType_Voice }
        AudioUnitSetParameter(unit.audioUnit, kAUSoundIsolationParam_SoundToIsolate, kAudioUnitScope_Global, 0, AudioUnitParameterValue(voice), 0)
        // The unit gives only its answer; strength is mixed here, against the dry sound lined up to it.
        AudioUnitSetParameter(unit.audioUnit, kAUSoundIsolationParam_WetDryMixPercent, kAudioUnitScope_Global, 0, 100, 0)
        do {
            try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: Self.slice)
            engine.attach(unit)
            engine.connect(engine.inputNode, to: unit, format: format)
            engine.connect(unit, to: engine.mainMixerNode, format: format)
            let fed = engine.inputNode.setManualRenderingInputPCMFormat(format) { count in
                let n = Int(count), buffer = feed.buffer
                guard count <= buffer.frameCapacity, let data = buffer.floatChannelData else { return nil }
                for c in feed.samples.indices {
                    let have = min(n, feed.samples[c].count)
                    if have < n { feed.short = true }
                    feed.samples[c].withUnsafeBufferPointer { data[c].update(from: $0.baseAddress!, count: have) }
                    (data[c] + have).update(repeating: 0, count: n - have)
                    feed.samples[c].removeFirst(have)
                }
                buffer.frameLength = count
                return UnsafePointer(buffer.audioBufferList)
            }
            guard fed else { return nil }
            try engine.start()
        } catch {
            return nil
        }
        self.feed = feed
        self.output = output
        self.strength = Float(min(max(strength, 0), 1))
        delay = Int((unit.auAudioUnit.latency * format.sampleRate).rounded())
        dry = Array(repeating: Array(repeating: 0, count: delay), count: Int(format.channelCount))
    }

    deinit { engine.stop() }

    func process(_ buffer: AVAudioPCMBuffer) {
        guard !failed, let data = buffer.floatChannelData else { return }
        let n = Int(buffer.frameLength), channels = min(Int(buffer.format.channelCount), dry.count)
        for c in 0..<channels {
            let samples = UnsafeBufferPointer(start: data[c], count: n)
            feed.samples[c] += samples
            dry[c] += samples
        }
        var done = 0
        while done < n {
            let count = min(Int(Self.slice), n - done)
            guard (try? engine.renderOffline(AVAudioFrameCount(count), to: output)) == .success, Int(output.frameLength) == count, !feed.short,
                  let wet = output.floatChannelData else {
                failed = true
                return
            }
            for c in 0..<channels {
                for i in 0..<count { data[c][done + i] = strength * wet[c][i] + (1 - strength) * dry[c][done + i] }
            }
            done += count
        }
        for c in 0..<channels { dry[c].removeFirst(n) }
    }
}

/// Noise gate: silences the sound while its level stays below `threshold` dBFS. The level is the RMS over 10 ms, so noise whose
/// single peaks reach above the threshold but whose level stays under it is silenced. The Noise gate gives the sound back 10 ms
/// late, so it judges each moment on the 10 ms that follow it: it has opened, fading in over a millisecond, by the time a word's
/// first sound comes out, even a word only a little over the threshold. It stays open for a hold time after the level last
/// reached the threshold so the quiet ends of words and the dips of low tones do not chop, then fades out. All channels open and
/// close together, on the loudest of them.
final class NoiseGate: CleanupStep {
    /// The threshold as a mean square, compared with the mean square of the window.
    private let threshold: Double
    /// Gain change per sample while opening and closing.
    private let attack: Float, release: Float
    private let hold: Int
    /// The 10 ms of squared samples (the loudest channel's at each frame) the Noise gate is judging, and their sum, kept across chunks.
    private var window: [Double]
    private var next = 0
    private var sum = 0.0
    /// Each channel's last 10 ms of sound, not given back yet, kept across chunks.
    private var waiting: [[Float]]
    /// Samples since the level last reached the threshold, and the gain now, kept across chunks.
    private var quiet: Int
    private var gain: Float = 0

    var delay: Int { window.count }

    init(threshold: Double, format: AVAudioFormat) {
        let rate = format.sampleRate
        self.threshold = pow(10, threshold / 10)
        attack = Float(1 / (0.001 * rate))
        release = Float(1 / (0.1 * rate))
        hold = Int(0.05 * rate)
        quiet = hold
        window = Array(repeating: 0, count: max(Int(0.01 * rate), 1))
        waiting = Array(repeating: Array(repeating: 0, count: window.count), count: Int(format.channelCount))
    }

    func process(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData else { return }
        let channels = min(Int(buffer.format.channelCount), waiting.count)
        for i in 0..<Int(buffer.frameLength) {
            var square = 0.0
            for c in 0..<channels { square = max(square, Double(data[c][i]) * Double(data[c][i])) }
            sum += square - window[next]
            window[next] = square
            // The sample that leaves the window now is the one given back, so the window holds the 10 ms that follow it.
            for c in 0..<channels {
                let sample = data[c][i]
                data[c][i] = waiting[c][next]
                waiting[c][next] = sample
            }
            next = (next + 1) % window.count
            // Recomputed once per window so rounding in the running sum never builds up.
            if next == 0 { sum = window.reduce(0, +) }
            quiet = sum / Double(window.count) >= threshold ? 0 : min(quiet + 1, hold)
            gain = quiet < hold ? min(gain + attack, 1) : max(gain - release, 0)
            for c in 0..<channels { data[c][i] *= gain }
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
    static let version = 5
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

    /// The cleaned copy of `microphone` for `settings`, made first unless it is already there, and what its render had to leave out.
    /// Copies cleaned for other settings are removed once the new one is in place, so the project keeps one.
    static func prepare(_ microphone: URL, settings: VoiceCleanup,
                        soundIsolation: AudioComponentDescription = NoiseRemoval.apple) throws -> (url: URL, report: VoiceCleanupReport) {
        let fm = FileManager.default
        let target = file(for: microphone, settings: settings)
        guard !fm.fileExists(atPath: target.path) else { return (target, VoiceCleanupReport()) }
        let folder = microphone.deletingLastPathComponent()
        // Made under a hidden name and moved in whole, so a half-written file never carries a settings name.
        let partial = folder.appendingPathComponent(".\(prefix)\(UUID().uuidString)").appendingPathExtension(microphone.pathExtension)
        let report: VoiceCleanupReport
        var made = target
        do {
            report = try VoiceCleanupRenderer.render(microphone, settings: settings, to: partial, soundIsolation: soundIsolation)
            // Sound that skipped Noise removal is what the settings without it make, so it takes their name: these settings are
            // cleaned again, with Noise removal, once the unit runs.
            if report.noiseRemovalUnavailable {
                var without = settings
                without.noiseRemovalOn = false
                made = file(for: microphone, settings: without)
            }
            if fm.fileExists(atPath: made.path) { try fm.removeItem(at: partial) } else { try fm.moveItem(at: partial, to: made) }
        } catch {
            try? fm.removeItem(at: partial)
            throw error
        }
        for name in (try? fm.contentsOfDirectory(atPath: folder.path)) ?? [] where name.hasPrefix(prefix) && name != made.lastPathComponent {
            try? fm.removeItem(at: folder.appendingPathComponent(name))
        }
        return (made, report)
    }
}
