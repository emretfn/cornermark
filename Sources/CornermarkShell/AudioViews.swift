import AppKit
import CornermarkCore
import CornermarkDesign
import CornermarkL10n

/// A thin bar that fills with the microphone's loudness on a decibel scale. It is neutral, because a level is a reading, not a choice.
/// It rises at once and falls back over about half a second, so a voice reads as a steady movement rather than a flicker. It fills
/// from the leading edge.
final class LevelMeterView: NSView {
    static let height: CGFloat = 4
    private(set) var shown: Float = 0
    private var lastUpdate: TimeInterval?
    /// The width a form row gives it.
    var preferredWidth: CGFloat = 0 { didSet { invalidateIntrinsicContentSize() } }
    override var intrinsicContentSize: NSSize { NSSize(width: preferredWidth > 0 ? preferredWidth : NSView.noIntrinsicMetric, height: DS.Size.controlSmall) }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.levelIndicator)
        setAccessibilityLabel(tr("Microphone level"))
    }

    required init?(coder: NSCoder) { fatalError("LevelMeterView is created in code") }

    func show(_ level: AudioLevel, at now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        let target = level.meterFraction()
        let elapsed = lastUpdate.map { min(max(now - $0, 0), 1) } ?? 1
        lastUpdate = now
        // Falls a whole meter in 0.6 s.
        shown = max(target, shown - Float(elapsed / 0.6))
        setAccessibilityValue(tr("{level} dB", ["level": Int(AudioLevel.decibels(level.rms, floor: -60).rounded())]))
        needsDisplay = true
    }

    /// Empty at once, as when the microphone stops.
    func reset() {
        shown = 0
        lastUpdate = nil
        setAccessibilityValue(nil)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let track = CGRect(x: 0, y: (bounds.height - Self.height) / 2, width: bounds.width, height: Self.height)
        DS.Color.borderStrong.setFill()
        NSBezierPath(roundedRect: track, xRadius: Self.height / 2, yRadius: Self.height / 2).fill()
        guard shown > 0 else { return }
        let fill = mirrored(CGRect(x: track.minX, y: track.minY, width: max(Self.height, track.width * CGFloat(shown)), height: Self.height))
        DS.Color.bgInverse.setFill()
        NSBezierPath(roundedRect: fill, xRadius: Self.height / 2, yRadius: Self.height / 2).fill()
    }
}

/// The microphone in the control bar: its symbol and level, or a warning badge when it gives no sound. Both states take the same width,
/// so the buttons beside it never move.
final class MicrophoneSlotView: NSView {
    private let symbol = SymbolGlyphView()
    let meter = LevelMeterView()
    private(set) var silent = MicrophoneSlotView.silentBadge()
    private(set) var isSilent = false

    static var width: CGFloat { silentBadge().intrinsicContentSize.width }

    /// A badge draws its text once, so a new language gets a new badge.
    private static func silentBadge() -> Badge {
        let badge = Badge(text: tr("No sound"), symbol: "mic.slash.fill", tone: .warning)
        badge.toolTip = tr("No sound from the microphone for 3 seconds. Check that it is not muted and its input volume is up.")
        badge.setAccessibilityIdentifier("recording.microphoneSilent")
        badge.setAccessibilityLabel(tr("No sound from the microphone"))
        badge.setAccessibilityHelp(tr("Check that the microphone is not muted and its input volume is up."))
        return badge
    }

    override init(frame: NSRect) {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: DS.Size.controlSmall))
        symbol.symbol = "mic.fill"
        meter.setAccessibilityIdentifier("recording.microphoneMeter")
        [symbol, meter, silent].forEach(addSubview)
        apply(nil)
        NotificationCenter.default.addObserver(self, selector: #selector(languageDidChange), name: L10n.didChange, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("MicrophoneSlotView is created in code") }

    deinit { NotificationCenter.default.removeObserver(self, name: L10n.didChange, object: nil) }

    @objc private func languageDidChange() {
        let badge = Self.silentBadge()
        badge.isHidden = silent.isHidden
        replaceSubview(silent, with: badge)
        silent = badge
        meter.setAccessibilityLabel(tr("Microphone level"))
        applyLanguageDirection(L10n.layoutDirection)
        layoutSlot()
    }

    func apply(_ status: MicrophoneStatus?) {
        isSilent = status?.isSilent ?? false
        silent.isHidden = !isSilent
        symbol.isHidden = isSilent
        meter.isHidden = isSilent
        meter.show(status?.level ?? .silence)
        layoutSlot()
    }

    private func layoutSlot() {
        let h = bounds.height, icon = DS.Size.icon
        // Lined up with the badge's own symbol, so the glyph stays put when the slot swaps.
        let glyph = CGRect(x: DS.Space.s8 + (DS.Size.iconSmall - icon) / 2, y: (h - icon) / 2, width: icon, height: icon)
        symbol.frame = mirrored(glyph)
        let x = glyph.maxX + DS.Space.s6
        meter.frame = mirrored(CGRect(x: x, y: 0, width: bounds.width - x - DS.Space.s4, height: h))
        silent.frame = CGRect(x: 0, y: (h - DS.Size.controlSmall) / 2, width: bounds.width, height: DS.Size.controlSmall)
    }
}

/// A symbol in the secondary text colour, resolved at draw time so it follows the appearance.
final class SymbolGlyphView: NSView {
    var symbol = "mic.fill" { didSet { needsDisplay = true } }
    var color = DS.Color.textSecondary { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) { Glyph.draw(symbol, in: bounds, pointSize: DS.Size.icon, color) }
}
