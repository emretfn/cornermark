import AppKit
import CornermarkDesign
import CornermarkL10n

/// The row under the preview: the time on the left; go to start, a round play or pause and go to end centred under the picture;
/// the clip edits at the playhead, the volume and the preview-only switch on the right.
final class TransportBar: NSView {
    enum Command { case start, toggle, end, split, delete, mute, previewOnly }

    static let height: CGFloat = 44

    var onCommand: (Command) -> Void = { _ in }
    var onVolume: (Float) -> Void = { _ in }

    let startButton = IconButton(symbol: "backward.end.fill", label: tr("Go to Start"))
    let playButton = IconButton(symbol: "play.fill", label: tr("Play (Space)"), size: .large, tone: .round)
    let pauseButton = IconButton(symbol: "pause.fill", label: tr("Pause (Space)"), size: .large, tone: .round)
    let endButton = IconButton(symbol: "forward.end.fill", label: tr("Go to End"))
    let splitButton = IconButton(symbol: "scissors", label: tr("Split Clip at Playhead (\u{2318}B)"))
    let deleteButton = IconButton(symbol: "trash", label: tr("Delete Clip (\u{232B})"))
    let muteButton = IconButton(symbol: "speaker.wave.2.fill", label: tr("Mute"))
    let unmuteButton = IconButton(symbol: "speaker.slash.fill", label: tr("Unmute"))
    let volume = Slider()
    let fullButton = IconButton(symbol: "arrow.up.left.and.arrow.down.right", label: tr("Full Screen Preview"))
    let exitFullButton = IconButton(symbol: "arrow.down.right.and.arrow.up.left", label: tr("Exit Full Screen Preview (Esc)"))
    let time = NSTextField.label(tr("{current} / {duration}", ["current": Timecode.text(0), "duration": Timecode.text(0)]), style: DS.Text.readout, color: DS.Color.textPrimary)

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
        volume.style = .field
        volume.format = { Digits.percent($0) }
        volume.setAccessibilityIdentifier("video.volume")
        volume.setAccessibilityLabel(tr("Volume"))
        volume.target = self
        volume.action = #selector(volumeChanged)
        volume.widthAnchor.constraint(equalToConstant: 80).isActive = true
        time.setAccessibilityIdentifier("video.time")
        // A time code keeps its shape in every language, so it reads left to right wherever the bar puts it.
        time.alignment = .natural
        time.baseWritingDirection = .leftToRight

        // Play sits under the picture it plays; the edits and the view tools are the right group, a hairline between them.
        playback.setViews([startButton, playButton, pauseButton, endButton], in: .leading)
        playback.spacing = DS.Space.s8
        playbackLeading = playback.leadingAnchor.constraint(equalTo: leadingAnchor)
        let divider = Separator(axis: .vertical)
        divider.heightAnchor.constraint(equalToConstant: DS.Space.s16).isActive = true
        let right = NSStackView(views: [splitButton, deleteButton, divider, muteButton, unmuteButton, volume, fullButton, exitFullButton])
        right.spacing = DS.Space.s4
        right.setCustomSpacing(DS.Space.s8, after: deleteButton)
        right.setCustomSpacing(DS.Space.s8, after: divider)
        right.setCustomSpacing(DS.Space.s12, after: volume)
        for v in [time, playback, right] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            time.leadingAnchor.constraint(equalTo: leadingAnchor, constant: DS.Space.s12),
            time.centerYAnchor.constraint(equalTo: centerYAnchor),
            playbackLeading,
            playback.centerYAnchor.constraint(equalTo: centerYAnchor),
            right.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -DS.Space.s12),
            right.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("TransportBar is created in code") }

    private let playback = MediaControlStack()
    private var playbackLeading: NSLayoutConstraint!

    /// Centres the playback group on a whole point, so the buttons stay sharp whatever the bar's width.
    override func layout() {
        let centred = ((bounds.width - playback.fittingSize.width) / 2).rounded(.down)
        if playbackLeading.constant != centred { playbackLeading.constant = centred }
        super.layout()
    }

    /// Everything the row shows except the time, so a playing frame that changes only the time touches only the time.
    struct Look: Equatable {
        var playing, atStart, atEnd, playable, hasAudio, muted, previewOnly, canSplit, canDelete: Bool
        var level: Float
    }

    private var shown: Look?

    func update(time current: Double, duration: Double, playing: Bool, hasAudio: Bool, muted: Bool, volume level: Float, previewOnly: Bool,
                canSplit: Bool, canDelete: Bool) {
        let now = Timecode.text(current), total = Timecode.text(duration)
        time.stringValue = tr("{current} / {duration}", ["current": now, "duration": total])
        time.setAccessibilityLabel(tr("{current} of {duration}", ["current": now, "duration": total]))
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
        deleteButton.toolTip = canDelete ? tr("Delete Clip (\u{232B})") : tr("A video keeps at least one clip")
        deleteButton.setAccessibilityHelp(canDelete ? nil : tr("A video keeps at least one clip"))
        muteButton.isHidden = muted
        unmuteButton.isHidden = !muted
        // A recording without sound has nothing to turn up: the speaker stays, off and saying why, and the slider steps aside
        // instead of showing a level nothing plays at.
        muteButton.isEnabled = hasAudio
        unmuteButton.isEnabled = hasAudio
        volume.isHidden = !hasAudio
        let reason = hasAudio ? nil : tr("This recording has no sound")
        muteButton.toolTip = reason ?? tr("Mute")
        unmuteButton.toolTip = reason ?? tr("Unmute")
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
