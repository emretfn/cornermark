import AppKit
import CornermarkCapture

/// Events delivered through `window.sendEvent`, the entry real input uses.
@MainActor
private enum Pointer {
    private static var serial = 0

    static func event(_ type: NSEvent.EventType, at global: CGPoint, in window: NSWindow) -> NSEvent {
        serial += 1
        return NSEvent.mouseEvent(with: type, location: window.convertPoint(fromScreen: global), modifierFlags: [],
                                  timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                                  eventNumber: serial, clickCount: 1, pressure: 1)!
    }

    static func drag(_ window: NSWindow, from a: CGPoint, to b: CGPoint) {
        window.sendEvent(event(.mouseMoved, at: a, in: window))
        window.sendEvent(event(.leftMouseDown, at: a, in: window))
        for i in 1...8 {
            let t = CGFloat(i) / 8
            window.sendEvent(event(.leftMouseDragged, at: CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t), in: window))
        }
        window.sendEvent(event(.leftMouseUp, at: b, in: window))
    }
}

/// Top-left desktop points to the global AppKit rect the overlay works in.
func globalRect(fromTopLeft r: CGRect) -> CGRect {
    CGRect(x: r.minX, y: SampleScene.desktopSize.height - r.maxY, width: r.width, height: r.height)
}

@MainActor
func captureShot() async throws -> CGImage {
    let display = DisplaySnapshot(displayID: 1, frame: CGRect(origin: .zero, size: SampleScene.desktopSize), scale: 2, image: SampleScene.desktop())
    let controller = CaptureController(source: FixtureScreenSource(displays: [display]), presentation: .offscreen)
    controller.settleDelay = 0
    controller.pointerLocation = { CGPoint(x: 560, y: 450) }
    controller.begin(.allInOne) { _ in }
    let shown = await waitUntil { !controller.overlayWindows.isEmpty }
    guard shown, let window = controller.overlayWindows.first else { throw ShotError("overlay never appeared") }
    defer { controller.cancel() }
    let chart = globalRect(fromTopLeft: Dashboard.chartCard.offsetBy(dx: SampleScene.dashboardFrame.minX, dy: SampleScene.dashboardFrame.minY))
    Pointer.drag(window, from: CGPoint(x: chart.minX, y: chart.maxY), to: CGPoint(x: chart.maxX, y: chart.minY))
    settle(0.2)
    guard let state = controller.overlayState, case .adjusting = state, let content = window.contentView, let shot = image(of: content) else { throw ShotError("overlay did not reach the adjusting state") }
    return shot
}
