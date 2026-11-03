import CoreGraphics
import Foundation

public struct RGBA: Codable, Hashable, Sendable {
    public var r, g, b, a: Double
    public init(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }
    public var cgColor: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
}

public enum ArrowStyle: String, Codable, CaseIterable, Sendable { case classic, tapered, outline, curved }
public enum BlurMode: String, Codable, CaseIterable, Sendable { case smooth, secure }
public enum TextStylePreset: String, Codable, CaseIterable, Sendable {
    case plain, bold, outlined, pill, banner, shadowed, mono
}

public struct Stroke: Codable, Hashable, Sendable {
    public var color: RGBA
    public var width: Double
    public init(color: RGBA, width: Double) { self.color = color; self.width = width }
}

/// Every drawable mark. All geometry is in source image pixels, y-down, so crop, rotate and
/// export never have to rewrite annotations.
public enum AnnotationKind: Codable, Hashable, Sendable {
    case arrow(from: CGPoint, to: CGPoint, control: CGPoint?, style: ArrowStyle)
    case line(from: CGPoint, to: CGPoint)
    case rect(CGRect, filled: Bool, cornerRadius: Double)
    case ellipse(CGRect, filled: Bool)
    case text(origin: CGPoint, string: String, fontSize: Double, style: TextStylePreset)
    case counter(center: CGPoint, number: Int, radius: Double)
    case pencil(points: [CGPoint])
    case highlighter(points: [CGPoint])
    case blur(CGRect, mode: BlurMode)
    case pixelate(CGRect, blockSize: Int, seed: UInt64)
    case spotlight(CGRect)
    case image(CGRect, asset: AssetID)
}

public struct Annotation: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var kind: AnnotationKind
    public var stroke: Stroke
    public init(id: UUID = UUID(), kind: AnnotationKind, stroke: Stroke) {
        self.id = id; self.kind = kind; self.stroke = stroke
    }
}

public typealias AssetID = String

public struct Geometry: Codable, Hashable, Sendable {
    public var quarterTurns: Int = 0   // clockwise, 0...3
    public var flipH = false
    public var flipV = false
    public init() {}
}

public enum BackgroundFill: Codable, Hashable, Sendable {
    case none
    case solid(RGBA)
    case gradient(RGBA, RGBA, angleDegrees: Double)
    case image(asset: AssetID)
    case builtin(index: Int)   // 0..<20
}

public enum BackgroundAlignment: String, Codable, CaseIterable, Sendable {
    case center, top, bottom, left, right
}

public struct BackgroundStyle: Codable, Hashable, Sendable {
    public var fill: BackgroundFill = .builtin(index: 0)
    public var padding: Double = 64
    public var alignment: BackgroundAlignment = .center
    public var aspectRatio: Double? = nil   // width / height
    public var autoBalance = false
    public var cornerRadius: Double = 12
    public var shadow = true
    public init() {}
}

/// The whole editable state of one screenshot. A value type: undo history is a stack of these,
/// the project file is its JSON, and the renderer is a pure function of it plus the asset store.
public struct Document: Codable, Hashable, Sendable {
    public var base: AssetID
    public var pixelSize: CGSize        // source image size in pixels
    public var pointScale: Double       // pixels per point of the capture, used for export DPI
    public var crop: CGRect?            // in source pixels; nil means the full image
    public var geometry = Geometry()
    public var annotations: [Annotation] = []
    public var background: BackgroundStyle? = nil
    public var outputScale: Double = 1  // resize at export
    public init(base: AssetID, pixelSize: CGSize, pointScale: Double) {
        self.base = base; self.pixelSize = pixelSize; self.pointScale = pointScale
    }
}

/// All edits go through this. The editor UI never mutates a Document directly.
public enum EditCommand: Hashable, Sendable {
    case add(Annotation)
    case update(Annotation)
    case remove(UUID)
    case reorder(UUID, toIndex: Int)
    case setCrop(CGRect?)
    case rotateClockwise
    case flipHorizontal
    case flipVertical
    case setOutputScale(Double)
    case setBackground(BackgroundStyle?)
}

public enum CaptureKind: String, Codable, CaseIterable, Sendable {
    case area, window, fullscreen, scrolling, timed, imported
}

/// One entry in capture history. `directory` holds image.png and, once edited, project.json plus assets.
public struct CaptureRecord: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var createdAt: Date
    public var kind: CaptureKind
    public var pixelSize: CGSize
    public var directoryName: String
    public var pointScale: Double = 1
    public init(id: UUID = UUID(), createdAt: Date = Date(), kind: CaptureKind, pixelSize: CGSize, directoryName: String, pointScale: Double = 1) {
        self.id = id; self.createdAt = createdAt; self.kind = kind; self.pixelSize = pixelSize; self.directoryName = directoryName
        self.pointScale = pointScale
    }
}
