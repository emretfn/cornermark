import AppKit
import CornermarkCore
import CornermarkDesign

/// Sizes of the panel's parts, in points. Every width is the panel's inner width divided exactly, so tiles and thumbnails
/// land on whole points.
enum MenuMetrics {
    static let width: CGFloat = 300
    /// Radius.lg (12) minus this is Radius.sm (6): the rows' corners follow the panel's.
    static let padding = DS.Space.s6
    static let innerWidth = width - 2 * padding
    static let bannerHeight: CGFloat = 48
    static let tileHeight: CGFloat = 64
    static let tileGap = DS.Space.s6
    static let tileWidth = (innerWidth - CGFloat(MenuPanelModel.columns - 1) * tileGap) / CGFloat(MenuPanelModel.columns)
    static let headerHeight: CGFloat = 24
    static let captionHeight: CGFloat = 22
    static let thumbHeight: CGFloat = 58
    static let thumbGap = DS.Space.s6
    static let thumbWidth = (innerWidth - CGFloat(MenuPanelModel.recentLimit - 1) * thumbGap) / CGFloat(MenuPanelModel.recentLimit)
    static let rowHeight = DS.Size.control
    static let afterBanner = DS.Space.s6
    static let separatorInset = DS.Space.s4
    static let radius = DS.Radius.sm
    static let rowInset = DS.Space.s8
    static let rowGap = DS.Space.s8
}

/// What the views need from the app. The controller fills it in; a harness can fill it with anything.
struct MenuPanelHost {
    var activate: (PanelItem) -> Void
    var close: () -> Void
    var thumbnail: (CaptureRecord, @escaping @MainActor (CGImage?) -> Void) -> Void
}

// MARK: Drawing helpers

/// One line of text centred vertically in `rect`, truncated with an ellipsis.
private func drawText(_ string: String, _ style: TextStyle, _ color: NSColor, in rect: CGRect, alignment: NSTextAlignment = .left) {
    var attributes = style.attributes(color: color)
    let paragraph = (attributes[.paragraphStyle] as! NSParagraphStyle).mutableCopy() as! NSMutableParagraphStyle
    paragraph.alignment = alignment
    paragraph.lineBreakMode = .byTruncatingTail
    attributes[.paragraphStyle] = paragraph
    let line = CGRect(x: rect.minX, y: rect.midY - style.lineHeight / 2, width: rect.width, height: style.lineHeight)
    NSAttributedString(string: string, attributes: attributes).draw(with: line, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
}

private func textWidth(_ string: String, _ style: TextStyle) -> CGFloat {
    ceil(NSAttributedString(string: string, attributes: style.attributes(color: DS.Color.textPrimary)).size().width)
}

private func strokeInside(_ path: NSBezierPath, _ color: NSColor, width: CGFloat) {
    NSGraphicsContext.saveGraphicsState()
    path.addClip()
    color.setStroke()
    path.lineWidth = width * 2
    path.stroke()
    NSGraphicsContext.restoreGraphicsState()
}

private func fill(_ path: NSBezierPath, _ color: NSColor) {
    color.setFill()
    path.fill()
}

// MARK: Pressable parts

/// A part of the panel that runs on mouse up inside it. It draws itself from an `InteractionState`, like the design
/// system's controls, but fills its whole width and has no press scale.
class MenuPressableView: NSView {
    var onPress: () -> Void = {}
    var isEnabled = true {
        didSet {
            setAccessibilityEnabled(isEnabled)
            if !isEnabled { isHovering = false }
            needsDisplay = true
        }
    }

    private var isHovering = false { didSet { if oldValue != isHovering { needsDisplay = true } } }
    private var isPressing = false { didSet { if oldValue != isPressing { needsDisplay = true } } }

    var state: InteractionState {
        if !isEnabled { return .disabled }
        if isPressing { return .pressed }
        return isHovering ? .hover : .normal
    }

    init(item: PanelItem, label: String) {
        super.init(frame: .zero)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(label)
        setAccessibilityIdentifier(item.identifier)
    }

    required init?(coder: NSCoder) { fatalError("created in code") }

    var shape: NSBezierPath { .continuous(bounds, radius: MenuMetrics.radius) }

    /// What a click does, so a test or the accessibility API can press without a mouse.
    func press() { if isEnabled { onPress() } }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        press()
        return true
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        isHovering = false
        isPressing = false
    }

    override func mouseEntered(with event: NSEvent) { if isEnabled { isHovering = true } }
    override func mouseExited(with event: NSEvent) { isHovering = false }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        isPressing = true
    }

    override func mouseUp(with event: NSEvent) {
        let wasPressing = isPressing
        isPressing = false
        guard wasPressing, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        press()
    }
}

final class MenuTileView: MenuPressableView {
    let tile: MenuPanelModel.Tile

    init(_ tile: MenuPanelModel.Tile) {
        self.tile = tile
        super.init(item: tile.item, label: tile.accessibilityLabel)
    }

    required init?(coder: NSCoder) { fatalError("created in code") }

    override func draw(_ dirtyRect: NSRect) {
        let c = DS.Color.self
        switch state {
        case .normal, .disabled: fill(shape, c.bgControl)
        case .hover: fill(shape, c.bgControlHover)
        case .pressed: fill(shape, c.bgControlActive)
        }
        let top = bounds.height
        Glyph.draw(tile.symbol, in: CGRect(x: 0, y: top - 9 - DS.Size.iconLarge, width: bounds.width, height: DS.Size.iconLarge),
                   pointSize: DS.Size.iconLarge, c.textPrimary)
        let inset = DS.Space.s4
        let titleY = top - 9 - DS.Size.iconLarge - 5 - DS.Text.caption.lineHeight
        drawText(tile.title, DS.Text.caption, c.textPrimary,
                 in: CGRect(x: inset, y: titleY, width: bounds.width - 2 * inset, height: DS.Text.caption.lineHeight), alignment: .center)
        if let shortcut = tile.shortcut {
            drawText(shortcut, DS.Text.readout, c.textSecondary,
                     in: CGRect(x: inset, y: titleY - 2 - DS.Text.readout.lineHeight, width: bounds.width - 2 * inset, height: DS.Text.readout.lineHeight), alignment: .center)
        }
    }
}

final class MenuRowView: MenuPressableView {
    let row: MenuPanelModel.Row

    init(_ row: MenuPanelModel.Row) {
        self.row = row
        super.init(item: row.item, label: row.accessibilityLabel)
        isEnabled = row.isEnabled
    }

    required init?(coder: NSCoder) { fatalError("created in code") }

    override func draw(_ dirtyRect: NSRect) {
        let c = DS.Color.self
        switch state {
        case .hover: fill(shape, c.bgControl)
        case .pressed: fill(shape, c.bgControlHover)
        case .normal, .disabled: break
        }
        let disabled = state == .disabled
        let danger = row.isDestructive && !disabled
        Glyph.draw(row.symbol, in: CGRect(x: MenuMetrics.rowInset, y: 0, width: DS.Size.icon, height: bounds.height),
                   pointSize: DS.Size.icon, disabled ? c.textDisabled : (danger ? c.dangerText : c.textSecondary))
        let textX = MenuMetrics.rowInset + DS.Size.icon + MenuMetrics.rowGap
        drawText(row.title, DS.Text.body, disabled ? c.textDisabled : (danger ? c.dangerText : c.textPrimary),
                 in: CGRect(x: textX, y: 0, width: bounds.width - textX - MenuMetrics.rowInset, height: bounds.height))
    }
}

final class MenuThumbView: MenuPressableView {
    var image: CGImage? { didSet { needsDisplay = true } }

    init(_ recent: MenuPanelModel.Recent) {
        super.init(item: recent.item, label: recent.accessibilityLabel)
    }

    required init?(coder: NSCoder) { fatalError("created in code") }

    override func draw(_ dirtyRect: NSRect) {
        ImageWell.draw(image, in: bounds, radius: MenuMetrics.radius)
        switch state {
        case .hover: strokeInside(shape, DS.Color.borderStrong, width: 2)
        case .pressed: strokeInside(shape, DS.Color.textSecondary, width: 2)
        case .normal, .disabled: break
        }
    }
}

// MARK: Static parts

/// A small group title such as "Pinned screenshots".
final class MenuCaptionView: NSView {
    let text: String

    init(_ text: String) {
        self.text = text
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(text)
    }

    required init?(coder: NSCoder) { fatalError("created in code") }

    override func draw(_ dirtyRect: NSRect) {
        drawText(text, DS.Text.captionStrong, DS.Color.textSecondary,
                 in: CGRect(x: MenuMetrics.rowInset, y: 0, width: bounds.width - MenuMetrics.rowInset, height: bounds.height))
    }
}

/// The update row: the one tinted block in the panel, and the only accent.
final class MenuBannerView: NSView {
    let banner: MenuPanelModel.UpdateBanner
    let button: Button?

    init(_ banner: MenuPanelModel.UpdateBanner, press: @escaping () -> Void) {
        self.banner = banner
        button = banner.button == nil ? nil : Button(title: "Update", variant: .primary, size: .small)
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("\(banner.title), \(banner.detail)")
        if let button {
            button.setAccessibilityLabel(banner.buttonLabel)
            button.setAccessibilityIdentifier(banner.button?.identifier)
            pressAction = press
            button.target = self
            button.action = #selector(pressed)
            addSubview(button)
        }
    }

    required init?(coder: NSCoder) { fatalError("created in code") }

    private var pressAction: () -> Void = {}
    @objc private func pressed() { pressAction() }

    private var textRight: CGFloat { (button?.frame.minX ?? bounds.width) - DS.Space.s8 }

    override func layout() {
        super.layout()
        guard let button else { return }
        let size = button.intrinsicContentSize
        button.frame = CGRect(x: bounds.width - DS.Space.s12 - size.width, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        let c = DS.Color.self
        fill(.continuous(bounds, radius: MenuMetrics.radius), c.accentWash)
        Glyph.draw(banner.symbol, in: CGRect(x: DS.Space.s12, y: 0, width: DS.Size.iconXLarge, height: bounds.height),
                   pointSize: DS.Size.iconXLarge, c.textPrimary)
        let x = DS.Space.s12 + DS.Size.iconXLarge + DS.Space.s8
        let block = DS.Text.bodyStrong.lineHeight + DS.Text.caption.lineHeight
        let top = (bounds.height + block) / 2
        let width = max(textRight - x, 0)
        drawText(banner.title, DS.Text.bodyStrong, c.textPrimary,
                 in: CGRect(x: x, y: top - DS.Text.bodyStrong.lineHeight, width: width, height: DS.Text.bodyStrong.lineHeight))
        drawText(banner.detail, DS.Text.caption, c.textPrimary,
                 in: CGRect(x: x, y: top - block, width: width, height: DS.Text.caption.lineHeight))
    }
}

/// "Recent" on the left and the All control on the right.
final class MenuRecentHeaderView: NSView {
    let all: Button

    init(title: String, all item: PanelItem, press: @escaping () -> Void) {
        self.title = title
        all = Button(title: "All", variant: .ghost, size: .small)
        pressAction = press
        super.init(frame: .zero)
        all.setAccessibilityLabel("All captures")
        all.setAccessibilityIdentifier(item.identifier)
        all.target = self
        all.action = #selector(pressed)
        addSubview(all)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) { fatalError("created in code") }

    private let title: String
    private let pressAction: () -> Void
    @objc private func pressed() { pressAction() }

    override func layout() {
        super.layout()
        let size = all.intrinsicContentSize
        all.frame = CGRect(x: bounds.width - size.width, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        drawText(title, DS.Text.captionStrong, DS.Color.textSecondary,
                 in: CGRect(x: MenuMetrics.rowInset, y: 0, width: bounds.width - MenuMetrics.rowInset, height: bounds.height))
    }
}

/// A pinned screenshot's row. The title is not a control, so lock and close are the only things to press.
final class MenuPinRowView: NSView {
    let pin: MenuPanelModel.Pin
    let lock: IconButton
    let close: IconButton

    init(_ pin: MenuPanelModel.Pin, activate: @escaping (PanelItem) -> Void) {
        self.pin = pin
        lock = IconButton(symbol: pin.isLocked ? "lock.fill" : "lock.open", label: pin.isLocked ? "Unlock" : "Lock")
        close = IconButton(symbol: "xmark", label: "Close")
        self.activate = activate
        super.init(frame: .zero)
        lock.setAccessibilityLabel("\(pin.isLocked ? "Unlock" : "Lock") \(pin.title)")
        close.setAccessibilityLabel("Close \(pin.title)")
        lock.setAccessibilityIdentifier(pin.lock.identifier)
        close.setAccessibilityIdentifier(pin.close.identifier)
        for (button, action) in [(lock, #selector(lockPressed)), (close, #selector(closePressed))] {
            button.target = self
            button.action = action
            addSubview(button)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(pin.title)
    }

    required init?(coder: NSCoder) { fatalError("created in code") }

    private let activate: (PanelItem) -> Void
    @objc private func lockPressed() { activate(pin.lock) }
    @objc private func closePressed() { activate(pin.close) }

    override func layout() {
        super.layout()
        let size = close.intrinsicContentSize
        let y = (bounds.height - size.height) / 2
        close.frame = CGRect(x: bounds.width - DS.Space.s4 - size.width, y: y, width: size.width, height: size.height)
        lock.frame = CGRect(x: close.frame.minX - DS.Space.s2 - size.width, y: y, width: size.width, height: size.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        let c = DS.Color.self
        Glyph.draw("pin", in: CGRect(x: MenuMetrics.rowInset, y: 0, width: DS.Size.icon, height: bounds.height), pointSize: DS.Size.icon, c.textSecondary)
        let textX = MenuMetrics.rowInset + DS.Size.icon + MenuMetrics.rowGap
        drawText(pin.title, DS.Text.body, c.textPrimary, in: CGRect(x: textX, y: 0, width: max(lock.frame.minX - textX - DS.Space.s4, 0), height: bounds.height))
    }
}

/// The keyboard focus ring, drawn over whichever part is focused. The parts are plain views and the focus is virtual,
/// because the panel's keys must work without the app ever becoming active.
final class MenuFocusRingView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath.continuous(bounds.insetBy(dx: 1, dy: 1), radius: MenuMetrics.radius + 1)
        path.lineWidth = 2
        DS.Color.focusRing.setStroke()
        path.stroke()
    }
}

// MARK: The panel

/// The whole panel for one model. A new model means a new view: the panel is rebuilt rather than patched.
final class MenuPanelView: NSView {
    let model: MenuPanelModel
    private let host: MenuPanelHost
    private(set) var focus: MenuFocus
    private(set) var targets: [PanelItem: NSView] = [:]
    private let ring = MenuFocusRingView()

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init(model: MenuPanelModel, host: MenuPanelHost, focus: MenuFocus? = nil) {
        self.model = model
        self.host = host
        var initial = MenuFocus(rows: model.focusRows)
        if let focus {
            initial = focus
            initial.rebase(onto: model.focusRows)
        }
        self.focus = initial
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Cornermark")
        setAccessibilityIdentifier("menu.panel")
        frame.size = build()
        addSubview(ring)
        ring.isHidden = true
        placeRing()
    }

    required init?(coder: NSCoder) { fatalError("created in code") }

    // MARK: Layout

    private func build() -> CGSize {
        let pad = MenuMetrics.padding
        var y = pad
        var previous: MenuPanelModel.Section?
        for section in model.sections {
            if let previous {
                if case .update = previous {
                    y += MenuMetrics.afterBanner
                } else {
                    y += MenuMetrics.separatorInset
                    let line = Separator(axis: .horizontal)
                    line.frame = CGRect(x: pad, y: y, width: MenuMetrics.innerWidth, height: 1)
                    addSubview(line)
                    y += 1 + MenuMetrics.separatorInset
                }
            }
            y = add(section, at: y)
            previous = section
        }
        return CGSize(width: MenuMetrics.width, height: y + pad)
    }

    private func add(_ section: MenuPanelModel.Section, at top: CGFloat) -> CGFloat {
        let pad = MenuMetrics.padding
        var y = top
        func place(_ view: NSView, height: CGFloat, x: CGFloat = pad, width: CGFloat = MenuMetrics.innerWidth) {
            view.frame = CGRect(x: x, y: y, width: width, height: height)
            addSubview(view)
        }
        func addRows(_ rows: [MenuPanelModel.Row]) {
            for row in rows {
                let view = MenuRowView(row)
                view.onPress = { [host] in host.activate(row.item) }
                targets[row.item] = view
                place(view, height: MenuMetrics.rowHeight)
                y += MenuMetrics.rowHeight
            }
        }

        switch section {
        case .update(let banner):
            let view = MenuBannerView(banner) { [host] in if let item = banner.button { host.activate(item) } }
            place(view, height: MenuMetrics.bannerHeight)
            if let item = banner.button, let button = view.button { targets[item] = button }
            y += MenuMetrics.bannerHeight

        case .captures(let tiles):
            for (i, tile) in tiles.enumerated() {
                let view = MenuTileView(tile)
                view.onPress = { [host] in host.activate(tile.item) }
                targets[tile.item] = view
                let column = CGFloat(i % MenuPanelModel.columns), row = CGFloat(i / MenuPanelModel.columns)
                view.frame = CGRect(x: pad + column * (MenuMetrics.tileWidth + MenuMetrics.tileGap),
                                    y: top + row * (MenuMetrics.tileHeight + MenuMetrics.tileGap),
                                    width: MenuMetrics.tileWidth, height: MenuMetrics.tileHeight)
                addSubview(view)
            }
            let rows = CGFloat((tiles.count + MenuPanelModel.columns - 1) / MenuPanelModel.columns)
            y += rows * MenuMetrics.tileHeight + max(rows - 1, 0) * MenuMetrics.tileGap

        case .recent(let header, let all, let recents):
            let headerView = MenuRecentHeaderView(title: header, all: all) { [host] in host.activate(all) }
            place(headerView, height: MenuMetrics.headerHeight)
            targets[all] = headerView.all
            y += MenuMetrics.headerHeight + DS.Space.s2
            for (i, recent) in recents.enumerated() {
                let view = MenuThumbView(recent)
                view.onPress = { [host] in host.activate(recent.item) }
                targets[recent.item] = view
                view.frame = CGRect(x: pad + CGFloat(i) * (MenuMetrics.thumbWidth + MenuMetrics.thumbGap), y: y,
                                    width: MenuMetrics.thumbWidth, height: MenuMetrics.thumbHeight)
                addSubview(view)
                host.thumbnail(recent.record) { [weak view] image in view?.image = image }
            }
            y += MenuMetrics.thumbHeight

        case .rows(let rows), .footer(let rows):
            addRows(rows)

        case .pins(let header, let pins, let bulk):
            place(MenuCaptionView(header), height: MenuMetrics.captionHeight)
            y += MenuMetrics.captionHeight
            for pin in pins {
                let view = MenuPinRowView(pin) { [host] in host.activate($0) }
                targets[pin.lock] = view.lock
                targets[pin.close] = view.close
                place(view, height: MenuMetrics.rowHeight)
                y += MenuMetrics.rowHeight
            }
            addRows(bulk)
        }
        return y
    }

    // MARK: Keyboard

    /// Arrows move the ring, Return and Space press what it is on, Escape closes. Anything else is not the panel's.
    func handleKey(_ event: NSEvent) -> Bool {
        let direction: MenuFocus.Direction
        switch event.keyCode {
        case 126: direction = .up
        case 125: direction = .down
        case 123: direction = .left
        case 124: direction = .right
        case 36, 76, 49:
            if let current = focus.current { host.activate(current) }
            return true
        case 53:
            host.close()
            return true
        default:
            return false
        }
        move(direction)
        return true
    }

    func move(_ direction: MenuFocus.Direction) {
        focus.move(direction)
        placeRing()
    }

    override func keyDown(with event: NSEvent) {
        if !handleKey(event) { super.keyDown(with: event) }
    }

    private func placeRing() {
        guard let current = focus.current, let target = targets[current] else {
            ring.isHidden = true
            return
        }
        ring.frame = convert(target.bounds, from: target).insetBy(dx: -2, dy: -2)
        ring.isHidden = false
        ring.needsDisplay = true
    }

    /// The part showing `item`, for the harness and the accessibility tree.
    func part(for item: PanelItem) -> NSView? { targets[item] }

    var focusRingFrame: CGRect? { ring.isHidden ? nil : ring.frame }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath.continuous(bounds, radius: DS.Radius.lg)
        fill(shape, DS.Color.bgRaised)
        strokeInside(shape, DS.Color.separator, width: 1)
    }
}
