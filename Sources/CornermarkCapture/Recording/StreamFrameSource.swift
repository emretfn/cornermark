import AppKit
import AVFoundation
import ScreenCaptureKit

/// The live source. The cursor is part of the picture only when asked, because a project stores it as its own track.
public final class StreamFrameSource: NSObject, FrameSource, SCStreamOutput, SCStreamDelegate {
    public var onFailure: ((Error) -> Void)?
    public let deliversInRealTime = true
    private let target: RecordingTarget
    private let options: RecordingOptions
    private let queue = DispatchQueue(label: "cornermark.stream-frames", qos: .userInteractive)
    private let audioQueue = DispatchQueue(label: "cornermark.stream-audio", qos: .userInteractive)
    /// What the Mac plays, when the options ask for it. It needs only Screen Recording, no audio driver.
    public let systemAudio = StreamAudio()
    /// The running stream and the recorder's handler, shared with the sample queue and the delegate callback.
    private let link = StreamLink<SCStream>()
    private var prepared: (filter: SCContentFilter, config: SCStreamConfiguration, format: FrameFormat)?
    private var display: SCDisplay?
    private var refresh: Task<Void, Never>?
    private var tracker: ExclusionTracker?
    public private(set) var pointArea = CGRect.zero

    public init(target: RecordingTarget, options: RecordingOptions) {
        self.target = target
        self.options = options
    }

    public func prepare() async throws -> FrameFormat {
        let content = try await Self.content()
        let config = SCStreamConfiguration()
        config.showsCursor = options.showsCursor
        config.capturesAudio = options.capturesSystemAudio
        if options.capturesSystemAudio {
            config.excludesCurrentProcessAudio = true
            config.sampleRate = 48_000
            config.channelCount = 2
        }
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        // The stream spaces frames about a millisecond wider than asked. Measured on a 120 Hz display, asking for exactly 1/60 s
        // delivered 57 frames a second, and 8% headroom delivered 60.
        config.minimumFrameInterval = CMTime(seconds: 0.92 / Double(options.fps), preferredTimescale: 60_000)
        config.queueDepth = 6
        let filter: SCContentFilter
        let format: FrameFormat
        var plan: ContentExclusion.Plan?

        switch target {
        case .window(let id):
            guard let window = content.windows.first(where: { $0.windowID == id }) else { throw RecordingError.windowNotFound(id) }
            filter = SCContentFilter(desktopIndependentWindow: window)
            format = StreamGeometry.format(of: filter.contentRect, scale: Double(filter.pointPixelScale), options: options)
            // A window's frame is in Quartz global points, with the origin at the top-left of the main display.
            pointArea = CGRect(x: window.frame.minX, y: CGDisplayBounds(CGMainDisplayID()).height - window.frame.maxY,
                               width: window.frame.width, height: window.frame.height)
        case .display(let requested, let area):
            guard let display = Self.display(requested, area: area, in: content) else { throw RecordingError.displayNotFound }
            (filter, plan) = Self.filter(display, content, options.exclusion)
            self.display = display
            let frame = Self.appKitFrame(of: display.displayID)
            guard let rect = StreamGeometry.sourceRect(area: area ?? frame, displayFrame: frame) else { throw RecordingError.displayNotFound }
            format = StreamGeometry.format(of: rect, scale: Double(filter.pointPixelScale), options: options)
            pointArea = CGRect(x: rect.minX + frame.minX, y: frame.maxY - rect.maxY, width: rect.width, height: rect.height)
            if area != nil { config.sourceRect = rect }
        }
        config.width = format.width
        config.height = format.height
        tracker = plan.map { ExclusionTracker(exclusion: options.exclusion, plan: $0, ownPID: ProcessInfo.processInfo.processIdentifier) }
        prepared = (filter, config, format)
        return format
    }

    public func start(_ deliver: @escaping (VideoFrame) -> Void) async throws {
        if prepared == nil { _ = try await prepare() }
        guard let prepared else { throw RecordingError.source("Nothing prepared") }
        link.open(deliver)
        let stream = SCStream(filter: prepared.filter, configuration: prepared.config, delegate: self)
        do {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            if options.capturesSystemAudio { try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue) }
            try await stream.startCapture()
        } catch {
            _ = link.close()
            throw Self.map(error)
        }
        link.attach(stream)
        // A filter can exclude only an application the stream was handed as an object, never a bundle identifier. Notification Center
        // may have had no window when the stream was prepared, and a Finder window may open mid-recording, so the list is looked at again.
        if let display, let tracker, options.exclusion.needsRefresh {
            refresh = Task { [weak self] in await self?.refreshFilter(stream, display, tracker) }
        }
    }

    /// Looks once a second and replaces the filter only when the plan changed. A failed replacement is tried again at the next look.
    private func refreshFilter(_ stream: SCStream, _ display: SCDisplay, _ initial: ExclusionTracker) async {
        var tracker = initial
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled, let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false) else { continue }
            let before = tracker
            let (apps, windows) = Self.snapshot(content)
            guard !Task.isCancelled, tracker.observe(apps: apps, windows: windows) != nil else { continue }
            do { try await stream.updateContentFilter(Self.filter(display, content, tracker.plan)) } catch { tracker = before }
        }
    }

    private static func snapshot(_ content: SCShareableContent) -> ([ContentExclusion.App], [ContentExclusion.Window]) {
        let apps = content.applications.map { ContentExclusion.App(pid: $0.processID, bundleID: $0.bundleIdentifier) }
        let windows = content.windows.compactMap { w in
            w.owningApplication.map { ContentExclusion.Window(id: w.windowID, ownerPID: $0.processID, layer: w.windowLayer) }
        }
        return (apps, windows)
    }

    /// The exclusion plan as a content filter: excluded applications, and the windows of theirs that are filmed anyway.
    static func filter(_ display: SCDisplay, _ content: SCShareableContent, _ exclusion: ContentExclusion) -> (SCContentFilter, ContentExclusion.Plan) {
        let (apps, windows) = snapshot(content)
        let plan = exclusion.plan(apps: apps, windows: windows, ownPID: ProcessInfo.processInfo.processIdentifier)
        return (filter(display, content, plan), plan)
    }

    private static func filter(_ display: SCDisplay, _ content: SCShareableContent, _ plan: ContentExclusion.Plan) -> SCContentFilter {
        SCContentFilter(display: display, excludingApplications: content.applications.filter { plan.excludedApps.contains($0.processID) },
                        exceptingWindows: content.windows.filter { plan.exceptedWindows.contains($0.windowID) })
    }

    public func stop() async {
        refresh?.cancel()
        refresh = nil
        guard let stream = link.close() else { return }
        try? await stream.stopCapture()
    }

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        if type == .audio { return systemAudio.receive(sampleBuffer) }
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        link.send(VideoFrame(pixels: pixels, time: sampleBuffer.presentationTimeStamp))
    }

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        guard link.fail() != nil else { return }
        onFailure?(Self.map(error))
    }

    private static func content() async throws -> SCShareableContent {
        var last: Error?
        for _ in 0..<5 {
            do { return try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false) } catch {
                last = error
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
        throw map(last!)
    }

    private static func display(_ id: CGDirectDisplayID?, area: CGRect?, in content: SCShareableContent) -> SCDisplay? {
        if let id { return content.displays.first { $0.displayID == id } }
        if let area {
            let best = content.displays.max { lhs, rhs in
                area.intersection(appKitFrame(of: lhs.displayID)).area < area.intersection(appKitFrame(of: rhs.displayID)).area
            }
            if let best, area.intersection(appKitFrame(of: best.displayID)).area > 0 { return best }
        }
        return content.displays.first { $0.displayID == CGMainDisplayID() } ?? content.displays.first
    }

    private static func appKitFrame(of id: CGDirectDisplayID) -> CGRect {
        let bounds = CGDisplayBounds(id)
        return CGRect(x: bounds.minX, y: CGDisplayBounds(CGMainDisplayID()).height - bounds.maxY, width: bounds.width, height: bounds.height)
    }

    private static func map(_ error: Error) -> RecordingError {
        if let known = error as? RecordingError { return known }
        if let sc = error as? SCStreamError, sc.code == .userDeclined { return .permissionDenied }
        return .source(error.localizedDescription)
    }
}

/// The stream's sound as an audio source. The stream itself starts and stops it, so `start` only says where chunks go.
public final class StreamAudio: AudioSource {
    private let lock = NSLock()
    private var deliver: ((AudioChunk) -> Void)?

    public func start(_ deliver: @escaping (AudioChunk) -> Void) throws { lock.withLock { self.deliver = deliver } }
    public func stop() { lock.withLock { deliver = nil } }

    /// The stream stamps sound and pictures on the host clock, which is the recording clock.
    func receive(_ sample: CMSampleBuffer) {
        guard sample.isValid, let deliver = lock.withLock({ self.deliver }), let chunk = AudioChunk(sample, clock: { $0.seconds }) else { return }
        deliver(chunk)
    }
}

private extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}
