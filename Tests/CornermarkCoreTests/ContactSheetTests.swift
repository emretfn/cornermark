import CoreGraphics
import Foundation
import XCTest
@testable import CornermarkCore

/// Writes a PNG with every annotation kind for a human to inspect.
/// Set CORNERMARK_CONTACT_SHEET to choose the output path.
final class ContactSheetTests: XCTestCase {
    private struct Tile {
        let label: String
        let annotations: [Annotation]
        var background: BackgroundStyle?
        var geometry: ((inout Document) -> Void)?
    }

    private func a(_ kind: AnnotationKind, _ color: RGBA = RGBA(0.92, 0.18, 0.2), _ width: Double = 5) -> Annotation {
        Fixture.annotation(kind, color: color, width: width)
    }

    private func tiles(patch: AssetID) -> [Tile] {
        let blue = RGBA(0.1, 0.35, 0.9), yellow = RGBA(1, 0.9, 0.1), ink = RGBA(0.08, 0.08, 0.1)
        let from = CGPoint(x: 30, y: 150), to = CGPoint(x: 225, y: 100)
        var out: [Tile] = []
        var wave: [CGPoint] = []
        for i in 0..<12 { wave.append(CGPoint(x: 20.0 + Double(i) * 20, y: 85.0 + 50.0 * sin(Double(i) * 0.9))) }
        for style in ArrowStyle.allCases {
            out.append(Tile(label: "arrow \(style.rawValue)", annotations: [a(.arrow(from: from, to: to, control: CGPoint(x: 90, y: 60), style: style))]))
        }
        out += [
            Tile(label: "line", annotations: [a(.line(from: CGPoint(x: 20, y: 20), to: CGPoint(x: 240, y: 70)), blue)]),
            Tile(label: "rect", annotations: [a(.rect(CGRect(x: 40, y: 40, width: 170, height: 90), filled: false, cornerRadius: 0))]),
            Tile(label: "rect filled", annotations: [a(.rect(CGRect(x: 40, y: 40, width: 170, height: 90), filled: true, cornerRadius: 0), RGBA(0.1, 0.6, 0.4, 0.85))]),
            Tile(label: "rect rounded", annotations: [a(.rect(CGRect(x: 40, y: 40, width: 170, height: 90), filled: false, cornerRadius: 28), blue)]),
            Tile(label: "ellipse", annotations: [a(.ellipse(CGRect(x: 40, y: 40, width: 170, height: 90), filled: false))]),
            Tile(label: "ellipse filled", annotations: [a(.ellipse(CGRect(x: 40, y: 40, width: 170, height: 90), filled: true), RGBA(0.5, 0.2, 0.8, 0.85))]),
        ]
        for style in TextStylePreset.allCases {
            out.append(Tile(label: "text \(style.rawValue)", annotations: [a(.text(origin: CGPoint(x: 24, y: 50), string: "Cornermark text\nTLq 123", fontSize: 28, style: style), style == .outlined ? RGBA(1, 1, 1) : blue)]))
        }
        out += [
            Tile(label: "counter", annotations: [a(.counter(center: CGPoint(x: 60, y: 80), number: 1, radius: 20), blue), a(.counter(center: CGPoint(x: 130, y: 80), number: 12, radius: 20)), a(.counter(center: CGPoint(x: 200, y: 80), number: 345, radius: 20), ink)]),
            Tile(label: "pencil", annotations: [a(.pencil(points: wave), RGBA(0.1, 0.5, 0.2), 4)]),
            Tile(label: "highlighter", annotations: [a(.highlighter(points: [CGPoint(x: 10, y: 74), CGPoint(x: 120, y: 72), CGPoint(x: 250, y: 76)]), yellow, 22)]),
            Tile(label: "blur smooth", annotations: [a(.blur(CGRect(x: 8, y: 60, width: 150, height: 52), mode: .smooth))]),
            Tile(label: "blur secure", annotations: [a(.blur(CGRect(x: 8, y: 60, width: 150, height: 52), mode: .secure))]),
            Tile(label: "pixelate seed 1", annotations: [a(.pixelate(CGRect(x: 8, y: 60, width: 150, height: 52), blockSize: 7, seed: 1))]),
            Tile(label: "pixelate seed 2", annotations: [a(.pixelate(CGRect(x: 8, y: 60, width: 150, height: 52), blockSize: 7, seed: 2))]),
            Tile(label: "spotlight", annotations: [a(.spotlight(CGRect(x: 60, y: 40, width: 140, height: 90)))]),
            Tile(label: "image", annotations: [a(.image(CGRect(x: 60, y: 40, width: 140, height: 90), asset: patch))]),
            Tile(label: "crop + rotate cw", annotations: [a(.arrow(from: CGPoint(x: 30, y: 150), to: CGPoint(x: 120, y: 105), control: nil, style: .classic))], background: nil) { doc in
                doc.crop = CGRect(x: 10, y: 60, width: 200, height: 100)
                doc.geometry.quarterTurns = 1
            },
            Tile(label: "bg + flipH + text", annotations: [a(.text(origin: CGPoint(x: 20, y: 120), string: "Hello", fontSize: 26, style: .pill), blue)], background: BackgroundStyle()) { doc in
                doc.geometry.flipH = true
            },
        ]
        for i in [0, 2, 8, 14, 18] {
            var bg = BackgroundStyle()
            bg.fill = .builtin(index: i); bg.padding = 36; bg.cornerRadius = 14
            out.append(Tile(label: "background \(i) \(BuiltinBackgrounds.all[i].name)", annotations: [], background: bg))
        }
        return out
    }

    func testWriteContactSheet() throws {
        let store = AssetStore()
        let patch = store.add(image: Fixture.image(width: 40, height: 24) { ctx in
            ctx.setFillColor(RGBA(0.1, 0.4, 0.9).cgColor); ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 12))
            ctx.setFillColor(RGBA(1, 0.6, 0.1).cgColor); ctx.fill(CGRect(x: 0, y: 12, width: 40, height: 12))
            ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fillEllipse(in: CGRect(x: 14, y: 6, width: 12, height: 12))
        })!
        let baseImage = Fixture.detail()
        let baseID = store.add(image: baseImage)!

        var rendered: [(String, CGImage)] = []
        for tile in tiles(patch: patch) {
            var doc = Document(base: baseID, pixelSize: CGSize(width: baseImage.width, height: baseImage.height), pointScale: 2)
            doc.annotations = tile.annotations
            doc.background = tile.background
            tile.geometry?(&doc)
            rendered.append((tile.label, Renderer.render(doc, assets: store)))
        }

        let cols = 5, cell = CGSize(width: 330, height: 280), label: CGFloat = 26, pad: CGFloat = 18
        let rows = (rendered.count + cols - 1) / cols
        let sheetW = Int(CGFloat(cols) * cell.width + pad), sheetH = Int(CGFloat(rows) * cell.height + pad)
        let ctx = Bitmap.makeContext(width: sheetW, height: sheetH, yDown: true)!
        ctx.setFillColor(RGBA(0.93, 0.93, 0.95).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: sheetW, height: sheetH))

        for (i, (name, image)) in rendered.enumerated() {
            let col = i % cols, row = i / cols
            let x = pad + CGFloat(col) * cell.width, y = pad + CGFloat(row) * cell.height
            let scale = min((cell.width - pad) / CGFloat(image.width), (cell.height - pad - label) / CGFloat(image.height), 1)
            let rect = CGRect(x: x, y: y + label, width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
            TextLayout(string: name, fontSize: 13, style: .bold).draw(at: CGPoint(x: x, y: y + 2), color: RGBA(0.15, 0.15, 0.2), in: ctx)
            ctx.drawImageYDown(image, in: rect)
        }

        let path = ProcessInfo.processInfo.environment["CORNERMARK_CONTACT_SHEET"]
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("cornermark-core-contact-sheet.png").path
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let png = try XCTUnwrap(AssetStore.pngData(from: ctx.makeImage()!))
        try png.write(to: url)
        XCTAssertGreaterThan(png.count, 50_000)
        print("contact sheet: \(url.path)")
    }
}
