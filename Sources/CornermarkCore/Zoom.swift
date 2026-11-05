import Foundation

/// What the camera aims at inside a zoom. Until following the pointer and picking a target by hand arrive, both modes hold the
/// zoom's stored center.
public enum ZoomMode: String, Codable, CaseIterable, Sendable {
    case followCursor, manual

    public var title: String {
        switch self {
        case .followCursor: return "Follow Cursor"
        case .manual: return "Manual"
        }
    }
}

/// A point of the recorded area as fractions of its size, from the top-left corner with y down.
public struct ZoomPoint: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
    public static let middle = ZoomPoint(x: 0.5, y: 0.5)
}

/// The part of the recorded area the finished video shows, as fractions of its size from the top-left corner with y down.
/// It keeps the recording's shape, so `width == height`.
public struct ZoomRect: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public init(x: Double, y: Double, width: Double, height: Double) { self.x = x; self.y = y; self.width = width; self.height = height }

    public static let full = ZoomRect(x: 0, y: 0, width: 1, height: 1)
    /// 1 is the whole picture, 2 shows half its width.
    public var scale: Double { 1 / width }
}

/// One zoom on the timeline: from `start` to `end` seconds of the finished video the camera closes in to `scale`.
public struct Zoom: Codable, Equatable, Sendable, Identifiable {
    /// The steps the level menu offers. The slider reaches everything between them.
    public static let levels: [Double] = [1, 1.5, 2, 3, 4]
    public static let scaleRange = 1.0...4.0
    public static let defaultScale = 2.0
    /// A click on the lane adds a zoom this long.
    public static let defaultDuration = 2.0
    public static let minimumDuration = 0.5

    public var id: UUID
    public var start: Double
    public var end: Double
    public var scale: Double
    public var mode: ZoomMode
    /// Where the camera aims while zoomed.
    public var center: ZoomPoint

    public init(id: UUID = UUID(), start: Double, end: Double, scale: Double = Zoom.defaultScale, mode: ZoomMode = .followCursor,
                center: ZoomPoint = .middle) {
        self.id = id; self.start = start; self.end = end; self.scale = scale; self.mode = mode; self.center = center
    }

    public var duration: Double { end - start }

    /// The level as a whole percentage, the way the lane and the menu name it.
    public static func percent(_ scale: Double) -> String { "\(Int((scale * 100).rounded()))%" }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        start = try c.decode(Double.self, forKey: .start)
        end = try c.decode(Double.self, forKey: .end)
        guard start.isFinite, end.isFinite, end > start else {
            throw DecodingError.dataCorruptedError(forKey: .end, in: c, debugDescription: "a zoom ends after it starts")
        }
        let s = try c.decodeIfPresent(Double.self, forKey: .scale) ?? Self.defaultScale
        scale = s.isFinite ? min(max(s, Self.scaleRange.lowerBound), Self.scaleRange.upperBound) : Self.defaultScale
        mode = (try? c.decodeIfPresent(ZoomMode.self, forKey: .mode)) ?? .followCursor
        center = (try? c.decodeIfPresent(ZoomPoint.self, forKey: .center)) ?? .middle
    }
    private enum Keys: String, CodingKey { case id, start, end, scale, mode, center }
}

/// How the camera moves into and out of a zoom.
public enum ZoomCurve {
    /// Seconds a full move into or out of a zoom takes.
    public static let duration = 0.68
    /// A rest at the whole picture shorter than this between two zooms would read as a bounce, so the camera goes from the first
    /// zoom straight to the second.
    public static let joinGap = 2 * duration

    /// Zero speed and zero acceleration at both ends, the fastest point exactly halfway.
    public static func smootherstep(_ u: Double) -> Double {
        let x = min(max(u, 0), 1)
        return x * x * x * (x * (x * 6 - 15) + 10)
    }

    /// Each end of a zoom moves for the full duration, or for half the zoom when it is shorter than two moves.
    public static func ramp(_ zoom: Zoom) -> Double { min(duration, zoom.duration / 2) }
}

public enum ZoomCamera {
    /// What the finished video shows at `t` seconds. Pure, so preview and export cannot disagree.
    /// A zoom's move in happens over its first `ramp` seconds and its move out over its last, so outside every zoom the picture is
    /// whole. A zoom that starts within `joinGap` of the one before moves in from that zoom instead of from the whole picture, and
    /// the one before then holds until it does.
    public static func rect(_ zooms: [Zoom], at t: Double) -> ZoomRect {
        guard let i = zooms.lastIndex(where: { $0.start <= t }) else { return .full }
        let zoom = zooms[i]
        let joinedNext = i + 1 < zooms.count && zooms[i + 1].start - zoom.end < ZoomCurve.joinGap
        guard t < zoom.end else { return joinedNext ? target(zoom) : .full }
        let joinedPrevious = i > 0 && zoom.start - zooms[i - 1].end < ZoomCurve.joinGap
        let ramp = ZoomCurve.ramp(zoom)
        if t < zoom.start + ramp {
            let from = joinedPrevious ? target(zooms[i - 1]) : .full
            return blend(from, target(zoom), ZoomCurve.smootherstep((t - zoom.start) / ramp))
        }
        if !joinedNext && t > zoom.end - ramp {
            return blend(.full, target(zoom), ZoomCurve.smootherstep((zoom.end - t) / ramp))
        }
        return target(zoom)
    }

    /// The zoom's level around its center, moved inside the picture where the center sits too close to an edge.
    public static func target(_ zoom: Zoom) -> ZoomRect {
        let side = 1 / min(max(zoom.scale, Zoom.scaleRange.lowerBound), Zoom.scaleRange.upperBound)
        func origin(_ c: Double) -> Double { min(max(c - side / 2, 0), 1 - side) }
        return ZoomRect(x: origin(zoom.center.x), y: origin(zoom.center.y), width: side, height: side)
    }

    /// The scale goes from `a`'s to `b`'s along `e`, and the picture grows about the one point that sits still in both, so the move
    /// reads as a single zoom and never shows past the picture's edge. Equal scales pan in a straight line instead.
    static func blend(_ a: ZoomRect, _ b: ZoomRect, _ e: Double) -> ZoomRect {
        let scale = a.scale + (b.scale - a.scale) * e
        let side = 1 / scale
        guard abs(a.width - b.width) > 1e-12 else {
            return ZoomRect(x: a.x + (b.x - a.x) * e, y: a.y + (b.y - a.y) * e, width: side, height: side)
        }
        let k = b.width / a.width
        let fx = (b.x - a.x * k) / (1 - k), fy = (b.y - a.y * k) / (1 - k)
        let grow = side / a.width
        return ZoomRect(x: fx + (a.x - fx) * grow, y: fy + (a.y - fy) * grow, width: side, height: side)
    }
}

/// The zooms of one video, ordered and apart, with the edits the lane offers. Every edit keeps them inside the video and apart.
public struct ZoomLane: Equatable, Sendable {
    public private(set) var zooms: [Zoom]
    public let duration: Double

    public enum Edge: Sendable { case start, end }

    /// Zooms are sorted; one that overlaps the zoom before it, or lies outside the video, is left out.
    public init(_ zooms: [Zoom], duration: Double) {
        self.duration = max(duration, 0)
        var kept: [Zoom] = []
        for zoom in zooms.sorted(by: { $0.start < $1.start }) where zoom.start >= 0 && zoom.end <= self.duration + 1e-9 {
            if let last = kept.last, zoom.start < last.end { continue }
            kept.append(zoom)
        }
        self.zooms = kept
    }

    public func index(of id: UUID) -> Int? { zooms.firstIndex { $0.id == id } }
    public func zoom(_ id: UUID) -> Zoom? { index(of: id).map { zooms[$0] } }
    public func zoom(at t: Double) -> Zoom? { zooms.first { $0.start <= t && t < $0.end } }

    /// The free stretch `t` falls in, between the zoom before it (or the start) and the zoom after it (or the end).
    public func gap(around t: Double) -> ClosedRange<Double>? {
        guard t >= 0, t <= duration, zoom(at: t) == nil else { return nil }
        let low = zooms.last { $0.end <= t }?.end ?? 0
        let high = zooms.first { $0.start > t }?.start ?? duration
        return low...high
    }

    /// A zoom over `from`...`to` inside the free stretch `from` falls in. A click passes no `to` and gets the default length, moved
    /// earlier when the stretch ends sooner. Nil when the stretch is shorter than the shortest zoom.
    public func adding(from: Double, to: Double? = nil, center: ZoomPoint = .middle) -> (lane: ZoomLane, zoom: Zoom)? {
        guard let gap = gap(around: min(max(from, 0), duration)), gap.upperBound - gap.lowerBound >= Zoom.minimumDuration - 1e-9 else { return nil }
        var a: Double, b: Double
        if let to {
            a = min(max(min(from, to), gap.lowerBound), gap.upperBound)
            b = min(max(max(from, to), gap.lowerBound), gap.upperBound)
            if b - a < Zoom.minimumDuration { b = min(a + Zoom.minimumDuration, gap.upperBound); a = b - Zoom.minimumDuration }
        } else {
            let length = min(Zoom.defaultDuration, gap.upperBound - gap.lowerBound)
            a = min(max(from, gap.lowerBound), gap.upperBound - length)
            b = a + length
        }
        let zoom = Zoom(start: a, end: b, center: center)
        return (ZoomLane(zooms + [zoom], duration: duration), zoom)
    }

    /// Moves a zoom to start at `start`, stopping at its neighbours and the ends of the video.
    public func moving(_ id: UUID, to start: Double) -> ZoomLane {
        guard let i = index(of: id) else { return self }
        let zoom = zooms[i]
        let low = i > 0 ? zooms[i - 1].end : 0
        let high = (i + 1 < zooms.count ? zooms[i + 1].start : duration) - zoom.duration
        let s = min(max(start, low), max(high, low))
        return updating(id) { $0.start = s; $0.end = s + zoom.duration }
    }

    /// Moves one edge to `t`, stopping at the neighbour on that side and keeping the shortest zoom length.
    public func resizing(_ id: UUID, _ edge: Edge, to t: Double) -> ZoomLane {
        guard let i = index(of: id) else { return self }
        let zoom = zooms[i]
        switch edge {
        case .start:
            let low = i > 0 ? zooms[i - 1].end : 0
            let s = min(max(t, low), zoom.end - Zoom.minimumDuration)
            return updating(id) { $0.start = s }
        case .end:
            let high = i + 1 < zooms.count ? zooms[i + 1].start : duration
            let e = max(min(t, high), zoom.start + Zoom.minimumDuration)
            return updating(id) { $0.end = e }
        }
    }

    /// Two zooms with the same settings, meeting at `t`. Nil when either part would be shorter than the shortest zoom.
    public func splitting(_ id: UUID, at t: Double) -> (lane: ZoomLane, second: Zoom)? {
        guard let zoom = zoom(id), t - zoom.start >= Zoom.minimumDuration - 1e-9, zoom.end - t >= Zoom.minimumDuration - 1e-9 else { return nil }
        var first = zoom, second = zoom
        first.end = t
        second.id = UUID()
        second.start = t
        return (ZoomLane(zooms.filter { $0.id != id } + [first, second], duration: duration), second)
    }

    /// A copy with the same settings and length in the first free stretch after the zoom that holds it. Nil when none does.
    public func duplicating(_ id: UUID) -> (lane: ZoomLane, copy: Zoom)? {
        guard let i = index(of: id) else { return nil }
        let zoom = zooms[i]
        var low = zoom.end
        for next in zooms[(i + 1)...] + [Zoom(start: duration, end: duration + 1)] {
            if next.start - low >= zoom.duration - 1e-9 {
                var copy = zoom
                copy.id = UUID()
                copy.start = low
                copy.end = low + zoom.duration
                return (ZoomLane(zooms + [copy], duration: duration), copy)
            }
            low = next.end
        }
        return nil
    }

    public func removing(_ id: UUID) -> ZoomLane { ZoomLane(zooms.filter { $0.id != id }, duration: duration) }

    public func updating(_ id: UUID, _ change: (inout Zoom) -> Void) -> ZoomLane {
        ZoomLane(zooms.map { zoom in
            guard zoom.id == id else { return zoom }
            var z = zoom
            change(&z)
            return z
        }, duration: duration)
    }

    public func settingScale(_ scale: Double) -> ZoomLane {
        let s = min(max(scale, Zoom.scaleRange.lowerBound), Zoom.scaleRange.upperBound)
        return ZoomLane(zooms.map { var z = $0; z.scale = s; return z }, duration: duration)
    }
}
