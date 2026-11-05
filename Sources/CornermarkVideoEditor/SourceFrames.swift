import AVFoundation
import CoreGraphics
import VideoToolbox

/// Pictures of the source video for the preview. The preview asks for the moment `frameState` names, so it shows what export will write.
@MainActor
public protocol SourceFrames: AnyObject {
    /// Keeps decoding in step with the playhead: running while playing, parked on `sourceTime` while paused.
    func follow(sourceTime: Double, playing: Bool)
    /// The picture for `sourceTime` when a new one is ready, else nil and the preview keeps the one it shows.
    func frame(at sourceTime: Double) -> CGImage?
    /// Reads what the preview needs to know before the first frame, such as `hasAudio`.
    func load() async
    /// Whether the source has sound the volume control can change.
    var hasAudio: Bool { get }
    /// 0 to 1, applied to playback.
    var volume: Float { get set }
}

/// Decodes the source with a player whose clock follows the editor's. The editor's clock leads, so a later mapping from output
/// time to source time, such as a cut, only moves the player.
@MainActor
public final class PlayerFrames: SourceFrames {
    public let player: AVPlayer
    private let output: AVPlayerItemVideoOutput
    private var parkedAt: Double?
    /// The last moment asked for while playing, and the host time it was asked at.
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

    /// A playing player may stray from the editor's clock by this much before it is moved back in step.
    static let drift = 0.1
    static let settling = 0.5
    /// More than the few microseconds between the editor reading its clock and this reading the host's, less than any frame.
    static let jump = 0.004

    public init(url: URL) {
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
        guard let asset = player.currentItem?.asset else { return }
        hasAudio = !((try? await asset.loadTracks(withMediaType: .audio)) ?? []).isEmpty
    }

    public func follow(sourceTime: Double, playing: Bool) {
        let now = player.currentTime().seconds
        if playing {
            parkedAt = nil
            let host = CMClockGetTime(CMClockGetHostTimeClock())
            let settled = host.seconds - syncedAt > Self.settling
            // Inside a clip the source moves exactly as the clock does. A cut makes it jump, however little, and the player follows at once.
            let jumped = lastAsked.map { abs((sourceTime - $0.source) - (host.seconds - $0.host)) > Self.jump } ?? false
            lastAsked = (sourceTime, host.seconds)
            guard player.rate == 0 || jumped || (settled && abs(now - sourceTime) > Self.drift) else { return }
            // Both clocks count host time, so the player shows `sourceTime` at the same instant the editor's playhead is there.
            player.setRate(1, time: CMTime(seconds: sourceTime, preferredTimescale: 600), atHostTime: host)
            syncedAt = host.seconds
            syncs += 1
        } else {
            lastAsked = nil
            if player.rate != 0 { player.pause() }
            guard parkedAt != sourceTime else { return }
            parkedAt = sourceTime
            seek(sourceTime)
        }
    }

    public func frame(at sourceTime: Double) -> CGImage? {
        let time = CMTime(seconds: sourceTime, preferredTimescale: 600)
        guard output.hasNewPixelBuffer(forItemTime: time), let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) else { return nil }
        var image: CGImage?
        VTCreateCGImageFromCVPixelBuffer(buffer, options: nil, imageOut: &image)
        return image
    }

    private func seek(_ t: Double) {
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }
}
