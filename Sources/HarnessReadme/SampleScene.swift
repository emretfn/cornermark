import AppKit

/// The fictional Mac desktop every README shot is built from: wallpaper, menu bar, Dock and two app windows.
/// Layout constants live here so annotations and capture selections can point at real content.
enum SampleScene {
    static let desktopSize = CGSize(width: 1440, height: 900)
    static let menuBarHeight: CGFloat = 28
    static let dockTop: CGFloat = 828
    static let dashboardFrame = CGRect(x: 40, y: 116, width: 860, height: 600)
    static let codeFrame = CGRect(x: 918, y: 76, width: 490, height: 560)
    static let windowRadius: CGFloat = 12

    static func dashboardWindow() -> CGImage {
        let c = Canvas(size: Dashboard.size)
        Dashboard.draw(c)
        return c.image()
    }

    static func codeWindow(size: CGSize = codeFrame.size) -> CGImage {
        let c = Canvas(size: size)
        CodeWindow.draw(c, size: size)
        return c.image()
    }

    /// A window as the screenshot tool would capture it: rounded corners and a soft shadow on transparency.
    static func shadowedCapture(_ window: CGImage, margin: CGFloat = 28) -> CGImage {
        let pt = CGSize(width: CGFloat(window.width) / 2, height: CGFloat(window.height) / 2)
        let c = Canvas(size: CGSize(width: pt.width + margin * 2, height: pt.height + margin * 2))
        drawWindow(c, image: window, at: CGPoint(x: margin, y: margin))
        return c.image()
    }

    static func desktop(code: CGRect = codeFrame, withDashboard: Bool = true) -> CGImage {
        let c = Canvas(size: desktopSize)
        c.drawImage(Wallpaper.image(width: Int(desktopSize.width * 2), height: Int(desktopSize.height * 2)), in: CGRect(origin: .zero, size: desktopSize))
        menuBar(c)
        drawWindow(c, image: codeWindow(size: code.size), at: code.origin, active: !withDashboard)
        if withDashboard { drawWindow(c, image: dashboardWindow(), at: dashboardFrame.origin, active: true) }
        dock(c)
        return c.image()
    }

    static func drawWindow(_ c: Canvas, image: CGImage, at origin: CGPoint, active: Bool = false) {
        let size = CGSize(width: CGFloat(image.width) / 2, height: CGFloat(image.height) / 2)
        let rect = CGRect(origin: origin, size: size)
        let path = CGPath(roundedRect: rect, cornerWidth: windowRadius, cornerHeight: windowRadius, transform: nil)
        c.shadowed(dy: 22, blur: 44, alpha: active ? 0.42 : 0.30) {
            c.ctx.addPath(path)
            c.ctx.setFillColor(NSColor.black.cgColor)
            c.ctx.fillPath()
        }
        c.shadowed(dy: 2, blur: 6, alpha: 0.28) {
            c.ctx.addPath(path)
            c.ctx.setFillColor(NSColor.black.cgColor)
            c.ctx.fillPath()
        }
        c.withState {
            c.ctx.addPath(path)
            c.ctx.clip()
            c.drawImage(image, in: rect)
        }
        c.stroke(rect.insetBy(dx: -0.5, dy: -0.5), NSColor(white: 0, alpha: 0.28), radius: windowRadius + 0.5, width: 0.5)
        c.stroke(rect, NSColor(white: 1, alpha: 0.10), radius: windowRadius, width: 0.5)
    }

    static func trafficLights(_ c: Canvas, y: CGFloat) {
        for (i, hex) in [UInt32(0xFF5F57), 0xFEBC2E, 0x28C840].enumerated() {
            let center = CGPoint(x: 20 + CGFloat(i) * 20, y: y)
            c.circle(center: center, radius: 6, fill: NSColor(hex: hex))
            c.ctx.setStrokeColor(NSColor(white: 0, alpha: 0.14).cgColor)
            c.ctx.setLineWidth(0.5)
            c.ctx.strokeEllipse(in: CGRect(x: center.x - 5.75, y: center.y - 5.75, width: 11.5, height: 11.5))
        }
    }

    // MARK: Menu bar and Dock

    private static func menuBar(_ c: Canvas) {
        c.fill(CGRect(x: 0, y: 0, width: desktopSize.width, height: menuBarHeight), NSColor(white: 0, alpha: 0.26))
        let white = NSColor(white: 1, alpha: 0.95)
        c.symbol("circle.hexagongrid.fill", in: CGRect(x: 14, y: 6, width: 16, height: 16), color: white, pointSize: 13, weight: .medium)
        var x: CGFloat = 44
        for (i, item) in ["Dashboard", "File", "Edit", "View", "Window", "Help"].enumerated() {
            let font = Font.ui(13, i == 0 ? .bold : .medium)
            x += c.text(item, at: CGPoint(x: x, y: 6), font: font, color: white) + 18
        }
        var right = desktopSize.width - 16
        right -= c.text("Tue Nov 3  2:05 PM", at: CGPoint(x: right, y: 6), font: Font.ui(13, .medium), color: white, align: .right) + 14
        for name in ["magnifyingglass", "wifi", "battery.100percent"] {
            let w: CGFloat = name == "battery.100percent" ? 26 : 18
            c.symbol(name, in: CGRect(x: right - w, y: 5, width: w, height: 18), color: white, pointSize: 13, weight: .medium)
            right -= w + 12
        }
    }

    private static func dock(_ c: Canvas) {
        let icons: [(String, UInt32, UInt32)] = [
            ("folder.fill", 0x4FA3F7, 0x2468E0), ("envelope.fill", 0x5AC8FA, 0x2F7FE8), ("calendar", 0xFF6B5E, 0xE0392D),
            ("photo.fill", 0xFFC85C, 0xF2802E), ("music.note", 0xFF6A8A, 0xD92B5C), ("chart.bar.fill", 0x3CC7B5, 0x0E7C86),
            ("chevron.left.forwardslash.chevron.right", 0x6F7380, 0x2E3038), ("note.text", 0xFFE066, 0xF2B01E),
            ("map.fill", 0x7BD88F, 0x2FA862), ("gearshape.fill", 0xA9AEB8, 0x6B707B),
        ]
        let icon: CGFloat = 50, gap: CGFloat = 10, padX: CGFloat = 14
        let width = padX * 2 + CGFloat(icons.count) * icon + CGFloat(icons.count - 1) * gap + 22
        let bar = CGRect(x: (desktopSize.width - width) / 2, y: dockTop, width: width, height: 64)
        c.shadowed(dy: 8, blur: 24, alpha: 0.3) { c.fill(bar, NSColor(white: 1, alpha: 0.22), radius: 22) }
        c.fill(bar, NSColor(white: 1, alpha: 0.12), radius: 22)
        c.stroke(bar, NSColor(white: 1, alpha: 0.32), radius: 22, width: 0.5)
        var x = bar.minX + padX
        for (i, (symbol, top, bottom)) in icons.enumerated() {
            if i == icons.count - 1 {
                c.line(CGPoint(x: x - gap / 2 - 1, y: bar.minY + 12), CGPoint(x: x - gap / 2 - 1, y: bar.maxY - 12), NSColor(white: 1, alpha: 0.35), width: 1)
                x += 11
            }
            let r = CGRect(x: x, y: bar.minY + 7, width: icon, height: icon)
            c.shadowed(dy: 2, blur: 5, alpha: 0.28) { c.fill(r, NSColor(hex: bottom), radius: 12) }
            c.linearGradient([NSColor(hex: top), NSColor(hex: bottom)], in: r, from: CGPoint(x: r.midX, y: r.minY), to: CGPoint(x: r.midX, y: r.maxY))
            c.withState {
                c.ctx.addPath(CGPath(roundedRect: r, cornerWidth: 12, cornerHeight: 12, transform: nil))
                c.ctx.clip()
                c.linearGradient([NSColor(white: 1, alpha: 0.22), NSColor(white: 1, alpha: 0)], in: r, from: CGPoint(x: r.midX, y: r.minY), to: CGPoint(x: r.midX, y: r.midY))
            }
            c.symbol(symbol, in: r, color: NSColor(white: 1, alpha: 0.96), pointSize: symbol.count > 20 ? 19 : 24, weight: .semibold)
            if i == 5 || i == 6 { c.circle(center: CGPoint(x: r.midX, y: bar.maxY - 3.5), radius: 2, fill: NSColor(white: 1, alpha: 0.85)) }
            x += icon + gap
        }
    }
}

// MARK: Wallpaper

enum Wallpaper {
    private struct Blob {
        let x, y, sigma: Double
        let color: UInt32
    }

    private static let blobs: [Blob] = [
        Blob(x: 0.02, y: 0.04, sigma: 0.34, color: 0x1B2A6E),
        Blob(x: 0.36, y: 0.00, sigma: 0.26, color: 0x4A2A8C),
        Blob(x: 0.78, y: 0.06, sigma: 0.28, color: 0x0E5A70),
        Blob(x: 0.98, y: 0.48, sigma: 0.26, color: 0xA8345A),
        Blob(x: 0.90, y: 1.00, sigma: 0.30, color: 0xE0702C),
        Blob(x: 0.48, y: 0.96, sigma: 0.28, color: 0x7C2A5C),
        Blob(x: 0.00, y: 0.86, sigma: 0.28, color: 0x243C7E),
        Blob(x: 0.52, y: 0.48, sigma: 0.34, color: 0x3A2A70),
    ]

    /// A mesh-like blend: every pixel is the Gaussian-weighted mean of the blob colours. Computed on a coarse grid and
    /// upscaled with smooth interpolation, so there is no grain and no banding grid.
    static func image(width: Int, height: Int) -> CGImage {
        let gw = max(8, width / 8), gh = max(8, height / 8)
        let aspect = Double(width) / Double(height)
        var buffer = [UInt8](repeating: 255, count: gw * gh * 4)
        for gy in 0..<gh {
            for gx in 0..<gw {
                let u = (Double(gx) + 0.5) / Double(gw), v = (Double(gy) + 0.5) / Double(gh)
                var total = 0.0, r = 0.0, g = 0.0, b = 0.0
                for blob in blobs {
                    let dx = (u - blob.x) * aspect, dy = v - blob.y
                    let w = exp(-(dx * dx + dy * dy) / (2 * blob.sigma * blob.sigma))
                    total += w
                    r += w * Double((blob.color >> 16) & 0xFF); g += w * Double((blob.color >> 8) & 0xFF); b += w * Double(blob.color & 0xFF)
                }
                let edge = 1 - 0.18 * pow(max(abs(u - 0.5), abs(v - 0.5)) * 2, 3)
                let i = (gy * gw + gx) * 4
                buffer[i] = UInt8(min(255, r / total * edge)); buffer[i + 1] = UInt8(min(255, g / total * edge)); buffer[i + 2] = UInt8(min(255, b / total * edge))
            }
        }
        let small = buffer.withUnsafeMutableBytes { raw -> CGImage in
            CGContext(data: raw.baseAddress, width: gw, height: gh, bitsPerComponent: 8, bytesPerRow: gw * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
        }
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.interpolationQuality = .high
        ctx.draw(small, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }
}
