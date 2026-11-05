import AppKit
import CornermarkDesign

/// The row under the preview: go to start, play or pause, go to end, the clip edits at the playhead, the time, the volume,
/// and the preview-only switch.
final class TransportBar: NSView {
    enum Command { case start, toggle, end, split, delete, mute, previewOnly }

    static let height: CGFloat = 44

    var onCommand: (Command) -> Void = { _ in }
    var onVolume: (Float) -> Void = { _ in }

    let startButton = IconButton(symbol: "backward.end.fill", label: "Go to Start")
    let playButton = IconButton(symbol: "play.fill", label: "Play (Space)")
    let pauseButton = IconButton(symbol: "pause.fill", label: "Pause (Space)")
    let endButton = IconButton(symbol: "forward.end.fill", label: "Go to End")
    let splitButton = IconButton(symbol: "scissors", label: "Split Clip at Playhead (\u{2318}B)")
    let deleteButton = IconButton(symbol: "trash", label: "Delete Clip (\u{232B})")
    let muteButton = IconButton(symbol: "speaker.wave.2.fill", label: "Mute")
    let unmuteButton = IconButton(symbol: "speaker.slash.fill", label: "Unmute")
    let volume = Slider()
    let fullButton = IconButton(symbol: "arrow.up.left.and.arrow.down.right", label: "Full Screen Preview")
    let exitFullButton = IconButton(symbol: "arrow.down.right.and.arrow.up.left", label: "Exit Full Screen Preview (Esc)")
    let time = NSTextField.label("0:00.00 / 0:00.00", style: DS.Text.readout, color: DS.Color.textPrimary)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let ids: [(IconButton, String, Command)] = [
            (startButton, "video.start", .start), (playButton, "video.play", .toggle), (pauseButton, "video.pause", .toggle),
            (endButton, "video.end", .end), (splitButton, "video.split", .split), (deleteButton, "video.deleteClip", .delete),
            (muteButton, "video.mute", .mute), (unmuteButton, "video.unmute", .mute),
            (fullButton, "video.fullscreen", .previewOnly), (exitFullButton, "video.exitFullscreen", .previewOnly),
        ]
        for (b, id, command) in ids {
            b.setAccessibilityIdentifier(id)
            b.onPress { [unowned self] in onCommand(command) }
        }
        volume.minValue = 0
        volume.maxValue = 1
        volume.doubleValue = 1
        volume.isContinuous = true
        volume.controlSize = .small
        volume.setAccessibilityIdentifier("video.volume")
        volume.setAccessibilityLabel("Volume")
        volume.target = self
        volume.action = #selector(volumeChanged)
        volume.widthAnchor.constraint(equalToConstant: 80).isActive = true
        time.setAccessibilityIdentifier("video.time")
        time.alignment = .center

        let left = NSStackView(views: [startButton, playButton, pauseButton, endButton, splitButton, deleteButton])
        left.spacing = DS.Space.s4
        // Playback and the clip edits are two groups; space alone sets them apart.
        left.setCustomSpacing(DS.Space.s16, after: endButton)
        let right = NSStackView(views: [muteButton, unmuteButton, volume, fullButton, exitFullButton])
        right.spacing = DS.Space.s4
        right.setCustomSpacing(DS.Space.s12, after: volume)
        for v in [left, time, right] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            left.leadingAnchor.constraint(equalTo: leadingAnchor, constant: DS.Space.s12),
            left.centerYAnchor.constraint(equalTo: centerYAnchor),
            time.centerXAnchor.constraint(equalTo: centerXAnchor),
            time.centerYAnchor.constraint(equalTo: centerYAnchor),
            right.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -DS.Space.s12),
            right.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("TransportBar is created in code") }

    /// Everything the row shows except the time, so a playing frame that changes only the time touches only the time.
    struct Look: Equatable {
        var playing, atStart, atEnd, playable, hasAudio, muted, previewOnly, canSplit, canDelete: Bool
        var level: Float
    }

    private var shown: Look?

    func update(time current: Double, duration: Double, playing: Bool, hasAudio: Bool, muted: Bool, volume level: Float, previewOnly: Bool,
                canSplit: Bool, canDelete: Bool) {
        time.stringValue = "\(Timecode.text(current)) / \(Timecode.text(duration))"
        time.setAccessibilityLabel("\(Timecode.text(current)) of \(Timecode.text(duration))")
        let look = Look(playing: playing, atStart: current <= 0, atEnd: current >= duration, playable: duration > 0, hasAudio: hasAudio,
                        muted: muted, previewOnly: previewOnly, canSplit: canSplit, canDelete: canDelete, level: level)
        guard look != shown else { return }
        shown = look
        playButton.isHidden = playing
        pauseButton.isHidden = !playing
        startButton.isEnabled = !look.atStart
        endButton.isEnabled = !look.atEnd
        playButton.isEnabled = look.playable
        splitButton.isEnabled = canSplit
        deleteButton.isEnabled = canDelete
        deleteButton.toolTip = canDelete ? "Delete Clip (\u{232B})" : "A video keeps at least one clip"
        deleteButton.setAccessibilityHelp(canDelete ? nil : "A video keeps at least one clip")
        muteButton.isHidden = muted
        unmuteButton.isHidden = !muted
        // A recording without sound has nothing to turn up: the speaker stays, off and saying why, and the slider steps aside
        // instead of showing a level nothing plays at.
        muteButton.isEnabled = hasAudio
        unmuteButton.isEnabled = hasAudio
        volume.isHidden = !hasAudio
        let reason = hasAudio ? nil : "This recording has no sound"
        muteButton.toolTip = reason ?? "Mute"
        unmuteButton.toolTip = reason ?? "Unmute"
        muteButton.setAccessibilityHelp(reason)
        volume.doubleValue = Double(muted ? 0 : level)
        fullButton.isHidden = previewOnly
        exitFullButton.isHidden = !previewOnly
    }

    @objc private func volumeChanged() { onVolume(Float(volume.doubleValue)) }
}

extension NSButton {
    func onPress(_ handler: @escaping () -> Void) {
        let target = PressTarget(handler)
        objc_setAssociatedObject(self, &PressTarget.key, target, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        self.target = target
        action = #selector(PressTarget.fire)
    }
}

private final class PressTarget: NSObject {
    static var key: UInt8 = 0
    let handler: () -> Void
    init(_ handler: @escaping () -> Void) { self.handler = handler }
    @objc func fire() { handler() }
}
