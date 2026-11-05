import Foundation

/// Playback over the finished video's timeline. A pure state machine: every method takes the host clock's `now` in seconds,
/// so the same calls give the same answers in a test, a harness film and the running app.
public struct Transport: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case paused(at: Double)
        /// Playing since host time `since`, when the playhead was at `from`.
        case playing(from: Double, since: Double)
    }

    public private(set) var state: State
    public let duration: Double

    public init(duration: Double) {
        self.duration = max(duration, 0)
        state = .paused(at: 0)
    }

    public var isPlaying: Bool { if case .playing = state { return true } else { return false } }

    /// The playhead at `now`. Playing never runs past the end.
    public func time(at now: Double) -> Double {
        switch state {
        case .paused(let at): return at
        case .playing(let from, let since): return clamp(from + max(now - since, 0))
        }
    }

    /// Plays from the playhead, or from the start when the playhead is at the end.
    public mutating func play(now: Double) {
        guard !isPlaying, duration > 0 else { return }
        let at = time(at: now)
        state = .playing(from: at >= duration ? 0 : at, since: now)
    }

    public mutating func pause(now: Double) {
        state = .paused(at: time(at: now))
    }

    public mutating func toggle(now: Double) {
        if isPlaying { pause(now: now) } else { play(now: now) }
    }

    /// Moves the playhead and keeps playing if it was.
    public mutating func seek(to t: Double, now: Double) {
        state = isPlaying ? .playing(from: clamp(t), since: now) : .paused(at: clamp(t))
    }

    /// Stops at the end once playing reaches it. Returns whether that happened.
    @discardableResult
    public mutating func settle(now: Double) -> Bool {
        guard isPlaying, time(at: now) >= duration else { return false }
        state = .paused(at: duration)
        return true
    }

    private func clamp(_ t: Double) -> Double { min(max(t, 0), duration) }
}

/// `0:01.25`: minutes, seconds and hundredths, the readout under the preview.
public enum Timecode {
    public static func text(_ seconds: Double) -> String {
        let hundredths = Int((max(seconds, 0) * 100).rounded(.down))
        return String(format: "%d:%02d.%02d", hundredths / 6000, hundredths / 100 % 60, hundredths % 100)
    }

    /// `0:05`, a ruler label. A ruler whose ticks are under a second apart needs the hundredths too.
    public static func label(_ seconds: Double, step: Double) -> String {
        guard step >= 1 else { return text(seconds + 0.0001) }
        let s = Int(max(seconds, 0).rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// Where each second of the video sits along the timeline.
public struct TimelineScale: Equatable, Sendable {
    public var duration: Double
    /// The x of time zero and of the end, in the timeline's points.
    public var start: Double
    public var end: Double

    public init(duration: Double, start: Double, end: Double) {
        self.duration = max(duration, 0); self.start = start; self.end = max(end, start)
    }

    public var pointsPerSecond: Double { duration > 0 ? (end - start) / duration : 0 }

    public func x(_ t: Double) -> Double { start + min(max(t, 0), duration) * pointsPerSecond }

    public func time(_ x: Double) -> Double {
        guard pointsPerSecond > 0 else { return 0 }
        return min(max((x - start) / pointsPerSecond, 0), duration)
    }

    /// The labelled ticks: the smallest step in this list that keeps labels `minSpacing` points apart.
    public static let steps: [Double] = [0.1, 0.25, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600]

    public func majorStep(minSpacing: Double) -> Double {
        Self.steps.first { $0 * pointsPerSecond >= minSpacing } ?? Self.steps.last!
    }

    public func ticks(minSpacing: Double) -> [Double] {
        guard duration > 0, pointsPerSecond > 0 else { return [0] }
        let step = majorStep(minSpacing: minSpacing)
        return (0...Int((duration / step).rounded(.down))).map { Double($0) * step }
    }
}
