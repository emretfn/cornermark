import AppKit

/// "Annual Sales Summary": a fictional sales dashboard. Everything is laid out from `Dashboard`'s constants, in window points.
enum Dashboard {
    static let size = CGSize(width: 860, height: 600)
    static let sidebarWidth: CGFloat = 188
    static let titleBarHeight: CGFloat = 44

    static let ink = NSColor(hex: 0x1D1D1F)
    static let muted = NSColor(hex: 0x6E6E73)
    static let faint = NSColor(hex: 0x8E8E93)
    static let teal = NSColor(hex: 0x0E7C86)
    static let tealDark = NSColor(hex: 0x0A5E66)
    static let coral = NSColor(hex: 0xE4572E)
    static let page = NSColor(hex: 0xF7F6F4)
    static let card = NSColor.white
    static let edge = NSColor(hex: 0xE6E4E0)

    static let contentX = sidebarWidth + 28
    static let contentWidth = size.width - contentX - 28

    static let kpiCards: [CGRect] = (0..<4).map { CGRect(x: contentX + CGFloat($0) * 157, y: 124, width: 145, height: 76) }
    static let chartCard = CGRect(x: contentX, y: 212, width: contentWidth, height: 172)
    static let tableCard = CGRect(x: contentX, y: 396, width: contentWidth, height: 176)
    static let plot = CGRect(x: chartCard.minX + 52, y: chartCard.minY + 46, width: chartCard.width - 52 - 20, height: chartCard.height - 46 - 28)

    static let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
    static let revenue2025: [Double] = [268, 295, 322, 301, 356, 389, 372, 418, 447, 463, 512, 498]
    static let revenue2024: [Double] = [231, 248, 262, 270, 291, 305, 312, 339, 352, 371, 402, 420]
    static let peakIndex = 10
    static let axisMin = 200.0
    static let axisMax = 600.0

    static func chartPoint(_ index: Int, _ value: Double) -> CGPoint {
        CGPoint(x: plot.minX + 14 + (plot.width - 28) * CGFloat(index) / 11, y: plot.maxY - plot.height * CGFloat((value - axisMin) / (axisMax - axisMin)))
    }

    static var peak: CGPoint { chartPoint(peakIndex, revenue2025[peakIndex]) }

    struct Order {
        let number, customer, email, amount, status: String
    }

    static let orders = [
        Order(number: "#SO-20418", customer: "Cedar Software", email: "billing@cedar.example", amount: "$18,450.00", status: "Completed"),
        Order(number: "#SO-20417", customer: "Prairie Foods", email: "purchasing@prairie.example", amount: "$7,920.50", status: "Processing"),
        Order(number: "#SO-20416", customer: "Harbor Logistics", email: "finance@harbor.example", amount: "$42,300.00", status: "Completed"),
        Order(number: "#SO-20415", customer: "Coral Textiles", email: "orders@coral.example", amount: "$3,185.75", status: "On hold"),
    ]

    static let rowHeight: CGFloat = 28
    static let rowsTop = tableCard.minY + 64
    static var emailCells: CGRect {
        CGRect(x: tableCard.minX + 240, y: rowsTop + 3, width: 160, height: rowHeight * CGFloat(orders.count) - 6)
    }

    // MARK: Drawing

    static func draw(_ c: Canvas) {
        c.fill(CGRect(origin: .zero, size: size), page)
        drawSidebar(c)
        c.text("Dashboard", at: CGPoint(x: (sidebarWidth + size.width) / 2, y: 14), font: Font.ui(13, .semibold), color: ink, align: .center)
        SampleScene.trafficLights(c, y: 22)
        drawHeader(c)
        for (i, kpi) in [("Total Revenue", "$4.64M", "▲ 22.0%", true), ("Orders", "18,240", "▲ 6.1%", true),
                         ("Average Order", "$264", "▼ 1.8%", false), ("New Customers", "1,284", "▲ 9.7%", true)].enumerated() {
            drawKPI(c, kpiCards[i], label: kpi.0, value: kpi.1, delta: kpi.2, up: kpi.3)
        }
        drawChart(c)
        drawTable(c)
    }

    private static func panel(_ c: Canvas, _ rect: CGRect) {
        c.shadowed(dy: 1, blur: 3, alpha: 0.06) { c.fill(rect, card, radius: 10) }
        c.stroke(rect, edge, radius: 10, width: 1)
    }

    private static func drawSidebar(_ c: Canvas) {
        c.fill(CGRect(x: 0, y: 0, width: sidebarWidth, height: size.height), NSColor(hex: 0xEDECE9))
        c.line(CGPoint(x: sidebarWidth - 0.5, y: 0), CGPoint(x: sidebarWidth - 0.5, y: size.height), NSColor(hex: 0xDDDBD7), width: 1)
        let logo = CGRect(x: 16, y: 62, width: 24, height: 24)
        c.linearGradient([NSColor(hex: 0x16A3A0), NSColor(hex: 0x0A5E66)], in: logo, from: CGPoint(x: logo.minX, y: logo.minY), to: CGPoint(x: logo.maxX, y: logo.maxY))
        c.withState {
            c.ctx.addPath(CGPath(roundedRect: logo, cornerWidth: 7, cornerHeight: 7, transform: nil))
            c.ctx.clip()
            c.linearGradient([NSColor(hex: 0x16A3A0), NSColor(hex: 0x0A5E66)], in: logo, from: CGPoint(x: logo.minX, y: logo.minY), to: CGPoint(x: logo.maxX, y: logo.maxY))
        }
        c.symbol("shippingbox.fill", in: logo, color: .white, pointSize: 12, weight: .semibold)
        c.text("Ada Supply", at: CGPoint(x: 48, y: 65), font: Font.ui(13, .semibold), color: ink)

        let items = [("square.grid.2x2", "Overview"), ("chart.line.uptrend.xyaxis", "Sales"), ("shippingbox", "Orders"),
                     ("person.2", "Customers"), ("archivebox", "Inventory"), ("doc.text", "Reports")]
        for (i, item) in items.enumerated() {
            let row = CGRect(x: 10, y: 104 + CGFloat(i) * 32, width: sidebarWidth - 20, height: 30)
            let selected = i == 0
            if selected { c.fill(row, teal.withAlphaComponent(0.14), radius: 7) }
            c.symbol(item.0, in: CGRect(x: row.minX + 8, y: row.minY, width: 20, height: row.height), color: selected ? teal : muted, pointSize: 13, weight: .medium)
            c.text(item.1, at: CGPoint(x: row.minX + 36, y: row.minY + 7), font: Font.ui(13, selected ? .semibold : .regular), color: selected ? tealDark : ink)
        }
        c.line(CGPoint(x: 16, y: size.height - 62), CGPoint(x: sidebarWidth - 16, y: size.height - 62), NSColor(hex: 0xDDDBD7), width: 1)
        c.symbol("gearshape", in: CGRect(x: 18, y: size.height - 52, width: 20, height: 30), color: muted, pointSize: 13, weight: .medium)
        c.text("Settings", at: CGPoint(x: 46, y: size.height - 45), font: Font.ui(13), color: ink)
    }

    private static func drawHeader(_ c: Canvas) {
        c.text("Annual Sales Summary", at: CGPoint(x: contentX, y: 62), font: Font.ui(22, .bold), color: ink)
        c.text("Jan 1 – Dec 31, 2025  ·  All regions", at: CGPoint(x: contentX, y: 92), font: Font.ui(12.5), color: muted)
        let widths: [CGFloat] = [56, 44, 44]
        let track = CGRect(x: size.width - 28 - widths.reduce(0, +) - 6, y: 62, width: widths.reduce(0, +) + 6, height: 28)
        c.fill(track, NSColor(hex: 0xE9E7E3), radius: 8)
        var x = track.minX + 3
        for (i, title) in ["Week", "Month", "Year"].enumerated() {
            let r = CGRect(x: x, y: track.minY + 3, width: widths[i], height: 22)
            if i == 2 {
                c.shadowed(dy: 1, blur: 2, alpha: 0.14) { c.fill(r, .white, radius: 6) }
            }
            c.text(title, at: CGPoint(x: r.midX, y: r.minY + 4), font: Font.ui(12, i == 2 ? .semibold : .medium), color: i == 2 ? ink : muted, align: .center)
            x += widths[i]
        }
    }

    private static func drawKPI(_ c: Canvas, _ r: CGRect, label: String, value: String, delta: String, up: Bool) {
        panel(c, r)
        c.text(label, at: CGPoint(x: r.minX + 14, y: r.minY + 11), font: Font.ui(11.5, .medium), color: muted)
        c.text(value, at: CGPoint(x: r.minX + 14, y: r.minY + 28), font: Font.ui(22, .semibold), color: ink)
        let w = c.text(delta, at: CGPoint(x: r.minX + 14, y: r.minY + 57), font: Font.ui(11, .semibold), color: up ? NSColor(hex: 0x1B8A4B) : NSColor(hex: 0xC8372D))
        c.text("vs last year", at: CGPoint(x: r.minX + 14 + w + 5, y: r.minY + 57), font: Font.ui(11), color: faint)
    }

    private static func smoothPath(_ pts: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        path.move(to: pts[0])
        for i in 0..<pts.count - 1 {
            let p0 = pts[max(i - 1, 0)], p1 = pts[i], p2 = pts[i + 1], p3 = pts[min(i + 2, pts.count - 1)]
            path.addCurve(to: p2, control1: CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6),
                          control2: CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6))
        }
        return path
    }

    private static func drawChart(_ c: Canvas) {
        let r = chartCard
        panel(c, r)
        c.text("Monthly revenue", at: CGPoint(x: r.minX + 16, y: r.minY + 14), font: Font.ui(13, .semibold), color: ink)
        c.text("$ thousands", at: CGPoint(x: r.minX + 16 + c.textWidth("Monthly revenue", font: Font.ui(13, .semibold)) + 8, y: r.minY + 16), font: Font.ui(11), color: faint)
        var lx = r.maxX - 16
        for (name, color, dashed) in [("2024", NSColor(hex: 0xA6A6AB), true), ("2025", teal, false)] {
            lx -= c.text(name, at: CGPoint(x: lx, y: r.minY + 15), font: Font.ui(11.5, .medium), color: muted, align: .right) + 6
            if dashed { c.line(CGPoint(x: lx - 14, y: r.minY + 22.5), CGPoint(x: lx, y: r.minY + 22.5), color, width: 1.5, dash: [3, 2]) }
            else { c.line(CGPoint(x: lx - 14, y: r.minY + 22.5), CGPoint(x: lx, y: r.minY + 22.5), color, width: 2) }
            lx -= 14 + 16
        }

        for step in 0...4 {
            let v = axisMin + Double(step) * 100
            let y = plot.maxY - plot.height * CGFloat((v - axisMin) / (axisMax - axisMin))
            c.line(CGPoint(x: plot.minX, y: y), CGPoint(x: plot.maxX, y: y), NSColor(hex: step == 0 ? 0xD9D7D3 : 0xEFEDEA), width: 1)
            c.text("\(Int(v))", at: CGPoint(x: plot.minX - 10, y: y - 7), font: Font.digits(10.5), color: faint, align: .right)
        }
        for (i, m) in months.enumerated() {
            c.text(m, at: CGPoint(x: chartPoint(i, axisMin).x, y: plot.maxY + 8), font: Font.ui(10.5), color: faint, align: .center)
        }

        let previous = revenue2024.enumerated().map { chartPoint($0.offset, $0.element) }
        c.withState {
            c.ctx.addPath(smoothPath(previous))
            c.ctx.setStrokeColor(NSColor(hex: 0xA6A6AB).cgColor)
            c.ctx.setLineWidth(1.5)
            c.ctx.setLineDash(phase: 0, lengths: [4, 3])
            c.ctx.setLineCap(.round)
            c.ctx.strokePath()
        }

        let current = revenue2025.enumerated().map { chartPoint($0.offset, $0.element) }
        let area = CGMutablePath()
        area.addPath(smoothPath(current))
        area.addLine(to: CGPoint(x: current.last!.x, y: plot.maxY))
        area.addLine(to: CGPoint(x: current[0].x, y: plot.maxY))
        area.closeSubpath()
        c.withState {
            c.ctx.addPath(area)
            c.ctx.clip()
            c.linearGradient([teal.withAlphaComponent(0.26), teal.withAlphaComponent(0.02)], in: plot.insetBy(dx: -20, dy: -10),
                             from: CGPoint(x: 0, y: plot.minY), to: CGPoint(x: 0, y: plot.maxY))
        }
        c.withState {
            c.ctx.addPath(smoothPath(current))
            c.ctx.setStrokeColor(teal.cgColor)
            c.ctx.setLineWidth(2.5)
            c.ctx.setLineCap(.round)
            c.ctx.setLineJoin(.round)
            c.ctx.strokePath()
        }
        c.circle(center: peak, radius: 6, fill: teal)
        c.circle(center: peak, radius: 3.2, fill: .white)
    }

    private static func statusStyle(_ status: String) -> (NSColor, NSColor) {
        switch status {
        case "Completed": return (NSColor(hex: 0x167A43), NSColor(hex: 0xE3F4EA))
        case "Processing": return (NSColor(hex: 0x9A5B00), NSColor(hex: 0xFBEFD9))
        default: return (NSColor(hex: 0x57575C), NSColor(hex: 0xECEBE8))
        }
    }

    private static func drawTable(_ c: Canvas) {
        let r = tableCard
        panel(c, r)
        c.text("Recent orders", at: CGPoint(x: r.minX + 16, y: r.minY + 13), font: Font.ui(13, .semibold), color: ink)
        c.text("View all", at: CGPoint(x: r.maxX - 16, y: r.minY + 14), font: Font.ui(12, .medium), color: teal, align: .right)

        let header = CGRect(x: r.minX, y: r.minY + 38, width: r.width, height: 26)
        c.fill(header, NSColor(hex: 0xF6F5F3))
        c.line(CGPoint(x: r.minX, y: header.minY), CGPoint(x: r.maxX, y: header.minY), NSColor(hex: 0xEEECE9))
        let cols: [(String, CGFloat, Align)] = [("Order", 16, .left), ("Customer", 104, .left), ("Email", 244, .left), ("Amount", 506, .right), ("Status", 524, .left)]
        for (title, x, align) in cols {
            c.text(title, at: CGPoint(x: r.minX + x, y: header.minY + 6), font: Font.ui(11, .medium), color: muted, align: align)
        }
        for (i, o) in orders.enumerated() {
            let y = rowsTop + CGFloat(i) * rowHeight
            if i > 0 { c.line(CGPoint(x: r.minX + 16, y: y), CGPoint(x: r.maxX - 16, y: y), NSColor(hex: 0xF0EEEB)) }
            c.text(o.number, at: CGPoint(x: r.minX + 16, y: y + 7), font: Font.digits(11.5), color: muted)
            c.text(o.customer, at: CGPoint(x: r.minX + 104, y: y + 6), font: Font.ui(12.5, .medium), color: ink)
            c.text(o.email, at: CGPoint(x: r.minX + 244, y: y + 7), font: Font.ui(12), color: NSColor(hex: 0x55555A))
            c.text(o.amount, at: CGPoint(x: r.minX + 506, y: y + 6), font: Font.digits(12.5, .medium), color: ink, align: .right)
            let (fg, bg) = statusStyle(o.status)
            let font = Font.ui(11, .medium)
            let pill = CGRect(x: r.minX + 524, y: y + 4, width: c.textWidth(o.status, font: font) + 18, height: 20)
            c.fill(pill, bg, radius: 10)
            c.text(o.status, at: CGPoint(x: pill.midX, y: pill.minY + 3), font: font, color: fg, align: .center)
        }
    }
}
