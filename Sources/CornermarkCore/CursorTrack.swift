import Foundation

public enum CursorStyle: String, Codable, CaseIterable, Sendable {
    case white, black, dot
}

public enum CursorMotion: String, Codable, CaseIterable, Sendable {
    /// The path as it was recorded.
    case natural
    /// The recorded path through a critically damped spring, which steadies a shaky hand and never overshoots a stop.
    case smooth
}

/// Where the pointer is and how much of it shows at a moment of the source video, from the recorded track and the viewer's choices.
/// Every answer is a closed form of the track and the time, so the preview and the export agree at any frame rate.
public enum CursorTrack {
    /// The spring's natural frequency in radians a second. Its lag on a moving pointer is `2 / springRate` seconds, about 0.14 s.
    public static let springRate = 14.0
    /// How long a still pointer stays before Hide when not moving fades it out.
    public static let idleDelay = 1.5
    public static let idleFade = 0.3
    /// Typing hides the pointer faster than idling: the key press is the moment the viewer's eye leaves it.
    public static let typingFade = 0.15
    /// The pointer is back in full by the time it starts to move.
    public static let returnFade = 0.15

    public static func frame(_ project: RecordingProject, at t: Double) -> CursorFrame? {
        let settings = project.edits.cursor
        guard settings.isVisible, let path = PointerPath.of(project.events.pointer) else { return nil }
        let opacity = visibility(path, keys: project.events.keys, settings: settings, at: t)
        guard opacity > 0 else { return nil }
        let at = settings.motion == .smooth ? path.smoothed(at: t) : path.recorded(at: t)
        let scale = min(max(settings.scale, CursorSettings.scaleRange.lowerBound), CursorSettings.scaleRange.upperBound)
        return CursorFrame(x: at.x, y: at.y, scale: scale, style: settings.style, opacity: opacity)
    }

    /// 1 shows the pointer in full and 0 hides it. Each hiding option fades out after its trigger and fades back in just before the
    /// pointer's next move, so the pointer never pops in or out.
    static func visibility(_ path: PointerPath, keys: [KeyEvent], settings: CursorSettings, at t: Double) -> Double {
        guard settings.hidesWhenIdle || settings.hidesWhenTyping, let still = path.stillStretch(at: t) else { return 1 }
        let back = 1 - ease((still.until - t) / returnFade)
        var opacity = 1.0
        if settings.hidesWhenIdle {
            opacity = min(opacity, max(1 - ease((t - still.since - idleDelay) / idleFade), back))
        }
        if settings.hidesWhenTyping, let typed = firstTyping(keys, from: still.since, to: t) {
            opacity = min(opacity, max(1 - ease((t - typed) / typingFade), back))
        }
        return opacity
    }

    /// The first key press without Command or Control in `from...to`. Keys are sorted by time.
    private static func firstTyping(_ keys: [KeyEvent], from: Double, to: Double) -> Double? {
        var low = 0, high = keys.count
        while low < high {
            let mid = (low + high) / 2
            if keys[mid].t < from { low = mid + 1 } else { high = mid }
        }
        for key in keys[low...] {
            if key.t > to { return nil }
            if !key.isCommand { return key.t }
        }
        return nil
    }

    private static func ease(_ x: Double) -> Double {
        let u = min(max(x, 0), 1)
        return u * u * (3 - 2 * u)
    }
}

/// A recorded pointer track read for drawing: straight lines between samples, the spring's state at every sample, and the stretches
/// in which the pointer moved. Built once per track and shared, since the editor and an export draw the same track every frame.
final class PointerPath: Sendable {
    private struct Spring: Sendable {
        var x: Double, y: Double, vx: Double, vy: Double
    }

    let samples: [PointerSample]
    private let springs: [Spring]
    /// Sorted, disjoint and apart: `moveStarts[i]...moveEnds[i]` is one stretch of movement.
    private let moveStarts: [Double]
    private let moveEnds: [Double]

    init?(_ samples: [PointerSample]) {
        guard let first = samples.first else { return nil }
        self.samples = samples
        var springs = [Spring(x: first.x, y: first.y, vx: 0, vy: 0)]
        springs.reserveCapacity(samples.count)
        var starts: [Double] = [], ends: [Double] = []
        for (a, b) in zip(samples, samples.dropFirst()) {
            let dt = b.t - a.t
            guard dt > 0 else { springs.append(springs[springs.count - 1]); continue }
            springs.append(Self.advance(springs[springs.count - 1], from: a, to: b, by: dt))
            guard a.x != b.x || a.y != b.y else { continue }
            if let end = ends.last, end >= a.t { ends[ends.count - 1] = b.t } else { starts.append(a.t); ends.append(b.t) }
        }
        self.springs = springs
        moveStarts = starts
        moveEnds = ends
    }

    func recorded(at t: Double) -> (x: Double, y: Double) {
        PointerTrack.position(samples, at: t) ?? (samples[0].x, samples[0].y)
    }

    func smoothed(at t: Double) -> (x: Double, y: Double) {
        let first = samples[0], last = samples[samples.count - 1]
        if t <= first.t { return (first.x, first.y) }
        let i = t >= last.t ? samples.count - 1 : segment(at: t)
        let a = samples[i]
        let b = i + 1 < samples.count ? samples[i + 1] : a
        let s = Self.advance(springs[i], from: a, to: b, by: t - a.t)
        return (s.x, s.y)
    }

    /// The still stretch around `t`: since the last move ended, or the video began, until the next move starts. Nil while moving.
    func stillStretch(at t: Double) -> (since: Double, until: Double)? {
        var low = 0, high = moveStarts.count
        while low < high {
            let mid = (low + high) / 2
            if moveStarts[mid] <= t { low = mid + 1 } else { high = mid }
        }
        let next = low < moveStarts.count ? moveStarts[low] : .infinity
        guard low > 0 else { return (0, next) }
        if t < moveEnds[low - 1] { return nil }
        return (moveEnds[low - 1], next)
    }

    /// The index of the sample that starts the straight line through `t`, for `samples[0].t < t < samples.last.t`.
    private func segment(at t: Double) -> Int {
        var low = 0, high = samples.count - 1
        while high - low > 1 {
            let mid = (low + high) / 2
            if samples[mid].t <= t { low = mid } else { high = mid }
        }
        return low
    }

    /// The exact state `tau` seconds after `state`, while the spring's target runs in a straight line from `a` toward `b`.
    /// With target `g + s·τ`, the error from the target settles as `-2s/ω + (A + Bτ)·e^(-ωτ)`, so no step size can go unstable.
    /// Past the last sample `a == b` and the target stands still.
    private static func advance(_ state: Spring, from a: PointerSample, to b: PointerSample, by tau: Double) -> Spring {
        let w = CursorTrack.springRate
        let span = b.t - a.t
        let decay = exp(-w * tau)
        func axis(_ x: Double, _ v: Double, _ g0: Double, _ g1: Double) -> (Double, Double) {
            let slope = span > 0 ? (g1 - g0) / span : 0
            let u0 = x - g0 + 2 * slope / w
            let rate = v - slope + w * u0
            let u = (u0 + rate * tau) * decay
            let du = (rate - w * (u0 + rate * tau)) * decay
            return (g0 + slope * tau + u - 2 * slope / w, slope + du)
        }
        let (x, vx) = axis(state.x, state.vx, a.x, b.x)
        let (y, vy) = axis(state.y, state.vy, a.y, b.y)
        return Spring(x: x, y: y, vx: vx, vy: vy)
    }

    /// The path of `samples`, built at most once while it is in use. Arrays that share storage compare in constant time,
    /// so a frame that asks for the track it asked for last pays nothing.
    static func of(_ samples: [PointerSample]) -> PointerPath? {
        cache.path(for: samples)
    }

    private static let cache = Cache()

    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var recent: [PointerPath] = []

        func path(for samples: [PointerSample]) -> PointerPath? {
            guard !samples.isEmpty else { return nil }
            lock.lock()
            defer { lock.unlock() }
            if let hit = recent.firstIndex(where: { $0.samples == samples }) {
                let path = recent.remove(at: hit)
                recent.insert(path, at: 0)
                return path
            }
            guard let path = PointerPath(samples) else { return nil }
            recent.insert(path, at: 0)
            if recent.count > 4 { recent.removeLast() }
            return path
        }
    }
}
