import Foundation

/// A kept piece of the recording, in seconds of the source video. The finished video plays the project's clips one after another.
public struct Clip: Codable, Equatable, Sendable {
    public var start: Double
    public var end: Double

    public init(start: Double, end: Double) { self.start = start; self.end = end }

    public var duration: Double { end - start }
}

/// The finished video's timeline: the project's clips back to back. Output time runs over the clips in order, source time is the
/// recording's own. Clips are ordered, apart and inside the source, so source time never runs backwards as output time runs forward,
/// and every track recorded on the source's clock maps through `sourceTime(at:)`.
public struct ClipTimeline: Equatable, Sendable {
    public let clips: [Clip]
    public let sourceDuration: Double
    /// Source frames per second. Edits put clip edges on this grid, so an output frame always lands on whole source frames.
    public let fps: Double

    public enum Edge: Equatable, Sendable { case start, end }

    /// Puts any list of clips into shape: inside the source, ordered, apart and not empty. A project without clips, or whose clips
    /// all fell outside the source, keeps the whole recording.
    public init(clips: [Clip], source: RecordingProject.Source) {
        let duration = max(source.duration, 0)
        sourceDuration = duration
        fps = Double(max(source.fps, 1))
        var kept: [Clip] = []
        for clip in clips.sorted(by: { $0.start < $1.start }) {
            let start = max(clip.start, kept.last?.end ?? 0, 0), end = min(clip.end, duration)
            if end - start > 1e-9 { kept.append(Clip(start: start, end: end)) }
        }
        self.clips = kept.isEmpty ? [Clip(start: 0, end: duration)] : kept
    }

    private init(_ clips: [Clip], like other: ClipTimeline) {
        self.clips = clips; sourceDuration = other.sourceDuration; fps = other.fps
    }

    public var frame: Double { 1 / fps }

    /// The finished video's length.
    public var duration: Double { clips.reduce(0) { $0 + $1.duration } }

    /// Where each clip begins in the finished video.
    public var starts: [Double] {
        var at = 0.0
        return clips.map { clip in defer { at += clip.duration }; return at }
    }

    /// Where one clip ends and the next begins, in the finished video.
    public var cuts: [Double] { Array(starts.dropFirst()) }

    /// The clip playing at `t`. A cut belongs to the clip it starts.
    public func clipIndex(at t: Double) -> Int {
        starts.lastIndex { $0 <= t + 1e-9 } ?? 0
    }

    /// The source moment shown at `t` seconds of the finished video. At the end and past it, the middle of the last kept frame,
    /// so a still playhead at the end shows that frame and never the one after it.
    public func sourceTime(at t: Double) -> Double {
        let last = clips[clips.count - 1]
        guard t < duration - 1e-9 else { return max(last.end - frame / 2, last.start) }
        let i = clipIndex(at: max(t, 0))
        return clips[i].start + max(t, 0) - starts[i]
    }

    /// Where a source moment plays in the finished video, or nil when it was cut out.
    public func outputTime(ofSource s: Double) -> Double? {
        zip(clips, starts).first { s >= $0.0.start - 1e-9 && s < $0.0.end - 1e-9 }.map { $0.1 + s - $0.0.start }
    }

    /// Two clips where one was, cut at the source frame nearest `t`. Nil when either piece would be shorter than a frame.
    public func splitting(at t: Double) -> ClipTimeline? {
        let i = clipIndex(at: t), clip = clips[i]
        let cut = snap(clip.start + t - starts[i])
        guard cut - clip.start >= frame - 1e-9, clip.end - cut >= frame - 1e-9 else { return nil }
        var next = clips
        next.replaceSubrange(i...i, with: [Clip(start: clip.start, end: cut), Clip(start: cut, end: clip.end)])
        return ClipTimeline(next, like: self)
    }

    /// Without clip `index`. Nil for the last clip left, since a video needs at least one.
    public func deleting(_ index: Int) -> ClipTimeline? {
        guard clips.count > 1, clips.indices.contains(index) else { return nil }
        var next = clips
        next.remove(at: index)
        return ClipTimeline(next, like: self)
    }

    /// Clip `index` with `edge` moved to the source frame nearest `source`. An edge stops a frame from the clip's other edge and at
    /// its neighbour or the source's end, so trimming out can only bring back what was cut, never repeat what another clip shows.
    public func trimming(_ index: Int, _ edge: Edge, to source: Double) -> ClipTimeline {
        guard clips.indices.contains(index) else { return self }
        var clip = clips[index]
        switch edge {
        case .start:
            let lowest = index > 0 ? clips[index - 1].end : 0
            clip.start = min(max(snap(source), lowest), clip.end - frame)
            clip.start = max(clip.start, lowest)
        case .end:
            let highest = index < clips.count - 1 ? clips[index + 1].start : sourceDuration
            // The source's end may sit between grid points; past the last one below it, the edge lands on the end itself.
            let end = snap(source) > highest - 1e-9 ? highest : snap(source)
            clip.end = max(min(end, highest), clip.start + frame)
            clip.end = min(clip.end, highest)
        }
        var next = clips
        next[index] = clip
        return ClipTimeline(next, like: self)
    }

    func snap(_ s: Double) -> Double { (s * fps).rounded() / fps }
}

extension RecordingProject {
    /// The clips as the finished video plays them.
    public var timeline: ClipTimeline { ClipTimeline(clips: edits.clips, source: source) }
    /// The finished video's length: what the clips keep of the recording.
    public var outputDuration: Double { timeline.duration }
}
