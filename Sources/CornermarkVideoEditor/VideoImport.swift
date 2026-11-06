import AVFoundation
import CornermarkCore
import UniformTypeIdentifiers

public enum VideoImportError: Error, Equatable {
    /// The file is not an MP4 or QuickTime movie.
    case notAVideo
    /// The file holds no picture to edit.
    case noPicture
    /// The picture is stored turned, which the preview and the export would show on its side.
    case turned
}

/// Makes a project from a video file. The video is copied into the new package as it is, never encoded again, and the original is
/// only read. A video from a file has no pointer, click or key tracks: whatever was filmed is already in its picture.
public enum VideoImport {
    public static let types: [UTType] = [.mpeg4Movie, .quickTimeMovie]

    public static func canImport(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return types.contains { type.conforms(to: $0) }
    }

    /// Writes `<save folder>/<video name>.cornermarkvideo`, never over an existing one, and returns it with its project.
    public static func makeProject(from video: URL, in saveFolder: URL) async throws -> (folder: URL, project: RecordingProject) {
        guard canImport(video) else { throw VideoImportError.notAVideo }
        let asset = AVURLAsset(url: video)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw VideoImportError.noPicture }
        let (size, transform, rate) = try await track.load(.naturalSize, .preferredTransform, .nominalFrameRate)
        guard transform.a == 1, transform.b == 0, transform.c == 0, transform.d == 1 else { throw VideoImportError.turned }
        let duration = try await asset.load(.duration).seconds
        guard size.width >= 1, size.height >= 1, duration.isFinite, duration > 0 else { throw VideoImportError.noPicture }

        let base = video.deletingPathExtension().lastPathComponent
        let fm = FileManager.default
        try fm.createDirectory(at: saveFolder, withIntermediateDirectories: true)
        var folder = saveFolder.appendingPathComponent("\(base).\(RecordingProjectFile.packageExtension)", isDirectory: true)
        var n = 2
        while fm.fileExists(atPath: folder.path) {
            folder = saveFolder.appendingPathComponent("\(base) \(n).\(RecordingProjectFile.packageExtension)", isDirectory: true)
            n += 1
        }
        let name = video.lastPathComponent
        let source = RecordingProject.Source(video: name, pixelWidth: Int(size.width.rounded()), pixelHeight: Int(size.height.rounded()),
                                             pointWidth: Double(size.width), pointHeight: Double(size.height),
                                             fps: rate > 0 ? Int(rate.rounded()) : 30, duration: duration, origin: .file)
        let project = RecordingProject(source: source)
        try fm.createDirectory(at: folder, withIntermediateDirectories: false)
        do {
            try fm.copyItem(at: video, to: folder.appendingPathComponent(name))
            try RecordingProjectFile.write(project, to: folder)
        } catch {
            try? fm.removeItem(at: folder)
            throw error
        }
        return (folder, project)
    }
}
