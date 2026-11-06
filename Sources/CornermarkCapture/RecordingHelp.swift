import AppKit
import CornermarkDesign

/// The small window the recording panel's help button opens: what a project recording is, a picture of the editor it opens in, and
/// one button to close it. It sits above the capture overlay, takes the keyboard while it is open, and gives it back when it closes.
final class RecordingHelpWindow: NSPanel {
    static let title = "What is a project recording?"
    static let body = "Record Project keeps your recording editable. After you stop, you can add zooms, change the cursor, add click effects, move or resize the camera, and adjust the sound. Export a video when it looks right."
    static let dismiss = "Close"
    private static let width: CGFloat = 440
    private static let margin = DS.Space.s24

    let closeButton = Button(title: dismiss, variant: .primary, size: .large)
    var onClose: () -> Void = {}

    init(level overlay: NSWindow.Level) {
        let inner = Self.width - 2 * Self.margin
        let titleLabel = NSTextField.wrappingLabel(Self.title, style: DS.Text.title, color: DS.Color.textPrimary, width: inner)
        let bodyLabel = NSTextField.wrappingLabel(Self.body, style: DS.Text.body, color: DS.Color.textSecondary, width: inner)
        let art = RecordingHelpIllustration(frame: CGRect(x: 0, y: 0, width: inner, height: RecordingHelpIllustration.height(for: inner)))
        art.setAccessibilityElement(true)
        art.setAccessibilityRole(.image)
        art.setAccessibilityLabel("The video editor: a zoom on part of the recording, the pointer and a click ring, the camera bubble, and the zoom, clip and sound lanes")
        let titleBar: CGFloat = 28
        var y = Self.margin
        let height = Self.margin + DS.Size.controlLarge + DS.Space.s24 + art.frame.height + DS.Space.s24 + bodyLabel.frame.height
            + DS.Space.s8 + titleLabel.frame.height + DS.Space.s8 + titleBar
        super.init(contentRect: CGRect(x: 0, y: 0, width: Self.width, height: height),
                   styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel], backing: .buffered, defer: false)
        title = Self.title
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        animationBehavior = DS.Motion.isReduced ? .none : .alertPanel
        self.level = NSWindow.Level(rawValue: overlay.rawValue + 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true

        let root = HelpBackground(frame: CGRect(x: 0, y: 0, width: Self.width, height: height))
        closeButton.frame.size.width = max(closeButton.frame.width, 120)
        closeButton.frame.origin = CGPoint(x: (Self.width - closeButton.frame.width) / 2, y: y)
        closeButton.keyEquivalent = "\r"
        closeButton.target = self
        closeButton.action = #selector(closeTapped)
        closeButton.setAccessibilityIdentifier("cornermark.record.help.close")
        root.addSubview(closeButton)
        y += DS.Size.controlLarge + DS.Space.s24
        art.frame.origin = CGPoint(x: Self.margin, y: y)
        root.addSubview(art)
        y += art.frame.height + DS.Space.s24
        bodyLabel.frame.origin = CGPoint(x: Self.margin, y: y)
        bodyLabel.setAccessibilityIdentifier("cornermark.record.help.body")
        root.addSubview(bodyLabel)
        y += bodyLabel.frame.height + DS.Space.s8
        titleLabel.frame.origin = CGPoint(x: Self.margin, y: y)
        titleLabel.setAccessibilityIdentifier("cornermark.record.help.title")
        root.addSubview(titleLabel)
        contentView = root
        initialFirstResponder = closeButton
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) { closeTapped() }

    @objc private func closeTapped() {
        orderOut(nil)
        onClose()
    }
}

private final class HelpBackground: NSView {
    override func draw(_ dirtyRect: NSRect) {
        DS.Color.bgWindow.setFill()
        bounds.fill()
    }
}

private extension NSTextField {
    static func wrappingLabel(_ text: String, style: TextStyle, color: NSColor, width: CGFloat) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = style.font
        label.textColor = color
        label.alignment = .center
        label.isSelectable = false
        label.preferredMaxLayoutWidth = width
        label.frame.size = CGSize(width: width, height: ceil(label.fittingSize.height))
        return label
    }
}

/// A sketch of the video editor drawn from Cornermark's own pieces: a preview with a zoom frame, the pointer, a click ring and the
/// camera bubble over a made-up page, and below it the timeline's zoom lane, clip strip and sound. Nothing in it is a real screenshot.
final class RecordingHelpIllustration: NSView {
    static func height(for width: CGFloat) -> CGFloat { (width * 0.5).rounded() }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let frame = bounds.insetBy(dx: 0.5, dy: 0.5)
        let card = NSBezierPath.continuous(frame, radius: DS.Radius.lg)
        DS.Color.bgCanvas.setFill()
        card.fill()
        DS.Color.borderSubtle.setStroke()
        card.stroke()

        let pad = DS.Space.s12
        let timelineHeight: CGFloat = 54
        let preview = CGRect(x: pad, y: pad, width: bounds.width - 2 * pad, height: bounds.height - 2 * pad - timelineHeight - DS.Space.s8)
        drawPreview(in: preview)
        drawTimeline(in: CGRect(x: pad, y: preview.maxY + DS.Space.s8, width: preview.width, height: timelineHeight))
    }

    /// The made-up page is content, like a recording, so it keeps its own colours in both appearances.
    private func drawPreview(in r: CGRect) {
        let backdrop = NSGradient(starting: NSColor(srgbRed: 0.36, green: 0.42, blue: 0.40, alpha: 1), ending: NSColor(srgbRed: 0.22, green: 0.26, blue: 0.30, alpha: 1))
        backdrop?.draw(in: NSBezierPath.continuous(r, radius: DS.Radius.md), angle: -60)

        let page = r.insetBy(dx: r.width * 0.12, dy: r.height * 0.12)
        let pagePath = NSBezierPath.continuous(page, radius: DS.Radius.sm)
        NSColor(srgbRed: 0.97, green: 0.97, blue: 0.95, alpha: 1).setFill()
        pagePath.fill()
        let ink = NSColor(srgbRed: 0.80, green: 0.81, blue: 0.79, alpha: 1)
        ink.setFill()
        NSBezierPath.continuous(CGRect(x: page.minX, y: page.minY, width: page.width, height: 12), radius: DS.Radius.sm).fill()
        NSColor(srgbRed: 0.90, green: 0.91, blue: 0.89, alpha: 1).setFill()
        CGRect(x: page.minX, y: page.minY + 12, width: page.width * 0.24, height: page.height - 12).fill()
        ink.setFill()
        let text = CGRect(x: page.minX + page.width * 0.30, y: page.minY + 22, width: page.width * 0.62, height: page.height - 32)
        for (i, w) in [0.9, 0.7, 0.8, 0.5].enumerated() {
            NSBezierPath.continuous(CGRect(x: text.minX, y: text.minY + CGFloat(i) * 9, width: text.width * w, height: 4), radius: 2).fill()
        }
        let tile = CGRect(x: text.minX, y: text.minY + 40, width: text.width * 0.42, height: text.maxY - text.minY - 40)
        NSColor(srgbRed: 0.84, green: 0.89, blue: 0.62, alpha: 1).setFill()
        NSBezierPath.continuous(tile, radius: DS.Radius.xs).fill()

        // The zoom's frame, drawn the way the editor draws one over a recording.
        let zoom = tile.insetBy(dx: -8, dy: -6)
        DS.Color.selectionHalo.setStroke()
        let halo = NSBezierPath.continuous(zoom.insetBy(dx: -1, dy: -1), radius: DS.Radius.xs + 1)
        halo.lineWidth = 2
        halo.stroke()
        DS.Color.selectionStroke.setStroke()
        let edge = NSBezierPath.continuous(zoom, radius: DS.Radius.xs)
        edge.lineWidth = 1.5
        edge.stroke()

        let click = CGPoint(x: tile.midX + 6, y: tile.midY + 2)
        let ring = NSBezierPath(ovalIn: CGRect(x: click.x - 11, y: click.y - 11, width: 22, height: 22))
        NSColor(srgbRed: 0.98, green: 0.84, blue: 0.20, alpha: 0.35).setFill()
        ring.fill()
        NSColor(srgbRed: 0.85, green: 0.66, blue: 0.05, alpha: 1).setStroke()
        ring.lineWidth = 1.5
        ring.stroke()
        drawPointer(at: click)

        let d = r.height * 0.34
        let bubble = CGRect(x: r.maxX - d - 10, y: r.maxY - d - 10, width: d, height: d)
        let face = NSBezierPath(ovalIn: bubble)
        NSColor(srgbRed: 0.30, green: 0.34, blue: 0.40, alpha: 1).setFill()
        face.fill()
        NSGraphicsContext.saveGraphicsState()
        face.addClip()
        NSColor(srgbRed: 0.72, green: 0.75, blue: 0.80, alpha: 1).setFill()
        NSBezierPath(ovalIn: CGRect(x: bubble.midX - d * 0.17, y: bubble.minY + d * 0.22, width: d * 0.34, height: d * 0.34)).fill()
        NSBezierPath(ovalIn: CGRect(x: bubble.midX - d * 0.32, y: bubble.minY + d * 0.62, width: d * 0.64, height: d * 0.6)).fill()
        NSGraphicsContext.restoreGraphicsState()
        NSColor.white.withAlphaComponent(0.85).setStroke()
        face.lineWidth = 2
        face.stroke()
    }

    /// The arrow pointer: black with a white edge, tip at `tip`.
    private func drawPointer(at tip: CGPoint) {
        let s: CGFloat = 1.1
        let points: [CGPoint] = [(0, 0), (0, 16), (4, 12.5), (6.6, 18.4), (9.2, 17.3), (6.7, 11.6), (11.6, 11.4)].map { CGPoint(x: tip.x + $0.0 * s, y: tip.y + $0.1 * s) }
        let arrow = NSBezierPath()
        arrow.move(to: points[0])
        points.dropFirst().forEach { arrow.line(to: $0) }
        arrow.close()
        arrow.lineJoinStyle = .round
        NSColor.white.setStroke()
        arrow.lineWidth = 2.4
        arrow.stroke()
        NSColor.black.setFill()
        arrow.fill()
    }

    /// The editor's lanes in the shell's own colours: zooms, the clip with its pictures, and the sound under them.
    private func drawTimeline(in r: CGRect) {
        let lane: CGFloat = 14, gap: CGFloat = 4
        let zoomLane = CGRect(x: r.minX, y: r.minY, width: r.width, height: lane)
        let clipLane = CGRect(x: r.minX, y: zoomLane.maxY + gap, width: r.width, height: lane + 4)
        let soundLane = CGRect(x: r.minX, y: clipLane.maxY + gap, width: r.width, height: r.maxY - clipLane.maxY - gap)
        DS.Color.bgControl.setFill()
        NSBezierPath.continuous(zoomLane, radius: DS.Radius.xs).fill()
        let block = CGRect(x: r.minX + r.width * 0.34, y: zoomLane.minY, width: r.width * 0.22, height: lane)
        DS.Color.bgControlActive.setFill()
        let blockPath = NSBezierPath.continuous(block, radius: DS.Radius.xs)
        blockPath.fill()
        DS.Color.borderStrong.setStroke()
        blockPath.stroke()
        Glyph.draw("plus.magnifyingglass", in: CGRect(x: block.minX + 2, y: block.minY, width: lane, height: lane), pointSize: 9, DS.Color.textPrimary)

        let tones: [(CGFloat, CGFloat, CGFloat)] = [(0.36, 0.42, 0.40), (0.90, 0.91, 0.89), (0.84, 0.89, 0.62), (0.90, 0.91, 0.89), (0.30, 0.34, 0.40)]
        let slot = clipLane.width / CGFloat(tones.count * 2)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath.continuous(clipLane, radius: DS.Radius.xs).addClip()
        for i in 0..<(tones.count * 2) {
            let t = tones[i / 2]
            NSColor(srgbRed: t.0, green: t.1, blue: t.2, alpha: 1).setFill()
            CGRect(x: clipLane.minX + CGFloat(i) * slot, y: clipLane.minY, width: slot - 1, height: clipLane.height).fill()
        }
        NSGraphicsContext.restoreGraphicsState()

        DS.Color.textSecondary.setFill()
        let bars = Int(soundLane.width / 4)
        for i in 0..<bars {
            let phase = Double(i) / Double(bars)
            let level = 0.25 + 0.75 * abs(sin(phase * 19) * cos(phase * 7))
            let h = max(2, soundLane.height * CGFloat(level))
            NSBezierPath.continuous(CGRect(x: soundLane.minX + CGFloat(i) * 4, y: soundLane.midY - h / 2, width: 2, height: h), radius: 1).fill()
        }

        let head = r.minX + r.width * 0.45
        DS.Color.bgInverse.setFill()
        CGRect(x: head - 1, y: r.minY - 2, width: 2, height: r.height + 2).fill()
    }
}
