import CoreGraphics
import CornermarkCore
import XCTest
@testable import CornermarkVideoEditor

/// A player that takes a new Microphone file when the test says, and says whether it took over.
@MainActor
private final class Player: SourceFrames {
    var hasAudio = true
    var volume: Float = 1
    /// While true, every new file waits for `answer`; else it takes over at once.
    var holds = false
    private var waiting: [(file: URL, answer: CheckedContinuation<Bool, Never>)] = []
    private(set) var given: [URL] = []

    func follow(sourceTime: Double, playing: Bool, now: Double) {}
    func frame(at sourceTime: Double) -> CGImage? { nil }
    func load() async {}

    func setSound(_ file: URL, for track: AudioTrack) async -> Bool {
        given.append(file)
        guard holds else { return true }
        return await withCheckedContinuation { waiting.append((file, $0)) }
    }

    func answer(_ name: String, tookOver: Bool) {
        guard let i = waiting.firstIndex(where: { $0.file.lastPathComponent == name }) else { return XCTFail("\(name) was never given") }
        waiting.remove(at: i).answer.resume(returning: tookOver)
    }

    func waitUntilGiven(_ name: String) async {
        for _ in 0..<2_000 where !given.contains(where: { $0.lastPathComponent == name }) { try? await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertTrue(given.contains { $0.lastPathComponent == name }, "\(name) went to the player")
    }
}

/// Renders that answer at once with a file named after the Low cut frequency, or as the test says.
private final class Renders: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var stops = 0
    var calls: Int { lock.withLock { count } }
    var stopped: Int { lock.withLock { stops } }
    /// Each render's answer, in turn; past the end, a file named after the frequency.
    var answers: [Result<VoiceCleanupReport, Error>] = []
    /// While true, a render runs until it is cancelled.
    var runsUntilCancelled = false

    func render(_ microphone: URL, settings: VoiceCleanup) throws -> VoiceCleanupRenders.Cleaned {
        let answer: Result<VoiceCleanupReport, Error> = lock.withLock {
            count += 1
            return count <= answers.count ? answers[count - 1] : .success(VoiceCleanupReport())
        }
        if runsUntilCancelled {
            for _ in 0..<2_000 where !Task.isCancelled { usleep(1_000) }
            lock.withLock { stops += Task.isCancelled ? 1 : 0 }
            throw CancellationError()
        }
        return (URL(fileURLWithPath: "/tmp/clean-\(Int(settings.lowCutFrequency)).m4a"), try answer.get())
    }
}

@MainActor
final class PreviewMicrophoneTests: XCTestCase {
    private var folder: URL!
    private var recorded: URL!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("preview-microphone-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        recorded = folder.appendingPathComponent("mic.m4a")
        try Data().write(to: recorded)
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: folder) }

    private func lowCut(_ frequency: Double) -> VoiceCleanup {
        var settings = VoiceCleanup(isOn: true)
        settings.lowCutFrequency = frequency
        return settings
    }

    private func microphone(_ player: Player, _ renders: Renders) -> PreviewMicrophone {
        PreviewMicrophone(recorded: recorded, playing: recorded, frames: player, renders: VoiceCleanupRenders(render: renders.render))
    }

    func testWhenNeitherOfTwoNewFilesTakesOverTheFileThatPlaysStaysTheOneShown() async throws {
        let player = Player(), renders = Renders()
        player.holds = true
        let microphone = microphone(player, renders)
        microphone.update(lowCut(100))
        await player.waitUntilGiven("clean-100.m4a")
        microphone.update(lowCut(120))
        await player.waitUntilGiven("clean-120.m4a")

        player.answer("clean-100.m4a", tookOver: false)
        try await Task.sleep(nanoseconds: 20_000_000)
        player.answer("clean-120.m4a", tookOver: false)
        await microphone.prepared()
        XCTAssertEqual(microphone.file, recorded, "the recorded file still plays, not the copy that never took over")
    }

    func testARenderThatFailedIsTriedAgainOnTheNextUpdate() async throws {
        let player = Player(), renders = Renders()
        renders.answers = [.failure(CocoaError(.fileWriteUnknown))]
        let microphone = microphone(player, renders)
        microphone.update(lowCut(100))
        await microphone.prepared()
        XCTAssertEqual(microphone.file, recorded, "the failed render leaves the recorded sound playing")
        XCTAssertFalse(microphone.isPreparing)

        microphone.update(lowCut(100))
        await microphone.prepared()
        XCTAssertEqual(renders.calls, 2, "the same settings render again")
        XCTAssertEqual(microphone.file?.lastPathComponent, "clean-100.m4a")
    }

    func testARenderThatFailedGivesUpItsHoldOnTheCopiesItAskedFor() async throws {
        let player = Player()
        let renders = VoiceCleanupRenders { microphone, settings in
            guard settings.lowCutFrequency == 100 else { throw CocoaError(.fileWriteUnknown) }
            let made = VoiceCleanupCache.file(for: microphone, settings: settings)
            try Data().write(to: made)
            return (made, VoiceCleanupReport())
        }
        let microphone = PreviewMicrophone(recorded: recorded, playing: recorded, frames: player, renders: renders)
        microphone.update(lowCut(100))
        await microphone.prepared()
        // Left by an earlier render on a Mac whose Noise removal could not run: the copy the failing settings would play there.
        var without = lowCut(120)
        without.noiseRemovalOn = false
        let leftover = VoiceCleanupCache.file(for: recorded, settings: without)
        try Data().write(to: leftover)

        microphone.update(lowCut(120))
        await microphone.prepared()
        XCTAssertFalse(FileManager.default.fileExists(atPath: leftover.path), "the failed render no longer holds the copy, so it goes")
        XCTAssertEqual(microphone.file, VoiceCleanupCache.file(for: recorded, settings: lowCut(100)), "the previous sound plays on")
    }

    func testARenderThatCouldNotRunNoiseRemovalSaysSo() async throws {
        let player = Player(), renders = Renders()
        renders.answers = [.success(VoiceCleanupReport(noiseRemovalUnavailable: true))]
        let microphone = microphone(player, renders)
        var unavailable = false
        microphone.onNoiseRemovalUnavailable = { unavailable = true }
        microphone.update(lowCut(100))
        await microphone.prepared()
        XCTAssertTrue(unavailable, "the panel can grey Noise removal out after a preview render, not only after an export")
    }

    func testClosingStopsTheRenderThePreviewWaitsFor() async throws {
        let player = Player(), renders = Renders()
        renders.runsUntilCancelled = true
        let microphone = microphone(player, renders)
        microphone.update(lowCut(100))
        for _ in 0..<2_000 where renders.calls == 0 { try await Task.sleep(nanoseconds: 1_000_000) }
        microphone.close()
        for _ in 0..<500 where renders.stopped == 0 { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertEqual(renders.stopped, 1, "nobody wants the sound once the editor closed")
    }
}
