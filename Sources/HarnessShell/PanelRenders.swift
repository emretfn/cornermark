import AppKit
import CornermarkCapture
import CornermarkCore
import CornermarkDesign
@testable import CornermarkVideoEditor
@testable import CornermarkShell

/// Renders the real recording panel, its help window and the recording control bar offscreen into PNGs, and writes what the
/// options menu and every tooltip say into `panel-renders.txt`, since neither a menu nor a tooltip draws offscreen. The panel and the bar
/// are always dark; the help window follows the system, so it is rendered light and dark. Run with `CORNERMARK_PANEL_RENDERS=<folder>`.
@MainActor
enum PanelRenders {
    static func run(out: URL) async -> Bool {
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var notes: [String] = []
        var failures: [String] = []
        do {
            try await panel(out: out, notes: &notes)
            try await bar(out: out, notes: &notes)
            try await editor(out: out, notes: &notes)
        } catch { failures.append("\(error)") }
        try? notes.joined(separator: "\n").write(to: out.appendingPathComponent("panel-renders.txt"), atomically: true, encoding: .utf8)
        print("RENDERS panel files=\((try? FileManager.default.contentsOfDirectory(atPath: out.path).count) ?? 0) failures=\(failures)")
        return failures.isEmpty
    }

    private static func image(_ view: NSView, scale: CGFloat) -> CGImage? {
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width * scale), pixelsHigh: Int(view.bounds.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = view.bounds.size
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.cgImage
    }

    private static func write(_ image: CGImage?, _ url: URL) throws {
        guard let image, let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { throw FilmError.missing(url.lastPathComponent) }
        try png.write(to: url)
    }

    private static func panel(out: URL, notes: inout [String]) async throws {
        let w = try World()
        defer { w.cleanup() }
        let c = w.coordinator
        w.env.hasInputPermission = { true }
        w.env.microphoneAccess = { .allowed }
        w.env.cameraAccess = { .allowed }
        w.settings.update {
            $0.recording.audio.microphone = true
            $0.recording.camera.isVisible = true
            $0.recording.keystrokes.isVisible = true
        }
        c.capture.lastSelection = PreviousSelection(rect: CGRect(x: 200, y: 160, width: 480, height: 270))
        c.perform(.capture(.recording))
        guard await waitUntil(5, { !c.capture.overlayWindows.isEmpty }), let window = c.capture.overlayWindows.first,
              let content = window.contentView else { throw FilmError.missing("the overlay") }
        guard let panel = findView("cornermark.record.options", in: content)?.superview else { throw FilmError.missing("the panel") }
        try write(image(panel, scale: 3), out.appendingPathComponent("panel.png"))
        let panelOff = offPixelViews(in: panel)
        notes.append("panel off-pixel views: \(panelOff.count)")
        notes += panelOff
        let selection = CGRect(x: 200 - window.frame.minX - 40, y: 160 - window.frame.minY - 40, width: 560, height: 350)
        if let full = image(content, scale: 2) {
            let flippedY = content.bounds.height - selection.maxY
            try write(full.cropping(to: CGRect(x: selection.minX * 2, y: flippedY * 2, width: selection.width * 2, height: selection.height * 2)),
                      out.appendingPathComponent("panel-in-480x270-selection.png"))
        }
        // Every source on, then every source off. The overlay keeps the panel dark, so the same toggles are also drawn on a window
        // surface in both appearances, to show the component on the light tokens.
        let toggles = try RecordingSource.allCases.map { source in
            guard let toggle = findView("cornermark.record.source.\(source.rawValue)", in: content) as? IconButton else { throw FilmError.missing(source.rawValue) }
            return toggle
        }
        for on in [true, false] {
            for toggle in toggles where toggle.isSelected != on { toggle.performClick(nil) }
            guard await waitUntil(5, { toggles.allSatisfy { $0.isSelected == on } }) else { throw FilmError.missing("every source \(on ? "on" : "off")") }
            let name = on ? "on" : "off"
            try write(image(panel, scale: 3), out.appendingPathComponent("panel-sources-\(name).png"))
            let pitch = toggles[1].frame.minX - toggles[0].frame.minX
            notes.append("panel sources \(name): pitch \(Int(pitch)) pt, gap \(Int(pitch - toggles[0].frame.width)) pt")
            for dark in [false, true] {
                let host = NSView(frame: CGRect(x: 0, y: 0, width: 16 + CGFloat(toggles.count) * pitch, height: DS.Size.control + 24))
                host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                host.wantsLayer = true
                host.effectiveAppearance.performAsCurrentDrawingAppearance { host.layer?.backgroundColor = DS.Color.bgWindow.cgColor }
                for (i, toggle) in toggles.enumerated() {
                    let copy = IconButton(symbol: toggle.symbol, label: toggle.accessibilityLabel() ?? "", size: toggle.size)
                    copy.selection = toggle.selection
                    copy.marksSelection = toggle.marksSelection
                    copy.isSelected = toggle.isSelected
                    copy.frame.origin = CGPoint(x: 12 + CGFloat(i) * pitch, y: 12)
                    host.addSubview(copy)
                }
                try write(image(host, scale: 3), out.appendingPathComponent("toggles-\(name)-\(dark ? "dark" : "light").png"))
            }
        }
        let pill = panel.bounds.insetBy(dx: 32, dy: 32)
        notes.append("panel pill size: \(Int(pill.width)) x \(Int(pill.height)) pt; selection 480 x 270 pt; fits with 12 pt margins: \(pill.width <= 456 && pill.height <= 246)")

        notes.append("\ntooltips:")
        for id in ["options", "target.area", "target.window", "target.fullscreen", "width", "height", "aspect",
                   "source.microphone", "source.systemAudio", "source.camera", "source.clicks", "source.keystrokes",
                   "start.video", "start.gif", "start.editing", "help"] {
            notes.append("  \(id): \(findView("cornermark.record." + id, in: content)?.toolTip ?? "none")")
        }
        notes.append("\noptions menu:")
        for item in findView("cornermark.record.options", in: content)?.menu?.items ?? [] {
            if item.isSeparatorItem { notes.append("  ---"); continue }
            notes.append(item.isSectionHeader ? "  [\(item.title)]" : "  \(item.state == .on ? "x" : " ") \(item.title)")
        }

        (findView("cornermark.record.help", in: content) as? NSButton)?.performClick(nil)
        guard let help = c.capture.overlayWindows.first(where: { findView("cornermark.record.help.title", in: $0.contentView) != nil }) else { throw FilmError.missing("the help window") }
        for dark in [false, true] {
            try write(windowImage(help, dark: dark), out.appendingPathComponent("help-\(dark ? "dark" : "light").png"))
        }
        let text = { (id: String) in (findView("cornermark.record.help." + id, in: help.contentView) as? NSTextField)?.stringValue ?? "" }
        let button = (findView("cornermark.record.help.close", in: help.contentView) as? NSButton)?.title ?? ""
        notes.append("\nhelp window: \(text("title")) | \(text("body")) | button: \(button)")
        c.capture.cancel()
        _ = await waitUntil { c.capture.overlayWindows.isEmpty }
    }

    private static func bar(out: URL, notes: inout [String]) async throws {
        let view = RecordingBarView()
        let host = NSView(frame: CGRect(x: 0, y: 0, width: 420, height: RecordingBarView.height + 24))
        host.appearance = NSAppearance(named: .darkAqua)
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor(srgbRed: 0.85, green: 0.86, blue: 0.84, alpha: 1).cgColor
        host.addSubview(view)
        func shot(_ name: String) throws {
            host.frame.size.width = view.frame.width + 24
            view.frame.origin = CGPoint(x: 12, y: 12)
            try write(image(host, scale: 3), out.appendingPathComponent("bar-\(name).png"))
            notes += offPixelViews(in: view).map { "  bar-\(name) off-pixel:" + $0 }
            notes.append("  bar-\(name): width \(Int(view.frame.width)) pt, stop: \(view.stop.accessibilityLabel() ?? "")")
        }
        notes.append("\ncontrol bar:")
        view.apply(RecordingStatus(phase: .recording, seconds: 18))
        try shot("recording")
        view.showsMicrophone = true
        view.microphone.apply(MicrophoneStatus(level: AudioLevel(rms: 0.2, peak: 0.4), isSilent: false, quietFor: 0))
        try shot("recording-microphone")
        view.showsMicrophone = false
        view.apply(RecordingStatus(phase: .paused, seconds: 18))
        try shot("paused")
        view.apply(RecordingStatus(phase: .recording, seconds: 18))
        view.restart.performClick(nil)
        try shot("restart-armed")
        view.delete.performClick(nil)
        try shot("delete-armed")
        view.apply(RecordingStatus(phase: .countingDown(3), seconds: 0))
        try shot("countdown")
        view.stop.isHighlighted = true
        view.apply(RecordingStatus(phase: .recording, seconds: 618))
        try shot("stop-pressed")
        view.stop.isHighlighted = false
        notes.append("  tooltips: stop=\(view.stop.toolTip ?? "") pause=\(view.pause.toolTip ?? "") resume=\(view.resume.toolTip ?? "") restart=\(view.restart.toolTip ?? "") confirmRestart=\(view.confirmRestart.toolTip ?? "") delete=\(view.delete.toolTip ?? "") confirmDelete=\(view.confirmDelete.toolTip ?? "") grip=\(view.grip.toolTip ?? "")")
    }

    /// The video editor at its film size: every rail section light and dark, a selected zoom with its panel, and the export and zoom
    /// animation panels open. The project is recorded from the fixture display, so it carries no camera, microphone or key track.
    private static func editor(out: URL, notes: inout [String]) async throws {
        guard let film = Film(url: URL(fileURLWithPath: scratch).appendingPathComponent("editor-renders-\(UUID().uuidString.prefix(6)).mp4")) else {
            throw FilmError.missing("a film to host the editor")
        }
        let stage = try await EditorStage(film)
        defer { stage.w.cleanup() }
        guard let editor = try await stage.openProject() else { throw FilmError.missing("the editor") }
        var offPixel: [String] = []
        func shot(_ name: String, darkToo: Bool = true) async throws {
            await stage.settle(editor)
            for line in offPixelViews(in: editor.window?.contentView) where !offPixel.contains(line) { offPixel.append(line) }
            for dark in darkToo ? [false, true] : [false] {
                try write(editorImage(editor, dark: dark), out.appendingPathComponent("editor-\(name)-\(dark ? "dark" : "light").png"))
            }
        }
        for section in EditorSection.allCases {
            editor.select(section)
            try await shot(section.rawValue)
        }
        editor.select(.cursor)
        if let zoom = editor.addZoom(from: 0.5, to: 1.4) {
            editor.selectZoom(zoom.id)
            await editor.zoomTargetSettled()
            try await shot("zoom")
            editor.openZoomAnimation()
            try await shot("zoom-animation")
            editor.closeZoomAnimation()
            editor.selectZoom(nil)
        }
        editor.openExport()
        try await shot("export")
        notes.append("\noff-pixel views in any rendered state (window points; a 1x display needs whole points): \(offPixel.count)")
        notes += offPixel
        editor.closeExport()
        notes.append("\neditor: \(EditorSection.allCases.count) sections, zoom, zoom animation and export rendered light and dark")
        _ = await film.finish()
    }

    /// Views whose frame does not start on a whole point of the window, which draw their edges and text across two pixels at 1x.
    static func offPixelViews(in root: NSView?) -> [String] {
        guard let root else { return [] }
        var out: [String] = []
        func walk(_ v: NSView) {
            guard !v.isHidden else { return }
            let r = v.convert(v.bounds, to: nil)
            if r.minX.rounded() != r.minX || r.minY.rounded() != r.minY {
                out.append("  \(type(of: v)) \(v.accessibilityIdentifier()) \((v as? NSTextField)?.stringValue ?? (v as? NSButton)?.title ?? "") at \(r.origin.x), \(r.origin.y) size \(r.width) x \(r.height)")
            }
            v.subviews.forEach(walk)
        }
        walk(root)
        return out
    }
}
