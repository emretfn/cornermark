import AppKit

public enum OverlayPresentation {
    case onscreen
    /// Windows exist and take events but are never ordered in. For tests that must not flash a full-screen overlay.
    case offscreen
}

struct SessionOptions {
    var presentation = OverlayPresentation.onscreen
    var tickInterval: TimeInterval = 1
    var scrollInterval: TimeInterval = 0.15
}

enum SessionEnd {
    case finish(Finish)
    case scrolled(CGImage?, pointScale: Double)
    case failed(CaptureFailure)
}

/// Owns every window of one capture and funnels all input through the machine. Whatever the
/// machine ends in, `tearDown` runs before the end is reported.
@MainActor
final class CaptureSession: OverlayHost {
    private(set) var machine: SelectionMachine
    private let displays: [DisplaySnapshot]
    private let source: ScreenSource
    private let options: SessionOptions
    private var onEnd: ((SessionEnd) -> Void)?

    private(set) var panels: [OverlayPanel] = []
    private var toolbar: SelectionToolbar?
    private(set) var toolbarPill: CGRect?
    private var countdown: CountdownPanel?
    private var scroll: ScrollCapture?
    private var tickTimer: Timer?
    private var escapeMonitor: Any?
    private var previousApp: NSRunningApplication?

    init(displays: [DisplaySnapshot], config: MachineConfig, source: ScreenSource, options: SessionOptions, onEnd: @escaping (SessionEnd) -> Void) {
        self.displays = displays
        self.machine = SelectionMachine(config: config)
        self.source = source
        self.options = options
        self.onEnd = onEnd
    }

    var windows: [NSWindow] {
        panels + [countdown].compactMap { $0 } + (scroll?.windows ?? [])
    }

    func start(cursor: CGPoint) {
        if options.presentation == .onscreen {
            // A nonactivating panel only becomes key in an active app, and a hotkey-launched app is not active.
            previousApp = NSWorkspace.shared.frontmostApplication.flatMap { $0.processIdentifier == getpid() ? nil : $0 }
            NSApp.activate()
        }
        if case .timedFullscreen = machine.config.flow {} else { buildPanels(cursor: cursor) }
        if options.presentation == .onscreen, AXIsProcessTrusted() {
            escapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard event.keyCode == 53 else { return }
                Task { @MainActor in self?.send(.keyDown(.escape, [])) }
            }
        }
        send(.begin(cursor: cursor))
    }

    private func buildPanels(cursor: CGPoint) {
        panels = displays.map { OverlayPanel(display: $0, host: self) }
        guard options.presentation == .onscreen else { return }
        for p in panels { p.orderFrontRegardless() }
        let key = panels.first { $0.display.frame.contains(cursor) } ?? panels.first
        key?.makeKeyAndOrderFront(nil)
        key?.makeFirstResponder(key?.chrome)
    }

    // MARK: Input

    func send(_ input: Input) {
        guard onEnd != nil else { return }
        let before = machine.state
        machine.send(input)
        reconcile(from: before)
    }

    func handleKey(_ event: NSEvent) -> Bool {
        let mods = Modifiers(event.modifierFlags)
        switch event.type {
        case .flagsChanged:
            send(.modifiers(mods))
            return false
        case .keyDown:
            guard let key = Key(event) else { return false }
            if event.isARepeat && key == .space { return true }
            send(.keyDown(key, mods))
            return true
        case .keyUp:
            guard let key = Key(event) else { return false }
            send(.keyUp(key))
            return true
        default:
            return false
        }
    }

    func cancel() { send(.keyDown(.escape, [])) }

    func fail(_ error: Error) {
        guard let end = onEnd else { return }
        onEnd = nil
        tearDown()
        previousApp?.activate()
        end(.failed(error as? CaptureFailure ?? .other(error.localizedDescription)))
    }

    // MARK: State to windows

    private func reconcile(from before: OverlayState) {
        switch machine.state {
        case .finished(let finish):
            guard let end = onEnd else { return }
            onEnd = nil
            let stitched = scroll?.image
            let scale = scroll?.area.display.scale ?? 1
            tearDown()
            switch finish {
            case .scrolled: end(.scrolled(stitched, pointScale: scale))
            case .cancelled:
                previousApp?.activate()
                end(.finish(finish))
            case .capture: end(.finish(finish))
            }
        case .countdown(let remaining, _):
            if case .countdown = before {} else { enterCountdown() }
            countdown?.show(remaining)
        case .scrollingCapture(let area, let progress):
            if case .scrollingCapture = before {} else { enterScrolling(area) }
            scroll?.update(progress)
        default:
            refreshOverlay()
        }
    }

    private func refreshOverlay() {
        for p in panels { p.chrome.needsDisplay = true }
        updateToolbar()
    }

    private func closePanels() {
        toolbar?.removeFromSuperview()
        for p in panels { p.keyHost = nil; p.orderOut(nil); p.close() }
        panels = []
    }

    private func enterCountdown() {
        closePanels()
        let display = machine.display(at: machine.cursor) ?? machine.config.displays[0]
        let hud = CountdownPanel(display: display, host: self)
        if options.presentation == .onscreen { hud.makeKeyAndOrderFront(nil) }
        countdown = hud
        tickTimer = Timer.scheduledTimer(withTimeInterval: options.tickInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.send(.tick) }
        }
    }

    private func enterScrolling(_ area: ScrollArea) {
        closePanels()
        let capture = ScrollCapture(area: area, source: source, host: self)
        scroll = capture
        capture.start(interval: options.scrollInterval, present: options.presentation == .onscreen)
    }

    private func updateToolbar() {
        guard machine.config.flow == .adjustable else { return }
        switch machine.state {
        case .armed, .windowHover, .adjusting: break
        default:
            toolbar?.removeFromSuperview()
            toolbarPill = nil
            return
        }
        let bar: SelectionToolbar
        if let existing = toolbar { bar = existing } else {
            bar = SelectionToolbar(frame: .zero)
            bar.onAction = { [weak self] in self?.send(.toolbar($0)) }
            toolbar = bar
        }
        bar.update(machine)

        let display: DisplayGeometry
        let pill = bar.pillRect.size
        var origin: CGPoint
        if case .adjusting(let sel, _) = machine.state {
            display = machine.chromeDisplay(for: sel.rect) ?? machine.config.displays[0]
            // Hug the part of the selection on this display, so the pill never straddles two.
            let part = sel.rect.intersection(display.frame)
            let anchor = part.isEmpty ? sel.rect : part
            origin = CGPoint(x: anchor.midX - pill.width / 2, y: anchor.minY - 12 - pill.height)
            if origin.y < display.frame.minY + 8 {
                origin.y = anchor.maxY + 12
                if origin.y + pill.height > display.frame.maxY - 8 { origin.y = anchor.minY + 12 }
            }
            origin.y = min(max(origin.y, display.frame.minY + 8), display.frame.maxY - pill.height - 8)
        } else {
            display = machine.display(at: machine.cursor) ?? machine.config.displays[0]
            origin = CGPoint(x: display.frame.midX - pill.width / 2, y: display.frame.minY + 90)
        }
        origin.x = min(max(origin.x, display.frame.minX + 8), display.frame.maxX - pill.width - 8)

        guard let panel = panels.first(where: { $0.display.displayID == display.id }) else { return }
        toolbarPill = CGRect(origin: origin, size: pill)
        let inset = bar.bounds.width - pill.width
        bar.setFrameOrigin(CGPoint(x: origin.x - display.frame.minX - inset / 2, y: origin.y - display.frame.minY - inset / 2))
        if bar.superview !== panel.root {
            bar.removeFromSuperview()
            panel.root.addSubview(bar)
        }
    }

    func tearDown() {
        tickTimer?.invalidate(); tickTimer = nil
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = nil
        closePanels()
        toolbar = nil
        countdown?.keyHost = nil
        countdown?.orderOut(nil); countdown?.close(); countdown = nil
        scroll?.stop(); scroll = nil
    }
}
