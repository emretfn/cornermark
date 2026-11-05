import CoreGraphics
import Foundation

/// Where recorded pictures come from: the live screen, or a canned scene in tests.
public protocol FrameSource: AnyObject {
    /// True when pictures arrive at the pace of the screen and cannot wait. False when the source can be held back until the encoder keeps up.
    var deliversInRealTime: Bool { get }
    /// The size the frames will have. Nothing is delivered before `start`.
    func prepare() async throws -> FrameFormat
    /// What the pictures show, in global AppKit points (bottom-left origin). Valid after `prepare`. The pointer track is measured against it.
    var pointArea: CGRect { get }
    /// Frames arrive on a queue of the source's choosing until `stop`.
    func start(_ deliver: @escaping (VideoFrame) -> Void) async throws
    func stop() async
    /// Called once when the source ends by itself, such as when the window closes.
    var onFailure: ((Error) -> Void)? { get set }
}
