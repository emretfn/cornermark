import AppKit

private let appearances: [NSAppearance.Name] = [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua]

private func dynamic(_ light: NSColor, _ dark: NSColor, lightIncreased: NSColor? = nil, darkIncreased: NSColor? = nil) -> NSColor {
    NSColor(name: nil) { appearance in
        switch appearance.bestMatch(from: appearances) {
        case .some(.darkAqua): return dark
        case .some(.accessibilityHighContrastDarkAqua): return darkIncreased ?? dark
        case .some(.accessibilityHighContrastAqua): return lightIncreased ?? light
        default: return light
        }
    }
}

private func ramp(_ role: (StatusRamp) -> NSColor, of family: Palette.Accent) -> NSColor {
    dynamic(role(family.light), role(family.dark))
}

private func n(_ steps: [NSColor], _ step: Int) -> NSColor { steps[step - 1] }

extension DS {
    public enum Color {
        private static let nl = Palette.neutralLight
        private static let nd = Palette.neutralDark

        private static func neutral(light: Int, dark: Int) -> NSColor { dynamic(n(nl, light), n(nd, dark)) }
        private static func neutral(_ step: Int) -> NSColor { neutral(light: step, dark: step) }

        public static let bgWindow = neutral(light: 1, dark: 2)
        public static let bgSurface = neutral(light: 2, dark: 3)
        public static let bgRaised = neutral(light: 1, dark: 4)
        public static let bgSunken = neutral(light: 3, dark: 1)
        public static let bgCanvas = neutral(light: 4, dark: 1)
        public static let bgControl = neutral(light: 3, dark: 5)
        public static let bgControlHover = neutral(light: 4, dark: 6)
        public static let bgControlActive = neutral(light: 5, dark: 7)
        /// The raised thumb of a segment track: lighter than the track in light mode, and in dark mode too, where light reads as raised.
        public static let bgControlThumb = neutral(light: 1, dark: 7)

        public static let bgHud = NSColor(name: nil) { _ in
            let base = n(nd, 2)
            return NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency ? base : base.withAlphaComponent(0.88)
        }
        public static let bgInverse = neutral(12)
        public static let bgInverseHover = neutral(11)
        public static let onInverse = neutral(light: 1, dark: 2)
        public static let bgScrim = NSColor.black.withAlphaComponent(0.45)

        public static let textPrimary = neutral(12)
        public static let textSecondary = dynamic(n(nl, 11), n(nd, 11), lightIncreased: n(nl, 12), darkIncreased: n(nd, 12))
        public static let textDisabled = neutral(10)

        public static let separator = dynamic(n(nl, 6), n(nd, 6), lightIncreased: n(nl, 7), darkIncreased: n(nd, 7))
        public static let borderSubtle = separator
        public static let border = dynamic(n(nl, 7), n(nd, 7), lightIncreased: n(nl, 8), darkIncreased: n(nd, 8))
        public static let borderStrong = neutral(8)
        public static let focusRing = NSColor.keyboardFocusIndicatorColor

        public static let imageOutline = dynamic(NSColor.black.withAlphaComponent(0.10), NSColor.white.withAlphaComponent(0.10))
        public static let selectionStroke = NSColor.white
        public static let selectionHalo = NSColor.black.withAlphaComponent(0.45)

        public static let accentSubtle = ramp({ $0.subtle }, of: Palette.accent)
        public static let accentBorder = ramp({ $0.border }, of: Palette.accent)
        public static let accentSolid = ramp({ $0.solid }, of: Palette.accent)
        public static let accentSolidHover = ramp({ $0.solidHover ?? $0.solid }, of: Palette.accent)
        public static let accentText = ramp({ $0.text }, of: Palette.accent)
        public static let accentMark = dynamic(Palette.accent.light.text, Palette.accent.dark.solid)
        public static let accentWash = dynamic(Palette.accent.light.solid.withAlphaComponent(0.22), Palette.accent.dark.solid.withAlphaComponent(0.22))
        public static let onAccent = ramp({ $0.onSolid }, of: Palette.accent)

        public static let dangerSubtle = ramp({ $0.subtle }, of: (Palette.dangerLight, Palette.dangerDark))
        public static let dangerBorder = ramp({ $0.border }, of: (Palette.dangerLight, Palette.dangerDark))
        public static let dangerSolid = ramp({ $0.solid }, of: (Palette.dangerLight, Palette.dangerDark))
        public static let dangerText = ramp({ $0.text }, of: (Palette.dangerLight, Palette.dangerDark))
        public static let onDanger = ramp({ $0.onSolid }, of: (Palette.dangerLight, Palette.dangerDark))

        public static let warningSubtle = ramp({ $0.subtle }, of: (Palette.warningLight, Palette.warningDark))
        public static let warningBorder = ramp({ $0.border }, of: (Palette.warningLight, Palette.warningDark))
        public static let warningSolid = ramp({ $0.solid }, of: (Palette.warningLight, Palette.warningDark))
        public static let warningText = ramp({ $0.text }, of: (Palette.warningLight, Palette.warningDark))
        public static let onWarning = ramp({ $0.onSolid }, of: (Palette.warningLight, Palette.warningDark))

        public static let successSubtle = ramp({ $0.subtle }, of: (Palette.successLight, Palette.successDark))
        public static let successBorder = ramp({ $0.border }, of: (Palette.successLight, Palette.successDark))
        public static let successSolid = ramp({ $0.solid }, of: (Palette.successLight, Palette.successDark))
        public static let successText = ramp({ $0.text }, of: (Palette.successLight, Palette.successDark))
        public static let onSuccess = ramp({ $0.onSolid }, of: (Palette.successLight, Palette.successDark))
    }
}
