import CornermarkCore
import Foundation

/// Makes cleaned Microphone tracks one at a time per recorded file, so preview and export never render the same sound twice. A
/// request for the settings already being rendered waits for that render. A request for other settings supersedes it, unless an export
/// waits for it: the export then gets its sound and the new render starts after it.
final class VoiceCleanupRenders: @unchecked Sendable {
    typealias Render = @Sendable (URL, VoiceCleanup) throws -> URL

    /// The one the editor and the exporter share.
    static let shared = VoiceCleanupRenders()

    private struct Job {
        let id: Int
        let settings: VoiceCleanup
        let task: Task<URL, Error>
        /// An export waits for it, so a newer request must not cancel it.
        var kept: Bool
    }

    private let render: Render
    private let lock = NSLock()
    private var jobs: [URL: Job] = [:]
    private var nextID = 0

    /// `render` makes the cleaned file and returns where it is; it should stop with `CancellationError` when its task is cancelled.
    init(render: @escaping Render = { try VoiceCleanupCache.prepare($0, settings: $1) }) { self.render = render }

    /// The cleaned copy of `microphone` for `settings`. `keep` is for an export: no later request cancels the render it waits for.
    /// A superseded request ends with `CancellationError`.
    func request(_ microphone: URL, settings: VoiceCleanup, keep: Bool = false) -> Task<URL, Error> {
        var steps = settings
        steps.isOn = true
        lock.lock()
        defer { lock.unlock() }
        if var job = jobs[microphone], job.settings == steps {
            if keep && !job.kept {
                job.kept = true
                jobs[microphone] = job
            }
            return job.task
        }
        let previous = jobs[microphone]
        if let previous, !previous.kept { previous.task.cancel() }
        nextID += 1
        let id = nextID, render = render
        let task = Task.detached(priority: .userInitiated) { [weak self] () throws -> URL in
            defer { self?.finished(microphone, id: id) }
            // One render per file at a time: a cancelled one stops at its next chunk, a kept one runs to its end.
            _ = await previous?.task.result
            try Task.checkCancellation()
            return try render(microphone, steps)
        }
        jobs[microphone] = Job(id: id, settings: steps, task: task, kept: keep)
        return task
    }

    /// Waits for the cleaned copy, rendering it when no render for these settings is under way.
    func cleaned(_ microphone: URL, settings: VoiceCleanup, keep: Bool = false) async throws -> URL {
        try await request(microphone, settings: settings, keep: keep).value
    }

    private func finished(_ microphone: URL, id: Int) {
        lock.lock()
        defer { lock.unlock() }
        if jobs[microphone]?.id == id { jobs[microphone] = nil }
    }
}
