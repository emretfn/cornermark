import AppKit
import CornermarkCore

@MainActor
public final class CaptureController {
    private let source: ScreenSource
    private var session: CaptureSession?
    private var completion: ((CaptureOutcome) -> Void)?
    private var frozen: [CGDirectDisplayID: DisplaySnapshot] = [:]
    private var followUp: CaptureMode?
    /// Bumped whenever the current capture ends, so work still in flight for it drops its result.
    private var serial = 0

    public var lastSelection: PreviousSelection?
    /// Window captures include the drop shadow unless Option is held at the click.
    public var includeWindowShadow = true
    public var timerSeconds = 3
    /// What `.timed` captures once the countdown ends.
    public var timedMode: CaptureMode = .fullscreen
    public var presentation = OverlayPresentation.onscreen
    public var countdownTickInterval: TimeInterval = 1
    public var scrollPollInterval: TimeInterval = 0.15
    /// Time for our overlays to leave the compositor before a fresh capture.
    public var settleDelay: TimeInterval = 0.12
    public var pointerLocation: () -> CGPoint = { NSEvent.mouseLocation }

    public var overlayWindows: [NSWindow] { session?.windows ?? [] }
    public var overlayState: OverlayState? { session?.machine.state }

    /// `.offscreen` never orders a window in, activates the app, or takes focus.
    public init(source: ScreenSource, presentation: OverlayPresentation = .onscreen) {
        self.source = source
        self.presentation = presentation
    }

    public nonisolated static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }
    public nonisolated static func requestPermission() { _ = CGRequestScreenCaptureAccess() }

    public func begin(_ mode: CaptureMode, completion: @escaping (CaptureOutcome) -> Void) {
        complete(.cancelled)
        self.completion = completion
        let id = serial
        Task { [weak self] in await self?.run(mode, id: id) }
    }

    public func cancel() { complete(.cancelled) }

    // MARK: Run

    private func run(_ mode: CaptureMode, id: Int) async {
        do {
            switch mode {
            case .fullscreen:
                let displays = try await source.displays()
                guard serial == id else { return }
                guard let d = display(under: pointerLocation(), in: displays) else { throw CaptureFailure.noDisplay }
                complete(.captured(CaptureOutput(image: ImageCrop.detached(d.image), kind: .fullscreen, pointScale: d.scale)))
            case .previousArea:
                guard let prev = lastSelection else { return await run(.area, id: id) }
                let displays = try await source.displays()
                guard serial == id else { return }
                // Displays that vanished simply contribute nothing; with none of the rect left, pick a new area.
                guard let rect = prev.recapturable(on: displays), let shot = AreaCompositor.composite(rect: rect, displays: displays) else {
                    return await run(.area, id: id)
                }
                complete(.captured(CaptureOutput(image: shot.image, kind: .area, pointScale: shot.pointScale)))
            case .timed(let seconds):
                followUp = timedMode
                try await present(flow: .timedFullscreen(seconds: seconds), id: id)
            case .area:
                try await present(flow: .immediate, id: id)
            case .scrolling:
                try await present(flow: .immediate, intent: .scrolling, id: id)
            case .allInOne:
                try await present(flow: .adjustable, wantsWindows: true, id: id)
            case .window:
                try await present(flow: .window, wantsWindows: true, id: id)
            }
        } catch {
            guard serial == id else { return }
            complete(.failed(Self.failure(from: error)))
        }
    }

    private func present(flow: Flow, intent: Intent = .area, wantsWindows: Bool = false, id: Int) async throws {
        let displays = try await source.displays()
        guard !displays.isEmpty else { throw CaptureFailure.noDisplay }
        var windows: [WindowSnapshot] = []
        if wantsWindows {
            windows = flow == .window ? try await source.windows() : ((try? await source.windows()) ?? [])
        }
        guard serial == id else { return }

        frozen = Dictionary(displays.map { ($0.displayID, $0) }, uniquingKeysWith: { a, _ in a })
        let geometry = displays.map { DisplayGeometry(id: $0.displayID, frame: $0.frame, scale: $0.scale) }
        let config = MachineConfig(flow: flow, intent: intent, timerSeconds: timerSeconds, displays: geometry, windows: windows)
        var options = SessionOptions()
        options.presentation = presentation
        options.tickInterval = countdownTickInterval
        options.scrollInterval = scrollPollInterval
        let session = CaptureSession(displays: displays, config: config, source: source, options: options) { [weak self] end in
            self?.sessionEnded(end, id: id)
        }
        self.session = session
        session.start(cursor: pointerLocation())
    }

    // MARK: Results

    private func sessionEnded(_ end: SessionEnd, id: Int) {
        guard serial == id else { return }
        switch end {
        case .failed(let f): complete(.failed(f))
        case .finish(.cancelled), .finish(.scrolled): complete(.cancelled)
        case .scrolled(let image, let scale):
            guard let image else { return complete(.failed(.other("Nothing was captured"))) }
            complete(.captured(CaptureOutput(image: image, kind: .scrolling, pointScale: scale)))
        case .finish(.capture(let target, let kind)):
            Task { [weak self] in await self?.resolve(target, kind: kind, id: id) }
        }
    }

    private func resolve(_ target: Target, kind: CaptureKind, id: Int) async {
        do {
            if kind == .timed, case .fullscreen = target, let next = followUp, next != .fullscreen {
                followUp = nil
                session = nil
                return await run(next, id: id)
            }
            let fresh = kind == .timed
            if fresh { try await Task.sleep(nanoseconds: UInt64(settleDelay * 1_000_000_000)) }
            guard serial == id else { return }

            func snapshot(_ display: DisplayGeometry) async throws -> DisplaySnapshot {
                if !fresh, let frozen = frozen[display.id] { return frozen }
                return try await source.capture(displayID: display.id)
            }

            switch target {
            case .area(let sel):
                let touched = frozen.values.filter { !$0.frame.intersection(sel.rect).isEmpty }.sorted { $0.displayID < $1.displayID }
                var snaps: [DisplaySnapshot] = []
                for d in touched {
                    snaps.append(fresh ? try await source.capture(displayID: d.displayID) : d)
                }
                guard let shot = AreaCompositor.composite(rect: sel.rect, displays: snaps) else { throw CaptureFailure.other("The selection is empty") }
                lastSelection = PreviousSelection(rect: sel.rect)
                guard serial == id else { return }
                complete(.captured(CaptureOutput(image: shot.image, kind: kind, pointScale: shot.pointScale)))
            case .fullscreen(let display):
                let snap = try await snapshot(display)
                guard serial == id else { return }
                complete(.captured(CaptureOutput(image: ImageCrop.detached(snap.image), kind: kind, pointScale: snap.scale)))
            case .window(let window, let toggleShadow):
                let image = try await source.image(of: window, options: WindowCaptureOptions(includeShadow: includeWindowShadow != toggleShadow))
                let mid = CGPoint(x: window.frame.midX, y: window.frame.midY)
                let scale = frozen.values.first { $0.frame.contains(mid) }?.scale ?? frozen.values.first?.scale ?? 1
                guard serial == id else { return }
                complete(.captured(CaptureOutput(image: image, kind: .window, pointScale: scale)))
            }
        } catch {
            guard serial == id else { return }
            complete(.failed(Self.failure(from: error)))
        }
    }

    private func complete(_ outcome: CaptureOutcome) {
        serial += 1
        followUp = nil
        let ending = session
        session = nil
        ending?.tearDown()
        frozen = [:]
        let done = completion
        completion = nil
        done?(outcome)
    }

    private func display(under p: CGPoint, in displays: [DisplaySnapshot]) -> DisplaySnapshot? {
        displays.first { $0.frame.contains(p) } ?? displays.first
    }

    private static func failure(from error: Error) -> CaptureFailure {
        error as? CaptureFailure ?? .other(error.localizedDescription)
    }
}
