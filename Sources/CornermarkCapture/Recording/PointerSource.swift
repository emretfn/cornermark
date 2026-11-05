import AppKit
import CoreMedia
import CornermarkCore

/// Seconds on the clock the frame sources stamp their pictures with, which is the host clock for the live stream.
public func recordingClockNow() -> Double {
    CMClockGetTime(CMClockGetHostTimeClock()).seconds
}

/// Where the pointer is, stamped on the same clock as the pictures. Positions are in points of the filmed area, with a top-left origin.
public struct PointerReading: Equatable {
    public var time: Double
    public var x: Double
    public var y: Double
    public init(time: Double, x: Double, y: Double) { self.time = time; self.x = x; self.y = y }
}

/// The seam between the recorder and whatever knows where the pointer is.
/// A live instance reads the real pointer. A scripted instance replays a path, so a test never touches the developer's mouse.
public protocol PointerSource: AnyObject {
    /// `area` is what the pictures show, in global AppKit points. Readings may arrive on any queue until `stop`.
    func start(in area: CGRect, deliver: @escaping (PointerReading) -> Void)
    func stop()
}

public enum PointerGeometry {
    /// A global AppKit point (bottom-left origin) as a point of `area` with a top-left origin.
    public static func local(_ global: CGPoint, in area: CGRect) -> CGPoint {
        CGPoint(x: global.x - area.minX, y: area.maxY - global.y)
    }
}

/// Reads the real pointer's position by polling. Reading a position needs no permission and shows no prompt,
/// unlike an event tap, which clicks and keys will need later.
public final class LivePointerSource: PointerSource {
    private let rate: Int
    private let queue = DispatchQueue(label: "cornermark.pointer", qos: .userInteractive)
    private var timer: DispatchSourceTimer?

    public init(rate: Int = 120) { self.rate = rate }

    public func start(in area: CGRect, deliver: @escaping (PointerReading) -> Void) {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .nanoseconds(1_000_000_000 / rate), leeway: .microseconds(500))
        timer.setEventHandler {
            let local = PointerGeometry.local(NSEvent.mouseLocation, in: area)
            deliver(PointerReading(time: recordingClockNow(), x: local.x, y: local.y))
        }
        self.timer = timer
        timer.resume()
    }

    public func stop() {
        timer?.cancel()
        timer = nil
        queue.sync {}
    }
}
