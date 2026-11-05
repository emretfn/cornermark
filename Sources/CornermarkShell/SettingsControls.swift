import AppKit
import CornermarkDesign
import ObjectiveC

private final class ClosureTarget: NSObject {
    let fn: (NSControl) -> Void
    init(_ fn: @escaping (NSControl) -> Void) { self.fn = fn }
    @objc func fire(_ sender: NSControl) { fn(sender) }
}

private nonisolated(unsafe) var targetKey: UInt8 = 0

extension NSControl {
    func onAction(_ fn: @escaping (NSControl) -> Void) {
        let t = ClosureTarget(fn)
        target = t
        action = #selector(ClosureTarget.fire(_:))
        objc_setAssociatedObject(self, &targetKey, t, .OBJC_ASSOCIATION_RETAIN)
    }
}

/// Click, then press the new shortcut. Escape cancels, Delete switches the shortcut off.
final class ShortcutRecorderView: NSView {
    /// Played when a key is refused. The harness replaces it, because its checks run while someone may be at the Mac.
    static var playRefusedSound: () -> Void = { NSSound.beep() }

    var hotKey: HotKey? { didSet { needsDisplay = true } }
    var onChange: (HotKey?) -> Void = { _ in }
    private enum Phase: Equatable {
        case idle
        case listening(held: UInt32)
        case refused
    }
    private var phase = Phase.idle { didSet { needsDisplay = true } }
    var isRecording: Bool { phase != .idle }

    static let width: CGFloat = 140
    static let waitingPrompt = "Type shortcut\u{2026}"
    static let modifierHint = "Add \u{2303} \u{2325} \u{21E7} or \u{2318}"

    var recordingPrompt: String? {
        switch phase {
        case .idle: return nil
        case .listening(held: 0): return Self.waitingPrompt
        case .listening(let held): return HotKey.modifierSymbols(held) + "\u{2026}"
        case .refused: return Self.modifierHint
        }
    }

    override var acceptsFirstResponder: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: Self.width, height: DS.Size.control) }
    // A click starts recording; it must not start a window drag.
    override var mouseDownCanMoveWindow: Bool { false }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityRole(.button)
        focusRingType = .exterior
    }

    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        beginRecording()
    }

    override func resignFirstResponder() -> Bool {
        phase = .idle
        return super.resignFirstResponder()
    }

    func beginRecording() { phase = .listening(held: 0) }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording else { return false }
        keyDown(with: event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else { return super.keyDown(with: event) }
        switch event.keyCode {
        case 53:
            phase = .idle
        case 51, 117:
            phase = .idle
            onChange(nil)
        default:
            guard let key = HotKey(event: event) else {
                phase = .refused
                return Self.playRefusedSound()
            }
            phase = .idle
            onChange(key)
        }
    }

    override func flagsChanged(with event: NSEvent) {
        guard isRecording else { return super.flagsChanged(with: event) }
        phase = .listening(held: HotKey.carbonModifiers(event.modifierFlags))
    }

    override func drawFocusRingMask() { NSBezierPath.continuous(bounds, radius: DS.Radius.md).fill() }
    override var focusRingMaskBounds: NSRect { bounds }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath.continuous(bounds, radius: DS.Radius.md)
        (isRecording ? DS.Color.accentSubtle : DS.Color.bgControl).setFill()
        path.fill()
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        (isRecording ? DS.Color.accentBorder : DS.Color.border).setStroke()
        path.lineWidth = 2
        path.stroke()
        NSGraphicsContext.restoreGraphicsState()

        let text: String, color: NSColor
        if let recordingPrompt { text = recordingPrompt; color = DS.Color.textSecondary }
        else if let hotKey { text = hotKey.displayString; color = DS.Color.textPrimary }
        else { text = "Not set"; color = DS.Color.textDisabled }
        let style = DS.Text.bodyStrong
        var attributes = style.attributes(color: color)
        let paragraph = (attributes[.paragraphStyle] as! NSParagraphStyle).mutableCopy() as! NSMutableParagraphStyle
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingTail
        attributes[.paragraphStyle] = paragraph
        let line = NSRect(x: DS.Space.s8, y: bounds.midY - style.lineHeight / 2, width: bounds.width - 2 * DS.Space.s8, height: style.lineHeight)
        NSAttributedString(string: text, attributes: attributes).draw(with: line, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }
}

/// One settings row: the title on the left with an optional caption under it, the control on the right and centred.
/// Laid out by hand at a fixed width, so its height is known without a layout pass and a caption that changes can be re-measured.
final class FormRow: NSView {
    static let minHeight: CGFloat = 44
    private static let titleStyle = DS.Text.body

    let titleField: NSTextField?
    let caption: NSTextField?
    let control: NSView?
    var width: CGFloat = Form.cardWidth { didSet { invalidate() } }

    override var isFlipped: Bool { true }

    init(title: String, caption: NSTextField?, control: NSView?) {
        titleField = title.isEmpty ? nil : NSTextField.label(title, style: Self.titleStyle, color: DS.Color.textPrimary)
        self.caption = caption
        self.control = control
        super.init(frame: .zero)
        for view in [titleField, caption, control] { if let view { addSubview(view) } }
    }

    required init?(coder: NSCoder) { fatalError() }

    func invalidate() {
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    private struct Metrics {
        var controlSize: CGSize
        var textWidth: CGFloat
        var captionHeight: CGFloat
        var height: CGFloat
    }

    private var hasCaption: Bool { caption.map { !$0.isHidden && !$0.stringValue.isEmpty } ?? false }

    private var metrics: Metrics {
        let inner = width - 2 * DS.Space.s16
        var controlSize: CGSize = .zero
        if let control, !control.isHidden { controlSize = control.fittingSize }
        // A text control gets the same frame height as the title, so both draw their glyphs on the same pixel rows.
        if control is NSTextField, controlSize.width > 0 { controlSize.height = Self.titleStyle.lineHeight }
        let titleWidth = titleField.map { ceil($0.intrinsicContentSize.width) } ?? 0
        if control != nil {
            // The control keeps its natural width unless that would crowd the title out.
            controlSize.width = min(controlSize.width, max(inner - titleWidth - DS.Space.s12, 0))
        }
        let textWidth = inner - (controlSize.width > 0 ? controlSize.width + DS.Space.s12 : 0)
        var captionHeight: CGFloat = 0
        if hasCaption, let caption {
            captionHeight = caption.maximumNumberOfLines == 1
                ? DS.Text.caption.lineHeight
                : max(ceil(caption.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: textWidth, height: 10_000)).height ?? 0), DS.Text.caption.lineHeight)
        }
        let textHeight = (titleField == nil ? 0 : Self.titleStyle.lineHeight) + (captionHeight > 0 ? (titleField == nil ? 0 : DS.Space.s2) + captionHeight : 0)
        let height = max(Self.minHeight, textHeight + 2 * DS.Space.s12, controlSize.height + 2 * DS.Space.s8)
        return Metrics(controlSize: controlSize, textWidth: textWidth, captionHeight: captionHeight, height: height)
    }

    override var intrinsicContentSize: NSSize { NSSize(width: width, height: metrics.height) }

    override func layout() {
        super.layout()
        let m = metrics
        let x = DS.Space.s16
        // A label's text starts a fixed 2pt inside its frame; pulling the frame back puts the glyphs on the row's padding line.
        let inset = Form.labelInset
        var y = ((m.height - (titleField == nil ? 0 : Self.titleStyle.lineHeight) - (m.captionHeight > 0 ? (titleField == nil ? 0 : DS.Space.s2) + m.captionHeight : 0)) / 2).rounded()
        if let titleField {
            titleField.frame = CGRect(x: x - inset, y: y, width: m.textWidth + 2 * inset, height: Self.titleStyle.lineHeight)
            y += Self.titleStyle.lineHeight + DS.Space.s2
        }
        if let caption {
            if m.captionHeight > 0 { caption.frame = CGRect(x: x - inset, y: y, width: m.textWidth + 2 * inset, height: m.captionHeight) }
        }
        if let control, m.controlSize.width > 0 {
            // A right-aligned label's last glyph ends `inset` short of its frame, so its frame reaches past the padding line.
            let reach = control is NSTextField ? inset : 0
            control.frame = CGRect(x: width - x - m.controlSize.width + reach, y: ((m.height - m.controlSize.height) / 2).rounded(),
                                   width: m.controlSize.width, height: m.controlSize.height)
        }
    }
}

/// The grouped card: rows on a surface with a hairline between them, inset on the left.
final class FormCard: NSView {
    private(set) var rows: [FormRow]
    private var separators: [NSView] = []

    override var isFlipped: Bool { true }

    init(rows: [FormRow]) {
        self.rows = rows
        super.init(frame: .zero)
        for (i, row) in rows.enumerated() {
            addSubview(row)
            if i > 0 {
                let line = InsetSeparator()
                separators.append(line)
                addSubview(line)
            }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    func reflow() {
        rows.forEach { $0.invalidate() }
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    private var height: CGFloat { rows.reduce(0) { $0 + $1.intrinsicContentSize.height } + CGFloat(separators.count) }

    override var intrinsicContentSize: NSSize { NSSize(width: Form.cardWidth, height: height) }

    override func layout() {
        super.layout()
        var y: CGFloat = 0
        for (i, row) in rows.enumerated() {
            if i > 0 {
                separators[i - 1].frame = CGRect(x: 0, y: y, width: bounds.width, height: 1)
                y += 1
            }
            let h = row.intrinsicContentSize.height
            row.frame = CGRect(x: 0, y: y, width: bounds.width, height: h)
            y += h
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath.continuous(bounds, radius: DS.Radius.lg)
        DS.Color.bgSurface.setFill()
        path.fill()
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        DS.Color.borderSubtle.setStroke()
        path.lineWidth = 2
        path.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// A 1pt line that starts s16 in from the card's left edge and runs to its right edge.
private final class InsetSeparator: NSView {
    override func draw(_ dirtyRect: NSRect) {
        DS.Color.separator.setFill()
        NSRect(x: DS.Space.s16, y: 0, width: max(bounds.width - DS.Space.s16, 0), height: bounds.height).fill()
    }
}

/// A settings pane's content: the title, then the groups. Its frame is the fitted size at the fixed page width.
final class FormPage: NSView {
    private let stack = NSStackView()
    private var cards: [FormCard] = []

    override var isFlipped: Bool { true }

    init(title: String, groups: [Form.Group]) {
        super.init(frame: NSRect(x: 0, y: 0, width: Form.pageWidth, height: 100))
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = DS.Space.s24
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: DS.Space.s24),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: DS.Space.s24),
            stack.widthAnchor.constraint(equalToConstant: Form.cardWidth),
        ])

        let heading = NSTextField.label(title, style: DS.Text.title, color: DS.Color.textPrimary)
        stack.addArrangedSubview(heading)
        stack.setCustomSpacing(DS.Space.s16, after: heading)
        for group in groups {
            if let groupTitle = group.title {
                let label = NSTextField.label(groupTitle, style: DS.Text.captionStrong, color: DS.Color.textSecondary)
                stack.addArrangedSubview(label)
                stack.setCustomSpacing(DS.Space.s6, after: label)
            }
            let card = FormCard(rows: group.rows)
            card.translatesAutoresizingMaskIntoConstraints = false
            card.widthAnchor.constraint(equalToConstant: Form.cardWidth).isActive = true
            cards.append(card)
            stack.addArrangedSubview(card)
            if let footer = group.footer {
                stack.setCustomSpacing(DS.Space.s6, after: card)
                let note = Form.caption(footer)
                note.preferredMaxLayoutWidth = Form.cardWidth
                stack.addArrangedSubview(note)
            }
        }
        reflow()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Re-measures every row, then fits the page to its content.
    func reflow() {
        cards.forEach { $0.reflow() }
        stack.invalidateIntrinsicContentSize()
        layoutSubtreeIfNeeded()
        setFrameSize(NSSize(width: Form.pageWidth, height: ceil(stack.fittingSize.height) + 2 * DS.Space.s24))
        layoutSubtreeIfNeeded()
    }
}

enum Form {
    static let sidebarWidth: CGFloat = 200
    static let pageWidth: CGFloat = 760 - sidebarWidth
    static let cardWidth: CGFloat = pageWidth - 2 * DS.Space.s24
    /// How far a label's glyphs start inside its frame. Auto Layout already allows for it through the label's alignment rect;
    /// a frame set by hand has to.
    static let labelInset: CGFloat = 2

    struct Group {
        var title: String?
        var rows: [FormRow]
        var footer: String?

        init(_ title: String? = nil, rows: [FormRow], footer: String? = nil) {
            self.title = title
            self.rows = rows
            self.footer = footer
        }
    }

    static func page(title: String, groups: [Group]) -> FormPage { FormPage(title: title, groups: groups) }

    static func row(title: String, caption: NSTextField? = nil, control: NSView? = nil) -> FormRow {
        FormRow(title: title, caption: caption, control: control)
    }

    /// A wrapping caption. Pass the result to `row(title:caption:)` or set its string later: the row re-measures on `reflow()`.
    static func caption(_ text: String, color: NSColor = DS.Color.textSecondary) -> NSTextField {
        let t = NSTextField(wrappingLabelWithString: text)
        t.font = DS.Text.caption.font
        t.textColor = color
        t.isSelectable = false
        return t
    }

    static func hstack(_ views: [NSView], spacing: CGFloat = DS.Space.s8) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = .horizontal
        s.alignment = .centerY
        s.spacing = spacing
        return s
    }

    /// The design system's checkbox without a title: the row owns the visible label, so the box keeps it for accessibility.
    static func checkbox(_ title: String, id: String) -> Checkbox {
        let b = Checkbox(title: "")
        b.setAccessibilityLabel(title)
        b.setAccessibilityIdentifier(id)
        return b
    }

    static func popup(_ titles: [String], id: String) -> NSPopUpButton {
        let p = NSPopUpButton(frame: .zero, pullsDown: false)
        p.controlSize = .small
        p.font = DS.Text.label.font
        p.addItems(withTitles: titles)
        p.setAccessibilityIdentifier(id)
        return p
    }

    static func stepper(range: ClosedRange<Int>, id: String, suffix: String) -> (view: NSView, stepper: NSStepper, label: NSTextField) {
        let st = NSStepper()
        st.controlSize = .small
        st.minValue = Double(range.lowerBound); st.maxValue = Double(range.upperBound); st.increment = 1
        st.valueWraps = false
        st.setAccessibilityIdentifier(id)
        let label = NSTextField.label("", style: DS.Text.bodyStrong, color: DS.Color.textPrimary)
        label.alignment = .right
        label.setAccessibilityIdentifier(id + ".value")
        label.widthAnchor.constraint(equalToConstant: 72).isActive = true
        return (hstack([label, st], spacing: DS.Space.s8), st, label)
    }
}
