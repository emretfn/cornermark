import CoreGraphics
import XCTest
@testable import CornermarkCore

final class CaptureStoreTests: XCTestCase {
    private let day: TimeInterval = 86_400
    private let image = Fixture.detail(64, 40)

    private func makeStore() throws -> (CaptureStore, URL) {
        let root = try tempDirectory().appendingPathComponent("history", isDirectory: true)
        return (try CaptureStore(root: root), root)
    }

    func testAddWritesImageAndIndexAtomically() throws {
        let (store, root) = try makeStore()
        let record = try store.add(image, kind: .area, pointScale: 2)
        XCTAssertEqual(record.pixelSize, CGSize(width: 64, height: 40))
        XCTAssertEqual(record.pointScale, 2)

        let paths = store.paths(for: record)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.image.path))
        XCTAssertEqual(try Pixels(XCTUnwrap(AssetStore.decode(Data(contentsOf: paths.image)))).count { _ in true }, 64 * 40)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("index.json").path))
        XCTAssertEqual(store.list().map(\.id), [record.id])
        XCTAssertFalse(store.hasProject(record))
    }

    func testListIsNewestFirstAndFilters() throws {
        let (store, _) = try makeStore()
        let now = Date()
        let a = try store.add(image, kind: .area, now: now.addingTimeInterval(-3 * day))
        let b = try store.add(image, kind: .window, now: now.addingTimeInterval(-2 * day))
        let c = try store.add(image, kind: .area, now: now.addingTimeInterval(-1 * day))

        XCTAssertEqual(store.list().map(\.id), [c.id, b.id, a.id])
        XCTAssertEqual(store.list(filter: CaptureFilter(kinds: [.area])).map(\.id), [c.id, a.id])
        XCTAssertEqual(store.list(filter: CaptureFilter(createdAfter: now.addingTimeInterval(-2.5 * day))).map(\.id), [c.id, b.id])
        XCTAssertEqual(store.list(filter: CaptureFilter(createdBefore: now.addingTimeInterval(-2.5 * day))).map(\.id), [a.id])
        XCTAssertEqual(store.list(filter: CaptureFilter(limit: 1)).map(\.id), [c.id])
    }

    func testDeleteRemovesRecordAndFilesAndRejectsUnknownIDs() throws {
        let (store, _) = try makeStore()
        let keep = try store.add(image, kind: .area)
        let drop = try store.add(image, kind: .window)
        let dropDir = store.paths(for: drop).directory
        try store.delete(drop.id)
        XCTAssertEqual(store.list().map(\.id), [keep.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: dropDir.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.paths(for: keep).image.path))
        XCTAssertThrowsError(try store.delete(drop.id)) { XCTAssertEqual($0 as? CaptureStoreError, .unknownRecord(drop.id)) }
    }

    func testPruneRemovesOnlyEntriesOlderThanThirtyDays() throws {
        let (store, root) = try makeStore()
        let now = Date()
        let ancient = try store.add(image, kind: .area, now: now.addingTimeInterval(-90 * day))
        let old = try store.add(image, kind: .window, now: now.addingTimeInterval(-30 * day - 1))
        let edge = try store.add(image, kind: .timed, now: now.addingTimeInterval(-29 * day))
        let fresh = try store.add(image, kind: .area, now: now)

        let removed = try store.prune(olderThan: 30 * day, now: now)
        XCTAssertEqual(Set(removed.map(\.id)), [ancient.id, old.id])
        XCTAssertEqual(Set(store.list().map(\.id)), [edge.id, fresh.id])
        for gone in [ancient, old] { XCTAssertFalse(FileManager.default.fileExists(atPath: store.paths(for: gone).directory.path)) }
        for kept in [edge, fresh] { XCTAssertTrue(FileManager.default.fileExists(atPath: store.paths(for: kept).image.path)) }

        XCTAssertEqual(try store.prune(olderThan: 30 * day, now: now), [], "pruning again is a no-op")
        XCTAssertEqual(Set(try CaptureStore(root: root).list().map(\.id)), [edge.id, fresh.id], "persisted")
        XCTAssertEqual(CaptureStore.defaultRetention, 30 * day)
    }

    func testIndexSurvivesReopen() throws {
        let (store, root) = try makeStore()
        let r = try store.add(image, kind: .scrolling, pointScale: 2)
        let reopened = try CaptureStore(root: root)
        XCTAssertEqual(reopened.list(), [r])
        XCTAssertEqual(reopened.record(id: r.id), r)
    }

    func testCorruptIndexIsSetAsideAndHistoryRebuiltFromFolders() throws {
        let (store, root) = try makeStore()
        let r = try store.add(image, kind: .area)
        try Data("not json".utf8).write(to: root.appendingPathComponent("index.json"))
        let reopened = try CaptureStore(root: root)
        XCTAssertEqual(reopened.list().count, 1)
        XCTAssertEqual(reopened.list().first?.directoryName, r.directoryName)
        XCTAssertEqual(reopened.list().first?.pixelSize, r.pixelSize)
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertTrue(names.contains { $0.hasPrefix("index.corrupt-") })
    }

    func testOpenAndSaveDocumentRestoreEditedStateOrOriginal() throws {
        let (store, _) = try makeStore()
        let r = try store.add(image, kind: .area, pointScale: 2)

        var (doc, assets) = try store.openDocument(for: r)
        XCTAssertEqual(doc.pixelSize, CGSize(width: 64, height: 40))
        XCTAssertEqual(doc.pointScale, 2)
        XCTAssertEqual(assets.data(for: doc.base), try Data(contentsOf: store.paths(for: r).image))

        doc.annotations = [Fixture.annotation(.counter(center: CGPoint(x: 10, y: 10), number: 3, radius: 8))]
        doc.geometry.quarterTurns = 2
        try store.saveDocument(doc, assets: assets, for: r)
        XCTAssertTrue(store.hasProject(r))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.paths(for: r).image.path), "original stays beside the project")

        let (again, _) = try store.openDocument(for: r)
        XCTAssertEqual(again, doc)
    }

    func testPathsIgnoreTraversalInDirectoryNames() throws {
        let (store, root) = try makeStore()
        let hostile = CaptureRecord(kind: .area, pixelSize: .zero, directoryName: "../../etc")
        let p = store.paths(for: hostile)
        XCTAssertEqual(p.directory.deletingLastPathComponent().standardizedFileURL.path, root.standardizedFileURL.path)
    }

    func testRecordingKeepsItsVideoWhereItWasSavedAndListsWithAFilter() throws {
        let (store, root) = try makeStore()
        let saved = try tempDirectory().appendingPathComponent("Cornermark Recording 2026-11-03 at 14.05.09.mp4")
        try Data("not really a video".utf8).write(to: saved)
        let picture = try store.add(image, kind: .area)
        let video = RecordedVideo(location: saved, format: .video, duration: 2.5)
        let recording = try store.addRecording(video, poster: image, kind: .window, pixelSize: CGSize(width: 1280, height: 720))

        XCTAssertEqual(recording.video, video)
        XCTAssertTrue(recording.isRecording)
        XCTAssertFalse(picture.isRecording)
        XCTAssertEqual(recording.kind, .window, "the kind stays what was filmed")
        XCTAssertEqual(recording.pixelSize, CGSize(width: 1280, height: 720), "the video's size, not the poster's")
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.paths(for: recording).image.path), "history keeps a poster frame")
        XCTAssertEqual(store.list(filter: CaptureFilter(recordings: true)).map(\.id), [recording.id])
        XCTAssertEqual(store.list(filter: CaptureFilter(recordings: false)).map(\.id), [picture.id])
        XCTAssertEqual(store.list().count, 2)
        XCTAssertEqual(try CaptureStore(root: root).record(id: recording.id)?.video, video, "persisted")

        try store.delete(recording.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: saved.path), "deleting the entry leaves the video alone")
        let old = try store.addRecording(video, poster: image, kind: .area, pixelSize: .zero, now: Date().addingTimeInterval(-90 * day))
        XCTAssertEqual(try store.prune(olderThan: 30 * day).map(\.id), [old.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: saved.path), "pruning leaves the video alone")
    }

    func testAnOwnedVideoMovesInAndLeavesWithItsEntry() throws {
        let (store, _) = try makeStore()
        try FileManager.default.createDirectory(at: store.incomingDirectory, withIntermediateDirectories: true)
        let file = store.incomingDirectory.appendingPathComponent("Cornermark Recording 1.mp4")
        try Data([1, 2, 3]).write(to: file)
        let record = try store.addOwnedVideo(moving: file, duration: 2, poster: image, kind: .area, pixelSize: CGSize(width: 1280, height: 720))
        let video = try XCTUnwrap(record.video)
        XCTAssertEqual(video.format, .video)
        XCTAssertEqual(video.file.lastPathComponent, "Cornermark Recording 1.mp4")
        XCTAssertEqual(video.file.deletingLastPathComponent().path, store.paths(for: record).directory.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "the file moved, it was not copied")
        XCTAssertEqual(try Data(contentsOf: video.file), Data([1, 2, 3]))
        XCTAssertTrue(record.ownsVideo)
        try store.delete(record.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: video.file.path), "deleting the entry deletes the video it owns")
    }

    func testARecordingIsNotOwned() throws {
        let (store, root) = try makeStore()
        let elsewhere = root.deletingLastPathComponent().appendingPathComponent("a.mp4")
        try Data([1]).write(to: elsewhere)
        let record = try store.addRecording(RecordedVideo(location: elsewhere, format: .video, duration: 1), poster: image, kind: .area, pixelSize: .zero)
        XCTAssertFalse(record.ownsVideo)
        try store.delete(record.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: elsewhere.path))
    }

    func testProjectRecordingPlaysItsScreenVideo() {
        let folder = URL(fileURLWithPath: "/tmp/Cornermark Recording", isDirectory: true)
        XCTAssertEqual(RecordedVideo(location: folder, format: .project, duration: 1).file.lastPathComponent, RecordingProjectFile.videoName)
        let file = URL(fileURLWithPath: "/tmp/a.mp4")
        XCTAssertEqual(RecordedVideo(location: file, format: .video, duration: 1).file, file)
    }

    func testIndexFromBeforeRecordingsStillLoads() throws {
        let root = try tempDirectory().appendingPathComponent("history", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let json = """
        {"records":[{"createdAt":783900000,"directoryName":"2025-11-03_140509_AB12CD34","id":"0F2C1C9E-4A55-4D3B-9A57-2B8E4D9A7F01",
        "kind":"area","pixelSize":[640,400],"pointScale":2}],"version":1}
        """
        try Data(json.utf8).write(to: root.appendingPathComponent("index.json"))
        let records = try CaptureStore(root: root).list()
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.kind, .area)
        XCTAssertNil(records.first?.video)
        XCTAssertEqual((try FileManager.default.contentsOfDirectory(atPath: root.path)).filter { $0.hasPrefix("index.corrupt") }, [])
    }
}
