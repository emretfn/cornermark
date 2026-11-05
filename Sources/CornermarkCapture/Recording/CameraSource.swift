import AppKit
import AVFoundation
import CornermarkCore
import VideoToolbox

/// One camera picture, stamped on the clock the screen pictures use.
public struct CameraPicture {
    public let pixels: CVPixelBuffer
    public let time: Double
    public init(pixels: CVPixelBuffer, time: Double) { self.pixels = pixels; self.time = time }
}

public enum CameraUnavailable: Error, Equatable, CustomStringConvertible {
    case notPermitted
    case noDevice
    case failed(String)

    public var description: String {
        switch self {
        case .notPermitted: return "notPermitted"
        case .noDevice: return "noDevice"
        case .failed(let m): return "failed(\(m))"
        }
    }
}

/// Whether Cornermark may use the camera.
public enum CameraAccess: String, Equatable, Sendable {
    case allowed, denied, notAsked

    /// Reads the answer without asking: this never shows the system prompt.
    public static var current: CameraAccess {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return .allowed
        case .notDetermined: return .notAsked
        default: return .denied
        }
    }

    public private(set) static var requests = 0

    /// Shows the system prompt. Only the live app calls it, when someone turns the camera on in Settings.
    public static func request(_ done: @escaping (Bool) -> Void) {
        requests += 1
        AVCaptureDevice.requestAccess(for: .video) { granted in DispatchQueue.main.async { done(granted) } }
    }
}

/// Where camera pictures come from: the real camera, or a synthetic one in tests and scripted instances.
public protocol CameraSource: AnyObject {
    /// The size of every picture, known before `start`.
    var pixelSize: CGSize { get }
    /// Pictures arrive on a queue of the source's choosing until `stop`. Throws when the camera cannot start, and then delivers nothing.
    func start(_ deliver: @escaping (CameraPicture) -> Void) throws
    func stop()
}

/// The Mac's camera. It never asks for access: without it, `start` throws `notPermitted` and opens nothing.
public final class LiveCameraSource: NSObject, CameraSource, AVCaptureVideoDataOutputSampleBufferDelegate {
    public private(set) static var sessionsOpened = 0
    public let pixelSize = CGSize(width: 1280, height: 720)
    private let queue = DispatchQueue(label: "cornermark.camera", qos: .userInteractive)
    private var session: AVCaptureSession?
    private var deliver: ((CameraPicture) -> Void)?

    public override init() {}

    public func start(_ deliver: @escaping (CameraPicture) -> Void) throws {
        guard CameraAccess.current == .allowed else { throw CameraUnavailable.notPermitted }
        guard let device = AVCaptureDevice.default(for: .video) else { throw CameraUnavailable.noDevice }
        let session = AVCaptureSession()
        let output = AVCaptureVideoDataOutput()
        // A fixed size keeps the camera file's size steady whichever camera is used.
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                                kCVPixelBufferWidthKey as String: Int(pixelSize.width), kCVPixelBufferHeightKey as String: Int(pixelSize.height)]
        output.alwaysDiscardsLateVideoFrames = true
        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input), session.canAddOutput(output) else { throw CameraUnavailable.failed("the camera cannot be used") }
            session.addInput(input)
            session.addOutput(output)
        } catch let error as CameraUnavailable {
            throw error
        } catch {
            throw CameraUnavailable.failed(error.localizedDescription)
        }
        output.setSampleBufferDelegate(self, queue: queue)
        self.deliver = deliver
        self.session = session
        Self.sessionsOpened += 1
        session.startRunning()
    }

    public func stop() {
        session?.stopRunning()
        session = nil
        queue.sync { deliver = nil }
    }

    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let deliver, let clock = session?.synchronizationClock, let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let time = CMSyncConvertTime(CMSampleBufferGetPresentationTimeStamp(sampleBuffer), from: clock, to: CMClockGetHostTimeClock()).seconds
        deliver(CameraPicture(pixels: pixels, time: time))
    }
}

/// A camera made of a moving drawing, so tests and scripted instances never open a real camera. It says SYNTHETIC CAMERA on every
/// picture, and a red block marks its left edge, so a mirrored picture shows it on the right.
public final class ScriptedCameraSource: CameraSource {
    public enum Pacing {
        /// Pictures arrive at `fps` until `stop`, stamped with the recording clock.
        case realtime
        /// Pictures arrive only when `advance` is called, `1/fps` apart from `origin`, so a test decides what happens between them.
        case manual(origin: Double)
    }

    public static let fps = 30
    public let pixelSize: CGSize
    public private(set) var picturesDelivered = 0
    private let pacing: Pacing
    private let queue = DispatchQueue(label: "cornermark.scripted-camera", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private var deliver: ((CameraPicture) -> Void)?
    private var manualCount = 0

    public init(pixelSize: CGSize = CGSize(width: 640, height: 360), pacing: Pacing = .realtime) {
        self.pixelSize = pixelSize; self.pacing = pacing
    }

    public func start(_ deliver: @escaping (CameraPicture) -> Void) throws {
        switch pacing {
        case .manual:
            self.deliver = deliver
        case .realtime:
            let origin = recordingClockNow()
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: .nanoseconds(1_000_000_000 / Self.fps), leeway: .microseconds(500))
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                let now = recordingClockNow()
                guard let pixels = SyntheticCamera.picture(self.pixelSize, at: now - origin) else { return }
                self.picturesDelivered += 1
                deliver(CameraPicture(pixels: pixels, time: now))
            }
            self.timer = timer
            timer.resume()
        }
    }

    /// Delivers the next `count` pictures of a `.manual` source.
    public func advance(_ count: Int = 1) {
        guard case .manual(let origin) = pacing, let deliver else { return }
        for _ in 0..<count {
            let t = Double(manualCount) / Double(Self.fps)
            manualCount += 1
            guard let pixels = SyntheticCamera.picture(pixelSize, at: t) else { continue }
            picturesDelivered += 1
            deliver(CameraPicture(pixels: pixels, time: origin + t))
        }
    }

    public func stop() {
        timer?.cancel()
        timer = nil
        deliver = nil
        queue.sync {}
    }
}

public enum SyntheticCamera {
    public static let label = "SYNTHETIC CAMERA"
    /// The left edge's marker, so mirroring can be seen and measured.
    public static let marker = CGColor(srgbRed: 0.9, green: 0.15, blue: 0.2, alpha: 1)

    /// A black picture, for the camera's file before the camera's first picture arrives.
    static func blank(_ format: FrameFormat) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, format.width, format.height, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
        guard let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer) { memset(base, 0, CVPixelBufferGetDataSize(buffer)) }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }

    /// Inside the part every bubble shape shows, left of centre.
    public static func markerRect(_ size: CGSize) -> CGRect {
        CGRect(x: size.width * 0.25, y: size.height * 0.4, width: size.width * 0.06, height: size.height * 0.2)
    }

    public static func picture(_ size: CGSize, at t: Double) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, Int(size.width), Int(size.height), kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
        guard let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: 1, y: -1)
        draw(in: ctx, size: size, at: t)
        return buffer
    }

    /// `ctx` has y down.
    public static func draw(in ctx: CGContext, size: CGSize, at t: Double) {
        let w = size.width, h = size.height
        let colors = [CGColor(srgbRed: 0.10, green: 0.32, blue: 0.36, alpha: 1), CGColor(srgbRed: 0.20, green: 0.16, blue: 0.40, alpha: 1)] as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1]) {
            ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: w, y: h), options: [])
        }
        // A head and shoulders that sway, so the picture moves on every frame.
        let sway = sin(t * 2 * .pi / 3) * w * 0.06, bob = sin(t * 2 * .pi / 1.5) * h * 0.02
        ctx.setFillColor(CGColor(srgbRed: 0.93, green: 0.80, blue: 0.62, alpha: 1))
        let head = h * 0.36
        ctx.fillEllipse(in: CGRect(x: w / 2 + sway - head / 2, y: h * 0.26 + bob, width: head, height: head * 1.1))
        ctx.setFillColor(CGColor(srgbRed: 0.85, green: 0.88, blue: 0.92, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: w / 2 + sway * 0.6 - w * 0.24, y: h * 0.68, width: w * 0.48, height: h * 0.6))
        ctx.setFillColor(marker)
        ctx.fill(markerRect(size))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        func text(_ s: String, _ size: CGFloat, _ weight: NSFont.Weight, at y: CGFloat) {
            let p = NSMutableParagraphStyle()
            p.alignment = .center
            (s as NSString).draw(in: CGRect(x: 0, y: y, width: w, height: size * 1.4), withAttributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight), .foregroundColor: NSColor(white: 1, alpha: 0.92), .paragraphStyle: p])
        }
        // Low and in the middle, so a circle bubble's crop keeps it whole.
        let font = h * 0.07
        let pill = CGRect(x: w * 0.27, y: h * 0.66, width: w * 0.46, height: font * 1.6)
        ctx.setFillColor(CGColor(gray: 0, alpha: 0.6))
        ctx.addPath(CGPath(roundedRect: pill, cornerWidth: pill.height / 2, cornerHeight: pill.height / 2, transform: nil))
        ctx.fillPath()
        text(label, font, .bold, at: pill.minY + font * 0.2)
        text(SyntheticScene.timecode(t), h * 0.05, .medium, at: h * 0.84)
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// The camera's look while recording, shared by the bubble on screen and the recorder. Full-screen spans here are on the recording
/// clock; the recorder moves them onto the video's timeline when it stops.
public final class CameraLook: @unchecked Sendable {
    private let lock = NSLock()
    private var bubble: CameraBubble
    private var openSince: Double?

    public init(_ bubble: CameraBubble) {
        var b = bubble
        b.fullScreen = []
        self.bubble = b
    }

    /// The look with any running full-screen span open to the far future.
    public var current: CameraBubble {
        lock.withLock {
            var b = bubble
            if let openSince { b.fullScreen.append(CameraSpan(from: openSince, to: .infinity)) }
            return b
        }
    }

    public var isFullScreen: Bool { lock.withLock { openSince != nil } }

    public func update(_ change: (inout CameraBubble) -> Void) {
        lock.withLock {
            let spans = bubble.fullScreen
            change(&bubble)
            bubble.fullScreen = spans
        }
    }

    public func setFullScreen(_ on: Bool, at clock: Double) {
        lock.withLock {
            if on, openSince == nil { openSince = clock }
            if !on, let since = openSince {
                bubble.fullScreen.append(CameraSpan(from: since, to: clock))
                openSince = nil
            }
        }
    }
}

/// Draws the camera over screen pictures, for a recording whose camera is in the picture.
final class CameraCompositor {
    private let format: FrameFormat
    private let area: CGSize
    private var pool: CVPixelBufferPool?
    private(set) var drawn = 0

    init(format: FrameFormat, area: CGSize) {
        self.format = format; self.area = area
        CVPixelBufferPoolCreate(nil, nil, [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey: format.width,
            kCVPixelBufferHeightKey: format.height, kCVPixelBufferIOSurfacePropertiesKey: [:],
        ] as CFDictionary, &pool)
    }

    func picture(_ camera: CVPixelBuffer, bubble: CameraBubble, over frame: VideoFrame) -> VideoFrame {
        guard let placed = CameraLayout.frame(bubble, area: area, at: frame.time.seconds), let pool else { return frame }
        var image: CGImage?
        VTCreateCGImageFromCVPixelBuffer(camera, options: nil, imageOut: &image)
        guard let image else { return frame }
        var copy: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &copy)
        guard let copy else { return frame }
        let source = frame.pixels
        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(copy, [])
        defer {
            CVPixelBufferUnlockBaseAddress(copy, [])
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
        }
        guard let from = CVPixelBufferGetBaseAddress(source), let to = CVPixelBufferGetBaseAddress(copy) else { return frame }
        let fromRow = CVPixelBufferGetBytesPerRow(source), toRow = CVPixelBufferGetBytesPerRow(copy)
        let rows = min(CVPixelBufferGetHeight(source), CVPixelBufferGetHeight(copy)), bytes = min(fromRow, toRow)
        for r in 0..<rows { memcpy(to + r * toRow, from + r * fromRow, bytes) }
        guard let ctx = CGContext(data: to, width: format.width, height: format.height, bitsPerComponent: 8, bytesPerRow: toRow,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return frame }
        ctx.translateBy(x: 0, y: CGFloat(format.height))
        ctx.scaleBy(x: CGFloat(format.width) / area.width, y: -CGFloat(format.height) / area.height)
        CameraBubblePainter.draw(image, placed, in: ctx)
        drawn += 1
        return VideoFrame(pixels: copy, time: frame.time)
    }
}
