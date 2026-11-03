import AppKit
import CoreGraphics
import CornermarkCore

/// The one in-progress pointer interaction. Points named `source` are source pixels,
/// `canvas` are display canvas pixels, `view` are CanvasView coordinates.
enum Gesture {
    case idle
    case drawing(Drawing)
    case moving(Moving)
    case resizing(Resizing)
    case cropping(CropDrag)
    case editingText(TextSession)

    struct Drawing {
        var tool: EditorTool
        var startView: CGPoint
        var input: DragInput
        var engaged = false
        var provisional: Annotation?
    }

    struct Moving {
        var original: Annotation
        var grab: CGPoint
        var startView: CGPoint
        var current: Annotation
        var engaged = false
    }

    struct Resizing {
        var original: Annotation
        var handle: Handle.Kind
        var current: Annotation
    }

    enum CropDrag {
        case fresh(anchor: CGPoint)
        case move(grab: CGPoint, original: CGRect)
        case resize(x: Int, y: Int, original: CGRect)
    }

    struct TextSession {
        var id: UUID
        var existing: Annotation?
        var origin: CGPoint
        var view: InlineTextView
    }
}

/// Where a live preview of the active annotation gets painted.
enum PreviewStrategy {
    /// Painted alone on a transparent layer over the cached composite of everything else.
    case overlay(multiply: Bool)
    /// Dims everything outside the rect; painted directly because its layer would span the whole image.
    case spotlight
    /// Reads pixels underneath, so the whole composite is rebuilt.
    case rebuild
    /// A frosted outline standing in for a redaction too big to recompute every mouse move.
    case frosted

    /// Redactions larger than this (source pixels squared) preview as `.frosted` and render for real on release.
    static let liveRedactionArea: CGFloat = 160_000

    /// Above this many source pixels even a small redaction rebuilds too much composite per mouse move.
    static let liveImageArea: CGFloat = 3_000_000

    static func of(_ kind: AnnotationKind, imageArea: CGFloat) -> PreviewStrategy {
        switch kind {
        case .highlighter: return .overlay(multiply: true)
        case .blur(let r, _), .pixelate(let r, _, _): return r.width * r.height > liveRedactionArea || imageArea > liveImageArea ? .frosted : .rebuild
        case .spotlight: return .spotlight
        default: return .overlay(multiply: false)
        }
    }
}

final class InlineTextView: NSTextView {
    var onCommit: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        if isReturn, event.modifierFlags.contains(.command) { onCommit?(); return }
        if event.keyCode == 53 { onCommit?(); return }
        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) { onCommit?() }
}
