import CoreGraphics
import Foundation
import XCTest
@testable import CornermarkCore

struct Px: Equatable, CustomStringConvertible {
    var r, g, b, a: Int
    var description: String { "(\(r),\(g),\(b),\(a))" }

    init(_ r: Int, _ g: Int, _ b: Int, _ a: Int = 255) { self.r = r; self.g = g; self.b = b; self.a = a }

    func isNear(_ o: Px, _ tol: Int = 6) -> Bool {
        abs(r - o.r) <= tol && abs(g - o.g) <= tol && abs(b - o.b) <= tol && abs(a - o.a) <= tol
    }
    func maxDiff(_ o: Px) -> Int { max(abs(r - o.r), abs(g - o.g), abs(b - o.b), abs(a - o.a)) }

    static let white = Px(255, 255, 255)
    static let black = Px(0, 0, 0)
    static let red = Px(255, 0, 0)
    static let green = Px(0, 255, 0)
    static let blue = Px(0, 0, 255)
}

/// Top-left origin, straight from the rendered CGImage's bytes.
struct Pixels {
    let width: Int
    let height: Int
    private let buffer: PixelBuffer

    init(_ image: CGImage) {
        buffer = PixelBuffer(image: image)!
        width = image.width
        height = image.height
    }

    subscript(x: Int, y: Int) -> Px {
        let p = buffer.pixel(x, y)
        return Px(Int(p.r), Int(p.g), Int(p.b), Int(p.a))
    }

    func count(in rect: CGRect? = nil, where predicate: (Px) -> Bool) -> Int {
        let r = (rect ?? CGRect(x: 0, y: 0, width: width, height: height)).integralClamped(to: CGRect(x: 0, y: 0, width: width, height: height))
        guard !r.isNull else { return 0 }
        var n = 0
        for y in Int(r.minY)..<Int(r.maxY) { for x in Int(r.minX)..<Int(r.maxX) where predicate(self[x, y]) { n += 1 } }
        return n
    }

    /// Pixels that differ between two same-size images, split by whether they fall inside `rect`.
    static func changed(_ a: Pixels, _ b: Pixels, inside rect: CGRect, threshold: Int = 0) -> (inside: Int, outside: Int) {
        precondition(a.width == b.width && a.height == b.height)
        var inside = 0, outside = 0
        for y in 0..<a.height {
            for x in 0..<a.width where a[x, y].maxDiff(b[x, y]) > threshold {
                if rect.contains(CGPoint(x: x, y: y)) { inside += 1 } else { outside += 1 }
            }
        }
        return (inside, outside)
    }
}

enum Fixture {
    static func image(width: Int, height: Int, draw: (CGContext) -> Void) -> CGImage {
        let ctx = Bitmap.makeContext(width: width, height: height, yDown: true)!
        draw(ctx)
        return ctx.makeImage()!
    }

    static func solid(_ w: Int, _ h: Int, _ c: RGBA) -> CGImage {
        image(width: w, height: h) { ctx in
            ctx.setFillColor(c.cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        }
    }

    /// Soft gradient, a block of 1px stripes, a checkerboard and real text: something redaction can destroy.
    static func detail(_ w: Int = 260, _ h: Int = 170) -> CGImage {
        image(width: w, height: h) { ctx in
            let grad = CGGradient(colorsSpace: Bitmap.sRGB,
                                  colors: [RGBA(0.86, 0.93, 1).cgColor, RGBA(1, 0.96, 0.88).cgColor] as CFArray,
                                  locations: [0, 1])!
            ctx.drawLinearGradient(grad, start: .zero, end: CGPoint(x: CGFloat(w), y: CGFloat(h)), options: [])
            ctx.setFillColor(RGBA(0.1, 0.1, 0.15).cgColor)
            for x in stride(from: 12, to: 120, by: 2) { ctx.fill(CGRect(x: x, y: 14, width: 1, height: 36)) }
            for row in 0..<6 { for col in 0..<10 where (row + col) % 2 == 0 {
                ctx.fill(CGRect(x: 140 + col * 6, y: 14 + row * 6, width: 6, height: 6))
            } }
            TextLayout(string: "Hello Cornermark 4821", fontSize: 15, style: .bold)
                .draw(at: CGPoint(x: 12, y: 68), color: RGBA(0.05, 0.05, 0.1), in: ctx)
            TextLayout(string: "account 0042 7781 9930", fontSize: 11, style: .mono)
                .draw(at: CGPoint(x: 12, y: 92), color: RGBA(0.2, 0.2, 0.25), in: ctx)
            ctx.setFillColor(RGBA(0.9, 0.35, 0.3).cgColor)
            ctx.fillEllipse(in: CGRect(x: 190, y: 90, width: 50, height: 50))
            ctx.setFillColor(RGBA(0.2, 0.5, 0.85).cgColor)
            ctx.fill(CGRect(x: 14, y: 120, width: 90, height: 34))
        }
    }

    static func document(_ image: CGImage, annotations: [Annotation] = [], pointScale: Double = 1) -> (Document, AssetStore) {
        let store = AssetStore()
        let id = store.add(image: image)!
        var doc = Document(base: id, pixelSize: CGSize(width: image.width, height: image.height), pointScale: pointScale)
        doc.annotations = annotations
        return (doc, store)
    }

    static func annotation(_ kind: AnnotationKind, color: RGBA = RGBA(0.9, 0.1, 0.1), width: Double = 4) -> Annotation {
        Annotation(kind: kind, stroke: Stroke(color: color, width: width))
    }

    static func randomRows(width: Int, height: Int, seed: UInt64) -> CGImage {
        var rng = SplitMix64(state: seed)
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for i in 0..<(width * height) {
            let v = rng.next()
            bytes[i * 4] = UInt8(truncatingIfNeeded: v)
            bytes[i * 4 + 1] = UInt8(truncatingIfNeeded: v >> 8)
            bytes[i * 4 + 2] = UInt8(truncatingIfNeeded: v >> 16)
        }
        return PixelBuffer(width: width, height: height, bytes: bytes).makeImage()!
    }
}

func render(_ doc: Document, _ store: AssetStore) -> Pixels { Pixels(Renderer.render(doc, assets: store)) }

func tempDirectory(_ name: String = #function) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("cornermark-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
