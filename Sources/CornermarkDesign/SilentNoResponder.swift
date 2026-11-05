#if DEBUG
import AppKit
import ObjectiveC

/// A key or menu action that no responder handles ends in `noResponder(for:)`, which plays the system alert sound. Harnesses and
/// scripted instances run beside a person, so once installed it counts and logs the action instead. A harness fails on any count.
public enum SilentNoResponder {
    public private(set) static var selectors: [String] = []
    public static var count: Int { selectors.count }
    private static var installed = false
    private static var silentIMP: IMP?

    /// True when every responder class a key reaches answers with the silent version, so calling it cannot make a sound.
    public static var isSilent: Bool {
        guard let silentIMP else { return false }
        let selector = #selector(NSResponder.noResponder(for:))
        return ([NSResponder.self, NSView.self, NSWindow.self, NSPanel.self, NSApplication.self] as [AnyClass]).allSatisfy {
            class_getMethodImplementation($0, selector) == silentIMP
        }
    }

    /// Runs `body` and returns the actions it let fall through, without counting them against the run.
    public static func catching(_ body: () -> Void) -> [String] {
        let before = selectors.count
        body()
        let caught = Array(selectors[before...])
        selectors.removeLast(caught.count)
        return caught
    }

    public static func install() {
        guard !installed else { return }
        installed = true
        let selector = #selector(NSResponder.noResponder(for:))
        let silent: @convention(block) (AnyObject, Selector) -> Void = { _, action in
            let name = NSStringFromSelector(action)
            selectors.append(name)
            print("NORESPONDER \(name)")
        }
        let imp = imp_implementationWithBlock(silent)
        silentIMP = imp
        // NSWindow and NSApplication may answer it themselves, so each gets the silent version too.
        for cls in [NSResponder.self, NSWindow.self, NSApplication.self] as [AnyClass] {
            guard let method = class_getInstanceMethod(cls, selector) else { continue }
            class_replaceMethod(cls, selector, imp, method_getTypeEncoding(method))
        }
    }
}
#endif
