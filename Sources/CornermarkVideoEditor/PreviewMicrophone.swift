import CornermarkCore
import Foundation

/// The Microphone track file the preview plays, kept on the current Voice cleanup settings. A change asks for the cleaned copy in the
/// background, superseding the one asked for before; the preview plays the previous sound until the copy is ready, then takes it
/// without stopping. Off stops the render under way and plays the recorded file again. The files played and waited for are leased,
/// so no render for other settings removes them under the player.
@MainActor
final class PreviewMicrophone {
    /// The file the preview plays, or is laying into the player: the recorded one, or its cleaned copy.
    private(set) var file: URL?
    /// The file the player last took over, which plays on when a newer one cannot be laid.
    private var playing: URL?
    /// Whether the cleaned copy for the current settings is still being made; the preview plays the previous sound meanwhile.
    private(set) var isPreparing = false {
        didSet { if isPreparing != oldValue { onPreparing(isPreparing) } }
    }
    var onPreparing: (Bool) -> Void = { _ in }
    /// A render for the preview could not run Noise removal on this Mac, so the panel greys it out.
    var onNoiseRemovalUnavailable: () -> Void = {}

    private let recorded: URL?
    private let frames: SourceFrames
    private let renders: VoiceCleanupRenders
    /// The settings last asked a cleaned copy for, nil while the recorded sound plays.
    private var asked: VoiceCleanup?
    private var job: Task<Void, Never>?
    /// Hold the cleaned file the player plays, and the one asked for, so no render for other settings removes them.
    private var playingLease: VoiceCleanupRenders.Lease?
    private var askedLease: VoiceCleanupRenders.Lease?
    /// Set once the editor closed, so a sound still being laid then gives its lease up instead of keeping it.
    private var isClosed = false
    /// How many files are being put into the player, and the last one asked for.
    private var swaps = 0
    private var swap: Task<Void, Never>?

    /// `recorded` is the recording's Microphone track, nil without one; `playing` is the file the player opened with.
    init(recorded: URL?, playing: URL?, frames: SourceFrames, renders: VoiceCleanupRenders = .shared) {
        self.recorded = recorded
        self.frames = frames
        self.renders = renders
        file = playing
        self.playing = playing
    }

    /// Keeps the preview on `settings`.
    func update(_ settings: VoiceCleanup) {
        guard let recorded else { return }
        let wanted = settings.isOn ? settings : nil
        guard wanted != asked else { return }
        asked = wanted
        job?.cancel()
        // Given up only after a new lease is taken, so a re-ask for the same settings never leaves the copy unheld in between.
        let previousAsked = askedLease
        askedLease = nil
        defer { if let previousAsked { renders.release(previousAsked) } }
        guard let wanted, FileManager.default.fileExists(atPath: recorded.path) else {
            // An export's render goes on; only the one nobody waits for any more stops.
            renders.cancel(recorded)
            isPreparing = false
            play(recorded, lease: nil)
            return
        }
        isPreparing = VoiceCleanupCache.ready(for: recorded, settings: wanted) == nil
        let lease = renders.lease(recorded, settings: wanted)
        askedLease = lease
        // Asked even when the copy is there, so a render for older settings still under way is superseded and cannot replace it.
        let render = renders.request(recorded, settings: wanted)
        job = Task { [weak self] in
            let result = await render.result
            guard let self, !Task.isCancelled, asked == wanted else { return }
            if case .failure(let error) = result, error is CancellationError {
                // Superseded by an export for other settings, or stopped with a cancelled one: asked again, it renders after the export.
                asked = nil
                update(settings)
                return
            }
            isPreparing = false
            switch result {
            case .success(let cleaned):
                if cleaned.report.noiseRemovalUnavailable { onNoiseRemovalUnavailable() }
                // The lease moves to the swap, which holds it until the player plays the file.
                askedLease = nil
                play(cleaned.url, lease: lease)
            case .failure:
                // The previous sound plays on, and the next update asks for these settings again.
                asked = nil
            }
        }
    }

    /// Puts `file`, held by `lease`, into the player. The lease of the file played before is given up only once the player no longer
    /// reads it; when the new file could not be laid, the old one plays on and keeps its lease.
    private func play(_ next: URL, lease: VoiceCleanupRenders.Lease?) {
        let renders = renders
        guard file != next else {
            if swaps > 0 {
                // Being laid, under the lease of that swap.
                if let lease { renders.release(lease) }
            } else {
                // Already playing, such as the copy that was ready when the editor opened: the new lease holds it from now on.
                if let playingLease { renders.release(playingLease) }
                playingLease = lease
            }
            return
        }
        file = next
        let frames = frames
        swaps += 1
        swap = Task { [weak self] in
            let tookOver = await frames.setSound(next, for: .microphone)
            self?.swaps -= 1
            guard let self, !isClosed else {
                if let lease { renders.release(lease) }
                return
            }
            guard tookOver else {
                if let lease { renders.release(lease) }
                // Not laid and not superseded: the file the player took last plays on.
                if file == next { file = playing }
                return
            }
            playing = next
            if let playingLease { renders.release(playingLease) }
            playingLease = lease
        }
    }

    /// Waits for the cleaned copy asked for last, and for the player to take it.
    func prepared() async {
        // Asking again replaces the job waited on.
        while let job {
            await job.value
            if job == self.job { break }
        }
        // And for the player to take it, which gives up the file played before.
        await swap?.value
    }

    /// The editor closed: the render waited for stops, unless an export waits for it too, and the leases go.
    func close() {
        job?.cancel()
        if let recorded { renders.cancel(recorded) }
        isClosed = true
        for lease in [playingLease, askedLease].compactMap({ $0 }) { renders.release(lease) }
        playingLease = nil
        askedLease = nil
    }
}
