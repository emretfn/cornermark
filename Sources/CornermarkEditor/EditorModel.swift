import CoreGraphics
import Foundation
import CornermarkCore
import CornermarkL10n

struct Change: OptionSet {
    let rawValue: Int
    static let document = Change(rawValue: 1)
    static let selection = Change(rawValue: 2)
    static let tool = Change(rawValue: 4)
    static let style = Change(rawValue: 8)
    static let crop = Change(rawValue: 16)
    static let all: Change = [.document, .selection, .tool, .style, .crop]
}

enum CropAspect: CaseIterable {
    case free, original, square, fourThree, threeTwo, sixteenNine, nineSixteen

    var title: String {
        switch self {
        case .free: return tr("Free")
        case .original: return tr("Original")
        case .square: return "1:1"
        case .fourThree: return "4:3"
        case .threeTwo: return "3:2"
        case .sixteenNine: return "16:9"
        case .nineSixteen: return "9:16"
        }
    }
    /// width / height, or nil when unconstrained. `.original` takes the displayed canvas ratio.
    func ratio(original: CGSize) -> CGFloat? {
        switch self {
        case .free: return nil
        case .original: return original.height > 0 ? original.width / original.height : nil
        case .square: return 1
        case .fourThree: return 4.0 / 3
        case .threeTwo: return 1.5
        case .sixteenNine: return 16.0 / 9
        case .nineSixteen: return 9.0 / 16
        }
    }
}

/// The crop rectangle being edited, in source pixels so rotating or flipping mid-edit keeps it attached to the content.
struct CropDraft: Equatable {
    var rect: CGRect
    var aspect: CropAspect = .free
}

/// Editor state shared by the canvas, toolbar and panels. Documents change only through `perform`.
final class EditorModel {
    private(set) var history: EditHistory
    let assets: AssetStore
    let prefs: EditorPreferences
    private(set) var revision = 0
    var onChange: ((Change) -> Void)?

    private(set) var tool: EditorTool = .select
    private(set) var selection: UUID?
    private(set) var cropDraft: CropDraft?
    var styles: [EditorTool: ToolStyle]
    /// While the inline text editor is open, style edits only retarget the editor; the annotation is written on commit.
    var textEditing = false

    init(document: Document, assets: AssetStore, prefs: EditorPreferences) {
        history = EditHistory(document)
        self.assets = assets
        self.prefs = prefs
        let scale = max(1, (max(document.pixelSize.width, document.pixelSize.height) / 1400).rounded())
        styles = Dictionary(uniqueKeysWithValues: EditorTool.allCases.map { tool in
            var s = tool.spec.baseStyle
            s.width *= scale
            s.fontSize *= scale
            s.pixelBlock = Int(Double(s.pixelBlock) * scale)
            return (tool, s)
        })
    }

    var document: Document { history.present }
    var selectedAnnotation: Annotation? { selection.flatMap { id in document.annotations.first { $0.id == id } } }

    func perform(_ command: EditCommand, coalescing key: CoalescingKey? = nil) {
        let before = history.present
        history.apply(command, coalescing: key)
        didEdit(from: before)
    }

    @discardableResult func undo() -> Bool {
        let before = history.present
        let ok = history.undo()
        didEdit(from: before)
        return ok
    }

    @discardableResult func redo() -> Bool {
        let before = history.present
        let ok = history.redo()
        didEdit(from: before)
        return ok
    }

    func endCoalescing() { history.endCoalescing() }

    private func didEdit(from before: Document) {
        guard history.present != before else { return }
        revision += 1
        var change: Change = .document
        if let id = selection, !history.present.annotations.contains(where: { $0.id == id }) {
            selection = nil
            change.insert(.selection)
        }
        if cropDraft != nil, history.present.pixelSize != before.pixelSize { cropDraft = nil }
        notify(change)
    }

    func select(_ id: UUID?) {
        guard id != selection else { return }
        history.endCoalescing()
        selection = id
        notify(.selection)
    }

    func setTool(_ new: EditorTool) {
        guard new != tool else { return }
        history.endCoalescing()
        tool = new
        selection = nil
        if new == .crop {
            cropDraft = CropDraft(rect: document.crop ?? document.sourceBounds)
        } else {
            cropDraft = nil
        }
        notify([.tool, .selection, .crop])
    }

    func setCropDraft(_ draft: CropDraft?) {
        cropDraft = draft
        notify(.crop)
    }

    /// Style the property bar edits: the selected annotation's tool, or the active tool.
    var styleTool: EditorTool {
        if let ann = selectedAnnotation, let t = EditorTool.tool(for: ann.kind) { return t }
        return tool
    }

    var activeStyle: ToolStyle {
        if let ann = selectedAnnotation { return ann.style(base: styles[styleTool] ?? tool.spec.baseStyle) }
        return styles[tool] ?? tool.spec.baseStyle
    }

    func editStyle(_ edit: (inout ToolStyle) -> Void, key: String) {
        let target = styleTool
        var s = activeStyle
        edit(&s)
        styles[target] = s
        if let ann = selectedAnnotation, !textEditing {
            perform(.update(ann.restyled(s)), coalescing: CoalescingKey("style.\(key).\(ann.id)"))
        }
        notify(.style)
    }

    /// Smallest positive number no counter uses yet.
    var nextCounterNumber: Int {
        let used = Set(document.annotations.compactMap { ann -> Int? in
            if case .counter(_, let n, _) = ann.kind { return n } else { return nil }
        })
        return (1...).first { !used.contains($0) }!
    }

    func notify(_ change: Change) { onChange?(change) }
}
