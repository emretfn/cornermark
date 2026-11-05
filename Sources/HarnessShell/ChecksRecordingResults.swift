import AppKit
import AVFoundation
import CornermarkCapture
import CornermarkCore
import CornermarkDesign
@testable import CornermarkShell

/// A world whose recordings come from the fixture display at `scale`, with the scripted pointer drawn when the options ask.
@MainActor
func recordingWorld(scale: Double = 2, frames: Int = 30) throws -> (World, () -> [(RecordingTarget, RecordingOptions)]) {
    let w = try World(after: [.showOverlay])
    var made: [(RecordingTarget, RecordingOptions)] = []
    w.env.frameSource = { target, options in
        made.append((target, options))
        let area: CGRect? = { if case .display(_, let a) = target { return a } else { return nil } }()
        return FixtureFrameSource(displayFrame: FixtureFrameSource.displayFrame, scale: scale, area: area, options: options, cursor: .tour,
                                  pacing: .scripted(frames: frames))
    }
    w.env.pointerSource = { ScriptedPointerSource(pacing: .fixed(origin: 0, count: 60)) }
    return (w, { made })
}

/// Starts and stops one recording through links, as a user's shortcut would, and waits for it to be listed.
@MainActor
func recordOnce(_ w: World, _ query: String) async -> CaptureRecord? {
    let before = Set(w.store.list().map(\.id))
    let c = w.coordinator
    guard c.handle(url: URL(string: "\(URLCommand.scheme)://record?\(query)")!) else { return nil }
    _ = await waitUntil { c.recording.phase == .recording }
    _ = c.handle(url: URL(string: "\(URLCommand.scheme)://record/stop")!)
    guard await waitUntil(10, { c.recording.phase == .idle && w.store.list().count > before.count }) else { return nil }
    return w.store.list().first { !before.contains($0.id) }
}

struct FileFacts: Equatable {
    var width = 0, height = 0, frames = 0
    var fps = 0.0
}

func fileFacts(_ url: URL) async -> FileFacts? {
    let asset = AVURLAsset(url: url)
    guard let track = try? await asset.loadTracks(withMediaType: .video).first, let size = try? await track.load(.naturalSize),
          let rate = try? await track.load(.nominalFrameRate), let reader = try? AVAssetReader(asset: asset) else { return nil }
    let out = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
    reader.add(out)
    reader.startReading()
    var frames = 0
    while out.copyNextSampleBuffer() != nil { frames += 1 }
    return FileFacts(width: Int(size.width), height: Int(size.height), frames: frames, fps: Double(rate))
}

@MainActor
func checkRecordingResults() async throws {
    section("recording settings model")
    check(Settings().recording == RecordingPreferences() && RecordingPreferences().fps == 60 && RecordingPreferences().quality == .high
          && RecordingPreferences().density == .retina && RecordingPreferences().limit == .none && RecordingPreferences().showCursor && RecordingPreferences().showQuickAccess,
          "defaults: 60 fps, high quality, Retina, no size limit, cursor shown, Quick Access shown")
    let before = #"{"afterCapture":3,"autoCloseSeconds":8,"checkForUpdatesAutomatically":true,"customShortcuts":{},"disabledShortcuts":[],"imageFormat":"png","launchAtLogin":false,"overlayCorner":"topLeft","overlaySize":"medium","playSound":true,"retentionDays":30,"timerSeconds":7,"windowShadow":true,"lastRunVersion":"0.3.0"}"#
    let old = try JSONDecoder().decode(Settings.self, from: Data(before.utf8))
    check(old.recording == RecordingPreferences() && old.timerSeconds == 7 && old.overlayCorner == .topLeft && old.lastRunVersion == "0.3.0",
          "settings saved before recordings decode, keep every value and get the recording defaults")
    let odd = try JSONDecoder().decode(Settings.self, from: Data(#"{"recording":{"fps":50,"quality":"ultra","limit":"fullHD","showCursor":false}}"#.utf8))
    check(odd.recording.fps == 60 && odd.recording.quality == .high && odd.recording.limit == .fullHD && !odd.recording.showCursor && odd.recording.showQuickAccess,
          "an unknown frame rate snaps to the nearest offered one, an unknown quality falls back, the rest is kept", detail: "\(odd.recording)")
    var custom = Settings()
    custom.recording.fps = 30; custom.recording.quality = .low; custom.recording.density = .standard; custom.recording.limit = .hd
    custom.recording.showCursor = false; custom.recording.showQuickAccess = false
    check(try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(custom)) == custom, "the recording settings round-trip through JSON")
    let p = custom.recording
    check(p.options(for: .video) == RecordingOptions(fps: 30, showsCursor: false, quality: .low, density: .standard, limit: .hd)
          && p.options(for: .editing).showsCursor == false && RecordingPreferences().options(for: .video).showsCursor
          && !RecordingPreferences().options(for: .editing).showsCursor,
          "a video draws the cursor only when it is shown; a project never has it in the picture")

    section("Recording settings pane")
    let (w, made) = try recordingWorld()
    defer { w.cleanup() }
    let c = w.coordinator
    c.perform(.openSettings)
    guard let sw = c.settingsWindow, let pane = sw.panes.first(where: { $0 is RecordingPane }) else { return check(false, "the Recording pane exists") }
    sw.select(pane: pane)
    let page = pane.view
    func popup(_ id: String) -> NSPopUpButton? { findView(id, in: page) as? NSPopUpButton }
    check(popup("recording.fps")?.itemTitles == ["30 fps", "60 fps"] && popup("recording.fps")?.titleOfSelectedItem == "60 fps", "frame rate offers 30 and 60 fps, 60 chosen")
    check(popup("recording.quality")?.itemTitles == ["High", "Medium", "Low"], "quality offers High, Medium, Low")
    check(["recording.fps", "recording.quality", "recording.resolution", "recording.limit"].map { popup($0)?.accessibilityLabel() ?? "" } == ["Frame rate", "Quality", "Resolution", "Largest size"],
          "each popup is named by its row title for VoiceOver")
    check(popup("recording.resolution")?.itemTitles == ["Retina", "Standard"], "resolution offers Retina and Standard")
    check(popup("recording.limit")?.itemTitles.count == 5 && popup("recording.limit")?.itemTitles.first == "No limit", "largest size offers no limit and four sizes",
          detail: "\(popup("recording.limit")?.itemTitles ?? [])")
    check((findView("recording.cursor", in: page) as? NSButton)?.state == .on && (findView("recording.quickAccess", in: page) as? NSButton)?.state == .on,
          "Show cursor and Show Quick Access start on")

    var record = await recordOnce(w, "display=1&x=0&y=0&width=640&height=360&style=video")
    check(made().last?.1 == RecordingOptions(fps: 60, showsCursor: true), "with the defaults the recorder is asked for 60 fps with the cursor in the picture", detail: "\(made().last.map { "\($0.1)" } ?? "none")")
    if let file = record?.video?.file, let facts = await fileFacts(file) {
        check(facts.width == 1280 && facts.height == 720 && abs(facts.fps - 60) < 1, "and the file is 1280x720 at 60 fps from a 2x display", detail: "\(facts)")
    } else { check(false, "the default recording can be read") }

    for (id, index) in [("recording.fps", 0), ("recording.quality", 2), ("recording.resolution", 1)] {
        guard let p = popup(id) else { check(false, "\(id) exists"); continue }
        p.selectItem(at: index); fire(p)
    }
    check(click("recording.cursor", in: page), "Show cursor clicked off")
    let s = c.settings.value.recording
    check(s.fps == 30 && s.quality == .low && s.density == .standard && !s.showCursor, "the pane writes frame rate, quality, resolution and cursor", detail: "\(s)")
    check(SettingsStore(defaults: w.defaults).value.recording == s, "and they persist")

    record = await recordOnce(w, "display=1&x=0&y=0&width=640&height=360&style=video")
    check(made().last?.1 == RecordingOptions(fps: 30, showsCursor: false, quality: .low, density: .standard), "the next recording is asked for 30 fps, low quality, standard, no cursor",
          detail: "\(made().last.map { "\($0.1)" } ?? "none")")
    if let file = record?.video?.file, let facts = await fileFacts(file) {
        check(facts.width == 640 && facts.height == 360 && abs(facts.fps - 30) < 1 && facts.frames == 30, "and the file is 640x360 at 30 fps", detail: "\(facts)")
    } else { check(false, "the changed recording can be read") }

    if let p = popup("recording.resolution") { p.selectItem(at: 0); fire(p) }
    if let p = popup("recording.limit") { p.selectItem(at: 4); fire(p) }
    record = await recordOnce(w, "display=1&style=video")
    if let file = record?.video?.file, let facts = await fileFacts(file) {
        check(c.settings.value.recording.limit == .hd && facts.width == 1280 && facts.height == 720,
              "a 720p limit scales the 2560x1440 Retina display down to 1280x720", detail: "\(facts)")
    } else { check(false, "the limited recording can be read") }

    record = await recordOnce(w, "display=1&x=0&y=0&width=640&height=360")
    if let folder = record?.video?.location, let project = try? RecordingProjectFile.read(from: folder) {
        check(made().last?.1.showsCursor == false && project.edits.cursor.isVisible == false, "with the cursor off, a project starts with its cursor hidden")
    } else { check(false, "the project can be read") }
    check(click("recording.cursor", in: page) && c.settings.value.recording.showCursor, "Show cursor clicked back on")
    record = await recordOnce(w, "display=1&x=0&y=0&width=640&height=360")
    if let folder = record?.video?.location, let project = try? RecordingProjectFile.read(from: folder) {
        check(project.edits.cursor.isVisible && !project.events.pointer.isEmpty, "with it on, the project starts with the cursor shown and keeps the track")
    } else { check(false, "the second project can be read") }

    section("finished recordings in Quick Access")
    let (q, _) = try recordingWorld()
    defer { q.cleanup() }
    let qc = q.coordinator
    guard let video = await recordOnce(q, "display=1&x=0&y=0&width=640&height=360&style=video") else { return check(false, "a video recording is listed") }
    check(video.video?.format == .video && video.kind == .area && video.pixelSize == CGSize(width: 1280, height: 720), "history lists it as a video of an area, at the video's size",
          detail: "\(video)")
    check(abs((video.video?.duration ?? 0) - 0.5) < 1e-6, "with its length, 30 frames at 60 fps", detail: "\(video.video?.duration ?? -1)")
    check(video.video?.location.deletingLastPathComponent().standardizedFileURL == q.saveDir.standardizedFileURL, "the video stays in the save folder")
    check(FileManager.default.fileExists(atPath: q.store.paths(for: video).image.path), "history keeps its first frame as the picture")
    guard let card = qc.overlay.card(forRecord: video.id), let view = qc.overlay.cardView(for: card) else { return check(false, "a Quick Access card appears") }
    check(qc.hud.lastMessage == nil, "the card is the confirmation, so no HUD shows", detail: qc.hud.lastMessage ?? "nil")
    check(view.buttons.keys.sorted { "\($0)" < "\($1)" } == [.close, .copy, .play, .reveal], "the card offers Copy, Play, Reveal in Finder and Close", detail: "\(view.buttons.keys)")
    check(card.info == "0:00  \u{00B7}  1280 \u{00D7} 720", "and reads its length and size", detail: card.info)
    check(card.thumbnail.width == 640 && card.thumbnail.height == 360, "its thumbnail is the video's first frame", detail: "\(card.thumbnail.width)x\(card.thumbnail.height)")
    check(click("card.copy", in: view), "Copy clicked")
    let copied = q.pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL]
    check(copied == [video.video!.file] && qc.hud.lastMessage == "Copied", "Copy puts the video file on the pasteboard", detail: "\(copied ?? [])")
    check(click("card.play", in: view) && q.opened.last == video.video!.file, "Play opens the video")
    check(click("card.reveal", in: view) && q.revealed.last == video.video!.location, "Reveal in Finder shows the file")
    check(view.accessibilityLabel() == "Recording, 0:00, 1280 \u{00D7} 720" && view.buttons[.reveal]?.accessibilityLabel() == "Reveal in Finder",
          "the card names itself and its buttons for VoiceOver", detail: view.accessibilityLabel() ?? "nil")
    check(qc.overlay.dragFile(for: card) == video.video!.file, "dragging the card drags the video itself")
    let opened = q.opened.count
    view.mouseDown(with: Synth.mouse(.leftMouseDown, at: .zero, in: qc.overlay.panel(for: card)!, clickCount: 2))
    check(q.opened.count == opened + 1 && qc.editors.isEmpty, "a double-click plays it and opens no picture editor")

    guard let project = await recordOnce(q, "display=1&x=0&y=0&width=640&height=360") else { return check(false, "a project recording is listed") }
    check(project.video?.format == .project && qc.overlay.stack.first?.record.id == project.id && qc.overlay.stack.count == 2,
          "Record for Editing gets its own card on top of the stack")
    if let pcard = qc.overlay.card(forRecord: project.id), let pview = qc.overlay.cardView(for: pcard) {
        check(click("card.play", in: pview) && q.opened.last?.lastPathComponent == RecordingProjectFile.videoName, "Play on a project opens its screen video")
        check(click("card.reveal", in: pview) && q.revealed.last == project.video!.location, "Reveal in Finder shows the project folder")
    }

    q.settings.update { $0.recording.showQuickAccess = false }
    let quiet = await recordOnce(q, "display=1&style=video")
    check(quiet != nil && qc.overlay.stack.count == 2 && qc.hud.lastMessage?.hasPrefix("Saved Cornermark Recording") == true,
          "with Quick Access off for recordings, a finished one says Saved in the HUD and shows no card", detail: qc.hud.lastMessage ?? "nil")
    q.settings.update { $0.recording.showQuickAccess = true; $0.afterCapture = [] }
    let still = await recordOnce(q, "display=1&style=video")
    check(still.flatMap { qc.overlay.card(forRecord: $0.id) } != nil, "the screenshot setting does not hide a recording's card")

    section("recordings in History")
    qc.perform(.openHistory)
    guard let h = qc.history else { return check(false, "History opens") }
    h.setFilter(.recordings)
    check(h.records.count == 4 && h.records.allSatisfy(\.isRecording), "the Recordings filter lists the four recordings", detail: "\(h.records.count)")
    _ = try q.store.add(Pix.flat(200, 100, r: 0.2, g: 0.5, b: 0.8), kind: .area)
    h.setFilter(.area)
    check(h.records.count == 1 && !h.records[0].isRecording, "the Area filter lists pictures only, though the recordings filmed areas")
    h.setFilter(.all)
    check(h.records.count == 5, "All lists both")
    h.setFilter(.recordings)
    h.window?.setContentSize(NSSize(width: 920, height: 900))
    h.window?.contentView?.layoutSubtreeIfNeeded()
    h.collectionView.layoutSubtreeIfNeeded()
    _ = await waitUntil { h.collectionView.item(at: IndexPath(item: 0, section: 0)) != nil }
    if let item = h.collectionView.item(at: IndexPath(item: 0, section: 0)) as? HistoryItem, let iv = item.view as? HistoryItemView {
        check(iv.title.hasPrefix("Recording") && iv.duration == "0:00", "a recording's item reads Recording and carries its length", detail: "\(iv.title) \(iv.duration ?? "nil")")
    } else { check(false, "a recording item is shown") }
    h.select(recordIDs: [video.id])
    check(h.actionButtons["edit"]?.isEnabled == false && h.actionButtons["copy"]?.isEnabled == true, "Edit is off for a recording, Copy is on")
    q.pasteboard.clearContents()
    h.copySelected()
    check((q.pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL]) == [video.video!.file], "History Copy copies the video file")
    h.revealSelected()
    check(q.revealed.last == video.video!.location, "History Reveal shows the video")
    qc.overlay.closeAll()
    h.restoreSelected()
    check(qc.overlay.card(forRecord: video.id)?.actions.contains(.play) == true, "Show Overlay brings back a video card")
    h.deleteSelected()
    check(q.store.record(id: video.id) == nil && FileManager.default.fileExists(atPath: video.video!.file.path), "Delete removes the entry and keeps the video")
    if let gone = q.store.list(filter: CaptureFilter(recordings: true)).first(where: { $0.video?.format == .video }), let file = gone.video?.file {
        try? FileManager.default.removeItem(at: file)
        let opens = q.opened.count
        qc.play(gone)
        check(q.opened.count == opens && qc.hud.lastMessage == "Recording not found. Look for it in the save folder.", "a moved video says so instead of opening nothing")
    }
    if let hw = h.window, let content = hw.contentView, let filter = findView("history.filter", in: content) {
        hw.setContentSize(hw.minSize)
        content.layoutSubtreeIfNeeded()
        let count = (content.subviews.first as? NSStackView)?.arrangedSubviews.first?.subviews.first { $0 is NSTextField }
        let f = filter.convert(filter.bounds, to: content), l = count.map { $0.convert($0.bounds, to: content) } ?? .null
        check(f.maxX + DS.Space.s16 <= l.minX + 0.5 && l.maxX <= content.bounds.maxX - DS.Space.s16 + Form.labelInset + 0.5,
              "at the smallest window the eight filters and the count fit side by side", detail: "filter \(f) count \(l) window \(content.bounds.width)")
        snapshotWindow(hw, name: "history-recordings-min-width")
    }
    check(nothingOnScreen(), "recording results put nothing on screen")
}
