import CoreGraphics
import KadrajCore

public enum CaptureMode: Hashable {
    case area, window, fullscreen, allInOne, previousArea
    case timed(seconds: Int)
    case scrolling
}

public struct CaptureOutput {
    public var image: CGImage
    public var kind: CaptureKind
    public var pointScale: Double
    public init(image: CGImage, kind: CaptureKind, pointScale: Double) {
        self.image = image; self.kind = kind; self.pointScale = pointScale
    }
}

public enum CaptureFailure: Error, Equatable {
    case permissionDenied
    case noDisplay
    case other(String)
}

public enum CaptureOutcome {
    case captured(CaptureOutput)
    case cancelled
    case failed(CaptureFailure)
}

/// Global AppKit points (bottom-left origin); may span displays. It carries no display ids, so a display
/// that has since gone can never leave it stale: whatever displays exist at recapture supply the pixels.
public struct PreviousSelection: Equatable {
    public var rect: CGRect
    public init(rect: CGRect) { self.rect = rect }

    /// The part of the rect still inside the current displays; nil when none of it is.
    func recapturable(on displays: [DisplaySnapshot]) -> CGRect? {
        let screen = displays.reduce(CGRect.null) { $0.union($1.frame) }
        let kept = rect.intersection(screen)
        return kept.isEmpty ? nil : kept
    }
}

public struct DisplaySnapshot {
    public var displayID: CGDirectDisplayID
    /// Global AppKit points, bottom-left origin.
    public var frame: CGRect
    /// Pixels per point.
    public var scale: Double
    public var image: CGImage
    public init(displayID: CGDirectDisplayID, frame: CGRect, scale: Double, image: CGImage) {
        self.displayID = displayID; self.frame = frame; self.scale = scale; self.image = image
    }
}

public struct WindowSnapshot: Hashable {
    public var id: CGWindowID
    public var title: String
    public var appName: String
    /// Global AppKit points, bottom-left origin.
    public var frame: CGRect
    public init(id: CGWindowID, title: String, appName: String, frame: CGRect) {
        self.id = id; self.title = title; self.appName = appName; self.frame = frame
    }
}

public struct WindowCaptureOptions: Hashable {
    public var includeShadow: Bool
    public init(includeShadow: Bool = true) { self.includeShadow = includeShadow }
}
