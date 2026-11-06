import AppKit
import CornermarkDesign

/// Whether the project file holds what the editor shows.
enum DocumentStatus: Equatable {
    /// Nothing changed since the project was opened, so there is nothing to say.
    case unchanged
    case edited
    case saved

    var text: String {
        switch self {
        case .unchanged: return ""
        case .edited: return "Edited"
        case .saved: return "Saved"
        }
    }

    var help: String? {
        switch self {
        case .unchanged: return nil
        case .edited: return "Your edits are saved when you close the window. Press Command-S to save now."
        case .saved: return "Your edits are saved in the project."
        }
    }
}

final class HeaderBar: NSView {
    static let height: CGFloat = 44

    let exportButton = Button(title: "Export", variant: .primary, symbol: "square.and.arrow.up")
    let status = NSTextField.label("", style: DS.Text.label, color: DS.Color.textSecondary)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        exportButton.setAccessibilityIdentifier("video.export")
        exportButton.toolTip = "Export the edited video"
        status.setAccessibilityIdentifier("video.document.status")
        let rule = Separator(axis: .horizontal)
        for v in [status, exportButton, rule] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            exportButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -DS.Space.s12),
            exportButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            status.trailingAnchor.constraint(equalTo: exportButton.leadingAnchor, constant: -DS.Space.s12),
            // The button draws its own title, so its baseline anchor is not where the text is; centring lines the two up.
            status.centerYAnchor.constraint(equalTo: exportButton.centerYAnchor),
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

    func show(document: DocumentStatus) {
        status.stringValue = document.text
        status.toolTip = document.help
        status.isHidden = document == .unchanged
    }
}
