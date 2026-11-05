import AVFoundation
import CoreGraphics

/// What a recording films. Areas are in global AppKit points (bottom-left origin), like every other capture rect.
public enum RecordingTarget: Equatable {
    case window(CGWindowID)
    /// A nil display means the one holding the area, else the main display. A nil area means the whole display.
    case display(CGDirectDisplayID?, area: CGRect?)
}

public struct RecordingOptions: Equatable {
    public var fps: Int
    public init(fps: Int = 60) { self.fps = fps }
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

    public var dropRate: Double {
        let total = framesWritten + framesDropped
        return total == 0 ? 0 : Double(framesDropped) / Double(total)
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
