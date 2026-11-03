import AppKit
import CornermarkDesign

final class BlockMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, key: String = "", handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: key)
        target = self
    }

    required init(coder: NSCoder) { fatalError() }
    @objc private func fire() { handler() }
}

final class PinWindow: NSPanel {
    weak var controller: PinController?

    init(frame: CGRect) {
        super.init(contentRect: frame, styleMask: [.borderless, .resizable, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, controller?.handleKey(event) == true { return }
        super.sendEvent(event)
    }
}

final class PinContentView: NSView {
    weak var controller: PinController?
    private let closeButton = CardAction.close.makeButton()
    private var hovering = false

    override var mouseDownCanMoveWindow: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init(controller: PinController) {
        self.controller = controller
        super.init(frame: .zero)
        closeButton.target = self
        closeButton.action = #selector(closePressed)
        closeButton.isHidden = true
        addSubview(closeButton)
        setAccessibilityIdentifier("pin.content")
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        closeButton.frame = NSRect(x: 6, y: bounds.height - 28, width: 22, height: 22)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let image = controller?.image else { return }
        NSGraphicsContext.current?.imageInterpolation = .high
        NSImage(cgImage: image, size: bounds.size).draw(in: bounds)
        DS.Color.imageOutline.setStroke()
        let b = NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5))
        b.lineWidth = 1
        b.stroke()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { setHovering(true) }
    override func mouseExited(with event: NSEvent) { setHovering(false) }

    func setHovering(_ value: Bool) {
        hovering = value
        closeButton.isHidden = !value
    }

    @objc private func closePressed() { controller?.close() }

    override func scrollWheel(with event: NSEvent) {
        let unit: CGFloat = event.hasPreciseScrollingDeltas ? 0.004 : 0.03
        if event.modifierFlags.contains(.option) {
            controller?.opacity += event.scrollingDeltaY * unit
        } else {
            controller?.zoom(by: exp(event.scrollingDeltaY * unit))
        }
    }

    override func magnify(with event: NSEvent) { controller?.zoom(by: 1 + event.magnification) }

    override func menu(for event: NSEvent) -> NSMenu? { controller?.makeMenu() }
}

/// One floating screenshot. Zoom, opacity and nudging all go through this class so menus, scroll
/// and keys behave the same.
@MainActor
final class PinController: NSObject, NSWindowDelegate {
    let id = UUID()
    let image: CGImage
    let window: PinWindow
    private(set) var isLocked = false
    private let aspect: CGFloat
    private let baseWidth: CGFloat
    var onClose: (PinController) -> Void = { _ in }
    var onCopy: (CGImage) -> Void = { _ in }
    var onChange: () -> Void = {}

    static let minWidth: CGFloat = 48

    init(image: CGImage, pointScale: Double, in screen: CGRect) {
        self.image = image
        aspect = CGFloat(image.width) / CGFloat(image.height)
        var w = CGFloat(image.width) / CGFloat(max(pointScale, 1))
        var h = CGFloat(image.height) / CGFloat(max(pointScale, 1))
        let fit = min(1, screen.width * 0.8 / w, screen.height * 0.8 / h)
        w = max(Self.minWidth, (w * fit).rounded()); h = (w / aspect).rounded()
        baseWidth = w
        // A fractional origin makes AppKit snap the frame outward and add a point to the size.
        window = PinWindow(frame: CGRect(x: (screen.midX - w / 2).rounded(), y: (screen.midY - h / 2).rounded(), width: w, height: h))
        super.init()
        window.controller = self
        window.delegate = self
        window.contentView = PinContentView(controller: self)
        window.title = "Pinned screenshot"
    }

    var sizeText: String { "\(image.width) \u{00D7} \(image.height)" }

    var opacity: CGFloat {
        get { window.alphaValue }
        set { window.alphaValue = min(max(newValue, 0.1), 1); onChange() }
    }

    func setLocked(_ locked: Bool) {
        isLocked = locked
        window.ignoresMouseEvents = locked
        onChange()
    }

    func close() {
        window.close()
        onClose(self)
    }

    /// Scales about the window center, within [minWidth, 4x the opening size].
    func zoom(by factor: CGFloat) {
        guard factor.isFinite, factor > 0 else { return }
        setWidth(window.frame.width * factor)
    }

    func setWidth(_ requested: CGFloat) {
        let f = window.frame
        let w = min(max(requested, Self.minWidth), baseWidth * 4)
        let h = w / aspect
        window.setFrame(CGRect(x: f.midX - w / 2, y: f.midY - h / 2, width: w, height: h).integral, display: true)
    }

    func resetSize() { setWidth(baseWidth) }

    /// Arrow keys nudge 1 pt, with Shift 10 pt; Escape closes.
    func handleKey(_ event: NSEvent) -> Bool {
        if event.keyCode == 53 { close(); return true }
        let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
        var o = window.frame.origin
        switch event.keyCode {
        case 123: o.x -= step
        case 124: o.x += step
        case 125: o.y -= step
        case 126: o.y += step
        default: return false
        }
        window.setFrameOrigin(o)
        return true
    }

    /// Keeps the image's aspect ratio when the user drags an edge.
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        let current = sender.frame.size
        let widthDriven = abs(frameSize.width - current.width) >= abs(frameSize.height - current.height)
        var w = widthDriven ? frameSize.width : frameSize.height * aspect
        w = max(w, Self.minWidth)
        return NSSize(width: w, height: w / aspect)
    }

    func windowWillClose(_ notification: Notification) {}

    func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(BlockMenuItem("Copy") { [weak self] in if let self { self.onCopy(self.image) } })
        let opacityMenu = NSMenu()
        for pct in [100, 75, 50, 25] {
            let item = BlockMenuItem("\(pct)%") { [weak self] in self?.opacity = CGFloat(pct) / 100 }
            item.state = abs(opacity - CGFloat(pct) / 100) < 0.01 ? .on : .off
            opacityMenu.addItem(item)
        }
        let opacityItem = NSMenuItem(title: "Opacity", action: nil, keyEquivalent: "")
        opacityItem.submenu = opacityMenu
        menu.addItem(opacityItem)
        let sizeMenu = NSMenu()
        sizeMenu.addItem(BlockMenuItem("Actual Size") { [weak self] in self?.resetSize() })
        sizeMenu.addItem(BlockMenuItem("Zoom In") { [weak self] in self?.zoom(by: 1.25) })
        sizeMenu.addItem(BlockMenuItem("Zoom Out") { [weak self] in self?.zoom(by: 0.8) })
        let sizeItem = NSMenuItem(title: "Size", action: nil, keyEquivalent: "")
        sizeItem.submenu = sizeMenu
        menu.addItem(sizeItem)
        menu.addItem(.separator())
        let lock = BlockMenuItem("Lock Mode (click-through)") { [weak self] in self?.setLocked(true) }
        menu.addItem(lock)
        menu.addItem(BlockMenuItem("Close") { [weak self] in self?.close() })
        return menu
    }
}

@MainActor
final class PinManager {
    private let env: AppEnvironment
    private(set) var pins: [PinController] = []
    var onCopied: () -> Void = {}

    init(env: AppEnvironment) { self.env = env }

    @discardableResult
    func pin(_ image: CGImage, pointScale: Double = 1) -> PinController {
        let pin = PinController(image: image, pointScale: pointScale, in: env.cursorScreenFrame())
        pin.onClose = { [weak self] p in self?.pins.removeAll { $0 === p } }
        pin.onCopy = { [weak self] img in
            guard let self else { return }
            _ = ImageOutput.copy(img, to: self.env.pasteboard)
            self.onCopied()
        }
        pins.append(pin)
        if env.isOnscreen { pin.window.orderFrontRegardless() }
        return pin
    }

    func closeAll() { for p in pins { p.close() } }
    func unlockAll() { pins.forEach { $0.setLocked(false) } }
    var hasLocked: Bool { pins.contains { $0.isLocked } }

    /// Entries for the menu bar: one submenu per pin, so a click-through pin can be unlocked or closed.
    func menuItems() -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        for (i, pin) in pins.enumerated() {
            let item = NSMenuItem(title: "Pin \(i + 1) \u{2013} \(pin.sizeText)", action: nil, keyEquivalent: "")
            if pin.isLocked { item.image = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: "Locked") }
            let sub = NSMenu()
            let lock = BlockMenuItem(pin.isLocked ? "Unlock" : "Lock Mode") { [weak pin] in pin?.setLocked(!(pin?.isLocked ?? false)) }
            lock.identifier = NSUserInterfaceItemIdentifier("pin.lock")
            sub.addItem(lock)
            sub.addItem(BlockMenuItem("Close") { [weak pin] in pin?.close() })
            item.submenu = sub
            items.append(item)
        }
        if pins.count > 1 {
            items.append(.separator())
            items.append(BlockMenuItem("Unlock All") { [weak self] in self?.unlockAll() })
            items.append(BlockMenuItem("Close All Pins") { [weak self] in self?.closeAll() })
        }
        return items
    }
}
