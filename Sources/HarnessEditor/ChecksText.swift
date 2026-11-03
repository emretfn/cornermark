import AppKit
import CornermarkCore
import CornermarkEditor

func textAnnotation(_ a: Annotation?) -> (origin: CGPoint, string: String, size: Double, style: TextStylePreset)? {
    if case .text(let o, let s, let size, let st)? = a?.kind { return (o, s, size, st) }
    return nil
}

func checkText() {
    section("Inline text editing")
    let rig = makeRig(zoom: 0.6)
    let d = rig.driver, c = rig.controller
    d.tapKey("t")
    let at = CGPoint(x: 300, y: 300)
    d.click(d.windowPoint(source: at))
    settle(0.05)
    let editor = c.view(identifier: "canvas.textEditor") as? NSTextView
    check("text tool click opens an inline NSTextView over the canvas", editor != nil && editor?.superview === c.canvasView)
    check("the inline editor is first responder", c.window?.firstResponder === editor)
    if let editor {
        let topLeft = editor.convert(CGPoint.zero, to: nil)
        let wantTop = d.windowPoint(source: at)
        check("editor origin sits at the clicked source pixel at zoom 0.6", abs(topLeft.x - wantTop.x) < 2 && abs(editor.frame.minY - c.canvasView.convert(wantTop, from: nil).y) < 2,
              "\(topLeft) vs \(wantTop)")
    }
    d.type("Hello")
    check("real key events type into the editor", editor?.string == "Hello", editor?.string ?? "nil")
    let fontPx = editor?.font?.pointSize ?? 0
    d.escape()
    settle(0.05)
    let t = textAnnotation(rig.last)
    check("Escape commits the text as an annotation", t?.string == "Hello" && rig.doc.annotations.count == 1, "\(String(describing: t))")
    check("committed origin matches the click in source pixels", t.map { near($0.origin, at, 1.5) } ?? false, t.map { fmt($0.origin) } ?? "")
    check("editor font was drawn at the zoomed size (source size x zoom)", t.map { abs(fontPx - CGFloat($0.size) * 0.6) < 0.6 } ?? false, "font \(fontPx) size \(t?.size ?? 0)")
    check("the editor is gone after commit", c.view(identifier: "canvas.textEditor") == nil)
    let id = rig.last!.id

    d.tapKey("v")
    let hit = d.windowPoint(source: CGPoint(x: at.x + 15, y: at.y + 10))
    d.down(hit, clicks: 2); d.up(hit, clicks: 2)
    settle(0.05)
    let editor2 = c.view(identifier: "canvas.textEditor") as? NSTextView
    check("double-click on text re-opens the editor with its content", editor2?.string == "Hello", editor2?.string ?? "nil")
    d.type(" World")
    d.key("\r", code: 36, flags: .command)
    settle(0.05)
    check("Cmd+Return commits the edit as an update to the same annotation",
          rig.doc.annotations.count == 1 && rig.last?.id == id && textAnnotation(rig.last)?.string == "Hello World", "\(String(describing: textAnnotation(rig.last)))")
    d.key("z", code: 6, flags: .command)
    check("undo restores the previous text", textAnnotation(rig.last)?.string == "Hello")

    d.tapKey("t")
    let far = d.windowPoint(source: CGPoint(x: 700, y: 500))
    d.click(far)
    d.escape()
    check("committing an empty editor adds nothing", rig.doc.annotations.count == 1)

    d.click(far)
    d.type("Styled")
    let popup = c.view(identifier: "prop.textStyle") as? NSPopUpButton
    popup?.selectItem(at: TextStylePreset.allCases.firstIndex(of: .pill)!)
    popup?.sendAction(popup?.action, to: popup?.target)
    let tools = c.view(identifier: "toolbar.tools") as? NSSegmentedControl
    tools?.selectedSegment = EditorTool.allCases.firstIndex(of: .select)!
    tools?.sendAction(tools?.action, to: tools?.target)
    check("switching tool commits the open editor with the chosen preset", textAnnotation(rig.last)?.string == "Styled" && textAnnotation(rig.last)?.style == .pill,
          "\(String(describing: textAnnotation(rig.last)))")
    closeRig(rig)
}
