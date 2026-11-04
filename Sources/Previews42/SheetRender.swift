import AppKit

enum SheetRenderer {
    static func columnName(_ i: Int) -> String {
        var n = i + 1, s = ""
        while n > 0 { n -= 1; s = String(UnicodeScalar(UInt8(65 + n % 26))) + s; n /= 26 }
        return s
    }

    static func css(_ c: NSColor) -> String {
        let s = c.usingColorSpace(.sRGB) ?? c
        return String(format: "#%02x%02x%02x", Int(s.redComponent * 255), Int(s.greenComponent * 255), Int(s.blueComponent * 255))
    }

    static func luminance(_ c: NSColor) -> CGFloat {
        let s = c.usingColorSpace(.sRGB) ?? c
        return 0.299 * s.redComponent + 0.587 * s.greenComponent + 0.114 * s.blueComponent
    }

    // MARK: HTML

    static func html(_ sheets: [PreviewSheet], title: String) -> String {
        var body = ""
        let multi = sheets.count > 1
        if multi {
            body += "<nav>" + sheets.enumerated().map { "<a href=\"#s\($0)\">\(HTMLPage.escape($1.name))</a>" }.joined() + "</nav>\n"
        }
        for (k, sheet) in sheets.enumerated() {
            body += "<section id=\"s\(k)\">"
            if multi { body += "<h2>\(HTMLPage.escape(sheet.name))</h2>" }
            body += table(sheet)
            if sheet.truncatedRows { body += "<p class=\"note\">\(HTMLPage.escape(String(format: Strings.firstRows, SheetReader.maxRows)))</p>" }
            body += "</section>\n"
        }
        let extra = multi ? ".sheet th { top:29px; }" : ""
        return HTMLPage.wrap(title: title, css: HTMLPage.sheetCSS + extra, body: body)
    }

    static func table(_ sheet: PreviewSheet) -> String {
        let cols = max(1, sheet.columnCount)
        var out = "<table class=\"sheet\">\n<colgroup><col>"
        for c in 0..<cols {
            if let w = sheet.columnWidths[c] { out += w == 0 ? "<col style=\"visibility:collapse\">" : "<col style=\"width:\(Int(w * 1.33))px\">" } else { out += "<col>" }
        }
        out += "</colgroup>\n<thead><tr><th class=\"r\"></th>"
        for c in 0..<cols { out += "<th>\(columnName(c))</th>" }
        out += "</tr></thead>\n<tbody>\n"
        for (r, row) in sheet.rows.enumerated() {
            out += "<tr><th class=\"r\">\(r + 1)</th>"
            for c in 0..<cols {
                guard c < row.count else { out += "<td></td>"; continue }
                let cell = row[c]
                if cell.covered { continue }
                var classes: [String] = []
                if cell.numeric && cell.align == nil { classes.append("n") }
                if cell.bold { classes.append("b") }
                if cell.italic { classes.append("i") }
                var style: [String] = []
                if let a = cell.align { style.append("text-align:\(a)") }
                if let bg = cell.background {
                    style.append("background:\(css(bg))")
                    // Explicit fill: keep the text dark/light against it in either colour scheme.
                    style.append("color:\(css(cell.color ?? (luminance(bg) > 0.5 ? .black : .white)))")
                } else if let fg = cell.color, luminance(fg) > 0.12, luminance(fg) < 0.9 {
                    style.append("color:\(css(fg))")
                }
                var attrs = classes.isEmpty ? "" : " class=\"\(classes.joined(separator: " "))\""
                if !style.isEmpty { attrs += " style=\"\(style.joined(separator: ";"))\"" }
                if cell.colSpan > 1 { attrs += " colspan=\"\(cell.colSpan)\"" }
                if cell.rowSpan > 1 { attrs += " rowspan=\"\(cell.rowSpan)\"" }
                out += "<td\(attrs)>\(HTMLPage.escape(cell.text))</td>"
            }
            out += "</tr>\n"
        }
        return out + "</tbody></table>"
    }

    // MARK: Thumbnail

    /// Draws the top-left part of the sheet as a grid filling `rect` (flipped context, light paper).
    static func draw(_ sheet: PreviewSheet, in page: NSRect) {
        NSColor.white.setFill()
        page.fill()
        let font = NSFont.systemFont(ofSize: 11)
        let rowH: CGFloat = 18
        let maxCols = 12
        // Column widths from content (first 40 rows), clamped; hidden columns stay hidden.
        var widths: [CGFloat] = []
        for c in 0..<min(maxCols, max(1, sheet.columnCount)) {
            var w: CGFloat = 40
            for row in sheet.rows.prefix(40) where c < row.count && row[c].colSpan == 1 {
                let t = row[c].text.split(separator: "\n").first.map(String.init) ?? ""
                w = max(w, (t as NSString).size(withAttributes: [.font: row[c].bold ? NSFont.systemFont(ofSize: 11, weight: .semibold) : font]).width + 12)
            }
            widths.append(sheet.columnWidths[c] == 0 ? 0 : min(w, 180))
        }
        // Small sheets are zoomed in so the thumbnail is not mostly empty paper.
        let contentW = max(1, widths.reduce(0, +)), contentH = max(1, CGFloat(sheet.rows.count) * rowH)
        let zoom = max(1, min(2.4, page.width / contentW, page.height / contentH))
        NSGraphicsContext.saveGraphicsState()
        let t = NSAffineTransform()
        t.translateX(by: page.minX, yBy: page.minY)
        t.scale(by: zoom)
        t.concat()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let rect = NSRect(x: 0, y: 0, width: page.width / zoom, height: page.height / zoom)
        let line = NSColor(white: 0.82, alpha: 1)
        var y = rect.minY
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail
        for row in sheet.rows {
            if y > rect.maxY { break }
            var x = rect.minX
            for (c, w) in widths.enumerated() {
                if x > rect.maxX { break }
                let cell = c < row.count ? row[c] : PreviewCell()
                if !cell.covered, w > 0 {
                    var span = NSRect(x: x, y: y, width: w, height: rowH)
                    if cell.colSpan > 1 { span.size.width = widths[c..<min(widths.count, c + cell.colSpan)].reduce(0, +) }
                    if let bg = cell.background { bg.setFill(); span.fill() }
                    var f = cell.bold ? NSFont.systemFont(ofSize: 11, weight: .semibold) : font
                    if cell.italic { f = NSFontManager.shared.convert(f, toHaveTrait: .italicFontMask) }
                    let p = para.mutableCopy() as! NSMutableParagraphStyle
                    p.alignment = cell.align == "center" ? .center : cell.align == "right" || (cell.numeric && cell.align == nil) ? .right : .left
                    let text = cell.text.split(separator: "\n").first.map(String.init) ?? ""
                    (text as NSString).draw(in: span.insetBy(dx: 5, dy: 2), withAttributes: [
                        .font: f, .foregroundColor: cell.color ?? NSColor(white: 0.1, alpha: 1), .paragraphStyle: p])
                    // Cell border (merged cells get one frame).
                    line.setStroke()
                    let border = NSBezierPath(rect: span.offsetBy(dx: 0.5, dy: 0.5))
                    border.lineWidth = 1
                    border.stroke()
                }
                x += w
            }
            y += rowH
        }
    }
}
