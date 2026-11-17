import CornermarkCore
import XCTest
@testable import CornermarkVideoEditor

/// A render that takes as long as the test wants: it notes which Low cut frequency it started on, then runs until released or cancelled.
private final class HeldRender: @unchecked Sendable {
    private let lock = NSLock()
    private var startedOn: [Double] = []
    private var isReleased = false

    var started: [Double] { lock.withLock { startedOn } }
    func release() { lock.withLock { isReleased = true } }

    func render(_ microphone: URL, settings: VoiceCleanup) throws -> URL {
        lock.withLock { startedOn.append(settings.lowCutFrequency) }
        while !lock.withLock({ isReleased }) {
            try Task.checkCancellation()
            usleep(1_000)
        }
        try Task.checkCancellation()
        return URL(fileURLWithPath: "/tmp/clean-\(Int(settings.lowCutFrequency)).m4a")
    }

    func waitUntilStarted(_ count: Int) async throws {
        for _ in 0..<5_000 where started.count < count { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertEqual(started.count, count, "the render started")
    }
}

final class VoiceCleanupRendersTests: XCTestCase {
    private let microphone = URL(fileURLWithPath: "/tmp/mic.m4a")

    private func lowCut(_ frequency: Double) -> VoiceCleanup {
        var settings = VoiceCleanup(isOn: true)
        settings.lowCutFrequency = frequency
        return settings
    }

    private func isCancelled(_ task: Task<URL, Error>) async -> Bool {
        if case .failure(let error) = await task.result { return error is CancellationError }
        return false
    }

    func testRapidChangesRenderOnlyTheLatestSettings() async throws {
        let held = HeldRender()
        let renders = VoiceCleanupRenders(render: held.render)
        let first = renders.request(microphone, settings: lowCut(100))
        try await held.waitUntilStarted(1)
        let second = renders.request(microphone, settings: lowCut(120))
        let third = renders.request(microphone, settings: lowCut(140))
        held.release()

        let latest = try await third.value
        XCTAssertEqual(latest.lastPathComponent, "clean-140.m4a")
        let firstCancelled = await isCancelled(first), secondCancelled = await isCancelled(second)
        XCTAssertTrue(firstCancelled, "the render in flight is superseded")
        XCTAssertTrue(secondCancelled, "a change made while another waited never renders")
        XCTAssertEqual(held.started, [100, 140])
    }

    func testAnExportDuringARenderWaitsForItInsteadOfStartingASecond() async throws {
        let held = HeldRender()
        let renders = VoiceCleanupRenders(render: held.render)
        let preview = renders.request(microphone, settings: lowCut(100))
        try await held.waitUntilStarted(1)
        let export = renders.request(microphone, settings: lowCut(100), keep: true)
        held.release()

        let exported = try await export.value, previewed = try await preview.value
        XCTAssertEqual(exported.lastPathComponent, "clean-100.m4a")
        XCTAssertEqual(previewed, exported)
        XCTAssertEqual(held.started, [100], "one render serves both")
    }

    func testAChangeDuringAnExportDoesNotCancelTheRenderTheExportWaitsFor() async throws {
        let held = HeldRender()
        let renders = VoiceCleanupRenders(render: held.render)
        let export = renders.request(microphone, settings: lowCut(100), keep: true)
        try await held.waitUntilStarted(1)
        let preview = renders.request(microphone, settings: lowCut(120))
        held.release()

        let exported = try await export.value, previewed = try await preview.value
        XCTAssertEqual(exported.lastPathComponent, "clean-100.m4a", "the export mixes the sound it asked for")
        XCTAssertEqual(previewed.lastPathComponent, "clean-120.m4a", "and the newer settings render after it")
        XCTAssertEqual(held.started, [100, 120])
    }

    func testASupersededRenderStopsAndLeavesNoCleanedFile() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("renders-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let mic = folder.appendingPathComponent("mic.m4a")
        try TestSound.write(mic, seconds: 30, channels: [[(50, 0.3), (1_000, 0.3)]])
        let renders = VoiceCleanupRenders()

        let superseded = renders.request(mic, settings: lowCut(100))
        // Under way once its half-written file is there.
        for _ in 0..<5_000 where (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.count == 1 {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).count, 2, "the render started")
        superseded.cancel()
        let isStopped = await isCancelled(superseded)
        XCTAssertTrue(isStopped, "a cancelled render stops instead of finishing")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["mic.m4a"], "and leaves nothing half-written behind")
    }
}
