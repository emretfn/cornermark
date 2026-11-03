import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ExportFormat: String, CaseIterable, Sendable {
    case png, jpeg, heic, tiff

    public var utType: UTType {
        switch self {
        case .png: return .png
        case .jpeg: return .jpeg
        case .heic: return .heic
        case .tiff: return .tiff
        }
    }

    public var fileExtension: String { self == .jpeg ? "jpg" : rawValue }
    var supportsAlpha: Bool { self == .png || self == .tiff }
}

public enum ExportError: Error, Equatable {
    case encodingFailed(ExportFormat)
}

public enum Exporter {
    /// Pixels per inch such that the image keeps the physical size of the capture:
    /// `pointScale` pixels per point, shrunk or grown by the output scale.
    public static func dpi(for doc: Document) -> Double {
        72 * doc.pointScale * min(max(doc.outputScale, Document.outputScaleRange.lowerBound), Document.outputScaleRange.upperBound)
    }

    public static func data(from image: CGImage, format: ExportFormat, quality: Double = 0.9, dpi: Double = 72) throws -> Data {
        let source = format.supportsAlpha ? image : flattenedOnWhite(image)
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, format.utType.identifier as CFString, 1, nil) else {
            throw ExportError.encodingFailed(format)
        }
        var props: [CFString: Any] = [
            kCGImagePropertyDPIWidth: dpi,
            kCGImagePropertyDPIHeight: dpi,
        ]
        if format == .jpeg || format == .heic {
            props[kCGImageDestinationLossyCompressionQuality] = min(max(quality, 0), 1)
        }
        CGImageDestinationAddImage(dest, source, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ExportError.encodingFailed(format) }
        return out as Data
    }

    public static func data(for doc: Document, assets: AssetStore, format: ExportFormat, quality: Double = 0.9) throws -> Data {
        try data(from: Renderer.render(doc, assets: assets), format: format, quality: quality, dpi: dpi(for: doc))
    }

    public static func export(_ doc: Document, assets: AssetStore, format: ExportFormat, quality: Double = 0.9, to url: URL) throws {
        try data(for: doc, assets: assets, format: format, quality: quality).write(to: url, options: .atomic)
    }

    private static func flattenedOnWhite(_ image: CGImage) -> CGImage {
        guard let ctx = Bitmap.makeContext(width: image.width, height: image.height, yDown: false) else { return image }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx.makeImage() ?? image
    }
}
