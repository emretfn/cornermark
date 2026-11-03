import AppKit
import KadrajCore

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

public final class EditorWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate {
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
    lazy var resizePanel = ResizePanel(model: model)
    private var toolControl: NSSegmentedControl!
    private var undoControl: NSSegmentedControl!
    private let dragHandle = DragHandleView()
    private var resizePopover: NSPopover?
    private var panelWidth: NSLayoutConstraint!
    private var segmentActions: [String: (Int) -> Void] = [:]

    public init(document: Document, assets: AssetStore, callbacks: EditorCallbacks = EditorCallbacks(),
                defaults: UserDefaults = .standard) {
        self.callbacks = callbacks
        model = EditorModel(document: document, assets: assets, prefs: EditorPreferences(defaults: defaults))
        canvas = CanvasView(model: model)
        propertyBar = PropertyBar(model: model)
        backgroundPanel = BackgroundPanel(model: model)

        let window = EditorWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 860),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
        super.init(window: window)
        window.editor = self
        window.delegate = self
        window.minSize = NSSize(width: 1080, height: 600)
        window.title = "Kadraj"
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.toolbarStyle = .unified
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
        [propertyBar, scroll, backgroundPanel, statusBar].forEach(content.addSubview)
        NSLayoutConstraint.activate([
            propertyBar.topAnchor.constraint(equalTo: content.topAnchor),
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
        undoControl?.setEnabled(model.history.canUndo, forSegment: 0)
        undoControl?.setEnabled(model.history.canRedo, forSegment: 1)
        statusBar.update(model: model, zoom: scroll.zoom)
        if resizePanel.isViewLoaded { resizePanel.refresh() }
        window?.isDocumentEdited = model.history.canUndo
    }

    // MARK: Toolbar

    private enum ItemID {
        static let tools = NSToolbarItem.Identifier("kadraj.tools")
        static let geometry = NSToolbarItem.Identifier("kadraj.geometry")
        static let history = NSToolbarItem.Identifier("kadraj.history")
        static let drag = NSToolbarItem.Identifier("kadraj.drag")
        static let actions = NSToolbarItem.Identifier("kadraj.actions")
    }

    private func buildToolbar(for window: NSWindow) {
        let tools = EditorTool.allCases
        toolControl = NSSegmentedControl(images: tools.map { UI.symbol($0.spec.symbol, $0.spec.title) ?? NSImage() },
                                         trackingMode: .selectOne, target: nil, action: nil)
        toolControl.segmentStyle = .texturedRounded
        toolControl.setAccessibilityIdentifier("toolbar.tools")
        for (i, t) in tools.enumerated() {
            toolControl.setWidth(29, forSegment: i)
            toolControl.setToolTip("\(t.spec.title) (\(String(t.spec.key).uppercased()))", forSegment: i)
        }
        toolControl.onAction { [unowned self] c in model.setTool(tools[(c as! NSSegmentedControl).selectedSegment]) }

        undoControl = momentary(["arrow.uturn.backward", "arrow.uturn.forward"], tips: ["Undo", "Redo"], id: "toolbar.history") { [unowned self] i in
            canvas.cancelGesture()
            if i == 0 { model.undo() } else { model.redo() }
        }
        dragHandle.toolTip = "Drag the rendered image into Finder or any app"
        dragHandle.setAccessibilityIdentifier("toolbar.dragHandle")

        let toolbar = NSToolbar(identifier: "kadraj.editor")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
    }

    private func momentary(_ symbols: [String], tips: [String], id: String, action: @escaping (Int) -> Void) -> NSSegmentedControl {
        let c = NSSegmentedControl(images: symbols.map { UI.symbol($0) ?? NSImage() }, trackingMode: .momentary, target: nil, action: nil)
        c.segmentStyle = .texturedRounded
        c.setAccessibilityIdentifier(id)
        for i in symbols.indices {
            c.setWidth(29, forSegment: i)
            c.setToolTip(tips[i], forSegment: i)
        }
        segmentActions[id] = action
        c.onAction { action(($0 as! NSSegmentedControl).selectedSegment) }
        return c
    }

    public func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [ItemID.tools, .flexibleSpace, ItemID.geometry, ItemID.history, ItemID.drag, ItemID.actions]
    }

    public func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    public func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: id)
        switch id {
        case ItemID.tools:
            item.label = "Tools"; item.view = toolControl
        case ItemID.geometry:
            item.label = "Image"
            let c = momentary(["rotate.right", "arrow.left.and.right.righttriangle.left.righttriangle.right",
                               "arrow.up.and.down.righttriangle.up.righttriangle.down", "arrow.up.left.and.down.right.magnifyingglass"],
                              tips: ["Rotate 90° clockwise", "Flip horizontally", "Flip vertically", "Resize"], id: "toolbar.geometry") { [unowned self] i in
                switch i {
                case 0: perform(.rotateClockwise)
                case 1: perform(.flipHorizontal)
                case 2: perform(.flipVertical)
                default: showResizePanel()
                }
            }
            item.view = c
        case ItemID.history:
            item.label = "History"; item.view = undoControl
        case ItemID.drag:
            item.label = "Drag"; item.view = dragHandle
        case ItemID.actions:
            item.label = "Actions"
            item.view = momentary(["pin", "doc.on.doc", "square.and.arrow.down"], tips: ["Pin to screen", "Copy (⌘C)", "Save image… (⌘S)"], id: "toolbar.actions") { [unowned self] i in
                switch i {
                case 0: callbacks.onPin(renderedImage())
                case 1: copyToPasteboard()
                default: presentSaveImagePanel()
                }
            }
        default:
            return nil
        }
        return item
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

final class StatusBar: BarView {
    var zoomIn: () -> Void = {}
    var zoomOut: () -> Void = {}
    var fit: () -> Void = {}
    private let info = NSTextField(labelWithString: "")
    private let zoomLabel = NSTextField(labelWithString: "100%")

    override init(frame: NSRect) {
        super.init(frame: frame)
        edge = .top
        info.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        info.textColor = .secondaryLabelColor
        zoomLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
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
        ], spacing: 4)
        for v in [info, controls] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 30),
            info.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            info.centerYAnchor.constraint(equalTo: centerYAnchor),
            controls.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
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
