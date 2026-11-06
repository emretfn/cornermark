import AppKit
import CornermarkCore
import CornermarkDesign
import CornermarkEditor
@testable import CornermarkShell

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
        check(h.records.count == kinds && h.records.allSatisfy { filter.captureFilter.kinds?.contains($0.kind) ?? true }, "filter \(filter.title): \(kinds)", detail: "\(h.records.count)")
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
    check(h.selectedRecords.map(\.id) == [first.id] && h.actionButtons.filter { $0.key != "gif" }.values.allSatisfy(\.isEnabled)
          && h.actionButtons["gif"]?.isEnabled == false, "selecting a picture enables the action buttons, all but Convert to GIF")
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
func checkHistoryChrome() async throws {
    section("History: title row, grid, bottom bar")
    let w = try World(after: [.showOverlay])
    defer { w.cleanup() }
    let c = w.coordinator
    c.perform(.openHistory)
    let h = c.history!
    let win = h.window!
    let content = win.contentView!
    check(win.styleMask.contains(.fullSizeContentView) && win.titlebarAppearsTransparent && win.titleVisibility == .hidden && win.toolbar?.items.isEmpty == true,
          "history: full-size content, transparent title bar, hidden title, empty toolbar")
    check(win.backgroundColor == DS.Color.bgSurface, "history: the window colour is bgSurface")

    func texts(_ view: NSView) -> [NSTextField] { (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap(texts) }
    let empty = texts(content).first { $0.stringValue == "No captures yet" }
    content.layoutSubtreeIfNeeded()
    check(empty?.isHidden == false && empty?.font == DS.Text.heading.font && empty?.textColor == DS.Color.textSecondary,
          "an empty history shows its message in heading and textSecondary")
    if let empty, let scroll = h.collectionView.enclosingScrollView {
        let a = empty.convert(empty.bounds, to: content), b = scroll.convert(scroll.bounds, to: content)
        check(abs(a.midX - b.midX) <= 1 && abs(a.midY - b.midY) <= 1, "the empty message is centred in the grid", detail: "\(a) in \(b)")
    }

    let seeded = seedHistory(w)
    h.reload()
    content.layoutSubtreeIfNeeded()
    check(texts(content).first { $0.stringValue == "No captures yet" }?.isHidden == true, "the empty message goes away once there are captures")

    let filter = findView("history.filter", in: content) as? Segments
    check(filter?.segmentCount == HistoryFilter.allCases.count && filter?.label(forSegment: 0) == "All" && filter?.size == .small && filter?.trackingMode == .selectOne,
          "the filter is a labelled, select-one Segments with a tile per filter")
    if let filter {
        filter.selectedSegment = HistoryFilter.window.rawValue
        fire(filter)
        check(h.filter == .window && h.records.count == 1, "choosing the Window tile filters the grid")
        h.setFilter(.all)
        check(filter.selectedSegment == HistoryFilter.all.rawValue, "setFilter moves the selected tile")

        let frame = content.superview!
        if let zoom = win.standardWindowButton(.zoomButton) {
            let a = zoom.convert(zoom.bounds, to: frame), b = filter.convert(filter.bounds, to: frame)
            check(abs(a.midY - b.midY) <= 1 && b.minX >= a.maxX + DS.Space.s16 - 0.5, "the filter sits on the window buttons' centre line, s16 past them",
                  detail: "buttons \(a), filter \(b)")
        }
        let count = texts(content).first { $0.stringValue.hasSuffix("captures") }
        if let count {
            let r = count.convert(count.bounds, to: frame), f = filter.convert(filter.bounds, to: frame)
            check(count.font == DS.Text.caption.font && count.textColor == DS.Color.textSecondary && abs(r.midY - f.midY) <= 1 && r.maxX + DS.Space.s16 - 2 >= frame.bounds.width - 1.5 && r.minX > f.maxX,
                  "the count is caption and textSecondary, on the filter's centre line, at the far right", detail: "\(r) vs \(f)")
        }
    }

    let order = ["copy", "edit", "restore", "reveal", "delete"]
    let buttons = order.compactMap { findView("history.\($0)", in: content) as? Button }
    check(buttons.count == 5 && buttons.allSatisfy { $0.size == .small }, "the bar has five small design-system Buttons")
    if buttons.count == 5 {
        check(buttons.map(\.title) == ["Copy", "Edit", "Show Overlay", "Reveal in Finder", "Delete"], "bar order: Copy, Edit, Show Overlay, Reveal in Finder, then Delete", detail: "\(buttons.map(\.title))")
        check(buttons[0].variant == .primary && buttons[1...3].allSatisfy { $0.variant == .ghost } && buttons[4].variant == .dangerGhost && buttons[4].symbol == "trash",
              "Copy is primary, the others ghost, Delete is a danger ghost with a trash symbol")
        let bar = buttons[0].superview!.superview as? BarView
        let rects = buttons.map { $0.convert($0.bounds, to: content) }
        check(bar?.edge == .top && bar?.frame.height == 48 && abs(rects[0].minX - DS.Space.s12) <= 0.5 && abs(rects[4].maxX - (content.bounds.width - DS.Space.s12)) <= 0.5,
              "the bar is a 48pt top-edged BarView with s12 padding either side", detail: "\(String(describing: bar?.frame)) \(rects[0]) \(rects[4])")
        check(zip(rects[0...2], rects[1...3]).allSatisfy { abs($1.minX - $0.maxX - DS.Space.s8) <= 0.5 } && rects.allSatisfy { abs($0.midY - rects[0].midY) <= 0.5 },
              "the bar's buttons are s8 apart on one centre line")
    }

    win.setContentSize(win.contentRect(forFrameRect: NSRect(origin: .zero, size: win.minSize)).size)
    content.layoutSubtreeIfNeeded()
    let fitted = ["copy", "edit", "restore", "reveal", "gif", "delete"].compactMap { findView("history.\($0)", in: content) as? Button }
    let fittedRects = fitted.map { $0.convert($0.bounds, to: content) }
    check(win.frame.width == 720 && fitted.count == 6
          && zip(fittedRects, fittedRects.dropFirst()).allSatisfy { $0.maxX + DS.Space.s8 - 0.5 <= $1.minX }
          && fittedRects.last.map { $0.maxX <= content.bounds.width - DS.Space.s12 + 0.5 } == true
          && zip(fitted, fittedRects).allSatisfy { $1.width >= $0.fittingSize.width - 0.5 },
          "at the 720 pt minimum width the six bar buttons keep their s8 gaps and full width", detail: "\(fittedRects) in \(content.bounds.width)")

    win.setContentSize(NSSize(width: 920, height: 1800))
    content.layoutSubtreeIfNeeded()
    h.collectionView.layoutSubtreeIfNeeded()
    h.select(recordIDs: [seeded[1].id])
    _ = await waitUntil { h.collectionView.item(at: IndexPath(item: 0, section: 0)) != nil }
    let items = (0..<h.collectionView.numberOfSections).flatMap { s in
        (0..<h.collectionView.numberOfItems(inSection: s)).compactMap { h.collectionView.item(at: IndexPath(item: $0, section: s))?.view as? HistoryItemView }
    }
    check(items.count == 7 && items.allSatisfy { $0.frame.size == NSSize(width: 204, height: 172) && $0.well.size == items[0].well.size && $0.well.minX == DS.Space.s8 },
          "every item is 204 x 172 with the same fixed well", detail: "\(items.map(\.well))")
    check(HistoryItemView.footerHeight == 48 && items[0].well.height == 172 - 8 - 48, "the well is the item height less the footer")
    let headerFrames = (0..<h.collectionView.numberOfSections).compactMap { h.collectionView.supplementaryView(forElementKind: NSCollectionView.elementKindSectionHeader, at: IndexPath(item: 0, section: $0)) as? HistoryHeaderView }
    check(!headerFrames.isEmpty, "section headers are instantiated")
    if let header = headerFrames.first, let label = header.subviews.compactMap({ $0 as? NSTextField }).first {
        let a = header.convert(label.alignmentRect(forFrame: label.frame), to: content)
        let well = items[0].convert(items[0].well, to: content)
        check(label.font == DS.Text.heading.font && label.textColor == DS.Color.textPrimary && abs(a.minX - well.minX) <= 0.5, "section headers are heading and textPrimary, left-aligned with the wells",
              detail: "header \(a.minX) well \(well.minX)")
    }

    for (label, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
        let v = HistoryItemView()
        v.frame = NSRect(x: 0, y: 0, width: 204, height: 172)
        v.appearance = NSAppearance(named: appearance)
        v.title = "Area  \u{00B7}  740 \u{00D7} 260"
        v.subtitle = "14:05:09"
        func pixel(_ x: CGFloat, _ y: CGFloat) -> [CGFloat] {
            let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds)!
            v.cacheDisplay(in: v.bounds, to: rep)
            let k = CGFloat(rep.pixelsWide) / v.bounds.width
            let c = rep.colorAt(x: Int(x * k), y: Int(y * k))!.usingColorSpace(.sRGB)!
            return [c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent]
        }
        let well = v.well
        let ringX = well.minX - 3.5, midY = well.midY
        check(isClose(pixel(well.midX, well.midY), rgba(DS.Color.bgSunken, appearance), 0.04), "[\(label)] an item with no picture yet shows the bgSunken well", detail: "\(pixel(well.midX, well.midY))")
        check(pixel(ringX, midY)[3] < 0.05, "[\(label)] an unselected item draws no ring")
        v.isSelected = true
        check(isClose(pixel(ringX, midY), rgba(DS.Color.accentMark, appearance), 0.06), "[\(label)] selection is a 2pt accentMark ring 3pt outside the well", detail: "\(pixel(ringX, midY))")
        check(pixel(2, 2)[3] < 0.05 && pixel(well.midX, well.maxY + 1)[3] < 0.05 && pixel(well.maxX - 2, well.maxY + 12)[3] < 0.05 && pixel(ringX - 3, midY)[3] < 0.05, "[\(label)] selection fills no card and leaves the title area clear")
        let blue = pixel(ringX, midY)
        check(!(blue[2] > blue[0] + 0.25 && blue[2] > blue[1] + 0.1), "[\(label)] the selection ring is not blue")
        v.isSelected = false
        v.mouseEntered(with: Synth.enterExit(.mouseEntered, in: win))
        check(isClose(pixel(well.minX - 3.5, midY), rgba(DS.Color.borderStrong, appearance), 0.06), "[\(label)] hover is a borderStrong ring", detail: "\(pixel(well.minX - 3.5, midY))")
        v.mouseExited(with: Synth.enterExit(.mouseExited, in: win))
        check(pixel(ringX, midY)[3] < 0.05, "[\(label)] leaving removes the hover ring")
    }
    check(nothingOnScreen(), "history chrome checks ordered nothing on screen")
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
