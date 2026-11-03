import AppKit
import KadrajCore

extension CanvasView {
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        Self.images(in: sender.draggingPasteboard).isEmpty ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        handleDrop(sender.draggingPasteboard, atViewPoint: convert(sender.draggingLocation, from: nil))
    }

    private static func images(in pasteboard: NSPasteboard) -> [Data] {
        var out: [Data] = []
        let urls = pasteboard.readObjects(forClasses: [NSURL.self],
                                          options: [.urlReadingFileURLsOnly: true,
                                                    .urlReadingContentsConformToTypes: NSImage.imageTypes]) as? [URL] ?? []
        for url in urls { if let data = try? Data(contentsOf: url) { out.append(data) } }
        if out.isEmpty, let png = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff) { out.append(png) }
        return out
    }

    /// Adds every image on the pasteboard as a movable, resizable `.image` annotation centred at `view`.
    @discardableResult
    func handleDrop(_ pasteboard: NSPasteboard, atViewPoint view: CGPoint) -> Bool {
        let center = sourcePoint(view)
        var added = false
        for (i, data) in Self.images(in: pasteboard).enumerated() {
            let offset = CGFloat(i) * 24
            added = addImage(data, centeredAt: CGPoint(x: center.x + offset, y: center.y + offset)) || added
        }
        return added
    }

    @discardableResult
    func addImage(_ data: Data, centeredAt center: CGPoint) -> Bool {
        guard let id = model.assets.add(encoded: data), let size = model.assets.pixelSize(of: id), size.width > 0, size.height > 0 else {
            return false
        }
        let bounds = model.document.sourceBounds
        let fit = min(1, bounds.width * 0.5 / size.width, bounds.height * 0.5 / size.height)
        let w = size.width * fit, h = size.height * fit
        var origin = CGPoint(x: center.x - w / 2, y: center.y - h / 2)
        origin.x = min(max(origin.x, 0), max(bounds.width - w, 0))
        origin.y = min(max(origin.y, 0), max(bounds.height - h, 0))
        let ann = Annotation(kind: .image(CGRect(origin: origin, size: CGSize(width: w, height: h)), asset: id),
                             stroke: model.styles[.select]?.stroke ?? Stroke(color: Palette.red, width: 1))
        model.perform(.add(ann))
        model.setTool(.select)
        model.select(ann.id)
        return true
    }
}
