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
    /// The recording has no mouse-up time, so a press is a fixed shape from the click.
    public static let pressDepth = 0.8
    public static let pressDown = 0.05
    public static let pressRelease = 0.18
    public static var pressLength: Double { pressDown + pressRelease }

    public static func frame(_ project: RecordingProject, at t: Double) -> CursorFrame? {
        let settings = project.edits.cursor
        guard settings.isVisible, let path = PointerPath.of(project.events.pointer) else { return nil }
        let opacity = visibility(path, keys: project.events.keys, settings: settings, at: t)
        guard opacity > 0 else { return nil }
        let at = settings.motion == .smooth ? path.smoothed(at: t) : path.recorded(at: t)
        var scale = min(max(settings.scale, CursorSettings.scaleRange.lowerBound), CursorSettings.scaleRange.upperBound)
        if settings.pressesOnClick { scale *= press(project.events.clicks, at: t) }
        return CursorFrame(x: at.x, y: at.y, scale: scale, style: settings.style, opacity: opacity)
    }

    /// The ring centres on the drawn pointer, not the click point, so under Smooth it meets the pressed pointer instead of leading it.
    public static func anchor(_ click: ClickEvent, in project: RecordingProject) -> (x: Double, y: Double) {
        guard let path = PointerPath.of(project.events.pointer) else { return (click.x, click.y) }
        return project.edits.cursor.motion == .smooth ? path.smoothed(at: click.t) : path.recorded(at: click.t)
    }

    static func press(_ clicks: [ClickEvent], at t: Double) -> Double {
        var factor = 1.0
        for click in clicks[firstIndex(clicks, from: t - pressLength)...] {
            let age = t - click.t
            if age < 0 { break }
            let f = age < pressDown ? 1 - (1 - pressDepth) * ease(age / pressDown)
                : pressDepth + (1 - pressDepth) * ease((age - pressDown) / pressRelease)
            factor = min(factor, f)
        }
        return factor
    }

    static func firstIndex(_ clicks: [ClickEvent], from: Double) -> Int {
        var low = 0, high = clicks.count
        while low < high {
            let mid = (low + high) / 2
            if clicks[mid].t < from { low = mid + 1 } else { high = mid }
        }
        return low
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

    /// Far below a pixel: two samples this close are the same still pointer, whatever rounding put between them.
    static let stillTolerance = 0.001

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
            guard abs(b.x - a.x) > Self.stillTolerance || abs(b.y - a.y) > Self.stillTolerance else { continue }
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
    /// Past the last sample `a == b` and the target stands still.
    private static func advance(_ state: Spring, from a: PointerSample, to b: PointerSample, by tau: Double) -> Spring {
        let w = CursorTrack.springRate, span = b.t - a.t
        let (x, vx) = CriticalSpring.advance(state.x, state.vx, from: a.x, to: b.x, over: span, by: tau, rate: w)
        let (y, vy) = CriticalSpring.advance(state.y, state.vy, from: a.y, to: b.y, over: span, by: tau, rate: w)
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
