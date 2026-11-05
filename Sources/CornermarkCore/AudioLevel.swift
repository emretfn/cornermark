import Foundation

/// How loud a stretch of sound is, as linear amplitudes where 1 is full scale.
public struct AudioLevel: Equatable, Sendable {
    public var rms: Float
    public var peak: Float

    public init(rms: Float, peak: Float) { self.rms = rms; self.peak = peak }

    public static let silence = AudioLevel(rms: 0, peak: 0)

    /// The level of every sample in every channel together.
    public static func measure(_ channels: [[Float]]) -> AudioLevel {
        var sum: Double = 0, peak: Float = 0, count = 0
        for channel in channels {
            for s in channel {
                sum += Double(s * s)
                peak = max(peak, abs(s))
            }
            count += channel.count
        }
        return AudioLevel(rms: count == 0 ? 0 : Float((sum / Double(count)).squareRoot()), peak: peak)
    }

    /// Decibels relative to full scale, never below `floor`.
    public static func decibels(_ amplitude: Float, floor: Float = -96) -> Float {
        amplitude <= 0 ? floor : max(floor, 20 * log10(amplitude))
    }

    /// Where a meter shows this level, 0 to 1, over the range `floor` dBFS to full scale. Decibels, because a voice spans most of the
    /// range in them, while on a linear scale it would sit near the bottom.
    public func meterFraction(floor: Float = -60) -> Float {
        let db = Self.decibels(rms, floor: floor)
        return min(max((db - floor) / -floor, 0), 1)
    }
}

/// Decides when a recording microphone gives no sound, such as when it is muted, its input volume is at zero, or it stopped sending.
/// Any working microphone hears a little noise even in a quiet room: built-in and USB microphones measure about -60 to -75 dBFS of
/// room noise. Muting gives digital silence instead. So the microphone counts as silent only when every sample of `delay` seconds
/// stays under `threshold`, -80 dBFS, or when nothing arrives for that long. A very quiet interface with its gain at the bottom can still
/// fall under it, and then a notice shows while it works; the notice changes nothing, so that mistake costs little.
public struct MicrophoneSilence: Equatable, Sendable {
    public static let threshold: Float = 0.0001
    public static let delay: Double = 3

    /// The last moment that had sound, or the start of listening.
    public private(set) var lastSound: Double

    public init(start: Double) { lastSound = start }

    /// One stretch of sound that ended at `end` seconds.
    public mutating func hear(_ level: AudioLevel, until end: Double) {
        if level.peak >= Self.threshold { lastSound = max(lastSound, end) }
    }

    /// Starts the wait over, such as after a pause, when nothing was listened to.
    public mutating func restart(at time: Double) { lastSound = max(lastSound, time) }

    public func isSilent(at now: Double) -> Bool { now - lastSound >= Self.delay }
}
