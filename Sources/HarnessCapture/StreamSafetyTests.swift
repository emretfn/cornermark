import CoreVideo
import CornermarkCapture
import CoreMedia
import Foundation

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    var value: Int { lock.withLock { n } }
    func bump() { lock.withLock { n += 1 } }
}

private func pixel() -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    CVPixelBufferCreate(kCFAllocatorDefault, 2, 2, kCVPixelFormatType_32BGRA, nil, &buffer)
    return buffer!
}

@MainActor
func runStreamSafetyTests() async {
    section("the live stream's frame hand-off")
    let frame = VideoFrame(pixels: pixel(), time: .zero)
    let iterations = 3000

    var leaked = 0
    var hung = 0
    for _ in 0..<iterations {
        let link = StreamLink<Int>()
        let delivered = Counter()
        link.open { _ in
            for _ in 0..<50 { _ = delivered.value }
            delivered.bump()
        }
        link.attach(1)
        let running = Counter()
        let finished = DispatchGroup()
        finished.enter()
        DispatchQueue.global(qos: .userInteractive).async {
            while running.value == 0 { link.send(frame) }
            finished.leave()
        }
        while delivered.value < 3 { usleep(5) }
        let stopped = DispatchSemaphore(value: 0)
        var atStop = 0
        DispatchQueue.global().async {
            _ = link.close()
            atStop = delivered.value
            stopped.signal()
        }
        if stopped.wait(timeout: .now() + 5) == .timedOut { hung += 1; running.bump(); finished.wait(); continue }
        running.bump()
        finished.wait()
        if delivered.value != atStop { leaked += 1 }
    }
    check(hung == 0, "stopping while frames arrive never deadlocks", detail: "\(hung) of \(iterations)")
    check(leaked == 0, "no frame reaches the recorder after stop returns", detail: "\(leaked) of \(iterations) runs delivered one afterwards")

    var winners = [Int](repeating: 0, count: 3)
    var reportedAfterStop = 0
    for _ in 0..<iterations {
        let link = StreamLink<Int>()
        link.open { _ in }
        link.attach(7)
        let results = Counter()
        let stops = Counter()
        let both = DispatchGroup()
        for isStop in [true, false] {
            both.enter()
            DispatchQueue.global(qos: .userInteractive).async {
                if (isStop ? link.close() : link.fail()) != nil { results.bump() }
                if isStop { stops.bump() }
                both.leave()
            }
        }
        both.wait()
        winners[min(results.value, 2)] += 1
        link.send(frame)
        if link.fail() != nil { reportedAfterStop += 1 }
    }
    check(winners == [0, iterations, 0], "stop racing with the stream's own error hands the stream to exactly one of them", detail: "\(winners)")
    check(reportedAfterStop == 0, "an error that comes after stop is not reported as a failure", detail: "\(reportedAfterStop)")

    let late = StreamLink<Int>()
    let lateFrames = Counter()
    late.open { _ in lateFrames.bump() }
    late.send(frame)
    _ = late.close()
    late.send(frame)
    check(lateFrames.value == 1, "a frame sent after stop is dropped", detail: "\(lateFrames.value)")

    section("the exclusion list while recording")
    let me: pid_t = 99
    let center = ContentExclusion.App(pid: 10, bundleID: ContentExclusion.notificationCenter)
    let editor = ContentExclusion.App(pid: 12, bundleID: "local.test.editor")
    let finder = ContentExclusion.App(pid: 11, bundleID: ContentExclusion.finder)

    check(ContentExclusion().needsRefresh, "by default the list is looked at again, because notifications are hidden")
    check(ContentExclusion(hidesNotifications: false, hidesDesktopIcons: true).needsRefresh, "and with only desktop icons hidden")
    check(!ContentExclusion(hidesNotifications: false, hidesDesktopIcons: false).needsRefresh, "but not when nothing is hidden")

    let exclusion = ContentExclusion()
    var tracker = ExclusionTracker(exclusion: exclusion, plan: exclusion.plan(apps: [editor], windows: [], ownPID: me), ownPID: me)
    check(tracker.plan.excludedApps == [me], "Notification Center was not listed when the recording began, so only Cornermark is left out", detail: "\(tracker.plan)")
    check(tracker.observe(apps: [editor], windows: []) == nil, "a look that finds the same applications changes nothing")
    check(tracker.observe(apps: [editor, ContentExclusion.App(pid: 13, bundleID: "local.test.other")], windows: [.init(id: 5, ownerPID: 13, layer: 0)]) == nil,
          "an unrelated application and window do not change the plan")
    let joined = tracker.observe(apps: [editor, center], windows: [.init(id: 1, ownerPID: 10, layer: 23)])
    check(joined?.excludedApps == [me, 10], "Notification Center appearing mid-recording joins the exclusion list", detail: "\(String(describing: joined))")
    check(joined.map { !$0.films(.init(id: 1, ownerPID: 10, layer: 23)) } == true, "so its banner is out of the picture")
    check(tracker.observe(apps: [editor, center], windows: [.init(id: 2, ownerPID: 10, layer: 23)]) == nil, "a second banner from the same process needs no new filter")
    check(tracker.observe(apps: [editor, ContentExclusion.App(pid: 20, bundleID: ContentExclusion.notificationCenter)], windows: [])?.excludedApps == [me, 20],
          "a restarted Notification Center under a new process is followed")

    let icons = ContentExclusion(hidesNotifications: true, hidesDesktopIcons: true)
    var withIcons = ExclusionTracker(exclusion: icons, plan: icons.plan(apps: [finder, center], windows: [], ownPID: me), ownPID: me)
    check(withIcons.observe(apps: [finder, center], windows: []) == nil, "with icons hidden nothing changed, so nothing is replaced")
    check(withIcons.observe(apps: [finder, center], windows: [.init(id: 30, ownerPID: 11, layer: 0)])?.exceptedWindows == [30], "a Finder window opened mid-recording is filmed")
}
