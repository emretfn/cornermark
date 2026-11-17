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

    /// `render`, with Noise removal done by the audio unit `soundIsolation` describes, so a test can name one that is not there, and
    /// with `noiseRemovalFailsAfter` set, failing once it has cleaned that many of its slices, as a unit that stops part way does.
    static func render(_ input: URL, settings: VoiceCleanup, to output: URL, soundIsolation: AudioComponentDescription,
                       noiseRemovalFailsAfter: Int? = nil) throws -> VoiceCleanupReport {
        let steps = try write(input, settings: settings, to: output, soundIsolation: soundIsolation, failsAfter: noiseRemovalFailsAfter)
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
    private static func write(_ input: URL, settings: VoiceCleanup, to output: URL, soundIsolation: AudioComponentDescription,
                              failsAfter: Int? = nil) throws -> [CleanupStep] {
        let source = try AVAudioFile(forReading: input, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = source.processingFormat
        try? FileManager.default.removeItem(at: output)
        let target = try AVAudioFile(forWriting: output, settings: outputSettings(like: source.fileFormat), commonFormat: .pcmFormatFloat32, interleaved: false)
        let steps = chain(settings, format: format, soundIsolation: soundIsolation, failsAfter: failsAfter)
        guard settings.levelingOn else {
            try run(source, through: steps, into: target)
            return steps
        }
        // Leveling needs the loudness of the whole track before it can set any of it. The steps before it write to a temporary file
        // and measure on the way; alone, Leveling measures the recorded file and reads it again.
        let meter = LoudnessMeter(format: format)
        guard !steps.isEmpty else {
            try measure(source, with: meter)
            source.framePosition = 0
            try Leveling(format: format).level(source, loudness: meter.integrated, into: target)
            return steps
        }
        let cleaned = temporaryFile()
        defer { try? FileManager.default.removeItem(at: cleaned) }
        try run(source, through: steps, into: cleaned, format: format, measuring: meter)
        try Leveling(format: format).level(AVAudioFile(forReading: cleaned, commonFormat: .pcmFormatFloat32, interleaved: false),
                                           loudness: meter.integrated, into: target)
        return steps
    }

    /// Runs `source` through `steps` into a new uncompressed float file at `url`, so a pass in between loses nothing, and into `meter`
    /// as it is written. The file is closed when this returns.
    static func run(_ source: AVAudioFile, through steps: [CleanupStep], into url: URL, format: AVAudioFormat, measuring meter: LoudnessMeter? = nil) throws {
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try run(source, through: steps, into: file, measuring: meter)
    }

    static func temporaryFile() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("cornermark-voice-cleanup-\(UUID().uuidString).caf")
    }

    /// Reads all of `source` into `meter`, a chunk at a time.
    private static func measure(_ source: AVAudioFile, with meter: LoudnessMeter) throws {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: chunk) else { throw VoiceCleanupError.unreadable }
        while source.framePosition < source.length {
            try Task.checkCancellation()
            try source.read(into: buffer, frameCount: min(chunk, AVAudioFrameCount(source.length - source.framePosition)))
            guard buffer.frameLength > 0 else { break }
            meter.add(buffer)
        }
    }

    /// Reads all of `source`, a chunk at a time, through `steps` into `target`, and into `meter` as it is written.
    private static func run(_ source: AVAudioFile, through steps: [CleanupStep], into target: AVAudioFile, measuring meter: LoudnessMeter? = nil) throws {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: chunk) else { throw VoiceCleanupError.unreadable }
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
            if buffer.frameLength > 0 {
                meter?.add(buffer)
                try target.write(from: buffer)
            }
        }
        while source.framePosition < source.length {
            // A render run in a task stops at the next chunk once a newer one supersedes it.
            try Task.checkCancellation()
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

    /// The steps that are on and run chunk by chunk, always in this order: Low cut, Noise removal, Noise gate. Leveling, which needs
    /// the whole track first, comes after them in `write`; Track level comes later still, in the mix.
    /// Noise removal at strength 0 is left out, so the sound is exactly as it came in; when its unit cannot be made, it is left out too.
    static func chain(_ settings: VoiceCleanup, format: AVAudioFormat, soundIsolation: AudioComponentDescription = NoiseRemoval.apple,
                      failsAfter: Int? = nil) -> [CleanupStep] {
        var steps: [CleanupStep] = []
        if settings.lowCutOn { steps.append(LowCut(frequency: settings.lowCutFrequency, format: format)) }
        if settings.runsNoiseRemoval,
           let step = NoiseRemoval(strength: settings.noiseRemovalStrength, format: format, unit: soundIsolation, failsAfter: failsAfter) { steps.append(step) }
        if settings.noiseGateOn { steps.append(NoiseGate(threshold: settings.noiseGateThreshold, format: format)) }
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

/// Why a cleaned Microphone track could not be made.
public enum VoiceCleanupError: Error, Equatable {
    /// The recorded sound could not be read into memory to clean it.
    case unreadable
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

/// Low cut: a 24 dB per octave Butterworth filter (a high-pass) at `frequency`, two biquads in a row, so hum an octave below is about 24 dB down
/// and speech above it stays as it was.
final class LowCut: CleanupStep {
    private struct Biquad {
        var b0 = 0.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0

        /// One section of Low cut at `frequency` with quality `q` (a high-pass biquad), from Robert Bristow-Johnson's Audio EQ Cookbook.
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
    static var available: Bool { isHere(apple) }

    /// Whether the audio unit `description` names is on this Mac.
    static func isHere(_ description: AudioComponentDescription) -> Bool {
        var find = description
        return AudioComponentFindNext(nil, &find) != nil
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

    /// Slices the unit may still clean before it stops answering, for a test; nil for as many as the file has.
    private var slicesLeft: Int?

    /// Nil when the unit cannot be made or started for `format`.
    init?(strength: Double, format: AVAudioFormat, unit description: AudioComponentDescription, failsAfter: Int? = nil) {
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
        slicesLeft = failsAfter
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
            if let left = slicesLeft { slicesLeft = left - 1 }
            guard slicesLeft.map({ $0 >= 0 }) ?? true, (try? engine.renderOffline(AVAudioFrameCount(count), to: output)) == .success, Int(output.frameLength) == count, !feed.short,
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
/// never clips. It needs the loudness of the whole track before it sets any of it, so it is not a chunk step: `level` takes the
/// loudness the steps before it measured and runs its own passes over the whole track.
struct Leveling {
    /// The loudness the track ends at, the common target for streamed speech.
    static let target = -16.0
    /// The highest sample allowed, 1.5 dB under full scale, which leaves room for the peaks between samples and for the AAC encoder.
    static let ceiling = Float(pow(10, -1.5 / 20))

    let format: AVAudioFormat

    /// Levels `source`, measured at `loudness`, into `target`: the sound raised or lowered to the target first, so the compressor's
    /// threshold sits at the same place in every voice, its loud stretches pulled down, and the result brought to the target.
    func level(_ source: AVAudioFile, loudness: Double, into target: AVAudioFile) throws {
        let compressed = VoiceCleanupRenderer.temporaryFile()
        defer { try? FileManager.default.removeItem(at: compressed) }
        let meter = LoudnessMeter(format: format)
        // A nearly silent track is raised by `boost` at most, so its hiss does not end up as loud as speech.
        let goal = loudness.isFinite ? min(Self.target, loudness + Self.boost) : Self.target
        try VoiceCleanupRenderer.run(source, through: [Compressor(gain: Double(Self.factor(Self.decibels(from: loudness, to: goal))), format: format)], into: compressed,
                                     format: format, measuring: meter)
        let leveled = try AVAudioFile(forReading: compressed, commonFormat: .pcmFormatFloat32, interleaved: false)
        // The limiter takes loudness out of peaky speech, so the limited sound is measured and the gain corrected by what it missed.
        // Raising the gain makes the limiter work harder, so a correction that falls short is made again by how much the last one
        // moved the loudness, a few times at most. When raising it no longer helps, the closest gain measured stays.
        var gain = Self.decibels(from: meter.integrated, to: goal), slope = 1.0
        var last: (gain: Double, loudness: Double)?, closest: (gain: Double, miss: Double)?
        for _ in 0..<Self.corrections {
            let limited = LoudnessMeter(format: format)
            leveled.framePosition = 0
            try normalize(leveled, gain: Self.factor(gain)) { limited.add($0) }
            let loudness = limited.integrated, miss = goal - loudness
            guard loudness.isFinite else { break }
            if closest.map({ abs(miss) < abs($0.miss) }) ?? true { closest = (gain, miss) }
            guard abs(miss) > 0.3 else { break }
            if let last {
                let moved = (loudness - last.loudness) / (gain - last.gain)
                guard moved > 0.1 else { gain = closest?.gain ?? gain; break }
                slope = min(moved, 1)
            }
            last = (gain, loudness)
            gain += miss / slope
        }
        leveled.framePosition = 0
        try normalize(leveled, gain: Self.factor(gain)) { try target.write(from: $0) }
    }

    /// `source` times `gain`, handed to `write` a chunk at a time. A limiter that looks 5 ms ahead lowers the gain smoothly before any
    /// peak that would pass the ceiling, so no sample does. It finds the peaks between samples as well (BS.1770's true peak, 4 times
    /// oversampled), so the sound does not pass the ceiling once it is played back or encoded either.
    private func normalize(_ source: AVAudioFile, gain: Float, into write: (AVAudioPCMBuffer) throws -> Void) throws {
        let ceiling = Self.ceiling, length = Int(source.length)
        let channels = Int(format.channelCount), look = max(1, Int(format.sampleRate * 0.005))
        let release = 1 - exp(-1 / (format.sampleRate * 0.1))
        guard let input = AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: VoiceCleanupRenderer.chunk),
              let output = AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: VoiceCleanupRenderer.chunk),
              let out = output.floatChannelData else { throw VoiceCleanupError.unreadable }
        // Frames read but not yet written, by frame number modulo `span`: the look-ahead and the frames the true peak needs after one.
        let span = look + TruePeak.taps
        var delay = [[Float]](repeating: [Float](repeating: 0, count: span), count: channels)
        var peaks = [TruePeak](repeating: TruePeak(), count: channels)
        // The gain each frame needs to stay under the ceiling, increasing from front to back, so the front is the lowest needed over
        // the next `look` frames.
        var needed: [(frame: Int, gain: Double)] = [], front = 0
        // The last `look` lowest gains, averaged, so the gain glides down over `look` frames and reaches each peak's need in time.
        var recent = [Double](repeating: 1, count: look), sum = Double(look), level = 1.0
        // Frames read, frames whose need is known, frames written, and the true peak just before the last known frame.
        var read = 0, known = 0, written = 0, before: Float = 0
        output.frameLength = 0

        func emit() throws {
            while needed[front].frame < written { front += 1 }
            let slot = written % look
            sum += needed[front].gain - recent[slot]
            recent[slot] = needed[front].gain
            let glide = sum / Double(look)
            level = glide < level ? glide : level + (glide - level) * release
            let n = Int(output.frameLength)
            for c in 0..<channels { out[c][n] = max(-ceiling, min(ceiling, delay[c][written % span] * Float(level))) }
            output.frameLength += 1
            written += 1
            if output.frameLength == output.frameCapacity {
                try write(output)
                output.frameLength = 0
            }
            if front > 4_096 {
                needed.removeFirst(front)
                front = 0
            }
        }

        /// Takes in the next frame, `sample(c)` on channel `c`; past the end, silence that only lets the last frames' peaks be found.
        func take(_ sample: (Int) -> Float) throws {
            var peak: Float = 0
            for c in 0..<channels {
                let v = sample(c)
                if read < length { delay[c][read % span] = v }
                peak = max(peak, peaks[c].add(v))
            }
            read += 1
            // `peak` is the highest the sound reaches from frame `frame` to the next; the frame needs that and the stretch before it.
            let frame = read - 1 - TruePeak.lag
            guard frame >= 0, frame < length else { return }
            let highest = max(before, peak)
            before = peak
            let need = highest > ceiling ? Double(ceiling / highest) : 1
            while needed.count > front, needed[needed.count - 1].gain >= need { needed.removeLast() }
            needed.append((frame, need))
            known = frame + 1
            while known - written >= look { try emit() }
        }

        while source.framePosition < source.length {
            try Task.checkCancellation()
            try source.read(into: input, frameCount: min(VoiceCleanupRenderer.chunk, AVAudioFrameCount(source.length - source.framePosition)))
            guard input.frameLength > 0, let data = input.floatChannelData else { break }
            for i in 0..<Int(input.frameLength) { try take { data[$0][i] * gain } }
        }
        while known < read, known < length { try take { _ in 0 } }
        while written < known { try emit() }
        if output.frameLength > 0 { try write(output) }
    }

    /// The most Leveling raises a track's loudness, in dB: enough for speech peaking at -40 dBFS, not enough to make a nearly silent
    /// track's hiss as loud as speech.
    static let boost = 40.0
    /// How many times the limited sound is measured, at most, to correct the gain.
    private static let corrections = 3

    /// The gain in dB that brings sound measured at `loudness` to `goal`; none for silence.
    private static func decibels(from loudness: Double, to goal: Double) -> Double { loudness.isFinite ? goal - loudness : 0 }
    private static func factor(_ decibels: Double) -> Float { Float(pow(10, decibels / 20)) }
}

/// One channel's true peak as BS.1770 finds it: the sound oversampled 4 times by a windowed-sinc interpolator, so a peak that falls
/// between two samples is seen at most a fraction of a dB short.
struct TruePeak {
    /// The interpolator's length in samples, and how many samples late the stretch it judges ends.
    static let taps = 12
    static let lag = taps / 2
    /// For each of the 4 phases, the weights of the last `taps` samples, newest first, that make the sound `lag` samples back plus a
    /// quarter, a half or three quarters of a sample. Phase 0 is the sample itself.
    private static let weights: [[Float]] = (0..<4).map { phase in
        let raw = (0..<taps).map { k -> Double in
            let t = Double(k - lag) + Double(phase) / 4
            let sinc = t == 0 ? 1 : sin(.pi * t) / (.pi * t)
            return sinc * 0.5 * (1 + cos(.pi * t / (Double(lag) + 0.5)))
        }
        let total = raw.reduce(0, +)
        return raw.map { Float($0 / total) }
    }

    private var history = [Float](repeating: 0, count: taps)
    private var next = 0

    /// Takes the next sample in and gives back the highest the sound reaches from `lag` samples back to the sample after it.
    mutating func add(_ sample: Float) -> Float {
        history[next] = sample
        next = (next + 1) % Self.taps
        var peak: Float = 0
        for phase in Self.weights {
            var value: Float = 0
            for k in 0..<Self.taps { value += phase[k] * history[(next - 1 - k + 2 * Self.taps) % Self.taps] }
            peak = max(peak, abs(value))
        }
        return peak
    }
}

/// Leveling's compressor: the sound times `gain`, then 3:1 above -20 dBFS with a soft knee, following the level in 5 ms and letting
/// go in 150 ms, the same on every channel.
final class Compressor: CleanupStep {
    private let gain: Float
    private let attack: Double, release: Double
    private var envelope = 0.0
    private static let threshold = -20.0, ratio = 3.0, knee = 6.0

    init(gain: Double, format: AVAudioFormat) {
        self.gain = Float(gain)
        attack = 1 - exp(-1 / (format.sampleRate * 0.005))
        release = 1 - exp(-1 / (format.sampleRate * 0.15))
    }

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
    }
}

/// The cleaned Microphone track kept inside the project folder beside the recorded one. It is a cache: its name is made from the
/// settings, the recorded file and `version`, so a file made for anything else is never used, and it can always be made again.
enum VoiceCleanupCache {
    /// Bump when a step starts sounding different, so files cleaned by an older build are made again.
    static let version = 6
    static let prefix = "voice-cleanup-"

    /// The settings as far as the sound goes: the master switch and the values of steps that are off do not change it, and Noise
    /// removal at strength 0 is off.
    static func sound(of settings: VoiceCleanup) -> VoiceCleanup {
        let defaults = VoiceCleanup()
        var steps = settings
        steps.isOn = true
        if !steps.lowCutOn { steps.lowCutFrequency = defaults.lowCutFrequency }
        if !steps.runsNoiseRemoval {
            steps.noiseRemovalOn = false
            steps.noiseRemovalStrength = defaults.noiseRemovalStrength
        }
        if !steps.noiseGateOn { steps.noiseGateThreshold = defaults.noiseGateThreshold }
        return steps
    }

    /// Where the cleaned copy of `microphone` for `settings` lives, whether or not it has been made. Its name starts with the
    /// microphone's, so copies of two recorded files in one folder never mix.
    static func file(for microphone: URL, settings: VoiceCleanup) -> URL {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let attributes = try? FileManager.default.attributesOfItem(atPath: microphone.path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let key = "\(version)|\(microphone.lastPathComponent)|\(size)|\(modified)|"
            + String(decoding: (try? encoder.encode(sound(of: settings))) ?? Data(), as: UTF8.self)
        let digest = SHA256.hash(data: Data(key.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        return microphone.deletingLastPathComponent().appendingPathComponent(lead(of: microphone) + digest).appendingPathExtension(microphone.pathExtension)
    }

    /// The start of the name of every cleaned copy of `microphone`.
    private static func lead(of microphone: URL) -> String { prefix + microphone.deletingPathExtension().lastPathComponent + "-" }

    /// The settings without Noise removal, whose copy these settings play where Noise removal cannot run.
    private static func withoutNoiseRemoval(_ settings: VoiceCleanup) -> VoiceCleanup {
        var without = settings
        without.noiseRemovalOn = false
        return without
    }

    /// The cleaned copy of `microphone` that plays for `settings` now, nil until it is made. Where Noise removal cannot run, that
    /// is the copy made without it. Preview and export look it up here, so they never wait for a copy that is already there.
    static func ready(for microphone: URL, settings: VoiceCleanup, soundIsolation: AudioComponentDescription = NoiseRemoval.apple) -> URL? {
        let fm = FileManager.default, asked = file(for: microphone, settings: settings)
        if fm.fileExists(atPath: asked.path) { return asked }
        guard sound(of: settings).runsNoiseRemoval, !NoiseRemoval.isHere(soundIsolation) else { return nil }
        let without = file(for: microphone, settings: withoutNoiseRemoval(settings))
        return fm.fileExists(atPath: without.path) ? without : nil
    }

    /// The cleaned copy of `microphone` for `settings`, made first unless it is already there, and what its render had to leave out.
    /// Copies cleaned for other settings stay: `VoiceCleanupRenders` removes the ones nobody holds.
    static func prepare(_ microphone: URL, settings: VoiceCleanup,
                        soundIsolation: AudioComponentDescription = NoiseRemoval.apple) throws -> (url: URL, report: VoiceCleanupReport) {
        let fm = FileManager.default
        let target = file(for: microphone, settings: settings)
        if let ready = ready(for: microphone, settings: settings, soundIsolation: soundIsolation) {
            return (ready, VoiceCleanupReport(noiseRemovalUnavailable: ready != target))
        }
        let folder = microphone.deletingLastPathComponent()
        // Made under a hidden name and moved in whole, so a half-written file never carries a settings name.
        let partial = folder.appendingPathComponent("." + lead(of: microphone) + UUID().uuidString).appendingPathExtension(microphone.pathExtension)
        let report: VoiceCleanupReport
        var made = target
        do {
            report = try VoiceCleanupRenderer.render(microphone, settings: settings, to: partial, soundIsolation: soundIsolation)
            // Sound that skipped Noise removal is what the settings without it make, so it takes their name: these settings are
            // cleaned again, with Noise removal, once the unit runs.
            if report.noiseRemovalUnavailable { made = file(for: microphone, settings: withoutNoiseRemoval(settings)) }
            if fm.fileExists(atPath: made.path) { try fm.removeItem(at: partial) } else { try fm.moveItem(at: partial, to: made) }
        } catch {
            try? fm.removeItem(at: partial)
            throw error
        }
        return (made, report)
    }

    /// Removes the cleaned copies of `microphone` but the ones in `keeping`, and with `partials` also the half-written ones: only
    /// when no render of `microphone` is writing one.
    static func prune(beside microphone: URL, keeping: Set<URL>, partials: Bool = false) {
        let fm = FileManager.default, folder = microphone.deletingLastPathComponent()
        let kept = Set(keeping.map(\.lastPathComponent))
        for name in (try? fm.contentsOfDirectory(atPath: folder.path)) ?? [] where !kept.contains(name) {
            guard isCopy(name, of: microphone, partial: false) || partials && isCopy(name, of: microphone, partial: true) else { continue }
            try? fm.removeItem(at: folder.appendingPathComponent(name))
        }
    }

    /// Whether the file named `name` is a cleaned copy of `microphone`, or with `partial` one being written.
    private static func isCopy(_ name: String, of microphone: URL, partial: Bool) -> Bool {
        let lead = (partial ? "." : "") + lead(of: microphone), ext = "." + microphone.pathExtension
        guard name.hasPrefix(lead), name.hasSuffix(ext), name.count >= lead.count + ext.count else { return false }
        let stem = String(name.dropFirst(lead.count).dropLast(ext.count))
        return partial ? UUID(uuidString: stem) != nil : stem.count == 16 && stem.allSatisfy(\.isHexDigit)
    }
}
