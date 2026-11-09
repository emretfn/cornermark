import AppKit
import CornermarkCore
import CornermarkDesign
import CornermarkL10n

public enum ExportPhase: Equatable, Sendable {
    case closed
    case choosing
    /// 0 to 1 of the frames written.
    case exporting(Double)

    public var isExporting: Bool { if case .exporting = self { return true } else { return false } }
}

final class ExportPanel: Surface {
    static let width: CGFloat = 320
    static let inset = DS.Space.s32

    var onSettings: (ExportSettings) -> Void = { _ in }
    var onExport: () -> Void = {}
    var onCancel: () -> Void = {}

    private let title = NSTextField.label(tr("Export"), style: DS.Text.heading, color: DS.Color.textPrimary)
    private let resolution = Select()
    private let quality = Slider()
    private let estimate = NSTextField.label("", style: DS.Text.body, color: DS.Color.textPrimary)
    private let details = NSTextField.label("", style: DS.Text.caption, color: DS.Color.textSecondary)
    private let bar = ProgressBar()
    private let percent = NSTextField.label(Digits.percent(0), style: DS.Text.readout, color: DS.Color.textPrimary)
    private let cancel = Button(title: tr("Cancel"), variant: .secondary)
    private let start = Button(title: tr("Export"), variant: .primary, shortcut: "\u{21A9}")
    private var choosingRows: [NSView] = []
    private var progressRows: [NSView] = []
    private var choices: [ExportResolution] = []
    private var settings = ExportSettings()

    init() {
        super.init(style: .floating, shadowInset: Self.inset)
        build()
    }

    required init?(coder: NSCoder) { fatalError("ExportPanel is created in code") }

    func show(_ phase: ExportPhase, settings: ExportSettings, project: RecordingProject, sourceBytes: Int64?) {
        self.settings = settings
        let exporting = phase.isExporting
        choosingRows.forEach { $0.isHidden = exporting }
        progressRows.forEach { $0.isHidden = !exporting }
        title.stringValue = exporting ? tr("Exporting video") : tr("Export")
        start.isHidden = exporting

        let options = ExportResolution.choices(for: project)
        // A background changes the sizes without changing the choices.
        let titles = options.map { option in
            let plan = ExportPlan(project: project, settings: ExportSettings(resolution: option, quality: settings.quality))
            let size = ["width": Digits.text(plan.width), "height": Digits.text(plan.height)]
            return option == .original ? tr("{width} \u{00D7} {height} (Original)", size) : tr("{width} \u{00D7} {height}", size)
        }
        if options != choices || titles != resolution.itemTitles {
            choices = options
            resolution.removeAllItems()
            resolution.addItems(withTitles: titles)
        }
        resolution.selectItem(at: options.firstIndex(of: settings.resolution) ?? 0)
        quality.doubleValue = Double(settings.quality.rawValue)
        quality.setAccessibilityValueDescription(settings.quality.localizedTitle)

        let plan = ExportPlan(project: project, settings: settings, sourceBytes: sourceBytes)
        let size = Self.bytes(plan.estimatedBytes)
        estimate.stringValue = tr("About {size}", ["size": size])
        let facts = ["width": Digits.text(plan.width), "height": Digits.text(plan.height), "fps": Digits.text(plan.fps), "duration": Timecode.text(plan.duration), "size": size]
        details.stringValue = exporting ? tr("{width} \u{00D7} {height}, {fps} fps, {duration}, about {size}", facts) : tr("{width} \u{00D7} {height}, {fps} fps, {duration}, H.264", facts)
        if case .exporting(let fraction) = phase {
            bar.fraction = fraction
            percent.stringValue = Digits.percent(Double(Int((fraction * 100).rounded(.down))) / 100)
            bar.setAccessibilityValue(NSNumber(value: fraction))
        }
    }

    static func bytes(_ count: Int64) -> String {
        let text = count.formatted(.byteCount(style: .file, allowedUnits: [.kb, .mb, .gb]).locale(L10n.locale))
        // The unit English has always shown here.
        return L10n.language == .en ? text.replacingOccurrences(of: "kB", with: "KB") : text
    }

    private func build() {
        resolution.setAccessibilityIdentifier("video.export.resolution")
        resolution.setAccessibilityLabel(tr("Resolution"))
        resolution.target = self
        resolution.action = #selector(resolutionChanged)

        quality.minValue = 0
        quality.maxValue = Double(ExportQuality.allCases.count - 1)
        quality.numberOfTickMarks = ExportQuality.allCases.count
        quality.allowsTickMarkValuesOnly = true
        quality.style = .field
        quality.format = { ExportQuality.allCases[min(max(Int($0.rounded()), 0), ExportQuality.allCases.count - 1)].localizedTitle }
        quality.isContinuous = true
        quality.setAccessibilityIdentifier("video.export.quality")
        quality.setAccessibilityLabel(tr("Quality"))
        quality.target = self
        quality.action = #selector(qualityChanged)

        estimate.setAccessibilityIdentifier("video.export.estimate")
        details.setAccessibilityIdentifier("video.export.details")
        details.lineBreakMode = .byWordWrapping
        details.maximumNumberOfLines = 0
        details.preferredMaxLayoutWidth = Self.width - 2 * DS.Space.s16
        title.setAccessibilityIdentifier("video.export.title")
        percent.setAccessibilityIdentifier("video.export.percent")
        // Flush with the bar's far end: the right in a left-to-right bar, the left in a mirrored one.
        percent.alignment = L10n.isRightToLeft ? .left : .right
        percent.setContentHuggingPriority(.required, for: .horizontal)
        percent.widthAnchor.constraint(equalToConstant: 40).isActive = true
        bar.setAccessibilityIdentifier("video.export.progress")

        start.setAccessibilityIdentifier("video.export.start")
        start.keyEquivalent = "\r"
        start.onPress { [unowned self] in onExport() }
        cancel.setAccessibilityIdentifier("video.export.cancel")
        cancel.keyEquivalent = "\u{1b}"
        cancel.onPress { [unowned self] in onCancel() }

        let resolutionRow = row(tr("Resolution"), [resolution])
        let qualityRow = row(tr("Quality"), [quality])
        let estimateRow = row(tr("Size"), [estimate])
        let progressRow = NSStackView(views: [bar, percent])
        progressRow.spacing = DS.Space.s12
        progressRow.alignment = .centerY
        let spacer = NSView()
        spacer.setContentHuggingPriority(.fittingSizeCompression, for: .horizontal)
        let buttons = NSStackView(views: [spacer, cancel, start])
        buttons.spacing = DS.Space.s8
        choosingRows = [resolutionRow, qualityRow, estimateRow]
        progressRows = [progressRow]

        let stack = NSStackView(views: [title, resolutionRow, qualityRow, estimateRow, progressRow, details, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = DS.Space.s12
        stack.setCustomSpacing(DS.Space.s16, after: title)
        stack.setCustomSpacing(DS.Space.s4, after: estimateRow)
        stack.setCustomSpacing(DS.Space.s4, after: progressRow)
        stack.setCustomSpacing(DS.Space.s16, after: details)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        let pad = Self.inset + DS.Space.s16
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.width + 2 * Self.inset),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: pad),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -pad),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -pad),
        ])
        for v in [resolutionRow, qualityRow, estimateRow, progressRow, details, buttons] {
            v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(tr("Export"))
        setAccessibilityIdentifier("video.export.panel")
    }

    private func row(_ label: String, _ views: [NSView]) -> NSStackView {
        let name = NSTextField.label(label, style: DS.Text.label, color: DS.Color.textSecondary)
        name.widthAnchor.constraint(equalToConstant: InspectorView.labelColumn + DS.Space.s8).isActive = true
        // A menu fills the rest of its row, so it ends on the same edge as the slider's value and the buttons.
        resolution.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [name] + views)
        row.spacing = DS.Space.s8
        row.alignment = .centerY
        row.distribution = .fill
        return row
    }

    var firstControl: NSView { resolution.isHiddenOrHasHiddenAncestor ? cancel : resolution }

    @objc private func resolutionChanged() {
        let i = resolution.indexOfSelectedItem
        guard choices.indices.contains(i) else { return }
        settings.resolution = choices[i]
        onSettings(settings)
    }

    @objc private func qualityChanged() {
        guard let q = ExportQuality(rawValue: Int(quality.doubleValue.rounded())), q != settings.quality else { return }
        settings.quality = q
        onSettings(settings)
    }
}

/// A determinate bar: a neutral track and a strong neutral fill, since progress is a state, not a selection or an action.
final class ProgressBar: NSView {
    static let height: CGFloat = 6

    var fraction: Double = 0 {
        didSet { if fraction != oldValue { needsDisplay = true } }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.progressIndicator)
        setAccessibilityLabel(tr("Export progress"))
        setAccessibilityMinValue(NSNumber(value: 0))
        setAccessibilityMaxValue(NSNumber(value: 1))
    }

    required init?(coder: NSCoder) { fatalError("ProgressBar is created in code") }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: Self.height) }

    override func draw(_ dirtyRect: NSRect) {
        let track = bounds.insetBy(dx: 0, dy: (bounds.height - Self.height) / 2)
        DS.Color.bgControlActive.setFill()
        NSBezierPath.continuous(track, radius: Self.height / 2).fill()
        let width = track.width * CGFloat(min(max(fraction, 0), 1))
        guard width > 0 else { return }
        var fill = CGRect(x: track.minX, y: track.minY, width: max(width, Self.height), height: track.height)
        if isRightToLeft { fill.origin.x = track.maxX - fill.width }
        DS.Color.bgInverse.setFill()
        NSBezierPath.continuous(fill, radius: Self.height / 2).fill()
    }
}
