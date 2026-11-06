import AVFoundation
import CornermarkCapture
import CornermarkCore
import CornermarkVideoEditor
import Foundation
import ImageIO
import VideoToolbox

// Measures and checks video export without any window or sound.
//   HarnessExport run <plain|heavy|gif> <video> <outDir>   one export, with wall time, CPU time, peak memory and scheduling latency
//   HarnessExport bench <seconds>                          a CPU benchmark on every core, to run beside an export
//   HarnessExport check                                    the video editor window in a pseudo language: texts, mirroring, kept state (also the default)

func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }

func cpuSeconds() -> Double {
    var u = rusage(); getrusage(RUSAGE_SELF, &u)
    return Double(u.ru_utime.tv_sec) + Double(u.ru_utime.tv_usec) / 1e6 + Double(u.ru_stime.tv_sec) + Double(u.ru_stime.tv_usec) / 1e6
}

func peakMemoryMB() -> Double {
    var u = rusage(); getrusage(RUSAGE_SELF, &u)
    return Double(u.ru_maxrss) / 1_048_576
}

/// A project over a 2560 x 1440 recording shown in points of half that, with the edits `scenario` names.
func makeProject(heavy: Bool, duration: Double, width: Int = 2560, height: Int = 1440, fps: Int = 60) -> RecordingProject {
    let pw = Double(width) / 2, ph = Double(height) / 2
    let pointer = stride(from: 0.0, through: duration, by: 1.0 / 60).map { t in
        PointerSample(t: t, x: pw * (0.5 + 0.38 * sin(t * 1.3)), y: ph * (0.5 + 0.35 * sin(t * 2.1 + 1)))
    }
    let clicks = stride(from: 1.0, to: duration, by: 2.5).map { ClickEvent(t: $0, x: pw * (0.5 + 0.38 * sin($0 * 1.3)), y: ph * (0.5 + 0.35 * sin($0 * 2.1 + 1))) }
    let source = RecordingProject.Source(pixelWidth: width, pixelHeight: height, pointWidth: pw, pointHeight: ph, fps: fps, duration: duration)
    var edits = RecordingProject.Edits()
    if heavy {
        let early = ProcessInfo.processInfo.environment["HE_EARLYZOOM"] != nil
        edits.zooms = [Zoom(start: early ? 0.2 : 2, end: early ? 5 : 5, scale: 2.2, mode: .followCursor), Zoom(start: 7, end: 10, scale: 3, mode: .followCursor), Zoom(start: 11, end: min(13.5, duration - 0.5), scale: 1.8, mode: .followCursor)]
        edits.cursor = CursorSettings(scale: 1.4, pressesOnClick: true)
        edits.background = VideoBackground(fill: .gradient(index: 2), padding: 64, shadow: 50, cornerRadius: 14)
        edits.motionBlur = MotionBlur(scope: .zoomsAndCursor, shutterAngle: 180)
    } else {
        edits.motionBlur = MotionBlur(scope: .off)
        edits.cursor = CursorSettings(isVisible: false)
    }
    return RecordingProject(source: source, events: .init(pointer: pointer, clicks: heavy ? clicks : []), edits: edits)
}

func probeDuration(_ url: URL) async -> Double { (try? await AVURLAsset(url: url).load(.duration).seconds) ?? 0 }

/// Wakes every 5 ms on a thread of the default class and notes how late each wake-up is: how a lively app on this Mac would fare.
final class LatencyProbe: @unchecked Sendable {
    private var samples: [Double] = []
    private var stop = false
    private let lock = NSLock()
    private var thread: Thread?
    func start() {
        let t = Thread { [self] in
            while true {
                lock.lock(); let s = stop; lock.unlock()
                if s { return }
                let before = now()
                Thread.sleep(forTimeInterval: 0.005)
                let late = (now() - before - 0.005) * 1000
                lock.lock(); samples.append(late); lock.unlock()
            }
        }
        t.qualityOfService = .userInteractive
        t.start(); thread = t
    }
    func finish() -> (p50: Double, p99: Double, max: Double, n: Int) {
        lock.lock(); stop = true; let s = samples.sorted(); lock.unlock()
        guard !s.isEmpty else { return (0, 0, 0, 0) }
        return (s[s.count / 2], s[min(s.count - 1, Int(Double(s.count) * 0.99))], s.last!, s.count)
    }
}

/// `HE_WORKERS` and `HE_QOS` (utility, userInitiated, default, background) override the export's tuning, to compare settings.
func tuningFromEnvironment() -> ExportTuning {
    let env = ProcessInfo.processInfo.environment
    var t = ExportTuning.standard
    if let w = env["HE_WORKERS"].flatMap(Int.init) { t.workers = max(1, w) }
    switch env["HE_QOS"] {
    case "userInitiated": t.qos = .userInitiated
    case "default": t.qos = .default
    case "background": t.qos = .background
    case "utility": t.qos = .utility
    default: break
    }
    return t
}

func report(_ pairs: [(String, String)]) { print(pairs.map { "\($0.0)=\($0.1)" }.joined(separator: " ")) }

func f(_ v: Double, _ d: Int = 2) -> String { String(format: "%.\(d)f", v) }

func runExport(scenario: String, video: URL, outDir: URL) async throws {
    try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    var duration = await probeDuration(video)
    if let limit = ProcessInfo.processInfo.environment["HE_SECONDS"].flatMap(Double.init) { duration = min(duration, limit) }
    let probe = LatencyProbe(); probe.start()
    let c0 = cpuSeconds(), w0 = now()
    if scenario == "gif" {
        let out = outDir.appendingPathComponent("out-\(UUID().uuidString.prefix(4)).gif")
        let r = try await GifConverter.convert(video, to: out, workers: ProcessInfo.processInfo.environment["HE_WORKERS"].flatMap(Int.init))
        let wall = now() - w0, cpu = cpuSeconds() - c0, lat = probe.finish()
        report([("scenario", "gif"), ("wall_s", f(wall)), ("rt_factor", f(duration / wall)), ("cpu_s", f(cpu)), ("avg_cores", f(cpu / wall)), ("peak_mb", f(peakMemoryMB(), 0)),
                ("frames", "\(r.frames)"), ("bytes", "\(r.bytes)"), ("lat_p50_ms", f(lat.p50)), ("lat_p99_ms", f(lat.p99)), ("lat_max_ms", f(lat.max)), ("out", out.path)])
        return
    }
    let project = makeProject(heavy: scenario == "heavy", duration: duration)
    let out = outDir.appendingPathComponent("out-\(scenario)-\(UUID().uuidString.prefix(4)).mp4")
    let r = try await VideoExporter.export(project: project, video: video, settings: ExportSettings(), to: out, tuning: tuningFromEnvironment())
    let wall = now() - w0, cpu = cpuSeconds() - c0, lat = probe.finish()
    report([("scenario", scenario), ("wall_s", f(wall)), ("rt_factor", f(duration / wall)), ("cpu_s", f(cpu)), ("avg_cores", f(cpu / wall)), ("peak_mb", f(peakMemoryMB(), 0)),
            ("frames", "\(r.framesWritten)"), ("drawings", "\(r.drawings)"), ("blurred", "\(r.blurredFrames)"), ("hw", "\(r.usesHardware)"), ("encoder", r.encoderID),
            ("bytes", "\(r.bytes)"), ("audio", "\(r.hasAudio)"), ("lat_p50_ms", f(lat.p50)), ("lat_p99_ms", f(lat.p99)), ("lat_max_ms", f(lat.max)), ("out", out.path)])
}

/// Spins on every core at the default class for `seconds` and reports iterations done, so a run beside an export shows how much throughput is left.
func bench(seconds: Double) {
    let cores = ProcessInfo.processInfo.activeProcessorCount
    let counts = UnsafeMutablePointer<UInt64>.allocate(capacity: cores)
    counts.initialize(repeating: 0, count: cores)
    let end = now() + seconds
    DispatchQueue.concurrentPerform(iterations: cores) { i in
        var x: UInt64 = 0x9E3779B97F4A7C15 &+ UInt64(i), n: UInt64 = 0
        while now() < end {
            for _ in 0..<200_000 { x = x &* 6364136223846793005 &+ 1442695040888963407; x ^= x >> 29 }
            n += 1
        }
        counts[i] = n &+ (x & 0)
    }
    var total: UInt64 = 0
    for i in 0..<cores { total += counts[i] }
    print("bench cores=\(cores) seconds=\(seconds) iterations=\(total) per_s=\(Double(total) / seconds)")
}

let args = CommandLine.arguments
switch args.count > 1 ? args[1] : "" {
case "run" where args.count >= 5:
    try await runExport(scenario: args[2], video: URL(fileURLWithPath: args[3]), outDir: URL(fileURLWithPath: args[4]))
case "encbench":
    print("BGRA", encodeBench(format: kCVPixelFormatType_32BGRA, frames: 300))
    print("420v", encodeBench(format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, frames: 300))
    print("BGRA speed", encodeBench(format: kCVPixelFormatType_32BGRA, frames: 300, extra: [kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality: true]))
    print("420v speed", encodeBench(format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, frames: 300, extra: [kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality: true]))
case "encbench2":
    print("HEVC", encodeBench(format: kCVPixelFormatType_32BGRA, frames: 300, codec: kCMVideoCodecType_HEVC))
    print("H264 1080p", encodeBench(format: kCVPixelFormatType_32BGRA, frames: 300, w: 1920, h: 1080))
    let g = DispatchGroup()
    for i in 0..<2 { g.enter(); DispatchQueue.global().async { print("parallel", i, encodeBench(format: kCVPixelFormatType_32BGRA, frames: 300)); g.leave() } }
    g.wait()
case "probe":
    let probe = LatencyProbe(); probe.start()
    Thread.sleep(forTimeInterval: args.count > 2 ? Double(args[2]) ?? 10 : 10)
    let lat = probe.finish()
    print("probe wakeups=\(lat.n) late_p50_ms=\(f(lat.p50)) late_p99_ms=\(f(lat.p99)) late_max_ms=\(f(lat.max))")
case "bench":
    bench(seconds: args.count > 2 ? Double(args[2]) ?? 10 : 10)
case "check", "":
    exit(await localizationChecks() ? 0 : 1)
default:
    print("usage: HarnessExport [check] | run <plain|heavy|gif> <video> <outDir> | bench <seconds>")
    exit(64)
}
