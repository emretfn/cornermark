import CoreGraphics
import Foundation

/// Canned screens and windows with no TCC involvement. `liveFrame` lets a test make the screen
/// change between `capture(displayID:)` calls, which is what scrolling capture polls.
public final class FixtureScreenSource: ScreenSource {
    public var displaySnapshots: [DisplaySnapshot]
    public var windowSnapshots: [WindowSnapshot]
    public var windowImages: [CGWindowID: CGImage] = [:]
    public var failure: CaptureFailure?
    public var liveFrame: ((_ displayID: CGDirectDisplayID, _ call: Int) -> CGImage?)?
    public var shadowMargin: CGFloat = 24
    public private(set) var liveCaptureCount = 0

    public init(displays: [DisplaySnapshot], windows: [WindowSnapshot] = []) {
        displaySnapshots = displays
        windowSnapshots = windows
    }

    public func displays() async throws -> [DisplaySnapshot] {
        if let failure { throw failure }
        return displaySnapshots
    }

    public func windows() async throws -> [WindowSnapshot] {
        if let failure { throw failure }
        return windowSnapshots
    }

    public func capture(displayID: CGDirectDisplayID) async throws -> DisplaySnapshot {
        if let failure { throw failure }
        guard var snap = displaySnapshots.first(where: { $0.displayID == displayID }) else { throw CaptureFailure.noDisplay }
        if let live = liveFrame?(displayID, liveCaptureCount) { snap.image = live }
        liveCaptureCount += 1
        return snap
    }

    public func image(of window: WindowSnapshot, options: WindowCaptureOptions) async throws -> CGImage {
        if let failure { throw failure }
        let center = CGPoint(x: window.frame.midX, y: window.frame.midY)
        guard let display = displaySnapshots.first(where: { $0.frame.contains(center) }) ?? displaySnapshots.first else {
            throw CaptureFailure.noDisplay
        }
        guard let body = windowImages[window.id] ?? ImageCrop.crop(display, rect: window.frame) else {
            throw CaptureFailure.other("Fixture window is outside every display")
        }
        guard options.includeShadow else { return body }

        let s = CGFloat(display.scale), m = shadowMargin * s
        let w = body.width + Int(2 * m), h = body.height + Int(2 * m)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return body }
        ctx.setShadow(offset: CGSize(width: 0, height: -10 * s), blur: 18 * s, color: CGColor(gray: 0, alpha: 0.55))
        ctx.draw(body, in: CGRect(x: m, y: m, width: CGFloat(body.width), height: CGFloat(body.height)))
        return ctx.makeImage() ?? body
    }
}
