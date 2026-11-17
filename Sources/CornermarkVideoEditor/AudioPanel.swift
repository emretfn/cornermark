import AppKit
import CornermarkCore
import CornermarkDesign
import CornermarkL10n

/// The sound after recording: each track on or off, at its own level, and the Microphone track's Voice cleanup under it. Export mixes
/// what this says.
final class AudioPanel: SettingsPanel {
    /// The key folds one slider drag into one undo step.
    var onChange: (AudioEdits, CoalescingKey?) -> Void = { _, _ in }
    private(set) var audio = AudioEdits()
    private struct TrackRows {
        let toggle: Checkbox
        let level: TrackingSlider
        let levelRow: NSStackView
    }
    private var rows: [AudioTrack: TrackRows] = [:]
    private let cleanup = Checkbox(title: tr("Voice cleanup"))
    /// Beside the master switch, so showing it moves no control under the pointer.
    private let preparing = NSTextField.label(tr("Preparing…"), style: DS.Text.caption, color: DS.Color.textSecondary)
    private var cleanupRow: NSStackView!
    /// Whether the cleaned Microphone track for the current settings is being made; the preview plays the previous sound meanwhile.
    var isPreparing = false { didSet { preparing.isHidden = !isPreparing } }

    /// One Voice cleanup step's row: its checkbox, and the row with its one setting, if it has one.
    private struct StepRow {
        let box: Checkbox
        /// What the step does, in its tooltip and VoiceOver help.
        let tip: String
        let isOn: WritableKeyPath<VoiceCleanup, Bool>
        let setting: Setting?

        struct Setting {
            let slider: TrackingSlider
            let row: NSStackView
            let value: WritableKeyPath<VoiceCleanup, Double>
            /// The value the slider shows, as the project keeps it.
            let round: (Double) -> Double
            let text: (Double) -> String
            /// Folds one drag into one undo step.
            let key: CoalescingKey
        }
    }
    private var steps: [StepRow] = []
    private var noiseRemovalStep: StepRow { steps[1] }
    private var noiseRemovalNote: NSTextField!
    /// False once a render reported Noise removal unavailable. The panel also asks the renderer whether the unit is on this Mac; when
    /// either says no, the row is greyed out and says so, and the other steps still clean.
    var noiseRemovalAvailable = true {
        didSet { showVoiceCleanup(audio.voiceCleanup, hidden: cleanup.isHidden) }
    }
    private var noiseRemovalRuns: Bool { noiseRemovalAvailable && VoiceCleanupRenderer.noiseRemovalAvailable }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        var views: [NSView] = []
        for track in AudioTrack.allCases {
            let toggle = Checkbox(title: track.localizedTitle)
            toggle.setAccessibilityIdentifier("video.audio.\(track.rawValue)")
            toggle.target = self
            toggle.action = #selector(toggled(_:))
            toggle.identifier = NSUserInterfaceItemIdentifier(track.rawValue)
            let level = slider(id: "video.audio.\(track.rawValue).level", label: tr("{track} level", ["track": track.localizedTitle]), range: AudioTrackLevel.range, action: #selector(slid(_:)))
            level.identifier = NSUserInterfaceItemIdentifier(track.rawValue)
            level.format = { Digits.percent($0) }
            let levelRow = row(tr("Level"), [level])
            levelRow.widthAnchor.constraint(equalToConstant: Self.inner).isActive = true
            rows[track] = TrackRows(toggle: toggle, level: level, levelRow: levelRow)
            views += [toggle, levelRow]
            if track == .microphone { views += voiceCleanupViews() }
        }
        add(views)
        if let mic = rows[.microphone] { stack.setCustomSpacing(DS.Space.s16, after: mic.levelRow) }
        if let last = steps.last { stack.setCustomSpacing(DS.Space.s16, after: last.box) }
        setAccessibilityIdentifier("video.audio")
    }

    required init?(coder: NSCoder) { fatalError("AudioPanel is created in code") }

    /// The master switch, then one checkbox per step with its setting under it, in the order the steps run.
    private func voiceCleanupViews() -> [NSView] {
        cleanup.setAccessibilityIdentifier("video.audio.voiceCleanup")
        cleanup.toolTip = tr("Cleans up the microphone in preview and export. The recorded sound is never changed.")
        cleanup.target = self
        cleanup.action = #selector(cleanupToggled)
        preparing.setAccessibilityIdentifier("video.audio.voiceCleanup.preparing")
        preparing.toolTip = tr("Preparing the cleaned microphone sound. The preview plays the previous sound until it is ready.")
        preparing.isHidden = true
        cleanupRow = NSStackView(views: [cleanup, preparing])
        cleanupRow.spacing = DS.Space.s8
        cleanupRow.alignment = .firstBaseline
        steps = [
            step(tr("Low cut"), id: "lowCut", tip: tr("Removes hum and rumble below the chosen frequency."), isOn: \.lowCutOn,
                 setting: (tr("Frequency"), tr("Low cut frequency"), VoiceCleanup.lowCutRange, \.lowCutFrequency, "frequency",
                           { $0.rounded() }, { Self.hertz($0) })),
            step(tr("Noise removal"), id: "noiseRemoval", tip: tr("Takes steady background noise, like a fan or a busy street, out from behind your voice."),
                 isOn: \.noiseRemovalOn,
                 setting: (tr("Strength"), tr("Noise removal strength"), VoiceCleanup.noiseRemovalRange, \.noiseRemovalStrength, "strength",
                           { ($0 * 100).rounded() / 100 }, { Digits.percent($0) })),
            step(tr("Noise gate"), id: "noiseGate",
                 tip: tr("Silences the microphone while its sound stays below the threshold, for quiet sounds such as breaths between sentences."),
                 isOn: \.noiseGateOn,
                 setting: (tr("Threshold"), tr("Noise gate threshold"), VoiceCleanup.noiseGateRange, \.noiseGateThreshold, "threshold",
                           { $0.rounded() }, { Self.decibels($0) })),
            step(tr("Leveling"), id: "leveling", tip: tr("Evens out loud and soft speech and brings the microphone to a steady loudness."),
                 isOn: \.levelingOn, setting: nil),
        ]
        noiseRemovalNote = caption(tr("Not available on this Mac"), id: "video.audio.voiceCleanup.noiseRemoval.unavailable")
        var views: [NSView] = [cleanupRow]
        for step in steps {
            views.append(step.box)
            if let setting = step.setting { views.append(setting.row) }
            if step.box === noiseRemovalStep.box { views.append(noiseRemovalNote) }
        }
        return views
    }

    /// A step's checkbox `video.audio.voiceCleanup.<id>` and, with `setting`, its one slider `...<id>.<name>` in a row titled `row`.
    private func step(_ title: String, id: String, tip: String, isOn: WritableKeyPath<VoiceCleanup, Bool>,
                      setting: (row: String, label: String, range: ClosedRange<Double>, value: WritableKeyPath<VoiceCleanup, Double>, name: String,
                                round: (Double) -> Double, text: (Double) -> String)?) -> StepRow {
        let box = Checkbox(title: title)
        box.setAccessibilityIdentifier("video.audio.voiceCleanup.\(id)")
        box.toolTip = tip
        box.setAccessibilityHelp(tip)
        box.target = self
        box.action = #selector(cleanupToggled)
        guard let setting else { return StepRow(box: box, tip: tip, isOn: isOn, setting: nil) }
        let slider = slider(id: "video.audio.voiceCleanup.\(id).\(setting.name)", label: setting.label, range: setting.range, action: #selector(stepSlid(_:)))
        slider.format = setting.text
        let row = row(setting.row, [slider])
        row.widthAnchor.constraint(equalToConstant: Self.inner).isActive = true
        return StepRow(box: box, tip: tip, isOn: isOn, setting: .init(slider: slider, row: row, value: setting.value, round: setting.round, text: setting.text,
                                                            key: CoalescingKey("audio.voiceCleanup.\(id)")))
    }

    static func hertz(_ value: Double) -> String { tr("{frequency} Hz", ["frequency": Digits.text(Int(value.rounded()))]) }
    /// The level after a left-to-right mark, so in Arabic, Hebrew and Persian the minus sign stays in front of the number.
    static func decibels(_ value: Double) -> String { tr("{level} dB", ["level": "\u{200E}" + Digits.text(Int(value.rounded()))]) }

    /// `tracks` are the ones the recording has; the rest are hidden.
    func show(_ audio: AudioEdits, tracks: [AudioTrack]) {
        self.audio = audio
        for (track, r) in rows {
            let has = tracks.contains(track)
            r.toggle.isHidden = !has
            r.levelRow.isHidden = !has
            let level = audio[track]
            r.toggle.state = level.isOn ? .on : .off
            r.level.doubleValue = level.level
            r.level.isEnabled = level.isOn
            (r.levelRow.arrangedSubviews.first as? NSTextField)?.textColor = level.isOn ? DS.Color.textSecondary : DS.Color.textDisabled
        }
        showVoiceCleanup(audio.voiceCleanup, hidden: !tracks.contains(.microphone))
    }

    /// Step rows stay readable but greyed while the master switch is off, like a section whose switch is off.
    private func showVoiceCleanup(_ settings: VoiceCleanup, hidden: Bool) {
        cleanupRow.isHidden = hidden
        cleanup.isHidden = hidden
        cleanup.state = settings.isOn ? .on : .off
        let runs = noiseRemovalRuns
        noiseRemovalNote.isHidden = hidden || runs
        for step in steps {
            let available = step.box !== noiseRemovalStep.box || runs
            step.box.isHidden = hidden
            // A step that cannot run is greyed out but keeps showing what the project says, and its help says why.
            step.box.state = settings[keyPath: step.isOn] ? .on : .off
            step.box.isEnabled = settings.isOn && available
            let tip = available ? step.tip : noiseRemovalNote.stringValue
            step.box.toolTip = tip
            step.box.setAccessibilityHelp(tip)
            guard let setting = step.setting else { continue }
            setting.row.isHidden = hidden
            let value = settings[keyPath: setting.value]
            setting.slider.doubleValue = value
            setting.slider.setAccessibilityValueDescription(setting.text(value))
            let on = step.box.isEnabled && settings[keyPath: step.isOn]
            setting.slider.isEnabled = on
            (setting.row.arrangedSubviews.first as? NSTextField)?.textColor = on ? DS.Color.textSecondary : DS.Color.textDisabled
        }
    }

    private func track(of control: NSControl) -> AudioTrack? { control.identifier.flatMap { AudioTrack(rawValue: $0.rawValue) } }

    /// Takes `next` as the panel's sound and passes it on, unless nothing changed.
    private func commit(_ next: AudioEdits, key: CoalescingKey?) {
        guard next != audio else { return }
        audio = next
        onChange(next, key)
    }

    @objc private func toggled(_ sender: Checkbox) {
        guard let track = track(of: sender) else { return }
        var next = audio
        next[track].isOn = sender.state == .on
        commit(next, key: nil)
    }

    @objc private func cleanupToggled() {
        var next = audio
        next.voiceCleanup.isOn = cleanup.state == .on
        // A greyed-out Noise removal keeps what the project says, so the project sounds the same on a Mac that has it.
        for step in steps where step.box !== noiseRemovalStep.box || noiseRemovalRuns {
            next.voiceCleanup[keyPath: step.isOn] = step.box.state == .on
        }
        commit(next, key: nil)
    }

    @objc private func stepSlid(_ sender: TrackingSlider) {
        guard let setting = steps.lazy.compactMap(\.setting).first(where: { $0.slider === sender }) else { return }
        var next = audio
        next.voiceCleanup[keyPath: setting.value] = setting.round(sender.doubleValue)
        commit(next, key: setting.key)
    }

    @objc private func slid(_ sender: TrackingSlider) {
        guard let track = track(of: sender) else { return }
        var next = audio
        next[track].level = (sender.doubleValue * 100).rounded() / 100
        commit(next, key: CoalescingKey("audio.\(track.rawValue).level"))
    }
}
