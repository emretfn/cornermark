import AppKit
import AVFoundation
import CornermarkCore
import CornermarkDesign

public struct InputMarks: Equatable {
    public var clicks: ClickHighlight
    public var keystrokes: KeystrokeDisplay
    public init(clicks: ClickHighlight, keystrokes: KeystrokeDisplay) { self.clicks = clicks; self.keystrokes = keystrokes }
    public var isVisible: Bool { clicks.isVisible || keystrokes.isVisible }
}

extension InputOverlayInk {
    /// Red, orange and green are the image editor's annotation swatches, not the status tokens: a ring means a click, never danger,
    /// warning or success.
    public static let design: InputOverlayInk = {
        func resolve(_ color: NSColor, _ name: NSAppearance.Name = .darkAqua) -> CGColor {
            var out = CGColor(gray: 1, alpha: 1)
            NSAppearance(named: name)?.performAsCurrentDrawingAppearance { out = color.cgColor }
            return out
        }
        let clicks: [ClickHighlight.Color: CGColor] = [
            .lemon: resolve(DS.Color.accentSolid), .white: resolve(DS.Color.selectionStroke),
            .red: CGColor(srgbRed: 0xE5 / 255, green: 0x30 / 255, blue: 0x3A / 255, alpha: 1),
            .orange: CGColor(srgbRed: 0xF2 / 255, green: 0x8C / 255, blue: 0x28 / 255, alpha: 1),
            .green: CGColor(srgbRed: 0x2F / 255, green: 0xBF / 255, blue: 0x5B / 255, alpha: 1),
        ]
        let dark = (fill: resolve(DS.Color.bgHud), text: resolve(DS.Color.textPrimary), border: resolve(DS.Color.borderSubtle))
        let light = (fill: resolve(DS.Color.bgRaised, .aqua), text: resolve(DS.Color.textPrimary, .aqua), border: resolve(DS.Color.border, .aqua))
        return InputOverlayInk(
            click: { clicks[$0] ?? CGColor(gray: 1, alpha: 1) }, halo: resolve(DS.Color.selectionHalo),
            badgeFill: { $0 == .dark ? dark.fill : light.fill }, badgeText: { $0 == .dark ? dark.text : light.text },
            badgeBorder: { $0 == .dark ? dark.border : light.border })
    }()
}

/// A live stream sends no picture while the screen is still, so a mark would freeze there. After a gap, the last clean picture is
/// repeated for each missed slot in which the marks changed.
final class InputCompositor {
    private let marks: InputMarks
    private let ink: InputOverlayInk
    private let format: FrameFormat
    private let area: CGSize
    private var pool: CVPixelBufferPool?
    private var lastClean: VideoFrame?
    private var lastShown = InputOverlayState()
    private(set) var marked = 0
    private(set) var filled = 0

    init(marks: InputMarks, format: FrameFormat, area: CGSize, ink: InputOverlayInk = .design) {
        self.marks = marks; self.format = format; self.area = area; self.ink = ink
        CVPixelBufferPoolCreate(nil, nil, [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey: format.width,
            kCVPixelBufferHeightKey: format.height, kCVPixelBufferIOSurfacePropertiesKey: [:],
        ] as CFDictionary, &pool)
    }

    func pictures(for frame: VideoFrame, clicks: [ClickEvent], keys: [KeyEvent]) -> [VideoFrame] {
        var out: [VideoFrame] = []
        let step = 1 / Double(format.fps), now = frame.time.seconds
        if let last = lastClean {
            var slot = last.time.seconds + step
            while slot < now - step / 2 {
                let state = self.state(clicks, keys, at: slot)
                if state != lastShown {
                    out.append(VideoFrame(pixels: draw(state, over: last.pixels), time: CMTime(seconds: slot, preferredTimescale: 600_000)))
                    filled += 1
                    lastShown = state
                }
                slot += step
            }
        }
        let state = self.state(clicks, keys, at: now)
        out.append(VideoFrame(pixels: draw(state, over: frame.pixels), time: frame.time))
        lastShown = state
        lastClean = frame
        return out
    }

    func forget() { lastClean = nil }

    private func state(_ clicks: [ClickEvent], _ keys: [KeyEvent], at t: Double) -> InputOverlayState {
        InputOverlay.state(clicks: clicks, keys: keys, highlight: marks.clicks, keystrokes: marks.keystrokes, at: t)
    }

    private func draw(_ state: InputOverlayState, over source: CVPixelBuffer) -> CVPixelBuffer {
        guard !state.isEmpty, let pool else { return source }
        var copy: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &copy)
        guard let copy else { return source }
        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(copy, [])
        defer {
            CVPixelBufferUnlockBaseAddress(copy, [])
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
        }
        guard let from = CVPixelBufferGetBaseAddress(source), let to = CVPixelBufferGetBaseAddress(copy) else { return source }
        let fromRow = CVPixelBufferGetBytesPerRow(source), toRow = CVPixelBufferGetBytesPerRow(copy)
        let rows = min(CVPixelBufferGetHeight(source), CVPixelBufferGetHeight(copy)), bytes = min(fromRow, toRow)
        for r in 0..<rows { memcpy(to + r * toRow, from + r * fromRow, bytes) }
        guard let ctx = CGContext(data: to, width: format.width, height: format.height, bitsPerComponent: 8, bytesPerRow: toRow,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return source }
        ctx.translateBy(x: 0, y: CGFloat(format.height))
        ctx.scaleBy(x: CGFloat(format.width) / area.width, y: -CGFloat(format.height) / area.height)
        InputOverlayPainter.draw(state, area: area, highlight: marks.clicks, keystrokes: marks.keystrokes, ink: ink, in: ctx)
        marked += 1
        return copy
    }
}
