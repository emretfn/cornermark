import Foundation

/// How big the exported picture is. A size is named by its short side, so 1080 means 1920 × 1080 for a wide recording
/// and 1080 × 1920 for a tall one. Export never enlarges a recording.
public enum ExportResolution: Hashable, Sendable {
    case original
    case shortSide(Int)

    public static let shortSides = [2160, 1440, 1080, 720, 480]

    public static func choices(for source: RecordingProject.Source) -> [ExportResolution] {
        let short = min(source.pixelWidth, source.pixelHeight)
        return [.original] + shortSides.filter { $0 < short }.map { .shortSide($0) }
    }
}

public enum ExportQuality: Int, CaseIterable, Sendable {
    case low, medium, high

    public var title: String {
        switch self {
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        }
    }

    var bitsPerPixel: Double {
        switch self {
        case .low: return 0.05
        case .medium: return 0.1
        case .high: return 0.2
        }
    }
}

public struct ExportSettings: Equatable, Sendable {
    public var resolution: ExportResolution
    public var quality: ExportQuality

    public init(resolution: ExportResolution = .original, quality: ExportQuality = .high) {
        self.resolution = resolution; self.quality = quality
    }
}

/// What an export will write, worked out before a frame is drawn: the picture size, the frames, the bit rate and so the size.
public struct ExportPlan: Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var fps: Int
    public var frameCount: Int
    /// Bits per second the encoder aims at on average.
    public var bitRate: Int
    public var estimatedBytes: Int64

    /// A small video still needs enough bits for one sharp frame, whatever its pixel count.
    static let minimumBitRate = 1_000_000

    /// `sourceBytes` is the size of the recording's video. The encoder spends what the picture needs, up to the bit rate, so a still
    /// screen comes out far under it whatever the quality. The recording was encoded from the same pictures, so its size says what
    /// they need; fewer pixels need fewer bits, though not in proportion, since every frame has a cost of its own. The bit rate caps
    /// the result, which is what limits a busy picture. Without `sourceBytes` the estimate is that cap.
    public init(project: RecordingProject, settings: ExportSettings, sourceBytes: Int64? = nil) {
        let source = project.source
        let w = Double(source.pixelWidth > 0 ? source.pixelWidth : Int(source.pointWidth.rounded()))
        let h = Double(source.pixelHeight > 0 ? source.pixelHeight : Int(source.pointHeight.rounded()))
        let scale: Double
        switch settings.resolution {
        case .original: scale = 1
        case .shortSide(let side): scale = min(1, Double(side) / max(min(w, h), 1))
        }
        width = Self.even(w * scale)
        height = Self.even(h * scale)
        fps = max(source.fps, 1)
        frameCount = max(1, Int((max(source.duration, 0) * Double(fps)).rounded()))
        bitRate = max(Self.minimumBitRate, Int(Double(width * height * fps) * settings.quality.bitsPerPixel))
        let ceiling = Int64((Double(bitRate) * Double(frameCount) / Double(fps) / 8).rounded())
        if let sourceBytes, sourceBytes > 0, source.duration > 0 {
            let pixels = (Double(width * height) / max(w * h, 1)).squareRoot()
            let lengths = Double(frameCount) / Double(fps) / source.duration
            estimatedBytes = min(ceiling, Int64((Double(sourceBytes) * pixels * lengths).rounded()))
        } else {
            estimatedBytes = ceiling
        }
    }

    /// The finished video's length: whole frames at `fps`, within half a frame of the project's duration.
    public var duration: Double { Double(frameCount) / Double(fps) }

    public func time(ofFrame index: Int) -> Double { Double(index) / Double(fps) }

    /// H.264 with 4:2:0 colour needs even sides.
    static func even(_ value: Double) -> Int { max(2, Int((value / 2).rounded()) * 2) }
}
