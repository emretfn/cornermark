import AppKit
import KadrajCore

/// Output scale: the exported size is the canvas size times this.
final class ResizePanel: NSViewController {
    let model: EditorModel
    private let slider = UI.slider(5...400, width: 200, id: "resize.scale")
    private let readout = NSTextField(labelWithString: "")
    private let sizeLabel = NSTextField(labelWithString: "")

    init(model: EditorModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        readout.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        sizeLabel.font = .systemFont(ofSize: 11)
        sizeLabel.textColor = .secondaryLabelColor
        slider.onAction { [unowned self] c in
            model.perform(.setOutputScale((c as! NSSlider).doubleValue / 100), coalescing: "outputScale")
            refresh()
        }
        slider.onTrackingEnd = { [unowned self] in model.endCoalescing() }

        let presets = [25, 50, 100, 200].map { pct -> NSButton in
            let b = NSButton(title: "\(pct)%", target: nil, action: nil)
            b.bezelStyle = .rounded
            b.controlSize = .small
            b.setAccessibilityIdentifier("resize.preset.\(pct)")
            b.onAction { [unowned self] _ in model.perform(.setOutputScale(Double(pct) / 100)); refresh() }
            return b
        }
        let title = NSTextField(labelWithString: "Resize")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        let stack = UI.vstack([title, UI.hstack([slider, readout]), sizeLabel, UI.hstack(presets)], spacing: 10)
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
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
