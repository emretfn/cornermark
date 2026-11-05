import AVFoundation
import CoreGraphics
import CornermarkCore

/// What a recording films. Areas are in global AppKit points (bottom-left origin), like every other capture rect.
public enum RecordingTarget: Equatable {
    case window(CGWindowID)
    /// A nil display means the one holding the area, else the main display. A nil area means the whole display.
    case display(CGDirectDisplayID?, area: CGRect?)
}

/// How hard the encoder works to keep detail: the average bits it spends on each pixel of each frame.
public enum VideoQuality: String, Codable, CaseIterable, Sendable {
    case high, medium, low
    public var bitsPerPixel: Double {
        switch self {
        case .high: return 0.2
        case .medium: return 0.1
        case .low: return 0.05
        }
    }
}

/// Pixels per point. Retina keeps every pixel the display has; standard records one pixel per point.
public enum PixelDensity: String, Codable, CaseIterable, Sendable { case retina, standard }

/// The largest frame a recording may have. A larger area is scaled down to fit, keeping its proportions.
public enum SizeLimit: String, Codable, CaseIterable, Sendable {
    case none, uhd, qhd, fullHD, hd
    /// The box a frame must fit, long side by short side, so a portrait area fits the same box turned.
    public var box: (long: Double, short: Double)? {
        switch self {
        case .none: return nil
        case .uhd: return (3840, 2160)
        case .qhd: return (2560, 1440)
        case .fullHD: return (1920, 1080)
        case .hd: return (1280, 720)
        }
    }
}

public struct RecordingOptions: Equatable {
    public var fps: Int
    /// A finished video carries the pointer in its picture. A project keeps it out, as its own track.
    public var showsCursor: Bool
    public var quality: VideoQuality
    public var density: PixelDensity
    public var limit: SizeLimit
    /// What a display recording leaves out. A window recording films one window and nothing over it.
    public var exclusion: ContentExclusion
    public init(fps: Int = 60, showsCursor: Bool = false, quality: VideoQuality = .high, density: PixelDensity = .retina, limit: SizeLimit = .none,
                exclusion: ContentExclusion = ContentExclusion()) {
        self.fps = fps; self.showsCursor = showsCursor; self.quality = quality; self.density = density; self.limit = limit; self.exclusion = exclusion
    }
    public static let standard = RecordingOptions()
}

/// The pixel size a source will deliver. Both sides are even, because H.264 needs it.
public struct FrameFormat: Equatable {
    public var width: Int
    public var height: Int
    public var fps: Int
    public init(width: Int, height: Int, fps: Int) {
        self.width = max(2, width & ~1); self.height = max(2, height & ~1); self.fps = max(1, fps)
    }
}

/// One finished picture. `time` is on the source's own clock, so only differences mean anything.
public struct VideoFrame {
    public let pixels: CVPixelBuffer
    public let time: CMTime
    public init(pixels: CVPixelBuffer, time: CMTime) { self.pixels = pixels; self.time = time }
}

public struct RecordingReport: Equatable {
    public var url: URL
    public var format: FrameFormat
    public var framesWritten: Int
    /// Slots at the target rate between the first and last frame that no frame filled, whether the source skipped them or the encoder was too slow.
    public var framesDropped: Int
    /// Seconds from the first to the last frame.
    public var duration: Double
    public var fileBytes: Int
    /// What the encoder was asked to average, in bits a second.
    public var bitRate: Int = 0
    /// The first frame's time on the source's own clock. Everything else the recorder noted, such as the pointer, is measured from it.
    public var firstFrameTime: Double = 0
    /// What the pictures show, in global AppKit points.
    public var area: CGRect = .zero
    /// The pointer on the video's timeline, so `t == 0` is the first frame. Empty when nothing watched the pointer.
    public var pointer: [PointerSample] = []
    /// Clicks and key presses on the video's timeline. Empty when nothing watched them.
    public var clicks: [ClickEvent] = []
    public var keys: [KeyEvent] = []
    /// The stretches a pause left out, on the source clock in seconds after the first frame.
    public var pauses: [RecordingPause] = []
    /// The camera, when one was recorded.
    public var camera: CameraTrackReport?

    public var dropRate: Double {
        let total = framesWritten + framesDropped
        return total == 0 ? 0 : Double(framesDropped) / Double(total)
    }
}

extension RecordingReport {
    /// The project that describes this recording, with every edit at its default. The video is the file the report names.
    public var project: RecordingProject {
        var project = RecordingProject(
            source: .init(video: url.lastPathComponent, pixelWidth: format.width, pixelHeight: format.height,
                          pointWidth: area.width, pointHeight: area.height, fps: format.fps,
                          duration: duration + 1.0 / Double(format.fps), camera: camera?.file?.lastPathComponent),
            events: .init(pointer: pointer, clicks: clicks, keys: keys))
        if let camera { project.edits.camera = camera.bubble }
        return project
    }
}

/// The camera beside a recording.
public struct CameraTrackReport: Equatable {
    /// The camera's own file, on the video's timeline. Nil when the camera was drawn into the picture.
    public var file: URL?
    /// Pictures the camera delivered.
    public var pictures: Int
    /// Frames the recording made from the camera's clock because the screen sent none, so a still screen still shows a moving camera.
    public var filled: Int
    /// The look at the end, with full-screen spans on the video's timeline.
    public var bubble: CameraBubble
}

/// A stretch of the source clock that a pause kept out of the video. `from` is where the video stopped and `to` where it went on.
public struct RecordingPause: Equatable, Sendable {
    public var from: Double
    public var to: Double
    public init(from: Double, to: Double) { self.from = from; self.to = to }

    /// Source times as video times: a time after a pause moves back by the pause's length, and a time inside one has no place in the video.
    public static func videoTime(_ t: Double, skipping pauses: [RecordingPause]) -> Double? {
        var shift = 0.0
        for p in pauses {
            if t >= p.to { shift += p.to - p.from } else if t > p.from { return nil }
        }
        return t - shift
    }
}

public enum RecordingError: Error, Equatable, CustomStringConvertible {
    case permissionDenied
    case windowNotFound(CGWindowID)
    case displayNotFound
    case noFrames
    case writer(String)
    case source(String)

    public var description: String {
        switch self {
        case .permissionDenied: return "permissionDenied"
        case .windowNotFound(let id): return "windowNotFound(\(id))"
        case .displayNotFound: return "displayNotFound"
        case .noFrames: return "noFrames"
        case .writer(let m): return "writer(\(m))"
        case .source(let m): return "source(\(m))"
        }
    }
}
