import AppKit
import CornermarkCapture
import CornermarkCore
import CryptoKit
import ImageIO
@testable import CornermarkShell

struct GifFileFacts: Equatable {
    var width = 0, height = 0, frames = 0
    var loopCount: Int?
    var duration = 0.0
}

func gifFileFacts(_ url: URL) -> GifFileFacts? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetType(source) as String? == "com.compuserve.gif" else { return nil }
    var facts = GifFileFacts(frames: CGImageSourceGetCount(source))
    let file = CGImageSourceCopyProperties(source, nil) as? [CFString: Any]
    facts.loopCount = (file?[kCGImagePropertyGIFDictionary] as? [CFString: Any])?[kCGImagePropertyGIFLoopCount] as? Int
    for i in 0..<facts.frames {
        let p = CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [CFString: Any]
        let gif = p?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        facts.duration += (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double) ?? 0
        if i == 0 { facts.width = p?[kCGImagePropertyPixelWidth] as? Int ?? 0; facts.height = p?[kCGImagePropertyPixelHeight] as? Int ?? 0 }
    }
    return facts
}

func sha256(_ url: URL) -> String? { (try? Data(contentsOf: url)).map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() } }

@MainActor
func checkGifRecording() async throws {
    section("GIF recording")
    check(RecordingPreferences().options(for: .gif).showsCursor, "a GIF draws the cursor into its picture when the cursor is shown")
    var hidden = RecordingPreferences()
    hidden.showCursor = false
    check(!hidden.options(for: .gif).showsCursor, "and leaves it out when it is hidden")
    check(RecordingStyle.gif.format == .gif && RecordingStyle.video.format == .video && RecordingStyle.editing.format == .project, "each style lands in its own format")
    let named = RecordedVideo(location: URL(fileURLWithPath: "/tmp/x/Cornermark Recording 1.gif"), format: .gif, duration: 0)
    check(named.film.lastPathComponent == ".Cornermark Recording 1.gif.mp4" && named.film.deletingLastPathComponent() == named.location.deletingLastPathComponent()
          && named.file == named.location, "a GIF is filmed into a hidden video beside it and opens as itself", detail: named.film.path)

    let m = try ManualRecordingWorld()
    let w = m.world, c = w.coordinator
    defer { w.cleanup() }
    check(m.link("record?display=1&x=100&y=80&width=400&height=300&style=gif"), "a GIF link is accepted")
    check(await waitUntil { m.phase == .recording }, "and the recording starts")
    guard let entry = w.env.recordingJournal?.entries().first else { return check(false, "the journal names the GIF") }
    check(entry.format == .gif && entry.location.pathExtension == "gif", "the journal names the GIF it will become", detail: "\(entry)")
    check(FileManager.default.fileExists(atPath: entry.video.film.path) && !FileManager.default.fileExists(atPath: entry.location.path),
          "while it records, only the hidden video exists")
    try m.source?.advance(90)
    c.recording.pause()
    try m.source?.advance(60)
    c.recording.resume()
    try m.source?.advance(60)
    let started = Date()
    c.recording.stop()
    check(await waitUntil(15) { m.phase == .idle && w.store.list().count == 1 }, "Stop finishes the recording and lists the GIF")
    guard let record = w.store.list().first, let video = record.video else { return check(false, "the GIF is listed") }
    check(video.format == .gif && video.location == entry.location && record.kind == .area, "History lists it as a GIF of an area", detail: "\(video)")
    let saved = (try? FileManager.default.contentsOfDirectory(atPath: w.saveDir.path)) ?? []
    check(saved == [entry.location.lastPathComponent], "the save folder holds the GIF and nothing else, the hidden video is gone", detail: "\(saved)")
    if let facts = gifFileFacts(video.file) {
        check(facts.width == 400 && facts.height == 300 && facts.loopCount == 0, "the GIF is 400x300 and loops forever", detail: "\(facts)")
        check(facts.frames == 38 && abs(facts.duration - 2.5) < 0.04, "150 kept frames at 60 fps become 38 GIF frames lasting 2.5 s: the 1 s pause is left out",
              detail: "\(facts)")
        check(abs(video.duration - facts.duration) < 0.001, "History keeps the GIF's own length", detail: "\(video.duration)")
    } else { check(false, "the GIF can be read") }
    check(w.env.recordingJournal?.entries().isEmpty == true, "the journal is empty once the GIF is written")
    check(Date().timeIntervalSince(started) < 10, "and making it took seconds", detail: "\(Date().timeIntervalSince(started)) s")
    let paths = w.store.paths(for: record)
    check(FileManager.default.fileExists(atPath: paths.image.path), "History keeps the GIF's first frame as its picture")
    if let card = c.overlay.card(forRecord: record.id) {
        check(card.actions == [.copy, .play, .reveal, .close], "its card offers Copy, Play, Reveal in Finder and Close", detail: "\(card.actions)")
        check(card.info.hasPrefix("GIF") && card.info.contains("0:02") && card.info.contains("400"), "and says GIF with its length and size", detail: card.info)
        let label = c.overlay.cardView(for: card)?.accessibilityLabel() ?? ""
        check(label.hasPrefix("GIF, 0:02") && label.components(separatedBy: "GIF").count == 2, "and VoiceOver hears GIF once", detail: label)
        c.overlay.perform(.copy, card)
        let copied = (w.pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL])?.first
        check(copied?.lastPathComponent == entry.location.lastPathComponent, "Copy puts the GIF file on the pasteboard", detail: "\(String(describing: copied))")
        c.overlay.perform(.play, card)
        check(w.opened.last == video.file, "Play opens the GIF itself")
    } else { check(false, "the GIF shows a Quick Access card") }

    section("GIF from a finished recording")
    let (rw, _) = try recordingWorld(frames: 45)
    defer { rw.cleanup() }
    let rc = rw.coordinator
    guard let plain = await recordOnce(rw, "display=1&x=0&y=0&width=640&height=360&style=video"), let plainVideo = plain.video,
          let project = await recordOnce(rw, "display=1&x=0&y=0&width=640&height=360") else { return check(false, "a video and a project are recorded") }
    let hash = sha256(plainVideo.file)
    guard let card = rc.overlay.card(forRecord: plain.id), let view = rc.overlay.cardView(for: card) else { return check(false, "the video has a card") }
    check(card.actions == [.copy, .play, .makeGif, .reveal, .close] && view.buttons[.makeGif] != nil, "a video's card offers Convert to GIF", detail: "\(card.actions)")
    check(view.buttons[.makeGif]?.accessibilityLabel() == "Convert to GIF", "named Convert to GIF", detail: view.buttons[.makeGif]?.accessibilityLabel() ?? "nil")
    check(rc.overlay.card(forRecord: project.id).map { !$0.actions.contains(.makeGif) } == true, "a project's card does not, its pointer is not in its video")
    func newest(after ids: Set<UUID>) -> CaptureRecord? { rw.store.list().first { !ids.contains($0.id) } }
    var known = Set(rw.store.list().map(\.id))
    view.buttons[.makeGif]?.performClick(nil)
    view.buttons[.makeGif]?.performClick(nil)
    check(rc.makingGifs == [plain.id] && rc.hud.lastMessage == "Converting to GIF", "the click starts one conversion and says so; a second click while it runs adds none")
    check(await waitUntil(15) { rw.store.list().count == 3 && rc.makingGifs.isEmpty }, "the GIF is listed as its own recording")
    guard let made = newest(after: known), let madeVideo = made.video else { return check(false, "the converted GIF is listed") }
    let beside = plainVideo.file.deletingPathExtension().appendingPathExtension("gif")
    check(madeVideo.format == .gif && madeVideo.location == beside, "it sits beside the video under the same name", detail: madeVideo.location.lastPathComponent)
    check(sha256(plainVideo.file) == hash && hash != nil, "the video is not changed")
    if let facts = gifFileFacts(madeVideo.file) {
        check(facts.width == 960 && facts.height == 540 && facts.loopCount == 0 && abs(facts.duration - plainVideo.duration) < 0.07,
              "a 1280x720 video makes a 960x540 GIF as long as the video, looping forever", detail: "\(facts) video \(plainVideo.duration)")
    } else { check(false, "the converted GIF can be read") }
    check(rc.overlay.card(forRecord: made.id) != nil, "and gets its own card")

    rc.perform(.openHistory)
    guard let h = rc.history else { return check(false, "History opens") }
    let gifButton = h.actionButtons["gif"]
    check(gifButton?.title == "Convert to GIF", "History's action bar has Convert to GIF")
    h.select(recordIDs: [project.id])
    check(gifButton?.isEnabled == false, "it is off for a project")
    h.select(recordIDs: [made.id])
    check(gifButton?.isEnabled == false, "and for a GIF")
    h.select(recordIDs: [plain.id])
    check(gifButton?.isEnabled == true, "and on for a video")
    known = Set(rw.store.list().map(\.id))
    gifButton?.performClick(nil)
    check(await waitUntil(15) { rw.store.list().count == 4 && rc.makingGifs.isEmpty }, "it converts the selected video again")
    let again = newest(after: known)?.video?.location.lastPathComponent
    check(again == plainVideo.file.deletingPathExtension().lastPathComponent + " 2.gif", "without overwriting the first GIF", detail: again ?? "nil")
    let item = NSMenuItem(title: "Convert to GIF", action: #selector(HistoryWindowController.makeGifSelected), keyEquivalent: "")
    h.select(recordIDs: [project.id])
    check(!h.validateMenuItem(item), "the context menu offers it only where the bar does")

    section("GIF recovery after a crash")
    let film = rw.saveDir.appendingPathComponent(".crashed.gif.mp4")
    try FileManager.default.copyItem(at: plainVideo.file, to: film)
    let journal = RecordingJournal(folder: rw.root.appendingPathComponent("unfinished", isDirectory: true))
    rw.env.recordingJournal = journal
    _ = journal.open(location: rw.saveDir.appendingPathComponent("crashed.gif"), format: .gif, kind: .area, area: CGRect(x: 0, y: 0, width: 640, height: 360))
    let listed = rw.store.list().count
    known = Set(rw.store.list().map(\.id))
    await rc.recoverRecordings()
    let recovered = newest(after: known)?.video
    check(journal.entries().isEmpty && rw.store.list().count == listed + 1 && recovered?.format == .gif && recovered?.location.lastPathComponent == "crashed.gif",
          "the next launch makes the GIF from the cut-off video and lists it", detail: "\(String(describing: recovered))")
    check(!FileManager.default.fileExists(atPath: film.path) && gifFileFacts(rw.saveDir.appendingPathComponent("crashed.gif"))?.frames ?? 0 > 0,
          "and removes the hidden video")
}
