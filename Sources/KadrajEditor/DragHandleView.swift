import AppKit
import KadrajDesign

/// The drag grip: dragging it hands a rendered PNG file to Finder, Mail, a browser or anything else that takes files.
final class DragHandleView: NSView, NSDraggingSource {
    /// Writes the current render to a file and returns it, plus a preview for the drag image.
    var provider: () -> (url: URL, preview: NSImage)? = { nil }
    private var pressed: NSEvent?

    override var intrinsicContentSize: NSSize { NSSize(width: DS.Size.control, height: DS.Size.control) }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath.continuous(bounds.insetBy(dx: 0.5, dy: 0.5), radius: DS.Radius.sm)
        DS.Color.bgControl.setFill()
        path.fill()
        DS.Color.border.setStroke()
        path.stroke()
        Glyph.draw("hand.draw", in: bounds, DS.Color.textSecondary)
    }

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
        let frame = NSRect(x: 0, y: 0, width: size.width * scale, height: size.height * scale)
        item.setDraggingFrame(frame, contents: payload.preview)
        beginDraggingSession(with: [item], event: start, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
}
