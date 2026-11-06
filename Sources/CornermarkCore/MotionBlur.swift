import Foundation

/// How the finished video smears what moves fast within one frame, the way a camera's open shutter does.
public struct MotionBlur: Codable, Equatable, Sendable {
    public enum Scope: String, Codable, CaseIterable, Sendable {
        case off
        /// The zoom's own moves: closing in, pulling out and panning while zoomed. Everything on the recording moves with it.
        case zooms
        /// The zoom's moves, and the pointer's own movement on top.
        case zoomsAndCursor
    }

    public static let shutterRange = 30.0...360.0
    /// The fewest drawings a moving frame averages with the shutter open all the way, and fewer at a smaller angle.
    public static let samplesPerFrame = 16

    public var scope: Scope
    /// How long the shutter stays open, in degrees of one frame: 180 is half a frame, 360 a whole one.
    public var shutterAngle: Double

    public init(scope: Scope = .zoomsAndCursor, shutterAngle: Double = 180) {
        self.scope = scope; self.shutterAngle = shutterAngle
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let d = MotionBlur()
        scope = (try? c.decodeIfPresent(Scope.self, forKey: .scope)) ?? d.scope
        shutterAngle = (try? c.decodeIfPresent(Double.self, forKey: .shutterAngle)) ?? d.shutterAngle
    }
    private enum Keys: String, CodingKey { case scope, shutterAngle }

    var angle: Double { min(max(shutterAngle, Self.shutterRange.lowerBound), Self.shutterRange.upperBound) }

    /// The fewest drawings a moving frame averages at this angle.
    public var sampleCount: Int { max(2, Int((angle / 360 * Double(Self.samplesPerFrame)).rounded(.up))) }
    /// Neighbouring drawings land at most this many output pixels apart, so a fast move smears instead of showing separate copies.
    public static let sampleSpacing = 1.5
    public static let maxSamples = 64
    /// Below this many output pixels of movement inside the shutter window the frame is drawn sharp.
    public static let stillThreshold = 0.05

    /// `count` moments evenly spaced inside a shutter window centred on `t`, so the smear sits around where the sharp frame would be.
    public func sampleTimes(at t: Double, fps: Int, count: Int? = nil) -> [Double] {
        let n = count ?? sampleCount, window = angle / 360 / Double(max(fps, 1))
        return (0..<n).map { t + window * ((Double($0) + 0.5) / Double(n) - 0.5) }
    }
}

/// The states one output frame averages. One state, the sharp frame, when blur is off or nothing it covers moves inside the shutter window.
/// Each sample is the frame at `outputTime` with the crop, and the pointer when the scope covers it, taken at its own moment. The recording's
/// picture, the camera, the rings and the badge stay those of `outputTime`: blur shows the zoom and the pointer moving, not what was filmed.
/// `pixelsAcross` is the width the recording is drawn at, which turns movement into output pixels: the faster it moves, the more samples.
public func frameSamples(_ project: RecordingProject, outputTime t: Double, fps: Int, pixelsAcross: Double) -> [FrameState] {
    let sharp = frameState(project, outputTime: t)
    let blur = project.edits.motionBlur
    guard blur.scope != .off else { return [sharp] }
    let timeline = project.timeline
    let clip = timeline.clipIndex(at: t)
    func sample(_ at: Double) -> FrameState {
        let moment = frameState(project, outputTime: at)
        var sample = sharp
        sample.crop = moment.crop
        // Across a cut the pointer is somewhere else in the recording, which is not movement.
        if blur.scope == .zoomsAndCursor, timeline.clipIndex(at: at) == clip { sample.cursor = moment.cursor }
        return sample
    }
    let window = blur.angle / 360 / Double(max(fps, 1))
    let travel = sample(t - window / 2).pixelsMoved(to: sample(t + window / 2), area: project.source, pixelsAcross: pixelsAcross)
    guard travel >= MotionBlur.stillThreshold else { return [sharp] }
    let count = min(MotionBlur.maxSamples, max(blur.sampleCount, Int((travel / MotionBlur.sampleSpacing).rounded(.up)) + 1))
    return blur.sampleTimes(at: t, fps: fps, count: count).map(sample)
}

extension FrameState {
    /// How far the farthest edge of the picture, or the pointer, travels between two states, in pixels of a recording drawn `pixelsAcross` wide.
    func pixelsMoved(to other: FrameState, area: RecordingProject.Source, pixelsAcross: Double) -> Double {
        let a = crop, b = other.crop
        let width = max((a.width + b.width) / 2, 1e-6), height = max((a.height + b.height) / 2, 1e-6)
        let across = pixelsAcross / width, down = pixelsAcross * area.pointHeight / max(area.pointWidth, 1) / height
        var travel = max(abs(a.x - b.x), abs(a.x + a.width - b.x - b.width)) * across
        travel = max(travel, max(abs(a.y - b.y), abs(a.y + a.height - b.y - b.height)) * down)
        if let p = cursor, let q = other.cursor {
            travel = max(travel, hypot(p.x - q.x, p.y - q.y) * pixelsAcross / max(area.pointWidth, 1) / width)
        }
        return travel
    }
}
