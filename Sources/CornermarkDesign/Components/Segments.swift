import AppKit

/// Separate tiles in a row, one per segment, with optional hairline dividers between groups. It stays an
/// NSSegmentedControl, so `selectedSegment`, target/action, `setToolTip(_:forSegment:)` and casts typed `as? NSSegmentedControl`
/// keep working. The cell draws every tile itself and the control runs its own tracking loop, because the stock look turns grey
/// whenever the window is not key.
public final class Segments: NSSegmentedControl, NSViewToolTipOwner {
    public let size: ComponentSize
    /// Symbol tiles use `textSecondary` at rest instead of `textPrimary`, for groups that sit beside the main tools.
    public let quiet: Bool

    /// Segment indices that get a 1pt line after them. The line's room is part of that segment's width.
    public var dividers: Set<Int> = [] {
        didSet {
            guard oldValue != dividers else { return }
            relayout()
        }
    }

    private let symbols: [String]
    private let tileWidths: [CGFloat]
    private var toolTips: [Int: String] = [:]

    /// Pins a segment's look for specimens and tests. Real interaction is ignored for that segment while it is set.
    var forcedStates: [Int: InteractionState] = [:] { didSet { needsDisplay = true } }
    /// A momentary control reports the segment being clicked as `selectedSegment` for the length of the action.
    private var actingSegment: Int?
    public override var selectedSegment: Int {
        get { actingSegment ?? super.selectedSegment }
        set { super.selectedSegment = newValue }
    }

    private var hovered: Int? { didSet { if oldValue != hovered { needsDisplay = true } } }
    private var pressed: Int? { didSet { if oldValue != pressed { needsDisplay = true } } }

    public override class var cellClass: AnyClass? {
        get { SegmentsCell.self }
        set {}
    }

    /// One tile per symbol. `labels` name the tiles for accessibility and become their default tooltips.
    public init(symbols: [String], labels: [String], trackingMode: NSSegmentedControl.SwitchTracking = .selectOne,
                size: ComponentSize = .regular, quiet: Bool = false, tileWidth: CGFloat? = nil) {
        precondition(symbols.count == labels.count, "one label per symbol")
        self.symbols = symbols
        self.size = size
        self.quiet = quiet
        tileWidths = symbols.map { _ in tileWidth ?? size.height }
        super.init(frame: .zero)
        setUp(trackingMode: trackingMode, count: symbols.count)
        for (i, symbol) in symbols.enumerated() {
            setImage(NSImage(systemSymbolName: symbol, accessibilityDescription: labels[i]), forSegment: i)
            setToolTip(labels[i], forSegment: i)
        }
        relayout()
    }

    /// One tile per label, as wide as its text plus `tilePadding` on each side.
    public init(labels: [String], trackingMode: NSSegmentedControl.SwitchTracking = .selectOne, size: ComponentSize = .small,
                tilePadding: CGFloat = DS.Space.s12) {
        symbols = []
        self.size = size
        quiet = false
        tileWidths = labels.map { Paint.width(of: $0, DS.Text.label) + 2 * tilePadding }
        super.init(frame: .zero)
        setUp(trackingMode: trackingMode, count: labels.count)
        for (i, label) in labels.enumerated() { setLabel(label, forSegment: i) }
        relayout()
    }

    /// One tile per label, together exactly `width` wide, so a row of choices ends on the same edge as the rows around it. Each tile
    /// is as wide as its text plus an equal share of the room left.
    public init(labels: [String], width: CGFloat, size: ComponentSize = .small) {
        symbols = []
        self.size = size
        quiet = false
        let texts = labels.map { Paint.width(of: $0, DS.Text.label).rounded(.up) }
        let share = ((width - CGFloat(labels.count - 1) * DS.Space.s4 - texts.reduce(0, +)) / CGFloat(labels.count)).rounded(.down)
        tileWidths = texts.map { $0 + max(share, 0) }
        super.init(frame: .zero)
        setUp(trackingMode: .selectOne, count: labels.count)
        for (i, label) in labels.enumerated() { setLabel(label, forSegment: i) }
        relayout()
    }

    public required init?(coder: NSCoder) { fatalError("Segments is created in code") }

    private func setUp(trackingMode: NSSegmentedControl.SwitchTracking, count: Int) {
        segmentCount = count
        self.trackingMode = trackingMode
        focusRingType = .exterior
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }

    var isLabelled: Bool { symbols.isEmpty }
    var isMomentary: Bool { trackingMode == .momentary }

    // MARK: Geometry

    private static let dividerLength: CGFloat = DS.Space.s16
    /// Room a divider adds after the normal gap: s4 clear, the 1pt line, then s8 clear. Together with the gap that is s8 either side.
    private static let dividerExtra = DS.Space.s4 + 1 + DS.Space.s8

    /// The width a segment owns: its tile, the gap after it, and the divider when it has one. The last tile has no trailing gap.
    func slotWidth(_ i: Int) -> CGFloat {
        guard i < segmentCount - 1 else { return tileWidths[i] }
        return tileWidths[i] + DS.Space.s4 + (dividers.contains(i) ? Self.dividerExtra : 0)
    }

    private func relayout() {
        for i in 0..<segmentCount { setWidth(slotWidth(i), forSegment: i) }
        invalidateIntrinsicContentSize()
        frame.size = intrinsicContentSize
        refreshToolTips()
        needsDisplay = true
    }

    public override var intrinsicContentSize: NSSize {
        NSSize(width: (0..<segmentCount).reduce(0) { $0 + slotWidth($1) }, height: size.height)
    }

    /// The tile of segment `i`, vertically centred in the bounds.
    func tile(_ i: Int) -> CGRect {
        let x = (0..<i).reduce(CGFloat(0)) { $0 + slotWidth($1) }
        return CGRect(x: x, y: (bounds.height - size.height) / 2, width: tileWidths[i], height: size.height)
    }

    /// Where the divider after segment `i` is drawn.
    func dividerRect(after i: Int) -> CGRect {
        let t = tile(i)
        return CGRect(x: t.maxX + DS.Space.s4 + DS.Space.s4, y: bounds.midY - Self.dividerLength / 2, width: 1, height: Self.dividerLength)
    }

    func segment(at point: CGPoint) -> Int? {
        (0..<segmentCount).first { i in
            let slot = tile(i)
            return CGRect(x: slot.minX, y: bounds.minY, width: slotWidth(i), height: bounds.height).contains(point)
        }
    }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        refreshToolTips()
    }

    // MARK: State

    func state(of i: Int) -> InteractionState {
        if let forced = forcedStates[i] { return forced }
        if !isEnabled || !isEnabled(forSegment: i) { return .disabled }
        if pressed == i { return .pressed }
        return hovered == i ? .hover : .normal
    }

    func isSelected(_ i: Int) -> Bool { !isMomentary && isSelected(forSegment: i) }

    func look(_ i: Int) -> ButtonAppearance {
        Self.look(selected: isSelected(i), state: state(of: i), labelled: isLabelled, quiet: quiet)
    }

    static func look(selected: Bool, state: InteractionState, labelled: Bool, quiet: Bool) -> ButtonAppearance {
        let c = DS.Color.self
        if selected {
            // A choice that cannot change keeps its tile, so what is picked still reads while the control is off.
            return state == .disabled ? ButtonAppearance(fill: c.bgControl, text: c.textDisabled)
                : ButtonAppearance(fill: c.accentSubtle, text: c.accentText, border: c.accentBorder)
        }
        switch state {
        case .normal: return ButtonAppearance(fill: nil, text: labelled || quiet ? c.textSecondary : c.textPrimary)
        case .hover: return ButtonAppearance(fill: c.bgControlHover, text: c.textPrimary)
        case .pressed: return ButtonAppearance(fill: c.bgControlActive, text: c.textPrimary)
        case .disabled: return ButtonAppearance(fill: nil, text: c.textDisabled)
        }
    }

    func glyph(_ i: Int) -> String? { isLabelled ? nil : symbols[i] }

    // MARK: Pointer

    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    public override func mouseEntered(with event: NSEvent) { hovered = segment(at: convert(event.locationInWindow, from: nil)) }
    public override func mouseMoved(with event: NSEvent) { hovered = segment(at: convert(event.locationInWindow, from: nil)) }
    public override func mouseExited(with event: NSEvent) { hovered = nil }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        hovered = nil
        pressed = nil
    }

    public override func mouseDown(with event: NSEvent) {
        guard isEnabled, let window, let start = segment(at: convert(event.locationInWindow, from: nil)), isEnabled(forSegment: start) else { return }
        pressed = start
        var inside = true
        while let next = window.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) {
            inside = segment(at: convert(next.locationInWindow, from: nil)) == start
            pressed = inside ? start : nil
            if next.type == .leftMouseUp { break }
        }
        pressed = nil
        if inside { activate(start) }
    }

    /// What a completed click on segment `i` does.
    func activate(_ i: Int) {
        switch trackingMode {
        case .selectAny:
            setSelected(!isSelected(forSegment: i), forSegment: i)
            sendAction(action, to: target)
        case .momentary:
            actingSegment = i
            sendAction(action, to: target)
            actingSegment = nil
        default:
            selectedSegment = i
            sendAction(action, to: target)
        }
    }

    // MARK: Tooltips

    public override func setToolTip(_ toolTip: String?, forSegment segment: Int) {
        super.setToolTip(toolTip, forSegment: segment)
        toolTips[segment] = toolTip
        refreshToolTips()
    }

    /// The stock tooltip rects follow the stock layout, so each tile gets its own rect over the geometry drawn here.
    private func refreshToolTips() {
        removeAllToolTips()
        for i in 0..<segmentCount where toolTips[i] != nil {
            addToolTip(CGRect(x: tile(i).minX, y: bounds.minY, width: slotWidth(i), height: bounds.height), owner: self, userData: nil)
        }
    }

    public func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        segment(at: point).flatMap { toolTips[$0] } ?? ""
    }

    // MARK: Focus

    public override func drawFocusRingMask() {
        let target = selectedSegment >= 0 ? selectedSegment : 0
        guard target < segmentCount else { return }
        NSBezierPath.continuous(tile(target), radius: DS.Radius.md).fill()
    }

    public override var focusRingMaskBounds: NSRect { bounds }
}

final class SegmentsCell: NSSegmentedCell {
    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        guard let segments = controlView as? Segments, let context = NSGraphicsContext.current?.cgContext else { return }
        for i in 0..<segments.segmentCount {
            let state = segments.state(of: i), look = segments.look(i)
            let tile = segments.tile(i)
            let path = NSBezierPath.continuous(tile, radius: segments.size == .small ? DS.Radius.sm : DS.Radius.md)

            context.saveGState()
            if state == .pressed, !DS.Motion.isReduced {
                context.translateBy(x: tile.midX, y: tile.midY)
                context.scaleBy(x: DS.Motion.pressScale, y: DS.Motion.pressScale)
                context.translateBy(x: -tile.midX, y: -tile.midY)
            }
            if let fill = look.fill { Paint.fill(path, fill) }
            if let border = look.border { Paint.strokeInside(path, border) }
            if let glyph = segments.glyph(i) {
                Paint.symbol(glyph, in: tile, pointSize: segments.size.iconSize, look.text)
            } else {
                Paint.text(label(forSegment: i) ?? "", DS.Text.label, look.text, in: tile, alignment: .center)
            }
            context.restoreGState()

            if segments.dividers.contains(i), i < segments.segmentCount - 1 { Paint.fill(NSBezierPath(rect: segments.dividerRect(after: i)), DS.Color.separator) }
        }
    }

    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {}
}
