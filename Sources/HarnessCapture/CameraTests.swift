import AppKit
import AVFoundation
import CornermarkCapture
import CornermarkCore

/// Presentation times of every frame in a file's video track.
func frameTimes(_ url: URL) async -> [Double] {
    let asset = AVURLAsset(url: url)
    guard let track = try? await asset.loadTracks(withMediaType: .video).first, let reader = try? AVAssetReader(asset: asset) else { return [] }
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
    reader.add(output)
    reader.startReading()
    var times: [Double] = []
    while let sample = output.copyNextSampleBuffer() {
        if CMSampleBufferGetNumSamples(sample) > 0 { times.append(CMSampleBufferGetPresentationTimeStamp(sample).seconds) }
    }
    return times
}

/// True when the pixel is the synthetic camera's red marker.
@MainActor
func isMarker(_ rgb: [Int]) -> Bool { rgb[0] > 170 && rgb[1] < 90 && rgb[2] < 110 }

@MainActor
func runCameraTests() async {
    section("camera")
    try? FileManager.default.createDirectory(atPath: recordingScratch, withIntermediateDirectories: true)
    let fps = 60
    let area = CGSize(width: 1280, height: 720)

    /// Camera pictures at 30 fps and screen frames at 60 fps, interleaved the way a live recording receives them, for `seconds`.
    /// `quiet` is a stretch with camera pictures and no screen frames. `during` runs before each camera picture with its time.
    func record(_ name: String, editing: Bool, seconds: Double, quiet: ClosedRange<Double>? = nil, look: CameraLook,
                during: (Double, Recorder) -> Void = { _, _ in }) async throws -> (RecordingReport, URL, URL?) {
        let url = URL(fileURLWithPath: recordingScratch + name + ".mp4")
        let cameraURL = editing ? URL(fileURLWithPath: recordingScratch + name + "-camera.mp4") : nil
        let screen = FixtureFrameSource(options: RecordingOptions(fps: fps), pacing: .manual)
        let camera = ScriptedCameraSource(pacing: .manual(origin: 0))
        let recorder = Recorder(source: screen, output: url, camera: CameraRecording(source: camera, output: cameraURL, look: look))
        try await recorder.start()
        let pictures = Int(seconds * Double(ScriptedCameraSource.fps))
        for k in 0..<pictures {
            let t = Double(k) / Double(ScriptedCameraSource.fps)
            during(t, recorder)
            camera.advance()
            if let quiet, quiet.contains(t) { continue }
            try screen.advance(2)
        }
        return (try await recorder.stop(), url, cameraURL)
    }

    do {
        let look = CameraLook(CameraBubble())
        let (report, url, cameraURL) = try await record("camera-editing", editing: true, seconds: 3, quiet: 2.0...3.0, look: look) { t, _ in
            if abs(t - 0.5) < 1e-9 { look.setFullScreen(true, at: t) }
            if abs(t - 1.2) < 1e-9 { look.setFullScreen(false, at: t) }
        }
        let screenTimes = await frameTimes(url)
        let cameraTimes = await frameTimes(cameraURL!)
        check(report.camera?.file == cameraURL && FileManager.default.fileExists(atPath: cameraURL!.path),
              "Record for Editing writes the camera to its own file beside the video", detail: "\(String(describing: report.camera))")
        check(!screenTimes.isEmpty && cameraTimes == screenTimes, "the camera file has a frame at every moment the video has one, so both share a timeline",
              detail: "screen \(screenTimes.count) camera \(cameraTimes.count)")
        let filled = report.camera?.filled ?? 0
        let quietTimes = screenTimes.filter { $0 >= 2.0 }
        let widest = zip(quietTimes, quietTimes.dropFirst()).map { $1 - $0 }.max() ?? 1
        check(filled >= 27 && widest < 1.0 / 30 + 1e-3, "a still screen keeps the camera moving: once the screen is quiet each camera picture makes a frame",
              detail: "filled \(filled), widest gap \(widest)")
        let spans = report.camera?.bubble.fullScreen ?? []
        check(spans.count == 1 && abs(spans[0].from - 0.5) < 1e-6 && abs(spans[0].to - 1.2) < 1e-6,
              "a full-screen click lands on the video's timeline", detail: "\(spans)")
        let project = report.project
        check(project.source.camera == cameraURL!.lastPathComponent && project.edits.camera.fullScreen == spans,
              "the project names the camera file and keeps the look", detail: "\(project.source)")
        let inPicture = await frame(of: url, at: 1.0)
        let bubble = CameraLayout.bubbleRect(CameraBubble(), area: area)
        check(inPicture.map { !isMarker(color($0, (bubble.midX + bubble.width * 0.3) / area.width, bubble.midY / area.height)) } == true,
              "Record for Editing draws no camera into its picture")
    } catch {
        check(false, "recording for editing with the camera threw", detail: "\(error)")
    }

    do {
        let look = CameraLook(CameraBubble())
        let (report, url, _) = try await record("camera-video", editing: false, seconds: 2.4, look: look) { t, _ in
            if abs(t - 1.0) < 1e-9 { look.update { $0.isMirrored = false } }
            if abs(t - 1.5) < 1e-9 { look.update { $0.shape = .rectangle; $0.position = .topRight; $0.size = .large } }
            if abs(t - 2.0) < 1e-9 { look.setFullScreen(true, at: t) }
        }
        check(report.camera?.file == nil && report.project.source.camera == nil, "Record Video keeps no camera file: the camera is in its picture")
        let bubble = CameraLayout.bubbleRect(CameraBubble(), area: area)
        let markerSide = CameraBubblePainter.aspectFill(CGSize(width: 640, height: 360), in: bubble)
        let marker = SyntheticCamera.markerRect(CGSize(width: 640, height: 360))
        let leftX = markerSide.minX + (marker.midX / 640) * markerSide.width
        let rightX = markerSide.maxX - (marker.midX / 640) * markerSide.width
        let y = bubble.midY / area.height
        if let mirrored = await frame(of: url, at: 0.5), let plain = await frame(of: url, at: 1.25) {
            check(isMarker(color(mirrored, rightX / area.width, y)) && !isMarker(color(mirrored, leftX / area.width, y)),
                  "the camera is drawn into the picture mirrored, its left marker on the right", detail: "\(color(mirrored, rightX / area.width, y))")
            check(isMarker(color(plain, leftX / area.width, y)) && !isMarker(color(plain, rightX / area.width, y)),
                  "turning mirroring off flips it back while recording", detail: "\(color(plain, leftX / area.width, y))")
        } else {
            check(false, "frames of the video could be read")
        }
        let wide = CameraBubble(shape: .rectangle, size: .large, position: .topRight, isMirrored: false)
        let rect = CameraLayout.bubbleRect(wide, area: area)
        if let moved = await frame(of: url, at: 1.75) {
            let fill = CameraBubblePainter.aspectFill(CGSize(width: 640, height: 360), in: rect)
            let x = fill.minX + (marker.midX / 640) * fill.width
            check(isMarker(color(moved, x / area.width, rect.midY / area.height)) && !isMarker(color(moved, leftX / area.width, y)),
                  "a new shape, size and corner reach the picture", detail: "rect \(rect)")
        }
        if let full = await frame(of: url, at: 2.38) {
            let fill = CameraBubblePainter.aspectFill(CGSize(width: 640, height: 360), in: CGRect(origin: .zero, size: area))
            let x = fill.minX + (marker.midX / 640) * fill.width
            check(isMarker(color(full, x / area.width, 0.5)), "full screen fills the picture with the camera after its transition")
        }
    } catch {
        check(false, "recording a video with the camera threw", detail: "\(error)")
    }

    do {
        let spans = CameraSpans.onVideo([CameraSpan(from: 10.5, to: 11.5), CameraSpan(from: 12.2, to: .infinity)], firstFrame: 10,
                                        end: 4, pauses: [RecordingPause(from: 1.2, to: 2.0)])
        let expected = [CameraSpan(from: 0.5, to: 1.2), CameraSpan(from: 1.4, to: 3.2)]
        check(spans.count == 2 && zip(spans, expected).allSatisfy { abs($0.from - $1.from) < 1e-9 && abs($0.to - $1.to) < 1e-9 },
              "spans on the recording clock move onto the video: a pause cuts them, an open one ends with the recording", detail: "\(spans)")
    }

    check(LiveCameraSource.sessionsOpened == 0 && CameraAccess.requests == 0, "no real camera was opened and access was never asked for",
          detail: "sessions \(LiveCameraSource.sessionsOpened) requests \(CameraAccess.requests)")
}
