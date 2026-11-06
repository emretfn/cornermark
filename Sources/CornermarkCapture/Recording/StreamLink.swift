import Foundation

/// What a live stream shares between the queue its frames arrive on, the task that stops it, and the thread that hears it fail.
/// Every read and write goes through one lock, and `send` calls the recorder with that lock held. `close` therefore waits for a
/// frame already on its way and no frame reaches the recorder after it returns. The recorder's handler must not call `close`.
public final class StreamLink<Stream> {
    private let lock = NSLock()
    private var deliver: ((VideoFrame) -> Void)?
    private var stream: Stream?

    public init() {}

    public func open(_ deliver: @escaping (VideoFrame) -> Void) { lock.withLock { self.deliver = deliver } }

    /// Remembers the running stream. `close` and `fail` hand it back once between them.
    public func attach(_ stream: Stream) { lock.withLock { self.stream = stream } }

    public func send(_ frame: VideoFrame) { lock.withLock { deliver?(frame) } }

    /// Ends the hand-off for good. Returns the stream if it was still running, so only the caller that gets it stops it.
    public func close() -> Stream? {
        lock.withLock {
            deliver = nil
            defer { stream = nil }
            return stream
        }
    }

    /// The stream ended by itself. Returns it if it was still running, so the failure is reported once and never after `close`.
    public func fail() -> Stream? {
        lock.withLock {
            defer { stream = nil }
            return stream
        }
    }
}
