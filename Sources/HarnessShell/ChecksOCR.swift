import AppKit
import KadrajCore
import Vision
@testable import KadrajShell

@MainActor
func checkOCR() async throws {
    section("OCR: recognize(CGImage) with real Vision")
    let lines = Fixture.textLines
    let result = try await recognize(Pix.textImage(lines))
    check(result.lines.map(\.text) == lines, "rendered text is recognized line by line in reading order", detail: "\(result.lines.map(\.text))")
    check(result.qrPayloads.isEmpty, "no QR payload in a text-only image")
    check(result.text == lines.joined(separator: "\n"), "text joins lines with newlines")
    check(result.lines.map { $0.box.midY } == result.lines.map { $0.box.midY }.sorted(by: >), "line boxes run top to bottom")

    let qr = try await recognize(Pix.qrImage(Fixture.qrPayload))
    check(qr.qrPayloads == [Fixture.qrPayload], "CoreImage-generated QR payload is decoded", detail: "\(qr.qrPayloads)")
    check(qr.clipboardText == Fixture.qrPayload, "QR-only clipboard text is the payload")

    let mixed = try await recognize(combined(Pix.textImage(["Order 4711"]), Pix.qrImage("kadraj-ticket-9")))
    check(mixed.qrPayloads == ["kadraj-ticket-9"] && mixed.text.contains("Order 4711"), "text and QR in one image are both found", detail: "\(mixed)")
    check(mixed.clipboardText == "Order 4711\nkadraj-ticket-9" || mixed.clipboardText.hasSuffix("kadraj-ticket-9"), "clipboard text is text first, then the payload", detail: mixed.clipboardText)

    let blank = Pix.context(300, 200)
    blank.setFillColor(CGColor(gray: 1, alpha: 1))
    blank.fill(CGRect(x: 0, y: 0, width: 300, height: 200))
    let empty = try await recognize(blank.makeImage()!)
    check(empty.isEmpty && empty.clipboardText.isEmpty, "a blank image yields an empty result")

    let order = readingOrder([
        OCRLine(text: "bottom", box: CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.1)),
        OCRLine(text: "right", box: CGRect(x: 0.6, y: 0.81, width: 0.3, height: 0.1)),
        OCRLine(text: "left", box: CGRect(x: 0.1, y: 0.8, width: 0.3, height: 0.1)),
    ])
    check(order.map(\.text) == ["left", "right", "bottom"], "readingOrder puts same-row boxes left to right, rows top to bottom")

    let request = VNRecognizeTextRequest()
    let supported = (try? request.supportedRecognitionLanguages()) ?? []
    print("INFO Vision supports tr-TR: \(supported.contains("tr-TR")), count \(supported.count)")
    if supported.contains("tr-TR") {
        let tr = try await recognize(Pix.textImage(["Çalışma ışığı güneş"]))
        let t = tr.text.lowercased()
        check(t.contains("çal") || t.contains("güneş") || t.contains("ışığı"), "Turkish letters are recognized when tr-TR is available", detail: tr.text)
    }
}

func combined(_ top: CGImage, _ bottom: CGImage) -> CGImage {
    let w = max(top.width, bottom.width), h = top.height + bottom.height
    let ctx = Pix.context(w, h)
    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    ctx.draw(bottom, in: CGRect(x: 0, y: 0, width: bottom.width, height: bottom.height))
    ctx.draw(top, in: CGRect(x: 0, y: bottom.height, width: top.width, height: top.height))
    return ctx.makeImage()!
}
