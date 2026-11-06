import AppKit
import CornermarkCore
import CornermarkDesign
import CornermarkL10n

/// The Background section: what the recording sits on, then how it is framed. Every tile shows its fill through the painter the
/// preview and export use, so a tile is exactly what the video gets.
final class BackgroundPanel: NSView {
    static let columns = 4
    static let tile: CGFloat = 48
    static let gap = DS.Space.s8
    /// Every row ends on the panel's right edge: four tiles and their gaps.
    static let inner = CGFloat(columns) * tile + CGFloat(columns - 1) * gap
    /// The gradients shown before Show more: two rows.
    static let firstGradients = 2 * columns
    static let colors: [(name: String, color: RGBA)] = [
        ("White", RGBA(1, 1, 1)), ("Silver", RGBA(0.86, 0.87, 0.89)), ("Graphite", RGBA(0.17, 0.18, 0.2)),
    ]

    var onChange: (VideoBackground, CoalescingKey?) -> Void = { _, _ in }
    /// A slider let go, which ends its undo step.
    var onSliderEnd: () -> Void = {}
    var onAddImage: () -> Void = {}
    /// The video's size in pixels now, which Custom starts from, so picking it changes nothing until a number is typed.
    var videoSize = CGSize(width: 16, height: 9)

    private(set) var background = VideoBackground()
    private(set) var showsAllGradients = false
    private var picture: CGImage?
    private var tiles: [(view: Tile, fill: VideoBackground.Fill)] = []
    private let noneTile = Tile(label: tr("None"), id: "video.background.none", size: CGSize(width: inner, height: DS.Size.control))
    private let addTile = Tile(label: tr("Add image"), id: "video.background.add")
    private let imageTile = Tile(label: tr("Your image"), id: "video.background.image")
    private let colorWell = ColorTile()
    private var gradientTiles: [Tile] = []
    private let gradientRows = NSStackView()
    private let wallpaperRows = NSStackView()
    private let more = Button(title: tr("Show more"), variant: .ghost, size: .small)
    private struct SliderRow {
        let slider: TrackingSlider
        let unit: String
        let key: CoalescingKey
        let read: (VideoBackground) -> Double
        let write: (inout VideoBackground, Double) -> Void
    }
    private var sliders: [SliderRow] = []
    private let frameNote = NSTextField(wrappingLabelWithString: "")
    private let aspect = Select()
    private let aspectWidth = TextInput(placeholder: tr("W"), size: .small, monospaced: true, centered: true)
    private let aspectHeight = TextInput(placeholder: tr("H"), size: .small, monospaced: true, centered: true)
    private var customRow = NSView()
    /// The menu's choices by item tag: the presets, then Custom.
    private static let customTag = VideoAspect.presets.count
    /// Says why Add image did nothing. Any change clears it.
    private let problem = NSTextField(wrappingLabelWithString: "")
    private let content = NSStackView()
    private let scroll = NSScrollView()
    /// The file Add image could not use, kept so the message can be written again in another language.
    private var problemFile: String?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) { fatalError("BackgroundPanel is created in code") }

    func show(_ background: VideoBackground, picture: CGImage?) {
        if background != self.background {
            problem.isHidden = true
            problemFile = nil
        }
        // A fill picked elsewhere, by undo or on opening, opens the rows that hold it so its ring shows.
        if background.fill != self.background.fill, case .gradient(let i) = background.fill, i >= Self.firstGradients, !showsAllGradients {
            setShowsAllGradients(true)
        }
        let pictureChanged = picture !== self.picture
        self.background = background
        self.picture = picture
        if pictureChanged { imageTile.thumbnail = nil }
        imageTile.isHidden = background.image == nil
        layoutWallpapers()
        for (tile, fill) in tiles { tile.isCurrent = fill == background.fill }
        noneTile.isCurrent = background.fill == .none
        imageTile.isCurrent = background.fill == .image
        if case .solid(let c) = background.fill, !Self.colors.contains(where: { $0.color == c }) {
            colorWell.isCurrent = true
            colorWell.color = NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: c.a)
        } else {
            colorWell.isCurrent = false
        }
        let framed = background.fill != .none
        for row in sliders {
            row.slider.isEnabled = framed
            row.slider.doubleValue = row.read(background)
        }
        frameNote.stringValue = background.aspect == .auto
            ? tr("Pick a background to frame the video.")
            : tr("Black bars fill the rest of the video.")
        frameNote.isHidden = framed
        showAspect(background.aspect)
    }

    private func showAspect(_ value: VideoAspect) {
        let tag: Int
        if case .custom(let w, let h) = value {
            tag = Self.customTag
            for (field, side) in [(aspectWidth, w), (aspectHeight, h)] where field.currentEditor() == nil { field.stringValue = Digits.text(side) }
        } else {
            tag = VideoAspect.presets.firstIndex(of: value) ?? 0
        }
        aspect.selectItem(withTag: tag)
        customRow.isHidden = tag != Self.customTag
    }

    /// Shows all twenty gradients, or the first two rows.
    func setShowsAllGradients(_ on: Bool) {
        showsAllGradients = on
        more.title = on ? tr("Show less") : tr("Show more")
        more.setAccessibilityLabel(on ? tr("Show fewer gradients") : tr("Show more gradients"))
        layoutGradients()
    }

    func showProblem(file: String) {
        problemFile = file
        let text = tr("{file} could not be added. Choose another image.", ["file": file])
        problem.stringValue = text
        problem.isHidden = false
        NSAccessibility.post(element: problem, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    /// What a language change must not lose: how far the fills are scrolled, how many gradients show, a message, and a ratio being typed.
    struct Snapshot {
        var scroll: CGFloat
        var showsAllGradients: Bool
        var problemFile: String?
        var typedRatio: (width: String, height: String)?
    }

    func snapshot() -> Snapshot {
        let typing = aspectWidth.currentEditor() != nil || aspectHeight.currentEditor() != nil
        return Snapshot(scroll: scroll.contentView.bounds.origin.y, showsAllGradients: showsAllGradients, problemFile: problemFile,
                        typedRatio: typing ? (aspectWidth.stringValue, aspectHeight.stringValue) : nil)
    }

    /// Call after the panel was built again and shown the project's background.
    func restore(_ snapshot: Snapshot) {
        if snapshot.showsAllGradients != showsAllGradients { setShowsAllGradients(snapshot.showsAllGradients) }
        if let file = snapshot.problemFile { showProblem(file: file) }
        if let typed = snapshot.typedRatio {
            aspectWidth.stringValue = typed.width
            aspectHeight.stringValue = typed.height
        }
        layoutSubtreeIfNeeded()
        scroll.contentView.scroll(to: CGPoint(x: 0, y: snapshot.scroll))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    static func colorName(_ name: String) -> String {
        switch name {
        case "White": return tr("White")
        case "Silver": return tr("Silver")
        case "Graphite": return tr("Graphite")
        default: return name
        }
    }

    // MARK: Build

    private func build() {
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = DS.Space.s8
        content.edgeInsets = NSEdgeInsets(top: 0, left: DS.Space.s16, bottom: DS.Space.s16, right: DS.Space.s16)
        content.translatesAutoresizingMaskIntoConstraints = false

        noneTile.paint = { [unowned tile = noneTile] rect in
            let rtl = tile.isRightToLeft
            DS.Color.bgControl.setFill()
            rect.fill()
            Glyph.draw("circle.slash", in: CGRect(x: rtl ? rect.maxX - DS.Space.s12 - DS.Size.iconLarge : rect.minX + DS.Space.s12, y: rect.minY, width: DS.Size.iconLarge, height: rect.height),
                       pointSize: DS.Size.icon, DS.Color.textSecondary)
            let text = NSAttributedString(string: tr("None"), attributes: DS.Text.label.attributes(color: DS.Color.textPrimary))
            let after = DS.Space.s12 + DS.Size.iconLarge + DS.Space.s8
            // The glyph leads and the word follows it, on whichever side the tile reads from.
            let x = rtl ? rect.maxX - after - text.size().width : rect.minX + after
            text.draw(at: CGPoint(x: x, y: rect.midY - DS.Text.label.lineHeight / 2))
        }
        noneTile.onPick = { [unowned self] in pick(.none) }
        noneTile.toolTip = tr("No background: the recording fills the video")

        for (i, g) in BuiltinBackgrounds.all.enumerated() {
            let tile = swatch(.gradient(index: i), label: tr("{name} gradient", ["name": g.localizedName]), id: "video.background.gradient.\(i)")
            gradientTiles.append(tile)
        }
        more.setAccessibilityIdentifier("video.background.more")
        more.onPress { [unowned self] in setShowsAllGradients(!showsAllGradients) }
        for rows in [gradientRows, wallpaperRows] {
            rows.orientation = .vertical
            rows.alignment = .leading
            rows.spacing = Self.gap
        }

        addTile.paint = { rect in
            DS.Color.bgControl.setFill()
            rect.fill()
            Glyph.draw("plus", in: rect, pointSize: DS.Size.iconLarge, DS.Color.textSecondary)
        }
        addTile.toolTip = tr("Add an image from your Mac")
        addTile.onPick = { [unowned self] in onAddImage() }
        imageTile.paint = { [unowned self] rect in drawThumbnail(of: .image, for: imageTile, in: rect) }
        imageTile.onPick = { [unowned self] in pick(.image) }
        for i in VideoBackground.wallpapers {
            _ = swatch(.wallpaper(index: i), label: tr("{name} wallpaper", ["name": BuiltinBackgrounds.background(at: i).localizedName]), id: "video.background.wallpaper.\(i)")
        }

        var colorRow: [NSView] = Self.colors.enumerated().map { i, c in
            swatch(.solid(color: c.color), label: Self.colorName(c.name), id: "video.background.color.\(i)")
        }
        colorWell.setAccessibilityIdentifier("video.background.color.custom")
        colorWell.setAccessibilityLabel(tr("Custom colour"))
        colorWell.toolTip = tr("Custom colour")
        colorWell.target = self
        colorWell.action = #selector(customColor)
        colorRow.append(colorWell)

        let gradientsHeader = header(tr("Gradients"), trailing: more)
        content.addArrangedSubview(noneTile)
        content.addArrangedSubview(gradientsHeader)
        content.addArrangedSubview(gradientRows)
        content.addArrangedSubview(header(tr("Wallpapers")))
        content.addArrangedSubview(wallpaperRows)
        problem.font = DS.Text.caption.font
        problem.textColor = DS.Color.dangerText
        problem.preferredMaxLayoutWidth = Self.inner
        problem.isHidden = true
        problem.setAccessibilityIdentifier("video.background.problem")
        content.addArrangedSubview(problem)
        content.addArrangedSubview(header(tr("Colour")))
        content.addArrangedSubview(row(colorRow))
        for group in [noneTile, gradientRows, wallpaperRows, problem] as [NSView] { content.setCustomSpacing(DS.Space.s16, after: group) }

        // The frame settings stay put under the fills, which scroll, so they are never past a scroll edge however short the window.
        let frame = NSStackView(views: [header(tr("Frame")), aspectRow(), customAspectRow(),
            sliderRow(tr("Padding"), range: VideoBackground.paddingRange, unit: "", id: "video.background.padding", key: "padding",
                      read: { $0.padding }, write: { $0.padding = $1 }),
            sliderRow(tr("Shadow"), range: VideoBackground.shadowRange, unit: "%", id: "video.background.shadow", key: "shadow",
                      read: { $0.shadow }, write: { $0.shadow = $1 }),
            sliderRow(tr("Corners"), range: VideoBackground.cornerRange, unit: "", id: "video.background.corners", key: "corners",
                      read: { $0.cornerRadius }, write: { $0.cornerRadius = $1 }),
            frameNote])
        frame.orientation = .vertical
        frame.alignment = .leading
        frame.spacing = DS.Space.s4
        frame.setCustomSpacing(DS.Space.s8, after: frame.arrangedSubviews[0])
        frame.edgeInsets = NSEdgeInsets(top: DS.Space.s12, left: DS.Space.s16, bottom: DS.Space.s16, right: DS.Space.s16)
        frameNote.font = DS.Text.caption.font
        frameNote.textColor = DS.Color.textSecondary
        frameNote.setAccessibilityIdentifier("video.background.note")
        frameNote.preferredMaxLayoutWidth = Self.inner

        let document = FlippedView()
        document.addSubview(content)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        // A legacy scroller would take width from the grid and move every right edge.
        scroll.scrollerStyle = .overlay
        scroll.documentView = document
        let line = Separator(axis: .horizontal)
        for v in [scroll, line, frame, document] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false }
        for v in [scroll, line, frame] as [NSView] { addSubview(v) }
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor), scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor), scroll.bottomAnchor.constraint(equalTo: line.topAnchor),
            line.leadingAnchor.constraint(equalTo: leadingAnchor), line.trailingAnchor.constraint(equalTo: trailingAnchor),
            frame.topAnchor.constraint(equalTo: line.bottomAnchor), frame.leadingAnchor.constraint(equalTo: leadingAnchor),
            frame.trailingAnchor.constraint(equalTo: trailingAnchor), frame.bottomAnchor.constraint(equalTo: bottomAnchor),
            content.leadingAnchor.constraint(equalTo: document.leadingAnchor), content.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            content.topAnchor.constraint(equalTo: document.topAnchor), content.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
        setAccessibilityIdentifier("video.background")
        layoutGradients()
        layoutWallpapers()
        show(background, picture: nil)
    }

    private func header(_ title: String, trailing: NSView? = nil) -> NSView {
        let label = NSTextField.label(title, style: DS.Text.label, color: DS.Color.textSecondary)
        label.setAccessibilityRole(.staticText)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.fittingSizeCompression, for: .horizontal)
        let views = [label, spacer] + (trailing.map { [$0] } ?? [])
        let stack = NSStackView(views: views)
        stack.alignment = .centerY
        stack.spacing = 0
        stack.widthAnchor.constraint(equalToConstant: Self.inner).isActive = true
        stack.heightAnchor.constraint(equalToConstant: DS.Size.controlSmall).isActive = true
        return stack
    }

    private func row(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.spacing = Self.gap
        return stack
    }

    private func fill(_ rows: NSStackView, with views: [NSView]) {
        rows.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for start in stride(from: 0, to: views.count, by: Self.columns) {
            rows.addArrangedSubview(row(Array(views[start..<min(start + Self.columns, views.count)])))
        }
        rows.applyChromeDirection()
    }

    private func layoutGradients() {
        fill(gradientRows, with: showsAllGradients ? gradientTiles : Array(gradientTiles.prefix(Self.firstGradients)))
    }

    private func layoutWallpapers() {
        let wallpapers = tiles.filter { if case .wallpaper = $0.fill { return true } else { return false } }.map(\.view)
        let views: [NSView] = [addTile] + (background.image == nil ? [] : [imageTile]) + wallpapers
        guard views.map(ObjectIdentifier.init) != wallpaperRows.arrangedSubviews.flatMap({ ($0 as? NSStackView)?.arrangedSubviews ?? [] }).map(ObjectIdentifier.init)
        else { return }
        fill(wallpaperRows, with: views)
    }

    private func swatch(_ fill: VideoBackground.Fill, label: String, id: String) -> Tile {
        let tile = Tile(label: label, id: id)
        tile.paint = { [unowned self, unowned tile] rect in drawThumbnail(of: fill, for: tile, in: rect) }
        tile.onPick = { [unowned self] in pick(fill) }
        tiles.append((tile, fill))
        return tile
    }

    /// Drawn once at the tile's pixel size and kept.
    private func drawThumbnail(of fill: VideoBackground.Fill, for tile: Tile, in rect: CGRect) {
        if tile.thumbnail == nil {
            let px = Int(rect.width * (window?.backingScaleFactor ?? 2))
            let canvas = VideoCanvas(source: RecordingProject.Source(pointWidth: 1, pointHeight: 1), background: VideoBackground(fill: fill, padding: 0, shadow: 0))
            tile.thumbnail = VideoBackdrop.image(canvas, width: px, height: px, picture: fill == .image ? picture : nil)
        }
        guard let image = tile.thumbnail, let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.draw(image, in: rect)
    }

    private func sliderRow(_ title: String, range: ClosedRange<Double>, unit: String, id: String, key: String,
                           read: @escaping (VideoBackground) -> Double, write: @escaping (inout VideoBackground, Double) -> Void) -> NSView {
        let label = NSTextField.label(title, style: DS.Text.label, color: DS.Color.textSecondary)
        label.widthAnchor.constraint(equalToConstant: InspectorView.labelColumn).isActive = true
        let slider = TrackingSlider()
        slider.minValue = range.lowerBound
        slider.maxValue = range.upperBound
        slider.isContinuous = true
        slider.setAccessibilityIdentifier(id)
        slider.setAccessibilityLabel(title)
        slider.format = { unit == "%" ? Digits.percent($0.rounded() / 100) : Digits.text(Int($0.rounded())) }
        slider.target = self
        slider.action = #selector(sliderMoved(_:))
        slider.onTrackingEnd = { [unowned self] in onSliderEnd() }
        sliders.append(SliderRow(slider: slider, unit: unit, key: CoalescingKey("background.\(key)"), read: read, write: write))
        let stack = NSStackView(views: [label, slider])
        stack.spacing = DS.Space.s8
        stack.alignment = .centerY
        stack.widthAnchor.constraint(equalToConstant: Self.inner).isActive = true
        stack.heightAnchor.constraint(equalToConstant: DS.Size.control).isActive = true
        return stack
    }

    private func aspectRow() -> NSView {
        aspect.setAccessibilityIdentifier("video.background.aspect")
        aspect.setAccessibilityLabel(tr("Ratio"))
        aspect.toolTip = tr("The finished video's shape")
        let menu = NSMenu()
        for (i, option) in VideoAspect.presets.enumerated() {
            if i == 1 || option == .ratio(width: 4, height: 5) { menu.addItem(Self.separator()) }
            let item = NSMenuItem(title: option.localizedTitle, action: nil, keyEquivalent: "")
            item.tag = i
            menu.addItem(item)
        }
        menu.addItem(Self.separator())
        let custom = NSMenuItem(title: VideoAspect.custom(width: 1, height: 1).localizedTitle, action: nil, keyEquivalent: "")
        custom.tag = Self.customTag
        menu.addItem(custom)
        aspect.menu = menu
        aspect.target = self
        aspect.action = #selector(aspectPicked)
        return labelled(tr("Ratio"), aspect)
    }

    /// Tagged apart from every choice, so selecting by tag never lands on one.
    private static func separator() -> NSMenuItem {
        let item = NSMenuItem.separator()
        item.tag = -1
        return item
    }

    private func customAspectRow() -> NSView {
        let times = NSTextField.label("\u{00D7}", style: DS.Text.caption, color: DS.Color.textSecondary)
        times.alignment = .center
        times.widthAnchor.constraint(equalToConstant: DS.Space.s16).isActive = true
        for (field, id, label) in [(aspectWidth, "video.background.aspect.width", tr("Ratio width")), (aspectHeight, "video.background.aspect.height", tr("Ratio height"))] {
            field.cell?.sendsActionOnEndEditing = true
            field.setAccessibilityIdentifier(id)
            field.setAccessibilityLabel(label)
            field.toolTip = tr("Only the shape counts: Export sets the size. Shapes run from 1:4 to 4:1.")
            field.target = self
            field.action = #selector(customAspectTyped)
        }
        let fields = NSStackView(views: [aspectWidth, times, aspectHeight])
        fields.spacing = 0
        fields.distribution = .fill
        aspectWidth.widthAnchor.constraint(equalTo: aspectHeight.widthAnchor).isActive = true
        customRow = labelled("", fields)
        return customRow
    }

    /// A row with the label column on the left and `control` filling the rest, ending on the panel's right edge.
    private func labelled(_ title: String, _ control: NSView) -> NSView {
        let label = NSTextField.label(title, style: DS.Text.label, color: DS.Color.textSecondary)
        label.widthAnchor.constraint(equalToConstant: InspectorView.labelColumn).isActive = true
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let stack = NSStackView(views: [label, control])
        stack.spacing = DS.Space.s8
        stack.alignment = .centerY
        stack.distribution = .fill
        stack.widthAnchor.constraint(equalToConstant: Self.inner).isActive = true
        stack.heightAnchor.constraint(equalToConstant: DS.Size.control).isActive = true
        return stack
    }

    @objc private func aspectPicked() {
        let tag = aspect.selectedTag()
        var next = background
        if tag == Self.customTag {
            if case .custom = background.aspect { return }
            next.aspect = .custom(Int(videoSize.width.rounded()), Int(videoSize.height.rounded()))
        } else {
            next.aspect = VideoAspect.presets[tag]
        }
        guard next != background else { return }
        onChange(next, nil)
    }

    @objc private func customAspectTyped() {
        guard case .custom(let w, let h) = background.aspect else { return }
        func side(_ field: NSTextField, _ old: Int) -> Int { Digits.parse(field.stringValue.trimmingCharacters(in: .whitespaces)) ?? old }
        let typed = VideoAspect.custom(side(aspectWidth, w), side(aspectHeight, h))
        if typed != background.aspect {
            var next = background
            next.aspect = typed
            onChange(next, nil)
        }
        // A number held to the limits, or one that did not parse, shows what the video uses, even while the field keeps focus.
        guard case .custom(let sw, let sh) = self.background.aspect else { return }
        aspectWidth.stringValue = Digits.text(sw)
        aspectHeight.stringValue = Digits.text(sh)
    }

    private func pick(_ fill: VideoBackground.Fill) {
        guard fill != background.fill else { return }
        var next = background
        next.fill = fill
        onChange(next, nil)
    }

    @objc private func sliderMoved(_ sender: NSSlider) {
        guard let row = sliders.first(where: { $0.slider === sender }) else { return }
        var next = background
        row.write(&next, sender.doubleValue.rounded())
        onChange(next, row.key)
    }

    @objc private func customColor() {
        let c = colorWell.color.usingColorSpace(.sRGB) ?? colorWell.color
        var next = background
        next.fill = .solid(color: RGBA(Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent), 1))
        onChange(next, "background.color")
    }
}

/// One square of the fill grid. The picture is inset when the tile is current, so the accent ring sits outside it with a gap.
final class Tile: NSButton {
    static let ring: CGFloat = 2
    var paint: (CGRect) -> Void = { _ in }
    var onPick: () -> Void = {}
    var thumbnail: CGImage? { didSet { needsDisplay = true } }
    var isCurrent = false {
        didSet {
            guard isCurrent != oldValue else { return }
            setAccessibilityValue(isCurrent ? 1 : 0)
            needsDisplay = true
        }
    }
    private var hovering = false { didSet { if oldValue != hovering { needsDisplay = true } } }

    init(label: String, id: String, size: CGSize = CGSize(width: BackgroundPanel.tile, height: BackgroundPanel.tile)) {
        super.init(frame: NSRect(origin: .zero, size: size))
        isBordered = false
        title = ""
        toolTip = label
        setAccessibilityRole(.radioButton)
        setAccessibilityLabel(label)
        setAccessibilityIdentifier(id)
        setAccessibilityValue(0)
        target = self
        action = #selector(pressed)
        widthAnchor.constraint(equalToConstant: size.width).isActive = true
        heightAnchor.constraint(equalToConstant: size.height).isActive = true
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { fatalError("Tile is created in code") }

    @objc private func pressed() { onPick() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }

    override func draw(_ dirtyRect: NSRect) {
        // Pressing shows at once, with no motion: picking a fill is frequent.
        Tile.drawChrome(in: bounds, current: isCurrent, hovering: hovering || isHighlighted, content: paint)
    }

    override func drawFocusRingMask() { NSBezierPath.continuous(bounds, radius: DS.Radius.md).fill() }
    override var focusRingMaskBounds: NSRect { bounds }

    static func drawChrome(in bounds: CGRect, current: Bool, hovering: Bool, content: (CGRect) -> Void) {
        let inset = current ? ring + 1 : 0
        let rect = bounds.insetBy(dx: inset, dy: inset)
        let picture = NSBezierPath.continuous(rect, radius: DS.Radius.md - inset)
        NSGraphicsContext.saveGraphicsState()
        picture.addClip()
        content(rect)
        DS.Color.imageOutline.setStroke()
        picture.lineWidth = 2
        picture.stroke()
        NSGraphicsContext.restoreGraphicsState()
        if current {
            DS.Color.accentMark.setStroke()
            let outline = NSBezierPath.continuous(bounds.insetBy(dx: ring / 2, dy: ring / 2), radius: DS.Radius.md - ring / 2)
            outline.lineWidth = ring
            outline.stroke()
        } else if hovering {
            let outline = NSBezierPath.continuous(bounds, radius: DS.Radius.md)
            NSGraphicsContext.saveGraphicsState()
            outline.addClip()
            DS.Color.borderStrong.setStroke()
            outline.lineWidth = 2
            outline.stroke()
            NSGraphicsContext.restoreGraphicsState()
        }
    }
}

/// The system colour well, kept for its colour panel, drawn as a tile: the custom colour in the accent ring when it is the fill,
/// otherwise a neutral tile with a palette glyph. The minimal style draws through a hosted view `draw` never reaches, so the
/// look is an overlay that lets every click through.
final class ColorTile: NSColorWell {
    var isCurrent = false {
        didSet {
            setAccessibilityValue(isCurrent ? 1 : 0)
            overlay.needsDisplay = true
        }
    }
    private let overlay = Overlay()

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: BackgroundPanel.tile, height: BackgroundPanel.tile))
        colorWellStyle = .minimal
        color = NSColor(srgbRed: 0.35, green: 0.45, blue: 0.95, alpha: 1)
        overlay.tile = self
        overlay.frame = bounds
        overlay.autoresizingMask = [.width, .height]
        addSubview(overlay)
        widthAnchor.constraint(equalToConstant: BackgroundPanel.tile).isActive = true
        heightAnchor.constraint(equalToConstant: BackgroundPanel.tile).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("ColorTile is created in code") }

    override var color: NSColor { didSet { overlay.needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {}
    override func drawFocusRingMask() { NSBezierPath.continuous(bounds, radius: DS.Radius.md).fill() }
    override var focusRingMaskBounds: NSRect { bounds }

    private final class Overlay: NSView {
        weak var tile: ColorTile?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func draw(_ dirtyRect: NSRect) {
            guard let tile else { return }
            // Covers the system swatch, which can reach past the picture when the tile is inset.
            DS.Color.bgSurface.setFill()
            bounds.fill()
            Tile.drawChrome(in: bounds, current: tile.isCurrent, hovering: false) { rect in
                if tile.isCurrent {
                    tile.color.setFill()
                    rect.fill()
                } else {
                    DS.Color.bgControl.setFill()
                    rect.fill()
                    Glyph.draw("paintpalette", in: rect, pointSize: DS.Size.icon, DS.Color.textSecondary)
                }
            }
        }
    }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
