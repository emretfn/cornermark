import AppKit
import CornermarkDesign
import CornermarkL10n

/// What the What's New window shows. `.loaded` is never empty.
enum WhatsNewContent: Equatable {
    case loading
    case loaded([ReleaseEntry])
    case failed

    /// Keeps the versions up to the running one, in the order given. Nothing left counts as a failure.
    init(history: [ReleaseEntry], running: AppVersion?) {
        let shown = running.map { running in history.filter { $0.version <= running } } ?? history
        self = shown.isEmpty ? .failed : .loaded(shown)
    }
}

/// A vertical stack that scrolls from its top: a document view shorter than the window stays pinned there only when it is flipped.
private final class Column: NSStackView {
    override var isFlipped: Bool { true }
}

/// Reads the release notes from GitHub each time it opens, so correcting a note there fixes the app.
@MainActor
final class WhatsNewWindowController: NSWindowController {
    static let releasesPage = URL(string: "https://github.com/emretfn/cornermark/releases")!
    static var emptyVersionNote: String { tr("Small fixes and improvements.") }
    static var failureNote: String { tr("Cornermark could not load the release notes.") }

    private static let width: CGFloat = 480
    private static let inner = width - 2 * DS.Space.s24

    private let env: AppEnvironment
    private let scroll = NSScrollView()
    private var load: Task<Void, Never>?
    private var language: LanguageObserver?
    private(set) var content: WhatsNewContent = .loading

    init(env: AppEnvironment) {
        self.env = env
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 560),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: true)
        window.title = tr("What's New")
        window.backgroundColor = DS.Color.bgWindow
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: Self.width, height: 280)
        window.contentMaxSize = NSSize(width: Self.width, height: .greatestFiniteMagnitude)
        super.init(window: window)

        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.setAccessibilityIdentifier("whatsnew.scroll")
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let root = FillView(color: DS.Color.bgWindow)
        root.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: root.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
        ])
        window.contentView = root
        window.center()
        render()
        root.applyLanguageDirection()
        language = LanguageObserver { [weak self] in self?.relocalize() }
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Draws the notes again in the new language at the place the reader had scrolled to. The notes themselves are the release's own
    /// text and stay as published.
    private func relocalize() {
        window?.title = tr("What's New")
        let offset = scroll.contentView.bounds.origin
        render()
        window?.contentView?.applyLanguageDirection()
        scroll.contentView.scroll(to: offset)
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    /// Shows the loading state and fetches the history again.
    func reload() {
        load?.cancel()
        show(.loading)
        load = Task { [weak self] in
            guard let env = self?.env else { return }
            let history = try? await env.updateService.releaseHistory()
            guard !Task.isCancelled else { return }
            self?.show(WhatsNewContent(history: history ?? [], running: env.updateService.currentVersion))
        }
    }

    private func show(_ content: WhatsNewContent) {
        self.content = content
        render()
    }

    // MARK: Layout

    private func render() {
        let column = Column()
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = DS.Space.s24
        column.edgeInsets = NSEdgeInsets(top: DS.Space.s24, left: DS.Space.s24, bottom: DS.Space.s24, right: DS.Space.s24)

        switch content {
        case .loading:
            column.addArrangedSubview(Self.text(tr("Loading release notes\u{2026}"), DS.Text.body, DS.Color.textSecondary, width: Self.inner))
        case .failed:
            column.addArrangedSubview(failureView())
        case .loaded(let entries):
            let running = env.updateService.currentVersion
            for (index, entry) in entries.enumerated() {
                if index > 0 {
                    let line = Separator(axis: .horizontal)
                    column.addArrangedSubview(line)
                    line.widthAnchor.constraint(equalToConstant: Self.inner).isActive = true
                }
                column.addArrangedSubview(versionView(entry, installed: entry.version == running))
            }
        }

        column.translatesAutoresizingMaskIntoConstraints = false
        column.applyLanguageDirection()
        scroll.documentView = column
        let clip = scroll.contentView
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: clip.topAnchor),
            column.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
        ])
        clip.scroll(to: .zero)
        scroll.reflectScrolledClipView(clip)
    }

    private func failureView() -> NSView {
        let button = Button(title: tr("Open Releases Page"), variant: .secondary)
        button.target = self
        button.action = #selector(openReleasesPage)
        button.setAccessibilityIdentifier("whatsnew.openReleases")
        let stack = NSStackView(views: [Self.text(Self.failureNote, DS.Text.body, DS.Color.textPrimary, width: Self.inner), button])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = DS.Space.s12
        return stack
    }

    private func versionView(_ entry: ReleaseEntry, installed: Bool) -> NSView {
        let title = NSTextField.label(tr("Version {version}", ["version": "\(entry.version)"]), style: DS.Text.heading, color: DS.Color.textPrimary)
        var head: [NSView] = [title]
        if installed { head.append(Badge(text: tr("Installed"), symbol: "checkmark.circle")) }
        let header = NSStackView(views: head)
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = DS.Space.s8

        var rows: [NSView] = [header]
        if let date = entry.publishedAt {
            rows.append(NSTextField.label(date.formatted(Date.FormatStyle(date: .long, time: .omitted).locale(L10n.locale)), style: DS.Text.caption, color: DS.Color.textSecondary))
        }
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = DS.Space.s2
        stack.setCustomSpacing(DS.Space.s12, after: rows.last!)

        let sections = entry.notes.sections
        if sections.isEmpty {
            stack.addArrangedSubview(Self.text(Self.emptyVersionNote, DS.Text.body, DS.Color.textPrimary, width: Self.inner))
        }
        for (index, section) in sections.enumerated() {
            if !section.title.isEmpty {
                let label = NSTextField.label(section.displayTitle, style: DS.Text.captionStrong, color: DS.Color.textSecondary)
                stack.addArrangedSubview(label)
                stack.setCustomSpacing(DS.Space.s6, after: label)
            }
            for (i, item) in section.items.enumerated() {
                let row = bulletRow(item)
                stack.addArrangedSubview(row)
                stack.setCustomSpacing(i == section.items.count - 1 && index < sections.count - 1 ? DS.Space.s12 : DS.Space.s4, after: row)
            }
        }
        return stack
    }

    private func bulletRow(_ item: String) -> NSView {
        let bullet = NSTextField.label("\u{2022}", style: DS.Text.body, color: DS.Color.textSecondary)
        bullet.setContentHuggingPriority(.required, for: .horizontal)
        let gap = DS.Space.s8
        let text = Self.text(item, DS.Text.body, DS.Color.textPrimary, width: Self.inner - ceil(bullet.intrinsicContentSize.width) - gap)
        let row = NSStackView(views: [bullet, text])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = gap
        return row
    }

    private static func text(_ string: String, _ style: TextStyle, _ color: NSColor, width: CGFloat) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: string)
        field.font = style.font
        field.textColor = color
        field.isSelectable = false
        field.preferredMaxLayoutWidth = width
        return field
    }

    @objc func openReleasesPage() { env.openURL(Self.releasesPage) }
}
