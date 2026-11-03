import CoreGraphics
import XCTest
@testable import CornermarkCore

final class LayoutAndBackgroundTests: XCTestCase {
    private func marked(_ w: Int, _ h: Int) -> (CGImage, red: CGRect, green: CGRect) {
        let red = CGRect(x: 30, y: 10, width: 6, height: 6)
        let green = CGRect(x: w - 20, y: h - 14, width: 8, height: 4)
        let image = Fixture.image(width: w, height: h) { ctx in
            ctx.setFillColor(RGBA(1, 1, 1).cgColor); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.setFillColor(RGBA(1, 0, 0).cgColor); ctx.fill(red)
            ctx.setFillColor(RGBA(0, 1, 0).cgColor); ctx.fill(green)
        }
        return (image, red, green)
    }

    func testCropThenRotateGivesExpectedSizeAndMovesKnownPixel() {
        let image = Fixture.image(width: 200, height: 100) { ctx in
            ctx.setFillColor(RGBA(1, 1, 1).cgColor); ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
            ctx.setFillColor(RGBA(1, 0, 0).cgColor); ctx.fill(CGRect(x: 150, y: 20, width: 6, height: 6))
        }
        var (doc, store) = Fixture.document(image)
        doc = doc.applying(.setCrop(CGRect(x: 100, y: 10, width: 100, height: 80)))
        doc = doc.applying(.rotateClockwise)

        let out = render(doc, store)
        XCTAssertEqual(out.width, 80)
        XCTAssertEqual(out.height, 100)
        // Crop-local (50..<56, 10..<16); a clockwise turn sends (x, y) to (80 - y, x).
        XCTAssertEqual(out.count { $0 == .red }, 36)
        XCTAssertEqual(out.count(in: CGRect(x: 64, y: 50, width: 6, height: 6)) { $0 == .red }, 36)
        XCTAssertEqual(out[67, 53], .red)
        XCTAssertEqual(out[10, 10], .white)
    }

    func testEveryTurnAndFlipCombinationKeepsMarkersWhereSourceToCanvasSays() {
        let (image, red, green) = marked(120, 80)
        for turns in 0..<4 { for flipH in [false, true] { for flipV in [false, true] {
            var (doc, store) = Fixture.document(image)
            doc.geometry.quarterTurns = turns; doc.geometry.flipH = flipH; doc.geometry.flipV = flipV
            doc.crop = CGRect(x: 5, y: 3, width: 112, height: 70)
            var bg = BackgroundStyle()
            bg.fill = .solid(RGBA(0, 0, 1)); bg.padding = 17; bg.shadow = false; bg.cornerRadius = 0; bg.aspectRatio = 1.4
            doc.background = bg
            doc.outputScale = 2

            let out = render(doc, store)
            let size = Renderer.canvasSize(doc)
            XCTAssertEqual(CGFloat(out.width), size.width)
            XCTAssertEqual(CGFloat(out.height), size.height)
            let t = Renderer.sourceToCanvas(doc)
            for (rect, expected) in [(red, Px.red), (green, Px.green)] {
                let p = CGPoint(x: rect.midX, y: rect.midY).applying(t)
                XCTAssertEqual(out[Int(p.x), Int(p.y)], expected, "turns \(turns) H\(flipH) V\(flipV) at \(p)")
            }
            let blank = CGPoint(x: 60, y: 40).applying(t)
            XCTAssertEqual(out[Int(blank.x), Int(blank.y)], .white)
            let back = p(Renderer.canvasToSource(doc), at: CGPoint(x: blank.x, y: blank.y))
            XCTAssertEqual(back.x, 60, accuracy: 1e-6)
            XCTAssertEqual(back.y, 40, accuracy: 1e-6)
        } } }
    }

    private func p(_ t: CGAffineTransform, at point: CGPoint) -> CGPoint { point.applying(t) }

    func testSourceToCanvasHandWorkedExampleWithBackgroundRotationAndScale() {
        let (image, red, _) = marked(120, 80)
        var (doc, store) = Fixture.document(image)
        doc.geometry.quarterTurns = 1
        var bg = BackgroundStyle()
        bg.fill = .solid(RGBA(0, 0, 1)); bg.padding = 30; bg.shadow = false; bg.cornerRadius = 0
        doc.background = bg
        doc.outputScale = 2

        XCTAssertEqual(Renderer.canvasSize(doc), CGSize(width: 280, height: 360))
        // Source (33, 13): clockwise turn gives (80 - 13, 33) = (67, 33), plus 30 padding, doubled.
        let mapped = CGPoint(x: red.midX, y: red.midY).applying(Renderer.sourceToCanvas(doc))
        XCTAssertEqual(mapped.x, 194, accuracy: 1e-9)
        XCTAssertEqual(mapped.y, 126, accuracy: 1e-9)
        XCTAssertEqual(render(doc, store)[194, 126], .red)
        XCTAssertEqual(render(doc, store)[5, 5], .blue)
    }

    func testUnscaledNoBackgroundOutputIsLosslessRotationOfSource() {
        let image = Fixture.detail(90, 50)
        var (doc, store) = Fixture.document(image)
        let src = render(doc, store)
        doc.geometry.quarterTurns = 1
        let rot = render(doc, store)
        XCTAssertEqual(rot.width, 50); XCTAssertEqual(rot.height, 90)
        for (x, y) in [(0, 0), (89, 0), (0, 49), (89, 49), (45, 20), (10, 33)] {
            XCTAssertEqual(rot[50 - 1 - y, x], src[x, y], "rotation moved pixel (\(x),\(y)) lossily")
        }
    }

    func testAspectRatioAndAlignmentPlaceContent() {
        let content = Fixture.solid(100, 50, RGBA(1, 0, 0))
        var (doc, store) = Fixture.document(content)
        var bg = BackgroundStyle()
        bg.fill = .solid(RGBA(0, 0, 1)); bg.padding = 10; bg.shadow = false; bg.cornerRadius = 0; bg.aspectRatio = 1
        doc.background = bg
        XCTAssertEqual(Renderer.canvasSize(doc), CGSize(width: 120, height: 120))

        let centered = render(doc, store)
        XCTAssertEqual(centered[60, 60], .red)
        XCTAssertEqual(centered[60, 20], .blue)

        bg.alignment = .top; doc.background = bg
        let top = render(doc, store)
        XCTAssertEqual(top[60, 15], .red, "content sits one padding from the top")
        XCTAssertEqual(top[60, 8], .blue)
        XCTAssertEqual(top[60, 100], .blue)

        bg.alignment = .bottom; doc.background = bg
        let bottom = render(doc, store)
        XCTAssertEqual(bottom[60, 105], .red)
        XCTAssertEqual(bottom[60, 20], .blue)

        bg.aspectRatio = nil; bg.padding = 0; bg.alignment = .left; doc.background = bg
        XCTAssertEqual(Renderer.canvasSize(doc), CGSize(width: 100, height: 50))
    }

    func testShadowFallsBelowContentAndCornerRadiusClipsIt() {
        let content = Fixture.solid(100, 100, RGBA(0.5, 0.5, 0.5))
        var (doc, store) = Fixture.document(content)
        var bg = BackgroundStyle()
        bg.fill = .solid(RGBA(1, 1, 1)); bg.padding = 64; bg.shadow = true; bg.cornerRadius = 20
        doc.background = bg
        let out = render(doc, store)
        let below = out[114, 64 + 100 + 8].r, above = out[114, 64 - 8].r
        XCTAssertLessThan(below, above - 15, "shadow is heavier under the content than above it (\(below) vs \(above))")
        XCTAssertGreaterThan(out[2, 2].r, 250, "far corner stays clean")
        XCTAssertEqual(out[64 + 1, 64 + 1].r > 200, true, "rounded corner shows background, not content")
        XCTAssertTrue(out[114, 114].isNear(Px(128, 128, 128), 2))

        bg.shadow = false; doc.background = bg
        XCTAssertEqual(render(doc, store)[114, 64 + 100 + 8], .white)
    }

    func testNoneFillLeavesTransparentCornersAndImageFillCovers() {
        let content = Fixture.solid(60, 60, RGBA(1, 0, 0))
        var (doc, store) = Fixture.document(content)
        var bg = BackgroundStyle()
        bg.fill = .none; bg.padding = 0; bg.shadow = false; bg.cornerRadius = 20
        doc.background = bg
        let out = render(doc, store)
        XCTAssertEqual(out[0, 0].a, 0)
        XCTAssertEqual(out[30, 30], .red)

        let wallpaper = Fixture.image(width: 10, height: 10) { ctx in
            ctx.setFillColor(RGBA(0, 1, 0).cgColor); ctx.fill(CGRect(x: 0, y: 0, width: 10, height: 10))
        }
        let id = store.add(image: wallpaper)!
        bg.fill = .image(asset: id); bg.padding = 30; bg.cornerRadius = 0
        doc.background = bg
        let wall = render(doc, store)
        XCTAssertEqual(wall[2, 2], .green)
        XCTAssertEqual(wall[117, 117], .green)
        XCTAssertEqual(wall[60, 60], .red)
    }

    func testTwentyDistinctBuiltinBackgroundsAllRenderAsGradients() {
        XCTAssertEqual(BuiltinBackgrounds.all.count, 20)
        XCTAssertEqual(Set(BuiltinBackgrounds.all.map(\.name)).count, 20)
        let content = Fixture.solid(10, 10, RGBA(1, 1, 1))
        var corners = Set<String>()
        for i in 0..<20 {
            var (doc, store) = Fixture.document(content)
            var bg = BackgroundStyle()
            bg.fill = .builtin(index: i); bg.padding = 100; bg.shadow = false
            doc.background = bg
            let out = render(doc, store)
            let w = out.width - 2, h = out.height - 2
            let probes = [out[1, 1], out[w, 1], out[1, h], out[w, h]]
            let spread = probes.map { a in probes.map { a.maxDiff($0) }.max()! }.max()!
            XCTAssertGreaterThan(spread, 12, "\(BuiltinBackgrounds.all[i].name) is a flat color")
            corners.insert(probes.map(\.description).joined())
        }
        XCTAssertEqual(corners.count, 20)
    }

    func testAutoBalanceTrimsUnevenMarginsToTheSmallestOne() {
        let w = 200, h = 100
        let image = Fixture.image(width: w, height: h) { ctx in
            ctx.setFillColor(RGBA(1, 1, 1).cgColor); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.setFillColor(RGBA(0.1, 0.2, 0.6).cgColor)
            ctx.fill(CGRect(x: 40, y: 10, width: 140, height: 60))
        }
        var (doc, store) = Fixture.document(image)
        var bg = BackgroundStyle()
        bg.fill = .solid(RGBA(1, 1, 1)); bg.padding = 0; bg.shadow = false; bg.cornerRadius = 0; bg.autoBalance = true
        doc.background = bg

        let out = render(doc, store)
        XCTAssertEqual(out.width, 160, "left margin 40 -> 10, right 20 -> 10: 200 - 30 - 10")
        XCTAssertEqual(out.height, 80, "top 10 stays, bottom 30 -> 10: 100 - 20")

        func firstInk(_ range: [Int], _ at: (Int) -> Px) -> Int { range.first { at($0).b < 200 && at($0).r < 200 } ?? -1 }
        let midY = out.height / 2, midX = out.width / 2
        XCTAssertEqual(firstInk(Array(0..<out.width)) { out[$0, midY] }, 10)
        XCTAssertEqual(firstInk(Array((0..<out.width).reversed())) { out[$0, midY] }, out.width - 1 - 10)
        XCTAssertEqual(firstInk(Array(0..<out.height)) { out[midX, $0] }, 10)
        XCTAssertEqual(firstInk(Array((0..<out.height).reversed())) { out[midX, $0] }, out.height - 1 - 10)

        let t = Renderer.sourceToCanvas(doc, assets: store)
        let p = CGPoint(x: 40, y: 10).applying(t)
        XCTAssertEqual(p.x, 10, accuracy: 1e-9)
        XCTAssertEqual(p.y, 10, accuracy: 1e-9)
    }

    func testAutoBalanceToleratesNoiseAndSkipsUniformImages() {
        var rng = SplitMix64(state: 5)
        let noisy = Fixture.image(width: 100, height: 60) { ctx in
            for y in 0..<60 { for x in 0..<100 {
                let n = Double(rng.next() % 5) / 255
                ctx.setFillColor(RGBA(1 - n, 1 - n, 1 - n).cgColor)
                ctx.fill(CGRect(x: x, y: y, width: 1, height: 1))
            } }
            ctx.setFillColor(RGBA(0, 0, 0).cgColor); ctx.fill(CGRect(x: 30, y: 20, width: 40, height: 20))
        }
        var (doc, store) = Fixture.document(noisy)
        var bg = BackgroundStyle(); bg.padding = 0; bg.autoBalance = true
        doc.background = bg
        XCTAssertEqual(Renderer.canvasSize(doc, assets: store), CGSize(width: 80, height: 60), "margins 30/20/30/20 trim to 20: only the sides lose 10")

        let flat = Fixture.solid(50, 50, RGBA(1, 1, 1))
        var (flatDoc, flatStore) = Fixture.document(flat)
        flatDoc.background = bg
        XCTAssertEqual(Renderer.canvasSize(flatDoc, assets: flatStore), CGSize(width: 50, height: 50))
    }
}
