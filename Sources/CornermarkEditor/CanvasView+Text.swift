import AppKit
import CornermarkDesign
import CornermarkCore

extension CanvasView {
    /// Opens the inline editor on an existing text annotation under `source`, or on a fresh one there.
    func beginTextEdit(at source: CGPoint) {
        let tolerance = 4 / max(screenScale, 0.0001)
        let hit = model.document.annotations.last { ann in
            if case .text = ann.kind { return ann.hitTest(source, tolerance: tolerance) }
            return false
        }
        beginTextEdit(existing: hit, at: source)
    }

    func beginTextEdit(existing: Annotation?, at source: CGPoint = .zero) {
        commitText()
        var style = model.styles[.text] ?? EditorTool.text.spec.baseStyle
        var origin = source
        var string = ""
        if let e = existing, case .text(let o, let s, _, _) = e.kind {
            origin = o
            string = s
            style = e.style(base: style)
            model.styles[.text] = style
            model.select(e.id)
        }

        let tv = InlineTextView(frame: .zero)
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isHorizontallyResizable = true
        tv.isVerticallyResizable = true
        tv.textContainer?.widthTracksTextView = false
        tv.textContainer?.containerSize = NSSize(width: 1e7, height: 1e7)
        tv.textContainer?.lineFragmentPadding = 0
        tv.wantsLayer = true
        tv.delegate = self
        tv.setAccessibilityIdentifier("canvas.textEditor")
        tv.onCommit = { [weak self] in self?.commitText() }
        tv.string = string

        let session = Gesture.TextSession(id: existing?.id ?? UUID(), existing: existing, origin: origin, view: tv)
        gesture = .editingText(session)
        model.textEditing = true
        addSubview(tv)
        styleTextView(tv, style: style)
        layoutTextView(session)
        window?.makeFirstResponder(tv)
        tv.setSelectedRange(NSRange(location: (string as NSString).length, length: 0))
        invalidateAll()
    }

    func commitText() {
        guard case .editingText(let t) = gesture else { return }
        gesture = .idle
        model.textEditing = false
        let string = t.view.string
        t.view.removeFromSuperview()
        window?.makeFirstResponder(self)

        let style = model.styles[.text] ?? EditorTool.text.spec.baseStyle
        if string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let e = t.existing { model.perform(.remove(e.id)) }
        } else {
            let kind = AnnotationKind.text(origin: t.origin, string: string, fontSize: style.fontSize, style: style.textStyle)
            if var e = t.existing {
                e.kind = kind
                e.stroke = style.stroke
                model.perform(.update(e))
            } else {
                model.perform(.add(Annotation(id: t.id, kind: kind, stroke: style.stroke)))
            }
        }
        invalidateAll()
    }

    func restyleTextView() {
        guard case .editingText(let t) = gesture else { return }
        let style = model.styles[.text] ?? EditorTool.text.spec.baseStyle
        styleTextView(t.view, style: style)
        layoutTextView(t)
    }

    private static func padding(_ style: TextStylePreset, fontSize: CGFloat) -> NSSize {
        switch style {
        case .pill: return NSSize(width: fontSize * 0.55, height: fontSize * 0.28)
        case .banner: return NSSize(width: fontSize * 0.7, height: fontSize * 0.4)
        default: return .zero
        }
    }

    private func editorFont(_ style: ToolStyle, size: CGFloat) -> NSFont {
        switch style.textStyle {
        case .mono: return NSFont(name: "Menlo-Regular", size: size) ?? .monospacedSystemFont(ofSize: size, weight: .regular)
        case .plain: return .systemFont(ofSize: size)
        default: return .systemFont(ofSize: size, weight: .bold)
        }
    }

    private func styleTextView(_ tv: InlineTextView, style: ToolStyle) {
        let scale = canvasScale
        let size = CGFloat(style.fontSize) * scale
        let font = editorFont(style, size: size)
        let filled = style.textStyle == .pill || style.textStyle == .banner
        let color = style.color.cgColor.nsColor
        let textColor = filled ? style.color.contrasting.cgColor.nsColor : color
        let pad = Self.padding(style.textStyle, fontSize: size)

        tv.font = font
        tv.textColor = textColor
        tv.typingAttributes = [.font: font, .foregroundColor: textColor]
        tv.insertionPointColor = textColor
        tv.drawsBackground = filled
        tv.backgroundColor = filled ? color : .clear
        tv.textContainerInset = pad
        tv.layer?.cornerRadius = style.textStyle == .pill ? (size * 1.2 + pad.height * 2) / 2 : 0
        tv.layer?.borderWidth = 1 / max(magnification, 0.01)
        tv.layer?.borderColor = DS.Color.selectionStroke.cgColor
        tv.layer?.shadowColor = DS.Color.selectionHalo.cgColor
        tv.layer?.shadowOpacity = 1
        tv.layer?.shadowOffset = .zero
        tv.layer?.shadowRadius = 1 / max(magnification, 0.01)
    }

    func layoutTextView(_ t: Gesture.TextSession) {
        let tv = t.view
        guard let lm = tv.layoutManager, let tc = tv.textContainer else { return }
        lm.ensureLayout(for: tc)
        let used = lm.usedRect(for: tc)
        let inset = tv.textContainerInset
        let minWidth = (tv.font?.pointSize ?? 12) * 0.5
        let size = NSSize(width: max(used.width, minWidth) + inset.width * 2 + 2,
                          height: max(used.height, tv.font.map { lm.defaultLineHeight(for: $0) } ?? 12) + inset.height * 2)
        tv.setFrameSize(size)
        tv.setFrameOrigin(viewPoint(source: t.origin))
    }

    func textDidChange(_ notification: Notification) {
        guard case .editingText(let t) = gesture, notification.object as? NSTextView === t.view else { return }
        layoutTextView(t)
    }
}

extension CGColor {
    var nsColor: NSColor { NSColor(cgColor: self) ?? .black }
}
