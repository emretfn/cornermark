import AppKit
import AVFoundation

/// A canned display showing `SyntheticScene`, with no screen and no permission involved.
public final class FixtureFrameSource: FrameSource {
    public enum Pacing {
        /// Delivers `frames` pictures from `start` itself, spaced exactly `1/fps` apart on the picture clock, the first one at `origin` seconds.
        /// `skipping` leaves holes.
        case scripted(frames: Int, skipping: Set<Int> = [], origin: Double = 0)
        /// Delivers at the real rate until `stop`.
        case realtime
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
    private let displayFrame: CGRect
    private let scale: Double
    private let area: CGRect?
    private let fps: Int
    private let pacing: Pacing
    private let queue = DispatchQueue(label: "cornermark.fixture-frames")
    private var timer: DispatchSourceTimer?
    private var crop = CGRect.zero
    public private(set) var pointArea = CGRect.zero

    public init(displayFrame: CGRect = FixtureFrameSource.displayFrame, scale: Double = 1, area: CGRect? = nil, fps: Int = 60, pacing: Pacing) {
        self.displayFrame = displayFrame; self.scale = scale; self.area = area; self.fps = fps; self.pacing = pacing
    }

    public func prepare() async throws -> FrameFormat {
        guard let rect = StreamGeometry.sourceRect(area: area ?? displayFrame, displayFrame: displayFrame) else {
            throw RecordingError.source("The area is outside the display")
        }
        pointArea = CGRect(x: rect.minX + displayFrame.minX, y: displayFrame.maxY - rect.maxY, width: rect.width, height: rect.height)
        crop = CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale)
        return StreamGeometry.format(of: rect, scale: scale, fps: fps)
    }

    public func start(_ deliver: @escaping (VideoFrame) -> Void) async throws {
        let format = try await prepare()
        switch pacing {
        case .scripted(let frames, let skipping, let origin):
            let start = CMTime(seconds: origin, preferredTimescale: CMTimeScale(fps))
            for i in 0..<frames where !skipping.contains(i) {
                let t = CMTime(value: CMTimeValue(i), timescale: CMTimeScale(fps))
                deliver(VideoFrame(pixels: try render(format, at: t.seconds), time: CMTimeAdd(start, t)))
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
                if let pixels = try? self.render(format, at: CMTimeSubtract(now, origin).seconds) {
                    deliver(VideoFrame(pixels: pixels, time: now))
                    self.framesDelivered += 1
                }
            }
            self.timer = timer
            timer.resume()
        }
    }

    public func stop() async {
        timer?.cancel()
        timer = nil
        queue.sync {}
    }

    private func render(_ format: FrameFormat, at time: Double) throws -> CVPixelBuffer {
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
        ctx.scaleBy(x: scale, y: scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        SyntheticScene.draw(size: displayFrame.size, time: time)
        NSGraphicsContext.restoreGraphicsState()
        return buffer
    }
}
