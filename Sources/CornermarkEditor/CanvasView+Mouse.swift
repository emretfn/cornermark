import AppKit
import CornermarkCore

extension CanvasView {
    /// Pointer travel, in screen points, before a press turns into a drag.
    private static let dragThreshold: CGFloat = 3

    override func mouseDown(with event: NSEvent) {
        if case .editingText = gesture { commitText() }
        window?.makeFirstResponder(self)
        let v = convert(event.locationInWindow, from: nil)
        let src = sourcePoint(v)
        let shift = event.modifierFlags.contains(.shift)

        switch model.tool.spec.input {
        case .select: pressSelect(v, src, clicks: event.clickCount, shift: shift)
        case .crop: pressCrop(v)
        case .inert: break
        case .drag, .freehand, .click, .text:
            model.select(nil)
            let input = DragInput(start: src, end: src, points: [src], constrain: shift)
            var drawing = Gesture.Drawing(tool: model.tool, startView: v, input: input)
            if model.tool.spec.input == .click { drawing.engaged = true }
            if drawing.engaged { drawing.provisional = provisionalAnnotation(drawing) }
            gesture = .drawing(drawing)
            if drawing.engaged { updateLive(drawing.provisional) }
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let v = convert(event.locationInWindow, from: nil)
        let src = sourcePoint(v)
        let shift = event.modifierFlags.contains(.shift)

        switch gesture {
        case .drawing(var d):
            d.input.end = src
            d.input.constrain = shift
            if d.tool.spec.input == .freehand,
               d.input.points.last.map({ $0.distance(to: src) * screenScale >= 1 }) ?? true {
                d.input.points.append(src)
            }
            if !d.engaged, v.distance(to: d.startView) * magnification >= Self.dragThreshold { d.engaged = true }
            if d.engaged { d.provisional = provisionalAnnotation(d) }
            gesture = .drawing(d)
            if d.engaged { updateLive(d.provisional) }

        case .moving(var m):
            if !m.engaged, v.distance(to: m.startView) * magnification >= Self.dragThreshold {
                m.engaged = true
                lastLiveDirty = m.original.bounds.inflated(8)
            }
            if m.engaged {
                let delta = src - m.grab
                m.current = m.original.translated(by: CGVector(dx: delta.x, dy: delta.y))
                gesture = .moving(m)
                updateLive(m.current, original: m.original)
            } else {
                gesture = .moving(m)
            }

        case .resizing(var r):
            r.current = r.original.dragging(r.handle, to: src, constrain: shift)
            gesture = .resizing(r)
            updateLive(r.current, original: r.original)

        case .cropping(let drag):
            dragCrop(drag, to: v, shift: shift)

        case .idle, .editingText:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        let v = convert(event.locationInWindow, from: nil)
        switch gesture {
        case .drawing(let d):
            gesture = .idle
            lastLiveDirty = nil
            switch d.tool.spec.input {
            case .text:
                if !d.engaged { beginTextEdit(at: d.input.start) }
            default:
                if d.engaged, let ann = provisionalAnnotation(d) { model.perform(.add(ann)) }
            }
            invalidateAll()

        case .moving(let m):
            gesture = .idle
            lastLiveDirty = nil
            if m.engaged { model.perform(.update(m.current)) }
            invalidateAll()

        case .resizing(let r):
            gesture = .idle
            lastLiveDirty = nil
            model.perform(.update(r.current))
            invalidateAll()

        case .cropping:
            gesture = .idle
            invalidateAll()

        case .idle, .editingText:
            break
        }
        _ = v
    }

    private func pressSelect(_ v: CGPoint, _ src: CGPoint, clicks: Int, shift: Bool) {
        if let selected = model.selectedAnnotation, let handle = handle(of: selected, at: v) {
            gesture = .resizing(Gesture.Resizing(original: selected, handle: handle, current: selected))
            return
        }
        let tolerance = 6 / max(screenScale, 0.0001)
        guard let id = model.document.annotationID(at: src, tolerance: tolerance),
              let ann = model.document.annotations.first(where: { $0.id == id }) else {
            model.select(nil)
            return
        }
        model.select(id)
        if clicks >= 2, case .text = ann.kind {
            beginTextEdit(existing: ann)
            return
        }
        gesture = .moving(Gesture.Moving(original: ann, grab: src, startView: v, current: ann))
    }

    private func handle(of ann: Annotation, at v: CGPoint) -> Handle.Kind? {
        let reach = 9 / max(magnification, 0.01)
        return ann.handles.first { viewPoint(source: $0.position).distance(to: v) <= reach }?.kind
    }

    func provisionalAnnotation(_ d: Gesture.Drawing) -> Annotation? {
        let spec = d.tool.spec
        let style = model.styles[d.tool] ?? spec.baseStyle
        guard let kind = spec.build(d.input, style, model.nextCounterNumber) else { return nil }
        guard let existing = d.provisional else { return Annotation(kind: kind, stroke: style.stroke) }
        var stable = kind
        // A fresh random seed per mouse move would make the pixelate preview shimmer.
        if case .pixelate(let r, let b, _) = kind, case .pixelate(_, _, let seed) = existing.kind {
            stable = .pixelate(r, blockSize: b, seed: seed)
        }
        return Annotation(id: existing.id, kind: stable, stroke: style.stroke)
    }
}
