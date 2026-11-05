import AppKit

// focus-probe <pid> <seconds>: one JSON line. Reads window metadata and the frontmost PID only, never pixels.
let pid = pid_t(CommandLine.arguments[1])!
let end = Date().addingTimeInterval(Double(CommandLine.arguments[2])!)
var samples = 0, onScreenMax = 0, frontChanges = 0
var frontWasOurs = false
var lastFront: pid_t?

repeat {
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
    if samples > 0, front != lastFront { frontChanges += 1 }
    lastFront = front
    if front == pid { frontWasOurs = true }
    let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    onScreenMax = max(onScreenMax, windows.filter { $0[kCGWindowOwnerPID as String] as? pid_t == pid }.count)
    samples += 1
} while Date() < end

print("{\"pid\":\(pid),\"samples\":\(samples),\"onScreenWindowsMax\":\(onScreenMax),\"frontmostWasOurs\":\(frontWasOurs),\"frontmostChanges\":\(frontChanges)}")
