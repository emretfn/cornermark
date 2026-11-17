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
    private let lowCut = Checkbox(title: tr("Low cut"))
    private var lowCutFrequency: TrackingSlider!
    private var lowCutRow: NSStackView!
    private let noiseRemoval = Checkbox(title: tr("Noise removal"))
    private var noiseRemovalStrength: TrackingSlider!
    private var noiseRemovalRow: NSStackView!
    private var noiseRemovalNote: NSTextField!
    /// False once an export reported Noise removal unavailable. The panel also asks the renderer whether the unit is on this Mac; when
    /// either says no, the row is greyed out and says so, and the other steps still clean.
    var noiseRemovalAvailable = true {
        didSet { showVoiceCleanup(audio.voiceCleanup, hidden: cleanup.isHidden) }
    }
    private var noiseRemovalRuns: Bool { noiseRemovalAvailable && VoiceCleanupRenderer.noiseRemovalAvailable }
    private let noiseGate = Checkbox(title: tr("Noise gate"))
    private var noiseGateThreshold: TrackingSlider!
    private var noiseGateRow: NSStackView!
    private let leveling = Checkbox(title: tr("Leveling"))

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
        stack.setCustomSpacing(DS.Space.s16, after: leveling)
        setAccessibilityIdentifier("video.audio")
    }

    required init?(coder: NSCoder) { fatalError("AudioPanel is created in code") }

    /// The master switch, then one checkbox per step with its setting under it, in the order the steps run.
    private func voiceCleanupViews() -> [NSView] {
        cleanup.setAccessibilityIdentifier("video.audio.voiceCleanup")
        cleanup.toolTip = tr("Cleans up the microphone in preview and export. The recorded sound is never changed.")
        preparing.setAccessibilityIdentifier("video.audio.voiceCleanup.preparing")
        preparing.toolTip = tr("Preparing the cleaned microphone sound. The preview plays the previous sound until it is ready.")
        preparing.isHidden = true
        cleanupRow = NSStackView(views: [cleanup, preparing])
        cleanupRow.spacing = DS.Space.s8
        cleanupRow.alignment = .firstBaseline
        lowCut.setAccessibilityIdentifier("video.audio.voiceCleanup.lowCut")
        lowCut.toolTip = tr("Removes hum and rumble below the chosen frequency.")
        noiseRemoval.setAccessibilityIdentifier("video.audio.voiceCleanup.noiseRemoval")
        noiseRemoval.toolTip = tr("Takes steady background noise, like a fan or a busy street, out from behind your voice.")
        noiseGate.setAccessibilityIdentifier("video.audio.voiceCleanup.noiseGate")
        noiseGate.toolTip = tr("Silences the microphone while its sound stays below the threshold, such as breaths and keystrokes between sentences.")
        leveling.setAccessibilityIdentifier("video.audio.voiceCleanup.leveling")
        leveling.toolTip = tr("Evens out loud and soft speech and brings the microphone to a steady loudness.")
        for box in [cleanup, lowCut, noiseRemoval, noiseGate, leveling] {
            box.target = self
            box.action = #selector(cleanupToggled)
        }
        lowCutFrequency = slider(id: "video.audio.voiceCleanup.lowCut.frequency", label: tr("Low cut frequency"), range: VoiceCleanup.lowCutRange,
                                 action: #selector(lowCutSlid))
        lowCutFrequency.format = { Self.hertz($0) }
        lowCutRow = row(tr("Frequency"), [lowCutFrequency])
        lowCutRow.widthAnchor.constraint(equalToConstant: Self.inner).isActive = true
        noiseRemovalStrength = slider(id: "video.audio.voiceCleanup.noiseRemoval.strength", label: tr("Noise removal strength"),
                                      range: VoiceCleanup.noiseRemovalRange, action: #selector(noiseRemovalSlid))
        noiseRemovalStrength.format = { Digits.percent($0) }
        noiseRemovalRow = row(tr("Strength"), [noiseRemovalStrength])
        noiseRemovalRow.widthAnchor.constraint(equalToConstant: Self.inner).isActive = true
        noiseRemovalNote = caption(tr("Not available on this Mac"), id: "video.audio.voiceCleanup.noiseRemoval.unavailable")
        noiseGateThreshold = slider(id: "video.audio.voiceCleanup.noiseGate.threshold", label: tr("Noise gate threshold"), range: VoiceCleanup.noiseGateRange,
                                    action: #selector(noiseGateSlid))
        noiseGateThreshold.format = { Self.decibels($0) }
        noiseGateRow = row(tr("Threshold"), [noiseGateThreshold])
        noiseGateRow.widthAnchor.constraint(equalToConstant: Self.inner).isActive = true
        return [cleanupRow, lowCut, lowCutRow, noiseRemoval, noiseRemovalRow, noiseRemovalNote, noiseGate, noiseGateRow, leveling]
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
        for view in [cleanupRow, cleanup, lowCut, lowCutRow, noiseRemoval, noiseRemovalRow, noiseGate, noiseGateRow, leveling] as [NSView] { view.isHidden = hidden }
        cleanup.state = settings.isOn ? .on : .off
        lowCut.state = settings.lowCutOn ? .on : .off
        lowCut.isEnabled = settings.isOn
        lowCutFrequency.doubleValue = settings.lowCutFrequency
        lowCutFrequency.setAccessibilityValueDescription(Self.hertz(settings.lowCutFrequency))
        let frequencyOn = settings.isOn && settings.lowCutOn
        lowCutFrequency.isEnabled = frequencyOn
        (lowCutRow.arrangedSubviews.first as? NSTextField)?.textColor = frequencyOn ? DS.Color.textSecondary : DS.Color.textDisabled
        let runs = noiseRemovalRuns
        noiseRemovalNote.isHidden = hidden || runs
        noiseRemoval.state = settings.noiseRemovalOn && runs ? .on : .off
        noiseRemoval.isEnabled = settings.isOn && runs
        noiseRemovalStrength.doubleValue = settings.noiseRemovalStrength
        noiseRemovalStrength.setAccessibilityValueDescription(Digits.percent(settings.noiseRemovalStrength))
        let strengthOn = noiseRemoval.isEnabled && settings.noiseRemovalOn
        noiseRemovalStrength.isEnabled = strengthOn
        (noiseRemovalRow.arrangedSubviews.first as? NSTextField)?.textColor = strengthOn ? DS.Color.textSecondary : DS.Color.textDisabled
        noiseGate.state = settings.noiseGateOn ? .on : .off
        noiseGate.isEnabled = settings.isOn
        noiseGateThreshold.doubleValue = settings.noiseGateThreshold
        noiseGateThreshold.setAccessibilityValueDescription(Self.decibels(settings.noiseGateThreshold))
        let thresholdOn = settings.isOn && settings.noiseGateOn
        noiseGateThreshold.isEnabled = thresholdOn
        (noiseGateRow.arrangedSubviews.first as? NSTextField)?.textColor = thresholdOn ? DS.Color.textSecondary : DS.Color.textDisabled
        leveling.state = settings.levelingOn ? .on : .off
        leveling.isEnabled = settings.isOn
    }

    private func track(of control: NSControl) -> AudioTrack? { control.identifier.flatMap { AudioTrack(rawValue: $0.rawValue) } }

    @objc private func toggled(_ sender: Checkbox) {
        guard let track = track(of: sender) else { return }
        var next = audio
        next[track].isOn = sender.state == .on
        audio = next
        onChange(next, nil)
    }

    @objc private func cleanupToggled() {
        var next = audio
        next.voiceCleanup.isOn = cleanup.state == .on
        next.voiceCleanup.lowCutOn = lowCut.state == .on
        // A greyed-out Noise removal shows off but keeps what the project says, so the project sounds the same on a Mac that has it.
        if noiseRemovalRuns { next.voiceCleanup.noiseRemovalOn = noiseRemoval.state == .on }
        next.voiceCleanup.noiseGateOn = noiseGate.state == .on
        next.voiceCleanup.levelingOn = leveling.state == .on
        guard next != audio else { return }
        audio = next
        onChange(next, nil)
    }

    @objc private func lowCutSlid() {
        var next = audio
        next.voiceCleanup.lowCutFrequency = lowCutFrequency.doubleValue.rounded()
        guard next != audio else { return }
        audio = next
        onChange(next, CoalescingKey("audio.voiceCleanup.lowCut"))
    }

    @objc private func noiseRemovalSlid() {
        var next = audio
        next.voiceCleanup.noiseRemovalStrength = (noiseRemovalStrength.doubleValue * 100).rounded() / 100
        guard next != audio else { return }
        audio = next
        onChange(next, CoalescingKey("audio.voiceCleanup.noiseRemoval"))
    }

    @objc private func noiseGateSlid() {
        var next = audio
        next.voiceCleanup.noiseGateThreshold = noiseGateThreshold.doubleValue.rounded()
        guard next != audio else { return }
        audio = next
        onChange(next, CoalescingKey("audio.voiceCleanup.noiseGate"))
    }

    @objc private func slid(_ sender: TrackingSlider) {
        guard let track = track(of: sender) else { return }
        var next = audio
        next[track].level = (sender.doubleValue * 100).rounded() / 100
        guard next != audio else { return }
        audio = next
        onChange(next, CoalescingKey("audio.\(track.rawValue).level"))
    }
}
