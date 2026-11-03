import AppKit
import ImageIO
import KadrajCore

struct HistorySection: Equatable {
    let title: String
    let records: [CaptureRecord]
}

enum HistoryGrouping {
    /// `records` newest first. Groups: Today, Yesterday, Previous 7 Days, Earlier.
    static func sections(_ records: [CaptureRecord], now: Date, calendar: Calendar = .current) -> [HistorySection] {
        let startOfToday = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday)!
        let weekAgo = calendar.date(byAdding: .day, value: -7, to: startOfToday)!
        let buckets: [(String, (Date) -> Bool)] = [
            ("Today", { $0 >= startOfToday }),
            ("Yesterday", { $0 >= yesterday && $0 < startOfToday }),
            ("Previous 7 Days", { $0 >= weekAgo && $0 < yesterday }),
            ("Earlier", { $0 < weekAgo }),
        ]
        return buckets.compactMap { title, matches in
            let hit = records.filter { matches($0.createdAt) }
            return hit.isEmpty ? nil : HistorySection(title: title, records: hit)
        }
    }
}

enum HistoryFilter: Int, CaseIterable {
    case all, area, window, fullscreen, scrolling, timed, imported

    var title: String {
        switch self {
        case .all: return "All"
        case .area: return "Area"
        case .window: return "Window"
        case .fullscreen: return "Fullscreen"
        case .scrolling: return "Scrolling"
        case .timed: return "Timer"
        case .imported: return "Imported"
        }
    }

    var kinds: Set<CaptureKind>? {
        switch self {
        case .all: return nil
        case .area: return [.area]
        case .window: return [.window]
        case .fullscreen: return [.fullscreen]
        case .scrolling: return [.scrolling]
        case .timed: return [.timed]
        case .imported: return [.imported]
        }
    }
}

extension CaptureKind {
    var title: String {
        switch self {
        case .area: return "Area"
        case .window: return "Window"
        case .fullscreen: return "Fullscreen"
        case .scrolling: return "Scrolling"
        case .timed: return "Timer"
        case .imported: return "Imported"
        }
    }
}

/// Decodes only the pixels a thumbnail needs, on a background queue, and remembers the result.
final class ThumbnailCache: @unchecked Sendable {
    private final class Box: NSObject {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }

    private let cache = NSCache<NSString, Box>()
    private let queue = DispatchQueue(label: "kadraj.thumbnails", qos: .userInitiated, attributes: .concurrent)
    private let lock = NSLock()
    private var offMain = 0
    private var onMain = 0

    init() { cache.countLimit = 600 }

    var generationsOffMainThread: Int { lock.withLock { offMain } }
    var generationsOnMainThread: Int { lock.withLock { onMain } }

    private func key(_ id: UUID, _ maxPixel: Int) -> NSString { "\(id.uuidString)-\(maxPixel)" as NSString }

    func cached(_ id: UUID, maxPixel: Int) -> CGImage? { cache.object(forKey: key(id, maxPixel))?.image }

    func invalidate(_ id: UUID, maxPixel: Int) { cache.removeObject(forKey: key(id, maxPixel)) }

    func load(id: UUID, file: URL, maxPixel: Int, completion: @escaping @MainActor (CGImage?) -> Void) {
        if let hit = cached(id, maxPixel: maxPixel) {
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(hit) } }
            return
        }
        queue.async { [self] in
            lock.withLock { if Thread.isMainThread { onMain += 1 } else { offMain += 1 } }
            let image = Self.decode(file, maxPixel: maxPixel)
            if let image { cache.setObject(Box(image), forKey: key(id, maxPixel)) }
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(image) } }
        }
    }

    static func decode(_ file: URL, maxPixel: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
