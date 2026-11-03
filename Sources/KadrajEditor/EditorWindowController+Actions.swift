import AppKit
import KadrajCore
import UniformTypeIdentifiers

/// A key chord, matched against the table below.
struct Shortcut: Hashable {
    var key: String
    var command = false
    var shift = false

    init(_ key: String, command: Bool = false, shift: Bool = false) {
        self.key = key; self.command = command; self.shift = shift
    }

    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.control) || flags.contains(.option) { return nil }
        command = flags.contains(.command)
        shift = flags.contains(.shift)
        switch event.keyCode {
        case 53: key = "esc"
        case 36, 76: key = "return"
        case 51, 117: key = "delete"
        case 123: key = "left"
        case 124: key = "right"
        case 125: key = "down"
        case 126: key = "up"
        default:
            guard let chars = event.charactersIgnoringModifiers?.lowercased(), chars.count == 1 else { return nil }
            key = chars
        }
    }
}

extension EditorWindowController {
    typealias Action = (EditorWindowController) -> Void

    static let commands: [Shortcut: Action] = [
        Shortcut("z", command: true): { $0.undo() },
        Shortcut("z", command: true, shift: true): { $0.redo() },
        Shortcut("c", command: true): { $0.copyToPasteboard() },
        Shortcut("v", command: true): { $0.pasteImage() },
        Shortcut("s", command: true): { $0.presentSaveImagePanel() },
        Shortcut("s", command: true, shift: true): { $0.presentSaveProjectPanel() },
        Shortcut("=", command: true): { $0.scroll.zoomBy(1.25) },
        Shortcut("+", command: true): { $0.scroll.zoomBy(1.25) },
        Shortcut("+", command: true, shift: true): { $0.scroll.zoomBy(1.25) },
        Shortcut("-", command: true): { $0.scroll.zoomBy(0.8) },
        Shortcut("0", command: true): { $0.scroll.fit() },
        Shortcut("1", command: true): { $0.scroll.setZoom(1) },
        Shortcut("esc"): { $0.escape() },
        Shortcut("return"): { $0.returnKey() },
        Shortcut("delete"): { $0.deleteSelection() },
        Shortcut("left"): { $0.nudge(-1, 0, 1) }, Shortcut("right"): { $0.nudge(1, 0, 1) },
        Shortcut("up"): { $0.nudge(0, -1, 1) }, Shortcut("down"): { $0.nudge(0, 1, 1) },
        Shortcut("left", shift: true): { $0.nudge(-1, 0, 10) }, Shortcut("right", shift: true): { $0.nudge(1, 0, 10) },
        Shortcut("up", shift: true): { $0.nudge(0, -1, 10) }, Shortcut("down", shift: true): { $0.nudge(0, 1, 10) },
    ]

    /// Returns true when the editor consumed the key. Keys typed into a text field or the inline text editor are left alone.
    func handleKeyDown(_ event: NSEvent) -> Bool {
        if window?.firstResponder is NSText { return false }
        guard let chord = Shortcut(event: event) else { return false }
        if let action = Self.commands[chord] {
            action(self)
            return true
        }
        if !chord.command, let tool = ToolRegistry.tool(forKey: Character(chord.key), shift: chord.shift) {
            model.setTool(tool)
            return true
        }
        return false
    }

    func undo() { canvas.cancelGesture(); model.undo() }
    func redo() { canvas.cancelGesture(); model.redo() }

    func escape() {
        switch canvas.gesture {
        case .editingText, .drawing, .moving, .resizing, .cropping:
            canvas.cancelGesture()
        case .idle:
            if model.tool == .crop { cancelCrop() } else { model.select(nil) }
        }
    }

    func returnKey() {
        if model.tool == .crop { applyCrop() }
    }

    func applyCrop() {
        guard let draft = model.cropDraft else { return }
        model.perform(.setCrop(draft.rect))
        model.setTool(.select)
    }

    func cancelCrop() {
        canvas.cancelGesture()
        model.setTool(.select)
    }

    func deleteSelection() {
        guard model.tool == .select, let id = model.selection else { return }
        model.perform(.remove(id))
    }

    func nudge(_ dx: CGFloat, _ dy: CGFloat, _ step: CGFloat) {
        guard model.tool == .select, let ann = model.selectedAnnotation else { return }
        model.perform(.update(ann.translated(by: CGVector(dx: dx * step, dy: dy * step))), coalescing: CoalescingKey("nudge.\(ann.id)"))
    }

    // MARK: Output

    public func copyToPasteboard() {
        let cg = renderedImage()
        guard let png = try? Exporter.data(from: cg, format: .png, dpi: Exporter.dpi(for: model.document)) else { return }
        let scale = max(model.document.pointScale, 1)
        let image = NSImage(cgImage: cg, size: NSSize(width: Double(cg.width) / scale, height: Double(cg.height) / scale))
        pasteboard.clearContents()
        pasteboard.writeObjects([image])
        pasteboard.setData(png, forType: .png)
        callbacks.onCopied()
    }

    public func pasteImage() {
        let center = canvas.sourcePoint(canvas.convert(canvas.visibleRect.center, to: canvas))
        guard let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff) else { return }
        canvas.addImage(data, centeredAt: center)
    }

    /// Adds the images on `pasteboard` as `.image` annotations centred at a window point, as a drop on the canvas does.
    @discardableResult
    public func drop(_ pasteboard: NSPasteboard, atWindowPoint point: CGPoint) -> Bool {
        canvas.handleDrop(pasteboard, atViewPoint: canvas.convert(point, from: nil))
    }

    public var stylePresetNames: [String] { model.stylePresetsForTool.map(\.name) }
    public func saveStylePreset(named name: String) { model.saveStylePreset(named: name) }
    public func applyStylePreset(named name: String) {
        if let p = model.stylePresetsForTool.first(where: { $0.name == name }) { model.applyStylePreset(p) }
    }

    public func exportImage(to url: URL, format: ExportFormat? = nil) throws {
        let chosen = format ?? (["jpg", "jpeg"].contains(url.pathExtension.lowercased()) ? .jpeg : .png)
        try Exporter.export(model.document, assets: model.assets, format: chosen, to: url)
    }

    public func saveProject(to url: URL) throws {
        try ProjectFile.write(model.document, assets: model.assets, to: url)
        callbacks.onSaveProject(model.document, model.assets)
    }

    /// A PNG of the current render in a temp folder, for the "Drag me" handle.
    public func makeDragFile() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("KadrajDrag", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let url = dir.appendingPathComponent("Kadraj \(stamp.string(from: Date())).png")
        try exportImage(to: url, format: .png)
        return url
    }

    func presentSaveImagePanel() {
        guard let window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png, .jpeg]
        panel.nameFieldStringValue = "Kadraj.png"
        panel.canCreateDirectories = true
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do { try self?.exportImage(to: url) } catch { NSAlert(error: error).beginSheetModal(for: window) }
        }
    }

    func presentSaveProjectPanel() {
        guard let window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "kadraj", conformingTo: .package) ?? .package]
        panel.nameFieldStringValue = "Untitled.kadraj"
        panel.canCreateDirectories = true
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do { try self?.saveProject(to: url) } catch { NSAlert(error: error).beginSheetModal(for: window) }
        }
    }
}

extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}
