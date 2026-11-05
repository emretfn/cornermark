import AVFoundation
import CoreGraphics
import CornermarkCore

/// What a recording films. Areas are in global AppKit points (bottom-left origin), like every other capture rect.
public enum RecordingTarget: Equatable {
    case window(CGWindowID)
    /// A nil display means the one holding the area, else the main display. A nil area means the whole display.
    case display(CGDirectDisplayID?, area: CGRect?)
}

public struct RecordingOptions: Equatable {
    public var fps: Int
    /// A finished video carries the pointer in its picture. A project keeps it out, as its own track.
    public var showsCursor: Bool
    public init(fps: Int = 60, showsCursor: Bool = false) { self.fps = fps; self.showsCursor = showsCursor }
    public static let standard = RecordingOptions()

    public static func `for`(_ style: RecordingStyle) -> RecordingOptions {
        RecordingOptions(showsCursor: style == .video)
    }
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
    /// The first frame's time on the source's own clock. Everything else the recorder noted, such as the pointer, is measured from it.
    public var firstFrameTime: Double = 0
    /// What the pictures show, in global AppKit points.
    public var area: CGRect = .zero
    /// The pointer on the video's timeline, so `t == 0` is the first frame. Empty when nothing watched the pointer.
    public var pointer: [PointerSample] = []

    public var dropRate: Double {
        let total = framesWritten + framesDropped
        return total == 0 ? 0 : Double(framesDropped) / Double(total)
    }
}

extension RecordingReport {
    /// The project that describes this recording, with every edit at its default. The video is the file the report names.
    public var project: RecordingProject {
        RecordingProject(
            source: .init(video: url.lastPathComponent, pixelWidth: format.width, pixelHeight: format.height,
                          pointWidth: area.width, pointHeight: area.height, fps: format.fps,
                          duration: duration + 1.0 / Double(format.fps)),
            events: .init(pointer: pointer))
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
