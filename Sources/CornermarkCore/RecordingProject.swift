import CoreGraphics
import Foundation

/// Where the pointer was, in points of the recorded area with the origin at its top-left corner.
/// `t` is seconds on the video's own timeline, so `t == 0` is the first frame.
public struct PointerSample: Codable, Equatable, Sendable {
    public var t: Double
    public var x: Double
    public var y: Double
    public init(t: Double, x: Double, y: Double) { self.t = t; self.x = x; self.y = y }
}

/// How the pointer is drawn over the recording. The recording itself never contains a pointer.
public struct CursorSettings: Codable, Equatable, Sendable {
    public static let scaleRange = 0.25...8.0
    public var isVisible: Bool
    /// 1 is the system pointer's size.
    public var scale: Double
    public var style: CursorStyle
    public var motion: CursorMotion
    /// Fades the pointer out once it has been still for `CursorTrack.idleDelay`.
    public var hidesWhenIdle: Bool
    /// Fades the pointer out at a key press without Command or Control, until it next moves.
    public var hidesWhenTyping: Bool

    public init(isVisible: Bool = true, scale: Double = 1, style: CursorStyle = .white, motion: CursorMotion = .natural,
                hidesWhenIdle: Bool = false, hidesWhenTyping: Bool = false) {
        self.isVisible = isVisible; self.scale = scale; self.style = style; self.motion = motion
        self.hidesWhenIdle = hidesWhenIdle; self.hidesWhenTyping = hidesWhenTyping
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let d = CursorSettings()
        isVisible = try c.decodeIfPresent(Bool.self, forKey: .isVisible) ?? d.isVisible
        scale = try c.decodeIfPresent(Double.self, forKey: .scale) ?? d.scale
        style = (try? c.decodeIfPresent(CursorStyle.self, forKey: .style)) ?? d.style
        motion = (try? c.decodeIfPresent(CursorMotion.self, forKey: .motion)) ?? d.motion
        hidesWhenIdle = (try? c.decodeIfPresent(Bool.self, forKey: .hidesWhenIdle)) ?? d.hidesWhenIdle
        hidesWhenTyping = (try? c.decodeIfPresent(Bool.self, forKey: .hidesWhenTyping)) ?? d.hidesWhenTyping
    }
    private enum Keys: String, CodingKey { case isVisible, scale, style, motion, hidesWhenIdle, hidesWhenTyping }
}

/// A recording and everything that can still change about it. The source video is written once and never touched again,
/// so every edit lives here. Later steps add their own fields; a field that is missing decodes to its default.
public struct RecordingProject: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public struct Source: Codable, Equatable, Sendable {
        /// File name inside the project folder.
        public var video: String
        public var pixelWidth: Int
        public var pixelHeight: Int
        /// The size of the recorded area in points, which is the unit of every pointer sample.
        public var pointWidth: Double
        public var pointHeight: Double
        public var fps: Int
        /// Seconds from the first frame to the end of the last one.
        public var duration: Double
        /// File names inside the project folder of the sound tracks, each as long as the video and on its timeline. Nil when not recorded.
        public var microphone: String?
        public var systemAudio: String?
        /// The camera's file inside the project folder, on the same timeline as `video`. Nil when the camera was off.
        public var camera: String?

        public init(video: String = RecordingProjectFile.videoName, pixelWidth: Int = 0, pixelHeight: Int = 0,
                    pointWidth: Double = 0, pointHeight: Double = 0, fps: Int = 60, duration: Double = 0,
                    microphone: String? = nil, systemAudio: String? = nil, camera: String? = nil) {
            self.video = video; self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight
            self.pointWidth = pointWidth; self.pointHeight = pointHeight; self.fps = fps; self.duration = duration
            self.microphone = microphone; self.systemAudio = systemAudio; self.camera = camera
        }

        /// The sound tracks there are, microphone first.
        public var audioFiles: [String] { [microphone, systemAudio].compactMap { $0 } }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            video = try c.decodeIfPresent(String.self, forKey: .video) ?? RecordingProjectFile.videoName
            pixelWidth = try c.decodeIfPresent(Int.self, forKey: .pixelWidth) ?? 0
            pixelHeight = try c.decodeIfPresent(Int.self, forKey: .pixelHeight) ?? 0
            pointWidth = try c.decodeIfPresent(Double.self, forKey: .pointWidth) ?? 0
            pointHeight = try c.decodeIfPresent(Double.self, forKey: .pointHeight) ?? 0
            fps = try c.decodeIfPresent(Int.self, forKey: .fps) ?? 60
            duration = try c.decodeIfPresent(Double.self, forKey: .duration) ?? 0
            microphone = try? c.decodeIfPresent(String.self, forKey: .microphone)
            systemAudio = try? c.decodeIfPresent(String.self, forKey: .systemAudio)
            camera = (try? c.decodeIfPresent(String.self, forKey: .camera)) ?? nil
        }
        private enum Keys: String, CodingKey { case video, pixelWidth, pixelHeight, pointWidth, pointHeight, fps, duration, microphone, systemAudio, camera }
    }

    /// What happened while recording, on the video's timeline.
    public struct Events: Codable, Equatable, Sendable {
        /// Sorted by `t`.
        public var pointer: [PointerSample]
        public var clicks: [ClickEvent]
        public var keys: [KeyEvent]

        public init(pointer: [PointerSample] = [], clicks: [ClickEvent] = [], keys: [KeyEvent] = []) {
            self.pointer = pointer.sorted { $0.t < $1.t }
            self.clicks = clicks.sorted { $0.t < $1.t }
            self.keys = keys.sorted { $0.t < $1.t }
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            func lossy<T: Decodable>(_ key: Keys) -> [T] { ((try? c.decodeIfPresent([Lossy<T>].self, forKey: key)) ?? nil)?.compactMap(\.value) ?? [] }
            pointer = (lossy(.pointer) as [PointerSample]).sorted { $0.t < $1.t }
            clicks = (lossy(.clicks) as [ClickEvent]).sorted { $0.t < $1.t }
            keys = (lossy(.keys) as [KeyEvent]).sorted { $0.t < $1.t }
        }
        private enum Keys: String, CodingKey { case pointer, clicks, keys }
    }

    /// What the viewer chose, applied when a frame is drawn.
    public struct Edits: Codable, Equatable, Sendable {
        public var cursor: CursorSettings
        public var clicks: ClickHighlight
        public var keystrokes: KeystrokeDisplay
        /// What the finished video keeps of the recording, in order. A project read from a file always has at least one;
        /// one written before clips existed keeps the whole recording.
        public var clips: [Clip]
        /// Ordered and apart, on the finished video's timeline.
        public var zooms: [Zoom]
        public var background: VideoBackground
        public var camera: CameraBubble

        public init(cursor: CursorSettings = CursorSettings(), clicks: ClickHighlight = ClickHighlight(), keystrokes: KeystrokeDisplay = KeystrokeDisplay(),
                    clips: [Clip] = [], zooms: [Zoom] = [], background: VideoBackground = VideoBackground(), camera: CameraBubble = CameraBubble()) {
            self.cursor = cursor; self.clicks = clicks; self.keystrokes = keystrokes; self.clips = clips; self.zooms = zooms.sorted { $0.start < $1.start }
            self.background = background; self.camera = camera
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            cursor = try c.decodeIfPresent(CursorSettings.self, forKey: .cursor) ?? CursorSettings()
            clicks = (try? c.decodeIfPresent(ClickHighlight.self, forKey: .clicks)) ?? ClickHighlight()
            keystrokes = (try? c.decodeIfPresent(KeystrokeDisplay.self, forKey: .keystrokes)) ?? KeystrokeDisplay()
            camera = (try? c.decodeIfPresent(CameraBubble.self, forKey: .camera)) ?? CameraBubble()
            clips = try c.decodeIfPresent([Lossy<Clip>].self, forKey: .clips)?.compactMap(\.value) ?? []
            zooms = (((try? c.decodeIfPresent([Lossy<Zoom>].self, forKey: .zooms)) ?? nil)?.compactMap(\.value) ?? []).sorted { $0.start < $1.start }
            background = (try? c.decodeIfPresent(VideoBackground.self, forKey: .background)) ?? VideoBackground()
        }
        private enum Keys: String, CodingKey { case cursor, clicks, keystrokes, clips, zooms, background, camera }
    }

    public var version: Int
    public var source: Source
    public var events: Events
    public var edits: Edits

    public init(source: Source = Source(), events: Events = Events(), edits: Edits = Edits()) {
        self.version = Self.currentVersion; self.source = source; self.events = events; self.edits = edits
        self.edits.clips = timeline.clips
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? Self.currentVersion
        source = try c.decodeIfPresent(Source.self, forKey: .source) ?? Source()
        events = try c.decodeIfPresent(Events.self, forKey: .events) ?? Events()
        edits = try c.decodeIfPresent(Edits.self, forKey: .edits) ?? Edits()
        edits.clips = timeline.clips
    }
    private enum Keys: String, CodingKey { case version, source, events, edits }
}

/// Decodes to nil instead of failing the whole array, so one damaged entry costs one entry.
private struct Lossy<Value: Decodable>: Decodable {
    let value: Value?
    init(from decoder: Decoder) throws { value = try? Value(from: decoder) }
}

/// A recording's folder: the source video next to the project JSON.
public enum RecordingProjectFile {
    public static let videoName = "screen.mp4"
    public static let microphoneName = "mic.m4a"
    public static let systemAudioName = "system.m4a"
    public static let projectName = "project.json"
    public static let cameraName = "camera.mp4"

    public static func write(_ project: RecordingProject, to folder: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(project).write(to: folder.appendingPathComponent(projectName), options: .atomic)
    }

    public static func read(from folder: URL) throws -> RecordingProject {
        try JSONDecoder().decode(RecordingProject.self, from: Data(contentsOf: folder.appendingPathComponent(projectName)))
    }
}

/// The pointer's look at one instant.
public struct CursorFrame: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var scale: Double
    public var style: CursorStyle
    /// Above 0: a pointer faded all the way out is no pointer.
    public var opacity: Double

    public init(x: Double, y: Double, scale: Double, style: CursorStyle = .white, opacity: Double = 1) {
        self.x = x; self.y = y; self.scale = scale; self.style = style; self.opacity = opacity
    }
}

/// Everything a renderer needs to draw one output frame. Preview and export both ask for it, so they cannot disagree.
public struct FrameState: Equatable, Sendable {
    /// The moment of the source video to show.
    public var sourceTime: Double
    /// Nil when the viewer hid the pointer or the recording has none.
    public var cursor: CursorFrame?
    /// The part of the recorded area the picture shows. The pointer is placed in the recording's points, so it moves with the picture.
    /// The camera bubble is a separate overlay and ignores it.
    public var crop: ZoomRect = .full
    /// Where the camera goes. Its picture is the camera file at `sourceTime`. Nil when the recording has no camera or the viewer hid it.
    public var camera: CameraFrame?

    public init(sourceTime: Double, cursor: CursorFrame? = nil, camera: CameraFrame? = nil, crop: ZoomRect = .full) {
        self.sourceTime = sourceTime; self.cursor = cursor; self.camera = camera; self.crop = crop
    }
}

/// The frame at `outputTime` seconds of the finished video. Pure: the same project and time always give the same answer.
public func frameState(_ project: RecordingProject, outputTime: Double) -> FrameState {
    let sourceTime = project.timeline.sourceTime(at: outputTime)
    let area = CGSize(width: project.source.pointWidth, height: project.source.pointHeight)
    let camera = project.source.camera == nil ? nil : CameraLayout.frame(project.edits.camera, area: area, at: sourceTime)
    // Zooms sit on the finished video's timeline, so the crop follows output time after clips have mapped it to the source.
    let crop = ZoomCamera.rect(project.edits.zooms, at: outputTime)
    return FrameState(sourceTime: sourceTime, cursor: CursorTrack.frame(project, at: sourceTime), camera: camera, crop: crop)
}

public enum PointerTrack {
    /// Straight lines between samples. Before the first sample the pointer waits there, and after the last it stays.
    public static func position(_ samples: [PointerSample], at t: Double) -> (x: Double, y: Double)? {
        guard let first = samples.first, let last = samples.last else { return nil }
        if t <= first.t { return (first.x, first.y) }
        if t >= last.t { return (last.x, last.y) }
        var low = 0, high = samples.count - 1
        while high - low > 1 {
            let mid = (low + high) / 2
            if samples[mid].t <= t { low = mid } else { high = mid }
        }
        let a = samples[low], b = samples[high]
        let f = b.t > a.t ? (t - a.t) / (b.t - a.t) : 1
        return (a.x + (b.x - a.x) * f, a.y + (b.y - a.y) * f)
    }
}

/// Collects raw readings from a clock that is not the video's, then puts them on the video's timeline.
public struct PointerTrackBuilder {
    private struct Reading { var time: Double; var x: Double; var y: Double }
    private var kept: [Reading] = []
    /// The latest reading that repeated the last kept position. A run of equal positions keeps its first and last reading only,
    /// because the straight line between them is the same still pointer.
    private var pendingStill: Reading?

    public init() {}

    public mutating func add(time: Double, x: Double, y: Double) {
        let reading = Reading(time: time, x: x, y: y)
        if let last = kept.last, last.x == x, last.y == y {
            pendingStill = reading
            return
        }
        if let pending = pendingStill { kept.append(pending); pendingStill = nil }
        kept.append(reading)
    }

    /// Times become seconds after `firstFrameTime`. Readings before the first frame collapse to the one nearest it, and readings after
    /// `lastTime` to the one nearest it, so a long wait around the recording does not grow the file.
    public func samples(firstFrameTime: Double, lastTime: Double) -> [PointerSample] {
        var all = kept
        if let pending = pendingStill { all.append(pending) }
        let startIndex = all.lastIndex { $0.time <= firstFrameTime } ?? 0
        let endIndex = all.firstIndex { $0.time >= lastTime } ?? max(all.count - 1, 0)
        guard !all.isEmpty, startIndex <= endIndex else { return [] }
        return all[startIndex...endIndex].map { PointerSample(t: $0.time - firstFrameTime, x: $0.x, y: $0.y) }
    }
}
