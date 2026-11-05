import CoreGraphics
import Foundation

/// A pointer path in fractions of the filmed area, 0 to 1 from the top-left corner, so it fits any size.
public struct PointerScript: Equatable {
    public struct Waypoint: Equatable {
        public var t: Double
        public var x: Double
        public var y: Double
        public init(t: Double, x: Double, y: Double) { self.t = t; self.x = x; self.y = y }
    }

    public var waypoints: [Waypoint]
    /// Starts over when the last waypoint passes. Otherwise the pointer stays there.
    public var loops: Bool

    public init(_ waypoints: [Waypoint], loops: Bool = false) { self.waypoints = waypoints; self.loops = loops }

    /// A lap around the area and back to the middle, one second a leg, with a rest at each corner so a still pointer shows too.
    public static let tour = PointerScript([
        Waypoint(t: 0, x: 0.15, y: 0.20), Waypoint(t: 0.6, x: 0.15, y: 0.20),
        Waypoint(t: 1.6, x: 0.85, y: 0.20), Waypoint(t: 2.2, x: 0.85, y: 0.20),
        Waypoint(t: 3.2, x: 0.85, y: 0.80), Waypoint(t: 3.8, x: 0.85, y: 0.80),
        Waypoint(t: 4.8, x: 0.15, y: 0.80), Waypoint(t: 5.4, x: 0.15, y: 0.80),
        Waypoint(t: 6.4, x: 0.50, y: 0.50), Waypoint(t: 7.0, x: 0.50, y: 0.50),
    ], loops: true)

    public var duration: Double { waypoints.last?.t ?? 0 }

    /// Each leg eases in and out, so the pointer starts and stops like a hand.
    public func position(at time: Double) -> (x: Double, y: Double)? {
        guard let first = waypoints.first, let last = waypoints.last else { return nil }
        var t = max(time, 0)
        if loops, last.t > first.t { t = first.t + (t - first.t).truncatingRemainder(dividingBy: last.t - first.t) }
        if t <= first.t { return (first.x, first.y) }
        if t >= last.t { return (last.x, last.y) }
        guard let next = waypoints.firstIndex(where: { $0.t > t }) else { return (last.x, last.y) }
        let a = waypoints[next - 1], b = waypoints[next]
        let f = (t - a.t) / (b.t - a.t)
        let e = f * f * (3 - 2 * f)
        return (a.x + (b.x - a.x) * e, a.y + (b.y - a.y) * e)
    }
}

/// Replays a `PointerScript` instead of reading the pointer.
public final class ScriptedPointerSource: PointerSource {
    public enum Pacing {
        /// Readings arrive at `rate` a second for as long as the recording runs, the first one stamped with the clock at `start`.
        case realtime
        /// `count` readings arrive from `start` itself, exactly `1/rate` apart, the first stamped `origin`.
        case fixed(origin: Double, count: Int)
    }

    private let script: PointerScript
    private let rate: Int
    private let pacing: Pacing
    private let queue = DispatchQueue(label: "cornermark.scripted-pointer", qos: .userInteractive)
    private var timer: DispatchSourceTimer?

    public init(script: PointerScript = .tour, rate: Int = 120, pacing: Pacing = .realtime) {
        self.script = script; self.rate = rate; self.pacing = pacing
    }

    public func start(in area: CGRect, deliver: @escaping (PointerReading) -> Void) {
        func reading(_ k: Int, origin: Double) -> PointerReading? {
            let elapsed = Double(k) / Double(rate)
            guard let p = script.position(at: elapsed) else { return nil }
            return PointerReading(time: origin + elapsed, x: p.x * area.width, y: p.y * area.height)
        }
        switch pacing {
        case .fixed(let origin, let count):
            for k in 0..<count { if let r = reading(k, origin: origin) { deliver(r) } }
        case .realtime:
            let origin = recordingClockNow()
            var k = 0
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: .nanoseconds(1_000_000_000 / rate), leeway: .microseconds(500))
            timer.setEventHandler {
                if let r = reading(k, origin: origin) { deliver(r) }
                k += 1
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
