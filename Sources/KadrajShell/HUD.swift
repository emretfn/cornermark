import AppKit

final class HUDView: NSView {
    let message: String
    let symbol: String?
    static let font = NSFont.systemFont(ofSize: 14, weight: .medium)

    init(message: String, symbol: String?) {
        self.message = message
        self.symbol = symbol
        super.init(frame: .zero)
        setAccessibilityLabel(message)
        setAccessibilityIdentifier("hud")
    }

    required init?(coder: NSCoder) { fatalError() }

    static func size(for message: String, hasSymbol: Bool) -> CGSize {
        let text = (message as NSString).size(withAttributes: [.font: font])
        return CGSize(width: min(ceil(text.width) + (hasSymbol ? 70 : 44), 520), height: 46)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0.1, alpha: 0.86).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 14, yRadius: 14).fill()
        var x: CGFloat = 20
        if let symbol, let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
            let cfg = NSImage.SymbolConfiguration(pointSize: 16, weight: .semibold).applying(.init(paletteColors: [.white]))
            let tinted = img.withSymbolConfiguration(cfg) ?? img
            tinted.draw(in: NSRect(x: 18, y: bounds.midY - 10, width: 20, height: 20))
            x = 46
        }
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [.font: Self.font, .foregroundColor: NSColor.white, .paragraphStyle: para]
        let h = (message as NSString).size(withAttributes: attrs).height
        (message as NSString).draw(in: NSRect(x: x, y: bounds.midY - h / 2, width: bounds.width - x - 18, height: h), withAttributes: attrs)
    }
}

/// A short confirmation near the bottom of the cursor's display. Never takes events or focus.
@MainActor
final class HUD {
    private let env: AppEnvironment
    private(set) var lastMessage: String?
    private(set) var panel: NSPanel?
    private var dismissal: DispatchWorkItem?

    init(env: AppEnvironment) { self.env = env }

    func show(_ message: String, symbol: String? = "checkmark.circle.fill") {
        lastMessage = message
        dismissal?.cancel()
        panel?.close()
        let size = HUDView.size(for: message, hasSymbol: symbol != nil)
        let area = env.cursorScreenFrame()
        let frame = CGRect(x: area.midX - size.width / 2, y: area.minY + area.height * 0.18, width: size.width, height: size.height)
        let p = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.isFloatingPanel = true
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.ignoresMouseEvents = true
        p.isReleasedWhenClosed = false
        p.animationBehavior = .none
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.contentView = HUDView(message: message, symbol: symbol)
        panel = p
        guard env.isOnscreen else { return }
        p.orderFrontRegardless()
        let work = DispatchWorkItem { [weak self, weak p] in
            p?.close()
            if self?.panel === p { self?.panel = nil }
        }
        dismissal = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: work)
    }
}
