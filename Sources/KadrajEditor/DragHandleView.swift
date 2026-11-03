import AppKit
import KadrajDesign

/// The drag grip: dragging it hands a rendered PNG file to Finder, Mail, a browser or anything else that takes files.
final class DragHandleView: NSView, NSDraggingSource {
    /// Writes the current render to a file and returns it, plus a preview for the drag image.
    var provider: () -> (url: URL, preview: NSImage)? = { nil }
    var onDragBegan: () -> Void = {}
    var onDragEnded: (_ dropped: Bool) -> Void = { _ in }
    var onEscape: () -> Void = {}
    private var pressed: NSEvent?
    private var phase = DragPhase.idle
    private var dragPasteboard: NSPasteboard?
    private var session: NSDraggingSession?
    private var escapeWatch: Timer?

    private enum DragPhase { case idle, dragging, escaped }

    override var intrinsicContentSize: NSSize { NSSize(width: DS.Size.control, height: DS.Size.control) }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath.continuous(bounds.insetBy(dx: 0.5, dy: 0.5), radius: DS.Radius.sm)
        DS.Color.bgControl.setFill()
        path.fill()
        DS.Color.border.setStroke()
        path.stroke()
        Glyph.draw("hand.draw", in: bounds, DS.Color.textSecondary)
    }

    // The handle sits in the title bar, where a plain view's default would turn the press into moving the window.
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    override func mouseDown(with event: NSEvent) { pressed = event }

    override func mouseDragged(with event: NSEvent) {
        guard let start = pressed, hypot(event.locationInWindow.x - start.locationInWindow.x,
                                         event.locationInWindow.y - start.locationInWindow.y) > 3,
              let payload = provider() else { return }
        pressed = nil
        let item = NSDraggingItem(pasteboardWriter: payload.url as NSURL)
        let size = payload.preview.size
        let scale = min(1, 220 / max(size.width, 1), 160 / max(size.height, 1))
        let width = size.width * scale, height = size.height * scale
        let grab = convert(start.locationInWindow, from: nil)
        let frame = NSRect(x: grab.x - width / 2, y: grab.y - height / 2, width: width, height: height)
        item.setDraggingFrame(frame, contents: payload.preview)
        beginDraggingSession(with: [item], event: start, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        phase == .escaped ? [] : .copy
    }

    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        phase = .dragging
        dragPasteboard = session.draggingPasteboard
        self.session = session
        onDragBegan()
        watchForEscape()
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        escapeWatch?.invalidate()
        escapeWatch = nil
        phase = .idle
        dragPasteboard = nil
        self.session = nil
        onDragEnded(operation != [])
    }

    /// Once the editor is off screen another app has the keyboard, so Esc never reaches this drag and has to be read from the
    /// key state. AppKit has no call to end a session, so an escaped drag empties its pasteboard and ends at mouse-up with nothing
    /// to drop. The operation mask alone is not enough, because a target such as the canvas may not consult it.
    private func watchForEscape() {
        let escape: CGKeyCode = 53
        var wasDown = CGEventSource.keyState(.combinedSessionState, key: escape)
        let watch = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            let down = CGEventSource.keyState(.combinedSessionState, key: escape)
            defer { wasDown = down }
            if down && !wasDown { self?.escape() }
        }
        RunLoop.main.add(watch, forMode: .common)
        escapeWatch = watch
    }

    func escape() {
        guard phase == .dragging else { return }
        phase = .escaped
        hideDragImage()
        dragPasteboard?.clearContents()
        onEscape()
    }

    /// Runs before the pasteboard is emptied, because the enumeration finds items by what the pasteboard holds.
    private func hideDragImage() {
        guard let session else { return }
        session.animatesToStartingPositionsOnCancelOrFail = false
        let nothing = NSImage(size: NSSize(width: 1, height: 1))
        session.enumerateDraggingItems(options: [], for: nil, classes: [NSURL.self], searchOptions: [:]) { item, _, _ in
            item.setDraggingFrame(NSRect(origin: item.draggingFrame.origin, size: NSSize(width: 1, height: 1)), contents: nothing)
        }
    }

    func beginPhaseForTesting(pasteboard: NSPasteboard) {
        phase = .dragging
        dragPasteboard = pasteboard
    }

    var refusesDrops: Bool { phase == .escaped }
}
