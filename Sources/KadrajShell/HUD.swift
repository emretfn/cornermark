import AppKit
import KadrajDesign

final class HUDView: NSView {
    let message: String
    let symbol: String?
    private static let style = DS.Text.bodyStrong
    static let height = DS.Size.control + DS.Space.s12
    private static let padding = DS.Space.s16
    private static let gap = DS.Space.s8
    private static let maxWidth: CGFloat = 520

    init(message: String, symbol: String?) {
        self.message = message
        self.symbol = symbol
        super.init(frame: .zero)
        // The HUD floats over any screen, so it is always the dark surface whatever the system is set to.
        appearance = NSAppearance(named: .darkAqua)
        setAccessibilityLabel(message)
        setAccessibilityIdentifier("hud")
    }

    required init?(coder: NSCoder) { fatalError() }

    private static func leading(hasSymbol: Bool) -> CGFloat { padding + (hasSymbol ? DS.Size.iconLarge + gap : 0) }

    static func size(for message: String, hasSymbol: Bool) -> CGSize {
        let text = NSAttributedString(string: message, attributes: style.attributes(color: DS.Color.textPrimary)).size()
        return CGSize(width: min(leading(hasSymbol: hasSymbol) + ceil(text.width) + padding, maxWidth), height: height)
    }

    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath.continuous(bounds, radius: DS.Radius.lg)
        DS.Color.bgHud.setFill()
        shape.fill()
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        DS.Color.border.setStroke()
        shape.lineWidth = 2
        shape.stroke()
        NSGraphicsContext.restoreGraphicsState()

        if let symbol {
            Glyph.draw(symbol, in: CGRect(x: Self.padding, y: 0, width: DS.Size.iconLarge, height: bounds.height), pointSize: DS.Size.iconLarge, DS.Color.textPrimary)
        }
        let x = Self.leading(hasSymbol: symbol != nil)
        var attributes = Self.style.attributes(color: DS.Color.textPrimary)
        let paragraph = (attributes[.paragraphStyle] as! NSParagraphStyle).mutableCopy() as! NSMutableParagraphStyle
        paragraph.lineBreakMode = .byTruncatingTail
        attributes[.paragraphStyle] = paragraph
        let line = CGRect(x: x, y: bounds.midY - Self.style.lineHeight / 2, width: max(bounds.width - x - Self.padding, 0), height: Self.style.lineHeight)
        NSAttributedString(string: message, attributes: attributes).draw(with: line, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
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
