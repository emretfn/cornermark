import AppKit
import CornermarkDesign

private final class ElevationView: NSView {
    let flip: Bool
    let rect: CGRect
    let fill: NSColor
    init(flipped: Bool, size: CGSize, rect: CGRect, fill: NSColor) {
        flip = flipped
        self.rect = rect
        self.fill = fill
        super.init(frame: CGRect(origin: .zero, size: size))
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { flip }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill()
        bounds.fill()
        DS.Elevation.floating.draw(NSBezierPath.continuous(rect, radius: 12), fill: fill)
    }
}

/// Mean darkness of a horizontal band, rows counted from the top of the image.
private func band(_ rep: NSBitmapImageRep, _ scale: CGFloat, rows: Range<Int>, columns: Range<Int>) -> Double {
    var sum = 0.0, count = 0.0
    for y in rows {
        for x in columns {
            sum += 1 - pixel(rep, x: Int(CGFloat(x) * scale), y: Int(CGFloat(y) * scale)).g
            count += 1
        }
    }
    return sum / count
}

func checkElevation() {
    section("Elevation")
    let size = CGSize(width: 220, height: 220)
    // The rect covers image rows 70 to 130 whichever way the context is flipped.
    for flipped in [false, true] {
        let name = flipped ? "flipped" : "unflipped"
        let rect = flipped ? CGRect(x: 60, y: 70, width: 100, height: 60) : CGRect(x: 60, y: 90, width: 100, height: 60)

        for scale in [CGFloat(1), 2] {
            let rep = render(size: size, scale: scale, flipped: flipped) {
                NSColor.white.setFill()
                CGRect(origin: .zero, size: size).fill()
                DS.Elevation.floating.draw(NSBezierPath.continuous(rect, radius: 12), fill: .white)
            }
            let above = band(rep, scale, rows: 60..<70, columns: 80..<140), below = band(rep, scale, rows: 130..<140, columns: 80..<140)
            check(String(format: "shadow falls below the shape (%@, %.0fx): below %.3f vs above %.3f", name, scale, below, above), below > above * 1.5)
            check("fill covers the shadow under it (\(name), \(Int(scale))x)", pixel(rep, x: Int(100 * scale), y: Int(100 * scale)).g > 0.999)
        }

        let view = ElevationView(flipped: flipped, size: size, rect: rect, fill: .white)
        let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / size.width
        let above = band(rep, scale, rows: 60..<70, columns: 80..<140), below = band(rep, scale, rows: 130..<140, columns: 80..<140)
        check(String(format: "shadow falls below the shape inside NSView.draw (%@ view): below %.3f vs above %.3f", name, below, above), below > above * 1.5)

        let dark = render(size: size, scale: 2, flipped: flipped) {
            NSColor.black.setFill()
            CGRect(origin: .zero, size: size).fill()
            DS.Elevation.hud.draw(NSBezierPath.continuous(rect, radius: 12), fill: NSColor(white: 0.1, alpha: 1))
        }
        func lightness(row: Int) -> Double { pixel(dark, x: 200, y: row * 2).g }
        let top = lightness(row: 70), inside = lightness(row: 100), bottom = lightness(row: 129)
        check(String(format: "top-edge highlight sits on the top edge (%@): row 70 %.3f > inside %.3f, bottom row %.3f", name, top, inside, bottom),
              top > inside + 0.03 && abs(bottom - inside) < 0.01)
    }
}
