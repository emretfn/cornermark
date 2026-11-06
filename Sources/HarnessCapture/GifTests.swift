import AVFoundation
import CornermarkCapture
import Foundation
import ImageIO

struct GifFacts {
    var width = 0, height = 0, frames = 0
    var loopCount: Int?
    var delays: [Double] = []
    var duration: Double { delays.reduce(0, +) }
}

func gifFacts(_ url: URL) -> GifFacts? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetType(source) as String? == "com.compuserve.gif" else { return nil }
    var facts = GifFacts(frames: CGImageSourceGetCount(source))
    let file = CGImageSourceCopyProperties(source, nil) as? [CFString: Any]
    facts.loopCount = (file?[kCGImagePropertyGIFDictionary] as? [CFString: Any])?[kCGImagePropertyGIFLoopCount] as? Int
    for i in 0..<facts.frames {
        let p = CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [CFString: Any]
        let gif = p?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        facts.delays.append((gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double) ?? (gif?[kCGImagePropertyGIFDelayTime] as? Double) ?? 0)
        if i == 0 { facts.width = p?[kCGImagePropertyPixelWidth] as? Int ?? 0; facts.height = p?[kCGImagePropertyPixelHeight] as? Int ?? 0 }
    }
    return facts
}

func gifFrame(_ url: URL, _ index: Int) -> CGImage? {
    CGImageSourceCreateWithURL(url as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, index, nil) }
}

/// The video's picture at `time`, drawn at `size`, the way the GIF should show it before its palette.
func videoFrame(_ url: URL, at time: Double, size: CGSize) async -> CGImage? {
    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = .zero
    generator.maximumSize = size
    return try? await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image
}

/// The mean difference per channel, 0 to 255, between two pictures of the same size.
@MainActor
func meanDifference(_ a: CGImage, _ b: CGImage) -> Double {
    guard a.width == b.width, a.height == b.height else { return .infinity }
    let pa = Pixels.rgba(a), pb = Pixels.rgba(b)
    var sum = 0
    for i in stride(from: 0, to: pa.count, by: 4) {
        sum += abs(Int(pa[i]) - Int(pb[i])) + abs(Int(pa[i + 1]) - Int(pb[i + 1])) + abs(Int(pa[i + 2]) - Int(pb[i + 2]))
    }
    return Double(sum) / Double(pa.count / 4 * 3)
}

/// The process's memory footprint now and the highest it has been, in MB.
func footprintMB() -> (now: Double, peak: Double) {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) } }
    guard kr == KERN_SUCCESS else { return (0, 0) }
    return (Double(info.phys_footprint) / 1_048_576, Double(info.ledger_phys_footprint_peak) / 1_048_576)
}

@MainActor
func runGifTests() async {
    section("GIF conversion")
    let gif = { (name: String) in URL(fileURLWithPath: recordingScratch + name + ".gif") }
    do {
        let (report, video) = try await recordFixture("gif-source", area: nil, fps: 30, pacing: .scripted(frames: 90))
        let out = try await GifConverter.convert(report.url, to: gif("standard"))
        guard let facts = gifFacts(out.url) else { return check(false, "the converter writes a GIF ImageIO reads") }
        check(facts.width == 960 && facts.height == 540 && out.width == 960, "a 1280x720 video becomes a 960x540 GIF, the longest side at 960", detail: "\(facts.width)x\(facts.height)")
        check(facts.frames == 45 && out.frames == 45, "3.0 s of changing pictures at 15 fps make 45 frames", detail: "file \(facts.frames), report \(out.frames), video \(video.frames) frames")
        check(facts.loopCount == 0, "the GIF loops forever", detail: "\(String(describing: facts.loopCount))")
        check(Set(facts.delays.map { Int(($0 * 100).rounded()) }).isSubset(of: [6, 7]), "each delay is 6 or 7 hundredths, so 15 fps holds over time",
              detail: "\(Set(facts.delays))")
        check(abs(facts.duration - video.duration) < 0.011 && abs(out.duration - facts.duration) < 0.001, "the delays add up to the video's length",
              detail: "gif \(facts.duration) s, video \(video.duration) s, report \(out.duration) s")
        check(out.bytes == (try? FileManager.default.attributesOfItem(atPath: out.url.path)[.size] as? Int), "the report carries the real file size", detail: "\(out.bytes)")

        // ImageIO is fed 28 frames at a time at this size, so frames 27 and 28 sit on each side of the seam between two batches.
        var diffs: [Int: Double] = [:]
        for i in [0, 13, 26, 27, 28, 29, 43] {
            guard let g = gifFrame(out.url, i), let v = await videoFrame(report.url, at: Double(i) / 15, size: CGSize(width: 960, height: 540)) else {
                check(false, "frame \(i) can be read from both files"); continue
            }
            diffs[i] = meanDifference(g, v)
        }
        check((diffs.values.max() ?? .infinity) < 6, "every checked GIF frame matches the video at its time, across the batch seams",
              detail: diffs.sorted { $0.key < $1.key }.map { "\($0.key): \(String(format: "%.2f", $0.value))" }.joined(separator: ", "))
        if let first = gifFrame(out.url, 0) {
            check(dominant(color(first, 0.03, 0.04), is: 0) && dominant(color(first, 0.97, 0.04), is: 1) && dominant(color(first, 0.03, 0.96), is: 2),
                  "the first frame keeps the scene's red, green and blue corners")
        }

        let (small, _) = try await recordFixture("gif-small", area: CGRect(x: 0, y: 0, width: 320, height: 180), fps: 30, pacing: .scripted(frames: 30))
        let smallGif = try await GifConverter.convert(small.url, to: gif("small"))
        check(smallGif.width == 320 && smallGif.height == 180, "a video smaller than the limit keeps its size", detail: "\(smallGif.width)x\(smallGif.height)")

        let (held, heldVideo) = try await recordFixture("gif-held", area: CGRect(x: 0, y: 0, width: 320, height: 180), fps: 60, pacing: .scripted(frames: 60, skipping: Set(1..<59)))
        let heldGif = try await GifConverter.convert(held.url, to: gif("held"))
        let heldFacts = gifFacts(heldGif.url)
        check(heldVideo.frames == 2 && heldFacts?.frames == 2, "a picture held for most of a second stays one frame with a long delay",
              detail: "video \(heldVideo.frames) frames, GIF \(heldFacts?.frames ?? -1) frames, delays \(heldFacts?.delays ?? [])")
        check(abs((heldFacts?.duration ?? 0) - heldVideo.duration) <= 1.0 / 15 + 1e-6, "and the GIF lasts as long as the video, to within one GIF frame", detail: "\(heldFacts?.duration ?? 0) vs \(heldVideo.duration)")

        let custom = try await GifConverter.convert(report.url, to: gif("custom"), options: GifOptions(fps: 10, maxPixel: 480))
        let customFacts = gifFacts(custom.url)
        check(customFacts?.frames == 30 && customFacts?.width == 480 && customFacts?.loopCount == 0, "options set the rate and the size",
              detail: "\(customFacts?.frames ?? -1) frames, \(customFacts?.width ?? -1) wide, loop \(String(describing: customFacts?.loopCount))")

        // Threads scale the frames and encode the batches beside each other; the bytes of the file must not depend on how many there are.
        let serial = try await GifConverter.convert(report.url, to: gif("one-thread"), workers: 1)
        let wide = try await GifConverter.convert(report.url, to: gif("many-threads"), workers: 6)
        let one = try? Data(contentsOf: serial.url), many = try? Data(contentsOf: wide.url), standard = try? Data(contentsOf: out.url)
        check(one != nil && one == many && one == standard, "the GIF is the same file with one thread or six", detail: "\(one?.count ?? -1) / \(many?.count ?? -1) / \(standard?.count ?? -1) bytes")

        let (long, longVideo) = try await recordFixture("gif-long", area: nil, fps: 30, pacing: .scripted(frames: 600))
        let before = footprintMB()
        let longGif = try await GifConverter.convert(long.url, to: gif("long"))
        // The peak is the process's highest so far, so this bounds the conversion's own growth from above.
        let grew = footprintMB().peak - before.now
        check(longGif.frames == 300 && grew < 400, "20 s become 300 frames while memory grows by less than 400 MB",
              detail: "\(longGif.frames) frames of \(longVideo.frames), peak \(Int(grew)) MB over the start, \(longGif.bytes / 1024) KB")
    } catch {
        check(false, "GIF conversion threw", detail: "\(error)")
    }

    do {
        let junk = URL(fileURLWithPath: recordingScratch + "not-a-video.mp4")
        try Data("not a video".utf8).write(to: junk)
        _ = try await GifConverter.convert(junk, to: gif("junk"))
        check(false, "a file that is not a video is refused")
    } catch {
        check(error is GifError, "a file that is not a video is refused with a GIF error", detail: "\(error)")
    }
}
