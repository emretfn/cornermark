import CoreGraphics
import Foundation

/// What a display recording leaves out of its picture. The live stream and the fixture display both ask `plan` which applications
/// and windows to keep, so the list is decided in one place.
public struct ContentExclusion: Equatable, Sendable {
    /// Notification banners stay on screen but out of the video. Focus and Do Not Disturb are never changed.
    public var hidesNotifications: Bool
    /// The icons on the desktop stay out of the video. The wallpaper and Finder's own windows stay in.
    public var hidesDesktopIcons: Bool

    public init(hidesNotifications: Bool = true, hidesDesktopIcons: Bool = false) {
        self.hidesNotifications = hidesNotifications
        self.hidesDesktopIcons = hidesDesktopIcons
    }

    /// True when the list can go stale while recording. The stream can exclude only an `SCRunningApplication` taken from
    /// `SCShareableContent.applications`, never a bundle identifier, so a Notification Center process that was not listed when the
    /// stream was prepared, or a Finder window opened since, joins the filter only through a later look.
    public var needsRefresh: Bool { hidesNotifications || hidesDesktopIcons }

    public static let notificationCenter = "com.apple.notificationcenterui"
    public static let finder = "com.apple.finder"

    public struct App: Equatable, Sendable {
        public var pid: pid_t
        public var bundleID: String
        public init(pid: pid_t, bundleID: String) { self.pid = pid; self.bundleID = bundleID }
    }

    public struct Window: Equatable, Sendable {
        public var id: CGWindowID
        public var ownerPID: pid_t
        /// The window server layer. Desktop icons sit below every normal window, at a negative layer.
        public var layer: Int
        public init(id: CGWindowID, ownerPID: pid_t, layer: Int) { self.id = id; self.ownerPID = ownerPID; self.layer = layer }
    }

    /// Applications whose windows are filmed by no one, and windows of those applications that are filmed anyway.
    /// An excluded application keeps out the windows it opens later, which is what makes a banner that arrives mid-recording stay out.
    public struct Plan: Equatable, Sendable {
        public var excludedApps: Set<pid_t>
        public var exceptedWindows: Set<CGWindowID>

        public func films(_ window: Window) -> Bool {
            !excludedApps.contains(window.ownerPID) || exceptedWindows.contains(window.id)
        }
    }

    /// `ownPID` is always excluded, so the controls, the countdown and every other Cornermark window stay out of the video.
    public func plan(apps: [App], windows: [Window], ownPID: pid_t) -> Plan {
        var excluded: Set<pid_t> = [ownPID]
        var excepted: Set<CGWindowID> = []
        for app in apps {
            switch app.bundleID {
            case Self.notificationCenter where hidesNotifications:
                excluded.insert(app.pid)
            case Self.finder where hidesDesktopIcons:
                excluded.insert(app.pid)
                excepted.formUnion(windows.filter { $0.ownerPID == app.pid && $0.layer >= 0 }.map(\.id))
            default: break
            }
        }
        return Plan(excludedApps: excluded, exceptedWindows: excepted)
    }
}

/// Keeps the plan of a running recording current. `observe` takes a fresh look at the running applications and windows and hands
/// back a plan only when it differs from the one in force, so the stream's filter is replaced only when the list changed.
public struct ExclusionTracker: Sendable {
    public let exclusion: ContentExclusion
    public let ownPID: pid_t
    public private(set) var plan: ContentExclusion.Plan

    public init(exclusion: ContentExclusion, plan: ContentExclusion.Plan, ownPID: pid_t) {
        self.exclusion = exclusion
        self.plan = plan
        self.ownPID = ownPID
    }

    public mutating func observe(apps: [ContentExclusion.App], windows: [ContentExclusion.Window]) -> ContentExclusion.Plan? {
        let next = exclusion.plan(apps: apps, windows: windows, ownPID: ownPID)
        guard next != plan else { return nil }
        plan = next
        return next
    }
}
