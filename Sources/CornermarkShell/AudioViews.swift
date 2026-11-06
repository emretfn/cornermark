import AppKit
import CornermarkCore
import CornermarkDesign

/// A thin bar that fills with the microphone's loudness on a decibel scale. It is neutral, because a level is a reading, not a choice.
/// It rises at once and falls back over about half a second, so a voice reads as a steady movement rather than a flicker.
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
        setAccessibilityLabel("Microphone level")
    }

    required init?(coder: NSCoder) { fatalError("LevelMeterView is created in code") }

    func show(_ level: AudioLevel, at now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        let target = level.meterFraction()
        let elapsed = lastUpdate.map { min(max(now - $0, 0), 1) } ?? 1
        lastUpdate = now
        // Falls a whole meter in 0.6 s.
        shown = max(target, shown - Float(elapsed / 0.6))
        setAccessibilityValue("\(Int(AudioLevel.decibels(level.rms, floor: -60).rounded())) dB")
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
        let fill = CGRect(x: track.minX, y: track.minY, width: max(Self.height, track.width * CGFloat(shown)), height: Self.height)
        DS.Color.bgInverse.setFill()
        NSBezierPath(roundedRect: fill, xRadius: Self.height / 2, yRadius: Self.height / 2).fill()
    }
}

/// The microphone in the control bar: its symbol and level, or a warning badge when it gives no sound. Both states take the same width,
/// so the buttons beside it never move.
final class MicrophoneSlotView: NSView {
    private let symbol = SymbolGlyphView()
    let meter = LevelMeterView()
    let silent = Badge(text: "No sound", symbol: "mic.slash.fill", tone: .warning)
    private(set) var isSilent = false

    static var width: CGFloat { Badge(text: "No sound", symbol: "mic.slash.fill", tone: .warning).intrinsicContentSize.width }

    override init(frame: NSRect) {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: DS.Size.controlSmall))
        symbol.symbol = "mic.fill"
        silent.toolTip = "No sound from the microphone for 3 seconds. Check that it is not muted and its input volume is up."
        silent.setAccessibilityIdentifier("recording.microphoneSilent")
        silent.setAccessibilityLabel("No sound from the microphone")
        silent.setAccessibilityHelp("Check that the microphone is not muted and its input volume is up.")
        meter.setAccessibilityIdentifier("recording.microphoneMeter")
        [symbol, meter, silent].forEach(addSubview)
        apply(nil)
    }

    required init?(coder: NSCoder) { fatalError("MicrophoneSlotView is created in code") }

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
        symbol.frame = CGRect(x: DS.Space.s8 + (DS.Size.iconSmall - icon) / 2, y: (h - icon) / 2, width: icon, height: icon)
        let x = symbol.frame.maxX + DS.Space.s6
        meter.frame = CGRect(x: x, y: 0, width: bounds.width - x - DS.Space.s4, height: h)
        silent.frame = CGRect(x: 0, y: (h - DS.Size.controlSmall) / 2, width: bounds.width, height: DS.Size.controlSmall)
    }
}

/// A symbol in the secondary text colour, resolved at draw time so it follows the appearance.
final class SymbolGlyphView: NSView {
    var symbol = "mic.fill" { didSet { needsDisplay = true } }
    var color = DS.Color.textSecondary { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) { Glyph.draw(symbol, in: bounds, pointSize: DS.Size.icon, color) }
}
