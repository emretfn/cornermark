import AppKit
import CornermarkCore
import CornermarkDesign

/// The sound after recording: each track on or off, at its own level. Export mixes what this says.
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

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        var views: [NSView] = []
        for track in AudioTrack.allCases {
            let toggle = Checkbox(title: track.title)
            toggle.setAccessibilityIdentifier("video.audio.\(track.rawValue)")
            toggle.target = self
            toggle.action = #selector(toggled(_:))
            toggle.identifier = NSUserInterfaceItemIdentifier(track.rawValue)
            let level = slider(id: "video.audio.\(track.rawValue).level", label: "\(track.title) level", range: AudioTrackLevel.range, action: #selector(slid(_:)))
            level.identifier = NSUserInterfaceItemIdentifier(track.rawValue)
            level.format = { "\(Int(($0 * 100).rounded()))%" }
            let levelRow = row("Level", [level])
            levelRow.widthAnchor.constraint(equalToConstant: Self.inner).isActive = true
            rows[track] = TrackRows(toggle: toggle, level: level, levelRow: levelRow)
            views += [toggle, levelRow]
        }
        add(views)
        if let mic = rows[.microphone] { stack.setCustomSpacing(DS.Space.s16, after: mic.levelRow) }
        setAccessibilityIdentifier("video.audio")
    }

    required init?(coder: NSCoder) { fatalError("AudioPanel is created in code") }

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
    }

    private func track(of control: NSControl) -> AudioTrack? { control.identifier.flatMap { AudioTrack(rawValue: $0.rawValue) } }

    @objc private func toggled(_ sender: Checkbox) {
        guard let track = track(of: sender) else { return }
        var next = audio
        next[track].isOn = sender.state == .on
        audio = next
        onChange(next, nil)
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
