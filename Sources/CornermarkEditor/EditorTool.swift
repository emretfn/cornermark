import CoreGraphics
import Foundation
import CornermarkCore
import CornermarkL10n

public enum EditorTool: CaseIterable, Hashable, Sendable {
    case select, arrow, line, rect, filledRect, ellipse, filledEllipse
    case text, counter, pencil, highlighter, blur, pixelate, spotlight, crop, background
}

/// How a pointer gesture turns into an annotation.
enum InputModel {
    case select      // hit-test, move, resize
    case crop        // edits the crop draft
    case inert       // background: panel only
    case drag        // press, drag, release: two corner points
    case freehand    // every sampled point
    case click       // placed at the press point, may be dragged before release
    case text        // click opens the inline editor
}

/// What the canvas gesture carried, in source pixels.
struct DragInput {
    var start: CGPoint
    var end: CGPoint
    var points: [CGPoint]
    var constrain: Bool
}

struct ToolSpec {
    let title: LocalizedText
    let symbol: String
    let key: Character
    let input: InputModel
    let properties: [PropertyKind]
    let baseStyle: ToolStyle
    let hint: LocalizedText?
    let build: (DragInput, ToolStyle, _ nextCounter: Int) -> AnnotationKind?
    let matches: (AnnotationKind) -> Bool
}

extension EditorTool {
    var spec: ToolSpec { ToolRegistry.table[self]! }
    var name: String { String(describing: self) }

    /// The tool whose styling controls apply to an existing annotation.
    static func tool(for kind: AnnotationKind) -> EditorTool? {
        allCases.first { $0.spec.matches(kind) }
    }
}

private func snapped45(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
    let d = b - a, len = d.length
    guard len > 0 else { return b }
    let step = CGFloat.pi / 4
    let angle = (atan2(d.y, d.x) / step).rounded() * step
    return CGPoint(x: a.x + cos(angle) * len, y: a.y + sin(angle) * len)
}

private func squared(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
    let dx = b.x - a.x, dy = b.y - a.y
    let side = max(abs(dx), abs(dy))
    return CGPoint(x: a.x + (dx < 0 ? -side : side), y: a.y + (dy < 0 ? -side : side))
}

private func rect(_ a: CGPoint, _ b: CGPoint) -> CGRect {
    CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
}

private func endpoint(_ i: DragInput, line: Bool) -> CGPoint {
    i.constrain ? (line ? snapped45(i.start, i.end) : squared(i.start, i.end)) : i.end
}

enum ToolRegistry {
    private static func style(_ color: RGBA = Palette.red, width: Double = 5, font: Double = 32) -> ToolStyle {
        ToolStyle(color: color, width: width, fontSize: font)
    }

    private static let none: (DragInput, ToolStyle, Int) -> AnnotationKind? = { _, _, _ in nil }
    private static let never: (AnnotationKind) -> Bool = { _ in false }

    static let table: [EditorTool: ToolSpec] = [
        .select: ToolSpec(title: trKey("Select"), symbol: "cursorarrow", key: "v", input: .select, properties: [],
                          baseStyle: style(), hint: nil, build: none, matches: never),
        .arrow: ToolSpec(title: trKey("Arrow"), symbol: "arrow.up.right", key: "a", input: .drag,
                         properties: [.color, .width, .arrowStyle], baseStyle: style(width: 6), hint: nil,
                         build: { i, s, _ in .arrow(from: i.start, to: endpoint(i, line: true), control: nil, style: s.arrowStyle) },
                         matches: { if case .arrow = $0 { return true } else { return false } }),
        .line: ToolSpec(title: trKey("Line"), symbol: "line.diagonal", key: "l", input: .drag,
                        properties: [.color, .width], baseStyle: style(), hint: nil,
                        build: { i, _, _ in .line(from: i.start, to: endpoint(i, line: true)) },
                        matches: { if case .line = $0 { return true } else { return false } }),
        .rect: ToolSpec(title: trKey("Rectangle"), symbol: "rectangle", key: "r", input: .drag,
                        properties: [.color, .width], baseStyle: style(), hint: nil,
                        build: { i, _, _ in .rect(rect(i.start, endpoint(i, line: false)), filled: false, cornerRadius: 0) },
                        matches: { if case .rect(_, false, _) = $0 { return true } else { return false } }),
        .filledRect: ToolSpec(title: trKey("Filled Rectangle"), symbol: "rectangle.fill", key: "r", input: .drag,
                              properties: [.color], baseStyle: style(), hint: nil,
                              build: { i, _, _ in .rect(rect(i.start, endpoint(i, line: false)), filled: true, cornerRadius: 0) },
                              matches: { if case .rect(_, true, _) = $0 { return true } else { return false } }),
        .ellipse: ToolSpec(title: trKey("Ellipse"), symbol: "circle", key: "o", input: .drag,
                           properties: [.color, .width], baseStyle: style(), hint: nil,
                           build: { i, _, _ in .ellipse(rect(i.start, endpoint(i, line: false)), filled: false) },
                           matches: { if case .ellipse(_, false) = $0 { return true } else { return false } }),
        .filledEllipse: ToolSpec(title: trKey("Filled Ellipse"), symbol: "circle.fill", key: "o", input: .drag,
                                 properties: [.color], baseStyle: style(), hint: nil,
                                 build: { i, _, _ in .ellipse(rect(i.start, endpoint(i, line: false)), filled: true) },
                                 matches: { if case .ellipse(_, true) = $0 { return true } else { return false } }),
        .text: ToolSpec(title: trKey("Text"), symbol: "textformat", key: "t", input: .text,
                        properties: [.color, .textStyle, .fontSize], baseStyle: style(font: 32), hint: nil,
                        build: none, matches: { if case .text = $0 { return true } else { return false } }),
        .counter: ToolSpec(title: trKey("Counter"), symbol: "1.circle", key: "n", input: .click,
                           properties: [.color, .width], baseStyle: style(width: 6), hint: nil,
                           build: { i, s, n in .counter(center: i.end, number: n, radius: max(8, s.width * 2.5)) },
                           matches: { if case .counter = $0 { return true } else { return false } }),
        .pencil: ToolSpec(title: trKey("Pencil"), symbol: "pencil.tip", key: "p", input: .freehand,
                          properties: [.color, .width], baseStyle: style(width: 4), hint: nil,
                          build: { i, _, _ in .pencil(points: i.points) },
                          matches: { if case .pencil = $0 { return true } else { return false } }),
        .highlighter: ToolSpec(title: trKey("Highlighter"), symbol: "highlighter", key: "h", input: .freehand,
                               properties: [.color, .width], baseStyle: style(Palette.yellow, width: 24), hint: nil,
                               build: { i, _, _ in .highlighter(points: i.points) },
                               matches: { if case .highlighter = $0 { return true } else { return false } }),
        .blur: ToolSpec(title: trKey("Blur"), symbol: "drop.halffull", key: "b", input: .drag,
                        properties: [.blurMode], baseStyle: style(), hint: nil,
                        build: { i, s, _ in .blur(rect(i.start, endpoint(i, line: false)), mode: s.blurMode) },
                        matches: { if case .blur = $0 { return true } else { return false } }),
        .pixelate: ToolSpec(title: trKey("Pixelate"), symbol: "squareshape.split.3x3", key: "x", input: .drag,
                            properties: [.pixelBlock], baseStyle: style(), hint: nil,
                            build: { i, s, _ in .pixelate(rect(i.start, endpoint(i, line: false)), blockSize: s.pixelBlock, seed: .random(in: 1...UInt64.max)) },
                            matches: { if case .pixelate = $0 { return true } else { return false } }),
        .spotlight: ToolSpec(title: trKey("Spotlight"), symbol: "flashlight.on.fill", key: "s", input: .drag,
                             properties: [], baseStyle: style(), hint: trKey("Drag to light up an area and dim the rest"),
                             build: { i, _, _ in .spotlight(rect(i.start, endpoint(i, line: false))) },
                             matches: { if case .spotlight = $0 { return true } else { return false } }),
        .crop: ToolSpec(title: trKey("Crop"), symbol: "crop", key: "c", input: .crop, properties: [],
                        baseStyle: style(), hint: nil, build: none, matches: never),
        .background: ToolSpec(title: trKey("Background"), symbol: "photo.artframe", key: "g", input: .inert, properties: [],
                              baseStyle: style(), hint: nil, build: none, matches: never),
    ]

    /// Shortcut letters shared by two tools (R, O) pick the outline variant; Shift picks the filled one.
    static func tool(forKey key: Character, shift: Bool) -> EditorTool? {
        let hits = EditorTool.allCases.filter { $0.spec.key == key }
        guard !hits.isEmpty else { return nil }
        return shift && hits.count > 1 ? hits.last : hits.first
    }
}
