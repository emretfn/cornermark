#if DEBUG
import AppKit
import CornermarkL10n

/// Draws a live window into a PNG for scripted checks of the development app. Views draw into layers, which
/// `cacheDisplay` on a whole window leaves blank, so each leaf view, and each scroll view's document, is cached
/// on its own and placed where it sits in the window.
enum DebugSnapshot {
    static func write(_ window: NSWindow, to url: URL) throws {
        guard let content = window.contentView else { throw CocoaError(.fileWriteUnknown) }
        content.layoutSubtreeIfNeeded()
        let scale = window.backingScaleFactor
        let size = content.bounds.size
        guard let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw CocoaError(.fileWriteUnknown)
        }
        ctx.scaleBy(x: scale, y: scale)
        window.effectiveAppearance.performAsCurrentDrawingAppearance {
            ctx.setFillColor((window.backgroundColor.usingColorSpace(.sRGB) ?? .windowBackgroundColor).cgColor)
        }
        ctx.fill(CGRect(origin: .zero, size: size))

        func image(of view: NSView) -> CGImage? {
            view.displayIfNeeded()
            guard view.bounds.width >= 1, view.bounds.height >= 1, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
            view.cacheDisplay(in: view.bounds, to: rep)
            return rep.cgImage
        }
        func rectInContent(_ view: NSView) -> CGRect {
            let r = view.convert(view.bounds, to: content)
            return content.isFlipped ? CGRect(x: r.minX, y: size.height - r.maxY, width: r.width, height: r.height) : r
        }
        func place(_ view: NSView, clip: CGRect? = nil) {
            guard let picture = image(of: view) else { return }
            ctx.saveGState()
            if let clip { ctx.clip(to: clip) }
            ctx.draw(picture, in: rectInContent(view))
            ctx.restoreGState()
        }
        func containsScroll(_ view: NSView) -> Bool { view is NSScrollView || view.subviews.contains(where: containsScroll) }
        func paint(_ view: NSView) {
            guard !view.isHidden else { return }
            if let scroll = view as? NSScrollView, let document = scroll.documentView {
                place(document, clip: rectInContent(scroll.contentView))
            } else if containsScroll(view) {
                if !view.subviews.isEmpty { place(view) }
                view.subviews.forEach(paint)
            } else {
                place(view)
            }
        }
        content.subviews.forEach(paint)
        guard let picture = ctx.makeImage(), let png = NSBitmapImageRep(cgImage: picture).representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try png.write(to: url)
        try report(window).write(to: url.deletingPathExtension().appendingPathExtension("txt"), atomically: true, encoding: .utf8)
    }

    /// What the picture shows, as text: the language, the direction and every visible label, top to bottom.
    private static func report(_ window: NSWindow) -> String {
        var lines = ["language \(L10n.language.rawValue)", "locale \(L10n.locale.identifier)",
                     "content direction \(window.contentView?.userInterfaceLayoutDirection == .rightToLeft ? "rightToLeft" : "leftToRight")",
                     "window \(window.title) \(Int(window.frame.width))x\(Int(window.frame.height))"]
        func walk(_ view: NSView) {
            guard !view.isHidden else { return }
            if let field = view as? NSTextField, !field.stringValue.isEmpty {
                let r = field.convert(field.bounds, to: nil)
                lines.append("text x=\(Int(r.minX)) y=\(Int(r.minY)) \(field.stringValue)")
            } else if let button = view as? NSPopUpButton {
                lines.append("popup \(button.titleOfSelectedItem ?? "")")
            }
            view.subviews.forEach(walk)
        }
        window.contentView.map(walk)
        return lines.joined(separator: "\n") + "\n"
    }
}
#endif
