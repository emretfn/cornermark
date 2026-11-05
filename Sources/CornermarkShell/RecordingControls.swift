import AppKit
import CornermarkCapture
import CornermarkCore
import CornermarkDesign

/// What the controls and the menu bar show: the phase and the length of the video so far.
struct RecordingStatus: Equatable {
    var phase: RecordingController.Phase
    var seconds: Double

    var timeText: String { ImageOutput.durationText(seconds) }

    /// The words a screen reader says for the indicator.
    var spoken: String {
        switch phase {
        case .countingDown(let n): return "Recording starts in \(n)"
        case .paused: return "Recording paused at \(timeText)"
        case .recording: return "Recording, \(timeText)"
        case .starting: return "Preparing to record"
        case .stopping: return "Saving recording"
        case .idle: return "Not recording"
        }
    }
}

/// A borderless panel that never takes focus and never appears in a capture, whether Cornermark's own or another app's.
final class RecordingPanel: NSPanel {
    init(frame: CGRect, level: NSWindow.Level, title: String) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        self.title = title
        // Setting it after the level would put the level back to floating.
        isFloatingPanel = true
        self.level = level
        sharingType = .none
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Where the control bar sits when it first appears: centred under the area, else over it, else inside its bottom edge, and always
/// inside the visible frame. A place the user dragged it to wins while it still fits.
enum RecordingBarLayout {
    static let gap = DS.Space.s16

    static func origin(size: CGSize, area: CGRect, visible: CGRect, remembered: CGPoint?) -> CGPoint {
        if let remembered, visible.contains(CGRect(origin: remembered, size: size)) { return remembered }
        let x = min(max(area.midX - size.width / 2, visible.minX + gap), visible.maxX - gap - size.width)
        let below = area.minY - gap - size.height
        if below >= visible.minY + gap { return CGPoint(x: x, y: below) }
        let above = area.maxY + gap
        if above + size.height <= visible.maxY - gap { return CGPoint(x: x, y: above) }
        return CGPoint(x: x, y: max(area.minY, visible.minY) + gap)
    }
}

/// The control bar's look in each phase, read from one table so a phase cannot show a mix of two.
struct RecordingBarLook: Equatable {
    var indicator: String
    var indicatorIsDanger: Bool
    var timeIsMuted: Bool
    /// The pause button, or in its place the resume button.
    var showsResume: Bool
    var canPause: Bool
    var canRestart: Bool
    var stopTitle: String
    var canStop: Bool

    static func of(_ phase: RecordingController.Phase) -> RecordingBarLook {
        switch phase {
        case .starting:
            return .init(indicator: "record.circle", indicatorIsDanger: false, timeIsMuted: true, showsResume: false, canPause: false, canRestart: false, stopTitle: "Cancel", canStop: true)
        case .countingDown:
            return .init(indicator: "timer", indicatorIsDanger: false, timeIsMuted: true, showsResume: false, canPause: false, canRestart: false, stopTitle: "Cancel", canStop: true)
        case .recording:
            return .init(indicator: "record.circle.fill", indicatorIsDanger: true, timeIsMuted: false, showsResume: false, canPause: true, canRestart: true, stopTitle: "Stop", canStop: true)
        case .paused:
            return .init(indicator: "pause.fill", indicatorIsDanger: false, timeIsMuted: true, showsResume: true, canPause: true, canRestart: true, stopTitle: "Stop", canStop: true)
        case .idle, .stopping:
            return .init(indicator: "record.circle", indicatorIsDanger: false, timeIsMuted: true, showsResume: false, canPause: false, canRestart: false, stopTitle: "Stop", canStop: false)
        }
    }
}

/// A symbol drawn in a colour role, resolved at draw time so it follows the appearance.
private final class SymbolView: NSView {
    var symbol = "record.circle" { didSet { needsDisplay = true } }
    var color = DS.Color.textSecondary { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) { Glyph.draw(symbol, in: bounds, pointSize: DS.Size.iconLarge, color) }
}

/// The bar: what is happening and for how long, then pause or resume, restart, and stop. Dragging its background moves it.
final class RecordingBarView: NSView {
    static let height = DS.Size.control + 2 * DS.Space.s4
    private static let timeFont = NSFont.monospacedDigitSystemFont(ofSize: DS.Text.bodyStrong.size, weight: DS.Text.bodyStrong.weight)

    private let indicator = SymbolView()
    let time = NSTextField.label("0:00", style: DS.Text.bodyStrong, color: DS.Color.textPrimary)
    private let divider = Separator(axis: .vertical)
    let pause = IconButton(symbol: "pause.fill", label: "Pause")
    let resume = IconButton(symbol: "play.fill", label: "Resume")
    let restart = IconButton(symbol: "arrow.counterclockwise", label: "Restart")
    /// Restart throws the take away, so it asks once more in place: a second click within a few seconds confirms.
    let confirmRestart = Button(title: "Discard take", variant: .dangerGhost)
    let stop = Button(title: "Stop", variant: .secondary)
    /// The microphone's level, or its warning, shown only when the recording has a microphone.
    let microphone = MicrophoneSlotView()
    var showsMicrophone = false {
        didSet { if showsMicrophone != oldValue { microphone.isHidden = !showsMicrophone; layoutBar() } }
    }
    private var disarm: DispatchWorkItem?
    private(set) var isRestartArmed = false
    private(set) var look = RecordingBarLook.of(.idle)

    var onPause: () -> Void = {}
    var onResume: () -> Void = {}
    var onRestart: () -> Void = {}
    var onStop: () -> Void = {}

    init() {
        super.init(frame: .zero)
        // The bar floats over any screen, so it is the dark surface whatever the system is set to.
        appearance = NSAppearance(named: .darkAqua)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Recording controls")
        time.font = Self.timeFont
        time.setAccessibilityIdentifier("recording.time")
        pause.setAccessibilityIdentifier("recording.pause")
        resume.setAccessibilityIdentifier("recording.resume")
        restart.setAccessibilityIdentifier("recording.restart")
        stop.setAccessibilityIdentifier("recording.stop")
        restart.toolTip = "Restart: discard this take and start again"
        confirmRestart.setAccessibilityIdentifier("recording.confirmRestart")
        confirmRestart.toolTip = "Click again to discard this take and start over"
        for (button, action) in [(pause, #selector(pauseTapped)), (resume, #selector(resumeTapped)), (restart, #selector(restartTapped)),
                                 (confirmRestart, #selector(confirmTapped)), (stop, #selector(stopTapped))] as [(NSButton, Selector)] {
            button.target = self
            button.action = action
        }
        microphone.isHidden = true
        [indicator, time, microphone, divider, pause, resume, restart, confirmRestart, stop].forEach(addSubview)
        apply(RecordingStatus(phase: .idle, seconds: 0))
    }

    required init?(coder: NSCoder) { fatalError("RecordingBarView is created in code") }

    override var mouseDownCanMoveWindow: Bool { true }

    @objc private func pauseTapped() { onPause() }
    @objc private func resumeTapped() { onResume() }
    @objc private func restartTapped() { setRestartArmed(true) }
    @objc private func confirmTapped() {
        setRestartArmed(false)
        onRestart()
    }

    private func setRestartArmed(_ armed: Bool) {
        disarm?.cancel()
        isRestartArmed = armed
        if armed {
            let work = DispatchWorkItem { [weak self] in self?.setRestartArmed(false) }
            disarm = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
        }
        apply(lastStatus)
    }
    private var lastStatus = RecordingStatus(phase: .idle, seconds: 0)
    @objc private func stopTapped() { onStop() }

    func apply(_ status: RecordingStatus) {
        let look = RecordingBarLook.of(status.phase)
        self.look = look
        lastStatus = status
        if !look.canRestart, isRestartArmed { isRestartArmed = false }
        indicator.symbol = look.indicator
        // dangerText keeps 3:1 against the bar over any screen content; dangerSolid measured 2.72:1 over white.
        indicator.color = look.indicatorIsDanger ? DS.Color.dangerText : DS.Color.textSecondary
        time.stringValue = status.timeText
        time.textColor = look.timeIsMuted ? DS.Color.textSecondary : DS.Color.textPrimary
        time.setAccessibilityLabel(status.spoken)
        pause.isHidden = look.showsResume
        resume.isHidden = !look.showsResume
        pause.isEnabled = look.canPause
        resume.isEnabled = look.canPause
        restart.isEnabled = look.canRestart
        restart.isHidden = isRestartArmed
        confirmRestart.isHidden = !isRestartArmed
        if stop.title != look.stopTitle {
            stop.title = look.stopTitle
            stop.setAccessibilityLabel(look.stopTitle)
        }
        stop.isEnabled = look.canStop
        layoutBar()
    }

    /// Wide enough for every time under an hour, so the buttons hold still as the seconds tick.
    private var timeWidth: CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [.font: Self.timeFont]
        return ceil(max(("00:00" as NSString).size(withAttributes: attributes).width, (time.stringValue as NSString).size(withAttributes: attributes).width))
    }

    var fittingWidth: CGFloat {
        DS.Space.s12 + DS.Size.iconLarge + DS.Space.s6 + timeWidth + DS.Space.s8 + microphoneWidth + 1 + DS.Space.s8
            + DS.Size.control + DS.Space.s6 + restartWidth + DS.Space.s6 + stop.intrinsicContentSize.width + DS.Space.s4
    }

    private var microphoneWidth: CGFloat { showsMicrophone ? MicrophoneSlotView.width + DS.Space.s8 : 0 }

    private var restartWidth: CGFloat { isRestartArmed ? confirmRestart.intrinsicContentSize.width : DS.Size.control
    }

    private func layoutBar() {
        let h = Self.height, mid = h / 2
        var x = DS.Space.s12
        indicator.frame = CGRect(x: x, y: mid - DS.Size.iconLarge / 2, width: DS.Size.iconLarge, height: DS.Size.iconLarge)
        x += DS.Size.iconLarge + DS.Space.s6
        let line = DS.Text.bodyStrong.lineHeight
        time.frame = CGRect(x: x, y: mid - line / 2, width: timeWidth, height: line)
        x += timeWidth + DS.Space.s8
        if showsMicrophone {
            microphone.frame = CGRect(x: x, y: mid - DS.Size.controlSmall / 2, width: MicrophoneSlotView.width, height: DS.Size.controlSmall)
            x += MicrophoneSlotView.width + DS.Space.s8
        }
        divider.frame = CGRect(x: x, y: mid - DS.Space.s8, width: 1, height: DS.Space.s16)
        x += 1 + DS.Space.s8
        let c = DS.Size.control
        pause.frame = CGRect(x: x, y: mid - c / 2, width: c, height: c)
        resume.frame = pause.frame
        x += c + DS.Space.s6
        restart.frame = CGRect(x: x, y: mid - c / 2, width: c, height: c)
        confirmRestart.frame = CGRect(x: x, y: mid - c / 2, width: confirmRestart.intrinsicContentSize.width, height: c)
        x += restartWidth + DS.Space.s6
        let w = stop.intrinsicContentSize.width
        stop.frame = CGRect(x: x, y: mid - c / 2, width: w, height: c)
        setFrameSize(NSSize(width: fittingWidth, height: h))
        if let window, window.contentView === self, window.frame.size != frame.size { window.setContentSize(frame.size) }
    }

    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath.continuous(bounds, radius: DS.Radius.lg)
        DS.Color.bgHud.setFill()
        shape.fill()
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        DS.Color.border.setStroke()
        shape.lineWidth = 2
        shape.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// Darkens everything outside the recorded area and outlines it. It takes no clicks, so the screen works as usual underneath.
final class RecordingDimView: NSView {
    /// The recorded area in this view's coordinates.
    var hole = CGRect.zero { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let outside = NSBezierPath(rect: bounds)
        outside.append(NSBezierPath(rect: hole))
        outside.windingRule = .evenOdd
        DS.Color.bgScrim.setFill()
        outside.fill()
        // The outline sits just outside the area, so the recorded pixels are never touched by it.
        DS.Color.selectionHalo.setStroke()
        NSBezierPath(rect: hole.insetBy(dx: -1.5, dy: -1.5)).stroke()
        DS.Color.selectionStroke.setStroke()
        NSBezierPath(rect: hole.insetBy(dx: -0.5, dy: -0.5)).stroke()
    }
}

/// The windows a recording shows on screen: the control bar, the countdown, and the darkening outside an area. None of them is in
/// the video. The menu bar's time comes from `onStatus`.
@MainActor
final class RecordingControls {
    private let env: AppEnvironment
    private let recording: RecordingController
    private(set) var bar: RecordingPanel?
    private(set) var barView: RecordingBarView?
    private(set) var dim: RecordingPanel?
    private(set) var dimView: RecordingDimView?
    private(set) var countdown: RecordingPanel?
    private(set) var countdownView: CountdownView?
    private var ticker: Timer?
    private var moved: NSObjectProtocol?
    /// Where the user last dragged the bar, kept for the next recording while the app runs.
    private(set) var rememberedOrigin: CGPoint?
    var onStatus: (RecordingStatus) -> Void = { _ in }
    let camera: CameraBubbleWindow

    init(env: AppEnvironment, recording: RecordingController) {
        self.env = env
        self.recording = recording
        camera = CameraBubbleWindow(env: env, recording: recording)
        recording.onChange = { [weak self] in self?.update() }
        recording.onCameraChange = { [weak self] in self?.camera.update() }
        recording.onMicrophone = { [weak self] in self?.microphoneChanged() }
    }

    private var wasSilent = false

    private func microphoneChanged() {
        let status = recording.microphone
        barView?.microphone.apply(status)
        let silent = status?.isSilent ?? false
        guard silent != wasSilent else { return }
        wasSilent = silent
        // VoiceOver hears it once when the sound stops and once when it comes back, never each tick.
        if let view = barView {
            let words = silent ? "No sound from the microphone. Check that it is not muted." : "The microphone has sound again."
            let priority: NSAccessibilityPriorityLevel = silent ? .high : .medium
            NSAccessibility.post(element: view, notification: .announcementRequested, userInfo: [.announcement: words, .priority: priority.rawValue])
        }
    }

    var status: RecordingStatus { RecordingStatus(phase: recording.phase, seconds: recording.seconds) }

    /// The display a recorded area is on, in global points, with and without the menu bar and the Dock.
    static func screen(for area: CGRect) -> (frame: CGRect, visible: CGRect) {
        let screen = NSScreen.screens.max { $0.frame.intersection(area).width * $0.frame.intersection(area).height < $1.frame.intersection(area).width * $1.frame.intersection(area).height }
        return screen.map { ($0.frame, $0.visibleFrame) } ?? (area, area)
    }

    private var announced: RecordingController.Phase = .idle

    func update() {
        let s = status
        if s.phase != announced {
            announced = s.phase
            // VoiceOver hears each phase once, never each tick.
            if s.phase != .idle, let view = barView {
                NSAccessibility.post(element: view, notification: .announcementRequested,
                                     userInfo: [.announcement: s.spoken, .priority: NSAccessibilityPriorityLevel.high.rawValue])
            }
        }
        if s.phase == .idle {
            tearDown()
        } else if let area = recording.area {
            showBar(area: area)
            showDim(area: area)
            if case .countingDown(let n) = s.phase { showCountdown(n, area: area) } else { closeCountdown() }
        }
        camera.update(animated: false)
        barView?.showsMicrophone = recording.hearsMicrophone
        barView?.apply(s)
        if s.phase.isRunning, ticker == nil {
            let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
            RunLoop.main.add(t, forMode: .common)
            ticker = t
        } else if !s.phase.isRunning {
            ticker?.invalidate()
            ticker = nil
        }
        onStatus(s)
    }

    private func tick() {
        let s = status
        barView?.apply(s)
        onStatus(s)
    }

    private func showBar(area: CGRect) {
        guard bar == nil else { return }
        let view = RecordingBarView()
        view.onPause = { [unowned self] in recording.pause() }
        view.onResume = { [unowned self] in recording.resume() }
        view.onRestart = { [unowned self] in recording.restart() }
        view.onStop = { [unowned self] in recording.stop() }
        view.showsMicrophone = recording.hearsMicrophone
        view.apply(status)
        let visible = Self.screen(for: area).visible
        let origin = RecordingBarLayout.origin(size: view.frame.size, area: area, visible: visible, remembered: rememberedOrigin)
        let panel = RecordingPanel(frame: CGRect(origin: origin, size: view.frame.size), level: .statusBar, title: "Recording Controls")
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.contentView = view
        bar = panel
        barView = view
        present(panel)
        moved = NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: panel, queue: .main) { [weak self] note in
            guard let window = note.object as? NSWindow else { return }
            MainActor.assumeIsolated { self?.rememberedOrigin = window.frame.origin }
        }
    }

    /// Only an area is darkened around. A window or a whole display has nothing outside it worth hiding.
    private func showDim(area: CGRect) {
        guard dim == nil, recording.preferences.dimOutside, case .display(_, area: .some) = recording.target else { return }
        let frame = Self.screen(for: area).frame
        let view = RecordingDimView(frame: CGRect(origin: .zero, size: frame.size))
        view.hole = area.offsetBy(dx: -frame.minX, dy: -frame.minY)
        // Over the Dock and every app, under the menu bar, so the time there stays readable.
        let panel = RecordingPanel(frame: frame, level: NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue - 1), title: "Recording Dim")
        panel.ignoresMouseEvents = true
        panel.contentView = view
        dim = panel
        dimView = view
        present(panel)
    }

    private func showCountdown(_ n: Int, area: CGRect) {
        if countdown == nil {
            let size = CountdownView.size
            let view = CountdownView(frame: CGRect(origin: .zero, size: size), hint: "Recording starts")
            let panel = RecordingPanel(frame: CGRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2, width: size.width, height: size.height),
                                       level: .statusBar, title: "Recording Countdown")
            panel.ignoresMouseEvents = true
            view.appearance = NSAppearance(named: .darkAqua)
            panel.contentView = view
            countdown = panel
            countdownView = view
            view.remaining = n
            present(panel)
        }
        countdownView?.remaining = n
    }

    private func closeCountdown() {
        guard let countdown else { return }
        dismiss(countdown)
        self.countdown = nil
        countdownView = nil
    }

    private func tearDown() {
        ticker?.invalidate()
        ticker = nil
        if let moved { NotificationCenter.default.removeObserver(moved) }
        moved = nil
        closeCountdown()
        [bar, dim].compactMap { $0 }.forEach(dismiss)
        bar = nil; barView = nil; dim = nil; dimView = nil
    }

    /// Enters with a short fade and a slight grow from 96%, or only the fade when motion is reduced.
    private func present(_ panel: RecordingPanel) {
        panel.contentView?.wantsLayer = true
        env.present(panel, activate: false)
        guard env.isOnscreen, let layer = panel.contentView?.layer else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0; fade.toValue = 1
        fade.duration = DS.Motion.Duration.base
        fade.timingFunction = DS.Motion.Curve.easeOut
        layer.add(fade, forKey: "enter")
        guard !DS.Motion.isReduced, panel !== dim else { return }
        let grow = CABasicAnimation(keyPath: "transform")
        let b = layer.bounds
        var from = CATransform3DMakeTranslation(b.midX, b.midY, 0)
        from = CATransform3DScale(from, DS.Motion.enterScale, DS.Motion.enterScale, 1)
        from = CATransform3DTranslate(from, -b.midX, -b.midY, 0)
        grow.fromValue = NSValue(caTransform3D: from)
        grow.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        grow.duration = DS.Motion.Duration.base
        grow.timingFunction = DS.Motion.Curve.easeOut
        layer.add(grow, forKey: "grow")
    }

    /// Leaves faster than it came, and only by fading.
    private func dismiss(_ panel: RecordingPanel) {
        guard env.isOnscreen, panel.isVisible else { panel.close(); return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = DS.Motion.Duration.fast
            ctx.timingFunction = DS.Motion.Curve.easeOut
            panel.animator().alphaValue = 0
        }, completionHandler: { panel.close() })
    }
}
