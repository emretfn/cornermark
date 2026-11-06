import Foundation

/// One of a recording's sound tracks.
public enum AudioTrack: String, Codable, CaseIterable, Sendable {
    case microphone, systemAudio

    public var title: String { self == .microphone ? "Microphone" : "System audio" }
}

/// How loud one track plays in the finished video.
public struct AudioTrackLevel: Codable, Equatable, Sendable {
    public static let range = 0.0...1.0
    public var isOn: Bool
    /// A linear gain: 1 plays the track as recorded, 0.5 at half its amplitude.
    public var level: Double

    public init(isOn: Bool = true, level: Double = 1) { self.isOn = isOn; self.level = level }

    /// What the mix multiplies the track by.
    public var gain: Double { isOn ? min(max(level, Self.range.lowerBound), Self.range.upperBound) : 0 }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let d = AudioTrackLevel()
        isOn = (try? c.decodeIfPresent(Bool.self, forKey: .isOn)) ?? d.isOn
        level = (try? c.decodeIfPresent(Double.self, forKey: .level)) ?? d.level
    }
    private enum Keys: String, CodingKey { case isOn, level }
}

/// The level of each sound track. Preview and export mix by it.
public struct AudioEdits: Codable, Equatable, Sendable {
    public var microphone: AudioTrackLevel
    public var systemAudio: AudioTrackLevel

    public init(microphone: AudioTrackLevel = AudioTrackLevel(), systemAudio: AudioTrackLevel = AudioTrackLevel()) {
        self.microphone = microphone; self.systemAudio = systemAudio
    }

    public subscript(track: AudioTrack) -> AudioTrackLevel {
        get { track == .microphone ? microphone : systemAudio }
        set { if track == .microphone { microphone = newValue } else { systemAudio = newValue } }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        microphone = (try? c.decodeIfPresent(AudioTrackLevel.self, forKey: .microphone)) ?? AudioTrackLevel()
        systemAudio = (try? c.decodeIfPresent(AudioTrackLevel.self, forKey: .systemAudio)) ?? AudioTrackLevel()
    }
    private enum Keys: String, CodingKey { case microphone, systemAudio }
}

extension RecordingProject.Source {
    public func file(for track: AudioTrack) -> String? { track == .microphone ? microphone : systemAudio }

    /// The tracks this recording has, microphone first.
    public var audioTracks: [AudioTrack] { AudioTrack.allCases.filter { file(for: $0) != nil } }
}

extension RecordingProject {
    /// The tracks that reach the finished video, each with the gain it plays at. A muted track is left out.
    public var audioMix: [(track: AudioTrack, file: String, gain: Double)] {
        source.audioTracks.compactMap { track in
            let gain = edits.audio[track].gain
            guard gain > 0, let file = source.file(for: track) else { return nil }
            return (track, file, gain)
        }
    }
}
