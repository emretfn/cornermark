import CoreGraphics
import Foundation
import ImageIO

public enum CaptureStoreError: Error, Equatable {
    case encodingFailed
    case unknownRecord(UUID)
}

public struct CaptureFilter: Sendable {
    public var kinds: Set<CaptureKind>?
    /// True keeps only recordings, false only pictures, nil both.
    public var recordings: Bool?
    public var createdAfter: Date?
    public var createdBefore: Date?
    public var limit: Int?
    public init(kinds: Set<CaptureKind>? = nil, recordings: Bool? = nil, createdAfter: Date? = nil, createdBefore: Date? = nil, limit: Int? = nil) {
        self.kinds = kinds; self.recordings = recordings; self.createdAfter = createdAfter; self.createdBefore = createdBefore; self.limit = limit
    }
    public static let all = CaptureFilter()
}

public struct CapturePaths: Sendable, Hashable {
    public let directory: URL
    public let image: URL
    /// Exists only once the capture has been edited and saved.
    public let project: URL
    public let assets: URL
}

/// On-disk capture history: `<root>/index.json` plus one directory per capture.
public final class CaptureStore: @unchecked Sendable {
    public static let defaultRetention: TimeInterval = 30 * 24 * 60 * 60
    public static let imageFileName = "image.png"

    private struct Index: Codable {
        var version = 1
        var records: [CaptureRecord]
    }

    public let root: URL
    private let lock = NSLock()
    private var records: [CaptureRecord] = []
    private var indexURL: URL { root.appendingPathComponent("index.json") }

    public init(root: URL) throws {
        self.root = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        records = try loadIndex()
    }

    @discardableResult
    public func add(_ image: CGImage, kind: CaptureKind, pointScale: Double = 1, now: Date = Date()) throws -> CaptureRecord {
        try add(image, kind: kind, pointScale: pointScale, video: nil, now: now)
    }

    /// Lists a finished recording. `poster` is the frame history shows for it, and the recording itself stays at `video.location`.
    @discardableResult
    public func addRecording(_ video: RecordedVideo, poster: CGImage, kind: CaptureKind, pixelSize: CGSize, now: Date = Date()) throws -> CaptureRecord {
        try add(poster, kind: kind, pointScale: 1, video: video, pixelSize: pixelSize, now: now)
    }

    private func add(_ image: CGImage, kind: CaptureKind, pointScale: Double, video: RecordedVideo?, pixelSize: CGSize? = nil, now: Date) throws -> CaptureRecord {
        guard let png = AssetStore.pngData(from: image) else { throw CaptureStoreError.encodingFailed }
        let id = UUID()
        let record = CaptureRecord(id: id, createdAt: now, kind: kind,
                                   pixelSize: pixelSize ?? CGSize(width: image.width, height: image.height),
                                   directoryName: Self.directoryName(for: now, id: id), pointScale: pointScale, video: video)
        let dir = root.appendingPathComponent(record.directoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        do {
            try png.write(to: dir.appendingPathComponent(Self.imageFileName), options: .atomic)
            try lock.withLock {
                records.append(record)
                do { try saveIndex() } catch { records.removeLast(); throw error }
            }
        } catch {
            try? FileManager.default.removeItem(at: dir)
            throw error
        }
        return record
    }

    /// Newest first.
    public func list(filter: CaptureFilter = .all) -> [CaptureRecord] {
        var out = lock.withLock { records }.filter { r in
            (filter.kinds?.contains(r.kind) ?? true)
                && (filter.recordings.map { r.isRecording == $0 } ?? true)
                && (filter.createdAfter.map { r.createdAt >= $0 } ?? true)
                && (filter.createdBefore.map { r.createdAt < $0 } ?? true)
        }
        out.sort { $0.createdAt > $1.createdAt }
        if let limit = filter.limit { out = Array(out.prefix(max(limit, 0))) }
        return out
    }

    public func record(id: UUID) -> CaptureRecord? { lock.withLock { records.first { $0.id == id } } }

    public func delete(_ id: UUID) throws {
        let removed: CaptureRecord = try lock.withLock {
            guard let i = records.firstIndex(where: { $0.id == id }) else { throw CaptureStoreError.unknownRecord(id) }
            let record = records.remove(at: i)
            do { try saveIndex() } catch { records.insert(record, at: i); throw error }
            return record
        }
        try? FileManager.default.removeItem(at: paths(for: removed).directory)
    }

    /// Removes captures created before `now - age` and returns them. A recording loses its history entry, never its video.
    @discardableResult
    public func prune(olderThan age: TimeInterval = CaptureStore.defaultRetention, now: Date = Date()) throws -> [CaptureRecord] {
        let cutoff = now.addingTimeInterval(-age)
        let removed: [CaptureRecord] = try lock.withLock {
            let old = records.filter { $0.createdAt < cutoff }
            guard !old.isEmpty else { return [] }
            let before = records
            records.removeAll { $0.createdAt < cutoff }
            do { try saveIndex() } catch { records = before; throw error }
            return old
        }
        for r in removed { try? FileManager.default.removeItem(at: paths(for: r).directory) }
        return removed
    }

    /// Locations needed to reopen a capture. The directory name comes from index.json, so only its
    /// last component is trusted.
    public func paths(for record: CaptureRecord) -> CapturePaths {
        let name = (record.directoryName as NSString).lastPathComponent
        let dir = root.appendingPathComponent(name.isEmpty || name == ".." ? "_invalid" : name, isDirectory: true)
        return CapturePaths(directory: dir,
                            image: dir.appendingPathComponent(Self.imageFileName),
                            project: dir.appendingPathComponent(ProjectFile.documentFileName),
                            assets: dir.appendingPathComponent(ProjectFile.assetsDirectoryName, isDirectory: true))
    }

    public func hasProject(_ record: CaptureRecord) -> Bool {
        FileManager.default.fileExists(atPath: paths(for: record).project.path)
    }

    /// The saved edit if there is one, otherwise a fresh document around the original image.
    public func openDocument(for record: CaptureRecord) throws -> (document: Document, assets: AssetStore) {
        let p = paths(for: record)
        if hasProject(record) { return try ProjectFile.read(from: p.directory) }
        let png = try Data(contentsOf: p.image)
        let store = AssetStore()
        let base = store.add(png: png)
        return (Document(base: base, pixelSize: record.pixelSize, pointScale: record.pointScale), store)
    }

    public func saveDocument(_ doc: Document, assets: AssetStore, for record: CaptureRecord) throws {
        try ProjectFile.write(doc, assets: assets, to: paths(for: record).directory)
    }

    // MARK: Index

    private func saveIndex() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(Index(records: records)).write(to: indexURL, options: .atomic)
    }

    private func loadIndex() throws -> [CaptureRecord] {
        guard FileManager.default.fileExists(atPath: indexURL.path) else { return try rebuildIfDirectoriesExist() }
        do {
            return try JSONDecoder().decode(Index.self, from: Data(contentsOf: indexURL)).records
        } catch {
            let aside = root.appendingPathComponent("index.corrupt-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: indexURL, to: aside)
            return try rebuildIfDirectoriesExist()
        }
    }

    /// Recovers history from the capture folders when index.json is missing or unreadable.
    /// Original kind and time are lost; the folder's creation date stands in.
    private func rebuildIfDirectoriesExist() throws -> [CaptureRecord] {
        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.creationDateKey, .isDirectoryKey])) ?? []
        var found: [CaptureRecord] = []
        for dir in entries {
            let image = dir.appendingPathComponent(Self.imageFileName)
            guard fm.fileExists(atPath: image.path),
                  let source = CGImageSourceCreateWithURL(image as CFURL, nil),
                  let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let w = props[kCGImagePropertyPixelWidth] as? Double, let h = props[kCGImagePropertyPixelHeight] as? Double
            else { continue }
            let created = (try? dir.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
            found.append(CaptureRecord(createdAt: created, kind: .imported, pixelSize: CGSize(width: w, height: h),
                                       directoryName: dir.lastPathComponent))
        }
        guard !found.isEmpty else { return [] }
        records = found
        try saveIndex()
        return found
    }

    private static func directoryName(for date: Date, id: UUID) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd_HHmmss"
        return "\(f.string(from: date))_\(id.uuidString.prefix(8))"
    }
}
