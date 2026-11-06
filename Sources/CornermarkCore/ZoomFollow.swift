import Foundation

/// How a zoom that follows the cursor keeps the pointer in view. The camera holds while the pointer moves inside the middle of the
/// view, and drifts after it once the pointer pushes past that middle, starting and stopping without a jolt. The project's
/// `ZoomAnimation` sets the size of that middle and the drift's rate.
public enum ZoomFollow {
    /// The spacing of the precomputed track, in seconds of the finished video. Between two steps the drift is solved exactly.
    static let step = 1.0 / 240
}

/// Where each zoom that follows the cursor aims over time, on the finished video's timeline. Built once per project and shared,
/// since the editor and an export ask for every frame. Every answer depends only on the project and the time asked about, never on
/// which frames were asked for before, so the preview and the export agree frame by frame at any frame rate.
///
/// The camera aims for a lazy point that stays put while the pointer is within the animation's `deadZone` of the view around it and is dragged by
/// the pointer once it reaches that edge. The camera's centre follows the lazy point, held inside the picture, through a critically
/// damped spring, so its speed changes smoothly even when the pointer jumps at a cut between clips.
final class FollowPath: Sendable {
    struct State: Sendable {
        /// The lazy point, as fractions of the recorded area.
        var lx: Double, ly: Double
        /// The camera's centre and its speed in fractions a second.
        var x: Double, y: Double, vx: Double, vy: Double
    }

    struct Track: Sendable {
        let start: Double
        let end: Double
        let scale: Double
        let rate: Double
        /// `states[k]` is the state at `start + k * step`.
        let states: [State]

        /// The lowest and highest centre that keeps a view at `scale` inside the picture.
        var bounds: ClosedRange<Double> { Self.bounds(scale) }

        static func bounds(_ scale: Double) -> ClosedRange<Double> {
            let half = 0.5 / min(max(scale, Zoom.scaleRange.lowerBound), Zoom.scaleRange.upperBound)
            return half...(1 - half)
        }

        func state(at t: Double) -> State {
            let u = min(max(t, start), end) - start
            let k = min(Int(u / ZoomFollow.step), states.count - 1)
            let a = states[k], b = k + 1 < states.count ? states[k + 1] : a
            let tau = min(u - Double(k) * ZoomFollow.step, ZoomFollow.step)
            let f = tau / ZoomFollow.step
            let range = bounds
            func clamp(_ v: Double) -> Double { min(max(v, range.lowerBound), range.upperBound) }
            let (x, vx) = CriticalSpring.advance(a.x, a.vx, from: clamp(a.lx), to: clamp(b.lx), over: ZoomFollow.step, by: tau, rate: rate)
            let (y, vy) = CriticalSpring.advance(a.y, a.vy, from: clamp(a.ly), to: clamp(b.ly), over: ZoomFollow.step, by: tau, rate: rate)
            return State(lx: a.lx + (b.lx - a.lx) * f, ly: a.ly + (b.ly - a.ly) * f, x: x, y: y, vx: vx, vy: vy)
        }
    }

    /// One per zoom, nil for a zoom aimed by hand.
    private let tracks: [Track?]

    /// `pointer` gives the drawn pointer at a moment of the finished video, as fractions of the recorded area.
    init(zooms: [Zoom], animation: ZoomAnimation = ZoomAnimation(), pointer: (Double) -> (x: Double, y: Double)) {
        let rate = animation.driftRate
        var tracks: [Track?] = []
        for (i, zoom) in zooms.enumerated() {
            guard zoom.mode == .followCursor else { tracks.append(nil); continue }
            let next = i + 1 < zooms.count ? zooms[i + 1] : nil
            // A zoom the next one moves in from is still aimed at while that move lasts.
            let end = next.map { $0.start - zoom.end < animation.joinGap ? $0.start + animation.ramp($0) : zoom.end } ?? zoom.end
            let range = Track.bounds(zoom.scale)
            func clamp(_ v: Double) -> Double { min(max(v, range.lowerBound), range.upperBound) }
            var state: State
            if i > 0, zoom.start - zooms[i - 1].end < animation.joinGap, let before = tracks[i - 1] {
                // Following on from a zoom that followed too keeps its drift, so splitting a zoom changes nothing on screen.
                state = before.state(at: zoom.start)
                if state.x != clamp(state.x) { state.x = clamp(state.x); state.vx = 0 }
                if state.y != clamp(state.y) { state.y = clamp(state.y); state.vy = 0 }
            } else {
                let p = pointer(zoom.start)
                state = State(lx: p.x, ly: p.y, x: clamp(p.x), y: clamp(p.y), vx: 0, vy: 0)
            }
            let reach = animation.deadZone / 2 / min(max(zoom.scale, Zoom.scaleRange.lowerBound), Zoom.scaleRange.upperBound)
            func drag(_ lazy: Double, _ p: Double) -> Double { min(max(lazy, p - reach), p + reach) }
            let count = max(Int(((end - zoom.start) / ZoomFollow.step).rounded(.up)), 1)
            var states = [state]
            states.reserveCapacity(count + 1)
            for k in 1...count {
                let p = pointer(zoom.start + Double(k) * ZoomFollow.step)
                let a = states[k - 1]
                let lx = drag(a.lx, p.x), ly = drag(a.ly, p.y)
                let (x, vx) = CriticalSpring.advance(a.x, a.vx, from: clamp(a.lx), to: clamp(lx), over: ZoomFollow.step, by: ZoomFollow.step, rate: rate)
                let (y, vy) = CriticalSpring.advance(a.y, a.vy, from: clamp(a.ly), to: clamp(ly), over: ZoomFollow.step, by: ZoomFollow.step, rate: rate)
                states.append(State(lx: lx, ly: ly, x: x, y: y, vx: vx, vy: vy))
            }
            tracks.append(Track(start: zoom.start, end: zoom.start + Double(count) * ZoomFollow.step, scale: zoom.scale, rate: rate, states: states))
        }
        self.tracks = tracks
    }

    /// Where zoom `index` aims at `t`, or nil when it is aimed by hand.
    func center(_ index: Int, at t: Double) -> ZoomPoint? {
        guard tracks.indices.contains(index), let track = tracks[index] else { return nil }
        let s = track.state(at: t)
        return ZoomPoint(x: s.x, y: s.y)
    }

    /// The path of `project`'s follow zooms, built at most once while it is in use. Nil when no zoom follows the cursor or the
    /// recording has no pointer to follow.
    static func of(_ project: RecordingProject) -> FollowPath? {
        guard project.edits.zooms.contains(where: { $0.mode == .followCursor }), !project.events.pointer.isEmpty,
              project.source.pointWidth > 0, project.source.pointHeight > 0 else { return nil }
        return cache.path(for: Key(project))
    }

    private struct Key: Equatable {
        let pointer: [PointerSample]
        let motion: CursorMotion
        let zooms: [Zoom]
        let animation: ZoomAnimation
        let clips: [Clip]
        let source: RecordingProject.Source

        init(_ project: RecordingProject) {
            pointer = project.events.pointer; motion = project.edits.cursor.motion; zooms = project.edits.zooms
            animation = project.edits.zoomAnimation; clips = project.edits.clips; source = project.source
        }

        func build() -> FollowPath? {
            guard let path = PointerPath.of(pointer) else { return nil }
            let timeline = ClipTimeline(clips: clips, source: source)
            let w = source.pointWidth, h = source.pointHeight, smooth = motion == .smooth
            // The camera keeps the pointer the viewer sees in view, which under Smooth trails the recorded one.
            return FollowPath(zooms: zooms, animation: animation) { t in
                let s = timeline.sourceTime(at: t)
                let p = smooth ? path.smoothed(at: s) : path.recorded(at: s)
                return (p.x / w, p.y / h)
            }
        }
    }

    private static let cache = Cache()

    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var recent: [(key: Key, path: FollowPath)] = []

        func path(for key: Key) -> FollowPath? {
            lock.lock()
            defer { lock.unlock() }
            if let hit = recent.firstIndex(where: { $0.key == key }) {
                let entry = recent.remove(at: hit)
                recent.insert(entry, at: 0)
                return entry.path
            }
            guard let path = key.build() else { return nil }
            recent.insert((key, path), at: 0)
            if recent.count > 4 { recent.removeLast() }
            return path
        }
    }
}

/// A critically damped spring chasing a target that moves in a straight line, solved exactly, so no step size can go unstable.
enum CriticalSpring {
    /// The position and speed `tau` seconds after (`x`, `v`), while the target runs from `g0` to `g1` over `span` seconds at
    /// natural frequency `rate`. With target `g0 + s·τ` the error from the target settles as `-2s/ω + (A + Bτ)·e^(-ωτ)`.
    static func advance(_ x: Double, _ v: Double, from g0: Double, to g1: Double, over span: Double, by tau: Double, rate w: Double) -> (Double, Double) {
        let slope = span > 0 ? (g1 - g0) / span : 0
        let decay = exp(-w * tau)
        let u0 = x - g0 + 2 * slope / w
        let k = v - slope + w * u0
        let u = (u0 + k * tau) * decay
        let du = (k - w * (u0 + k * tau)) * decay
        return (g0 + slope * tau + u - 2 * slope / w, slope + du)
    }
}
