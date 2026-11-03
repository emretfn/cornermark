import AppKit
import KadrajCore

struct HistoryActions {
    var restore: (CaptureRecord) -> Void = { _ in }
    var edit: (CaptureRecord) -> Void = { _ in }
    var copy: (CaptureRecord) -> Void = { _ in }
    var reveal: (CaptureRecord) -> Void = { _ in }
    var delete: (CaptureRecord) -> Void = { _ in }
}

final class HistoryItemView: NSView {
    var thumbnail: CGImage? { didSet { needsDisplay = true } }
    var title = "" { didSet { needsDisplay = true } }
    var subtitle = "" { didSet { needsDisplay = true } }
    var isSelected = false { didSet { needsDisplay = true } }
    var onOpen: () -> Void = {}
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let card = bounds.insetBy(dx: 2, dy: 2)
        if isSelected {
            NSColor.selectedContentBackgroundColor.withAlphaComponent(0.25).setFill()
            NSBezierPath(roundedRect: card, xRadius: 10, yRadius: 10).fill()
            NSColor.selectedContentBackgroundColor.setStroke()
            let ring = NSBezierPath(roundedRect: card.insetBy(dx: 1, dy: 1), xRadius: 10, yRadius: 10)
            ring.lineWidth = 2
            ring.stroke()
        }
        let area = NSRect(x: card.minX + 8, y: card.minY + 8, width: card.width - 16, height: card.height - 52)
        if let thumbnail {
            let s = CGSize(width: thumbnail.width, height: thumbnail.height)
            let k = min(area.width / s.width, area.height / s.height)
            let r = NSRect(x: area.midX - s.width * k / 2, y: area.midY - s.height * k / 2, width: s.width * k, height: s.height * k)
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: r, xRadius: 5, yRadius: 5).addClip()
            NSGraphicsContext.current?.imageInterpolation = .high
            NSImage(cgImage: thumbnail, size: r.size).draw(in: r, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
            NSColor(white: 0.5, alpha: 0.35).setStroke()
            NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5).stroke()
        } else {
            NSColor.quaternaryLabelColor.setFill()
            NSBezierPath(roundedRect: area, xRadius: 5, yRadius: 5).fill()
        }
        let titleAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.labelColor]
        let subAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]
        title.draw(at: NSPoint(x: card.minX + 10, y: card.maxY - 40), withAttributes: titleAttrs)
        subtitle.draw(at: NSPoint(x: card.minX + 10, y: card.maxY - 22), withAttributes: subAttrs)
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        if event.clickCount == 2 { onOpen() }
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
        v.title = "\(record.kind.title)  \u{00B7}  \(ImageOutput.dimensionText(record.pixelSize))"
        v.subtitle = Self.timeText(record.createdAt, now: now)
        v.onOpen = onOpen
        v.isSelected = isSelected
    }

    func setThumbnail(_ image: CGImage?) { itemView.thumbnail = image }

    static func timeText(_ date: Date, now: Date) -> String {
        let f = DateFormatter()
        f.locale = .current
        f.setLocalizedDateFormatFromTemplate(Calendar.current.isDate(date, inSameDayAs: now) ? "HH:mm:ss" : "d MMM HH:mm")
        return f.string(from: date)
    }
}

final class HistoryHeaderView: NSView {
    private let label = NSTextField(labelWithString: "")
    override init(frame: NSRect) {
        super.init(frame: frame)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
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

@MainActor
final class HistoryWindowController: NSWindowController, NSCollectionViewDataSource, NSCollectionViewDelegateFlowLayout {
    private let env: AppEnvironment
    let thumbnails: ThumbnailCache
    var actions = HistoryActions()
    static let thumbnailPixels = 360

    private(set) var filter: HistoryFilter = .all
    private(set) var sections: [HistorySection] = []
    let collectionView = HistoryCollectionView()
    private let filterControl = NSSegmentedControl(labels: HistoryFilter.allCases.map(\.title), trackingMode: .selectOne, target: nil, action: nil)
    private let countLabel = NSTextField(labelWithString: "")
    private let emptyLabel = NSTextField(labelWithString: "No captures yet")
    private(set) var actionButtons: [String: NSButton] = [:]

    init(env: AppEnvironment, thumbnails: ThumbnailCache = ThumbnailCache()) {
        self.env = env
        self.thumbnails = thumbnails
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 640),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: true)
        window.title = "Capture History"
        window.minSize = NSSize(width: 640, height: 420)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        build(in: window)
        window.center()
        reload()
    }

    required init?(coder: NSCoder) { fatalError() }

    var records: [CaptureRecord] { sections.flatMap(\.records) }

    var selectedRecords: [CaptureRecord] {
        collectionView.selectionIndexPaths.sorted().map { sections[$0.section].records[$0.item] }
    }

    // MARK: Layout

    private func build(in window: NSWindow) {
        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = NSSize(width: 204, height: 172)
        layout.minimumInteritemSpacing = 10
        layout.minimumLineSpacing = 10
        layout.sectionInset = NSEdgeInsets(top: 4, left: 16, bottom: 14, right: 16)
        layout.headerReferenceSize = NSSize(width: 0, height: 34)
        collectionView.collectionViewLayout = layout
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = true
        collectionView.backgroundColors = [.clear]
        collectionView.register(HistoryItem.self, forItemWithIdentifier: NSUserInterfaceItemIdentifier("item"))
        collectionView.register(HistoryHeaderView.self, forSupplementaryViewOfKind: NSCollectionView.elementKindSectionHeader,
                                withIdentifier: NSUserInterfaceItemIdentifier("header"))
        collectionView.setAccessibilityIdentifier("history.grid")
        collectionView.onDelete = { [weak self] in self?.perform(\.delete) }
        collectionView.menu = makeMenu()

        let scroll = NSScrollView()
        scroll.documentView = collectionView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false

        filterControl.selectedSegment = 0
        filterControl.target = self
        filterControl.action = #selector(filterChanged)
        filterControl.setAccessibilityIdentifier("history.filter")
        countLabel.textColor = .secondaryLabelColor
        countLabel.font = .systemFont(ofSize: 12)
        let top = NSStackView(views: [filterControl, NSView(), countLabel])
        top.orientation = .horizontal
        top.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 8, right: 16)

        let bottom = NSStackView()
        bottom.orientation = .horizontal
        bottom.spacing = 8
        bottom.edgeInsets = NSEdgeInsets(top: 8, left: 16, bottom: 12, right: 16)
        let defs: [(String, String, Selector)] = [
            ("restore", "Show Overlay", #selector(restoreSelected)), ("edit", "Edit", #selector(editSelected)),
            ("copy", "Copy", #selector(copySelected)), ("reveal", "Reveal in Finder", #selector(revealSelected)),
        ]
        for (id, title, sel) in defs { bottom.addArrangedSubview(makeButton(id, title, sel)) }
        bottom.addArrangedSubview(NSView())
        bottom.addArrangedSubview(makeButton("delete", "Delete", #selector(deleteSelected)))

        emptyLabel.font = .systemFont(ofSize: 15)
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        let column = NSStackView(views: [top, scroll, bottom])
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
            emptyLabel.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: root.centerYAnchor),
        ])
        window.contentView = root
    }

    private func makeButton(_ id: String, _ title: String, _ action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .rounded
        b.setAccessibilityIdentifier("history.\(id)")
        actionButtons[id] = b
        return b
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Show Overlay", action: #selector(restoreSelected), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Edit", action: #selector(editSelected), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Copy", action: #selector(copySelected), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Reveal in Finder", action: #selector(revealSelected), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Delete", action: #selector(deleteSelected), keyEquivalent: "").target = self
        return menu
    }

    // MARK: Data

    func reload() {
        sections = HistoryGrouping.sections(env.store.list(filter: CaptureFilter(kinds: filter.kinds)), now: env.clock())
        collectionView.reloadData()
        let n = records.count
        countLabel.stringValue = n == 1 ? "1 capture" : "\(n) captures"
        emptyLabel.isHidden = n > 0
        updateButtons()
    }

    func setFilter(_ f: HistoryFilter) {
        filter = f
        filterControl.selectedSegment = f.rawValue
        reload()
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
        let has = !collectionView.selectionIndexPaths.isEmpty
        actionButtons.values.forEach { $0.isEnabled = has }
    }

    @objc private func filterChanged() {
        filter = HistoryFilter(rawValue: filterControl.selectedSegment) ?? .all
        reload()
    }

    private func perform(_ action: KeyPath<HistoryActions, (CaptureRecord) -> Void>) {
        let selected = selectedRecords
        let run = actions[keyPath: action]
        (action == \HistoryActions.copy ? Array(selected.prefix(1)) : selected).forEach(run)
    }

    @objc func restoreSelected() { perform(\.restore) }
    @objc func editSelected() { perform(\.edit) }
    @objc func copySelected() { perform(\.copy) }
    @objc func revealSelected() { perform(\.reveal) }
    @objc func deleteSelected() { perform(\.delete) }

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
        return header
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) { updateButtons() }
    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) { updateButtons() }
}
