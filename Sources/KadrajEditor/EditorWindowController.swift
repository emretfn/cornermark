import AppKit
import KadrajCore
import KadrajDesign

public struct EditorCallbacks {
    public var onSaveProject: (Document, AssetStore) -> Void
    public var onPin: (CGImage) -> Void
    public var onCopied: () -> Void
    public var onClose: () -> Void

    public init(onSaveProject: @escaping (Document, AssetStore) -> Void = { _, _ in },
                onPin: @escaping (CGImage) -> Void = { _ in },
                onCopied: @escaping () -> Void = {},
                onClose: @escaping () -> Void = {}) {
        self.onSaveProject = onSaveProject
        self.onPin = onPin
        self.onCopied = onCopied
        self.onClose = onClose
    }
}

final class EditorWindow: NSWindow {
    weak var editor: EditorWindowController?

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, editor?.handleKeyDown(event) == true { return }
        super.sendEvent(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if editor?.handleKeyDown(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
}

public final class EditorWindowController: NSWindowController, NSWindowDelegate {
    public static let canvasMargin = CanvasView.margin

    public var callbacks: EditorCallbacks
    /// Where Cmd+C writes. Tests point this at a private pasteboard.
    public var pasteboard: NSPasteboard = .general

    let model: EditorModel
    let canvas: CanvasView
    let scroll = CanvasScrollView()
    let propertyBar: PropertyBar
    let backgroundPanel: BackgroundPanel
    let statusBar = StatusBar()
    private let titleBar = TitleBar()
    lazy var resizePanel = ResizePanel(model: model)
    private var toolControl: Segments!
    private var undoControl: Segments!
    private let dragHandle = DragHandleView()
    private var resizePopover: NSPopover?
    private var panelWidth: NSLayoutConstraint!
    private var copyButton: Button?
    private var segmentActions: [String: (Int) -> Void] = [:]

    public init(document: Document, assets: AssetStore, callbacks: EditorCallbacks = EditorCallbacks(),
                defaults: UserDefaults = .standard) {
        self.callbacks = callbacks
        model = EditorModel(document: document, assets: assets, prefs: EditorPreferences(defaults: defaults))
        canvas = CanvasView(model: model)
        propertyBar = PropertyBar(model: model)
        backgroundPanel = BackgroundPanel(model: model)

        let window = EditorWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 860),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
        super.init(window: window)
        window.editor = self
        window.delegate = self
        window.minSize = NSSize(width: 1080, height: 600)
        window.title = "Kadraj"
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.toolbarStyle = .unified
        window.titlebarAppearsTransparent = true
        window.backgroundColor = DS.Color.bgSurface
        buildContent(in: window)
        buildToolbar(for: window)
        wire()
        window.center()
        refreshUI(.all)
    }

    public required init?(coder: NSCoder) { fatalError("EditorWindowController is created in code") }

    // MARK: Public surface

    public var history: EditHistory { model.history }
    public var currentDocument: Document { model.document }
    public var assets: AssetStore { model.assets }

    public var currentTool: EditorTool {
        get { model.tool }
        set { model.setTool(newValue) }
    }

    public var selection: UUID? { model.selection }

    public func perform(_ command: EditCommand) { model.perform(command) }

    public func renderedImage() -> CGImage { Renderer.render(model.document, assets: model.assets) }

    public var zoom: CGFloat {
        get { scroll.zoom }
        set { scroll.setZoom(newValue) }
    }

    /// The view annotations are drawn and edited in. Events sent to it behave as in the running app.
    public var canvasView: NSView { canvas }

    public func select(_ id: UUID?) { model.select(id) }

    /// Finds a control by accessibility identifier anywhere in the window, toolbar and resize panel included.
    public func view(identifier: String) -> NSView? { allViews(identifier: identifier).first }

    public func allViews(identifier: String) -> [NSView] {
        var roots: [NSView] = []
        if let frame = window?.contentView?.superview { roots.append(frame) }
        if resizePanel.isViewLoaded { roots.append(resizePanel.view) }
        return roots.flatMap { Self.collect(identifier, in: $0) }
    }

    private static func collect(_ id: String, in view: NSView) -> [NSView] {
        (view.accessibilityIdentifier() == id ? [view] : []) + view.subviews.flatMap { collect(id, in: $0) }
    }

    // MARK: Layout

    private func buildContent(in window: NSWindow) {
        scroll.documentView = canvas
        scroll.canvas = canvas
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.setAccessibilityIdentifier("canvas.scroll")
        propertyBar.translatesAutoresizingMaskIntoConstraints = false
        backgroundPanel.translatesAutoresizingMaskIntoConstraints = false
        statusBar.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        window.contentView = content
        titleBar.translatesAutoresizingMaskIntoConstraints = false
        [titleBar, propertyBar, scroll, backgroundPanel, statusBar].forEach(content.addSubview)
        NSLayoutConstraint.activate([
            titleBar.topAnchor.constraint(equalTo: content.topAnchor),
            titleBar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            titleBar.trailingAnchor.constraint(equalTo: content.trailingAnchor),

            propertyBar.topAnchor.constraint(equalTo: titleBar.bottomAnchor),
            propertyBar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            propertyBar.trailingAnchor.constraint(equalTo: content.trailingAnchor),

            scroll.topAnchor.constraint(equalTo: propertyBar.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.bottomAnchor.constraint(equalTo: statusBar.topAnchor),

            backgroundPanel.topAnchor.constraint(equalTo: propertyBar.bottomAnchor),
            backgroundPanel.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
            backgroundPanel.leadingAnchor.constraint(equalTo: scroll.trailingAnchor),
            backgroundPanel.trailingAnchor.constraint(equalTo: content.trailingAnchor),

            statusBar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        panelWidth = backgroundPanel.widthAnchor.constraint(equalToConstant: 0)
        panelWidth.isActive = true
        let flush = scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor)
        flush.priority = .defaultLow
        flush.isActive = true
    }

    private func wire() {
        model.onChange = { [weak self] change in self?.refreshUI(change) }
        scroll.onZoomChange = { [weak self] in self?.statusBar.update(model: self!.model, zoom: self!.scroll.zoom) }
        propertyBar.setAspect = { [unowned self] in canvas.setCropAspect($0) }
        propertyBar.applyCrop = { [unowned self] in applyCrop() }
        propertyBar.cancelCrop = { [unowned self] in cancelCrop() }
        statusBar.zoomIn = { [unowned self] in scroll.zoomBy(1.25) }
        statusBar.zoomOut = { [unowned self] in scroll.zoomBy(0.8) }
        statusBar.fit = { [unowned self] in scroll.fit() }
        dragHandle.provider = { [unowned self] in
            guard let url = try? makeDragFile() else { return nil }
            let cg = renderedImage()
            return (url, NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height)))
        }
    }

    func refreshUI(_ change: Change) {
        canvas.modelChanged(change)
        propertyBar.reload()
        let showPanel = model.tool == .background
        backgroundPanel.isHidden = !showPanel
        panelWidth.constant = showPanel ? BackgroundPanel.width : 0
        backgroundPanel.reload()
        if let i = EditorTool.allCases.firstIndex(of: model.tool), toolControl.selectedSegment != i { toolControl.selectedSegment = i }
        // A view has one primary action, and while cropping that is Apply.
        copyButton?.variant = model.tool == .crop ? .secondary : .primary
        undoControl?.setEnabled(model.history.canUndo, forSegment: 0)
        undoControl?.setEnabled(model.history.canRedo, forSegment: 1)
        statusBar.update(model: model, zoom: scroll.zoom)
        if resizePanel.isViewLoaded { resizePanel.refresh() }
        window?.isDocumentEdited = model.history.canUndo
    }

    // MARK: Toolbar

    /// Tool order in the toolbar is `EditorTool.allCases`; a divider goes after the last tool of every group but the final one.
    private static let toolGroups: [[EditorTool]] = [
        [.select],
        [.arrow, .line, .rect, .filledRect, .ellipse, .filledEllipse],
        [.text, .counter],
        [.pencil, .highlighter],
        [.blur, .pixelate, .spotlight],
        [.crop, .background],
    ]

    static var toolDividers: Set<Int> {
        precondition(toolGroups.flatMap { $0 } == EditorTool.allCases, "toolbar groups must follow the tool order")
        return Set(toolGroups.dropLast().reduce(into: [Int]()) { $0.append(($0.last ?? -1) + $1.count) })
    }

    private func buildToolbar(for window: NSWindow) {
        let tools = EditorTool.allCases
        toolControl = Segments(symbols: tools.map { $0.spec.symbol }, labels: tools.map { $0.spec.title })
        toolControl.dividers = Self.toolDividers
        toolControl.setAccessibilityIdentifier("toolbar.tools")
        for (i, t) in tools.enumerated() {
            toolControl.setToolTip("\(t.spec.title) (\(String(t.spec.key).uppercased()))", forSegment: i)
        }
        toolControl.onAction { [unowned self] c in model.setTool(tools[(c as! NSSegmentedControl).selectedSegment]) }

        undoControl = momentary(["arrow.uturn.backward", "arrow.uturn.forward"], tips: ["Undo", "Redo"], id: "toolbar.history") { [unowned self] i in
            canvas.cancelGesture()
            if i == 0 { model.undo() } else { model.redo() }
        }
        dragHandle.toolTip = "Drag the rendered image into Finder or any app"
        dragHandle.setAccessibilityIdentifier("toolbar.dragHandle")

        // An empty toolbar gives the taller title bar with centred window buttons. The controls live in `titleBar` instead of
        // toolbar items, because macOS 26 puts every toolbar item on a glass capsule that no public API removes.
        window.toolbar = NSToolbar(identifier: "kadraj.editor")
        let leading = (window.standardWindowButton(.zoomButton)?.frame.maxX ?? 68) + DS.Space.s16
        // The row is as tall as it takes to sit on the window buttons' centre line, which the system decides.
        window.layoutIfNeeded()
        let buttonCentre = window.standardWindowButton(.zoomButton).flatMap { button -> CGFloat? in
            guard let frame = window.contentView?.superview else { return nil }
            let rect = button.convert(button.bounds, to: frame)
            return frame.isFlipped ? rect.midY : frame.bounds.height - rect.midY
        }
        titleBar.heightAnchor.constraint(equalToConstant: 2 * (buttonCentre ?? 26)).isActive = true
        let spacer = NSView()
        spacer.setContentHuggingPriority(.fittingSizeCompression, for: .horizontal)
        let row = NSStackView(views: [toolControl, spacer, geometryControl(), undoControl, dragHandle, actionsView()])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = DS.Space.s8
        row.translatesAutoresizingMaskIntoConstraints = false
        titleBar.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: titleBar.leadingAnchor, constant: leading),
            row.trailingAnchor.constraint(equalTo: titleBar.trailingAnchor, constant: -DS.Space.s12),
            row.centerYAnchor.constraint(equalTo: titleBar.centerYAnchor),
        ])
    }

    private func momentary(_ symbols: [String], tips: [String], id: String, action: @escaping (Int) -> Void) -> Segments {
        let c = Segments(symbols: symbols, labels: tips, trackingMode: .momentary, quiet: true)
        c.setAccessibilityIdentifier(id)
        for i in symbols.indices { c.setToolTip(tips[i], forSegment: i) }
        segmentActions[id] = action
        c.onAction { action(($0 as! NSSegmentedControl).selectedSegment) }
        return c
    }

    private func geometryControl() -> NSView {
        momentary(["rotate.right", "arrow.left.and.right.righttriangle.left.righttriangle.right",
                   "arrow.up.and.down.righttriangle.up.righttriangle.down", "arrow.up.left.and.down.right.magnifyingglass"],
                  tips: ["Rotate 90° clockwise", "Flip horizontally", "Flip vertically", "Resize"], id: "toolbar.geometry") { [unowned self] i in
            switch i {
            case 0: perform(.rotateClockwise)
            case 1: perform(.flipHorizontal)
            case 2: perform(.flipVertical)
            default: showResizePanel()
            }
        }
    }

    /// Pin and save are segments of "toolbar.actions"; Copy is the view's one primary button. Both reach the same
    /// closure under the indices automation uses: 0 pin, 1 copy, 2 save.
    private func actionsView() -> NSView {
        let run: (Int) -> Void = { [unowned self] i in
            switch i {
            case 0: callbacks.onPin(renderedImage())
            case 1: copyToPasteboard()
            default: presentSaveImagePanel()
            }
        }
        segmentActions["toolbar.actions"] = run
        let segments = Segments(symbols: ["pin", "square.and.arrow.down"], labels: ["Pin to screen", "Save image… (⌘S)"], trackingMode: .momentary, quiet: true)
        segments.setAccessibilityIdentifier("toolbar.actions")
        for (i, tip) in ["Pin to screen", "Save image… (⌘S)"].enumerated() { segments.setToolTip(tip, forSegment: i) }
        segments.onAction { c in run([0, 2][(c as! NSSegmentedControl).selectedSegment]) }

        let copy = Button(title: "Copy", variant: .primary)
        copyButton = copy
        copy.toolTip = "Copy (⌘C)"
        copy.setAccessibilityIdentifier("toolbar.copy")
        copy.onAction { _ in run(1) }
        return UI.hstack([segments, copy], spacing: DS.Space.s8)
    }

    /// Orders the editor on screen and makes it key. Creating the controller never shows anything.
    public func show() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Runs the action a click on segment `index` of a toolbar button group triggers (for automation).
    public func pressToolbarButton(_ identifier: String, segment index: Int) { segmentActions[identifier]?(index) }

    /// The resize panel's content, loaded without presenting it (for automation).
    public func loadResizePanelView() -> NSView {
        resizePanel.refresh()
        return resizePanel.view
    }

    func showResizePanel() {
        let popover = resizePopover ?? NSPopover()
        popover.behavior = .transient
        popover.contentViewController = resizePanel
        resizePopover = popover
        resizePanel.refresh()
        guard let anchor = view(identifier: "toolbar.geometry") else { return }
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
    }

    public func windowWillClose(_ notification: Notification) {
        canvas.cancelGesture()
        callbacks.onClose()
    }
}

/// The toolbar row, drawn under the transparent title bar. Empty parts of it drag the window as a title bar does.
final class TitleBar: NSView {
    override var mouseDownCanMoveWindow: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        DS.Color.bgSurface.setFill()
        bounds.fill()
    }
}

final class StatusBar: BarView {
    var zoomIn: () -> Void = {}
    var zoomOut: () -> Void = {}
    var fit: () -> Void = {}
    private let info = NSTextField.label("", style: DS.Text.readout, color: DS.Color.textSecondary)
    private let zoomLabel = NSTextField.label("100%", style: DS.Text.readout, color: DS.Color.textPrimary)

    override init(frame: NSRect) {
        super.init(frame: frame)
        edge = .top
        zoomLabel.alignment = .center
        zoomLabel.widthAnchor.constraint(equalToConstant: 44).isActive = true
        zoomLabel.setAccessibilityIdentifier("status.zoom")

        func small(_ symbol: String, _ tip: String, _ id: String, _ action: @escaping () -> Void) -> NSButton {
            let b = UI.button(symbol: symbol, tip: tip, id: id)
            b.onAction { _ in action() }
            return b
        }
        let controls = UI.hstack([
            small("minus", "Zoom out (⌘−)", "status.zoomOut") { [unowned self] in zoomOut() },
            zoomLabel,
            small("plus", "Zoom in (⌘+)", "status.zoomIn") { [unowned self] in zoomIn() },
            small("arrow.up.left.and.down.right.and.arrow.up.right.and.down.left", "Fit to window (⌘0)", "status.fit") { [unowned self] in fit() },
        ], spacing: DS.Space.s4)
        for v in [info, controls] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: DS.Size.control + DS.Space.s4),
            info.leadingAnchor.constraint(equalTo: leadingAnchor, constant: DS.Space.s16),
            info.centerYAnchor.constraint(equalTo: centerYAnchor),
            controls.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -DS.Space.s12),
            controls.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(model: EditorModel, zoom: CGFloat) {
        zoomLabel.stringValue = "\(Int((zoom * 100).rounded()))%"
        let doc = model.document
        let out = Renderer.canvasSize(doc, assets: model.assets)
        var parts = ["Source \(Int(doc.pixelSize.width)) × \(Int(doc.pixelSize.height))"]
        if let c = doc.crop { parts.append("Crop \(Int(c.width)) × \(Int(c.height))") }
        parts.append("Output \(Int(out.width)) × \(Int(out.height)) px")
        parts.append("\(doc.annotations.count) annotation\(doc.annotations.count == 1 ? "" : "s")")
        info.stringValue = parts.joined(separator: "   ·   ")
    }
}
