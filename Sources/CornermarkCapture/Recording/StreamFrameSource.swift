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
    private var stream: SCStream?
    private var prepared: (filter: SCContentFilter, config: SCStreamConfiguration, format: FrameFormat)?
    private var deliver: ((VideoFrame) -> Void)?
    private var display: SCDisplay?
    private var refresh: Task<Void, Never>?
    private var plan: ContentExclusion.Plan?
    public private(set) var pointArea = CGRect.zero

    public init(target: RecordingTarget, options: RecordingOptions) {
        self.target = target
        self.options = options
    }

    public func prepare() async throws -> FrameFormat {
        let content = try await Self.content()
        let config = SCStreamConfiguration()
        config.showsCursor = options.showsCursor
        config.capturesAudio = false
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
        self.plan = plan
        prepared = (filter, config, format)
        return format
    }

    public func start(_ deliver: @escaping (VideoFrame) -> Void) async throws {
        if prepared == nil { _ = try await prepare() }
        guard let prepared else { throw RecordingError.source("Nothing prepared") }
        self.deliver = deliver
        let stream = SCStream(filter: prepared.filter, configuration: prepared.config, delegate: self)
        do {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            try await stream.startCapture()
        } catch {
            throw Self.map(error)
        }
        self.stream = stream
        // Finder windows are filmed by name while desktop icons are hidden, so one opened mid-recording joins the filter here.
        if display != nil, options.exclusion.hidesDesktopIcons { refresh = Task { [weak self] in await self?.refreshFilter() } }
    }

    private func refreshFilter() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard let stream, let display, let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false) else { continue }
            let (next, plan) = Self.filter(display, content, options.exclusion)
            guard plan != self.plan else { continue }
            try? await stream.updateContentFilter(next)
            self.plan = plan
        }
    }

    /// The exclusion plan as a content filter: excluded applications, and the windows of theirs that are filmed anyway.
    static func filter(_ display: SCDisplay, _ content: SCShareableContent, _ exclusion: ContentExclusion) -> (SCContentFilter, ContentExclusion.Plan) {
        let apps = content.applications.map { ContentExclusion.App(pid: $0.processID, bundleID: $0.bundleIdentifier) }
        let windows = content.windows.compactMap { w in
            w.owningApplication.map { ContentExclusion.Window(id: w.windowID, ownerPID: $0.processID, layer: w.windowLayer) }
        }
        let plan = exclusion.plan(apps: apps, windows: windows, ownPID: ProcessInfo.processInfo.processIdentifier)
        let filter = SCContentFilter(display: display, excludingApplications: content.applications.filter { plan.excludedApps.contains($0.processID) },
                                     exceptingWindows: content.windows.filter { plan.exceptedWindows.contains($0.windowID) })
        return (filter, plan)
    }

    public func stop() async {
        refresh?.cancel()
        refresh = nil
        deliver = nil
        guard let stream else { return }
        self.stream = nil
        try? await stream.stopCapture()
    }

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        deliver?(VideoFrame(pixels: pixels, time: sampleBuffer.presentationTimeStamp))
    }

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        guard self.stream != nil else { return }
        self.stream = nil
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

private extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}
