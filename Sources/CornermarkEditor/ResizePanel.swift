import AppKit
import CornermarkDesign
import CornermarkCore
import CornermarkL10n

/// Output scale: the exported size is the canvas size times this.
final class ResizePanel: NSViewController {
    /// Four equal presets with s8 between them set the width every row shares, so everything ends on one right edge.
    private static let presetWidth: CGFloat = 60
    private static let presets = [25, 50, 100, 200]
    static let contentWidth = CGFloat(presets.count) * presetWidth + CGFloat(presets.count - 1) * DS.Space.s8
    private static let readoutWidth: CGFloat = 44

    let model: EditorModel
    private let slider = UI.slider(5...400, width: nil, id: "resize.scale")
    private let readout = NSTextField.label("", style: DS.Text.readout, color: DS.Color.textPrimary)
    private let sizeLabel = NSTextField.label("", style: DS.Text.caption, color: DS.Color.textSecondary)
    private let titleLabel = NSTextField.label("", style: DS.Text.heading, color: DS.Color.textPrimary)
    private var presetButtons: [(button: Button, percent: Int)] = []

    init(model: EditorModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        readout.alignment = trailingAlignment
        readout.widthAnchor.constraint(equalToConstant: Self.readoutWidth).isActive = true
        slider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        slider.onAction { [unowned self] c in
            model.perform(.setOutputScale((c as! NSSlider).doubleValue / 100), coalescing: "outputScale")
            refresh()
        }
        slider.onTrackingEnd = { [unowned self] in model.endCoalescing() }

        let buttons = Self.presets.map { pct -> Button in
            let b = Button(title: Digits.percent(CGFloat(pct) / 100), variant: .secondary, size: .small)
            b.setAccessibilityIdentifier("resize.preset.\(pct)")
            b.onAction { [unowned self] _ in model.perform(.setOutputScale(Double(pct) / 100)); refresh() }
            presetButtons.append((b, pct))
            return b
        }
        let presets = UI.hstack(buttons, spacing: DS.Space.s8)
        presets.distribution = .fillEqually
        let scale = UI.hstack([slider, readout], spacing: DS.Space.s8)
        let stack = UI.vstack([titleLabel, scale, sizeLabel, presets], spacing: DS.Space.s12)
        stack.setCustomSpacing(DS.Space.s4, after: scale)
        stack.edgeInsets = NSEdgeInsets(top: DS.Space.s16, left: DS.Space.s16, bottom: DS.Space.s16, right: DS.Space.s16)
        for row in [scale, presets] { row.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true }
        // A leading-aligned stack does not reserve its trailing inset, so the panel's width is stated.
        stack.widthAnchor.constraint(equalToConstant: Self.contentWidth + 2 * DS.Space.s16).isActive = true
        view = stack
        relocalize()
    }

    /// Swaps the text in place, so a panel that is open stays open.
    func relocalize() {
        titleLabel.stringValue = tr("Resize")
        readout.alignment = trailingAlignment
        for (button, percent) in presetButtons {
            button.title = Digits.percent(CGFloat(percent) / 100)
            button.setAccessibilityLabel(button.title)
        }
        view.applyLanguageDirection()
        refresh()
    }

    func refresh() {
        let doc = model.document
        slider.doubleValue = doc.outputScale * 100
        readout.stringValue = Digits.percent(CGFloat(doc.outputScale))
        let size = Renderer.canvasSize(doc, assets: model.assets)
        sizeLabel.stringValue = tr("Exports at {size} px", ["size": Digits.size(size)])
    }
}
