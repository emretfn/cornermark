import AVFoundation
import CoreGraphics
import CornermarkCore
import Foundation

/// The camera recorded beside the screen.
public struct CameraRecording {
    public var source: CameraSource
    /// Record for Editing writes the camera to this file, on the video's timeline. Nil draws the camera into the picture.
    public var output: URL?
    public var look: CameraLook
    /// Every camera picture as it arrives, on the camera's queue, for the bubble on screen.
    public var preview: ((CVPixelBuffer) -> Void)?
    public init(source: CameraSource, output: URL?, look: CameraLook, preview: ((CVPixelBuffer) -> Void)? = nil) {
        self.source = source; self.output = output; self.look = look; self.preview = preview
    }
}

/// One recording, from the first frame to the finished file. The pointer, clicks and keys, when watched, are kept as tracks beside the video.
public final class Recorder {
    public let output: URL
    /// Only recent events can still show: a ring lasts under a second, and a badge shows at most its last characters.
    private static let recentClicks = 32
    private static let recentKeys = 2 * KeystrokeDisplay.maxCharacters
    private let source: FrameSource
    private let pointer: PointerSource?
    private let input: InputSource?
    private let marks: InputMarks?
    private let quality: VideoQuality
    private let camera: CameraRecording?
    private var writer: RecordingWriter?
    /// Camera state, guarded by `pictureLock`, which also keeps the frames reaching the writers in time order.
    private let pictureLock = NSLock()
    private var cameraWriter: RecordingWriter?
    private var cameraCompositor: CameraCompositor?
    private var latestCamera: CVPixelBuffer?
    private var blankCamera: CVPixelBuffer?
    private var lastScreen: VideoFrame?
    private var lastScreenTime = -Double.infinity
    private var lastEmitted = -Double.infinity
    private var cameraPictures = 0
    private var cameraFills = 0
    /// Why the camera is not recorded, when one was asked for and could not start.
    public private(set) var cameraFailure: CameraUnavailable?
    public var cameraInPicture: Bool { pictureLock.withLock { cameraCompositor != nil } }
    private var compositor: InputCompositor?
    private var track = PointerTrackBuilder()
    private var clicks: [ClickEvent] = []
    private var keys: [KeyEvent] = []
    private let trackLock = NSLock()
    public var marksInPicture: Bool { marks != nil }
    /// Why clicks and keys are not watched, when an input source was given and could not start.
    public private(set) var inputFailure: InputUnavailable?
    /// Pictures that carry click or key marks, and how many of them filled a gap in the stream.
    public var markedFrames: (marked: Int, filled: Int) { trackLock.withLock { (compositor?.marked ?? 0, compositor?.filled ?? 0) } }
    public private(set) var format: FrameFormat?
    /// What the pictures show, in global AppKit points. Valid once `start` returns.
    public var pointArea: CGRect { source.pointArea }
    /// The length of the video so far. A pause does not grow it.
    public var seconds: Double { writer?.seconds ?? 0 }

    public init(source: FrameSource, output: URL, pointer: PointerSource? = nil, input: InputSource? = nil, marks: InputMarks? = nil,
                camera: CameraRecording? = nil, quality: VideoQuality = .high) {
        self.source = source
        self.output = output
        self.pointer = pointer
        self.input = input
        self.marks = marks.flatMap { $0.isVisible ? $0 : nil }
        self.quality = quality
        self.camera = camera
    }

    public var onFailure: ((Error) -> Void)? {
        get { source.onFailure }
        set { source.onFailure = newValue }
    }

    public func start() async throws {
        let format = try await source.prepare()
        let writer = try RecordingWriter(url: output, format: format, realTime: source.deliversInRealTime, quality: quality)
        self.format = format
        self.writer = writer
        pointer?.start(in: source.pointArea) { [weak self] reading in
            guard let self else { return }
            self.trackLock.withLock { self.track.add(time: reading.time, x: reading.x, y: reading.y) }
        }
        do {
            try input?.start(in: source.pointArea) { [weak self] reading in
                guard let self else { return }
                self.trackLock.withLock {
                    switch reading {
                    case .click(let c): self.clicks.append(c)
                    case .key(let k): self.keys.append(k)
                    }
                }
            }
        } catch {
            inputFailure = error as? InputUnavailable ?? .tapFailed
        }
        if let marks { compositor = InputCompositor(marks: marks, format: format, area: source.pointArea.size) }
        startCamera(format)
        do {
            try await source.start { [weak self] frame in
                guard let self else { return }
                self.pictureLock.withLock {
                    if self.camera != nil {
                        self.lastScreen = frame
                        self.lastScreenTime = frame.time.seconds
                    }
                    self.emit(frame)
                }
            }
        } catch {
            input?.stop()
            pointer?.stop()
            stopCamera()
            cameraWriter?.cancel()
            cameraWriter = nil
            writer.cancel()
            self.writer = nil
            throw error
        }
    }

    /// The camera starts before the pictures, so the first frame already has the camera's picture.
    private func startCamera(_ format: FrameFormat) {
        guard let camera else { return }
        let size = camera.source.pixelSize
        do {
            if let output = camera.output {
                let cameraFormat = FrameFormat(width: Int(size.width), height: Int(size.height), fps: format.fps)
                cameraWriter = try RecordingWriter(url: output, format: cameraFormat, realTime: source.deliversInRealTime, quality: quality)
                blankCamera = SyntheticCamera.blank(cameraFormat)
            } else {
                cameraCompositor = CameraCompositor(format: format, area: source.pointArea.size)
            }
            try camera.source.start { [weak self] picture in self?.cameraArrived(picture) }
        } catch {
            cameraFailure = error as? CameraUnavailable ?? .failed(String(describing: error))
            cameraWriter?.cancel()
            pictureLock.withLock {
                cameraWriter = nil
                cameraCompositor = nil
            }
        }
    }

    private func stopCamera() { camera?.source.stop() }

    /// A live stream sends nothing while the screen is still, which would freeze the camera with it. A camera picture that comes after
    /// the screen has been quiet this long makes a frame of its own from the last screen picture.
    private var quietScreen: Double { max(3.0 / Double(format?.fps ?? 60), 0.05) }

    private func cameraArrived(_ picture: CameraPicture) {
        camera?.preview?(picture.pixels)
        pictureLock.withLock {
            cameraPictures += 1
            latestCamera = picture.pixels
            guard let last = lastScreen, picture.time - lastScreenTime > quietScreen, picture.time > lastEmitted else { return }
            cameraFills += 1
            emit(VideoFrame(pixels: last.pixels, time: CMTime(seconds: picture.time, preferredTimescale: 600_000)))
        }
    }

    /// Sends one picture to the file, and the camera's picture at the same moment to the camera's file, so both share a timeline.
    /// Called with `pictureLock` held.
    private func emit(_ frame: VideoFrame) {
        guard let writer else { return }
        if camera != nil {
            guard frame.time.seconds > lastEmitted else { return }
            lastEmitted = frame.time.seconds
        }
        var picture = frame
        if let cameraCompositor, let latestCamera, let look = camera?.look.current {
            picture = cameraCompositor.picture(latestCamera, bubble: look, over: frame)
        }
        if let cameraWriter, let pixels = latestCamera ?? blankCamera { cameraWriter.append(VideoFrame(pixels: pixels, time: frame.time)) }
        guard compositor != nil else { return writer.append(picture) }
        let pictures = trackLock.withLock {
            compositor?.pictures(for: picture, clicks: Array(clicks.suffix(Self.recentClicks)), keys: Array(keys.suffix(Self.recentKeys))) ?? [picture]
        }
        pictures.forEach(writer.append)
    }

    public func pause() {
        pictureLock.withLock {
            writer?.pause()
            cameraWriter?.pause()
        }
        trackLock.withLock { compositor?.forget() }
    }

    public func resume() {
        pictureLock.withLock {
            writer?.resume()
            cameraWriter?.resume()
        }
    }

    public func stop() async throws -> RecordingReport {
        await source.stop()
        pointer?.stop()
        input?.stop()
        stopCamera()
        guard let writer else { throw RecordingError.noFrames }
        let cameraWriter = pictureLock.withLock { () -> RecordingWriter? in
            self.writer = nil
            defer { self.cameraWriter = nil }
            return self.cameraWriter
        }
        var report: RecordingReport
        do { report = try await writer.finish() } catch {
            cameraWriter?.cancel()
            throw error
        }
        report.area = source.pointArea
        let paused = report.pauses.reduce(0) { $0 + $1.to - $1.from }
        let samples = trackLock.withLock {
            track.samples(firstFrameTime: report.firstFrameTime, lastTime: report.firstFrameTime + report.duration + paused)
        }
        report.pointer = samples.compactMap { s in
            RecordingPause.videoTime(s.t, skipping: report.pauses).map { PointerSample(t: $0, x: s.x, y: s.y) }
        }
        let (rawClicks, rawKeys) = trackLock.withLock { (clicks, keys) }
        let end = report.duration + paused
        func videoTime(_ t: Double) -> Double? {
            let since = t - report.firstFrameTime
            guard since >= 0, since <= end else { return nil }
            return RecordingPause.videoTime(since, skipping: report.pauses)
        }
        report.clicks = rawClicks.compactMap { c in videoTime(c.t).map { ClickEvent(t: $0, x: c.x, y: c.y) } }
        report.keys = rawKeys.compactMap { k in videoTime(k.t).map { KeyEvent(t: $0, label: k.label, isCommand: k.isCommand) } }
        if let camera, cameraFailure == nil {
            var file: URL?
            if let cameraWriter {
                do { file = try await cameraWriter.finish().url } catch {
                    cameraFailure = .failed(String(describing: error))
                }
            }
            if cameraFailure == nil {
                var bubble = camera.look.current
                bubble.fullScreen = CameraSpans.onVideo(bubble.fullScreen, firstFrame: report.firstFrameTime, end: end, pauses: report.pauses)
                let (pictures, filled) = pictureLock.withLock { (cameraPictures, cameraFills) }
                report.camera = CameraTrackReport(file: file, pictures: pictures, filled: filled, bubble: bubble)
            }
        }
        return report
    }

    /// Ends the recording and deletes its file.
    public func cancel() async {
        await source.stop()
        pointer?.stop()
        input?.stop()
        stopCamera()
        pictureLock.withLock {
            writer?.cancel()
            writer = nil
            cameraWriter?.cancel()
            cameraWriter = nil
        }
    }
}

public enum CameraSpans {
    /// Spans on the source clock as spans of the video: an end inside a pause moves to where the pause began, an end past the
    /// recording to its end, and a span left with no length is dropped.
    public static func onVideo(_ spans: [CameraSpan], firstFrame: Double, end: Double, pauses: [RecordingPause]) -> [CameraSpan] {
        func place(_ t: Double) -> Double {
            var since = min(max(t - firstFrame, 0), end)
            if let p = pauses.first(where: { since > $0.from && since < $0.to }) { since = p.from }
            return RecordingPause.videoTime(since, skipping: pauses) ?? 0
        }
        return spans.map { CameraSpan(from: place($0.from), to: place($0.to)) }.filter { $0.to > $0.from }
    }
}
