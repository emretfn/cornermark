import AppKit
import CornermarkCore

extension InputOverlayInk {
    /// Red, orange and green are the image editor's annotation swatches, not the status tokens: a ring means a click, never danger,
    /// warning or success.
    public static let design: InputOverlayInk = {
        func resolve(_ color: NSColor, _ name: NSAppearance.Name = .darkAqua) -> CGColor {
            var out = CGColor(gray: 1, alpha: 1)
            NSAppearance(named: name)?.performAsCurrentDrawingAppearance { out = color.cgColor }
            return out
        }
        let clicks: [ClickHighlight.Color: CGColor] = [
            .lemon: resolve(DS.Color.accentSolid), .white: resolve(DS.Color.selectionStroke),
            .red: CGColor(srgbRed: 0xE5 / 255, green: 0x30 / 255, blue: 0x3A / 255, alpha: 1),
            .orange: CGColor(srgbRed: 0xF2 / 255, green: 0x8C / 255, blue: 0x28 / 255, alpha: 1),
            .green: CGColor(srgbRed: 0x2F / 255, green: 0xBF / 255, blue: 0x5B / 255, alpha: 1),
        ]
        let dark = (fill: resolve(DS.Color.bgHud), text: resolve(DS.Color.textPrimary), border: resolve(DS.Color.borderSubtle))
        let light = (fill: resolve(DS.Color.bgRaised, .aqua), text: resolve(DS.Color.textPrimary, .aqua), border: resolve(DS.Color.border, .aqua))
        return InputOverlayInk(
            click: { clicks[$0] ?? CGColor(gray: 1, alpha: 1) }, halo: resolve(DS.Color.selectionHalo),
            badgeFill: { $0 == .dark ? dark.fill : light.fill }, badgeText: { $0 == .dark ? dark.text : light.text },
            badgeBorder: { $0 == .dark ? dark.border : light.border })
    }()
}
