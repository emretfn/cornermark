import AppKit
import CornermarkCore

@MainActor
func image(of view: NSView, scale: CGFloat = 2) -> CGImage? {
    view.layoutSubtreeIfNeeded()
    view.displayIfNeeded()
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width * scale), pixelsHigh: Int(view.bounds.height * scale),
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
    rep.size = view.bounds.size
    view.cacheDisplay(in: view.bounds, to: rep)
    return rep.cgImage
}

/// A whole window, title bar and traffic lights included, at 2x. `cacheDisplay` of the frame view comes back without the
/// content when the content holds a scroll view and the window was never ordered in, so the content is painted from its
/// pieces: every subtree without a scroll view on its own, a scroll view as its document view at the scroll offset,
/// then the frame view's chrome on top.
@MainActor
func snapshot(window: NSWindow, dark: Bool = false) -> CGImage? {
    let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    window.appearance = appearance
    guard let content = window.contentView, let frameView = content.superview else { return nil }
    content.layoutSubtreeIfNeeded()
    let scale: CGFloat = 2
    let size = frameView.bounds.size

    let c = Canvas(size: size)
    let ctx = c.ctx
    var background = NSColor.windowBackgroundColor
    appearance?.performAsCurrentDrawingAppearance { background = window.backgroundColor.usingColorSpace(.sRGB) ?? background }
    func place(_ image: CGImage?, _ rect: CGRect, clip: CGRect? = nil) {
        guard let image else { return }
        c.withState {
            if let clip { ctx.clip(to: clip) }
            c.drawImage(image, in: rect)
        }
    }
    func flipped(_ r: CGRect) -> CGRect { CGRect(x: r.minX, y: size.height - r.maxY, width: r.width, height: r.height) }
    func containsScroll(_ view: NSView) -> Bool { view is NSScrollView || view.subviews.contains(where: containsScroll) }
    func paint(_ view: NSView) {
        guard !view.isHidden else { return }
        if let scroll = view as? NSScrollView, let document = scroll.documentView {
            let clip = flipped(scroll.convert(scroll.bounds, to: content))
            if scroll.drawsBackground {
                appearance?.performAsCurrentDrawingAppearance { c.fill(clip, scroll.backgroundColor.usingColorSpace(.sRGB) ?? .clear) }
            }
            document.appearance = appearance
            place(image(of: document, scale: scale), flipped(document.convert(document.bounds, to: content)), clip: clip)
        } else if containsScroll(view) {
            view.subviews.forEach(paint)
        } else {
            view.appearance = appearance
            place(image(of: view, scale: scale), flipped(view.convert(view.bounds, to: content)))
        }
    }
    c.fill(CGRect(origin: .zero, size: size), background)
    content.subviews.forEach(paint)
    place(image(of: frameView, scale: scale), CGRect(origin: .zero, size: size))
    paintTrafficLights(c, window: window, frameView: frameView)
    return c.image()
}

/// A window that was never ordered in is never key, so AppKit draws its three buttons grey. They are repainted in the
/// active colours at the real buttons' positions; a button the window disables stays grey, as it does on screen.
@MainActor
private func paintTrafficLights(_ c: Canvas, window: NSWindow, frameView: NSView) {
    let colors: [(NSWindow.ButtonType, UInt32)] = [(.closeButton, 0xFF5F57), (.miniaturizeButton, 0xFEBC2E), (.zoomButton, 0x28C840)]
    for (type, hex) in colors {
        guard let button = window.standardWindowButton(type) else { continue }
        let r = button.convert(button.bounds, to: frameView)
        let center = CGPoint(x: r.midX, y: frameView.bounds.height - r.midY)
        let fill = button.isEnabled ? NSColor(hex: hex) : NSColor(hex: 0xD0CFCB)
        c.circle(center: center, radius: 6.5, fill: NSColor.white)
        c.circle(center: center, radius: 6, fill: fill)
        c.ctx.setStrokeColor(NSColor(white: 0, alpha: 0.14).cgColor)
        c.ctx.setLineWidth(0.5)
        c.ctx.strokeEllipse(in: CGRect(x: center.x - 5.75, y: center.y - 5.75, width: 11.5, height: 11.5))
    }
}

enum Compose {
    static let width = 2000

    /// A window (2x pixels, transparent corners) centred on a fresh wallpaper with generous padding and a large soft shadow.
    /// The window is only ever scaled down, so text stays as sharp as it can be.
    static func windowOnWallpaper(_ window: CGImage, padding: Double = 120) -> CGImage {
        let canvasW = Double(width)
        let inner = canvasW - padding * 2
        let scale = min(1, inner / Double(window.width))
        let w = Double(window.width) * scale, h = Double(window.height) * scale
        let pad = max(padding, (canvasW - w) / 2)
        let canvasH = (h + pad * 2).rounded()
        let c = Canvas(size: CGSize(width: canvasW, height: canvasH), scale: 1)
        c.drawImage(Wallpaper.image(width: width, height: Int(canvasH)), in: CGRect(x: 0, y: 0, width: canvasW, height: canvasH))
        let rect = CGRect(x: (canvasW - w) / 2, y: pad, width: w, height: h)
        c.shadowed(dy: 56, blur: 110, alpha: 0.55) { c.drawImage(window, in: rect) }
        c.shadowed(dy: 6, blur: 14, alpha: 0.30) { c.drawImage(window, in: rect) }
        return c.image()
    }

    static func png(_ image: CGImage) -> Data? { AssetStore.pngData(from: image) }

    static func rounded(_ image: CGImage, radiusPoints: CGFloat) -> CGImage {
        let size = CGSize(width: CGFloat(image.width) / 2, height: CGFloat(image.height) / 2)
        let c = Canvas(size: size)
        c.withState {
            c.ctx.addPath(CGPath(roundedRect: CGRect(origin: .zero, size: size), cornerWidth: radiusPoints, cornerHeight: radiusPoints, transform: nil))
            c.ctx.clip()
            c.drawImage(image, in: CGRect(origin: .zero, size: size))
        }
        return c.image()
    }
}
