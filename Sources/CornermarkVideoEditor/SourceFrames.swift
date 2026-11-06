import AVFoundation
import CoreGraphics
import CornermarkCore
import VideoToolbox

/// Pictures of the source video for the preview. The preview asks for the moment `frameState` names, so it shows what export will write.
@MainActor
public protocol SourceFrames: AnyObject {
    /// Keeps decoding in step with the playhead: running while playing, parked on `sourceTime` while paused. `now` is the host time, in
    /// seconds, at which the playhead is at `sourceTime`.
    func follow(sourceTime: Double, playing: Bool, now: Double)
    /// The picture for `sourceTime` when a new one is ready, else nil and the preview keeps the one it shows.
    func frame(at sourceTime: Double) -> CGImage?
    /// Reads what the preview needs to know before the first frame, such as `hasAudio`.
    func load() async
    /// Whether the source has sound the volume control can change.
    var hasAudio: Bool { get }
    /// 0 to 1, applied to playback.
    var volume: Float { get set }
    /// Each sound track's gain, as export mixes it. A source without separate tracks ignores it.
    func setGains(_ gains: [AudioTrack: Double])
    /// True keeps every sound of the source off, whatever the volume and the gains say.
    var isSilent: Bool { get set }
}

extension SourceFrames {
    public func setGains(_ gains: [AudioTrack: Double]) {}
    public var isSilent: Bool {
        get { true }
        set {}
    }
}

/// Decodes the source with a player whose clock follows the editor's. The editor's clock leads, so a later mapping from output
/// time to source time, such as a cut, only moves the player.
@MainActor
public final class PlayerFrames: SourceFrames {
    public let player: AVPlayer
    private let output: AVPlayerItemVideoOutput
    private var parkedAt: Double?
    private var lastAsked: (source: Double, host: Double)?
    /// Host time of the last move back in step. The player needs a moment to decode before its own clock is worth comparing.
    private var syncedAt = -Double.infinity
    public private(set) var hasAudio = false
    /// How many times playing moved the player back in step with the editor's clock.
    public private(set) var syncs = 0
    public var volume: Float {
        get { player.volume }
        set { player.volume = min(max(newValue, 0), 1) }
    }
    public var isSilent: Bool {
        get { player.isMuted }
        set { player.isMuted = newValue }
    }
    /// The sound tracks laid into the player, for a check to read.
    public var soundTrackCount: Int { soundTracks.count }

    /// A playing player may stray from the editor's clock by this much before it is moved back in step.
    static let drift = 0.1
    static let settling = 0.5
    /// More than the few microseconds between the editor reading its clock and this reading the host's, less than any frame.
    static let jump = 0.004

    /// Sound files to lay beside the pictures. `load` puts them into the player, so a cut that moves the player moves the sound too.
    private let soundFiles: [AudioTrack: URL]
    private var soundTracks: [AudioTrack: AVAssetTrack] = [:]
    private var soundAssets: [AVAsset] = []
    private var gains: [AudioTrack: Double] = [:]

    public convenience init(url: URL) { self.init(url: url, sound: [:]) }

    public init(url: URL, sound: [AudioTrack: URL]) {
        soundFiles = sound
        let item = AVPlayerItem(asset: AVURLAsset(url: url))
        output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ])
        item.add(output)
        player = AVPlayer(playerItem: item)
        player.actionAtItemEnd = .pause
        player.automaticallyWaitsToMinimizeStalling = false
    }

    public func load() async {
        if !soundFiles.isEmpty { await laySound() }
        guard let asset = player.currentItem?.asset else { return }
        hasAudio = !((try? await asset.loadTracks(withMediaType: .audio)) ?? []).isEmpty
    }

    /// Plays the pictures and every sound file as one composition, each track from the start of the recording.
    private func laySound() async {
        guard let current = player.currentItem, let picture = try? await current.asset.loadTracks(withMediaType: .video).first,
              let range = try? await picture.load(.timeRange) else { return }
        let composition = AVMutableComposition()
        guard let video = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              (try? video.insertTimeRange(range, of: picture, at: range.start)) != nil else { return }
        var tracks: [AudioTrack: AVAssetTrack] = [:]
        for track in AudioTrack.allCases {
            guard let url = soundFiles[track] else { continue }
            let asset = AVURLAsset(url: url)
            // A track read from an asset that was already released inserted nothing in a harness run, so the player keeps the assets.
            soundAssets.append(asset)
            guard let source = try? await asset.loadTracks(withMediaType: .audio).first,
                  let whole = try? await source.load(.timeRange),
                  let into = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid),
                  (try? into.insertTimeRange(whole, of: source, at: .zero)) != nil else { continue }
            tracks[track] = into
        }
        guard !tracks.isEmpty else { return }
        current.remove(output)
        let item = AVPlayerItem(asset: composition)
        item.add(output)
        player.replaceCurrentItem(with: item)
        soundTracks = tracks
        parkedAt = nil
        applyGains()
    }

    public func setGains(_ next: [AudioTrack: Double]) {
        guard next != gains else { return }
        gains = next
        applyGains()
    }

    private func applyGains() {
        guard !soundTracks.isEmpty else { return }
        let next = gains
        let mix = AVMutableAudioMix()
        mix.inputParameters = soundTracks.map { track, asset in
            let level = AVMutableAudioMixInputParameters(track: asset)
            level.setVolume(Float(next[track] ?? 0), at: .zero)
            return level
        }
        player.currentItem?.audioMix = mix
    }

    public func follow(sourceTime: Double, playing: Bool, now: Double) {
        if playing {
            parkedAt = nil
            let settled = now - syncedAt > Self.settling
            // Inside a clip the source moves exactly as the clock does. A cut makes it jump, however little, and the player follows at once.
            // Both moves are measured at the instants the editor read its clock, so a late tick cannot pass for a jump.
            let jumped = lastAsked.map { abs((sourceTime - $0.source) - (now - $0.host)) > Self.jump } ?? false
            lastAsked = (sourceTime, now)
            guard player.rate == 0 || jumped || (settled && abs(playerTime - sourceTime) > Self.drift) else { return }
            // Both clocks count host time, so the player shows `sourceTime` at the same instant the editor's playhead is there.
            player.setRate(1, time: CMTime(seconds: sourceTime, preferredTimescale: 600), atHostTime: CMTime(seconds: now, preferredTimescale: 1_000_000_000))
            syncedAt = now
            syncs += 1
        } else {
            lastAsked = nil
            if player.rate != 0 { player.pause() }
            guard parkedAt != sourceTime else { return }
            parkedAt = sourceTime
            seek(sourceTime)
        }
    }

    /// Where the player is. The item's timebase answers at once; `AVPlayer.currentTime()` waits for a player with a sound track to settle
    /// after it was put in step, which held the main thread for about 100 ms per tick.
    private var playerTime: Double {
        guard let timebase = player.currentItem?.timebase else { return player.currentTime().seconds }
        return CMTimebaseGetTime(timebase).seconds
    }

    public func frame(at sourceTime: Double) -> CGImage? {
        // Playing, the picture is the one the player is on. With a sound track its clock follows the sound device and runs a frame or
        // two ahead of the editor's, inside `drift`; asking for the editor's moment then finds that picture already passed, and the
        // preview skipped frames.
        let playing = player.rate != 0 && abs(playerTime - sourceTime) <= Self.drift
        let time = CMTime(seconds: playing ? playerTime : sourceTime, preferredTimescale: 600)
        guard output.hasNewPixelBuffer(forItemTime: time), let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) else { return nil }
        var image: CGImage?
        VTCreateCGImageFromCVPixelBuffer(buffer, options: nil, imageOut: &image)
        return image
    }

    private func seek(_ t: Double) {
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }
}
