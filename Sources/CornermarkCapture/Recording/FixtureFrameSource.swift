import AppKit
import AVFoundation

/// A canned display showing `SyntheticScene`, with no screen and no permission involved. When the options ask for the pointer in the
/// picture and a `cursor` script is given, the script's pointer is drawn into each frame, as the live stream draws the real one.
/// `windows` are other applications' windows on the display. The options' exclusion plan decides which of them the picture shows,
/// the same plan the live stream turns into its content filter.
public final class FixtureFrameSource: FrameSource {
    public enum Pacing {
        /// Delivers `frames` pictures from `start` itself, spaced exactly `1/fps` apart on the picture clock, the first one at `origin` seconds.
        /// `skipping` leaves holes.
        case scripted(frames: Int, skipping: Set<Int> = [], origin: Double = 0)
        /// Delivers at the real rate until `stop`.
        case realtime
        /// Delivers only when `advance` is called, `1/fps` apart, so a test decides what happens between frames.
        case manual
    }

    /// The fixture display every isolated recording uses.
    public static let displayID: CGDirectDisplayID = 1
    public static let displayFrame = CGRect(x: 0, y: 0, width: 1280, height: 720)

    public var onFailure: ((Error) -> Void)?
    public var deliversInRealTime: Bool {
        if case .realtime = pacing { return true }
        return false
    }
    public private(set) var framesDelivered = 0
    /// Whole white pictures, each the first frame at or after a click of these, for measuring sound against the picture.
    public var flash: AudioPattern.Clicks?
    private let displayFrame: CGRect
    private let scale: Double
    private let area: CGRect?
    private let options: RecordingOptions
    private let cursor: PointerScript?
    private let pacing: Pacing
    private let windows: [FixtureWindow]
    private var shown: [FixtureWindow] = []
    private var manual: (format: FrameFormat, deliver: (VideoFrame) -> Void)?
    private var manualCount = 0
    private let queue = DispatchQueue(label: "cornermark.fixture-frames")
    private var timer: DispatchSourceTimer?
    private var crop = CGRect.zero
    /// The filmed area in display points with a top-left origin.
    private var sourceRect = CGRect.zero
    /// Pixels per point along each axis, after the options' density and size limit.
    private var pixelScale = CGSize(width: 1, height: 1)
    public private(set) var pointArea = CGRect.zero
    private var fps: Int { options.fps }

    public init(displayFrame: CGRect = FixtureFrameSource.displayFrame, scale: Double = 1, area: CGRect? = nil, options: RecordingOptions = .standard,
                cursor: PointerScript? = nil, windows: [FixtureWindow] = [], pacing: Pacing) {
        self.displayFrame = displayFrame; self.scale = scale; self.area = area; self.options = options; self.cursor = cursor; self.pacing = pacing
        self.windows = windows
    }

    /// The windows this source's pictures show, after the exclusion plan.
    public var filmedWindows: [FixtureWindow] { shown }

    public func prepare() async throws -> FrameFormat {
        guard let rect = StreamGeometry.sourceRect(area: area ?? displayFrame, displayFrame: displayFrame) else {
            throw RecordingError.source("The area is outside the display")
        }
        pointArea = CGRect(x: rect.minX + displayFrame.minX, y: displayFrame.maxY - rect.maxY, width: rect.width, height: rect.height)
        sourceRect = rect
        let format = StreamGeometry.format(of: rect, scale: scale, options: options)
        pixelScale = CGSize(width: Double(format.width) / rect.width, height: Double(format.height) / rect.height)
        crop = CGRect(x: rect.minX * pixelScale.width, y: rect.minY * pixelScale.height, width: rect.width * pixelScale.width, height: rect.height * pixelScale.height)
        let plan = options.exclusion.plan(apps: windows.map(\.app), windows: windows.map(\.window), ownPID: ProcessInfo.processInfo.processIdentifier)
        shown = windows.filter { plan.films($0.window) }
        return format
    }

    public func start(_ deliver: @escaping (VideoFrame) -> Void) async throws {
        let format = try await prepare()
        switch pacing {
        case .scripted(let frames, let skipping, let origin):
            let start = CMTime(seconds: origin, preferredTimescale: CMTimeScale(fps))
            for i in 0..<frames where !skipping.contains(i) {
                let t = CMTime(value: CMTimeValue(i), timescale: CMTimeScale(fps))
                let time = CMTimeAdd(start, t)
                deliver(VideoFrame(pixels: try render(format, at: t.seconds, clock: time.seconds), time: time))
                framesDelivered += 1
            }
        case .realtime:
            let clock = CMClockGetHostTimeClock()
            let origin = CMClockGetTime(clock)
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: .nanoseconds(1_000_000_000 / fps), leeway: .microseconds(200))
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                let now = CMClockGetTime(clock)
                if let pixels = try? self.render(format, at: CMTimeSubtract(now, origin).seconds, clock: now.seconds) {
                    deliver(VideoFrame(pixels: pixels, time: now))
                    self.framesDelivered += 1
                }
            }
            self.timer = timer
            timer.resume()
        case .manual:
            manual = (format, deliver)
        }
    }

    /// Delivers the next `frames` pictures of a `.manual` source.
    public func advance(_ frames: Int) throws {
        guard let manual else { return }
        for _ in 0..<frames {
            let t = CMTime(value: CMTimeValue(manualCount), timescale: CMTimeScale(fps))
            manual.deliver(VideoFrame(pixels: try render(manual.format, at: t.seconds, clock: t.seconds), time: t))
            manualCount += 1
            framesDelivered += 1
        }
    }

    public func stop() async {
        timer?.cancel()
        timer = nil
        manual = nil
        queue.sync {}
    }

    private func render(_ format: FrameFormat, at time: Double, clock: Double) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, format.width, format.height, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
        guard let buffer else { throw RecordingError.source("Could not allocate a frame") }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: format.width, height: format.height,
                                  bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { throw RecordingError.source("Could not draw a frame") }
        ctx.translateBy(x: 0, y: CGFloat(format.height))
        ctx.scaleBy(x: 1, y: -1)
        ctx.translateBy(x: -crop.minX, y: -crop.minY)
        ctx.scaleBy(x: pixelScale.width, y: pixelScale.height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        SyntheticScene.draw(size: displayFrame.size, time: time)
        shown.forEach { $0.draw() }
        if options.showsCursor, let p = cursor?.position(at: time) {
            SyntheticScene.drawPointer(at: CGPoint(x: sourceRect.minX + p.x * sourceRect.width, y: sourceRect.minY + p.y * sourceRect.height))
        }
        if let flash, flash.isFirstFrame(at: clock, fps: fps) {
            NSColor.white.setFill()
            CGRect(origin: .zero, size: displayFrame.size).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        return buffer
    }
}
