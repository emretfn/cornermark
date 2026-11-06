import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// How a video becomes a GIF. The defaults keep a screen recording readable at a size a chat or an issue tracker takes. Every GIF loops forever.
public struct GifOptions: Equatable, Sendable {
    /// Pictures a second. GIF delays are whole hundredths, so the rate is kept between 1 and 50.
    public var fps: Int
    /// The longest side in pixels. A smaller video keeps its size.
    public var maxPixel: Int
    public init(fps: Int = 15, maxPixel: Int = 960) {
        self.fps = min(max(fps, 1), 50); self.maxPixel = max(16, maxPixel)
    }
    public static let standard = GifOptions()
}

public struct GifReport: Equatable, Sendable {
    public var url: URL
    public var width: Int
    public var height: Int
    public var frames: Int
    /// The sum of the frame delays.
    public var duration: Double
    public var bytes: Int
}

public enum GifError: Error, Equatable, CustomStringConvertible {
    case unreadable(String)
    case encoder(String)

    public var description: String {
        switch self {
        case .unreadable(let m): return "unreadable(\(m))"
        case .encoder(let m): return "encoder(\(m))"
        }
    }
}

/// Turns a video file into an animated GIF. The video's own timeline decides what is in it, so a recording's pauses, already absent
/// from its file, are absent from the GIF too. A picture held for several frames becomes one GIF frame with a longer delay.
///
/// ImageIO builds one palette for all the frames it is given and keeps every frame until it finishes, about 10 bytes a pixel each.
/// To keep memory flat for a long recording, the frames go to ImageIO in batches, and `GifAssembler` joins the batches into one file,
/// moving each batch's palette onto its own frames.
public enum GifConverter {
    /// Pixels ImageIO may hold at once, about 160 MB.
    static let batchPixels = 15_000_000

    /// `workers` caps the threads that scale and encode frames; the file is the same whatever it is.
    public static func convert(_ video: URL, to gif: URL, options: GifOptions = .standard, workers: Int? = nil) async throws -> GifReport {
        let asset = AVURLAsset(url: video)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first else { throw GifError.unreadable("no video track") }
        let duration = (try? await asset.load(.duration).seconds) ?? 0
        let natural = (try? await track.load(.naturalSize)) ?? .zero
        guard duration > 0, natural.width >= 1, natural.height >= 1 else { throw GifError.unreadable("empty video") }
        return try encode(asset: asset, track: track, duration: duration, natural: natural, to: gif, options: options, tuning: workers.map { GifTuning(workers: max(1, $0), qos: .userInitiated) } ?? .standard)
    }

    private static func encode(asset: AVURLAsset, track: AVAssetTrack, duration: Double, natural: CGSize, to gif: URL, options: GifOptions, tuning: GifTuning) throws -> GifReport {
        let k = min(1, Double(options.maxPixel) / Double(max(natural.width, natural.height)))
        let width = max(1, Int((natural.width * k).rounded())), height = max(1, Int((natural.height * k).rounded()))
        let reader: AVAssetReader
        do { reader = try AVAssetReader(asset: asset) } catch { throw GifError.unreadable(error.localizedDescription) }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { throw GifError.unreadable(reader.error?.localizedDescription ?? "reader did not start") }

        let fps = Double(options.fps)
        let slots = max(1, Int((duration * fps - 1e-6).rounded(.up)))
        func centis(_ slot: Int) -> Int { Int((Double(slot) * 100 / fps).rounded()) }

        let assembler = try GifAssembler(url: gif, width: width, height: height)
        var batches = GifBatches(capacity: max(4, batchPixels / (width * height)), assembler: assembler)
        var frames = 0, totalCentis = 0
        // The picture on screen from slot `held.start`, waiting to learn how long it stays.
        var held: (image: CGImage, start: Int)?
        var latest: CMSampleBuffer?
        var slot = 0
        // Pictures to show, each from a slot on. They are scaled together, since scaling is most of the work, and then taken in order.
        var shown: [(sample: CMSampleBuffer, start: Int)] = []
        // A scaler keeps its bitmap between frames, so each picture it makes is its own copy and nothing else holds the bitmap's memory.
        let idle = ScalerPool(width: width, height: height)

        func scaleAndTake() throws {
            guard !shown.isEmpty else { return }
            let work = shown
            shown.removeAll(keepingCapacity: true)
            var images = [CGImage?](repeating: nil, count: work.count)
            let lock = NSLock()
            var failure: Error?
            let lanes = min(tuning.workers, work.count)
            DispatchQueue.concurrentPerform(iterations: lanes) { lane in
                for i in stride(from: lane, to: work.count, by: lanes) {
                    autoreleasepool {
                        do {
                            let scaler = try idle.take()
                            defer { idle.give(scaler) }
                            let image = try scaler.image(of: work[i].sample)
                            lock.lock(); images[i] = image; lock.unlock()
                        } catch { lock.lock(); failure = failure ?? error; lock.unlock() }
                    }
                }
            }
            if let failure { throw failure }
            for (i, item) in work.enumerated() {
                if let h = held {
                    let delay = centis(item.start) - centis(h.start)
                    try batches.add(h.image, centis: delay)
                    frames += 1; totalCentis += delay
                }
                held = images[i].map { ($0, item.start) }
            }
        }

        func show(_ sample: CMSampleBuffer, from start: Int) throws {
            shown.append((sample, start))
            if shown.count >= tuning.workers { try scaleAndTake() }
        }

        while slot < slots, let sample = autoreleasepool(invoking: { output.copyNextSampleBuffer() }) {
            let t = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            // Slots before this frame show the latest one before it.
            if let latest, Double(slot) / fps < t - 1e-6 {
                try show(latest, from: slot)
                while slot < slots, Double(slot) / fps < t - 1e-6 { slot += 1 }
            }
            latest = sample
        }
        if reader.status == .failed { throw GifError.unreadable(reader.error?.localizedDescription ?? "reader failed") }
        if let latest, slot < slots { try show(latest, from: slot) }
        try scaleAndTake()
        reader.cancelReading()
        if let h = held {
            let delay = max(1, centis(slots) - centis(h.start))
            try batches.add(h.image, centis: delay)
            frames += 1; totalCentis += delay
        }
        try batches.finish()
        let bytes = try assembler.finish()
        return GifReport(url: gif, width: width, height: height, frames: frames, duration: Double(totalCentis) / 100, bytes: bytes)
    }
}

/// How hard a conversion works: the user-initiated class, since the person waits on it, on at most half the cores.
struct GifTuning {
    var workers: Int
    var qos: QualityOfService
    static var standard: GifTuning { GifTuning(workers: min(6, max(1, ProcessInfo.processInfo.activeProcessorCount / 2)), qos: .userInitiated) }
}

/// Scalers waiting for a frame, one for each frame being scaled at the same time.
private final class ScalerPool: @unchecked Sendable {
    let width: Int, height: Int
    private let lock = NSLock()
    private var idle: [Scaler] = []

    init(width: Int, height: Int) { self.width = width; self.height = height }

    func take() throws -> Scaler {
        lock.lock()
        let kept = idle.popLast()
        lock.unlock()
        return try kept ?? Scaler(width: width, height: height)
    }

    func give(_ scaler: Scaler) { lock.lock(); idle.append(scaler); lock.unlock() }
}

/// Draws decoded frames at the GIF's size.
private final class Scaler {
    let width: Int, height: Int
    private let context: CGContext
    private let space = CGColorSpace(name: CGColorSpace.sRGB)!
    private let info = CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue

    init(width: Int, height: Int) throws {
        self.width = width; self.height = height
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: info) else {
            throw GifError.encoder("no drawing context")
        }
        ctx.interpolationQuality = .high
        context = ctx
    }

    func image(of sample: CMSampleBuffer) throws -> CGImage? {
        guard let pixels = CMSampleBufferGetImageBuffer(sample) else { return nil }
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        guard let source = CGContext(data: CVPixelBufferGetBaseAddress(pixels), width: CVPixelBufferGetWidth(pixels), height: CVPixelBufferGetHeight(pixels),
                                     bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixels), space: space, bitmapInfo: info),
              let full = source.makeImage() else { throw GifError.encoder("frame not readable") }
        context.draw(full, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}

/// Frames waiting for ImageIO. A full batch is encoded and handed to the assembler.
///
/// Batches are encoded one at a time on the calling thread: encoded on other threads beside the scaling, ImageIO's memory was not given
/// back as it went and the conversion grew to over twice the memory for a third less time.
private struct GifBatches {
    let capacity: Int
    private let assembler: GifAssembler
    private var current: [(image: CGImage, centis: Int)] = []

    init(capacity: Int, assembler: GifAssembler) { self.capacity = capacity; self.assembler = assembler }

    mutating func add(_ image: CGImage, centis: Int) throws {
        current.append((image, centis))
        if current.count == capacity { try finish() }
    }

    mutating func finish() throws {
        guard !current.isEmpty else { return }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.gif.identifier as CFString, current.count, nil) else { throw GifError.encoder("no GIF destination") }
        for frame in current {
            let delay = Double(frame.centis) / 100
            let properties = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay, kCGImagePropertyGIFUnclampedDelayTime: delay]] as CFDictionary
            CGImageDestinationAddImage(destination, frame.image, properties)
        }
        current = []
        guard CGImageDestinationFinalize(destination) else { throw GifError.encoder("ImageIO could not finish a batch") }
        try assembler.append(data as Data)
    }
}

/// Writes one GIF from GIFs that ImageIO made of consecutive frames. The output has no global palette: each frame carries its batch's
/// palette as its own, so frames from different batches can differ in colors. ImageIO's frame delays, disposal and transparency stay.
final class GifAssembler {
    private let handle: FileHandle
    private let url: URL

    init(url: URL, width: Int, height: Int) throws {
        try? FileManager.default.removeItem(at: url)
        guard FileManager.default.createFile(atPath: url.path, contents: nil), let handle = try? FileHandle(forWritingTo: url) else {
            throw GifError.encoder("cannot create \(url.lastPathComponent)")
        }
        self.handle = handle
        self.url = url
        var head = Data("GIF89a".utf8)
        head.append(le16(width)); head.append(le16(height))
        head.append(contentsOf: [0, 0, 0])
        head.append(contentsOf: [0x21, 0xFF, 11]); head.append(Data("NETSCAPE2.0".utf8))
        head.append(contentsOf: [3, 1, 0, 0, 0])
        handle.write(head)
    }

    /// Copies every frame of `gif`, giving each the file's global palette when it has none of its own.
    func append(_ gif: Data) throws {
        let b = [UInt8](gif)
        func need(_ n: Int, at i: Int) throws { if i + n > b.count { throw GifError.encoder("batch GIF ends early") } }
        try need(13, at: 0)
        guard b[0] == 0x47, b[1] == 0x49, b[2] == 0x46 else { throw GifError.encoder("batch is not a GIF") }
        var i = 13
        var palette: ArraySlice<UInt8> = []
        var paletteBits: UInt8 = 0
        if b[10] & 0x80 != 0 {
            paletteBits = b[10] & 0x07
            let n = 3 << (Int(paletteBits) + 1)
            try need(n, at: i)
            palette = b[i..<i + n]
            i += n
        }
        var out = Data()
        func subBlocks(from start: Int) throws -> Int {
            var j = start
            while true {
                try need(1, at: j)
                let n = Int(b[j])
                j += 1
                if n == 0 { return j }
                try need(n, at: j)
                j += n
            }
        }
        while true {
            try need(1, at: i)
            switch b[i] {
            case 0x21:
                try need(2, at: i)
                let end = try subBlocks(from: i + 2)
                // Only the graphic control extension belongs to a frame. The loop extension is written once, in the header.
                if b[i + 1] == 0xF9 { out.append(contentsOf: b[i..<end]) }
                i = end
            case 0x2C:
                try need(10, at: i)
                var packed = b[i + 9]
                out.append(contentsOf: b[i..<i + 9])
                var j = i + 10
                if packed & 0x80 != 0 {
                    let n = 3 << (Int(packed & 0x07) + 1)
                    try need(n, at: j)
                    out.append(packed)
                    out.append(contentsOf: b[j..<j + n])
                    j += n
                } else {
                    guard !palette.isEmpty else { throw GifError.encoder("a frame has no palette") }
                    packed = 0x80 | (packed & 0x40) | paletteBits
                    out.append(packed)
                    out.append(contentsOf: palette)
                }
                try need(1, at: j)
                let end = try subBlocks(from: j + 1)
                out.append(contentsOf: b[j..<end])
                i = end
            case 0x3B:
                handle.write(out)
                return
            default:
                throw GifError.encoder("unknown block \(b[i]) in a batch")
            }
        }
    }

    /// Ends the file and returns its size.
    func finish() throws -> Int {
        handle.write(Data([0x3B]))
        try handle.close()
        return (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    }

    private func le16(_ v: Int) -> Data { Data([UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)]) }
}
