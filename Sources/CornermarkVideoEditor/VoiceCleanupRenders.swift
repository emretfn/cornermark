import CornermarkCore
import Foundation

/// Makes cleaned Microphone tracks one at a time per recorded file, so preview and export never render the same sound twice. A
/// request for the settings already being rendered waits for that render. A request for other settings supersedes it, unless an export
/// waits for it: the export then gets its sound and the new render starts after it. A finished render removes the copies made for other
/// settings, except the ones leased by an export or the preview.
final class VoiceCleanupRenders: @unchecked Sendable {
    /// A cleaned copy, and what its render had to leave out.
    typealias Cleaned = (url: URL, report: VoiceCleanupReport)
    typealias Render = @Sendable (URL, VoiceCleanup) throws -> Cleaned

    /// The one the editor and the exporter share.
    static let shared = VoiceCleanupRenders()

    private struct Job {
        let id: Int
        let settings: VoiceCleanup
        let task: Task<Cleaned, Error>
        /// How many exports wait for it. While one does, a newer request must not cancel it.
        var keeps: Int
    }

    private let render: Render
    private let lock = NSLock()
    private var jobs: [URL: Job] = [:]
    private var nextID = 0
    /// How many times each cleaned file is leased.
    private var leases: [URL: Int] = [:]
    /// The copy of each microphone rendered last, which stays when nobody holds it.
    private var latest: [URL: URL] = [:]

    /// `render` makes the cleaned file and returns where it is; it should stop with `CancellationError` when its task is cancelled.
    init(render: @escaping Render = { try VoiceCleanupCache.prepare($0, settings: $1) }) { self.render = render }

    /// The cleaned copy of `microphone` for `settings`. `keep` is for an export: no later request cancels the render it waits for.
    /// A superseded request ends with `CancellationError`.
    func request(_ microphone: URL, settings: VoiceCleanup, keep: Bool = false) -> Task<Cleaned, Error> {
        job(microphone, settings: settings, keep: keep).task
    }

    /// Waits for the cleaned copy, rendering it when no render for these settings is under way. Cancelled, it stops waiting at once,
    /// and the render stops too unless an export still waits for it.
    func cleaned(_ microphone: URL, settings: VoiceCleanup, keep: Bool = false) async throws -> Cleaned {
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

    private func job(_ microphone: URL, settings: VoiceCleanup, keep: Bool) -> (task: Task<Cleaned, Error>, id: Int) {
        let steps = VoiceCleanupCache.sound(of: settings)
        lock.lock()
        defer { lock.unlock() }
        // A render that was stopped but has not ended yet serves nobody: the request starts a new one after it.
        if var job = jobs[microphone], job.settings == steps, !job.task.isCancelled {
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
        let task = Task.detached(priority: .userInitiated) { [weak self] () throws -> Cleaned in
            defer { self?.finished(microphone, id: id) }
            // One render per file at a time: a cancelled one stops at its next chunk, a kept one runs to its end.
            _ = await previous?.task.result
            try Task.checkCancellation()
            let made = try render(microphone, steps)
            self?.prune(microphone, keeping: made.url)
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
        let microphone: URL
        /// The copy's name, and with Noise removal on also the name the copy takes when Noise removal cannot run.
        let files: [URL]
    }

    /// Holds the cleaned copy of `microphone` for `settings`, made or not, until `release`. Taken before the copy is asked for, so no
    /// render can remove it between the time it is made and the time it is opened.
    func lease(_ microphone: URL, settings: VoiceCleanup) -> Lease {
        var without = settings
        without.noiseRemovalOn = false
        let asked = VoiceCleanupCache.file(for: microphone, settings: settings), fallback = VoiceCleanupCache.file(for: microphone, settings: without)
        let lease = Lease(microphone: microphone, files: asked == fallback ? [asked] : [asked, fallback])
        lock.withLock { for file in lease.files { leases[file, default: 0] += 1 } }
        return lease
    }

    /// Gives the leased copy up. Once nobody holds it, it goes if newer settings were rendered since, and else with the next render.
    func release(_ lease: Lease) {
        lock.withLock {
            var freed = false
            for file in lease.files {
                guard let count = leases[file] else { continue }
                leases[file] = count > 1 ? count - 1 : nil
                freed = freed || count == 1
            }
            guard freed, let made = latest[lease.microphone] else { return }
            VoiceCleanupCache.prune(beside: lease.microphone, keeping: Set(leases.keys).union([made]))
        }
    }

    /// Removes the copies of `microphone` cleaned for other settings, but `made` and the ones held, so the project keeps one. Called
    /// as a render ends, when no other render of `microphone` writes, so half-written copies left by one that never finished go too.
    private func prune(_ microphone: URL, keeping made: URL) {
        lock.withLock {
            latest[microphone] = made
            VoiceCleanupCache.prune(beside: microphone, keeping: Set(leases.keys).union([made]), partials: true)
        }
    }

    private func finished(_ microphone: URL, id: Int) {
        lock.lock()
        defer { lock.unlock() }
        if jobs[microphone]?.id == id { jobs[microphone] = nil }
    }
}
