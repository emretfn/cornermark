import AppKit
import CoreGraphics
import ScreenCaptureKit

/// The real source. Every capture excludes this process's windows, so overlays, HUDs and the
/// editor never appear in a screenshot.
public final class ScreenCaptureKitSource: ScreenSource {
    private struct ScreenGeometry {
        var frame: CGRect
        var scale: Double
    }

    public init() {}

    public func displays() async throws -> [DisplaySnapshot] {
        let content = try await Self.shareableContent(onScreenOnly: true)
        let geometry = await Self.screenGeometry()
        var out: [DisplaySnapshot] = []
        for display in content.displays {
            guard let g = geometry[display.displayID] else { continue }
            out.append(try await Self.snapshot(of: display, geometry: g, content: content))
        }
        guard !out.isEmpty else { throw CaptureFailure.noDisplay }
        return out
    }

    public func capture(displayID: CGDirectDisplayID) async throws -> DisplaySnapshot {
        let content = try await Self.shareableContent(onScreenOnly: true)
        let geometry = await Self.screenGeometry()
        guard let display = content.displays.first(where: { $0.displayID == displayID }),
              let g = geometry[displayID] else { throw CaptureFailure.noDisplay }
        return try await Self.snapshot(of: display, geometry: g, content: content)
    }

    public func windows() async throws -> [WindowSnapshot] {
        let content = try await Self.shareableContent(onScreenOnly: true)
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let mainHeight = CGDisplayBounds(CGMainDisplayID()).height
        let order = Self.frontToBackOrder()
        let candidates = content.windows.filter {
            $0.windowLayer == 0 && $0.isOnScreen && $0.frame.width >= 40 && $0.frame.height >= 40
                && $0.owningApplication?.processID != ownPID
        }
        return candidates
            .sorted { (order[$0.windowID] ?? .max) < (order[$1.windowID] ?? .max) }
            .map {
                WindowSnapshot(id: $0.windowID, title: $0.title ?? "", appName: $0.owningApplication?.applicationName ?? "",
                               frame: CGRect(x: $0.frame.minX, y: mainHeight - $0.frame.maxY, width: $0.frame.width, height: $0.frame.height))
            }
    }

    public func image(of window: WindowSnapshot, options: WindowCaptureOptions) async throws -> CGImage {
        let content = try await Self.shareableContent(onScreenOnly: false)
        guard let target = content.windows.first(where: { $0.windowID == window.id }) else {
            throw CaptureFailure.other("The window is no longer available")
        }
        let filter = SCContentFilter(desktopIndependentWindow: target)
        let scale = CGFloat(filter.pointPixelScale)
        let rect = filter.contentRect
        let config = SCStreamConfiguration()
        config.width = max(1, Int((rect.width * scale).rounded()))
        config.height = max(1, Int((rect.height * scale).rounded()))
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = !options.includeShadow
        config.colorSpaceName = CGColorSpace.sRGB
        config.pixelFormat = kCVPixelFormatType_32BGRA
        do {
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        } catch {
            throw Self.map(error)
        }
    }

    private static func snapshot(of display: SCDisplay, geometry: ScreenGeometry, content: SCShareableContent) async throws -> DisplaySnapshot {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let own = content.windows.filter { $0.owningApplication?.processID == ownPID }
        let filter = SCContentFilter(display: display, excludingWindows: own)
        let config = SCStreamConfiguration()
        config.width = max(1, Int((geometry.frame.width * geometry.scale).rounded()))
        config.height = max(1, Int((geometry.frame.height * geometry.scale).rounded()))
        config.showsCursor = false
        config.colorSpaceName = CGColorSpace.sRGB
        config.pixelFormat = kCVPixelFormatType_32BGRA
        do {
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            return DisplaySnapshot(displayID: display.displayID, frame: geometry.frame, scale: geometry.scale, image: image)
        } catch {
            throw map(error)
        }
    }

    private static func shareableContent(onScreenOnly: Bool) async throws -> SCShareableContent {
        do {
            return try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: onScreenOnly)
        } catch {
            throw map(error)
        }
    }

    private static func map(_ error: Error) -> CaptureFailure {
        if let failure = error as? CaptureFailure { return failure }
        if let sc = error as? SCStreamError, sc.code == .userDeclined { return .permissionDenied }
        return .other(error.localizedDescription)
    }

    @MainActor
    private static func screenGeometry() -> [CGDirectDisplayID: ScreenGeometry] {
        var out: [CGDirectDisplayID: ScreenGeometry] = [:]
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { continue }
            out[CGDirectDisplayID(number.uint32Value)] = ScreenGeometry(frame: screen.frame, scale: Double(screen.backingScaleFactor))
        }
        return out
    }

    private static func frontToBackOrder() -> [CGWindowID: Int] {
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        var order: [CGWindowID: Int] = [:]
        for (index, entry) in info.enumerated() {
            if let number = entry[kCGWindowNumber as String] as? Int { order[CGWindowID(number)] = index }
        }
        return order
    }
}
