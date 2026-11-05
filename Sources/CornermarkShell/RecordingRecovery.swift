import AVFoundation
import CornermarkCapture
import CornermarkCore

/// One small file per recording in progress, written once its first frame is on disk and removed when it ends. A file still here at
/// launch belongs to a recording the app never finished, because it crashed or was killed.
struct RecordingJournal {
    struct Entry: Codable, Equatable {
        var id = UUID()
        var location: URL
        var format: RecordedVideo.Format
        var kind: CaptureKind
        /// The filmed area in points, which a project's pointer track is measured in.
        var pointWidth: Double
        var pointHeight: Double

        var video: RecordedVideo { RecordedVideo(location: location, format: format, duration: 0) }
    }

    let folder: URL

    private func file(_ entry: Entry) -> URL { folder.appendingPathComponent("\(entry.id.uuidString).json") }

    func open(location: URL, format: RecordedVideo.Format, kind: CaptureKind, area: CGRect) -> Entry? {
        let entry = Entry(location: location, format: format, kind: kind, pointWidth: area.width, pointHeight: area.height)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try JSONEncoder().encode(entry).write(to: file(entry), options: .atomic)
            return entry
        } catch {
            Log.shell.error("recording journal not written: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    func close(_ entry: Entry) { try? FileManager.default.removeItem(at: file(entry)) }

    func entries() -> [Entry] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap { url in
            (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Entry.self, from: $0) }
        }
    }
}

/// Turns the file of a recording that was cut off into a finished one. The writer closes a fragment every second, so the file holds
/// every frame up to its last full second. Rewriting it without fragments gives a file any player reads, and a project gets its
/// `project.json` back, with an empty pointer track because the track was only in memory.
enum RecordingRecovery {
    enum Failure: Error, CustomStringConvertible {
        case missing, unreadable, export(String)
        var description: String {
            switch self {
            case .missing: return "the file is gone"
            case .unreadable: return "the file holds no frames"
            case .export(let m): return "rewrite failed: \(m)"
            }
        }
    }

    /// Safe to run again on a file it already finished: the rewrite of a plain file is the same file.
    static func finish(_ entry: RecordingJournal.Entry) async throws -> FinishedRecording {
        let file = entry.video.file
        guard FileManager.default.fileExists(atPath: file.path) else { throw Failure.missing }
        let asset = AVURLAsset(url: file)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let duration = try? await asset.load(.duration), duration.seconds > 0 else { throw Failure.unreadable }
        let size = (try? await track.load(.naturalSize)) ?? .zero
        let fps = (try? await track.load(.nominalFrameRate)).map { Int($0.rounded()) } ?? 60

        let rewritten = file.deletingLastPathComponent().appendingPathComponent(".recovering-" + file.lastPathComponent)
        try? FileManager.default.removeItem(at: rewritten)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else { throw Failure.export("no export session") }
        export.outputURL = rewritten
        export.outputFileType = .mp4
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in export.exportAsynchronously { done.resume() } }
        guard export.status == .completed else {
            try? FileManager.default.removeItem(at: rewritten)
            throw Failure.export(export.error?.localizedDescription ?? "status \(export.status.rawValue)")
        }
        _ = try FileManager.default.replaceItemAt(file, withItemAt: rewritten)
        let seconds = (try? await AVURLAsset(url: file).load(.duration).seconds) ?? duration.seconds

        if entry.format == .project {
            let project = RecordingProject(
                source: .init(video: file.lastPathComponent, pixelWidth: Int(size.width), pixelHeight: Int(size.height),
                              pointWidth: entry.pointWidth, pointHeight: entry.pointHeight, fps: fps, duration: seconds),
                events: .init(pointer: []))
            try RecordingProjectFile.write(project, to: entry.location)
        }
        return FinishedRecording(video: RecordedVideo(location: entry.location, format: entry.format, duration: seconds),
                                 pixelSize: size, kind: entry.kind)
    }
}
