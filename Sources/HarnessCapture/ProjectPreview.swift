import AppKit
import AVFoundation
import CornermarkCapture
import CornermarkCore
import CryptoKit

/// Throwaway verification renderer, not the export. It draws a stored recording frame by frame from `frameState` so a human can see that
/// the pointer is a layer over an untouched video. The export pipeline is a later step and will replace this.
///
/// `CORNERMARK_PROJECT_PREVIEW=<project folder>` and `CORNERMARK_PROJECT_PREVIEW_OUT=<folder to write E1.mp4 and C8.mp4 into>`.
enum ProjectPreview {
    enum Layout {
        /// The source as stored, the same recording with a small pointer, and with a large one.
        case editsSideBySide
        /// The source as stored, the pointer track on its own, and the two together.
        case layers
    }

    static let panel = CGSize(width: 480, height: 270)
    static let headerHeight = 66, footerHeight = 54, captionHeight = 30

    static func sha256(of url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    @MainActor
    static func run(project folder: URL, out: URL) async -> Bool {
        do {
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            let project = try RecordingProjectFile.read(from: folder)
            let video = folder.appendingPathComponent(project.source.video)
            let before = try sha256(of: video)
            print("source \(video.lastPathComponent) sha256 before \(before)")
            print("project: \(project.source.pixelWidth)x\(project.source.pixelHeight)px, \(project.source.duration) s, \(project.events.pointer.count) pointer samples")
            for (name, layout, title) in [("E1", Layout.editsSideBySide, "E1  one recording, edited without touching the source"),
                                          ("C8", Layout.layers, "C8  the pointer is a separate layer, not part of the video")] {
                let url = out.appendingPathComponent("\(name).mp4")
                let source = PreviewFrameSource(project: project, video: video, layout: layout, title: title, hashBefore: before)
                let recorder = Recorder(source: source, output: url)
                try await recorder.start()
                let report = try await recorder.stop()
                print("\(name): \(report.framesWritten) frames, \(report.format.width)x\(report.format.height), \(report.duration) s -> \(url.path)")
            }
            let after = try sha256(of: video)
            print("source \(video.lastPathComponent) sha256 after  \(after)")
            return before == after
        } catch {
            print("FAIL preview: \(error)")
            return false
        }
    }
}

private final class PreviewFrameSource: FrameSource {
    var onFailure: ((Error) -> Void)?
    let deliversInRealTime = false
    var pointArea: CGRect { .zero }
    private let project: RecordingProject
    private let video: URL
    private let layout: ProjectPreview.Layout
    private let title: String
    private let hashBefore: String
    private let fps = 60
    private let width = Int(ProjectPreview.panel.width) * 3
    private let height = ProjectPreview.headerHeight + Int(ProjectPreview.panel.height) + ProjectPreview.captionHeight + ProjectPreview.footerHeight

    init(project: RecordingProject, video: URL, layout: ProjectPreview.Layout, title: String, hashBefore: String) {
        self.project = project; self.video = video; self.layout = layout; self.title = title; self.hashBefore = hashBefore
    }

    func prepare() async throws -> FrameFormat { FrameFormat(width: width, height: height, fps: fps) }
    func stop() async {}

    func start(_ deliver: @escaping (VideoFrame) -> Void) async throws {
        let asset = AVURLAsset(url: video)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw RecordingError.noFrames }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output)
        reader.startReading()
        var pending: (time: Double, image: CGImage)?
        var current: (time: Double, image: CGImage)?
        func next() -> (Double, CGImage)? {
            while let sample = output.copyNextSampleBuffer() {
                guard let buffer = CMSampleBufferGetImageBuffer(sample), CMSampleBufferGetNumSamples(sample) > 0 else { continue }
                return (CMSampleBufferGetPresentationTimeStamp(sample).seconds, Self.image(of: buffer))
            }
            return nil
        }
        pending = next()

        let hidden = Self.variant(project, CursorSettings(isVisible: false))
        let small = Self.variant(project, CursorSettings(isVisible: true, scale: 2))
        let large = Self.variant(project, CursorSettings(isVisible: true, scale: 5))
        let composite = Self.variant(project, CursorSettings(isVisible: true, scale: 3))
        let total = Int((project.source.duration * Double(fps)).rounded(.down))
        let hold = fps * 2
        var hashAfter: String?

        for k in 0..<(total + hold) {
            let outputTime = Double(min(k, total - 1)) / Double(fps)
            let time = CMTime(value: CMTimeValue(k), timescale: CMTimeScale(fps))
            let state = frameState(hidden, outputTime: outputTime)
            if k < total {
                while let p = pending, p.time <= state.sourceTime + 1e-9 { current = (p.time, p.image); pending = next() }
                if current == nil, let p = pending { current = (p.time, p.image) }
            } else if hashAfter == nil {
                hashAfter = try ProjectPreview.sha256(of: video)
            }
            guard let image = current?.image else { throw RecordingError.noFrames }
            let panels: [(String, FrameState, ProjectPreview.PanelKind)]
            switch layout {
            case .editsSideBySide:
                panels = [("the source file, as recorded", frameState(hidden, outputTime: outputTime), .picture),
                          ("edit A: pointer shown, size 2", frameState(small, outputTime: outputTime), .picture),
                          ("edit B: pointer shown, size 5", frameState(large, outputTime: outputTime), .picture)]
            case .layers:
                panels = [("video layer: no pointer in it", frameState(hidden, outputTime: outputTime), .picture),
                          ("pointer layer: the stored track", frameState(composite, outputTime: outputTime), .track),
                          ("both layers, composed now", frameState(composite, outputTime: outputTime), .picture)]
            }
            let footer = "screen.mp4 sha256 before rendering: \(hashBefore.prefix(32))...   after: " + (hashAfter.map { "\($0.prefix(32))...  " + ($0 == hashBefore ? "IDENTICAL" : "CHANGED") } ?? "read at the end of this video")
            let header = "\(title)     t = " + String(format: "%.3f", outputTime) + " s" + (k >= total ? "   (end)" : "")
            let pixels = try render(image: image, panels: panels, header: header, footer: footer)
            deliver(VideoFrame(pixels: pixels, time: time))
        }
    }

    static func variant(_ project: RecordingProject, _ cursor: CursorSettings) -> RecordingProject {
        var copy = project
        copy.edits.cursor = cursor
        return copy
    }

    static func image(of buffer: CVPixelBuffer) -> CGImage {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer),
                            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        return ctx.makeImage()!
    }

    private func render(image: CGImage, panels: [(String, FrameState, ProjectPreview.PanelKind)], header: String, footer: String) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
        guard let buffer else { throw RecordingError.source("Could not allocate a frame") }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { throw RecordingError.source("Could not draw a frame") }
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        defer { NSGraphicsContext.restoreGraphicsState() }

        NSColor(white: 0.07, alpha: 1).setFill()
        NSBezierPath.fill(CGRect(x: 0, y: 0, width: width, height: height))
        Self.text(header, in: CGRect(x: 12, y: 18, width: CGFloat(width) - 24, height: 30), size: 20, weight: .semibold, white: 0.95)
        let pw = ProjectPreview.panel.width, ph = ProjectPreview.panel.height
        let top = CGFloat(ProjectPreview.headerHeight)
        for (i, panel) in panels.enumerated() {
            let frame = CGRect(x: CGFloat(i) * pw, y: top, width: pw, height: ph)
            ctx.saveGState()
            ctx.clip(to: frame)
            ctx.translateBy(x: frame.minX, y: frame.minY)
            switch panel.2 {
            case .picture:
                ctx.saveGState()
                ctx.translateBy(x: 0, y: ph)
                ctx.scaleBy(x: 1, y: -1)
                ctx.interpolationQuality = .none
                ctx.draw(image, in: CGRect(origin: .zero, size: ProjectPreview.panel))
                ctx.restoreGState()
            case .track:
                NSColor(srgbRed: 0.12, green: 0.13, blue: 0.16, alpha: 1).setFill()
                NSBezierPath.fill(CGRect(origin: .zero, size: ProjectPreview.panel))
                drawTrack(ctx, upTo: panel.1.sourceTime)
            }
            if let cursor = panel.1.cursor { drawCursor(ctx, cursor) }
            ctx.restoreGState()
            Self.text(panel.0, in: CGRect(x: frame.minX + 8, y: frame.maxY + 6, width: pw - 16, height: 22), size: 14, weight: .medium, white: 0.85)
            NSColor(white: 0.07, alpha: 1).setFill()
            NSBezierPath.fill(CGRect(x: frame.maxX - 1, y: top, width: 2, height: ph))
        }
        Self.text(footer, in: CGRect(x: 12, y: top + ph + CGFloat(ProjectPreview.captionHeight) + 12, width: CGFloat(width) - 24, height: 24), size: 13, weight: .regular, white: 0.7)
        return buffer
    }

    /// Scale from the project's points to this panel's pixels.
    private var pointScale: CGFloat {
        project.source.pointWidth > 0 ? ProjectPreview.panel.width / CGFloat(project.source.pointWidth) : 1
    }

    private func drawTrack(_ ctx: CGContext, upTo time: Double) {
        let samples = project.events.pointer
        guard samples.count > 1 else { return }
        let k = pointScale
        ctx.setLineWidth(1.5)
        ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.18))
        ctx.beginPath()
        ctx.move(to: CGPoint(x: samples[0].x * k, y: samples[0].y * k))
        for s in samples.dropFirst() { ctx.addLine(to: CGPoint(x: s.x * k, y: s.y * k)) }
        ctx.strokePath()
        ctx.setStrokeColor(CGColor(srgbRed: 0.4, green: 0.8, blue: 1, alpha: 0.9))
        ctx.setLineWidth(2)
        ctx.beginPath()
        var started = false
        for s in samples where s.t <= time {
            let p = CGPoint(x: s.x * k, y: s.y * k)
            if started { ctx.addLine(to: p) } else { ctx.move(to: p); started = true }
        }
        ctx.strokePath()
    }

    private static let arrow: [CGPoint] = [(0, 0), (0, 16), (4, 12.5), (7, 19), (9.5, 18), (6.6, 11.6), (11.5, 11.6)].map { CGPoint(x: $0.0, y: $0.1) }

    private func drawCursor(_ ctx: CGContext, _ cursor: CursorFrame) {
        ctx.saveGState()
        ctx.translateBy(x: cursor.x * pointScale, y: cursor.y * pointScale)
        ctx.scaleBy(x: cursor.scale * pointScale, y: cursor.scale * pointScale)
        ctx.beginPath()
        ctx.addLines(between: Self.arrow)
        ctx.closePath()
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.setStrokeColor(CGColor(gray: 0, alpha: 1))
        ctx.setLineWidth(1.2)
        ctx.setLineJoin(.round)
        ctx.drawPath(using: .fillStroke)
        ctx.restoreGState()
    }

    private static func text(_ string: String, in rect: CGRect, size: CGFloat, weight: NSFont.Weight, white: CGFloat) {
        (string as NSString).draw(in: rect, withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: NSColor(white: white, alpha: 1)])
    }
}

extension ProjectPreview {
    enum PanelKind { case picture, track }
}
