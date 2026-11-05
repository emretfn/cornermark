import AVFoundation
import CornermarkCore

/// What one sound track holds once it is finished.
public struct AudioTrackReport: Equatable {
    public enum Kind: String, Equatable { case microphone, system }
    public var kind: Kind
    public var url: URL
    public var rate: Double
    public var channels: Int
    /// Samples per channel in the file, which the track's end pads with silence to the video's length.
    public var frames: Int
    /// Silence put where the source sent nothing, such as before its first sample or after a dropped buffer, in seconds.
    public var filled: Double
    public var duration: Double { rate > 0 ? Double(frames) / rate : 0 }
}

/// Where the samples of one chunk land in the video. A pause removes the same stretch from the sound as from the pictures.
enum AudioPlacement {
    struct Piece: Equatable {
        /// The first sample of the chunk this piece holds, and how many.
        var offset: Int
        var count: Int
        /// The video time of its first sample.
        var videoTime: Double
    }

    /// The pieces of a chunk of `frames` samples starting `start` seconds after the first frame, up to `until` seconds, and how many of its
    /// samples that used up. Samples before the first frame or inside a pause are used up and land nowhere.
    static func place(start: Double, frames: Int, rate: Double, pauses: [RecordingPause], until: Double) -> (pieces: [Piece], used: Int) {
        let end = start + Double(frames) / rate
        let stop = min(end, until)
        guard stop > start else { return ([], 0) }
        let used = min(frames, max(0, Int(((stop - start) * rate).rounded())))
        var pieces: [Piece] = []
        var from = 0.0, shift = 0.0
        for gap in pauses + [RecordingPause(from: .infinity, to: .infinity)] {
            let a = max(from, start), b = min(gap.from, stop)
            if b > a {
                let first = max(0, Int(((a - start) * rate).rounded())), last = min(used, Int(((b - start) * rate).rounded()))
                if last > first { pieces.append(Piece(offset: first, count: last - first, videoTime: start + Double(first) / rate - shift)) }
            }
            if gap.from == .infinity { break }
            shift += gap.to - gap.from
            from = gap.to
        }
        return (pieces, used)
    }
}

/// Writes one sound track as AAC in an M4A file, on the timeline of the video beside it. Chunks wait until the video's timeline is settled
/// for their moment, so a pause that starts after they arrive still leaves them out. The track has no holes: silence fills a gap, and
/// sound that would overlap what is written is dropped, so every later sample stays where the clock put it.
final class AudioTrackWriter {
    /// A difference this small between where a chunk belongs and where the track has got to is clock jitter, not a gap.
    static let tolerance = 0.002
    let kind: AudioTrackReport.Kind
    private let url: URL
    private let mono: Bool
    private let realTime: Bool
    private let mapping: () -> RecordingWriter.Mapping
    private let lock = NSLock()
    private var pending: [AudioChunk] = []
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var format: CMAudioFormatDescription?
    private var rate = 0.0
    private var channels = 0
    private var written = 0
    private var filled = 0
    private var finished = false
    private(set) var failure: String?

    init(kind: AudioTrackReport.Kind, url: URL, mono: Bool, realTime: Bool, mapping: @escaping () -> RecordingWriter.Mapping) {
        self.kind = kind; self.url = url; self.mono = mono; self.realTime = realTime; self.mapping = mapping
        try? FileManager.default.removeItem(at: url)
    }

    func append(_ chunk: AudioChunk) {
        lock.withLock {
            guard !finished, chunk.frames > 0 else { return }
            pending.append(chunk)
            flush(mapping(), end: nil)
        }
    }

    /// Writes what is left up to `videoEnd` seconds, pads the track with silence to that length, and closes the file.
    /// Nil when no sound ever arrived, so there is no file.
    func finish(videoEnd: Double) async throws -> AudioTrackReport? {
        let (made, input) = lock.withLock { () -> (AVAssetWriter?, AVAssetWriterInput?) in
            var final = mapping()
            final.settled = .infinity
            final.paused = false
            flush(final, end: videoEnd)
            if self.writer != nil { pad(to: Int((videoEnd * rate).rounded())) }
            finished = true
            return (self.writer, self.input)
        }
        guard let writer = made, let input else { return nil }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw RecordingError.writer(writer.error?.localizedDescription ?? "the sound was not finished") }
        return lock.withLock {
            AudioTrackReport(kind: kind, url: url, rate: rate, channels: channels, frames: written, filled: Double(filled) / max(rate, 1))
        }
    }

    func cancel() {
        let writer = lock.withLock { () -> AVAssetWriter? in
            finished = true
            return self.writer
        }
        writer?.cancelWriting()
        try? FileManager.default.removeItem(at: url)
    }

    /// Called with the lock held.
    private func flush(_ map: RecordingWriter.Mapping, end: Double?) {
        guard let origin = map.origin else { return }
        let until = map.paused ? .infinity : map.settled
        var keep: [AudioChunk] = []
        for chunk in pending {
            let start = chunk.time - origin
            let placed = AudioPlacement.place(start: start, frames: chunk.frames, rate: chunk.rate, pauses: map.pauses, until: until)
            // While paused, everything after the settled end lies inside the pause and is never written.
            let pieces = map.paused ? placed.pieces.compactMap { $0.trimmed(before: map.settled - start, rate: chunk.rate) } : placed.pieces
            for piece in pieces { write(chunk, piece, end: end) }
            if placed.used < chunk.frames, !map.paused {
                keep.append(AudioChunk(time: chunk.time + Double(placed.used) / chunk.rate, rate: chunk.rate,
                                       channels: chunk.channels.map { Array($0[placed.used...]) }))
            }
        }
        pending = keep
    }

    private func write(_ chunk: AudioChunk, _ piece: AudioPlacement.Piece, end: Double?) {
        guard prepare(rate: chunk.rate, sourceChannels: chunk.channels.count) else { return }
        var at = Int((piece.videoTime * rate).rounded())
        var offset = piece.offset, count = piece.count
        if abs(at - written) <= Int(Self.tolerance * rate) { at = written }
        if let end, at >= Int((end * rate).rounded()) { return }
        if at > written { pad(to: at) }
        if at < written {
            let skip = written - at
            guard skip < count else { return }
            offset += skip; count -= skip
        }
        if let end { count = min(count, Int((end * rate).rounded()) - written) }
        guard count > 0 else { return }
        var samples = [Float](repeating: 0, count: count * channels)
        let source = chunk.channels
        for i in 0..<count {
            if mono {
                var sum: Float = 0
                for c in source { sum += c[offset + i] }
                samples[i] = sum / Float(source.count)
            } else {
                for c in 0..<channels { samples[i * channels + c] = source[min(c, source.count - 1)][offset + i] }
            }
        }
        append(samples, frames: count)
    }

    private func pad(to frame: Int) {
        var left = frame - written
        guard left > 0, channels > 0 else { return }
        filled += left
        let block = 4096
        while left > 0 {
            let n = min(block, left)
            append([Float](repeating: 0, count: n * channels), frames: n)
            left -= n
        }
    }

    /// Opens the file on the first sound, at the source's rate, so nothing is resampled.
    private func prepare(rate: Double, sourceChannels: Int) -> Bool {
        if writer != nil { return true }
        guard failure == nil else { return false }
        self.rate = rate
        channels = mono ? 1 : min(sourceChannels, 2)
        do {
            let writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
            // Like the video, a fragment closes every second so a crash leaves a readable track.
            writer.movieFragmentInterval = CMTime(seconds: 1, preferredTimescale: 600)
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: rate,
                AVNumberOfChannelsKey: channels,
                AVEncoderBitRateKey: channels == 1 ? 96_000 : 160_000,
            ])
            input.expectsMediaDataInRealTime = realTime
            guard writer.canAdd(input) else { throw RecordingError.writer("the sound encoder rejected these settings") }
            writer.add(input)
            guard writer.startWriting() else { throw RecordingError.writer(writer.error?.localizedDescription ?? "could not start the sound") }
            writer.startSession(atSourceTime: .zero)
            var asbd = AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
                                                   mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                                                   mBytesPerPacket: UInt32(4 * channels), mFramesPerPacket: 1, mBytesPerFrame: UInt32(4 * channels),
                                                   mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 32, mReserved: 0)
            CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
                                           extensions: nil, formatDescriptionOut: &format)
            self.writer = writer
            self.input = input
        } catch {
            failure = String(describing: error)
            return false
        }
        return true
    }

    /// Interleaved samples, `frames` per channel, at the end of the track.
    private func append(_ samples: [Float], frames: Int) {
        guard let input, let format else { return }
        let bytes = samples.count * 4
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil, customBlockSource: nil,
                                                 offsetToData: 0, dataLength: bytes, flags: 0, blockBufferOut: &block) == noErr, let block else { return }
        samples.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes) }
        var sample: CMSampleBuffer?
        let pts = CMTime(value: CMTimeValue(written), timescale: CMTimeScale(rate))
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: frames,
                                                                   presentationTimeStamp: pts, packetDescriptions: nil, sampleBufferOut: &sample) == noErr,
              let sample else { return }
        var waited = 0
        while !input.isReadyForMoreMediaData, waited < 2_000 {
            usleep(500)
            waited += 1
        }
        if input.append(sample) { written += frames } else { failure = writer?.error?.localizedDescription ?? "a sound buffer was refused" }
    }
}

private extension AudioPlacement.Piece {
    /// The part of the piece before `limit` seconds into its chunk, or nil when none is.
    func trimmed(before limit: Double, rate: Double) -> AudioPlacement.Piece? {
        let cut = Int((limit * rate).rounded())
        guard cut > offset else { return nil }
        return AudioPlacement.Piece(offset: offset, count: min(count, cut - offset), videoTime: videoTime)
    }
}
