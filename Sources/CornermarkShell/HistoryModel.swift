import AppKit
import ImageIO
import CornermarkCore
import CornermarkL10n

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
            (tr("Today"), { $0 >= startOfToday }),
            (tr("Yesterday"), { $0 >= yesterday && $0 < startOfToday }),
            (tr("Previous 7 Days"), { $0 >= weekAgo && $0 < yesterday }),
            (tr("Earlier"), { $0 < weekAgo }),
        ]
        return buckets.compactMap { title, matches in
            let hit = records.filter { matches($0.createdAt) }
            return hit.isEmpty ? nil : HistorySection(title: title, records: hit)
        }
    }
}

enum HistoryFilter: Int, CaseIterable {
    case all, area, window, fullscreen, scrolling, timed, imported, recordings

    var title: String {
        switch self {
        case .all: return tr("All")
        case .area: return tr("Area")
        case .window: return tr("Window")
        case .fullscreen: return tr("Fullscreen")
        case .scrolling: return tr("Scrolling")
        case .timed: return tr("Timer")
        case .imported: return tr("Imported")
        case .recordings: return tr("Recordings")
        }
    }

    /// The kind filters list pictures. Recordings have their own filter, whatever they filmed.
    var captureFilter: CaptureFilter {
        switch self {
        case .all: return CaptureFilter()
        case .area: return CaptureFilter(kinds: [.area], recordings: false)
        case .window: return CaptureFilter(kinds: [.window], recordings: false)
        case .fullscreen: return CaptureFilter(kinds: [.fullscreen], recordings: false)
        case .scrolling: return CaptureFilter(kinds: [.scrolling], recordings: false)
        case .timed: return CaptureFilter(kinds: [.timed], recordings: false)
        case .imported: return CaptureFilter(kinds: [.imported], recordings: false)
        case .recordings: return CaptureFilter(recordings: true)
        }
    }
}

extension CaptureKind {
    var title: String {
        switch self {
        case .area: return tr("Area")
        case .window: return tr("Window")
        case .fullscreen: return tr("Fullscreen")
        case .scrolling: return tr("Scrolling")
        case .timed: return tr("Timer")
        case .imported: return tr("Imported")
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
    private let queue = DispatchQueue(label: "cornermark.thumbnails", qos: .userInitiated, attributes: .concurrent)
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
