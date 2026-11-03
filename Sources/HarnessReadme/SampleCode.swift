import AppKit

/// A dark code editor window showing a small Swift file. Positions come from `CodeWindow` so annotations can name a line and column.
enum CodeWindow {
    static let titleBarHeight: CGFloat = 40
    static let tabBarHeight: CGFloat = 30
    static let statusBarHeight: CGFloat = 24
    static let gutterWidth: CGFloat = 50
    static let lineHeight: CGFloat = 20
    static let fontSize: CGFloat = 12.5
    static let currentLine = 14

    static let source: [String] = """
    import Foundation

    /// Summarizes monthly sales figures.
    struct SalesSummary {
        let year: Int
        let revenue: [Double]
        let apiKey = "ada_demo_7f3a9c21b5e8"

        var total: Double {
            revenue.reduce(0, +)
        }

        /// Index of the month with the highest revenue.
        func peakMonth() -> Int? {
            guard let best = revenue.max() else {
                return nil
            }
            return revenue.firstIndex(of: best)
        }

        func growth(since prior: SalesSummary) -> Double {
            let change = total - prior.total
            return change / prior.total * 100
        }
    }

    extension SalesSummary {
        static let sample = SalesSummary(
            year: 2025,
            revenue: [268, 295, 322, 301, 356, 389,
                      372, 418, 447, 463, 512, 498]
        )
    }

    func printReport(_ summary: SalesSummary) {
        let total = String(format: "%.0f", summary.total)
        print("Total revenue: $\\(total)K")

        if let month = summary.peakMonth() {
            print("Peak month: \\(month + 1)")
        }
    }

    // TODO: Mark the November peak on the chart.
    printReport(.sample)
    """.components(separatedBy: "\n")

    static let bg = NSColor(hex: 0x1E2025)
    static let chrome = NSColor(hex: 0x2A2C32)
    static let plain = NSColor(hex: 0xC8CCD4)
    static let comment = NSColor(hex: 0x7A8190)
    static let keyword = NSColor(hex: 0xD58AF0)
    static let type = NSColor(hex: 0xE8C16E)
    static let function = NSColor(hex: 0x68B4F5)
    static let string = NSColor(hex: 0x9CCB7E)
    static let number = NSColor(hex: 0xE0A26A)

    static var charWidth: CGFloat { NSAttributedString(string: "M", attributes: [.font: Font.mono(fontSize)]).size().width }
    static var codeX: CGFloat { gutterWidth + 12 }
    static var firstLineY: CGFloat { titleBarHeight + tabBarHeight + 10 }

    static func lineRect(_ line: Int, columns: Range<Int>) -> CGRect {
        CGRect(x: codeX + CGFloat(columns.lowerBound) * charWidth, y: firstLineY + CGFloat(line - 1) * lineHeight,
               width: CGFloat(columns.count) * charWidth, height: lineHeight)
    }

    static func draw(_ c: Canvas, size: CGSize) {
        c.fill(CGRect(origin: .zero, size: size), bg)
        c.fill(CGRect(x: 0, y: 0, width: size.width, height: titleBarHeight), chrome)
        SampleScene.trafficLights(c, y: 20)
        c.symbol("swift", in: CGRect(x: size.width / 2 - 88, y: 10, width: 18, height: 20), color: NSColor(hex: 0xFF8A5B), pointSize: 13, weight: .semibold)
        c.text("SalesSummary.swift", at: CGPoint(x: size.width / 2 - 66, y: 12), font: Font.ui(13, .medium), color: NSColor(hex: 0xD6D9E0))

        let tabs = CGRect(x: 0, y: titleBarHeight, width: size.width, height: tabBarHeight)
        c.fill(tabs, NSColor(hex: 0x24262B))
        c.fill(CGRect(x: 0, y: tabs.minY, width: 148, height: tabs.height), bg)
        c.fill(CGRect(x: 0, y: tabs.minY, width: 148, height: 2), NSColor(hex: 0x68B4F5))
        c.text("SalesSummary.swift", at: CGPoint(x: 14, y: tabs.minY + 8), font: Font.ui(12, .medium), color: NSColor(hex: 0xD6D9E0))
        c.text("Report.swift", at: CGPoint(x: 166, y: tabs.minY + 8), font: Font.ui(12), color: comment)
        c.line(CGPoint(x: 0, y: tabs.maxY - 0.5), CGPoint(x: size.width, y: tabs.maxY - 0.5), NSColor(white: 1, alpha: 0.06))

        let font = Font.mono(fontSize)
        let editorBottom = size.height - statusBarHeight
        let visible = Int((editorBottom - firstLineY) / lineHeight)
        c.fill(CGRect(x: 0, y: lineRect(currentLine, columns: 0..<1).minY, width: size.width, height: lineHeight), NSColor(white: 1, alpha: 0.05))
        for (i, text) in source.enumerated() where i < visible {
            let n = i + 1
            let y = firstLineY + CGFloat(i) * lineHeight + 2
            c.text("\(n)", at: CGPoint(x: gutterWidth - 4, y: y), font: Font.digits(11.5), color: n == currentLine ? NSColor(hex: 0xC8CCD4) : NSColor(hex: 0x5C6270), align: .right)
            for token in tokens(text) {
                c.text(token.text, at: CGPoint(x: codeX + CGFloat(token.column) * charWidth, y: y), font: font, color: token.color)
            }
        }
        c.line(CGPoint(x: gutterWidth + 2, y: tabs.maxY), CGPoint(x: gutterWidth + 2, y: editorBottom), NSColor(white: 1, alpha: 0.04))

        let status = CGRect(x: 0, y: editorBottom, width: size.width, height: statusBarHeight)
        c.fill(status, chrome)
        c.symbol("arrow.triangle.branch", in: CGRect(x: 12, y: status.minY, width: 14, height: status.height), color: comment, pointSize: 10.5, weight: .medium)
        c.text("main", at: CGPoint(x: 30, y: status.minY + 5), font: Font.ui(11), color: NSColor(hex: 0x9EA4B1))
        var x = size.width - 14
        for item in ["Swift", "UTF-8", "Ln \(currentLine), Col 14"] {
            x -= c.text(item, at: CGPoint(x: x, y: status.minY + 5), font: Font.ui(11), color: NSColor(hex: 0x9EA4B1), align: .right) + 16
        }
    }

    // MARK: Highlighting

    struct Token {
        let text: String
        let column: Int
        let color: NSColor
    }

    private static let keywords: Set<String> = ["import", "struct", "let", "var", "func", "return", "guard", "if", "else", "extension", "static", "nil", "true", "false", "self"]

    static func tokens(_ line: String) -> [Token] {
        let chars = Array(line)
        var out: [Token] = []
        var i = 0
        func isIdent(_ ch: Character) -> Bool { ch.isLetter || ch.isNumber || ch == "_" }
        while i < chars.count {
            let ch = chars[i]
            if ch == "/", i + 1 < chars.count, chars[i + 1] == "/" {
                out.append(Token(text: String(chars[i...]), column: i, color: comment))
                break
            }
            if ch == "\"" {
                var j = i + 1
                while j < chars.count, chars[j] != "\"" { j += 1 }
                let end = min(j + 1, chars.count)
                out.append(Token(text: String(chars[i..<end]), column: i, color: string))
                i = end
            } else if ch.isNumber {
                var j = i
                while j < chars.count, chars[j].isNumber || chars[j] == "." { j += 1 }
                out.append(Token(text: String(chars[i..<j]), column: i, color: number))
                i = j
            } else if isIdent(ch) {
                var j = i
                while j < chars.count, isIdent(chars[j]) { j += 1 }
                let word = String(chars[i..<j])
                let previous = i > 0 ? chars[i - 1] : " "
                let isCall = j < chars.count && chars[j] == "("
                let color: NSColor
                if keywords.contains(word) { color = keyword }
                else if word.first!.isUppercase { color = type }
                else if isCall { color = function }
                else if previous == "." && word == "self" { color = keyword }
                else { color = plain }
                out.append(Token(text: word, column: i, color: color))
                i = j
            } else {
                if ch != " " { out.append(Token(text: String(ch), column: i, color: plain)) }
                i += 1
            }
        }
        return out
    }
}
