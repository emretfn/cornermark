import AppKit
import KadrajDesign

/// The system colour well, kept for its colour panel. The minimal style draws through a hosted SwiftUI view that `draw` never
/// reaches, so the look is an overlay that passes every click through to the well.
///
/// It reads as a tile of a row: when `isCurrent` says the colour is its own, it shows that colour in the accent ring; otherwise
/// it is a neutral tile with a palette glyph, an invitation to pick one.
final class SolidWell: NSColorWell {
    enum Shape {
        /// The rounded square of the background panel's fill grid.
        case tile
        /// A circle on the colour chips' 22pt grid, for the property bar.
        case circle
    }

    let shape: Shape
    var isCurrent: () -> Bool = { false }
    fileprivate var hovering = false { didSet { if oldValue != hovering { overlay.needsDisplay = true } } }
    private let overlay = TileOverlay()

    init(shape: Shape) {
        self.shape = shape
        super.init(frame: .zero)
        // `init(style:)` hands back a plain NSColorWell, never this subclass.
        colorWellStyle = .minimal
        overlay.well = self
        overlay.frame = bounds
        overlay.autoresizingMask = [.width, .height]
        addSubview(overlay)
        if shape == .tile { TileChrome.trackHover(self) }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var color: NSColor {
        didSet { overlay.needsDisplay = true }
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func draw(_ dirtyRect: NSRect) {}

    override func drawFocusRingMask() { focusShape.fill() }
    override var focusRingMaskBounds: NSRect { bounds }

    private var focusShape: NSBezierPath { shape == .circle ? NSBezierPath(ovalIn: bounds) : .continuous(bounds, radius: DS.Radius.md) }

    func redrawTile() { overlay.needsDisplay = true }

    fileprivate final class TileOverlay: NSView {
        weak var well: SolidWell?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func draw(_ dirtyRect: NSRect) {
            guard let well else { return }
            // Covers the system swatch, which can reach past the picture when the tile is inset.
            DS.Color.bgSurface.setFill()
            bounds.fill()
            switch well.shape {
            case .tile: drawTile(well)
            case .circle: drawCircle(well)
            }
        }

        private func drawTile(_ well: SolidWell) {
            let solid = well.isCurrent()
            TileChrome.draw(in: bounds, current: solid, hovering: well.hovering) { rect in
                if solid {
                    well.color.setFill()
                    rect.fill()
                } else {
                    DS.Color.bgControl.setFill()
                    rect.fill()
                    Glyph.draw("paintpalette", in: rect, pointSize: DS.Size.icon, DS.Color.textSecondary)
                }
            }
        }

        /// Matches `SwatchButton`: the chip is inset 3pt in its cell, and the current one carries a 2pt ring.
        private func drawCircle(_ well: SolidWell) {
            let solid = well.isCurrent()
            let chip = NSBezierPath(ovalIn: bounds.insetBy(dx: 3, dy: 3))
            (solid ? well.color : DS.Color.bgControl).setFill()
            chip.fill()
            if !solid { Glyph.draw("paintpalette", in: bounds, pointSize: DS.Size.iconSmall - 2, DS.Color.textSecondary) }
            DS.Color.imageOutline.setStroke()
            chip.lineWidth = 1
            chip.stroke()
            if solid {
                DS.Color.accentMark.setStroke()
                let ring = NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1))
                ring.lineWidth = 2
                ring.stroke()
            }
        }
    }
}
