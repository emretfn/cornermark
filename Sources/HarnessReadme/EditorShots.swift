import AppKit
import CornermarkCore
import CornermarkEditor

/// Annotation geometry is in source pixels; the sample windows are drawn in points at 2x.
private let px: CGFloat = 2
private let coral = RGBA(0.894, 0.341, 0.180)

private func stroke(_ width: Double = 6) -> Stroke { Stroke(color: coral, width: width) }
private func scaled(_ r: CGRect) -> CGRect { CGRect(x: r.minX * px, y: r.minY * px, width: r.width * px, height: r.height * px) }
private func scaled(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * px, y: p.y * px) }

private func rect(_ r: CGRect, radius: Double = 22) -> Annotation {
    Annotation(kind: .rect(scaled(r), filled: false, cornerRadius: radius), stroke: stroke())
}

private func arrow(from a: CGPoint, to b: CGPoint, style: ArrowStyle = .classic) -> Annotation {
    Annotation(kind: .arrow(from: scaled(a), to: scaled(b), control: nil, style: style), stroke: stroke(7))
}

private func counter(_ n: Int, at p: CGPoint) -> Annotation {
    Annotation(kind: .counter(center: scaled(p), number: n, radius: 21), stroke: stroke())
}

private func callout(_ string: String, at p: CGPoint, size: Double = 30) -> Annotation {
    Annotation(kind: .text(origin: scaled(p), string: string, fontSize: size, style: .pill), stroke: stroke())
}

enum EditorScene {
    static func heroAnnotations() -> [Annotation] {
        let kpi = Dashboard.kpiCards[0].insetBy(dx: -5, dy: -5)
        let peak = Dashboard.peak
        let plot = Dashboard.plot
        let calloutOrigin = CGPoint(x: Dashboard.chartPoint(2, 0).x, y: plot.minY + 1)
        let email = Dashboard.emailCells.insetBy(dx: -4, dy: -2)
        return [
            rect(kpi),
            counter(1, at: CGPoint(x: kpi.minX + 2, y: kpi.minY + 2)),
            callout("November peak: $512K", at: calloutOrigin),
            arrow(from: CGPoint(x: calloutOrigin.x + 214, y: calloutOrigin.y + 13), to: CGPoint(x: peak.x - 10, y: peak.y - 4)),
            counter(2, at: CGPoint(x: calloutOrigin.x - 14, y: calloutOrigin.y + 13)),
            Annotation(kind: .pixelate(scaled(email), blockSize: 10, seed: 7), stroke: stroke()),
            counter(3, at: CGPoint(x: email.minX - 4, y: email.minY - 1)),
        ]
    }

    static func codeAnnotations() -> [Annotation] {
        let secret = CodeWindow.lineRect(7, columns: 17..<40).insetBy(dx: -3, dy: 1)
        let function = CodeWindow.lineRect(14, columns: 4..<30).insetBy(dx: -6, dy: 0)
        let note = CGPoint(x: 340, y: function.minY - 3)
        return [
            Annotation(kind: .blur(scaled(secret), mode: .smooth), stroke: stroke()),
            counter(1, at: CGPoint(x: secret.maxX + 22, y: secret.midY)),
            rect(function, radius: 12),
            counter(2, at: CGPoint(x: function.minX - 17, y: function.midY)),
            callout("Finds the peak month", at: note, size: 28),
            arrow(from: CGPoint(x: note.x - 8, y: function.midY), to: CGPoint(x: function.maxX + 6, y: function.midY)),
        ]
    }
}

@MainActor
func editorWindowImage(base: CGImage, annotations: [Annotation], background: BackgroundStyle, dark: Bool, contentSize: NSSize,
                       tool: EditorTool = .select) async throws -> CGImage {
    let rig = try Rig()
    defer { rig.cleanup() }
    let assets = AssetStore()
    guard let id = assets.add(image: base) else { throw ShotError("could not store the base image") }
    var document = Document(base: id, pixelSize: CGSize(width: base.width, height: base.height), pointScale: 2)
    document.annotations = annotations
    document.background = background
    let controller = EditorWindowController(document: document, assets: assets, defaults: rig.defaults)
    controller.pasteboard = rig.pasteboard
    guard let window = controller.window else { throw ShotError("editor has no window") }
    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    window.setContentSize(contentSize)
    controller.currentTool = tool
    window.contentView?.layoutSubtreeIfNeeded()
    settle(0.3)
    window.contentView?.layoutSubtreeIfNeeded()
    settle(0.2)
    guard let shot = snapshot(window: window, dark: dark) else { throw ShotError("editor snapshot failed") }
    return Compose.rounded(shot, radiusPoints: 16)
}

@MainActor
func heroShot() async throws -> CGImage {
    var background = BackgroundStyle()
    background.fill = .builtin(index: 4)
    background.padding = 70
    background.cornerRadius = 22
    background.aspectRatio = 2.0
    let window = try await editorWindowImage(base: SampleScene.dashboardWindow(), annotations: EditorScene.heroAnnotations(), background: background,
                                             dark: false, contentSize: NSSize(width: 1120, height: 720))
    return Compose.windowOnWallpaper(window)
}

@MainActor
func editorDarkShot() async throws -> CGImage {
    var background = BackgroundStyle()
    background.fill = .builtin(index: 14)
    background.padding = 80
    background.cornerRadius = 20
    background.aspectRatio = 2.0
    let window = try await editorWindowImage(base: SampleScene.codeWindow(size: CGSize(width: 700, height: 520)), annotations: EditorScene.codeAnnotations(),
                                             background: background, dark: true, contentSize: NSSize(width: 1120, height: 720))
    return Compose.windowOnWallpaper(window)
}
