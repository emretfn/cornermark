import AppKit
import KadrajDesign

extension CardAction {
    var symbol: String {
        switch self {
        case .copy: return "doc.on.doc"
        case .save: return "square.and.arrow.down"
        case .annotate: return "pencil.tip.crop.circle"
        case .pin: return "pin"
        case .ocr: return "text.viewfinder"
        case .close: return "xmark"
        }
    }

    var title: String {
        switch self {
        case .copy: return "Copy"
        case .save: return "Save"
        case .annotate: return "Annotate"
        case .pin: return "Pin to Screen"
        case .ocr: return "Copy Text (OCR)"
        case .close: return "Close"
        }
    }

    /// The round dark button laid over a thumbnail. Corner actions are small, the rest regular.
    @MainActor
    func makeButton() -> IconButton {
        let button = IconButton(symbol: symbol, label: title, size: self == .close || self == .pin ? .small : .regular, tone: .overlay)
        button.setAccessibilityIdentifier("card.\(String(describing: self))")
        return button
    }
}

/// The thumbnail card. Buttons appear on hover; the whole card drags out as a PNG file.
final class QuickAccessCardView: NSView, NSDraggingSource {
    private let card: QuickAccessCard
    private var size: CGSize
    private let thumbnail: NSImage
    private(set) var buttons: [CardAction: IconButton] = [:]
    private(set) var isHovering = false
    private var mouseDownPoint: CGPoint?
    private var dragging = false
    private var swipeOffset: CGFloat = 0
    private var swipeOrigin: CGPoint?

    var onAction: (CardAction) -> Void = { _ in }
    var onHover: (Bool) -> Void = { _ in }
    var onDragBegan: () -> Void = {}
    var onDragEnded: (Bool) -> Void = { _ in }
    var onSwipeDismiss: () -> Void = {}
    var dragFile: () -> URL? = { nil }
    /// +1 when the card's screen edge is on the right, -1 on the left.
    var swipeDirection: () -> CGFloat = { 1 }

    override var isFlipped: Bool { true }

    init(card: QuickAccessCard, size: CGSize) {
        self.card = card
        self.size = size
        thumbnail = NSImage(cgImage: card.thumbnail, size: NSSize(width: card.thumbnail.width, height: card.thumbnail.height))
        super.init(frame: CGRect(origin: .zero, size: size))
        wantsLayer = true
        setAccessibilityIdentifier("quickaccess.card")
        for action in CardAction.allCases {
            let b = action.makeButton()
            b.target = self
            b.action = #selector(buttonPressed(_:))
            b.isHidden = true
            addSubview(b)
            buttons[action] = b
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    func setCardSize(_ newSize: CGSize) {
        size = newSize
        setFrameSize(newSize)
        needsLayout = true
        needsDisplay = true
    }

    // MARK: Drawing

    /// Room under the image for the readout: gap, one text line, bottom padding.
    private static let footerHeight = DS.Space.s6 + DS.Text.readout.lineHeight + DS.Space.s8

    private var imageArea: NSRect {
        let pad = DS.Space.s8
        return NSRect(x: pad, y: pad, width: bounds.width - 2 * pad, height: bounds.height - pad - Self.footerHeight)
    }

    private var thumbnailRect: NSRect {
        let area = imageArea, s = thumbnail.size
        let scale = min(area.width / s.width, area.height / s.height)
        let w = s.width * scale, h = s.height * scale
        return NSRect(x: area.midX - w / 2, y: area.midY - h / 2, width: w, height: h)
    }

    override func draw(_ dirtyRect: NSRect) {
        let chrome = NSBezierPath.continuous(bounds, radius: DS.Radius.xl)
        DS.Color.bgSurface.setFill()
        chrome.fill()
        strokeInside(chrome, DS.Color.borderSubtle)

        // The picture sits in a well, so a capture whose proportions differ from the card's reads as letterboxed, not as empty space.
        ImageWell.draw(card.thumbnail, in: imageArea)
        if isHovering {
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath.continuous(imageArea, radius: DS.Radius.md).addClip()
            DS.Color.bgScrim.setFill()
            imageArea.fill()
            NSGraphicsContext.restoreGraphicsState()
        }

        let line = NSRect(x: DS.Space.s12, y: imageArea.maxY + DS.Space.s6, width: bounds.width - 2 * DS.Space.s12, height: DS.Text.readout.lineHeight)
        NSAttributedString(string: card.info, attributes: DS.Text.readout.attributes(color: DS.Color.textSecondary))
            .draw(with: line, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    /// A 1pt line that stays inside the path, so the shape keeps its size.
    private func strokeInside(_ path: NSBezierPath, _ color: NSColor) {
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        color.setStroke()
        path.lineWidth = 2
        path.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }

    override func layout() {
        super.layout()
        let area = imageArea
        let pad = DS.Space.s6
        let corner = DS.Size.controlSmall
        buttons[.close]?.frame = NSRect(x: area.minX + pad, y: area.minY + pad, width: corner, height: corner)
        buttons[.pin]?.frame = NSRect(x: area.maxX - pad - corner, y: area.minY + pad, width: corner, height: corner)
        let middle: [CardAction] = [.copy, .save, .annotate, .ocr]
        let d = bounds.width < 190 ? DS.Size.controlSmall : DS.Size.control
        let gap = DS.Space.s8
        let total = CGFloat(middle.count) * d + CGFloat(middle.count - 1) * gap
        var x = area.midX - total / 2
        // Centred unless a wide, short image would make the row hit the corner buttons; then only as low as it takes.
        var y = area.midY - d / 2
        if x < area.minX + pad + corner { y = min(max(y, area.minY + pad + corner + DS.Space.s2), area.maxY - d) }
        for a in middle {
            buttons[a]?.frame = NSRect(x: x, y: y, width: d, height: d)
            x += d + gap
        }
    }

    // MARK: Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { setHovering(true) }
    override func mouseExited(with event: NSEvent) { setHovering(false) }

    func setHovering(_ hovering: Bool) {
        guard hovering != isHovering else { return }
        isHovering = hovering
        buttons.values.forEach { $0.isHidden = !hovering }
        needsDisplay = true
        onHover(hovering)
    }

    @objc private func buttonPressed(_ sender: IconButton) {
        if let action = buttons.first(where: { $0.value === sender })?.key { onAction(action) }
    }

    // MARK: Mouse, drag, swipe

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = event.locationInWindow
        dragging = false
        if event.clickCount == 2 { onAction(.annotate) }
    }

    override func mouseDragged(with event: NSEvent) {
        guard !dragging, let start = mouseDownPoint else { return }
        guard hypot(event.locationInWindow.x - start.x, event.locationInWindow.y - start.y) > 4 else { return }
        dragging = true
        beginFileDrag(with: event)
    }

    override func mouseUp(with event: NSEvent) { mouseDownPoint = nil }

    /// The dragged item is a file URL, which Finder, Mail, Slack and browsers all take.
    func dragItem() -> NSDraggingItem? {
        guard let url = dragFile() else { return nil }
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        item.setDraggingFrame(thumbnailRect, contents: thumbnail)
        return item
    }

    private func beginFileDrag(with event: NSEvent) {
        guard let item = dragItem() else { return }
        onDragBegan()
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        dragging = false
        onDragEnded(operation != [])
    }

    override func scrollWheel(with event: NSEvent) {
        guard event.hasPreciseScrollingDeltas else { return super.scrollWheel(with: event) }
        let fingerDX = event.isDirectionInvertedFromDevice ? event.scrollingDeltaX : -event.scrollingDeltaX
        let ended = event.phase.contains(.ended) || event.phase.contains(.cancelled)
        swipe(dx: fingerDX, dy: event.scrollingDeltaY, ended: ended)
    }

    /// Two-finger swipe toward the screen edge slides the card away; letting go early springs it back.
    func swipe(dx: CGFloat, dy: CGFloat, ended: Bool) {
        guard let window else { return }
        if swipeOrigin == nil {
            guard abs(dx) > abs(dy) else { return }
            swipeOrigin = window.frame.origin
        }
        let toward = swipeDirection()
        swipeOffset = max(0, swipeOffset + dx * toward)
        window.setFrameOrigin(CGPoint(x: swipeOrigin!.x + swipeOffset * toward, y: swipeOrigin!.y))
        window.alphaValue = max(0.2, 1 - swipeOffset / (bounds.width * 1.4))
        guard ended else { return }
        let origin = swipeOrigin!, offset = swipeOffset
        swipeOrigin = nil
        swipeOffset = 0
        if offset > bounds.width * 0.4 {
            onSwipeDismiss()
        } else {
            window.alphaValue = 1
            if window.isVisible && !DS.Motion.isReduced {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = DS.Motion.Duration.base
                    ctx.timingFunction = DS.Motion.Curve.easeOut
                    window.animator().setFrameOrigin(origin)
                }
            } else {
                window.setFrameOrigin(origin)
            }
        }
    }
}
