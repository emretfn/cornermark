import AppKit
import CornermarkDesign

final class HeaderBar: NSView {
    static let height: CGFloat = 44

    let exportButton = Button(title: "Export", variant: .primary, symbol: "square.and.arrow.up")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        exportButton.setAccessibilityIdentifier("video.export")
        exportButton.toolTip = "Export the edited video"
        let rule = Separator(axis: .horizontal)
        for v in [exportButton, rule] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            exportButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -DS.Space.s12),
            exportButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            rule.leadingAnchor.constraint(equalTo: leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: trailingAnchor),
            rule.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("HeaderBar is created in code") }

    /// While the panel is open its own Export is the view's primary action, so this one steps back; while exporting it waits.
    func show(_ phase: ExportPhase) {
        exportButton.variant = phase == .closed ? .primary : .secondary
        exportButton.isEnabled = !phase.isExporting
    }
}
