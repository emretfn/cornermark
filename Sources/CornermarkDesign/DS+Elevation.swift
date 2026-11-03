import AppKit

public struct ShadowLayer {
    public let offsetY: CGFloat
    public let blur: CGFloat
    public let alpha: CGFloat

    public init(offsetY: CGFloat, blur: CGFloat, alpha: CGFloat) {
        self.offsetY = offsetY
        self.blur = blur
        self.alpha = alpha
    }
}

public struct Elevation {
    public let contact: ShadowLayer
    public let ambient: ShadowLayer
    public let highlightAlpha: CGFloat

    public init(contact: ShadowLayer, ambient: ShadowLayer, highlightAlpha: CGFloat) {
        self.contact = contact
        self.ambient = ambient
        self.highlightAlpha = highlightAlpha
    }

    /// Draws into the current graphics context, flipped or not. Shadows are cast only outside the path, so a translucent
    /// fill such as `bgHud` is not darkened from underneath.
    public func draw(_ path: NSBezierPath, fill: NSColor) {
        guard let context = NSGraphicsContext.current else { return }
        cast(ambient, path, context)
        cast(contact, path, context)
        fill.setFill()
        path.fill()
        if highlightAlpha > 0 { highlight(path, context) }
    }

    private func cast(_ layer: ShadowLayer, _ path: NSBezierPath, _ context: NSGraphicsContext) {
        context.saveGraphicsState()
        defer { context.restoreGraphicsState() }
        let reach = layer.blur * 2 + abs(layer.offsetY) + 2
        let clip = NSBezierPath(rect: path.bounds.insetBy(dx: -reach, dy: -reach))
        clip.append(path)
        clip.windingRule = .evenOdd
        clip.addClip()

        // The caster is drawn far outside the clip and its shadow is offset back, so only the shadow is visible.
        // NSShadow offsets live in base space, which a flipped view does not flip, so down is always negative.
        let far: CGFloat = 8192
        let caster = path.copy() as! NSBezierPath
        caster.transform(using: AffineTransform(translationByX: -far, byY: 0))
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(layer.alpha)
        shadow.shadowBlurRadius = layer.blur
        shadow.shadowOffset = NSSize(width: far, height: -layer.offsetY)
        shadow.set()
        NSColor.black.setFill()
        caster.fill()
    }

    private func highlight(_ path: NSBezierPath, _ context: NSGraphicsContext) {
        context.saveGraphicsState()
        defer { context.restoreGraphicsState() }
        path.addClip()
        let lower = path.copy() as! NSBezierPath
        lower.transform(using: AffineTransform(translationByX: 0, byY: context.isFlipped ? 1 : -1))
        let sliver = NSBezierPath(rect: path.bounds.insetBy(dx: -2, dy: -2))
        sliver.append(lower)
        sliver.windingRule = .evenOdd
        sliver.addClip()
        NSColor.white.withAlphaComponent(highlightAlpha).setFill()
        path.bounds.fill()
    }
}

extension DS {
    public enum Elevation {
        public static let raised = CornermarkDesign.Elevation(contact: ShadowLayer(offsetY: 1, blur: 2, alpha: 0.12),
                                                          ambient: ShadowLayer(offsetY: 2, blur: 6, alpha: 0.10), highlightAlpha: 0)
        public static let hud = CornermarkDesign.Elevation(contact: ShadowLayer(offsetY: 1, blur: 3, alpha: 0.30),
                                                       ambient: ShadowLayer(offsetY: 8, blur: 24, alpha: 0.35), highlightAlpha: 0.10)
        public static let floating = CornermarkDesign.Elevation(contact: ShadowLayer(offsetY: 2, blur: 4, alpha: 0.25),
                                                            ambient: ShadowLayer(offsetY: 12, blur: 32, alpha: 0.40), highlightAlpha: 0.12)
    }
}
