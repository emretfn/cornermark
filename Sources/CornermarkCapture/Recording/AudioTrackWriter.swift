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
    /// Every track is written at this rate. A device may send any rate, and change it mid-recording, as a Bluetooth headset does when its
    /// microphone opens, and the encoder refuses rates under 32 kHz at these bit rates, so any other rate is resampled to it.
    static let rate = 48_000.0
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
    private let rate = AudioTrackWriter.rate
    private var channels = 0
    private var run: Run?
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
    /// Nil when no sound ever arrived, so there is no file. Throws when the file could not be opened or a buffer was refused.
    func finish(videoEnd: Double) async throws -> AudioTrackReport? {
        let (made, input, failed) = lock.withLock { () -> (AVAssetWriter?, AVAssetWriterInput?, String?) in
            var final = mapping()
            final.settled = .infinity
            final.paused = false
            flush(final, end: videoEnd)
            if self.writer != nil {
                let last = Int((videoEnd * rate).rounded())
                endRun(limit: last)
                pad(to: last)
            }
            finished = true
            return (self.writer, self.input, failure)
        }
        guard let writer = made, let input else {
            if let failed { throw RecordingError.writer(failed) }
            return nil
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed, failed == nil else {
            throw RecordingError.writer(writer.error?.localizedDescription ?? failed ?? "the sound was not finished")
        }
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
        guard prepare(sourceChannels: chunk.channels.count) else { return }
        let limit = end.map { Int(($0 * rate).rounded()) }
        if run?.rate != chunk.rate {
            endRun(limit: limit)
            let resampler = chunk.rate == rate ? nil : Resampler(from: chunk.rate, to: rate, channels: channels)
            guard chunk.rate == rate || resampler != nil else {
                failure = "sound at \(chunk.rate) Hz cannot be resampled"
                return
            }
            run = Run(rate: chunk.rate, resampler: resampler, start: written)
        }
        guard let current = run else { return }
        let toSource = chunk.rate / rate
        var at = Int((piece.videoTime * rate).rounded())
        var offset = piece.offset, count = piece.count
        let cursor = current.cursor(rate)
        if abs(at - cursor) <= Int(Self.tolerance * rate) { at = cursor }
        if let limit, at >= limit { return }
        if at > cursor {
            filled += at - cursor
            feed([[Float]](repeating: [Float](repeating: 0, count: Int((Double(at - cursor) * toSource).rounded())), count: channels), limit: limit)
        }
        if at < cursor {
            let skip = Int((Double(cursor - at) * toSource).rounded())
            guard skip < count else { return }
            offset += skip; count -= skip
        }
        if let limit, let run { count = min(count, Int((Double(limit - run.cursor(rate)) * toSource).rounded())) }
        guard count > 0 else { return }
        feed(mix(chunk.channels, offset: offset, count: count), limit: limit)
    }

    /// The track's channels of `count` samples from `offset`: every source channel mixed into one, or each kept, the last repeated
    /// when the source has fewer.
    private func mix(_ source: [[Float]], offset: Int, count: Int) -> [[Float]] {
        guard mono else { return (0..<channels).map { Array(source[min($0, source.count - 1)][offset..<offset + count]) } }
        var sum = [Float](repeating: 0, count: count)
        for c in source { for i in 0..<count { sum[i] += c[offset + i] } }
        let scale = 1 / Float(source.count)
        return [sum.map { $0 * scale }]
    }

    /// Source samples through the current run's resampler onto the end of the track.
    private func feed(_ planar: [[Float]], limit: Int?) {
        guard var current = run, let n = planar.first?.count, n > 0 else { return }
        current.consumed += n
        run = current
        append(current.resampler?.convert(planar, last: false) ?? planar, limit: limit)
    }

    /// Writes what the resampler still holds and ends the run, as the rate changes or the track ends.
    private func endRun(limit: Int?) {
        if let resampler = run?.resampler { append(resampler.convert([], last: true), limit: limit) }
        run = nil
    }

    private func append(_ planar: [[Float]], limit: Int?) {
        var frames = planar.first?.count ?? 0
        if let limit { frames = min(frames, limit - written) }
        guard frames > 0 else { return }
        var samples = [Float](repeating: 0, count: frames * channels)
        for c in 0..<channels {
            let channel = planar[min(c, planar.count - 1)]
            for i in 0..<frames { samples[i * channels + c] = channel[i] }
        }
        encode(samples, frames: frames)
    }

    private func pad(to frame: Int) {
        var left = frame - written
        guard left > 0, channels > 0 else { return }
        filled += left
        let block = 4096
        while left > 0 {
            let n = min(block, left)
            encode([Float](repeating: 0, count: n * channels), frames: n)
            left -= n
        }
    }

    /// Opens the file on the first sound.
    private func prepare(sourceChannels: Int) -> Bool {
        if writer != nil { return true }
        guard failure == nil else { return false }
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
    private func encode(_ samples: [Float], frames: Int) {
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

/// Sound that follows on at one source rate, through one resampler, so its joins make no click.
private struct Run {
    let rate: Double
    /// Nil at the track's rate.
    let resampler: Resampler?
    /// The track sample its first sample landed on.
    let start: Int
    /// Source samples given to it so far.
    var consumed = 0

    /// Where its next source sample lands on the track, which is ahead of what is written by what the resampler still holds.
    func cursor(_ trackRate: Double) -> Int { start + Int((Double(consumed) * trackRate / rate).rounded()) }
}

/// Changes the rate of planar float sound. The filter keeps its state between calls, so consecutive pieces join without a click.
final class Resampler {
    private let converter: AVAudioConverter
    private let input: AVAudioFormat
    private let output: AVAudioFormat

    init?(from: Double, to: Double, channels: Int) {
        guard let input = AVAudioFormat(standardFormatWithSampleRate: from, channels: AVAudioChannelCount(channels)),
              let output = AVAudioFormat(standardFormatWithSampleRate: to, channels: AVAudioChannelCount(channels)),
              let converter = AVAudioConverter(from: input, to: output) else { return nil }
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        self.input = input; self.output = output; self.converter = converter
    }

    /// `planar` at the new rate, as far as the filter has got. `last` also gives what it still holds, and ends its use.
    func convert(_ planar: [[Float]], last: Bool) -> [[Float]] {
        let channels = Int(output.channelCount), n = planar.first?.count ?? 0
        var given = 0
        var out = [[Float]](repeating: [], count: channels)
        while let buffer = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: AVAudioFrameCount(Double(n) * output.sampleRate / input.sampleRate) + 1024) {
            var error: NSError?
            let status = converter.convert(to: buffer, error: &error) { wanted, state in
                let take = min(Int(wanted), n - given)
                guard take > 0, let piece = AVAudioPCMBuffer(pcmFormat: self.input, frameCapacity: AVAudioFrameCount(take)) else {
                    state.pointee = last ? .endOfStream : .noDataNow
                    return nil
                }
                piece.frameLength = AVAudioFrameCount(take)
                for c in 0..<channels { planar[c].withUnsafeBufferPointer { piece.floatChannelData![c].update(from: $0.baseAddress! + given, count: take) } }
                given += take
                state.pointee = .haveData
                return piece
            }
            for c in 0..<channels { out[c] += UnsafeBufferPointer(start: buffer.floatChannelData![c], count: Int(buffer.frameLength)) }
            if status != .haveData || buffer.frameLength == 0 { break }
        }
        return out
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
