import AppKit
import CornermarkCore
import CornermarkDesign
import CornermarkEditor
import CornermarkL10n

struct HistoryActions {
    var restore: (CaptureRecord) -> Void = { _ in }
    /// Edits a picture or a recording for editing, and plays a plain video.
    var edit: (CaptureRecord) -> Void = { _ in }
    var copy: (CaptureRecord) -> Void = { _ in }
    var reveal: (CaptureRecord) -> Void = { _ in }
    /// Makes a GIF from a plain video recording.
    var makeGif: (CaptureRecord) -> Void = { _ in }
    var delete: (CaptureRecord) -> Void = { _ in }
}

final class HistoryItemView: NSView, KeepsLeftToRight {
    var thumbnail: CGImage? { didSet { needsDisplay = true } }
    var title = "" { didSet { needsDisplay = true } }
    var subtitle = "" { didSet { needsDisplay = true } }
    /// A recording's length, shown on its picture. Nil for a picture.
    var duration: String? { didSet { needsDisplay = true } }
    /// The glyph beside the length.
    var durationSymbol = RecordedVideo.Format.video.symbol { didSet { needsDisplay = true } }
    var isSelected = false { didSet { needsDisplay = true } }
    var onOpen: () -> Void = {}
    private var isHovering = false { didSet { if oldValue != isHovering { needsDisplay = true } } }
    override var isFlipped: Bool { true }

    /// Room around the well for the ring, which sits outside it: ring gap plus ring width, rounded up to the s8 grid.
    static let inset = DS.Space.s8
    private static let ringGap: CGFloat = 3
    /// The title and subtitle under the well: gap, a label line, a small gap, a readout line, bottom padding.
    static let footerHeight = DS.Space.s8 + DS.Text.label.lineHeight + DS.Space.s2 + DS.Text.readout.lineHeight + DS.Space.s8

    /// The fixed rectangle every capture sits in, whatever its proportions.
    var well: CGRect {
        CGRect(x: Self.inset, y: Self.inset, width: bounds.width - 2 * Self.inset, height: bounds.height - Self.inset - Self.footerHeight)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { isHovering = true }
    override func mouseExited(with event: NSEvent) { isHovering = false }

    /// A ring concentric with the well, `Self.ringGap` outside it.
    private func ring(width: CGFloat, color: NSColor) {
        let offset = Self.ringGap + width / 2
        let path = NSBezierPath.continuous(well.insetBy(dx: -offset, dy: -offset), radius: DS.Radius.md + offset)
        path.lineWidth = width
        color.setStroke()
        path.stroke()
    }

    override func draw(_ dirtyRect: NSRect) {
        let well = self.well
        ImageWell.draw(thumbnail, in: well)
        if isSelected { ring(width: 2, color: DS.Color.accentMark) } else if isHovering { ring(width: 1, color: DS.Color.borderStrong) }
        if let duration { drawDurationBadge(duration, in: well) }

        let label = DS.Text.label, readout = DS.Text.readout
        let titleLine = CGRect(x: well.minX, y: well.maxY + DS.Space.s8, width: well.width, height: label.lineHeight)
        let subtitleLine = CGRect(x: well.minX, y: titleLine.maxY + DS.Space.s2, width: well.width, height: readout.lineHeight)
        for (text, style, color, line) in [(title, label, DS.Color.textPrimary, titleLine), (subtitle, readout, DS.Color.textSecondary, subtitleLine)] {
            var attributes = style.attributes(color: color)
            let paragraph = (attributes[.paragraphStyle] as! NSParagraphStyle).mutableCopy() as! NSMutableParagraphStyle
            paragraph.lineBreakMode = .byTruncatingTail
            attributes[.paragraphStyle] = paragraph
            NSAttributedString(string: text, attributes: attributes).draw(with: line, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        if event.clickCount == 2 { onOpen() }
    }

    /// A small HUD plate in the well's bottom-left corner: a video or GIF glyph and the length. It is dark in both appearances,
    /// like the card's overlay buttons, so it reads on any frame.
    private func drawDurationBadge(_ text: String, in well: CGRect) {
        NSAppearance(named: .darkAqua)?.performAsCurrentDrawingAppearance {
            let readout = DS.Text.readout
            let attributed = NSAttributedString(string: text, attributes: readout.attributes(color: DS.Color.textPrimary))
            let pad = DS.Space.s6, glyph = DS.Size.iconSmall
            let height = readout.lineHeight + DS.Space.s4
            let width = pad + glyph + DS.Space.s4 + ceil(attributed.size().width) + pad
            // The picture is never mirrored, but the plate laid over it starts from the corner the language starts from.
            let plateX = L10n.isRightToLeft ? well.maxX - DS.Space.s6 - width : well.minX + DS.Space.s6
            let plate = CGRect(x: plateX, y: well.maxY - DS.Space.s6 - height, width: width, height: height)
            DS.Color.bgHud.setFill()
            NSBezierPath.continuous(plate, radius: DS.Radius.xs).fill()
            let glyphX = L10n.isRightToLeft ? plate.maxX - pad - glyph : plate.minX + pad
            let textX = L10n.isRightToLeft ? plate.minX + pad : plate.minX + pad + glyph + DS.Space.s4
            Glyph.draw(durationSymbol, in: CGRect(x: glyphX, y: plate.minY, width: glyph, height: plate.height), pointSize: glyph - 2, DS.Color.textPrimary)
            attributed.draw(with: CGRect(x: textX, y: plate.minY + DS.Space.s2, width: width, height: readout.lineHeight),
                            options: [.usesLineFragmentOrigin])
        }
    }
}

final class HistoryItem: NSCollectionViewItem {
    var record: CaptureRecord?
    private var itemView: HistoryItemView { view as! HistoryItemView }

    override func loadView() { view = HistoryItemView() }

    override var isSelected: Bool {
        didSet { itemView.isSelected = isSelected }
    }

    func configure(record: CaptureRecord, thumbnail: CGImage?, now: Date, onOpen: @escaping () -> Void) {
        self.record = record
        let v = itemView
        v.thumbnail = thumbnail
        v.title = "\(record.video?.format.noun ?? record.kind.title)  \u{00B7}  \(ImageOutput.dimensionText(record.pixelSize))"
        v.subtitle = Self.timeText(record.createdAt, now: now)
        v.duration = record.video.map { ImageOutput.durationText($0.duration) }
        v.durationSymbol = (record.video?.format ?? .video).symbol
        v.setAccessibilityElement(true)
        v.setAccessibilityRole(.group)
        v.setAccessibilityLabel(record.video.map {
            tr("{kind}, {duration}, {date}", ["kind": $0.format.noun, "duration": ImageOutput.durationText($0.duration), "date": v.subtitle])
        } ?? tr("{kind} capture, {date}", ["kind": record.kind.title, "date": v.subtitle]))
        v.onOpen = onOpen
        v.isSelected = isSelected
    }

    func setThumbnail(_ image: CGImage?) { itemView.thumbnail = image }

    static func timeText(_ date: Date, now: Date) -> String {
        let f = DateFormatter()
        f.locale = L10n.locale
        f.setLocalizedDateFormatFromTemplate(Calendar.current.isDate(date, inSameDayAs: now) ? "HH:mm:ss" : "d MMM HH:mm")
        return f.string(from: date)
    }
}

final class HistoryHeaderView: NSView {
    private let label = NSTextField.label("", style: DS.Text.heading, color: DS.Color.textPrimary)
    override init(frame: NSRect) {
        super.init(frame: frame)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: DS.Space.s16),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -DS.Space.s6),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
    var title: String { get { label.stringValue } set { label.stringValue = newValue } }
}

final class HistoryCollectionView: NSCollectionView {
    var onDelete: () -> Void = {}

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 51 || event.keyCode == 117 { onDelete() } else { super.keyDown(with: event) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let p = convert(event.locationInWindow, from: nil)
        if let path = indexPathForItem(at: p), !selectionIndexPaths.contains(path) { selectionIndexPaths = [path] }
        return super.menu(for: event)
    }
}

/// The row under the transparent title bar that holds the filter and the count.
final class HistoryTitleRow: NSView {
    override var mouseDownCanMoveWindow: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        DS.Color.bgSurface.setFill()
        bounds.fill()
    }
}

@MainActor
final class HistoryWindowController: NSWindowController, NSCollectionViewDataSource, NSCollectionViewDelegateFlowLayout, NSMenuItemValidation {
    private let env: AppEnvironment
    let thumbnails: ThumbnailCache
    var actions = HistoryActions()
    static let thumbnailPixels = 360

    private(set) var filter: HistoryFilter = .all
    private(set) var sections: [HistorySection] = []
    let collectionView = HistoryCollectionView()
    private let scroll = NSScrollView()
    private var filterControl = Segments(labels: HistoryFilter.allCases.map(\.title), trackingMode: .selectOne, size: .small, tilePadding: DS.Space.s8)
    private var countLabel = NSTextField.label("", style: DS.Text.caption, color: DS.Color.textSecondary)
    private var emptyLabel = NSTextField.label("", style: DS.Text.heading, color: DS.Color.textSecondary)
    private(set) var actionButtons: [String: NSButton] = [:]
    private var language: LanguageObserver?
    private var titleMetrics: (height: CGFloat, leading: CGFloat)?

    init(env: AppEnvironment, thumbnails: ThumbnailCache = ThumbnailCache()) {
        self.env = env
        self.thumbnails = thumbnails
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 640),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: true)
        window.title = tr("Capture History")
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = DS.Color.bgSurface
        // Wide enough for the eight filters and the count beside them.
        window.minSize = NSSize(width: 720, height: 420)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        configureGrid()
        build(in: window)
        window.center()
        reload()
        language = LanguageObserver { [weak self] in self?.relocalize() }
    }

    required init?(coder: NSCoder) { fatalError() }

    var records: [CaptureRecord] { sections.flatMap(\.records) }

    var selectedRecords: [CaptureRecord] {
        collectionView.selectionIndexPaths.sorted().map { sections[$0.section].records[$0.item] }
    }

    // MARK: Layout

    /// The grid and its scroll view are made once. A language change rebuilds only the chrome around them, so the selection and the
    /// scroll position stay.
    private func configureGrid() {
        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = NSSize(width: 204, height: 172)
        layout.minimumInteritemSpacing = 0
        layout.minimumLineSpacing = DS.Space.s6
        // The wells start s16 in, and each item already holds s8 of room for its selection ring.
        let side = DS.Space.s16 - HistoryItemView.inset
        layout.sectionInset = NSEdgeInsets(top: DS.Space.s4, left: side, bottom: DS.Space.s16, right: side)
        layout.headerReferenceSize = NSSize(width: 0, height: 34)
        collectionView.collectionViewLayout = layout
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = true
        collectionView.backgroundColors = [DS.Color.bgWindow]
        collectionView.register(HistoryItem.self, forItemWithIdentifier: NSUserInterfaceItemIdentifier("item"))
        collectionView.register(HistoryHeaderView.self, forSupplementaryViewOfKind: NSCollectionView.elementKindSectionHeader,
                                withIdentifier: NSUserInterfaceItemIdentifier("header"))
        collectionView.setAccessibilityIdentifier("history.grid")
        collectionView.onDelete = { [weak self] in self?.perform(\.delete) }

        scroll.documentView = collectionView
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.drawsBackground = true
        scroll.backgroundColor = DS.Color.bgWindow
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets()
    }

    private func build(in window: NSWindow) {
        collectionView.menu = makeMenu()
        actionButtons = [:]
        countLabel = NSTextField.label("", style: DS.Text.caption, color: DS.Color.textSecondary)
        emptyLabel = NSTextField.label(tr("No captures yet"), style: DS.Text.heading, color: DS.Color.textSecondary)
        filterControl = Segments(labels: HistoryFilter.allCases.map(\.title), trackingMode: .selectOne, size: .small, tilePadding: DS.Space.s8)
        filterControl.selectedSegment = filter.rawValue
        filterControl.target = self
        filterControl.action = #selector(filterChanged)
        filterControl.setAccessibilityIdentifier("history.filter")
        filterControl.setAccessibilityLabel(tr("Filter"))

        // The title row is a row of our own under the transparent title bar, on the window buttons' centre line.
        // The toolbar that makes the taller title bar is added once; a rebuild must not grow the window again.
        let (rowHeight, leading) = titleMetrics ?? WindowChrome.titleRowMetrics(for: window, toolbarIdentifier: "cornermark.history")
        titleMetrics = (rowHeight, leading)
        let titleRow = HistoryTitleRow()
        let rule = Separator(axis: .horizontal)
        for v in [filterControl, countLabel] { v.translatesAutoresizingMaskIntoConstraints = false; titleRow.addSubview(v) }
        // The window buttons stay at the top left in every language, so the row keeps clear of them there: the filters start after
        // them, or in a right-to-left language the count does, with the filters at the far right.
        if L10n.isRightToLeft {
            NSLayoutConstraint.activate([
                filterControl.rightAnchor.constraint(equalTo: titleRow.rightAnchor, constant: -DS.Space.s16),
                countLabel.leftAnchor.constraint(equalTo: titleRow.leftAnchor, constant: leading),
                countLabel.rightAnchor.constraint(lessThanOrEqualTo: filterControl.leftAnchor, constant: -DS.Space.s16),
            ])
        } else {
            NSLayoutConstraint.activate([
                filterControl.leftAnchor.constraint(equalTo: titleRow.leftAnchor, constant: leading),
                countLabel.rightAnchor.constraint(equalTo: titleRow.rightAnchor, constant: -DS.Space.s16),
                countLabel.leftAnchor.constraint(greaterThanOrEqualTo: filterControl.rightAnchor, constant: DS.Space.s16),
            ])
        }
        NSLayoutConstraint.activate([
            titleRow.heightAnchor.constraint(equalToConstant: rowHeight),
            filterControl.centerYAnchor.constraint(equalTo: titleRow.centerYAnchor),
            countLabel.centerYAnchor.constraint(equalTo: titleRow.centerYAnchor),
        ])

        let bar = BarView()
        bar.edge = .top
        let defs: [(String, String, Button.Variant, String?, Selector)] = [
            ("copy", tr("Copy"), .primary, nil, #selector(copySelected)),
            ("edit", tr("Edit"), .ghost, nil, #selector(editSelected)),
            ("restore", tr("Show Overlay"), .ghost, nil, #selector(restoreSelected)),
            ("reveal", tr("Reveal in Finder"), .ghost, nil, #selector(revealSelected)),
            ("gif", tr("Convert to GIF"), .ghost, nil, #selector(makeGifSelected)),
        ]
        let spacer = NSView()
        spacer.setContentHuggingPriority(.fittingSizeCompression, for: .horizontal)
        let buttons = defs.map { makeButton($0.0, $0.1, $0.2, $0.3, $0.4) }
            + [spacer, makeButton("delete", tr("Delete"), .dangerGhost, "trash", #selector(deleteSelected))]
        let barRow = NSStackView(views: buttons)
        barRow.orientation = .horizontal
        barRow.alignment = .centerY
        barRow.spacing = DS.Space.s8
        barRow.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(barRow)
        NSLayoutConstraint.activate([
            bar.heightAnchor.constraint(equalToConstant: 48),
            barRow.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: DS.Space.s12),
            barRow.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -DS.Space.s12),
            barRow.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
        ])

        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        let column = NSStackView(views: [titleRow, rule, scroll, bar])
        column.orientation = .vertical
        column.spacing = 0
        column.alignment = .width
        column.translatesAutoresizingMaskIntoConstraints = false
        let root = NSView()
        root.addSubview(column)
        root.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            column.topAnchor.constraint(equalTo: root.topAnchor),
            column.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
        ])
        window.contentView = root
        root.applyLanguageDirection()
    }

    private func makeButton(_ id: String, _ title: String, _ variant: Button.Variant, _ symbol: String?, _ action: Selector) -> Button {
        let b = Button(title: title, variant: variant, size: .small, symbol: symbol)
        b.target = self
        b.action = action
        b.setAccessibilityIdentifier("history.\(id)")
        actionButtons[id] = b
        return b
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: tr("Show Overlay"), action: #selector(restoreSelected), keyEquivalent: "").target = self
        menu.addItem(withTitle: tr("Edit"), action: #selector(editSelected), keyEquivalent: "").target = self
        menu.addItem(withTitle: tr("Copy"), action: #selector(copySelected), keyEquivalent: "").target = self
        menu.addItem(withTitle: tr("Reveal in Finder"), action: #selector(revealSelected), keyEquivalent: "").target = self
        menu.addItem(withTitle: tr("Convert to GIF"), action: #selector(makeGifSelected), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: tr("Delete"), action: #selector(deleteSelected), keyEquivalent: "").target = self
        return menu
    }

    // MARK: Data

    func reload() {
        sections = HistoryGrouping.sections(env.store.list(filter: filter.captureFilter), now: env.clock())
        collectionView.reloadData()
        let n = records.count
        countLabel.stringValue = filter == .recordings
            ? trPlural(one: "{count} recording", other: "{count} recordings", count: n)
            : trPlural(one: "{count} capture", other: "{count} captures", count: n)
        emptyLabel.isHidden = n > 0
        updateButtons()
    }

    func setFilter(_ f: HistoryFilter) {
        filter = f
        filterControl.selectedSegment = f.rawValue
        reload()
    }

    /// Writes every string again in the new language and lays the window out for its direction. The filter, the selection, the
    /// scroll position and the focus stay as they were.
    private func relocalize() {
        guard let window else { return }
        let selected = selectedRecords.map(\.id)
        let origin = scroll.contentView.bounds.origin
        let focused = window.firstResponder === collectionView
        window.title = tr("Capture History")
        build(in: window)
        reload()
        select(recordIDs: selected)
        scroll.contentView.scroll(to: origin)
        scroll.reflectScrolledClipView(scroll.contentView)
        if focused { window.makeFirstResponder(collectionView) }
    }

    func select(recordIDs: [UUID]) {
        var paths = Set<IndexPath>()
        for (s, section) in sections.enumerated() {
            for (i, r) in section.records.enumerated() where recordIDs.contains(r.id) { paths.insert(IndexPath(item: i, section: s)) }
        }
        collectionView.selectionIndexPaths = paths
        updateButtons()
    }

    private func updateButtons() {
        let selected = selectedRecords
        actionButtons.values.forEach { $0.isEnabled = !selected.isEmpty }
        // Edit opens a picture or a recording for editing. A plain video has nothing to edit.
        actionButtons["edit"]?.isEnabled = selected.contains { !$0.isRecording || $0.opensVideoEditor }
        actionButtons["gif"]?.isEnabled = selected.contains(where: Self.makesGif)
    }

    /// Only a plain video turns into a GIF: a project's pointer is not in its video's picture.
    private static func makesGif(_ r: CaptureRecord) -> Bool { r.video?.format == .video }

    @objc private func filterChanged() {
        filter = HistoryFilter(rawValue: filterControl.selectedSegment) ?? .all
        reload()
    }

    private func perform(_ action: KeyPath<HistoryActions, (CaptureRecord) -> Void>) {
        let selected = selectedRecords
        let run = actions[keyPath: action]
        if action == \HistoryActions.copy { return selected.prefix(1).forEach(run) }
        if action == \HistoryActions.edit { return selected.filter { !$0.isRecording || $0.opensVideoEditor }.forEach(run) }
        if action == \HistoryActions.makeGif { return selected.filter(Self.makesGif).forEach(run) }
        selected.forEach(run)
    }

    @objc func restoreSelected() { perform(\.restore) }
    @objc func editSelected() { perform(\.edit) }
    @objc func copySelected() { perform(\.copy) }
    @objc func revealSelected() { perform(\.reveal) }
    @objc func makeGifSelected() { perform(\.makeGif) }
    @objc func deleteSelected() { perform(\.delete) }

    /// The menu offers what the action bar offers for the same selection.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(editSelected)?: return selectedRecords.contains { !$0.isRecording }
        case #selector(makeGifSelected)?: return selectedRecords.contains(where: Self.makesGif)
        default: return true
        }
    }

    // MARK: Collection view

    func numberOfSections(in collectionView: NSCollectionView) -> Int { sections.count }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { sections[section].records.count }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: NSUserInterfaceItemIdentifier("item"), for: indexPath) as! HistoryItem
        let record = sections[indexPath.section].records[indexPath.item]
        let px = Self.thumbnailPixels
        item.configure(record: record, thumbnail: thumbnails.cached(record.id, maxPixel: px), now: env.clock()) { [weak self] in
            self?.actions.edit(record)
        }
        if thumbnails.cached(record.id, maxPixel: px) == nil {
            thumbnails.load(id: record.id, file: env.store.paths(for: record).image, maxPixel: px) { [weak item] image in
                if item?.record?.id == record.id { item?.setThumbnail(image) }
            }
        }
        return item
    }

    func collectionView(_ collectionView: NSCollectionView, viewForSupplementaryElementOfKind kind: NSCollectionView.SupplementaryElementKind,
                        at indexPath: IndexPath) -> NSView {
        let header = collectionView.makeSupplementaryView(ofKind: kind, withIdentifier: NSUserInterfaceItemIdentifier("header"), for: indexPath) as! HistoryHeaderView
        header.title = sections[indexPath.section].title
        header.applyLanguageDirection()
        return header
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) { updateButtons() }
    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) { updateButtons() }
}
