import AppKit
import CornermarkCapture
import CornermarkCore
import CornermarkDesign
import CornermarkL10n

/// What the controls and the menu bar show: the phase and the length of the video so far.
struct RecordingStatus: Equatable {
    var phase: RecordingController.Phase
    var seconds: Double

    var timeText: String { ImageOutput.durationText(seconds) }

    /// The words a screen reader says for the indicator.
    var spoken: String {
        switch phase {
        case .countingDown(let n): return tr("Recording starts in {count}", ["count": n])
        case .paused: return tr("Recording paused at {time}", ["time": timeText])
        case .recording: return tr("Recording, {time}", ["time": timeText])
        case .starting: return tr("Preparing to record")
        case .stopping: return tr("Saving recording")
        case .idle: return tr("Not recording")
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
    /// The mark at the start of the stop button: what a click ends. Red while frames are being kept. A filled circle symbol would draw as
    /// a plain dot in one colour, which reads as record, so the stop mark stays the outlined circle with its square.
    var stopSymbol: String
    var stopIsDanger: Bool
    var timeIsMuted: Bool
    /// The pause button, or in its place the resume button.
    var showsResume: Bool
    var canPause: Bool
    /// Restart and delete both need frames to throw away.
    var canDiscard: Bool
    /// Whether the stop button cancels a recording that has not begun, rather than ending one.
    var stopCancels: Bool
    var canStop: Bool

    var stopTitle: String { stopCancels ? tr("Cancel") : tr("Stop") }

    static func of(_ phase: RecordingController.Phase) -> RecordingBarLook {
        switch phase {
        case .starting, .countingDown:
            return .init(stopSymbol: "xmark.circle", stopIsDanger: false, timeIsMuted: true, showsResume: false, canPause: false, canDiscard: false, stopCancels: true, canStop: true)
        case .recording:
            return .init(stopSymbol: "stop.circle", stopIsDanger: true, timeIsMuted: false, showsResume: false, canPause: true, canDiscard: true, stopCancels: false, canStop: true)
        case .paused:
            return .init(stopSymbol: "stop.circle", stopIsDanger: false, timeIsMuted: true, showsResume: true, canPause: true, canDiscard: true, stopCancels: false, canStop: true)
        case .idle, .stopping:
            return .init(stopSymbol: "stop.circle", stopIsDanger: false, timeIsMuted: true, showsResume: false, canPause: false, canDiscard: false, stopCancels: false, canStop: false)
        }
    }
}

/// A symbol drawn in a colour role, resolved at draw time so it follows the appearance. Clicks pass through to the button under it.
private final class SymbolView: NSView {
    var symbol = "record.circle" { didSet { needsDisplay = true } }
    var color = DS.Color.textSecondary { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) { Glyph.draw(symbol, in: bounds, pointSize: DS.Size.iconLarge, color) }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The time sits on the stop button, so a click on it reaches the button.
private final class PassThroughLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Six dots that say the bar can be dragged. The whole background drags it; this only makes that visible.
final class RecordingBarGrip: NSView {
    static let width = DS.Space.s12
    override var mouseDownCanMoveWindow: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        DS.Color.textSecondary.setFill()
        let d: CGFloat = 2.5
        for col in 0..<2 {
            for row in 0..<3 {
                let x = bounds.midX - 3 + CGFloat(col) * 4 - d / 2
                let y = bounds.midY - 5 + CGFloat(row) * 5 - d / 2
                NSBezierPath(ovalIn: CGRect(x: x, y: y, width: d, height: d)).fill()
            }
        }
    }
}

/// The bar: the stop button that carries the length so far, then pause or resume, restart, delete, and the grip. Dragging its
/// background moves it.
final class RecordingBarView: NSView {
    static let height = DS.Size.control + 2 * DS.Space.s4
    private static let timeFont = NSFont.monospacedDigitSystemFont(ofSize: DS.Text.bodyStrong.size, weight: DS.Text.bodyStrong.weight)

    /// What a second click confirms. Only one of them waits at a time.
    enum Armed: Equatable { case restart, delete }

    private let indicator = SymbolView()
    let time: NSTextField = PassThroughLabel(labelWithString: "0:00")
    /// The red stop mark and the time together are the stop button, the one thing a recording most often needs.
    let stop = Button(title: "", variant: .ghost)
    private let divider = Separator(axis: .vertical)
    let pause = IconButton(symbol: "pause.fill", label: tr("Pause"))
    let resume = IconButton(symbol: "play.fill", label: tr("Resume"))
    let restart = IconButton(symbol: "arrow.counterclockwise", label: tr("Restart"))
    /// Restart throws the take away, so it asks once more in place: a second click within a few seconds confirms.
    let confirmRestart = Button(title: tr("Discard take"), variant: .dangerGhost)
    let delete = IconButton(symbol: "trash", label: tr("Delete"))
    /// Delete ends the recording and keeps nothing, so it asks the same way.
    let confirmDelete = Button(title: tr("Delete recording"), variant: .dangerGhost)
    let grip = RecordingBarGrip()
    /// The microphone's level, or its warning, shown only when the recording has a microphone.
    let microphone = MicrophoneSlotView()
    var showsMicrophone = false {
        didSet { if showsMicrophone != oldValue { microphone.isHidden = !showsMicrophone; layoutBar() } }
    }
    private var disarm: DispatchWorkItem?
    private(set) var armed: Armed?
    var isRestartArmed: Bool { armed == .restart }
    var isDeleteArmed: Bool { armed == .delete }
    private(set) var look = RecordingBarLook.of(.idle)

    var onPause: () -> Void = {}
    var onResume: () -> Void = {}
    var onRestart: () -> Void = {}
    var onDelete: () -> Void = {}
    var onStop: () -> Void = {}

    init() {
        super.init(frame: .zero)
        // The bar floats over any screen, so it is the dark surface whatever the system is set to.
        appearance = NSAppearance(named: .darkAqua)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        time.font = Self.timeFont
        time.textColor = DS.Color.textPrimary
        time.setAccessibilityElement(false)
        time.setAccessibilityIdentifier("recording.time")
        stop.setAccessibilityIdentifier("recording.stop")
        pause.setAccessibilityIdentifier("recording.pause")
        resume.setAccessibilityIdentifier("recording.resume")
        restart.setAccessibilityIdentifier("recording.restart")
        delete.setAccessibilityIdentifier("recording.delete")
        grip.setAccessibilityElement(false)
        confirmRestart.setAccessibilityIdentifier("recording.confirmRestart")
        confirmDelete.setAccessibilityIdentifier("recording.confirmDelete")
        for (button, action) in [(pause, #selector(pauseTapped)), (resume, #selector(resumeTapped)), (restart, #selector(restartTapped)),
                                 (confirmRestart, #selector(confirmRestartTapped)), (delete, #selector(deleteTapped)),
                                 (confirmDelete, #selector(confirmDeleteTapped)), (stop, #selector(stopTapped))] as [(NSButton, Selector)] {
            button.target = self
            button.action = action
        }
        microphone.isHidden = true
        [stop, indicator, time, microphone, divider, pause, resume, restart, confirmRestart, delete, confirmDelete, grip].forEach(addSubview)
        applyLanguageDirection()
        relocalize()
    }

    required init?(coder: NSCoder) { fatalError("RecordingBarView is created in code") }

    /// Writes every label, tooltip and spoken phrase again in the current language, and lays the bar out for its direction.
    func relocalize() {
        setAccessibilityLabel(tr("Recording controls"))
        pause.rename(tr("Pause"))
        resume.rename(tr("Resume"))
        restart.rename(tr("Restart"))
        delete.rename(tr("Delete"))
        pause.toolTip = tr("Pause recording")
        resume.toolTip = tr("Resume recording")
        restart.toolTip = tr("Restart: discard this take and start again")
        confirmRestart.title = tr("Discard take")
        confirmRestart.setAccessibilityLabel(tr("Discard take"))
        confirmRestart.toolTip = tr("Click again to discard this take and start again")
        delete.toolTip = tr("Delete: stop and keep nothing")
        delete.setAccessibilityHelp(tr("Stops the recording and deletes it. Asks once more first."))
        confirmDelete.title = tr("Delete recording")
        confirmDelete.setAccessibilityLabel(tr("Delete recording"))
        confirmDelete.toolTip = tr("Click again to stop and delete this recording")
        grip.toolTip = tr("Drag to move")
        applyLanguageDirection()
        apply(lastStatus)
    }

    override var mouseDownCanMoveWindow: Bool { true }

    @objc private func pauseTapped() { onPause() }
    @objc private func resumeTapped() { onResume() }
    @objc private func restartTapped() { arm(.restart) }
    @objc private func confirmRestartTapped() {
        arm(nil)
        onRestart()
    }
    @objc private func deleteTapped() { arm(.delete) }
    @objc private func confirmDeleteTapped() {
        arm(nil)
        onDelete()
    }

    private func arm(_ next: Armed?) {
        disarm?.cancel()
        armed = next
        if next != nil {
            let work = DispatchWorkItem { [weak self] in self?.arm(nil) }
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
        if !look.canDiscard, armed != nil { armed = nil }
        indicator.symbol = look.stopSymbol
        // dangerText keeps 3:1 against the bar over any screen content; dangerSolid measured 2.72:1 over white.
        indicator.color = look.stopIsDanger ? DS.Color.dangerText : (look.canStop ? DS.Color.textSecondary : DS.Color.textDisabled)
        time.stringValue = status.timeText
        time.textColor = look.timeIsMuted ? DS.Color.textSecondary : DS.Color.textPrimary
        let spoken = look.stopCancels ? tr("Cancel recording. {status}", ["status": status.spoken]) : tr("Stop recording. {status}", ["status": status.spoken])
        stop.setAccessibilityLabel(spoken)
        stop.toolTip = look.stopCancels ? tr("Cancel recording") : tr("Stop recording")
        stop.isEnabled = look.canStop
        pause.isHidden = look.showsResume
        resume.isHidden = !look.showsResume
        pause.isEnabled = look.canPause
        resume.isEnabled = look.canPause
        restart.isEnabled = look.canDiscard
        delete.isEnabled = look.canDiscard
        restart.isHidden = armed == .restart
        confirmRestart.isHidden = armed != .restart
        delete.isHidden = armed == .delete
        confirmDelete.isHidden = armed != .delete
        layoutBar()
    }

    /// Wide enough for every time under an hour, so the buttons hold still as the seconds tick.
    private var timeWidth: CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [.font: Self.timeFont]
        return ceil(max(("00:00" as NSString).size(withAttributes: attributes).width, (time.stringValue as NSString).size(withAttributes: attributes).width))
    }

    private var stopWidth: CGFloat { DS.Space.s8 + DS.Size.iconLarge + DS.Space.s6 + timeWidth + DS.Space.s8 }
    private var microphoneWidth: CGFloat { showsMicrophone ? MicrophoneSlotView.width + DS.Space.s8 : 0 }
    private var restartWidth: CGFloat { armed == .restart ? confirmRestart.intrinsicContentSize.width : DS.Size.control }
    private var deleteWidth: CGFloat { armed == .delete ? confirmDelete.intrinsicContentSize.width : DS.Size.control }

    var fittingWidth: CGFloat {
        DS.Space.s4 + stopWidth + DS.Space.s4 + microphoneWidth + 1 + DS.Space.s8
            + DS.Size.control + DS.Space.s4 + restartWidth + DS.Space.s4 + deleteWidth + DS.Space.s4 + RecordingBarGrip.width + DS.Space.s4
    }

    private func layoutBar() {
        let h = Self.height, mid = h / 2, c = DS.Size.control
        var x = DS.Space.s4
        stop.frame = CGRect(x: x, y: mid - c / 2, width: stopWidth, height: c)
        x += DS.Space.s8
        indicator.frame = CGRect(x: x, y: mid - DS.Size.iconLarge / 2, width: DS.Size.iconLarge, height: DS.Size.iconLarge)
        x += DS.Size.iconLarge + DS.Space.s6
        let line = DS.Text.bodyStrong.lineHeight
        time.frame = CGRect(x: x, y: mid - line / 2, width: timeWidth, height: line)
        x = stop.frame.maxX + DS.Space.s4
        if showsMicrophone {
            microphone.frame = CGRect(x: x, y: mid - DS.Size.controlSmall / 2, width: MicrophoneSlotView.width, height: DS.Size.controlSmall)
            x += MicrophoneSlotView.width + DS.Space.s8
        }
        divider.frame = CGRect(x: x, y: mid - DS.Space.s8, width: 1, height: DS.Space.s16)
        x += 1 + DS.Space.s8
        pause.frame = CGRect(x: x, y: mid - c / 2, width: c, height: c)
        resume.frame = pause.frame
        x += c + DS.Space.s4
        restart.frame = CGRect(x: x, y: mid - c / 2, width: c, height: c)
        confirmRestart.frame = CGRect(x: x, y: mid - c / 2, width: confirmRestart.intrinsicContentSize.width, height: c)
        x += restartWidth + DS.Space.s4
        delete.frame = CGRect(x: x, y: mid - c / 2, width: c, height: c)
        confirmDelete.frame = CGRect(x: x, y: mid - c / 2, width: confirmDelete.intrinsicContentSize.width, height: c)
        x += deleteWidth + DS.Space.s4
        grip.frame = CGRect(x: x, y: mid - c / 2, width: RecordingBarGrip.width, height: c)
        setFrameSize(NSSize(width: fittingWidth, height: h))
        // Everything above was placed left to right; a right-to-left language reads the bar from its other end.
        if isRightToLeft {
            for view in subviews { view.frame = mirrored(view.frame, within: fittingWidth) }
        }
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
    private var language: LanguageObserver?
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
        language = LanguageObserver { [weak self] in self?.relocalize() }
    }

    /// The bar, the countdown and the panels' titles follow the language while a recording runs. The recording itself is untouched.
    private func relocalize() {
        bar?.title = tr("Recording Controls")
        dim?.title = tr("Recording Dim")
        countdown?.title = tr("Recording Countdown")
        barView?.relocalize()
        if let countdown, let old = countdownView {
            let view = CountdownView(frame: old.frame, hint: tr("Recording starts"))
            view.appearance = NSAppearance(named: .darkAqua)
            view.remaining = old.remaining
            view.wantsLayer = true
            countdown.contentView = view
            countdownView = view
        }
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
            let words = silent ? tr("No sound from the microphone. Check that it is not muted.") : tr("The microphone has sound again.")
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
        view.onDelete = { [unowned self] in recording.discard() }
        view.onStop = { [unowned self] in recording.stop() }
        view.showsMicrophone = recording.hearsMicrophone
        view.apply(status)
        let visible = Self.screen(for: area).visible
        let origin = RecordingBarLayout.origin(size: view.frame.size, area: area, visible: visible, remembered: rememberedOrigin)
        let panel = RecordingPanel(frame: CGRect(origin: origin, size: view.frame.size), level: .statusBar, title: tr("Recording Controls"))
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
        let panel = RecordingPanel(frame: frame, level: NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue - 1), title: tr("Recording Dim"))
        panel.ignoresMouseEvents = true
        panel.contentView = view
        dim = panel
        dimView = view
        present(panel)
    }

    private func showCountdown(_ n: Int, area: CGRect) {
        if countdown == nil {
            let size = CountdownView.size
            let view = CountdownView(frame: CGRect(origin: .zero, size: size), hint: tr("Recording starts"))
            let panel = RecordingPanel(frame: CGRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2, width: size.width, height: size.height),
                                       level: .statusBar, title: tr("Recording Countdown"))
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
