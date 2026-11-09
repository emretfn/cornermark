import AppKit
import CornermarkL10n
@testable import CornermarkDesign

/// The columns of `field` that hold ink, drawn as it sits in a real window.
private func inkColumns(_ field: NSTextField) -> ClosedRange<Int>? {
    field.displayIfNeeded()
    guard let rep = field.bitmapImageRepForCachingDisplay(in: field.bounds) else { return nil }
    field.cacheDisplay(in: field.bounds, to: rep)
    var columns: [Int] = []
    for x in 0..<rep.pixelsWide {
        for y in 0..<rep.pixelsHigh where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.3 {
            columns.append(x)
            break
        }
    }
    guard let first = columns.first, let last = columns.last else { return nil }
    return first...last
}

func checkLabelAlignment() {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 60), styleMask: [.titled], backing: .buffered, defer: false)
    let root = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 60))
    window.contentView = root
    for text in ["Launch at login", "فتح عند تسجيل الدخول"] {
        let field = NSTextField.label(text, style: DS.Text.body, color: .black)
        field.frame = NSRect(x: 20, y: 20, width: 300, height: 20)
        root.addSubview(field)
        root.applyLanguageDirection(.leftToRight)
        let ltr = inkColumns(field)
        root.applyLanguageDirection(.rightToLeft)
        let rtl = inkColumns(field)
        root.applyLanguageDirection(.leftToRight)
        let back = inkColumns(field)
        let width = Int(field.bounds.width * window.backingScaleFactor)
        check("a label's text starts at the right edge of its frame in a right-to-left language (\(text.first!.isASCII ? "Latin" : "Arabic") text)",
              (rtl?.upperBound ?? 0) > width * 9 / 10 && (rtl?.lowerBound ?? 0) > width / 4, "\(String(describing: rtl)) of \(width)")
        if text.first!.isASCII {
            check("a Latin label starts at the left edge in a left-to-right language, before and after a right-to-left one",
                  (ltr?.lowerBound ?? width) < width / 10 && back == ltr, "\(String(describing: ltr)) \(String(describing: back))")
        }
        field.removeFromSuperview()
    }
}
