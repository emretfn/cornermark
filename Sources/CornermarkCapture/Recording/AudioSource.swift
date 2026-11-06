import AVFoundation
import CornermarkCore

/// A run of sound. `time` is the first sample's moment on the clock the pictures use, so the recorder can place it beside the video.
/// Each channel holds the same number of samples, as floats where 1 is full scale.
public struct AudioChunk {
    public var time: Double
    public var rate: Double
    public var channels: [[Float]]
    public init(time: Double, rate: Double, channels: [[Float]]) { self.time = time; self.rate = rate; self.channels = channels }

    public var frames: Int { channels.first?.count ?? 0 }
    public var end: Double { time + Double(frames) / rate }
    public var level: AudioLevel { AudioLevel.measure(channels) }

    /// The samples of a sample buffer as floats, one array per channel, stamped on the recording clock. `clock` converts the buffer's own
    /// time to it. Nil for a buffer that holds no linear PCM.
    init?(_ sample: CMSampleBuffer, clock: (CMTime) -> Double) {
        guard let description = CMSampleBufferGetFormatDescription(sample) else { return nil }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        let count = AVAudioFrameCount(CMSampleBufferGetNumSamples(sample))
        guard count > 0, format.channelCount > 0, let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count),
              CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(count), into: pcm.mutableAudioBufferList) == noErr
        else { return nil }
        pcm.frameLength = count
        guard let floats = Self.floats(pcm) else { return nil }
        time = clock(CMSampleBufferGetPresentationTimeStamp(sample))
        rate = format.sampleRate
        channels = floats
    }

    private static func floats(_ pcm: AVAudioPCMBuffer) -> [[Float]]? {
        let n = Int(pcm.frameLength), channels = Int(pcm.format.channelCount)
        if pcm.format.commonFormat == .pcmFormatFloat32, !pcm.format.isInterleaved, let data = pcm.floatChannelData {
            return (0..<channels).map { Array(UnsafeBufferPointer(start: data[$0], count: n)) }
        }
        guard let plain = AVAudioFormat(standardFormatWithSampleRate: pcm.format.sampleRate, channels: pcm.format.channelCount),
              let converter = AVAudioConverter(from: pcm.format, to: plain),
              let out = AVAudioPCMBuffer(pcmFormat: plain, frameCapacity: pcm.frameLength) else { return nil }
        guard (try? converter.convert(to: out, from: pcm)) != nil, let data = out.floatChannelData else { return nil }
        return (0..<channels).map { Array(UnsafeBufferPointer(start: data[$0], count: Int(out.frameLength))) }
    }
}

/// Where recorded sound comes from: a microphone, what the Mac plays, or a script in tests and scripted instances.
public protocol AudioSource: AnyObject {
    /// Chunks arrive on a queue of the source's choosing until `stop`. Throws when the source cannot start, and then delivers nothing.
    func start(_ deliver: @escaping (AudioChunk) -> Void) throws
    func stop()
}

public enum AudioUnavailable: Error, Equatable, CustomStringConvertible {
    case notPermitted
    case noDevice
    case failed(String)

    public var description: String {
        switch self {
        case .notPermitted: return "notPermitted"
        case .noDevice: return "noDevice"
        case .failed(let m): return "failed(\(m))"
        }
    }
}

public struct MicrophoneDevice: Equatable, Sendable {
    public var id: String
    public var name: String
    public init(id: String, name: String) { self.id = id; self.name = name }
}

/// Whether Cornermark may use the microphone.
public enum MicrophoneAccess: String, Equatable, Sendable {
    case allowed, denied, notAsked

    /// Reads the answer without asking: this never shows the system prompt.
    public static var current: MicrophoneAccess {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .allowed
        case .notDetermined: return .notAsked
        default: return .denied
        }
    }

    public private(set) static var requests = 0

    /// Shows the system prompt. Only the live app calls it, when someone turns on the microphone.
    public static func request(_ done: @escaping (Bool) -> Void) {
        requests += 1
        AVCaptureDevice.requestAccess(for: .audio) { granted in DispatchQueue.main.async { done(granted) } }
    }
}

/// The real microphone. It never asks for access: without it, `start` throws `notPermitted` and opens nothing.
public final class LiveMicrophoneSource: NSObject, AudioSource, AVCaptureAudioDataOutputSampleBufferDelegate {
    public private(set) static var sessionsOpened = 0
    private let deviceID: String?
    private let queue = DispatchQueue(label: "cornermark.microphone", qos: .userInteractive)
    private var session: AVCaptureSession?
    private var deliver: ((AudioChunk) -> Void)?

    /// Nil, or an ID no device has, records from the system's default input.
    public init(deviceID: String?) { self.deviceID = deviceID }

    /// Listing devices needs no access and shows no prompt.
    public static func devices() -> [MicrophoneDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified)
            .devices.map { MicrophoneDevice(id: $0.uniqueID, name: $0.localizedName) }
    }

    public func start(_ deliver: @escaping (AudioChunk) -> Void) throws {
        guard MicrophoneAccess.current == .allowed else { throw AudioUnavailable.notPermitted }
        guard let device = deviceID.flatMap(AVCaptureDevice.init(uniqueID:)) ?? AVCaptureDevice.default(for: .audio) else { throw AudioUnavailable.noDevice }
        let session = AVCaptureSession()
        let output = AVCaptureAudioDataOutput()
        output.audioSettings = [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
                                AVLinearPCMIsNonInterleaved: true]
        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input), session.canAddOutput(output) else { throw AudioUnavailable.failed("the device cannot be used") }
            session.addInput(input)
            session.addOutput(output)
        } catch let error as AudioUnavailable {
            throw error
        } catch {
            throw AudioUnavailable.failed(error.localizedDescription)
        }
        output.setSampleBufferDelegate(self, queue: queue)
        self.deliver = deliver
        self.session = session
        Self.sessionsOpened += 1
        session.startRunning()
    }

    public func stop() {
        session?.stopRunning()
        session = nil
        queue.sync { deliver = nil }
    }

    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let deliver, let clock = session?.synchronizationClock else { return }
        if let chunk = Self.chunk(sampleBuffer, clock: clock) { deliver(chunk) }
    }

    /// One capture buffer as sound on the recording clock. `clock` is the session's synchronization clock, which the buffer is stamped on.
    static func chunk(_ sample: CMSampleBuffer, clock: CMClockOrTimebase) -> AudioChunk? {
        let host = CMClockGetHostTimeClock()
        return AudioChunk(sample, clock: { CMSyncConvertTime($0, from: clock, to: host).seconds })
    }
}

/// Sound made from a formula, for tests and scripted instances, so nothing ever listens to a real device or plays a sound.
public struct AudioPattern {
    public var channels: Int
    public var rate: Double
    /// The sample of `channel` at `t` seconds after the source started. `clock` is the same moment on the recording clock.
    public var sample: (_ t: Double, _ clock: Double, _ channel: Int) -> Float

    public init(channels: Int, rate: Double = 48_000, sample: @escaping (_ t: Double, _ clock: Double, _ channel: Int) -> Float) {
        self.channels = channels; self.rate = rate; self.sample = sample
    }

    /// A voice-like hum: a 180 Hz tone with two overtones, four syllables a second, about -18 dBFS. `silent` is the part of every
    /// `period` seconds with no sound at all, as a muted microphone gives. With a period it follows the recording clock, so every source
    /// made from the pattern, like every reader of one real microphone, goes quiet at the same moment. `leftOnly` puts the voice in the
    /// left channel of two, like a microphone plugged into the first input of an interface.
    public static func voice(silent: Range<Double>? = nil, period: Double = 0, leftOnly: Bool = false) -> AudioPattern {
        AudioPattern(channels: leftOnly ? 2 : 1) { t, clock, channel in
            if leftOnly, channel > 0 { return 0 }
            let local = period > 0 ? clock.truncatingRemainder(dividingBy: period) : t
            if let silent, silent.contains(local) { return 0 }
            let syllable = 0.55 + 0.45 * sin(2 * .pi * 4 * t)
            let tone = sin(2 * .pi * 180 * t) + 0.5 * sin(2 * .pi * 360 * t) + 0.25 * sin(2 * .pi * 540 * t)
            return Float(0.07 * syllable * tone)
        }
    }

    /// The scripted microphone: the voice, silent from 4 to 9 s of every 12 on the recording clock, so a recording shows the
    /// silent-microphone notice and its end.
    public static let microphoneTour = voice(silent: 4..<9, period: 12)

    /// A stereo chime, an octave apart in each ear, plus `clicks`.
    public static func chime(clicks: Clicks? = nil) -> AudioPattern {
        AudioPattern(channels: 2) { t, clock, channel in
            if let clicks, let v = clicks.value(at: clock) { return v }
            let note = t.truncatingRemainder(dividingBy: 0.5)
            let envelope = exp(-note * 6)
            let f = channel == 0 ? 523.25 : 1046.5
            return Float(0.12 * envelope * sin(2 * .pi * f * t))
        }
    }

    /// The scripted system sound: the chime with a click on every whole second of the recording clock.
    public static let systemClicks = Clicks(epoch: 0, period: 1)
    public static let systemTour = chime(clicks: systemClicks)

    /// A short full-scale burst at `epoch + n * period` seconds on the recording clock, for measuring sync against a flash in the picture.
    public struct Clicks: Equatable, Sendable {
        public var epoch: Double
        public var period: Double
        public static let length = 0.004
        public init(epoch: Double, period: Double) { self.epoch = epoch; self.period = period }

        /// True for the frame at `clock` when a click happened since the frame before it. A tiny allowance absorbs rounding, so a click on a
        /// frame's exact time flashes that frame.
        public func isFirstFrame(at clock: Double, fps: Int) -> Bool {
            let since = (clock - epoch).truncatingRemainder(dividingBy: period)
            let into = since < 0 ? since + period : since
            return into < 1 / Double(fps) - 1e-6 || period - into < 1e-6
        }

        /// The burst's sample at `clock`, or nil outside a burst.
        public func value(at clock: Double) -> Float? {
            let since = (clock - epoch).truncatingRemainder(dividingBy: period)
            let into = since < 0 ? since + period : since
            guard into < Self.length else { return nil }
            return Float(0.9 * sin(2 * .pi * 2000 * into + .pi / 2))
        }
    }

    /// Only the clicks, with silence between.
    public static func clicks(_ clicks: Clicks, channels: Int = 1) -> AudioPattern {
        AudioPattern(channels: channels) { _, clock, _ in clicks.value(at: clock) ?? 0 }
    }
}

public final class ScriptedAudioSource: AudioSource {
    public enum Pacing {
        /// Chunks arrive as their moment passes, the pattern's zero at the clock's reading at `start`.
        case realtime
        /// Every chunk of the first `seconds` arrives from `start` itself, the pattern's zero at `origin` on the recording clock.
        case fixed(origin: Double, seconds: Double)
    }

    public static let chunkFrames = 480
    public let pattern: AudioPattern
    private let pacing: Pacing
    private let queue = DispatchQueue(label: "cornermark.scripted-audio", qos: .userInteractive)
    private var timer: DispatchSourceTimer?

    public init(pattern: AudioPattern, pacing: Pacing = .realtime) { self.pattern = pattern; self.pacing = pacing }

    /// The microphones a scripted instance offers. None is a real device.
    public static let microphones = [MicrophoneDevice(id: "scripted.microphone", name: "Test Microphone"),
                                     MicrophoneDevice(id: "scripted.interface", name: "Test Interface, input 1 of 2")]

    /// The scripted microphone a device ID names: the tour in one channel, or on the interface the same voice in the left of two
    /// channels. Any other ID gets the first, as a real missing device falls back to the default input.
    public static func microphone(_ id: String?, pacing: Pacing = .realtime) -> ScriptedAudioSource {
        let pattern = id == microphones[1].id ? AudioPattern.voice(silent: 4..<9, period: 12, leftOnly: true) : .microphoneTour
        return ScriptedAudioSource(pattern: pattern, pacing: pacing)
    }

    /// The chunk of `frames` samples starting at sample `index` after `origin`.
    public func chunk(origin: Double, index: Int, frames: Int) -> AudioChunk {
        let rate = pattern.rate
        let channels = (0..<pattern.channels).map { c in
            (0..<frames).map { i -> Float in
                let t = Double(index + i) / rate
                return pattern.sample(t, origin + t, c)
            }
        }
        return AudioChunk(time: origin + Double(index) / rate, rate: rate, channels: channels)
    }

    public func start(_ deliver: @escaping (AudioChunk) -> Void) throws {
        switch pacing {
        case .fixed(let origin, let seconds):
            let total = Int(seconds * pattern.rate)
            for index in stride(from: 0, to: total, by: Self.chunkFrames) { deliver(chunk(origin: origin, index: index, frames: min(Self.chunkFrames, total - index))) }
        case .realtime:
            let origin = recordingClockNow()
            var made = 0
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .milliseconds(1))
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                let due = Int((recordingClockNow() - origin) * self.pattern.rate)
                while due - made >= Self.chunkFrames {
                    deliver(self.chunk(origin: origin, index: made, frames: Self.chunkFrames))
                    made += Self.chunkFrames
                }
            }
            self.timer = timer
            timer.resume()
        }
    }

    public func stop() {
        timer?.cancel()
        timer = nil
        queue.sync {}
    }
}
