import AVFoundation
import CornermarkCore
import CryptoKit
import os

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
        let wanted = settings.noiseRemovalOn && settings.noiseRemovalStrength > 0
        let steps = try write(input, settings: settings, to: output, soundIsolation: soundIsolation)
        let noiseRemoval = steps.lazy.compactMap { $0 as? NoiseRemoval }.first
        guard wanted, noiseRemoval?.failed != false else { return VoiceCleanupReport() }
        if noiseRemoval != nil {
            // The unit failed part way: the file is cleaned again from the start without it, so no stretch carries half a step.
            var without = settings
            without.noiseRemovalOn = false
            try write(input, settings: without, to: output, soundIsolation: soundIsolation)
        }
        NoiseRemoval.failed(soundIsolation)
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
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk), let data = buffer.floatChannelData else {
            throw ExportError.writer("the sound could not be read")
        }
        // A step that answers late shifts the sound: its first answers are dropped and silence is fed after the end to draw out the
        // last ones, so every moment stays where it was recorded and the length stays the same.
        let latency = Int(steps.reduce(0) { $0 + $1.latency })
        var drop = latency, tail = latency
        let channels = Int(format.channelCount)
        while true {
            if source.framePosition < source.length {
                try source.read(into: buffer, frameCount: min(chunk, AVAudioFrameCount(source.length - source.framePosition)))
                guard buffer.frameLength > 0 else { break }
            } else if tail > 0 {
                buffer.frameLength = AVAudioFrameCount(min(Int(chunk), tail))
                tail -= Int(buffer.frameLength)
                for c in 0..<channels { data[c].update(repeating: 0, count: Int(buffer.frameLength)) }
            } else {
                break
            }
            for step in steps { step.process(buffer) }
            let length = Int(buffer.frameLength), early = min(drop, length)
            if early > 0 {
                drop -= early
                for c in 0..<channels { data[c].update(from: data[c] + early, count: length - early) }
                buffer.frameLength = AVAudioFrameCount(length - early)
            }
            if buffer.frameLength > 0 { try target.write(from: buffer) }
        }
        return steps
    }

    /// The steps that are on, always in this order: Low cut, Noise removal, Noise gate, Leveling. Track level comes later, in the mix.
    /// Noise removal at strength 0 is left out, so the sound is exactly as it came in; when its unit cannot be made, it is left out too.
    static func chain(_ settings: VoiceCleanup, format: AVAudioFormat, soundIsolation: AudioComponentDescription = NoiseRemoval.apple) -> [CleanupStep] {
        var steps: [CleanupStep] = []
        if settings.lowCutOn { steps.append(LowCut(frequency: settings.lowCutFrequency, format: format)) }
        if settings.noiseRemovalOn, settings.noiseRemovalStrength > 0,
           let step = NoiseRemoval(strength: settings.noiseRemovalStrength, format: format, unit: soundIsolation) { steps.append(step) }
        if settings.noiseGateOn { steps.append(PassThrough()) }
        if settings.levelingOn { steps.append(PassThrough()) }
        return steps
    }

    /// Whether Noise removal can run on this Mac: its unit is there and no render has seen it fail. The audio panel greys the step
    /// out when it cannot.
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
    /// Changes `buffer`'s deinterleaved float samples in place, keeping its length.
    func process(_ buffer: AVAudioPCMBuffer)
    /// How many frames late the step's sound comes out. The renderer lines the sound back up.
    var latency: AVAudioFrameCount { get }
}

extension CleanupStep {
    var latency: AVAudioFrameCount { 0 }
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
/// its answer with the sound as it came in. The unit answers `latency` frames late, which the renderer takes back out.
final class NoiseRemoval: CleanupStep {
    /// Apple's sound isolation unit, on every Mac since macOS 13.
    static let apple = AudioComponentDescription(componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_AUSoundIsolation,
                                                 componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
    /// Frames handed to the unit at a time.
    private static let slice: AVAudioFrameCount = 4_096
    private static let failure = OSAllocatedUnfairLock(initialState: false)

    static var available: Bool {
        var description = apple
        return AudioComponentFindNext(nil, &description) != nil && !failure.withLock { $0 }
    }

    /// Remembers for this run of the app that Apple's unit could not clean a file here.
    static func failed(_ unit: AudioComponentDescription) {
        guard unit.componentType == apple.componentType, unit.componentSubType == apple.componentSubType,
              unit.componentManufacturer == apple.componentManufacturer else { return }
        failure.withLock { $0 = true }
    }

    /// The sound waiting to go into the unit, read by its input block. A class of its own, so the engine does not hold the step.
    private final class Feed {
        var samples: [[Float]]
        var buffer: AVAudioPCMBuffer
        var short = false
        init(format: AVAudioFormat) {
            samples = Array(repeating: [], count: Int(format.channelCount))
            buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: NoiseRemoval.slice)!
        }
    }

    let latency: AVAudioFrameCount
    /// The unit stopped answering part way. What it wrote is not to be trusted.
    private(set) var failed = false
    private let engine = AVAudioEngine()
    private let strength: Float
    private let feed: Feed
    private let output: AVAudioPCMBuffer
    /// The sound as it came in, `latency` frames late, so it lines up with the unit's answer for the mix.
    private var dry: [[Float]]

    /// Nil when the unit cannot be made or started for `format`.
    init?(strength: Double, format: AVAudioFormat, unit description: AudioComponentDescription) {
        var find = description
        guard AudioComponentFindNext(nil, &find) != nil, let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: Self.slice) else { return nil }
        let unit = AVAudioUnitEffect(audioComponentDescription: description)
        // The high-quality voice model where the OS has it, the standard one before.
        let voice: Int
        if #available(macOS 15, *) { voice = kAUSoundIsolationSoundType_HighQualityVoice } else { voice = kAUSoundIsolationSoundType_Voice }
        AudioUnitSetParameter(unit.audioUnit, kAUSoundIsolationParam_SoundToIsolate, kAudioUnitScope_Global, 0, AudioUnitParameterValue(voice), 0)
        // The unit gives only its answer; strength is mixed here, against the dry sound lined up to it.
        AudioUnitSetParameter(unit.audioUnit, kAUSoundIsolationParam_WetDryMixPercent, kAudioUnitScope_Global, 0, 100, 0)
        let feed = Feed(format: format)
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
        latency = AVAudioFrameCount((unit.auAudioUnit.latency * format.sampleRate).rounded())
        dry = Array(repeating: Array(repeating: 0, count: Int(latency)), count: Int(format.channelCount))
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
