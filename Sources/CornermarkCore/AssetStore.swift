import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// AssetID to encoded image bytes (PNG), with a decode cache. Thread-safe so the renderer can be
/// driven from a background queue while the editor adds assets.
public final class AssetStore: @unchecked Sendable {
    private let lock = NSLock()
    private var blobs: [AssetID: Data]
    private var decoded: [AssetID: CGImage] = [:]
    private var marginCache: [String: CGRect] = [:]

    public init(_ blobs: [AssetID: Data] = [:]) { self.blobs = blobs }

    public var ids: [AssetID] { lock.withLock { Array(blobs.keys).sorted() } }
    public var snapshot: [AssetID: Data] { lock.withLock { blobs } }
    public func contains(_ id: AssetID) -> Bool { lock.withLock { blobs[id] != nil } }
    public func data(for id: AssetID) -> Data? { lock.withLock { blobs[id] } }

    public func image(for id: AssetID) -> CGImage? {
        let (cached, data) = lock.withLock { (decoded[id], blobs[id]) }
        if let cached { return cached }
        guard let data, let image = Self.decode(data) else { return nil }
        return lock.withLock {
            if let existing = decoded[id] { return existing }
            decoded[id] = image
            return image
        }
    }

    public func pixelSize(of id: AssetID) -> CGSize? {
        image(for: id).map { CGSize(width: $0.width, height: $0.height) }
    }

    /// Stores PNG bytes as given, byte for byte.
    @discardableResult
    public func add(png: Data, id: AssetID = UUID().uuidString) -> AssetID {
        lock.withLock {
            blobs[id] = png
            decoded[id] = nil
            marginCache.removeAll()
        }
        return id
    }

    /// Accepts any ImageIO-readable bytes and stores them as PNG. PNG input is kept untouched.
    @discardableResult
    public func add(encoded data: Data, id: AssetID = UUID().uuidString) -> AssetID? {
        if Self.isPNG(data) { return add(png: data, id: id) }
        guard let image = Self.decode(data), let png = Self.pngData(from: image) else { return nil }
        return add(png: png, id: id)
    }

    @discardableResult
    public func add(image: CGImage, id: AssetID = UUID().uuidString) -> AssetID? {
        guard let png = Self.pngData(from: image) else { return nil }
        return add(png: png, id: id)
    }

    public func remove(_ id: AssetID) {
        lock.withLock {
            blobs[id] = nil
            decoded[id] = nil
            marginCache.removeAll()
        }
    }

    /// An independent store with the same bytes, for forking a session.
    public func copy() -> AssetStore { AssetStore(snapshot) }

    func cachedMargin(key: String, compute: () -> CGRect) -> CGRect {
        if let hit = lock.withLock({ marginCache[key] }) { return hit }
        let value = compute()
        lock.withLock { marginCache[key] = value }
        return value
    }

    static func isPNG(_ data: Data) -> Bool {
        data.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    }

    static func decode(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    public static func pngData(from image: CGImage) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }
}
