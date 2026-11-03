import AppKit

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
}

final class CardButton: NSButton {
    let cardAction: CardAction
    private var hovering = false

    init(_ action: CardAction) {
        cardAction = action
        super.init(frame: .zero)
        isBordered = false
        title = ""
        imagePosition = .imageOnly
        toolTip = action.title
        setAccessibilityLabel(action.title)
        setAccessibilityIdentifier("card.\(String(describing: action))")
        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold).applying(.init(paletteColors: [.white]))
        image = NSImage(systemSymbolName: action.symbol, accessibilityDescription: action.title)?.withSymbolConfiguration(config)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let alpha: CGFloat = isHighlighted ? 0.85 : (hovering ? 0.75 : 0.6)
        NSColor(white: 0, alpha: alpha).setFill()
        NSBezierPath(ovalIn: bounds).fill()
        guard let image else { return }
        let s = image.size
        image.draw(in: NSRect(x: bounds.midX - s.width / 2, y: bounds.midY - s.height / 2, width: s.width, height: s.height))
    }
}

/// The thumbnail card. Buttons appear on hover; the whole card drags out as a PNG file.
final class QuickAccessCardView: NSView, NSDraggingSource {
    private let card: QuickAccessCard
    private var size: CGSize
    private let thumbnail: NSImage
    private(set) var buttons: [CardAction: CardButton] = [:]
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
            let b = CardButton(action)
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

    private var imageArea: NSRect { NSRect(x: 6, y: 6, width: bounds.width - 12, height: bounds.height - 12 - 22) }

    private var thumbnailRect: NSRect {
        let area = imageArea, s = thumbnail.size
        let scale = min(area.width / s.width, area.height / s.height)
        let w = s.width * scale, h = s.height * scale
        return NSRect(x: area.midX - w / 2, y: area.midY - h / 2, width: w, height: h)
    }

    override func draw(_ dirtyRect: NSRect) {
        let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 12, yRadius: 12)
        NSColor.windowBackgroundColor.setFill()
        outline.fill()
        NSColor.separatorColor.setStroke()
        outline.lineWidth = 1
        outline.stroke()

        let r = thumbnailRect
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6).addClip()
        NSGraphicsContext.current?.imageInterpolation = .high
        thumbnail.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        if isHovering {
            NSColor(white: 0, alpha: 0.42).setFill()
            r.fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        NSColor(white: 0.5, alpha: 0.35).setStroke()
        let edge = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        edge.lineWidth = 1
        edge.stroke()

        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
                                                    .foregroundColor: NSColor.secondaryLabelColor]
        card.info.draw(at: NSPoint(x: 10, y: bounds.height - 20), withAttributes: attrs)
    }

    override func layout() {
        super.layout()
        let d: CGFloat = bounds.width < 190 ? 24 : 30
        let area = thumbnailRect
        let pad: CGFloat = 6
        buttons[.close]?.frame = NSRect(x: area.minX + pad, y: area.minY + pad, width: d - 4, height: d - 4)
        buttons[.pin]?.frame = NSRect(x: area.maxX - pad - (d - 4), y: area.minY + pad, width: d - 4, height: d - 4)
        let middle: [CardAction] = [.copy, .save, .annotate, .ocr]
        let gap: CGFloat = 8
        let total = CGFloat(middle.count) * d + CGFloat(middle.count - 1) * gap
        var x = area.midX - total / 2
        for a in middle {
            buttons[a]?.frame = NSRect(x: x, y: area.midY - d / 2 + 6, width: d, height: d)
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

    @objc private func buttonPressed(_ sender: CardButton) { onAction(sender.cardAction) }

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
            if window.isVisible {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.2
                    window.animator().setFrameOrigin(origin)
                }
            } else {
                window.setFrameOrigin(origin)
            }
        }
    }
}
