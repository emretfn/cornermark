import AppKit

final class TextInputCell: NSTextFieldCell {
    var isCentered = false

    /// A one-line box centred vertically in the cell, so the text and the field editor land on the same baseline.
    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        let metrics = font ?? DS.Text.body.font
        let line = ceil(metrics.ascender - metrics.descender + metrics.leading)
        var inner = rect.insetBy(dx: isCentered ? 0 : DS.Space.s8, dy: 0)
        // Centres the capitals and digits rather than the font's line box, which sits them about 1pt low.
        let capCentre = metrics.ascender - metrics.capHeight / 2
        inner.origin.y += ((inner.height / 2 - capCentre) * 2).rounded() / 2
        inner.size.height = line
        return inner
    }

    override func edit(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, event: NSEvent?) {
        super.edit(withFrame: drawingRect(forBounds: rect), in: controlView, editor: textObj, delegate: delegate, event: event)
        followDirection(of: controlView, editor: textObj)
    }

    override func select(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, start selStart: Int, length selLength: Int) {
        super.select(withFrame: drawingRect(forBounds: rect), in: controlView, editor: textObj, delegate: delegate, start: selStart, length: selLength)
        followDirection(of: controlView, editor: textObj)
    }

    /// The shared field editor is created for the app's launch direction, so an empty field in a right-to-left language would put its
    /// caret on the left. Telling it the field's direction puts the caret and the text against the right edge.
    private func followDirection(of controlView: NSView, editor: NSText) {
        editor.baseWritingDirection = controlView.isRightToLeft ? .rightToLeft : .natural
    }
}

public final class TextInput: NSTextField {
    public let size: ComponentSize
    private let style: TextStyle
    private let placeholder: String

    public override class var cellClass: AnyClass? {
        get { TextInputCell.self }
        set {}
    }

    public init(placeholder: String, size: ComponentSize = .regular, monospaced: Bool = false, centered: Bool = false) {
        self.size = size
        self.placeholder = placeholder
        style = monospaced ? DS.Text.readout : (size == .small ? DS.Text.label : DS.Text.body)
        super.init(frame: .zero)
        isBordered = false
        isBezeled = false
        drawsBackground = false
        focusRingType = .exterior
        usesSingleLineMode = true
        font = style.font
        alignment = centered ? .center : .natural
        (cell as? TextInputCell)?.isCentered = centered
        applyColors()
        frame.size = NSSize(width: 0, height: size.height)
    }

    public required init?(coder: NSCoder) { fatalError("TextInput is created in code") }

    public override var isEnabled: Bool {
        didSet { applyColors() }
    }

    public override var userInterfaceLayoutDirection: NSUserInterfaceLayoutDirection {
        didSet {
            guard oldValue != userInterfaceLayoutDirection else { return }
            // Natural alignment follows the script of the text, which would leave an English name against the left edge of a right-to-left field.
            if alignment != .center { alignment = isRightToLeft ? .right : .natural }
            baseWritingDirection = isRightToLeft ? .rightToLeft : .natural
            needsDisplay = true
        }
    }

    private func applyColors() {
        textColor = isEnabled ? DS.Color.textPrimary : DS.Color.textDisabled
        placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [
            .font: style.font, .foregroundColor: isEnabled ? DS.Color.textSecondary : DS.Color.textDisabled,
        ])
        needsDisplay = true
    }

    public override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: size.height) }

    // NSTextField reports a 2pt alignment inset, which would push the drawn field out of line with its neighbours in a stack.
    public override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsets() }

    private var shape: NSBezierPath { .continuous(bounds, radius: DS.Radius.sm) }

    public override func draw(_ dirtyRect: NSRect) {
        Paint.fill(shape, DS.Color.bgControl)
        super.draw(dirtyRect)
    }

    public override func drawFocusRingMask() { shape.fill() }
    public override var focusRingMaskBounds: NSRect { bounds }
}
