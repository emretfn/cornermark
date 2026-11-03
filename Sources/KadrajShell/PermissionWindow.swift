import AppKit

/// Shown when a capture fails because Screen & System Audio Recording is not granted.
@MainActor
final class PermissionWindowController: NSWindowController {
    private let env: AppEnvironment

    init(env: AppEnvironment) {
        self.env = env
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 340),
                              styleMask: [.titled, .closable], backing: .buffered, defer: true)
        window.title = "Screen Recording Permission"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.contentView = buildContent()
        window.center()
    }

    required init?(coder: NSCoder) { fatalError() }

    static let steps = [
        "Open System Settings \u{2192} Privacy & Security \u{2192} Screen & System Audio Recording.",
        "Switch on Kadraj in the list. If it is missing, click + and add Kadraj.app.",
        "Quit and reopen Kadraj. macOS only applies the permission to a freshly launched app.",
    ]

    private func buildContent() -> NSView {
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 40, weight: .light).applying(.init(paletteColors: [.systemRed])))
        icon.setContentHuggingPriority(.required, for: .horizontal)

        let title = NSTextField(wrappingLabelWithString: "Kadraj needs permission to record your screen")
        title.font = .systemFont(ofSize: 18, weight: .semibold)
        let header = NSStackView(views: [icon, title])
        header.orientation = .horizontal
        header.spacing = 14
        header.alignment = .centerY

        let intro = NSTextField(wrappingLabelWithString:
            "macOS blocks screenshots until you allow them. Kadraj captures on this Mac only, nothing leaves it.")
        intro.textColor = .secondaryLabelColor

        let steps = NSStackView()
        steps.orientation = .vertical
        steps.alignment = .leading
        steps.spacing = 8
        for (i, s) in Self.steps.enumerated() {
            let n = NSTextField(labelWithString: "\(i + 1).")
            n.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
            n.setContentHuggingPriority(.required, for: .horizontal)
            let t = NSTextField(wrappingLabelWithString: s)
            let row = NSStackView(views: [n, t])
            row.orientation = .horizontal
            row.alignment = .firstBaseline
            row.spacing = 6
            steps.addArrangedSubview(row)
        }

        let open = NSButton(title: "Open System Settings", target: self, action: #selector(openSettings))
        open.bezelStyle = .rounded
        open.keyEquivalent = "\r"
        open.setAccessibilityIdentifier("permission.open")
        let quit = NSButton(title: "Quit Kadraj", target: self, action: #selector(quit))
        quit.bezelStyle = .rounded
        quit.setAccessibilityIdentifier("permission.quit")
        let buttons = NSStackView(views: [quit, open])
        buttons.spacing = 10

        let hint = NSTextField(wrappingLabelWithString: "After you switch it on, macOS asks you to quit Kadraj. Reopen it from Applications.")
        hint.textColor = .secondaryLabelColor
        hint.font = .systemFont(ofSize: 12)

        let stack = NSStackView(views: [header, intro, steps, hint, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.edgeInsets = NSEdgeInsets(top: 28, left: 28, bottom: 24, right: 28)
        stack.setCustomSpacing(24, after: hint)
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 340))
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor),
        ])
        for v in [intro, hint] { v.preferredMaxLayoutWidth = 464 }
        for row in steps.arrangedSubviews { (row as? NSStackView)?.arrangedSubviews.last.map { ($0 as? NSTextField)?.preferredMaxLayoutWidth = 440 } }
        return root
    }

    @objc func openSettings() { env.openURL(AppEnvironment.screenCapturePaneURL) }
    @objc func quit() { env.quit() }
}
