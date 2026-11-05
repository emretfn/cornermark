import AVFoundation
import CornermarkCore

/// Several sound files read as one: every track is summed into 48 kHz stereo. A finished video carries one track, because a player
/// plays one track at a time. The tracks share the video's timeline, so the same clips cut both.
final class AudioMixReader {
    static let aacSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 160_000,
    ]
    private static let pcmSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 32,
        AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false,
    ]

    private let reader: AVAssetReader
    private let output: AVAssetReaderAudioMixOutput

    /// Nil when none of the files has sound. `clips` are the stretches of the source kept, back to back, nil for all of it, and
    /// `duration` cuts the mix at the output's end.
    init?(files: [URL], clips: [Clip]? = nil, duration: Double) async throws {
        let composition = AVMutableComposition()
        var tracks: [AVAssetTrack] = []
        for file in files where FileManager.default.fileExists(atPath: file.path) {
            let asset = AVURLAsset(url: file)
            guard let source = try await asset.loadTracks(withMediaType: .audio).first,
                  let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            let whole = try await source.load(.timeRange)
            guard let clips else {
                try track.insertTimeRange(whole, of: source, at: .zero)
                tracks.append(track)
                continue
            }
            var at = CMTime.zero
            for clip in clips {
                let range = CMTimeRange(start: CMTime(seconds: clip.start, preferredTimescale: 48_000), end: CMTime(seconds: clip.end, preferredTimescale: 48_000))
                let kept = range.intersection(whole)
                if !kept.isEmpty { try track.insertTimeRange(kept, of: source, at: CMTimeAdd(at, CMTimeSubtract(kept.start, range.start))) }
                at = CMTimeAdd(at, range.duration)
            }
            tracks.append(track)
        }
        guard !tracks.isEmpty else { return nil }
        reader = try AVAssetReader(asset: composition)
        reader.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: duration, preferredTimescale: 48_000))
        output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: Self.pcmSettings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { throw ExportError.writer(reader.error?.localizedDescription ?? "the sound could not be read") }
    }

    func next() -> CMSampleBuffer? { output.copyNextSampleBuffer() }
    func cancel() { reader.cancelReading() }
    var failed: Bool { reader.status == .failed }

    /// The writer input for the mixed track, to add before the writer starts.
    static func makeInput() -> AVAssetWriterInput {
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: aacSettings)
        input.expectsMediaDataInRealTime = false
        return input
    }

    /// Feeds the whole mix into `input` on a queue of its own as the writer asks for it, and calls `done` once it is all in.
    func feed(_ input: AVAssetWriterInput, done: @escaping () -> Void) {
        let queue = DispatchQueue(label: "cornermark.audio-mix")
        var finished = false
        input.requestMediaDataWhenReady(on: queue) { [self] in
            while input.isReadyForMoreMediaData, !finished {
                guard let sample = next(), input.append(sample) else {
                    finished = true
                    input.markAsFinished()
                    done()
                    return
                }
            }
        }
    }
}

public enum AudioMux {
    /// Copies the pictures of `video` as they are and adds `audio`, mixed into one AAC track as long as the video, into a new file at
    /// `output`. Nothing is re-encoded but the sound.
    public static func mux(video: URL, audio: [URL], to output: URL) async throws {
        let asset = AVURLAsset(url: video)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw ExportError.noVideo }
        let duration = try await asset.load(.duration).seconds
        guard let mix = try await AudioMixReader(files: audio, duration: duration) else { throw ExportError.writer("there is no sound to add") }
        defer { mix.cancel() }
        let reader = try AVAssetReader(asset: asset)
        let pictures = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(pictures)
        try? FileManager.default.removeItem(at: output)
        let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
        let formats = try await track.load(.formatDescriptions)
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: formats.first)
        videoInput.expectsMediaDataInRealTime = false
        let audioInput = AudioMixReader.makeInput()
        guard writer.canAdd(videoInput), writer.canAdd(audioInput) else { throw ExportError.writer("the tracks could not be added") }
        writer.add(videoInput)
        writer.add(audioInput)
        guard reader.startReading(), writer.startWriting() else {
            throw ExportError.writer(writer.error?.localizedDescription ?? reader.error?.localizedDescription ?? "the file could not be started")
        }
        writer.startSession(atSourceTime: .zero)
        await withCheckedContinuation { (all: CheckedContinuation<Void, Never>) in
            let group = DispatchGroup()
            group.enter()
            group.enter()
            var finished = false
            videoInput.requestMediaDataWhenReady(on: DispatchQueue(label: "cornermark.mux-video")) {
                while videoInput.isReadyForMoreMediaData, !finished {
                    guard let sample = pictures.copyNextSampleBuffer(), videoInput.append(sample) else {
                        finished = true
                        videoInput.markAsFinished()
                        group.leave()
                        return
                    }
                }
            }
            mix.feed(audioInput) { group.leave() }
            group.notify(queue: .global()) { all.resume() }
        }
        if reader.status == .failed || mix.failed {
            writer.cancelWriting()
            throw ExportError.writer(reader.error?.localizedDescription ?? "the sound could not be read")
        }
        await writer.finishWriting()
        guard writer.status == .completed else { throw ExportError.writer(writer.error?.localizedDescription ?? "the file could not be finished") }
    }
}
