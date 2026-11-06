import AppKit

/// A field that picks one item of a list. It stays an NSPopUpButton, so its items, tags, `selectItem`, target/action, lookups typed
/// `as? NSPopUpButton` and VoiceOver's popup button with its value keep working, but it never shows the system menu: it draws its own
/// trigger and opens its own menu below it, with a check on the picked item. The menu takes the trigger's appearance, so it is dark in the
/// always-dark recording panel, and it stays on screen near any edge.
///
/// Keys: Space, Return or an arrow opens it; arrows, Home and End move the highlight; letters jump to the item they start; Return or
/// Space picks; Esc and Tab close. A click outside closes it. A press can also drag onto an item and let go to pick it.
public final class Select: NSPopUpButton {
    /// Pins the trigger's look for specimens and tests. Real interaction is ignored while it is set.
    var forcedState: InteractionState? { didSet { needsDisplay = true } }

    private var isHovering = false { didSet { if oldValue != isHovering { needsDisplay = true } } }
    private(set) var menuWindow: SelectMenuWindow?
    private var monitors: [Any] = []
    private var observers: [NSObjectProtocol] = []
    private var press: (at: CGPoint, time: TimeInterval)?
    private var typed = ""
    private var typedAt: TimeInterval = 0

    public var isMenuOpen: Bool { menuWindow != nil }

    public init() {
        super.init(frame: .zero, pullsDown: false)
        isBordered = false
        focusRingType = .exterior
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    public required init?(coder: NSCoder) { fatalError("Select is created in code") }

    // MARK: Trigger

    static let chevron = "chevron.down"

    public override var intrinsicContentSize: NSSize {
        let widest = itemArray.filter { !$0.isSeparatorItem }.map { Paint.width(of: $0.title, DS.Text.label) + ($0.image == nil ? 0 : DS.Size.iconSmall + DS.Space.s6) }.max() ?? 0
        return NSSize(width: (DS.Space.s8 + widest + DS.Space.s6 + DS.Size.iconSmall + DS.Space.s8).rounded(.up), height: DS.Size.control)
    }

    var interaction: InteractionState {
        if let forcedState { return forcedState }
        if !isEnabled { return .disabled }
        if isMenuOpen { return .pressed }
        return isHovering ? .hover : .normal
    }

    static func look(_ state: InteractionState) -> ButtonAppearance {
        let c = DS.Color.self
        switch state {
        case .normal: return ButtonAppearance(fill: c.bgControl, text: c.textPrimary)
        case .hover: return ButtonAppearance(fill: c.bgControlHover, text: c.textPrimary)
        case .pressed: return ButtonAppearance(fill: c.bgControlActive, text: c.textPrimary)
        case .disabled: return ButtonAppearance(fill: c.bgControl, text: c.textDisabled)
        }
    }

    public override func draw(_ dirtyRect: NSRect) {
        let c = DS.Color.self
        let state = interaction, look = Self.look(state)
        if let fill = look.fill { Paint.fill(.continuous(bounds, radius: DS.Radius.md), fill) }
        let icon = DS.Size.iconSmall
        let chevron = CGRect(x: bounds.maxX - DS.Space.s8 - icon, y: 0, width: icon, height: bounds.height)
        Paint.symbol(Self.chevron, in: chevron, pointSize: DS.Size.iconSmall, state == .disabled ? c.textDisabled : c.textSecondary)
        var x = DS.Space.s8
        if let image = selectedItem?.image {
            let size = image.size
            image.draw(in: CGRect(x: x, y: ((bounds.height - size.height) / 2).rounded(), width: size.width, height: size.height),
                       from: .zero, operation: .sourceOver, fraction: state == .disabled ? 0.45 : 1, respectFlipped: true, hints: nil)
            x += size.width + DS.Space.s6
        }
        Paint.text(titleOfSelectedItem ?? "", DS.Text.label, look.text, in: CGRect(x: x, y: 0, width: max(chevron.minX - DS.Space.s6 - x, 0), height: bounds.height))
    }

    public override var isEnabled: Bool {
        didSet {
            if !isEnabled { isHovering = false; close() }
            needsDisplay = true
        }
    }

    public override var isHidden: Bool {
        didSet { if isHidden { close() } }
    }

    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    public override func mouseEntered(with event: NSEvent) { isHovering = isEnabled }
    public override func mouseExited(with event: NSEvent) { isHovering = false }

    public override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow !== window { close() }
        super.viewWillMove(toWindow: newWindow)
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        isHovering = false
    }

    /// The system menu never opens, from a right click either.
    public override func menu(for event: NSEvent) -> NSMenu? { nil }
    public override func rightMouseDown(with event: NSEvent) {}

    public override func drawFocusRingMask() { NSBezierPath.continuous(bounds, radius: DS.Radius.md).fill() }
    public override var focusRingMaskBounds: NSRect { bounds }

    // MARK: Pointer

    public override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        if isMenuOpen { return close() }
        open(animated: true)
        press = (event.locationInWindow, event.timestamp)
    }

    public override func mouseDragged(with event: NSEvent) {
        guard let menuWindow, let window else { return }
        menuWindow.list.highlight(atScreen: window.convertPoint(toScreen: event.locationInWindow))
    }

    /// A press that dragged onto an item, or was held a moment, picks the item it lets go on; a plain click leaves the menu open.
    public override func mouseUp(with event: NSEvent) {
        defer { press = nil }
        guard let menuWindow, let window, let press else { return }
        let moved = hypot(event.locationInWindow.x - press.at.x, event.locationInWindow.y - press.at.y) > DS.Space.s4
        let held = event.timestamp - press.time > 0.35
        guard moved || held, let index = menuWindow.list.row(atScreen: window.convertPoint(toScreen: event.locationInWindow)) else { return }
        pick(index)
    }

    // MARK: Keys

    public override func performClick(_ sender: Any?) {
        guard isEnabled else { return }
        isMenuOpen ? close() : open(animated: false)
    }

    public override func keyDown(with event: NSEvent) {
        if [49, 36, 76, 125, 126].contains(event.keyCode), isEnabled, !isMenuOpen { return open(animated: false) }
        super.keyDown(with: event)
    }

    // MARK: Accessibility

    public override func isAccessibilityElement() -> Bool { true }
    public override func accessibilityRole() -> NSAccessibility.Role? { .popUpButton }
    public override func accessibilityValue() -> Any? { titleOfSelectedItem }
    public override func isAccessibilityExpanded() -> Bool { isMenuOpen }
    public override func accessibilityPerformPress() -> Bool {
        performClick(nil)
        return isEnabled
    }
    public override func accessibilityPerformShowMenu() -> Bool { accessibilityPerformPress() }

    // MARK: Menu

    /// Opens the menu under the trigger, or over it where the screen has no room below. A pointer opens it with a short fade and
    /// growth from the trigger; keys and VoiceOver open it at once, since they are the fast path.
    public func open(animated: Bool) {
        guard !isMenuOpen, let window, numberOfItems > 0 else { return }
        let rows = itemArray.map { SelectMenuList.Row(title: $0.title, image: $0.image, isEnabled: $0.isEnabled, isSeparator: $0.isSeparatorItem) }
        let menu = SelectMenuWindow(rows: rows, selected: indexOfSelectedItem, minWidth: bounds.width, appearance: effectiveAppearance)
        menu.list.onPick = { [weak self] in self?.pick($0) }
        let trigger = window.convertToScreen(convert(bounds, to: nil))
        let frame = Self.place(menu.frame.size, under: trigger, within: window.screen?.visibleFrame)
        menu.setFrame(frame.rect, display: false)
        menu.level = NSWindow.Level(rawValue: max(window.level.rawValue, NSWindow.Level.popUpMenu.rawValue))
        menu.sharingType = window.sharingType
        menuWindow = menu
        typed = ""
        // A window that is not on screen, as in a test, keeps its menu off screen too.
        if window.isVisible {
            window.addChildWindow(menu, ordered: .above)
            if animated { menu.enter(fromTop: !frame.above) }
        }
        install()
        needsDisplay = true
        NSAccessibility.post(element: menu.list, notification: .created)
    }

    /// Closes the menu without picking. Calling it with no menu open does nothing.
    public func close() {
        guard let menu = menuWindow else { return }
        menuWindow = nil
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        menu.parent?.removeChildWindow(menu)
        menu.orderOut(nil)
        needsDisplay = true
    }

    func pick(_ index: Int) {
        guard itemArray.indices.contains(index), itemArray[index].isEnabled, !itemArray[index].isSeparatorItem else { return }
        close()
        let changed = index != indexOfSelectedItem
        selectItem(at: index)
        needsDisplay = true
        if changed { sendAction(action, to: target) }
        NSAccessibility.post(element: self, notification: .valueChanged)
    }

    /// Where the menu goes: under the trigger, left edges aligned, or above it where the screen has no room below; always inside
    /// the visible screen, on whole points.
    static func place(_ size: CGSize, under trigger: CGRect, within visible: CGRect?) -> (rect: CGRect, above: Bool) {
        let gap = DS.Space.s4
        let area = visible ?? .infinite
        var y = trigger.minY - gap - size.height
        var above = false
        if y < area.minY {
            let up = trigger.maxY + gap
            if up + size.height <= area.maxY || area.maxY - trigger.maxY > trigger.minY - area.minY {
                y = up
                above = true
            }
        }
        y = min(max(y, area.minY), area.maxY - size.height)
        let x = min(max(trigger.minX, area.minX), area.maxX - size.width)
        return (CGRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height), above)
    }

    private func install() {
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let local = NSEvent.addLocalMonitorForEvents(matching: clicks.union(.keyDown), handler: { [weak self] event in
            guard let self else { return event }
            return route(event)
        }) { monitors.append(local) }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: clicks, handler: { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.close() } }
        }) { monitors.append(global) }
        let center = NotificationCenter.default
        for name in [NSApplication.didResignActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.close() } })
        }
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification, NSWindow.willCloseNotification, NSWindow.didResignKeyNotification] {
            observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.close() } })
        }
    }

    /// The open menu sees every key and click first, so Space, Return, the arrows and Esc never reach the window behind it.
    func route(_ event: NSEvent) -> NSEvent? {
        guard let menu = menuWindow else { return event }
        if event.type == .keyDown { return handleMenuKey(event) ? nil : event }
        if event.window === menu { return event }
        // A click on the trigger only closes, so it does not open the menu again.
        if event.type == .leftMouseDown, event.window === window, bounds.contains(convert(event.locationInWindow, from: nil)) {
            close()
            return nil
        }
        close()
        return event
    }

    /// What a key does while the menu is open. Returns false only for a Command shortcut, which closes the menu and goes on.
    func handleMenuKey(_ event: NSEvent) -> Bool {
        guard let menu = menuWindow else { return false }
        let list = menu.list
        if event.modifierFlags.contains(.command) {
            close()
            return false
        }
        switch event.keyCode {
        case 125: list.moveHighlight(by: 1)
        case 126: list.moveHighlight(by: -1)
        case 115, 116: list.moveHighlight(toEnd: false)
        case 119, 121: list.moveHighlight(toEnd: true)
        case 36, 76, 49:
            if let index = list.highlighted { pick(index) } else { close() }
        case 53, 48: close()
        default:
            let letters = (event.charactersIgnoringModifiers ?? "").lowercased().filter { $0.isLetter || $0.isNumber }
            guard !letters.isEmpty else { return true }
            if event.timestamp - typedAt > 1 { typed = "" }
            typedAt = event.timestamp
            typed += letters
            list.highlight(startingWith: typed)
        }
        return true
    }
}

/// The open menu: a borderless panel that never becomes key, so the window behind it keeps its focus and its keys come through the
/// select. Opaque `bgRaised` with a `separator` edge and the system window shadow, like the menu bar panel.
final class SelectMenuWindow: NSPanel {
    let list: SelectMenuList

    init(rows: [SelectMenuList.Row], selected: Int, minWidth: CGFloat, appearance: NSAppearance) {
        list = SelectMenuList(rows: rows, selected: selected, minWidth: minWidth)
        super.init(contentRect: CGRect(origin: .zero, size: list.frame.size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        self.appearance = appearance
        WindowChrome.clearBackground(of: self)
        hasShadow = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        animationBehavior = .none
        collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        contentView = list
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// 0.20 s ease-out: opacity, and growth from 96% at the edge that meets the trigger. Reduced motion keeps only the fade.
    func enter(fromTop: Bool) {
        list.wantsLayer = true
        guard let layer = list.layer else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = DS.Motion.Duration.base
        fade.timingFunction = DS.Motion.Curve.easeOut
        layer.add(fade, forKey: "fade")
        guard !DS.Motion.isReduced else { return }
        let corner = CGPoint(x: list.bounds.midX, y: fromTop ? list.bounds.maxY : 0)
        var t = CATransform3DMakeTranslation(corner.x, corner.y, 0)
        t = CATransform3DScale(t, DS.Motion.enterScale, DS.Motion.enterScale, 1)
        t = CATransform3DTranslate(t, -corner.x, -corner.y, 0)
        let grow = CABasicAnimation(keyPath: "transform")
        grow.fromValue = t
        grow.toValue = CATransform3DIdentity
        grow.duration = DS.Motion.Duration.base
        grow.timingFunction = DS.Motion.Curve.easeOut
        layer.add(grow, forKey: "grow")
    }
}

/// The menu's rows: 28-point items with the picked one marked by a check on the right, hairline separators between groups.
final class SelectMenuList: NSView {
    struct Row {
        var title: String
        var image: NSImage?
        var isEnabled: Bool
        var isSeparator: Bool
    }

    static let padding = DS.Space.s6
    static let rowHeight = DS.Size.control
    static let separatorHeight = DS.Space.s4 * 2 + 1

    let rows: [Row]
    let selected: Int
    private(set) var highlighted: Int? { didSet { if oldValue != highlighted { needsDisplay = true } } }
    var onPick: (Int) -> Void = { _ in }
    private var frames: [CGRect] = []

    init(rows: [Row], selected: Int, minWidth: CGFloat) {
        self.rows = rows
        self.selected = selected
        let check = DS.Size.iconSmall + DS.Space.s8
        let widest = rows.filter { !$0.isSeparator }.map { row in
            max(Paint.width(of: row.title, DS.Text.bodyStrong), Paint.width(of: row.title, DS.Text.body)) + (row.image == nil ? 0 : DS.Size.iconSmall + DS.Space.s8)
        }.max() ?? 0
        let width = max(minWidth, (2 * Self.padding + 2 * DS.Space.s8 + widest + check).rounded(.up))
        var y = Self.padding
        for row in rows {
            let h = row.isSeparator ? Self.separatorHeight : Self.rowHeight
            frames.append(CGRect(x: Self.padding, y: y, width: width - 2 * Self.padding, height: h))
            y += h
        }
        super.init(frame: CGRect(x: 0, y: 0, width: width, height: y + Self.padding))
        highlighted = rows.indices.contains(selected) && rows[selected].isEnabled ? selected : rows.indices.first { rows[$0].isEnabled && !rows[$0].isSeparator }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        setAccessibilityElement(true)
        setAccessibilityRole(.menu)
    }

    required init?(coder: NSCoder) { fatalError("SelectMenuList is created in code") }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func frame(of index: Int) -> CGRect { frames[index] }

    private func pickable(_ i: Int) -> Bool { rows.indices.contains(i) && rows[i].isEnabled && !rows[i].isSeparator }

    func row(at point: CGPoint) -> Int? { frames.indices.first { frames[$0].contains(point) && pickable($0) } }

    func row(atScreen point: CGPoint) -> Int? {
        guard let window, window.frame.contains(point) else { return nil }
        return row(at: convert(window.convertPoint(fromScreen: point), from: nil))
    }

    func highlight(atScreen point: CGPoint) {
        if let i = row(atScreen: point) { highlighted = i }
    }

    func moveHighlight(by step: Int) {
        var i = highlighted ?? (step > 0 ? -1 : rows.count)
        repeat { i += step } while rows.indices.contains(i) && !pickable(i)
        if pickable(i) { highlighted = i }
    }

    func moveHighlight(toEnd: Bool) {
        highlighted = (toEnd ? Array(rows.indices.reversed()) : Array(rows.indices)).first(where: pickable) ?? highlighted
    }

    func highlight(startingWith prefix: String) {
        if let i = rows.indices.first(where: { pickable($0) && rows[$0].title.lowercased().hasPrefix(prefix) }) { highlighted = i }
    }

    override func mouseMoved(with event: NSEvent) {
        if let i = row(at: convert(event.locationInWindow, from: nil)) { highlighted = i }
    }

    override func mouseUp(with event: NSEvent) {
        if let i = row(at: convert(event.locationInWindow, from: nil)) { onPick(i) }
    }

    override func draw(_ dirtyRect: NSRect) {
        let c = DS.Color.self
        let shape = NSBezierPath.continuous(bounds, radius: DS.Radius.lg)
        Paint.fill(shape, c.bgRaised)
        Paint.strokeInside(shape, c.separator)
        for (i, row) in rows.enumerated() {
            let r = frames[i]
            if row.isSeparator {
                Paint.fill(NSBezierPath(rect: CGRect(x: r.minX + DS.Space.s8, y: r.midY.rounded(.down), width: r.width - 2 * DS.Space.s8, height: 1)), c.separator)
                continue
            }
            if i == highlighted { Paint.fill(.continuous(r, radius: DS.Radius.sm), c.bgControl) }
            let ink = row.isEnabled ? c.textPrimary : c.textDisabled
            var x = r.minX + DS.Space.s8
            if let image = row.image {
                let size = image.size
                image.draw(in: CGRect(x: x, y: (r.midY - size.height / 2).rounded(), width: size.width, height: size.height),
                           from: .zero, operation: .sourceOver, fraction: row.isEnabled ? 1 : 0.45, respectFlipped: true, hints: nil)
                x += size.width + DS.Space.s8
            }
            let check = CGRect(x: r.maxX - DS.Space.s8 - DS.Size.iconSmall, y: r.minY, width: DS.Size.iconSmall, height: r.height)
            Paint.text(row.title, i == selected ? DS.Text.bodyStrong : DS.Text.body, ink, in: CGRect(x: x, y: r.minY, width: check.minX - DS.Space.s8 - x, height: r.height))
            if i == selected { Paint.symbol("checkmark", in: check, pointSize: DS.Size.iconSmall, c.textPrimary) }
        }
    }

    override func accessibilityChildren() -> [Any]? {
        rows.indices.filter { !rows[$0].isSeparator }.map { i in
            let element = SelectMenuItemElement()
            element.setAccessibilityParent(self)
            element.setAccessibilityRole(.menuItem)
            element.setAccessibilityLabel(rows[i].title)
            element.setAccessibilitySelected(i == highlighted)
            element.setAccessibilityEnabled(rows[i].isEnabled)
            element.setAccessibilityValue(i == selected ? "Selected" : nil)
            element.setAccessibilityFrameInParentSpace(frames[i])
            element.press = { [weak self] in self?.onPick(i) }
            return element
        }
    }
}

private final class SelectMenuItemElement: NSAccessibilityElement {
    var press: () -> Void = {}
    override func accessibilityPerformPress() -> Bool { press(); return true }
}
