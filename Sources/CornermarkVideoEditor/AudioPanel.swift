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
        stack.setCustomSpacing(DS.Space.s16, after: lowCutRow)
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
        for box in [cleanup, lowCut] {
            box.target = self
            box.action = #selector(cleanupToggled)
        }
        lowCutFrequency = slider(id: "video.audio.voiceCleanup.lowCut.frequency", label: tr("Low cut frequency"), range: VoiceCleanup.lowCutRange,
                                 action: #selector(lowCutSlid))
        lowCutFrequency.format = { Self.hertz($0) }
        lowCutRow = row(tr("Frequency"), [lowCutFrequency])
        lowCutRow.widthAnchor.constraint(equalToConstant: Self.inner).isActive = true
        return [cleanupRow, lowCut, lowCutRow]
    }

    static func hertz(_ value: Double) -> String { tr("{frequency} Hz", ["frequency": Digits.text(Int(value.rounded()))]) }

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
        for view in [cleanupRow, cleanup, lowCut, lowCutRow] as [NSView] { view.isHidden = hidden }
        cleanup.state = settings.isOn ? .on : .off
        lowCut.state = settings.lowCutOn ? .on : .off
        lowCut.isEnabled = settings.isOn
        lowCutFrequency.doubleValue = settings.lowCutFrequency
        lowCutFrequency.setAccessibilityValueDescription(Self.hertz(settings.lowCutFrequency))
        let frequencyOn = settings.isOn && settings.lowCutOn
        lowCutFrequency.isEnabled = frequencyOn
        (lowCutRow.arrangedSubviews.first as? NSTextField)?.textColor = frequencyOn ? DS.Color.textSecondary : DS.Color.textDisabled
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

    @objc private func slid(_ sender: TrackingSlider) {
        guard let track = track(of: sender) else { return }
        var next = audio
        next[track].level = (sender.doubleValue * 100).rounded() / 100
        guard next != audio else { return }
        audio = next
        onChange(next, CoalescingKey("audio.\(track.rawValue).level"))
    }
}
