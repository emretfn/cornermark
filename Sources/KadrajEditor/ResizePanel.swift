import AppKit
import KadrajDesign
import KadrajCore

/// Output scale: the exported size is the canvas size times this.
final class ResizePanel: NSViewController {
    let model: EditorModel
    private let slider = UI.slider(5...400, width: 200, id: "resize.scale")
    private let readout = NSTextField.label("", style: DS.Text.readout, color: DS.Color.textPrimary)
    private let sizeLabel = NSTextField.label("", style: DS.Text.caption, color: DS.Color.textSecondary)

    init(model: EditorModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        readout.alignment = .right
        readout.widthAnchor.constraint(equalToConstant: 40).isActive = true
        slider.onAction { [unowned self] c in
            model.perform(.setOutputScale((c as! NSSlider).doubleValue / 100), coalescing: "outputScale")
            refresh()
        }
        slider.onTrackingEnd = { [unowned self] in model.endCoalescing() }

        let presets = [25, 50, 100, 200].map { pct -> Button in
            let b = Button(title: "\(pct)%", variant: .secondary, size: .small)
            b.setAccessibilityIdentifier("resize.preset.\(pct)")
            b.onAction { [unowned self] _ in model.perform(.setOutputScale(Double(pct) / 100)); refresh() }
            return b
        }
        let title = NSTextField.label("Resize", style: DS.Text.bodyStrong, color: DS.Color.textPrimary)
        let stack = UI.vstack([title, UI.hstack([slider, readout], spacing: DS.Space.s8), sizeLabel, UI.hstack(presets, spacing: DS.Space.s8)], spacing: DS.Space.s12)
        stack.edgeInsets = NSEdgeInsets(top: DS.Space.s16, left: DS.Space.s16, bottom: DS.Space.s16, right: DS.Space.s16)
        view = stack
        refresh()
    }

    func refresh() {
        let doc = model.document
        slider.doubleValue = doc.outputScale * 100
        readout.stringValue = "\(Int((doc.outputScale * 100).rounded()))%"
        let size = Renderer.canvasSize(doc, assets: model.assets)
        sizeLabel.stringValue = "Exports at \(Int(size.width)) × \(Int(size.height)) px"
    }
}
