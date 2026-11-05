#if DEBUG
import AppKit
import CornermarkCapture
import CornermarkCore
import CornermarkDesign

/// What a scripted instance's test window shows instead of its synthetic scene, read from `<root>/test-stage.json` each time the window
/// opens, so verification can film real views through the real window path. `{"stage": "audio", "tour": true}` shows the Audio pane
/// beside a copy of the control bar that follows the running recording. With `tour`, the pane's own controls are clicked on a timeline.
struct RecordingTestStageFile: Decodable {
    var stage: String
    var tour: Bool?

    static func read(root: URL) -> RecordingTestStageFile? {
        (try? Data(contentsOf: root.appendingPathComponent("test-stage.json"))).flatMap { try? JSONDecoder().decode(Self.self, from: $0) }
    }
}

/// The Audio pane and the recording's control bar, both the real views, in one window a recording can film. Holds no user content.
@MainActor
final class AudioTestStage: NSView {
    static let size = CGSize(width: 960, height: 600)
    private let pane: AudioPane
    private let recording: RecordingController
    private let controls: RecordingControls
    private let bar = RecordingBarView()
    private let flash = NSView()
    private let status = NSTextField.label("", style: DS.Text.readout, color: DS.Color.textSecondary)
    private let step = NSTextField.label("", style: DS.Text.bodyStrong, color: DS.Color.textPrimary)
    private var timer: Timer?
    /// The tour's clock starts with the recording, so each step lands at the same moment of the video.
    private var started: Double?
    private var tour: [(at: Double, title: String, act: (AudioTestStage) -> Void)] = []
    private var toured = 0

    init(ctx: SettingsContext, recording: RecordingController, controls: RecordingControls, tour: Bool) {
        pane = AudioPane(ctx)
        self.recording = recording
        self.controls = controls
        super.init(frame: CGRect(origin: .zero, size: Self.size))
        let light = NSAppearance(named: .aqua)!
        appearance = light
        wantsLayer = true
        // A layer colour is resolved once, so it is resolved in the stage's own appearance.
        light.performAsCurrentDrawingAppearance { self.layer?.backgroundColor = DS.Color.bgWindow.cgColor }
        let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 560, height: Self.size.height))
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.documentView = pane.view
        pane.view.frame.size.width = 560
        scroll.contentView.scroll(to: CGPoint(x: 0, y: max(0, pane.view.frame.height - Self.size.height)))
        addSubview(scroll)
        let side = NSView(frame: CGRect(x: 560, y: 0, width: 400, height: Self.size.height))
        side.wantsLayer = true
        light.performAsCurrentDrawingAppearance { side.layer?.backgroundColor = DS.Color.bgSurface.cgColor }
        addSubview(side)
        let heading = NSTextField.label("While recording", style: DS.Text.heading, color: DS.Color.textPrimary)
        heading.frame = CGRect(x: 24, y: Self.size.height - 64, width: 352, height: 24)
        side.addSubview(heading)
        bar.frame.origin = CGPoint(x: 24, y: Self.size.height - 120)
        side.addSubview(bar)
        step.frame = CGRect(x: 24, y: 300, width: 352, height: 40)
        step.maximumNumberOfLines = 2
        side.addSubview(step)
        status.frame = CGRect(x: 24, y: 180, width: 352, height: 110)
        status.maximumNumberOfLines = 7
        status.lineBreakMode = .byWordWrapping
        side.addSubview(status)
        flash.frame = CGRect(x: 24, y: 24, width: 352, height: 140)
        flash.wantsLayer = true
        side.addSubview(flash)
        if tour { self.tour = Self.audioTour }
        pane.paneDidShow()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        tick()
    }

    required init?(coder: NSCoder) { fatalError("AudioTestStage is created in code") }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            timer?.invalidate()
            timer = nil
            pane.paneDidHide()
        }
    }

    /// Clicks the pane's own controls, as a person would, a few seconds apart.
    private static let audioTour: [(at: Double, title: String, act: (AudioTestStage) -> Void)] = [
        (2, "Microphone: Test Interface, input 1 of 2", { $0.choose("audio.device", 2) }),
        (5, "Record in mono: off", { $0.press("audio.mono") }),
        (8, "Record in mono: on", { $0.press("audio.mono") }),
        (11, "Microphone: System default", { $0.choose("audio.device", 0) }),
        (13, "Record system audio: on", { $0.press("audio.system") }),
    ]

    private func press(_ id: String) { (findControl(id) as? NSButton)?.performClick(nil) }

    private func choose(_ id: String, _ index: Int) {
        guard let popup = findControl(id) as? NSPopUpButton else { return }
        popup.selectItem(at: index)
        popup.sendAction(popup.action, to: popup.target)
    }

    private func findControl(_ id: String, in view: NSView? = nil) -> NSView? {
        let root = view ?? pane.view
        if root.accessibilityIdentifier() == id { return root }
        for sub in root.subviews { if let hit = findControl(id, in: sub) { return hit } }
        return nil
    }

    private func tick() {
        let s = controls.status
        if started == nil, s.phase == .recording { started = recordingClockNow() }
        let t = started.map { recordingClockNow() - $0 } ?? -1
        while toured < tour.count, tour[toured].at <= t {
            tour[toured].act(self)
            step.stringValue = tour[toured].title
            Log.shell.notice("test stage step=\(self.tour[self.toured].title, privacy: .public) at=\(String(format: "%.2f", t), privacy: .public)")
            toured += 1
        }
        bar.showsMicrophone = recording.hearsMicrophone
        bar.apply(s)
        bar.microphone.apply(recording.microphone)
        let a = pane.settings.recording.audio
        let mic = recording.microphone
        status.stringValue = """
        phase \(String(describing: s.phase))  video \(String(format: "%.2f", s.seconds)) s
        microphone \(a.microphone ? "on" : "off")  mono \(a.mono ? "on" : "off")  system \(a.systemAudio ? "on" : "off")
        device \(a.microphoneID ?? "system default")
        level \(mic.map { String(format: "%.0f dBFS", AudioLevel.decibels($0.level.rms, floor: -96)) } ?? "-")  silent \(mic.map { $0.isSilent ? "yes" : "no" } ?? "-")
        clock \(String(format: "%.3f", recordingClockNow()))
        """
        // White for a tenth of a second from each whole second of the recording clock, when the scripted system sound clicks.
        let clicks = AudioPattern.systemClicks
        let into = (recordingClockNow() - clicks.epoch).truncatingRemainder(dividingBy: clicks.period)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        flash.layer?.backgroundColor = (a.systemAudio && into < 0.1 ? NSColor.white : NSColor.black).cgColor
        CATransaction.commit()
    }
}
#endif
