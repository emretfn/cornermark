import AppKit
import KadrajCore
import KadrajEditor
@testable import KadrajShell

@MainActor
func seedHistory(_ w: World) -> [CaptureRecord] {
    let now = w.now
    let day: TimeInterval = 86_400
    let plan: [(CaptureKind, TimeInterval, String)] = [
        (.area, 0, "Area today"), (.window, 3600, "Window today"), (.fullscreen, -day, "Fullscreen yesterday"),
        (.scrolling, -3 * day, "Scrolling 3d"), (.area, -4 * day, "Area 4d"), (.imported, -12 * day, "Imported 12d"),
        (.timed, -20 * day, "Timer 20d"),
    ]
    return plan.enumerated().map { i, p in
        try! w.store.add(Pix.flat(640 + i * 40, 400, r: Double(i) / 7, g: 0.45, b: 0.8 - Double(i) / 12, label: p.2), kind: p.0,
                         now: now.addingTimeInterval(p.1 - 3600))
    }
}

@MainActor
func checkHistory() async throws {
    section("History: grouping, filter, thumbnails, actions")
    let w = try World(after: [.showOverlay])
    defer { w.cleanup() }
    let c = w.coordinator
    let records = seedHistory(w)
    c.perform(.openHistory)
    let h = c.history!
    check(h.records.count == 7, "history lists all seven captures")
    check(h.sections.map(\.title) == ["Today", "Yesterday", "Previous 7 Days", "Earlier"], "date groups", detail: "\(h.sections.map(\.title))")
    check(h.sections.map { $0.records.count } == [2, 1, 2, 2], "group sizes", detail: "\(h.sections.map { $0.records.count })")
    check(h.records.map(\.createdAt) == h.records.map(\.createdAt).sorted(by: >), "newest first across groups")

    for (filter, kinds) in [(HistoryFilter.area, 2), (.window, 1), (.fullscreen, 1), (.scrolling, 1), (.timed, 1), (.imported, 1), (.all, 7)] {
        h.setFilter(filter)
        check(h.records.count == kinds && h.records.allSatisfy { filter.kinds?.contains($0.kind) ?? true }, "filter \(filter.title): \(kinds)", detail: "\(h.records.count)")
    }
    h.setFilter(.all)

    h.window?.setContentSize(NSSize(width: 920, height: 1800))
    h.window?.contentView?.layoutSubtreeIfNeeded()
    h.collectionView.layoutSubtreeIfNeeded()
    check(h.collectionView.numberOfSections == 4 && h.collectionView.numberOfItems(inSection: 3) == 2, "collection view mirrors the sections")
    let items = (0..<4).flatMap { s in (0..<h.collectionView.numberOfItems(inSection: s)).compactMap { h.collectionView.item(at: IndexPath(item: $0, section: s)) } }
    check(items.count == 7, "all seven items were instantiated", detail: "\(items.count)")

    let px = HistoryWindowController.thumbnailPixels
    check(await waitUntil { h.records.allSatisfy { h.thumbnails.cached($0.id, maxPixel: px) != nil } }, "thumbnails arrive and are cached")
    check(h.thumbnails.generationsOffMainThread == 7 && h.thumbnails.generationsOnMainThread == 0, "every thumbnail was generated off the main thread",
          detail: "off \(h.thumbnails.generationsOffMainThread) main \(h.thumbnails.generationsOnMainThread)")
    check(h.records.allSatisfy { r in h.thumbnails.cached(r.id, maxPixel: px).map { max($0.width, $0.height) <= px } == true }, "thumbnails are at most \(px) px")
    h.reload()
    h.collectionView.layoutSubtreeIfNeeded()
    check(await waitUntil { h.thumbnails.generationsOffMainThread == 7 }, "reloading uses the cache: no regeneration", detail: "\(h.thumbnails.generationsOffMainThread)")

    var delivered: CGImage?
    h.thumbnails.load(id: records[0].id, file: w.store.paths(for: records[0]).image, maxPixel: px) { delivered = $0 }
    check(await waitUntil { delivered != nil }, "cache hit still completes on the main thread")

    let first = h.records[0]
    h.select(recordIDs: [first.id])
    check(h.selectedRecords.map(\.id) == [first.id] && h.actionButtons.values.allSatisfy(\.isEnabled), "selecting enables the action buttons")
    h.select(recordIDs: [])
    check(h.actionButtons.values.allSatisfy { !$0.isEnabled }, "no selection disables them")

    h.select(recordIDs: [first.id])
    check(click("history.restore", in: h.window?.contentView), "Show Overlay clicked")
    check(c.overlay.card(forRecord: first.id) != nil, "restore: a Quick Access card for that capture appeared")
    check(click("history.copy", in: h.window?.contentView) && w.pasteboardImage()?.width == Int(first.pixelSize.width), "copy: capture is on the pasteboard")
    check(click("history.reveal", in: h.window?.contentView) && w.revealed == [w.store.paths(for: first).image], "reveal: Finder gets the image path", detail: "\(w.revealed)")
    check(click("history.edit", in: h.window?.contentView) && c.editors[first.id] != nil, "edit: editor built for the capture")

    let victims = Array(h.records.suffix(2))
    h.select(recordIDs: victims.map(\.id))
    let dirs = victims.map { w.store.paths(for: $0).directory }
    check(click("history.delete", in: h.window?.contentView), "Delete clicked with two selected")
    check(w.store.list().count == 5 && victims.allSatisfy { w.store.record(id: $0.id) == nil }, "delete removes both records")
    check(dirs.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) }, "delete removes their folders from disk")
    check(h.records.count == 5, "history list refreshed")

    h.select(recordIDs: [first.id])
    h.collectionView.keyDown(with: Synth.keyEvent(h.window, 51))
    check(w.store.record(id: first.id) == nil && c.overlay.card(forRecord: first.id) == nil, "Delete key deletes the selection and closes its card")
    check(nothingOnScreen(), "history actions ordered nothing on screen")
}

@MainActor
func checkPrune() async throws {
    section("retention prune")
    let w = try World(after: [])
    defer { w.cleanup() }
    let c = w.coordinator
    let day: TimeInterval = 86_400
    let img = Pix.flat(64, 64, r: 0.4, g: 0.4, b: 0.4)
    let old = try w.store.add(img, kind: .area, now: w.now.addingTimeInterval(-40 * day))
    let mid = try w.store.add(img, kind: .area, now: w.now.addingTimeInterval(-10 * day))
    let new = try w.store.add(img, kind: .area, now: w.now.addingTimeInterval(-1 * day))
    let oldCard = c.overlay.add(record: old, image: img)
    check(c.settings.value.retentionDays == 30, "retention defaults to 30 days")
    check(c.prune() == 1, "prune at 30 days removes the 40 day old capture")
    check(w.store.record(id: old.id) == nil && !FileManager.default.fileExists(atPath: w.store.paths(for: old).directory.path), "record and folder are gone")
    check(oldCard.state == .closing, "its Quick Access card was closed")
    check(w.store.record(id: mid.id) != nil && w.store.record(id: new.id) != nil, "newer captures stay")
    check(c.prune() == 0, "pruning again removes nothing (idempotent)")
    w.settings.update { $0.retentionDays = 5 }
    check(c.prune() == 1 && w.store.record(id: mid.id) == nil && w.store.record(id: new.id) != nil, "retention 5 days removes the 10 day old capture only")
    w.now = w.now.addingTimeInterval(30 * day)
    check(c.prune() == 1 && w.store.list().isEmpty, "a month later the clock pushes the rest out too")
}

@MainActor
func checkImportAndEditorRoundTrip() async throws {
    section("open image from Finder, editor project round trip through history")
    let w = try World(after: [])
    defer { w.cleanup() }
    let c = w.coordinator

    let img = Pix.flat(300, 200, r: 0.7, g: 0.3, b: 0.2, label: "import")
    let png = w.root.appendingPathComponent("sample.png")
    try AssetStore.pngData(from: img)!.write(to: png)
    let jpg = w.root.appendingPathComponent("sample.jpg")
    try Exporter.data(from: img, format: .jpeg).write(to: jpg)
    let heic = w.root.appendingPathComponent("sample.heic")
    try Exporter.data(from: img, format: .heic).write(to: heic)
    for url in [png, jpg, heic] {
        let before = w.store.list().count
        c.perform(.openFile(url))
        check(w.store.list().count == before + 1 && w.store.list().first?.kind == .imported, "openFile imports \(url.pathExtension) as an imported capture")
        check(c.editors[w.store.list().first!.id]?.currentDocument.pixelSize == CGSize(width: 300, height: 200), "openFile(\(url.pathExtension)) builds an editor at the image size")
    }
    let n = w.store.list().count
    let junk = w.root.appendingPathComponent("junk.png")
    try Data("not an image".utf8).write(to: junk)
    c.perform(.openFile(junk))
    check(w.store.list().count == n && c.hud.lastMessage == "Could not read the image", "an undecodable file is refused with a HUD", detail: c.hud.lastMessage ?? "nil")
    c.perform(.openFile(w.root.appendingPathComponent("missing.png")))
    check(w.store.list().count == n, "a missing file is ignored")

    for e in c.editors.values { e.window?.close() }
    check(c.editors.isEmpty, "closing editors empties the editor table")

    c.handleCaptured(.init(image: img, kind: .area, pointScale: 1))
    c.settings.update { $0.afterCapture = [] }
    let record = w.store.list().first!
    check(!w.store.hasProject(record), "a fresh capture has no saved project")
    c.perform(.openHistory)
    c.history!.select(recordIDs: [record.id])
    c.history!.editSelected()
    let editor = c.editors[record.id]!
    let note = Annotation(kind: .rect(CGRect(x: 20, y: 30, width: 100, height: 60), filled: false, cornerRadius: 4),
                          stroke: Stroke(color: RGBA(1, 0, 0), width: 4))
    editor.perform(.add(note))
    editor.perform(.rotateClockwise)
    let edited = editor.currentDocument
    try editor.saveProject(to: w.store.paths(for: record).directory)
    check(w.store.hasProject(record), "saving the project writes project.json next to image.png")
    editor.window?.close()
    check(c.editors[record.id] == nil, "editor close clears its table entry")

    c.history!.select(recordIDs: [record.id])
    c.history!.editSelected()
    let reopened = c.editors[record.id]!
    check(reopened !== editor && reopened.currentDocument == edited, "reopening from history gives an equal document", detail: "\(reopened.currentDocument.annotations.count) annotations")
    check(reopened.currentDocument.annotations.first == note, "the annotation survived")

    reopened.perform(.add(Annotation(kind: .ellipse(CGRect(x: 5, y: 5, width: 50, height: 40), filled: true), stroke: Stroke(color: RGBA(0, 0, 1), width: 2))))
    let afterSecond = reopened.currentDocument
    reopened.window?.close()
    let (docAfterClose, _) = try w.store.openDocument(for: record)
    check(docAfterClose == afterSecond && docAfterClose.annotations.count == 2, "closing the editor saves unsaved edits to history")
    if let restored = c.currentImage(for: record) {
        check(restored.width == 200 && restored.height == 300, "history restore/copy use the edited (rotated) render", detail: "\(restored.width)x\(restored.height)")
    } else { check(false, "currentImage returns the edited render") }

    let pinsBefore = c.pins.pins.count
    let third = c.openEditor(record)!
    third.callbacks.onPin(img)
    check(c.pins.pins.count == pinsBefore + 1, "editor Pin callback creates a pin")
    third.callbacks.onCopied()
    check(c.hud.lastMessage == "Copied", "editor copied callback shows the HUD")
    check(nothingOnScreen(), "editor flows ordered nothing on screen")
}
