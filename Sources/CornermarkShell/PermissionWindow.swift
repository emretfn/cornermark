import AppKit
import CornermarkDesign

/// A flat colour behind a window's content, so a snapshot of the view carries the window colour too.
final class FillView: NSView {
    private let color: NSColor
    init(color: NSColor) {
        self.color = color
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        bounds.fill()
    }
}

/// The accent tile that heads the window.
private final class PermissionTile: NSView {
    static let side: CGFloat = 48
    override var intrinsicContentSize: NSSize { NSSize(width: Self.side, height: Self.side) }
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath.continuous(bounds, radius: DS.Radius.lg)
        DS.Color.accentSubtle.setFill()
        path.fill()
        Glyph.draw("camera.viewfinder", in: bounds, pointSize: DS.Size.iconLarge + DS.Space.s8, DS.Color.accentText)
    }
}

/// A numbered disc. The digit is drawn on the text's optical line so it sits in the middle of the disc.
private final class StepNumber: NSView {
    static let side: CGFloat = 20
    private let digit: String
    init(_ digit: Int) {
        self.digit = "\(digit)"
        super.init(frame: .zero)
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var intrinsicContentSize: NSSize { NSSize(width: Self.side, height: Self.side) }
    override func draw(_ dirtyRect: NSRect) {
        DS.Color.bgControl.setFill()
        NSBezierPath(ovalIn: bounds).fill()
        let style = DS.Text.captionStrong
        var attributes = style.attributes(color: DS.Color.textPrimary)
        let paragraph = (attributes[.paragraphStyle] as! NSParagraphStyle).mutableCopy() as! NSMutableParagraphStyle
        paragraph.alignment = .center
        attributes[.paragraphStyle] = paragraph
        NSAttributedString(string: digit, attributes: attributes)
            .draw(with: CGRect(x: 0, y: bounds.midY - style.lineHeight / 2, width: bounds.width, height: style.lineHeight), options: [.usesLineFragmentOrigin])
    }
}

/// Shown when a capture fails because Screen & System Audio Recording is not granted.
@MainActor
final class PermissionWindowController: NSWindowController {
    private let env: AppEnvironment
    private static let width: CGFloat = 520

    init(env: AppEnvironment) {
        self.env = env
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 340),
                              styleMask: [.titled, .closable], backing: .buffered, defer: true)
        window.title = "Screen Recording Permission"
        window.backgroundColor = DS.Color.bgWindow
        window.isReleasedWhenClosed = false
        super.init(window: window)
        let content = buildContent()
        // Assigning the content view stretches it to the window's rect, so the fitted size is taken first.
        let fitted = content.frame.size
        window.contentView = content
        window.setContentSize(fitted)
        window.center()
    }

    required init?(coder: NSCoder) { fatalError() }

    static let steps = [
        "Open System Settings \u{2192} Privacy & Security \u{2192} Screen & System Audio Recording.",
        "Switch on Cornermark in the list. If it is missing, click + and add Cornermark.app.",
        "Quit and reopen Cornermark. macOS only applies the permission to a freshly launched app.",
    ]

    private func wrapping(_ text: String, _ style: TextStyle, _ color: NSColor, width: CGFloat) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = style.font
        field.textColor = color
        field.isSelectable = false
        field.preferredMaxLayoutWidth = width
        return field
    }

    private func buildContent() -> NSView {
        let inner = Self.width - 2 * DS.Space.s24

        let title = wrapping("Cornermark needs permission to record your screen", DS.Text.title, DS.Color.textPrimary,
                             width: inner - PermissionTile.side - DS.Space.s12)
        let header = NSStackView(views: [PermissionTile(), title])
        header.orientation = .horizontal
        header.spacing = DS.Space.s12
        header.alignment = .centerY

        let intro = wrapping("macOS blocks screenshots until you allow them. Cornermark captures on this Mac only, nothing leaves it.",
                             DS.Text.body, DS.Color.textSecondary, width: inner)

        let steps = NSStackView()
        steps.orientation = .vertical
        steps.alignment = .leading
        steps.spacing = DS.Space.s12
        for (i, text) in Self.steps.enumerated() {
            let number = StepNumber(i + 1)
            let label = wrapping(text, DS.Text.body, DS.Color.textPrimary, width: inner - StepNumber.side - DS.Space.s12)
            let row = NSView()
            for v in [number, label] { v.translatesAutoresizingMaskIntoConstraints = false; row.addSubview(v) }
            // The disc is centred on the first line of text, which is a body line tall.
            let lead = (StepNumber.side - DS.Text.body.lineHeight) / 2
            NSLayoutConstraint.activate([
                number.leadingAnchor.constraint(equalTo: row.leadingAnchor),
                number.topAnchor.constraint(equalTo: row.topAnchor),
                number.widthAnchor.constraint(equalToConstant: StepNumber.side),
                number.heightAnchor.constraint(equalToConstant: StepNumber.side),
                label.leadingAnchor.constraint(equalTo: number.trailingAnchor, constant: DS.Space.s12),
                label.trailingAnchor.constraint(equalTo: row.trailingAnchor),
                label.topAnchor.constraint(equalTo: row.topAnchor, constant: lead),
                row.bottomAnchor.constraint(greaterThanOrEqualTo: label.bottomAnchor),
                row.bottomAnchor.constraint(greaterThanOrEqualTo: number.bottomAnchor),
                row.widthAnchor.constraint(equalToConstant: inner),
            ])
            steps.addArrangedSubview(row)
        }

        let hint = wrapping("After you switch it on, macOS asks you to quit Cornermark. Reopen it from Applications.", DS.Text.caption, DS.Color.textSecondary, width: inner)

        let openButton = Button(title: "Open System Settings", variant: .primary)
        openButton.keyEquivalent = "\r"
        openButton.target = self
        openButton.action = #selector(openSettings)
        openButton.setAccessibilityIdentifier("permission.open")
        let quitButton = Button(title: "Quit Cornermark", variant: .ghost)
        quitButton.target = self
        quitButton.action = #selector(quit)
        quitButton.setAccessibilityIdentifier("permission.quit")
        let spacer = NSView()
        spacer.setContentHuggingPriority(.fittingSizeCompression, for: .horizontal)
        let buttons = NSStackView(views: [spacer, quitButton, openButton])
        buttons.orientation = .horizontal
        buttons.spacing = DS.Space.s8
        buttons.alignment = .centerY

        let stack = NSStackView(views: [header, intro, steps, hint, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = DS.Space.s16
        stack.setCustomSpacing(DS.Space.s24, after: steps)
        stack.setCustomSpacing(DS.Space.s24, after: hint)
        stack.edgeInsets = NSEdgeInsets(top: DS.Space.s24, left: DS.Space.s24, bottom: DS.Space.s24, right: DS.Space.s24)
        stack.translatesAutoresizingMaskIntoConstraints = false
        buttons.widthAnchor.constraint(equalToConstant: inner).isActive = true

        let root = FillView(color: DS.Color.bgWindow)
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor),
        ])
        root.layoutSubtreeIfNeeded()
        root.setFrameSize(NSSize(width: Self.width, height: ceil(stack.fittingSize.height)))
        return root
    }

    @objc func openSettings() { env.openURL(AppEnvironment.screenCapturePaneURL) }
    @objc func quit() { env.quit() }
}
