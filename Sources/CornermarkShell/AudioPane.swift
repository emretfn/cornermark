import AppKit
import CornermarkCapture
import CornermarkCore
import CornermarkDesign
import CornermarkL10n

/// The sound a recording takes: the microphone, with its device, level and mono mix, and what the Mac plays.
final class AudioPane: SettingsPane {
    override var paneID: String { "audio" }
    override var paneTitle: String { tr("Audio") }
    override var symbol: String { "mic" }
    private let microphone = Form.checkbox(id: "audio.microphone")
    private let device = Form.popup(id: "audio.device")
    let meter = LevelMeterView()
    private let meterNote = Form.caption("")
    private let mono = Form.checkbox(id: "audio.mono")
    private let system = Form.checkbox(id: "audio.system")
    private let accessStatus = NSTextField.label("", style: DS.Text.bodyStrong, color: DS.Color.textPrimary)
    private let accessDot = StatusDot()
    private let accessNote = Form.caption("")
    private let accessOpen = Button(title: "", variant: .secondary, size: .small)
    private let accessRequest = Button(title: "", variant: .primary, size: .small)
    private let deviceNote = Form.caption("")
    /// The device IDs behind the popup's items, nil for the system default.
    private var deviceIDs: [String?] = []
    private var listening: (source: AudioSource, id: String?, hearing: MicrophoneHearing, timer: Timer)?
    private var isShown = false

    override func buildForm() -> FormPage {
        accessOpen.relabel(tr("Open System Settings"))
        accessRequest.relabel(tr("Request Access"))
        meter.setAccessibilityIdentifier("audio.meter")
        meter.setAccessibilityLabel(tr("Input level"))
        accessRequest.setAccessibilityIdentifier("audio.access.request")
        accessRequest.onAction { [unowned self] _ in ctx.env.requestMicrophoneAccess { [weak self] _ in self?.refresh() } }
        meter.preferredWidth = 160
        accessStatus.setAccessibilityIdentifier("audio.access")
        accessOpen.setAccessibilityIdentifier("audio.access.open")
        accessOpen.onAction { [unowned self] _ in ctx.env.openURL(AppEnvironment.microphonePaneURL) }
        microphone.onAction { [unowned self] c in
            let on = (c as! NSButton).state == .on
            change { $0.recording.audio.microphone = on }
            // The system asks once, when someone first turns the microphone on. Nothing else ever asks.
            if on, ctx.env.microphoneAccess() == .notAsked { ctx.env.requestMicrophoneAccess { [weak self] _ in self?.refresh() } }
        }
        device.onAction { [unowned self] c in
            let i = (c as! NSPopUpButton).indexOfSelectedItem
            guard deviceIDs.indices.contains(i) else { return }
            change { $0.recording.audio.microphoneID = self.deviceIDs[i] }
        }
        mono.onAction { [unowned self] c in change { $0.recording.audio.mono = (c as! NSButton).state == .on } }
        system.onAction { [unowned self] c in change { $0.recording.audio.systemAudio = (c as! NSButton).state == .on } }
        return Form.page(title: paneTitle, groups: [
            .init(tr("Microphone"), rows: [
                Form.row(title: tr("Record microphone"), caption: Form.caption(tr("Record MP4 and Record Project also record your voice.")), control: microphone),
                Form.row(title: tr("Microphone"), caption: deviceNote, control: device),
                Form.row(title: tr("Input level"), caption: meterNote, control: meter),
                Form.row(title: tr("Record in mono"), caption: Form.caption(tr("Mixes the input channels into one, so a voice on one input plays from both sides.")), control: mono),
            ], footer: tr("While recording, the control bar shows the level and says when the microphone gives no sound.")),
            .init(rows: [
                Form.row(title: tr("Microphone access"), caption: accessNote, control: Form.hstack([accessDot, accessStatus, accessRequest, accessOpen], spacing: DS.Space.s6)),
            ]),
            .init(tr("System audio"), rows: [
                Form.row(title: tr("Record system audio"), caption: Form.caption(tr("Records what your Mac plays, with no extra software. Cornermark\u{2019}s own sounds are left out.")),
                         control: system),
            ], footer: tr("Record GIF never records sound.")),
        ])
    }

    override func update() {
        let a = settings.recording.audio
        microphone.state = a.microphone ? .on : .off
        mono.state = a.mono ? .on : .off
        system.state = a.systemAudio ? .on : .off
        updateDevices(a)
        [device, mono].forEach { $0.isEnabled = a.microphone }
        let access = ctx.env.microphoneAccess()
        let blocking = a.microphone && access != .allowed
        switch access {
        case .allowed: accessStatus.stringValue = tr("Allowed")
        case .denied: accessStatus.stringValue = tr("Not allowed")
        case .notAsked: accessStatus.stringValue = tr("Not asked yet")
        }
        accessStatus.textColor = access == .allowed ? DS.Color.successText : blocking ? DS.Color.dangerText : DS.Color.textSecondary
        accessDot.color = accessStatus.textColor ?? DS.Color.textSecondary
        accessNote.textColor = blocking ? DS.Color.dangerText : DS.Color.textSecondary
        accessNote.stringValue = access == .allowed
            ? tr("Cornermark listens only while it records, or while this pane shows the level.")
            : blocking && access == .denied
            ? tr("Your voice is not recorded. Turn on Cornermark in System Settings > Privacy & Security > Microphone, then try again.")
            : blocking
            ? tr("Request access so Cornermark can record your voice.")
            : tr("The microphone needs it. System audio does not.")
        // macOS lists an app under Microphone only once it has asked, so until then the way forward is to ask.
        accessRequest.isHidden = access != .notAsked
        accessRequest.variant = blocking ? .primary : .secondary
        accessOpen.variant = blocking && access == .denied ? .primary : .secondary
        accessOpen.isHidden = access != .denied
        meterNote.stringValue = !a.microphone ? tr("Turn on the microphone to see its level.")
            : access != .allowed ? tr("Shows once Cornermark may use the microphone.")
            : tr("Speak to check the level.")
        if isShown { listen() }
    }

    override func paneDidShow() {
        isShown = true
        listen()
    }

    override func paneDidHide() {
        isShown = false
        stopListening()
    }

    private func updateDevices(_ a: AudioPreferences) {
        let devices = ctx.env.microphones()
        var titles = [tr("System default")]
        deviceIDs = [nil]
        for d in devices {
            titles.append(d.name)
            deviceIDs.append(d.id)
        }
        // A chosen device that is not connected stays chosen, and a recording uses the default until it is back.
        let missing = a.microphoneID.map { id in !devices.contains { $0.id == id } } ?? false
        if missing, let id = a.microphoneID {
            titles.append(tr("Disconnected microphone"))
            deviceIDs.append(id)
        }
        deviceNote.stringValue = missing ? tr("This microphone is not connected. Recordings use System default until it is back.") : ""
        deviceNote.isHidden = !missing
        if device.itemTitles != titles {
            device.removeAllItems()
            device.addItems(withTitles: titles)
        }
        device.selectItem(at: deviceIDs.firstIndex { $0 == a.microphoneID } ?? 0)
    }

    /// Shows the chosen microphone's level while this pane is on show and the microphone is on and allowed.
    private func listen() {
        let a = settings.recording.audio
        guard isShown, a.microphone, ctx.env.microphoneAccess() == .allowed else { return stopListening() }
        if let listening, listening.id == a.microphoneID { return }
        stopListening()
        guard let source = ctx.env.microphoneSource(a.microphoneID) else { return }
        let hearing = MicrophoneHearing(start: recordingClockNow())
        do {
            try source.start { chunk in hearing.hear(chunk.level, until: chunk.end) }
        } catch {
            meterNote.stringValue = tr("Unable to open this microphone. Choose another one above, or check that it is connected.")
            return
        }
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.meter.show(hearing.status(at: recordingClockNow()).level) }
        }
        RunLoop.main.add(timer, forMode: .common)
        listening = (source, a.microphoneID, hearing, timer)
    }

    private func stopListening() {
        guard let listening else { return }
        listening.timer.invalidate()
        listening.source.stop()
        self.listening = nil
        meter.reset()
    }

    /// Whether the pane is reading a microphone now, for checks.
    var isListening: Bool { listening != nil }
}
