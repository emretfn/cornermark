import AppKit
import Carbon.HIToolbox
import CornermarkCore

/// A click or a key press, stamped with `t` on the clock the pictures use. Positions are in points of the filmed area, top-left origin.
public enum InputReading: Equatable {
    case click(ClickEvent)
    case key(KeyEvent)
}

public enum InputUnavailable: Error, Equatable, CustomStringConvertible {
    case notPermitted
    case tapFailed

    public var description: String {
        switch self {
        case .notPermitted: return "notPermitted"
        case .tapFailed: return "tapFailed"
        }
    }
}

public protocol InputSource: AnyObject {
    /// `area` is what the pictures show, in global AppKit points. Readings may arrive on any queue until `stop`.
    func start(in area: CGRect, deliver: @escaping (InputReading) -> Void) throws
    func stop()
}

/// Never asks for Input Monitoring: without it, `start` throws `notPermitted` and creates nothing.
public final class LiveInputSource: InputSource {
    /// Reads the permission without showing a prompt.
    public static var isPermitted: Bool { CGPreflightListenEventAccess() }
    public private(set) static var tapsCreated = 0

    private let capture: InputCapture
    private var tap: CFMachPort?
    private var loopSource: CFRunLoopSource?
    private var handler: Handler?

    final class Handler {
        let capture: InputCapture
        let area: CGRect
        let deliver: (InputReading) -> Void
        var tap: CFMachPort?
        init(capture: InputCapture, area: CGRect, deliver: @escaping (InputReading) -> Void) { self.capture = capture; self.area = area; self.deliver = deliver }
    }

    public init(capture: InputCapture) { self.capture = capture }

    public func start(in area: CGRect, deliver: @escaping (InputReading) -> Void) throws {
        guard !capture.isEmpty else { return }
        guard Self.isPermitted else { throw InputUnavailable.notPermitted }
        var mask: CGEventMask = 0
        if capture.clicks { mask |= 1 << CGEventType.leftMouseDown.rawValue | 1 << CGEventType.rightMouseDown.rawValue }
        if capture.keys != nil { mask |= 1 << CGEventType.keyDown.rawValue }
        let handler = Handler(capture: capture, area: area, deliver: deliver)
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly, eventsOfInterest: mask,
                                          callback: inputTapCallback, userInfo: Unmanaged.passUnretained(handler).toOpaque()) else {
            throw InputUnavailable.tapFailed
        }
        Self.tapsCreated += 1
        handler.tap = tap
        let loopSource = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), loopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.loopSource = loopSource
        self.handler = handler
    }

    public func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let loopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), loopSource, .commonModes) }
        tap = nil
        loopSource = nil
        handler = nil
    }

    /// One system event as a reading, or nil when it is not kept: a key while secure input is on (a password field has focus),
    /// a repeat from a held key, a key the mode leaves out, or a click outside the area.
    public static func reading(_ event: CGEvent, type: CGEventType, capture: InputCapture, area: CGRect, secureInput: Bool, time: Double) -> InputReading? {
        switch type {
        case .leftMouseDown, .rightMouseDown:
            guard capture.clicks else { return nil }
            let q = event.location
            let global = CGPoint(x: q.x, y: CGDisplayBounds(CGMainDisplayID()).height - q.y)
            let p = PointerGeometry.local(global, in: area)
            guard p.x >= 0, p.y >= 0, p.x <= area.width, p.y <= area.height else { return nil }
            return .click(ClickEvent(t: time, x: p.x, y: p.y))
        case .keyDown:
            guard capture.keys != nil, !secureInput, event.getIntegerValueField(.keyboardEventAutorepeat) == 0,
                  let ns = NSEvent(cgEvent: event) else { return nil }
            var modifiers = KeyModifiers()
            let flags = event.flags
            if flags.contains(.maskControl) { modifiers.insert(.control) }
            if flags.contains(.maskAlternate) { modifiers.insert(.option) }
            if flags.contains(.maskShift) { modifiers.insert(.shift) }
            if flags.contains(.maskCommand) { modifiers.insert(.command) }
            let base = ns.characters(byApplyingModifiers: []) ?? ""
            guard var key = KeyLabel.make(keyCode: ns.keyCode, base: base, typed: ns.characters ?? "", modifiers: modifiers),
                  capture.admitsKey(isCommand: key.isCommand) else { return nil }
            key.t = time
            return .key(key)
        default:
            return nil
        }
    }
}

private func inputTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let handler = Unmanaged<LiveInputSource.Handler>.fromOpaque(refcon).takeUnretainedValue()
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let tap = handler.tap { CGEvent.tapEnable(tap: tap, enable: true) }
    } else if let reading = LiveInputSource.reading(event, type: type, capture: handler.capture, area: handler.area,
                                                    secureInput: IsSecureEventInputEnabled(), time: recordingClockNow()) {
        handler.deliver(reading)
    }
    return Unmanaged.passUnretained(event)
}

/// Clicks and key presses on a timeline, clicks in fractions of the filmed area so they fit any size.
public struct InputScript: Equatable {
    public struct Click: Equatable {
        public var t: Double, x: Double, y: Double
        public init(t: Double, x: Double, y: Double) { self.t = t; self.x = x; self.y = y }
    }
    public var clicks: [Click]
    public var keys: [KeyEvent]
    /// The script starts over after this many seconds. Zero plays it once.
    public var period: Double

    public init(clicks: [Click], keys: [KeyEvent], period: Double = 0) { self.clicks = clicks; self.keys = keys; self.period = period }

    public static let tour = InputScript(
        clicks: [Click(t: 0.3, x: 0.15, y: 0.20), Click(t: 1.9, x: 0.85, y: 0.20), Click(t: 3.5, x: 0.85, y: 0.80),
                 Click(t: 5.1, x: 0.15, y: 0.80), Click(t: 6.7, x: 0.50, y: 0.50)],
        keys: [KeyEvent(t: 0.9, label: "\u{21E7}\u{2318}4", isCommand: true),
               KeyEvent(t: 2.4, label: "h", isCommand: false), KeyEvent(t: 2.55, label: "e", isCommand: false),
               KeyEvent(t: 2.7, label: "l", isCommand: false), KeyEvent(t: 2.85, label: "l", isCommand: false),
               KeyEvent(t: 3.0, label: "o", isCommand: false),
               KeyEvent(t: 4.6, label: "\u{2318}S", isCommand: true)],
        period: 7)

    /// Every event from `from` up to but not including `to` seconds, with clicks placed in `area` and the script repeated.
    public func events(from: Double, to: Double, area: CGSize) -> [InputReading] {
        var out: [InputReading] = []
        let laps = period > 0 ? Int((to / period).rounded(.up)) : 1
        for lap in 0..<max(laps, 1) {
            let shift = Double(lap) * period
            for c in clicks where c.t + shift >= from && c.t + shift < to {
                out.append(.click(ClickEvent(t: c.t + shift, x: c.x * area.width, y: c.y * area.height)))
            }
            for k in keys where k.t + shift >= from && k.t + shift < to {
                out.append(.key(KeyEvent(t: k.t + shift, label: k.label, isCommand: k.isCommand)))
            }
        }
        return out.sorted { $0.t < $1.t }
    }
}

extension InputReading {
    var t: Double {
        switch self {
        case .click(let c): return c.t
        case .key(let k): return k.t
        }
    }

    func shifted(by seconds: Double) -> InputReading {
        switch self {
        case .click(var c): c.t += seconds; return .click(c)
        case .key(var k): k.t += seconds; return .key(k)
        }
    }
}

public final class ScriptedInputSource: InputSource {
    public enum Pacing {
        /// Readings arrive as their moment passes, the script's zero at the clock's reading at `start`.
        case realtime
        /// Every reading of the first `seconds` arrives from `start` itself, the script's zero at `origin`.
        case fixed(origin: Double, seconds: Double)
    }

    private let script: InputScript
    private let capture: InputCapture
    private let pacing: Pacing
    private let queue = DispatchQueue(label: "cornermark.scripted-input", qos: .userInteractive)
    private var timer: DispatchSourceTimer?

    public init(script: InputScript = .tour, capture: InputCapture, pacing: Pacing = .realtime) {
        self.script = script; self.capture = capture; self.pacing = pacing
    }

    public func start(in area: CGRect, deliver: @escaping (InputReading) -> Void) throws {
        let capture = self.capture
        func keep(_ r: InputReading) -> Bool {
            switch r {
            case .click: return capture.clicks
            case .key(let k): return capture.admitsKey(isCommand: k.isCommand)
            }
        }
        switch pacing {
        case .fixed(let origin, let seconds):
            script.events(from: 0, to: seconds, area: area.size).filter(keep).forEach { deliver($0.shifted(by: origin)) }
        case .realtime:
            let origin = recordingClockNow()
            var played = 0.0
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(4), leeway: .microseconds(500))
            timer.setEventHandler { [script] in
                let now = recordingClockNow() - origin
                script.events(from: played, to: now, area: area.size).filter(keep).forEach { deliver($0.shifted(by: origin)) }
                played = now
            }
            self.timer = timer
            timer.resume()
        }
    }

    public func stop() {
        timer?.cancel()
        timer = nil
        queue.sync {}
    }
}
