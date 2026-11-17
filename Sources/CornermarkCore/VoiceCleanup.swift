import Foundation

/// The microphone's Voice cleanup: a master switch and the cleanup steps, which always run in this order: Low cut, Noise removal,
/// Noise gate, Leveling. Track level comes after them. The recorded microphone file is never changed; preview and export play a
/// cleaned copy made from it.
/// A value outside its range, read from a file or set in code, is kept at the nearest end.
public struct VoiceCleanup: Codable, Equatable, Sendable {
    public static let lowCutRange = 60.0...200.0
    public static let noiseRemovalRange = 0.0...1.0
    public static let noiseGateRange = -80.0...(-20.0)

    public var isOn: Bool
    /// Low cut removes sound below `lowCutFrequency`, in Hz.
    public var lowCutOn: Bool
    public var lowCutFrequency: Double { didSet { lowCutFrequency = Self.clamp(lowCutFrequency, Self.lowCutRange) } }
    /// How much of the steady background noise Noise removal takes out, 0 none to 1 all it can.
    public var noiseRemovalOn: Bool
    public var noiseRemovalStrength: Double { didSet { noiseRemovalStrength = Self.clamp(noiseRemovalStrength, Self.noiseRemovalRange) } }
    /// Noise gate silences the microphone while its level stays below `noiseGateThreshold`, in dBFS.
    public var noiseGateOn: Bool
    public var noiseGateThreshold: Double { didSet { noiseGateThreshold = Self.clamp(noiseGateThreshold, Self.noiseGateRange) } }
    public var levelingOn: Bool

    /// Noise removal changes the sound: it is on and its strength is above 0. At 0 the sound passes exactly as it came in.
    public var runsNoiseRemoval: Bool { noiseRemovalOn && noiseRemovalStrength > 0 }

    private static func clamp(_ value: Double, _ range: ClosedRange<Double>) -> Double {
        value.isNaN ? range.lowerBound : min(max(value, range.lowerBound), range.upperBound)
    }

    /// Off, with every step at its default, so turning it on starts from the defaults.
    public init(isOn: Bool = false, lowCutOn: Bool = true, lowCutFrequency: Double = 80, noiseRemovalOn: Bool = true, noiseRemovalStrength: Double = 1,
                noiseGateOn: Bool = true, noiseGateThreshold: Double = -50, levelingOn: Bool = true) {
        self.isOn = isOn
        self.lowCutOn = lowCutOn; self.lowCutFrequency = Self.clamp(lowCutFrequency, Self.lowCutRange)
        self.noiseRemovalOn = noiseRemovalOn; self.noiseRemovalStrength = Self.clamp(noiseRemovalStrength, Self.noiseRemovalRange)
        self.noiseGateOn = noiseGateOn; self.noiseGateThreshold = Self.clamp(noiseGateThreshold, Self.noiseGateRange)
        self.levelingOn = levelingOn
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let d = VoiceCleanup()
        self.init(isOn: (try? c.decodeIfPresent(Bool.self, forKey: .isOn)) ?? d.isOn,
                  lowCutOn: (try? c.decodeIfPresent(Bool.self, forKey: .lowCutOn)) ?? d.lowCutOn,
                  lowCutFrequency: (try? c.decodeIfPresent(Double.self, forKey: .lowCutFrequency)) ?? d.lowCutFrequency,
                  noiseRemovalOn: (try? c.decodeIfPresent(Bool.self, forKey: .noiseRemovalOn)) ?? d.noiseRemovalOn,
                  noiseRemovalStrength: (try? c.decodeIfPresent(Double.self, forKey: .noiseRemovalStrength)) ?? d.noiseRemovalStrength,
                  noiseGateOn: (try? c.decodeIfPresent(Bool.self, forKey: .noiseGateOn)) ?? d.noiseGateOn,
                  noiseGateThreshold: (try? c.decodeIfPresent(Double.self, forKey: .noiseGateThreshold)) ?? d.noiseGateThreshold,
                  levelingOn: (try? c.decodeIfPresent(Bool.self, forKey: .levelingOn)) ?? d.levelingOn)
    }
    private enum Keys: String, CodingKey {
        case isOn, lowCutOn, lowCutFrequency, noiseRemovalOn, noiseRemovalStrength, noiseGateOn, noiseGateThreshold, levelingOn
    }
}

extension RecordingProject {
    /// The project of a recording just made: every edit at its default, and Voice cleanup on when there is a Microphone track.
    public static func newRecording(source: Source, events: Events = Events()) -> RecordingProject {
        var project = RecordingProject(source: source, events: events)
        if source.microphone != nil { project.edits.audio.voiceCleanup.isOn = true }
        return project
    }
}
