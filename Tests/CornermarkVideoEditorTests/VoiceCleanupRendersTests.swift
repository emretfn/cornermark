import CornermarkCore
import XCTest
@testable import CornermarkVideoEditor

/// A render that takes as long as the test wants: it notes which Low cut frequency it started on, then runs until released or cancelled,
/// and notes the ones it stopped on.
private final class HeldRender: @unchecked Sendable {
    private let lock = NSLock()
    private var startedOn: [Double] = []
    private var stoppedOn: [Double] = []
    private var isReleased = false

    var started: [Double] { lock.withLock { startedOn } }
    var stopped: [Double] { lock.withLock { stoppedOn } }
    func release() { lock.withLock { isReleased = true } }

    /// Releases the render after a while, so a test whose render is never stopped ends with a failed assertion instead of waiting forever.
    func releaseLater() {
        Task.detached { [self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            release()
        }
    }

    func render(_ microphone: URL, settings: VoiceCleanup) throws -> VoiceCleanupRenders.Cleaned {
        lock.withLock { startedOn.append(settings.lowCutFrequency) }
        while !lock.withLock({ isReleased }) {
            guard !Task.isCancelled else { break }
            usleep(1_000)
        }
        guard !Task.isCancelled else {
            lock.withLock { stoppedOn.append(settings.lowCutFrequency) }
            throw CancellationError()
        }
        return (URL(fileURLWithPath: "/tmp/clean-\(Int(settings.lowCutFrequency)).m4a"), VoiceCleanupReport())
    }

    func waitUntilStarted(_ count: Int) async throws {
        for _ in 0..<5_000 where started.count < count { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertEqual(started.count, count, "the render started")
    }
}

final class VoiceCleanupRendersTests: XCTestCase {
    /// In a folder that is never made, so the cleaned copies a finished render removes beside it are none.
    private let microphone = FileManager.default.temporaryDirectory.appendingPathComponent("renders-\(UUID().uuidString)/mic.m4a")

    private func lowCut(_ frequency: Double) -> VoiceCleanup {
        var settings = VoiceCleanup(isOn: true)
        settings.lowCutFrequency = frequency
        return settings
    }

    private func isCancelled(_ task: Task<VoiceCleanupRenders.Cleaned, Error>) async -> Bool {
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

        let latest = try await third.value.url
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

        let exported = try await export.value.url, previewed = try await preview.value.url
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

        let exported = try await export.value.url, previewed = try await preview.value.url
        XCTAssertEqual(exported.lastPathComponent, "clean-100.m4a", "the export mixes the sound it asked for")
        XCTAssertEqual(previewed.lastPathComponent, "clean-120.m4a", "and the newer settings render after it")
        XCTAssertEqual(held.started, [100, 120])
    }

    func testARenderForNewSettingsLeavesTheCleanedFileAnExportHoldsInPlace() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let mic = folder.appendingPathComponent("mic.m4a")
        try TestSound.write(mic, seconds: 1, channels: [[(50, 0.3), (1_000, 0.3)]])
        let renders = VoiceCleanupRenders()

        let lease = renders.lease(mic, settings: lowCut(100))
        let exported = try await renders.cleaned(mic, settings: lowCut(100), keep: true).url
        let newer = try await renders.cleaned(mic, settings: lowCut(120)).url
        XCTAssertTrue(FileManager.default.fileExists(atPath: exported.path), "the export still holds it, so the newer render leaves it")
        XCTAssertTrue(FileManager.default.fileExists(atPath: newer.path))

        renders.release(lease)
        await renders.removed()
        XCTAssertFalse(FileManager.default.fileExists(atPath: exported.path), "released, it goes, since newer settings were rendered since")
        XCTAssertTrue(FileManager.default.fileExists(atPath: newer.path), "and the latest stays")
        let latest = try await renders.cleaned(mic, settings: lowCut(140)).url
        XCTAssertFalse(FileManager.default.fileExists(atPath: newer.path), "a file nobody holds goes with the next render")
        XCTAssertTrue(FileManager.default.fileExists(atPath: latest.path))
    }

    func testALeaseAlsoHoldsTheCopyMadeWithoutNoiseRemovalWhenItCouldNotRun() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let mic = folder.appendingPathComponent("mic.m4a")
        // Stands in for a Mac whose sound isolation unit fails: the copy takes the name of the settings without Noise removal.
        let renders = VoiceCleanupRenders { microphone, settings in
            var without = settings
            without.noiseRemovalOn = false
            let made = VoiceCleanupCache.file(for: microphone, settings: without)
            try Data().write(to: made)
            return (made, VoiceCleanupReport(noiseRemovalUnavailable: true))
        }

        let lease = renders.lease(mic, settings: lowCut(100))
        let exported = try await renders.cleaned(mic, settings: lowCut(100), keep: true).url
        _ = try await renders.cleaned(mic, settings: lowCut(120))
        XCTAssertTrue(FileManager.default.fileExists(atPath: exported.path), "the export still holds the copy it got")
        renders.release(lease)
        await renders.removed()
        XCTAssertFalse(FileManager.default.fileExists(atPath: exported.path))
    }

    @MainActor
    func testGivingUpALeaseOnTheMainThreadDeletesTheCopyElsewhereAndWithoutHoldingUpOtherCalls() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let mic = folder.appendingPathComponent("mic.m4a")
        /// Each deletion: the file, whether it ran on the main thread, and whether another call to the renders could go on meanwhile.
        final class Deletions: @unchecked Sendable {
            let lock = NSLock()
            var renders: VoiceCleanupRenders?
            var seen: [(file: URL, onMain: Bool, othersGoOn: Bool)] = []
        }
        let deletions = Deletions()
        let renders = VoiceCleanupRenders(render: { microphone, settings in
            let made = VoiceCleanupCache.file(for: microphone, settings: settings)
            try Data().write(to: made)
            return (made, VoiceCleanupReport())
        }, remove: { file in
            let done = DispatchSemaphore(value: 0)
            Thread.detachNewThread {
                deletions.lock.withLock { deletions.renders }?.cancel(mic)
                done.signal()
            }
            let othersGoOn = done.wait(timeout: .now() + 1) == .success
            deletions.lock.withLock { deletions.seen.append((file, Thread.isMainThread, othersGoOn)) }
            try? FileManager.default.removeItem(at: file)
        })
        deletions.lock.withLock { deletions.renders = renders }

        let lease = renders.lease(mic, settings: lowCut(100))
        let exported = try await renders.cleaned(mic, settings: lowCut(100), keep: true).url
        _ = try await renders.cleaned(mic, settings: lowCut(120))
        renders.release(lease)
        await renders.removed()
        let seen = deletions.lock.withLock { deletions.seen }
        XCTAssertEqual(seen.map(\.file.lastPathComponent), [exported.lastPathComponent], "the released copy goes")
        XCTAssertEqual(seen.first?.onMain, false, "deleting it never stalls the editor")
        XCTAssertEqual(seen.first?.othersGoOn, true, "nor holds up a preview or export asking for a copy meanwhile")
    }

    func testARenderLeavesTheCleanedCopiesOfAnotherMicrophoneInTheFolder() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let mic = folder.appendingPathComponent("mic.m4a"), other = folder.appendingPathComponent("mic-2.m4a")
        try TestSound.write(mic, seconds: 1, channels: [[(1_000, 0.3)]])
        try TestSound.write(other, seconds: 1, channels: [[(1_000, 0.3)]])
        let renders = VoiceCleanupRenders()

        let theOthers = try await renders.cleaned(other, settings: lowCut(100)).url
        _ = try await renders.cleaned(mic, settings: lowCut(120))
        XCTAssertTrue(FileManager.default.fileExists(atPath: theOthers.path), "a render for one microphone removes only its own copies")
    }

    func testARenderRemovesHalfWrittenCopiesNoRenderIsWriting() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let mic = folder.appendingPathComponent("mic.m4a")
        try TestSound.write(mic, seconds: 1, channels: [[(1_000, 0.3)]])
        // Left by a render that never finished, such as when the app quit part way.
        let leftover = folder.appendingPathComponent(".\(VoiceCleanupCache.prefix)mic-\(UUID().uuidString).m4a")
        try Data([1, 2, 3]).write(to: leftover)

        let made = try await VoiceCleanupRenders().cleaned(mic, settings: lowCut(100)).url
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: folder.path)), ["mic.m4a", made.lastPathComponent])
    }

    private func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("renders-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    func testANewerRequestStopsTheRenderInFlight() async throws {
        let held = HeldRender()
        let renders = VoiceCleanupRenders(render: held.render)
        let superseded = renders.request(microphone, settings: lowCut(100))
        try await held.waitUntilStarted(1)
        _ = renders.request(microphone, settings: lowCut(120))
        held.releaseLater()

        let isStopped = await isCancelled(superseded)
        XCTAssertTrue(isStopped, "the superseded request ends without a file")
        XCTAssertEqual(held.stopped, [100], "and its render stops instead of running to the end")
    }

    func testACancelledRenderLeavesNoHalfWrittenFile() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let mic = folder.appendingPathComponent("mic.m4a")
        try TestSound.write(mic, seconds: 1, channels: [[(50, 0.3), (1_000, 0.3)]])
        let settings = lowCut(100)
        // Cancelled before it starts, the render stops at its first chunk, once the file it writes is already there.
        let render = Task.detached { () throws -> VoiceCleanupRenders.Cleaned in
            withUnsafeCurrentTask { $0?.cancel() }
            return try VoiceCleanupCache.prepare(mic, settings: settings)
        }
        let isStopped = await isCancelled(render)
        XCTAssertTrue(isStopped, "a cancelled render stops instead of finishing")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["mic.m4a"], "and leaves nothing half-written behind")
    }

    func testTurningCleanupOffStopsThePreviewsRenderButNotAnExports() async throws {
        let held = HeldRender()
        let renders = VoiceCleanupRenders(render: held.render)
        let preview = renders.request(microphone, settings: lowCut(100))
        try await held.waitUntilStarted(1)
        renders.cancel(microphone)
        held.releaseLater()
        let previewStopped = await isCancelled(preview)
        XCTAssertTrue(previewStopped, "nobody wants the sound the preview asked for any more")

        let export = renders.request(microphone, settings: lowCut(120), keep: true)
        try await held.waitUntilStarted(2)
        renders.cancel(microphone)
        held.release()
        let exported = try await export.value.url
        XCTAssertEqual(exported.lastPathComponent, "clean-120.m4a", "the export still gets its sound")
    }

    func testCancellingAnExportStopsTheRenderItWaitsFor() async throws {
        let held = HeldRender()
        let renders = VoiceCleanupRenders(render: held.render)
        let export = Task { try await renders.cleaned(microphone, settings: lowCut(100), keep: true) }
        try await held.waitUntilStarted(1)
        export.cancel()
        held.releaseLater()

        let isStopped = await isCancelled(export)
        XCTAssertTrue(isStopped, "the cancelled export stops waiting")
        XCTAssertEqual(held.stopped, [100], "and the render nobody else waits for stops too")
    }

    func testCancellingAnExportStopsItsRenderAfterAPreviewAskedForOtherSettings() async throws {
        let held = HeldRender()
        let renders = VoiceCleanupRenders(render: held.render)
        let export = Task { try await renders.cleaned(microphone, settings: lowCut(100), keep: true) }
        try await held.waitUntilStarted(1)
        // Queued after the export's render, which it may not cancel.
        let preview = renders.request(microphone, settings: lowCut(120))
        export.cancel()
        held.releaseLater()

        let isStopped = await isCancelled(export)
        XCTAssertTrue(isStopped, "the cancelled export stops waiting")
        XCTAssertEqual(held.stopped.first, 100, "and the render nobody waits for any more stops, though the preview's came after it")
        held.release()
        let previewed = try await preview.value.url
        XCTAssertEqual(previewed.lastPathComponent, "clean-120.m4a", "the preview still gets its sound")
    }

    func testExportingAgainRightAfterCancellingAnExportGetsTheSound() async throws {
        let held = HeldRender()
        let renders = VoiceCleanupRenders(render: held.render)
        let export = Task { try await renders.cleaned(microphone, settings: lowCut(100), keep: true) }
        try await held.waitUntilStarted(1)
        try await Task.sleep(nanoseconds: 20_000_000)
        export.cancel()
        // The cancelled render has not stopped yet when the export is asked for again.
        let again = renders.request(microphone, settings: lowCut(100), keep: true)
        held.release()

        let exported = try await again.value.url
        XCTAssertEqual(exported.lastPathComponent, "clean-100.m4a", "the new export does not join the render the cancelled one stopped")
    }

    func testAPreviewWhoseRenderAnExportSupersededGetsItsSoundByAskingAgain() async throws {
        let held = HeldRender()
        let renders = VoiceCleanupRenders(render: held.render)
        let preview = renders.request(microphone, settings: lowCut(100))
        try await held.waitUntilStarted(1)
        let export = renders.request(microphone, settings: lowCut(120), keep: true)
        let previewStopped = await isCancelled(preview)
        XCTAssertTrue(previewStopped, "the export's settings win")

        let again = renders.request(microphone, settings: lowCut(100))
        try await held.waitUntilStarted(2)
        held.release()
        let exported = try await export.value.url, previewed = try await again.value.url
        XCTAssertEqual(exported.lastPathComponent, "clean-120.m4a", "the export is not cancelled by the preview asking again")
        XCTAssertEqual(previewed.lastPathComponent, "clean-100.m4a", "and the preview gets its sound after it")
        XCTAssertEqual(held.started, [100, 120, 100])
    }
}
