import XCTest
@testable import CornermarkCore

final class ProjectPackageTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ProjectPackageTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func folder(_ name: String, video: String = "screen.mp4", origin: RecordingProject.Source.Origin = .recording) throws -> (URL, RecordingProject) {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data("video bytes".utf8).write(to: url.appendingPathComponent(video))
        let project = RecordingProject(source: .init(video: video, pixelWidth: 640, pixelHeight: 360, pointWidth: 640, pointHeight: 360, fps: 30, duration: 2, origin: origin))
        try RecordingProjectFile.write(project, to: url)
        return (url, project)
    }

    func testAProjectWithoutAnOriginWasRecorded() throws {
        let p = try JSONDecoder().decode(RecordingProject.self, from: Data(#"{"source": {"video": "screen.mp4"}}"#.utf8))
        XCTAssertEqual(p.source.origin, .recording)
        let unknown = try JSONDecoder().decode(RecordingProject.self, from: Data(#"{"source": {"origin": "camera"}}"#.utf8))
        XCTAssertEqual(unknown.source.origin, .recording, "an origin a later version adds still opens")
    }

    func testOriginRoundTrips() throws {
        let (url, project) = try folder("Clip.cornermarkvideo", video: "clip.mov", origin: .file)
        XCTAssertEqual(try RecordingProjectFile.read(from: url), project)
        XCTAssertEqual(try RecordingProjectFile.read(from: url).source.origin, .file)
    }

    func testDisplayNameDropsOnlyThePackageExtension() {
        XCTAssertEqual(RecordingProjectFile.displayName(of: URL(fileURLWithPath: "/a/Demo.cornermarkvideo")), "Demo")
        XCTAssertEqual(RecordingProjectFile.displayName(of: URL(fileURLWithPath: "/a/Demo.CornermarkVideo")), "Demo")
        XCTAssertEqual(RecordingProjectFile.displayName(of: URL(fileURLWithPath: "/a/Cornermark Recording 2026-11-03 at 14.05.09")), "Cornermark Recording 2026-11-03 at 14.05.09")
        XCTAssertEqual(RecordingProjectFile.displayName(of: URL(fileURLWithPath: "/a/v1.2")), "v1.2")
    }

    func testThePlayedFileIsTheOneTheProjectNames() throws {
        let (url, _) = try folder("Clip.cornermarkvideo", video: "clip.mov", origin: .file)
        XCTAssertEqual(RecordedVideo(location: url, format: .project, duration: 2).file.lastPathComponent, "clip.mov")
        let (old, _) = try folder("Old Recording")
        XCTAssertEqual(RecordedVideo(location: old, format: .project, duration: 2).file.lastPathComponent, "screen.mp4")
        XCTAssertEqual(RecordedVideo(location: root.appendingPathComponent("gone"), format: .project, duration: 2).file.lastPathComponent, "screen.mp4",
                       "a project whose file is gone still names the usual video, so the app can say it is missing")
    }

    func testCopyWritesTheEditsToTheCopyAndLeavesTheOriginal() throws {
        let (url, project) = try folder("Original.cornermarkvideo")
        try Data("picture".utf8).write(to: url.appendingPathComponent("background-1.png"))
        var edited = project
        edited.edits.cursor.scale = 3
        let target = root.appendingPathComponent("Copy.cornermarkvideo", isDirectory: true)
        try RecordingProjectFile.copy(edited, from: url, to: target)
        XCTAssertEqual(try RecordingProjectFile.read(from: target), edited)
        XCTAssertEqual(try RecordingProjectFile.read(from: url), project)
        XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent("screen.mp4")), Data("video bytes".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.appendingPathComponent("background-1.png").path), "files the edits added go with the copy")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix(".") }, [], "no staging folder is left")
    }

    func testCopyOverAnExistingPackageReplacesIt() throws {
        let (url, project) = try folder("Original.cornermarkvideo")
        let (target, _) = try folder("Taken.cornermarkvideo", video: "other.mov")
        try RecordingProjectFile.copy(project, from: url, to: target)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: target.path)), ["screen.mp4", "project.json"])
    }
}
