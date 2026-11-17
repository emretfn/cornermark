import CornermarkCore
import Foundation

/// Makes cleaned Microphone tracks one at a time per recorded file, so preview and export never render the same sound twice. A
/// request for the settings already being rendered waits for that render. A request for other settings supersedes it, unless an export
/// waits for it: the export then gets its sound and the new render starts after it. A finished render removes the copies made for other
/// settings, except the ones leased by an export or the preview.
final class VoiceCleanupRenders: @unchecked Sendable {
    typealias Render = @Sendable (URL, VoiceCleanup) throws -> URL

    /// The one the editor and the exporter share.
    static let shared = VoiceCleanupRenders()

    private struct Job {
        let id: Int
        let settings: VoiceCleanup
        let task: Task<URL, Error>
        /// How many exports wait for it. While one does, a newer request must not cancel it.
        var keeps: Int
    }

    private let render: Render
    private let lock = NSLock()
    private var jobs: [URL: Job] = [:]
    private var nextID = 0
    /// How many times each cleaned file is leased.
    private var leases: [URL: Int] = [:]

    /// `render` makes the cleaned file and returns where it is; it should stop with `CancellationError` when its task is cancelled.
    init(render: @escaping Render = { try VoiceCleanupCache.prepare($0, settings: $1) }) { self.render = render }

    /// The cleaned copy of `microphone` for `settings`. `keep` is for an export: no later request cancels the render it waits for.
    /// A superseded request ends with `CancellationError`.
    func request(_ microphone: URL, settings: VoiceCleanup, keep: Bool = false) -> Task<URL, Error> {
        job(microphone, settings: settings, keep: keep).task
    }

    /// Waits for the cleaned copy, rendering it when no render for these settings is under way. Cancelled, it stops waiting at once,
    /// and the render stops too unless an export still waits for it.
    func cleaned(_ microphone: URL, settings: VoiceCleanup, keep: Bool = false) async throws -> URL {
        let job = job(microphone, settings: settings, keep: keep)
        let cleaned = try await withTaskCancellationHandler {
            try await job.task.value
        } onCancel: { [weak self] in
            self?.drop(microphone, id: job.id, keep: keep)
        }
        // A render that finished as the wait was cancelled still hands its file back; the cancelled caller does not take it.
        try Task.checkCancellation()
        return cleaned
    }

    /// Stops the render under way for `microphone`, such as when Voice cleanup is turned off, unless an export waits for it.
    func cancel(_ microphone: URL) {
        lock.withLock {
            guard let job = jobs[microphone], job.keeps == 0 else { return }
            job.task.cancel()
        }
    }

    private func job(_ microphone: URL, settings: VoiceCleanup, keep: Bool) -> (task: Task<URL, Error>, id: Int) {
        var steps = settings
        steps.isOn = true
        lock.lock()
        defer { lock.unlock() }
        if var job = jobs[microphone], job.settings == steps {
            if keep {
                job.keeps += 1
                jobs[microphone] = job
            }
            return (job.task, job.id)
        }
        let previous = jobs[microphone]
        if let previous, previous.keeps == 0 { previous.task.cancel() }
        nextID += 1
        let id = nextID, render = render
        let task = Task.detached(priority: .userInitiated) { [weak self] () throws -> URL in
            defer { self?.finished(microphone, id: id) }
            // One render per file at a time: a cancelled one stops at its next chunk, a kept one runs to its end.
            _ = await previous?.task.result
            try Task.checkCancellation()
            let made = try render(microphone, steps)
            self?.prune(microphone, keeping: made)
            return made
        }
        jobs[microphone] = Job(id: id, settings: steps, task: task, keeps: keep ? 1 : 0)
        return (task, id)
    }

    /// A caller of job `id` stopped waiting. The render stops once no export waits for it.
    private func drop(_ microphone: URL, id: Int, keep: Bool) {
        lock.withLock {
            guard var job = jobs[microphone], job.id == id else { return }
            if keep {
                job.keeps -= 1
                jobs[microphone] = job
            }
            if job.keeps == 0 { job.task.cancel() }
        }
    }

    /// A hold on the cleaned copy of a microphone for some settings: while it is held, a render for other settings does not remove it.
    struct Lease: Hashable {
        let file: URL
    }

    /// Holds the cleaned copy of `microphone` for `settings`, made or not, until `release`. Taken before the copy is asked for, so no
    /// render can remove it between the time it is made and the time it is opened.
    func lease(_ microphone: URL, settings: VoiceCleanup) -> Lease {
        let lease = Lease(file: VoiceCleanupCache.file(for: microphone, settings: settings))
        lock.withLock { leases[lease.file, default: 0] += 1 }
        return lease
    }

    /// Lets the next finished render remove the leased copy, once nobody else holds it.
    func release(_ lease: Lease) {
        lock.withLock {
            guard let count = leases[lease.file] else { return }
            leases[lease.file] = count > 1 ? count - 1 : nil
        }
    }

    /// Removes the copies of `microphone` cleaned for other settings, but `made` and the ones held, so the project keeps one.
    private func prune(_ microphone: URL, keeping made: URL) {
        lock.withLock { VoiceCleanupCache.prune(beside: microphone, keeping: Set(leases.keys).union([made])) }
    }

    private func finished(_ microphone: URL, id: Int) {
        lock.lock()
        defer { lock.unlock() }
        if jobs[microphone]?.id == id { jobs[microphone] = nil }
    }
}
