import AppKit
import Kit42

/// Display-only spreadsheet for Quick Look: formatted cell text with a few visible styles.
public struct PreviewCell {
    public var text = ""
    public var numeric = false
    public var bold = false
    public var italic = false
    public var align: String?           // "left" | "center" | "right"
    public var background: NSColor?
    public var color: NSColor?
    public var colSpan = 1
    public var rowSpan = 1
    public var covered = false          // hidden by a merged cell
}

public struct PreviewSheet {
    public var name: String
    public var rows: [[PreviewCell]] = []
    public var columnWidths: [Int: CGFloat] = [:]   // points
    public var truncatedRows = false

    public var columnCount: Int { rows.map(\.count).max() ?? 0 }
}

public enum SheetReader {
    public static let maxRows = 2000
    public static let maxColumns = 200

    // MARK: Delimited text (TSV/CSV)

    public static func delimited(_ data: Data, separator: Character? = nil) -> PreviewSheet {
        let text = TextDecoding.decode(data).text
        let sep = separator ?? guessSeparator(text)
        var sheet = PreviewSheet(name: "")
        var row: [PreviewCell] = [], field = "", quoted = false, wasQuoted = false
        var chars = text.makeIterator()
        var pending: Character? = nil
        func endField() {
            var c = PreviewCell(text: field)
            c.numeric = !wasQuoted && isNumber(field)
            if row.count < maxColumns { row.append(c) }
            field = ""; wasQuoted = false
        }
        func endRow() {
            endField()
            if sheet.rows.count < maxRows { sheet.rows.append(row) } else { sheet.truncatedRows = true }
            row = []
        }
        while let ch = pending ?? chars.next() {
            pending = nil
            if quoted {
                if ch == "\"" {
                    if let next = chars.next() {
                        if next == "\"" { field.append("\"") } else { quoted = false; pending = next }
                    } else { quoted = false }
                } else { field.append(ch) }
                continue
            }
            switch ch {
            case "\"" where field.isEmpty: quoted = true; wasQuoted = true
            case sep: endField()
            case "\n", "\r\n", "\r": endRow()
            default: field.append(ch)
            }
            if sheet.truncatedRows { break }
        }
        if !field.isEmpty || !row.isEmpty { endRow() }
        return sheet
    }

    static func guessSeparator(_ text: String) -> Character {
        let head = text.prefix(4000)
        let counts: [(Character, Int)] = ["\t", ";", ",", "|"].map { c in (c, head.filter { $0 == c }.count) }
        return counts.max { $0.1 < $1.1 }.map { $0.1 > 0 ? $0.0 : "," } ?? ","
    }

    static func isNumber(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, t.count < 40 else { return false }
        return t.range(of: #"^[-+]?[\p{Sc}]?\s?[-+]?(\d{1,3}([ ,.\u{00A0}]\d{3})+|\d+)([.,]\d+)?([eE][-+]?\d+)?\s?[%\p{Sc}]?$"#, options: .regularExpression) != nil
    }

    // MARK: OpenDocument Spreadsheet

    struct ODFStyle {
        var parent: String?
        var bold: Bool?
        var italic: Bool?
        var align: String?
        var background: NSColor?
        var color: NSColor?
        var columnWidth: CGFloat?
    }

    public static func ods(_ data: Data) throws -> [PreviewSheet] {
        let zip = try ZipArchive(data: data)
        func xml(_ path: String) -> XMLElement? {
            guard let d = zip[path] else { return nil }
            return (try? XMLDocument(data: d, options: [.nodePreserveWhitespace]))?.rootElement()
        }
        guard let content = xml("content.xml"), let spreadsheet = content.child("body")?.child("spreadsheet") else { throw ZipError.corrupt }
        let stylesRoot = xml("styles.xml")
        var styles: [String: ODFStyle] = [:]
        for container in [stylesRoot?.child("styles"), stylesRoot?.child("automatic-styles"), content.child("automatic-styles")] {
            for s in container?.children("style") ?? [] {
                guard let name = s.attr("name") else { continue }
                var st = ODFStyle(parent: s.attr("parent-style-name"))
                if let t = s.child("text-properties") {
                    if let w = t.attr("font-weight") { st.bold = w == "bold" || (Int(w) ?? 400) >= 600 }
                    if let i = t.attr("font-style") { st.italic = i == "italic" || i == "oblique" }
                    st.color = color(t.attr("color"))
                }
                if let c = s.child("table-cell-properties") { st.background = color(c.attr("background-color")) }
                if let p = s.child("paragraph-properties"), let a = p.attr("text-align") {
                    st.align = a == "center" ? "center" : (a == "end" || a == "right") ? "right" : "left"
                }
                if let c = s.child("table-column-properties") { st.columnWidth = length(c.attr("column-width")) }
                styles[name] = st
            }
        }
        func resolved(_ name: String?) -> ODFStyle {
            var out = ODFStyle()
            var n = name, depth = 0
            while let key = n, let s = styles[key], depth < 8 {
                out.bold = out.bold ?? s.bold
                out.italic = out.italic ?? s.italic
                out.align = out.align ?? s.align
                out.background = out.background ?? s.background
                out.color = out.color ?? s.color
                n = s.parent; depth += 1
            }
            return out
        }

        var sheets: [PreviewSheet] = []
        for table in spreadsheet.children("table") {
            var sheet = PreviewSheet(name: table.attr("name") ?? "Sheet\(sheets.count + 1)")
            var col = 0
            var columnStyles: [Int: String] = [:]
            for c in descendants(table, "table-column") {
                let n = min(Int(c.attr("number-columns-repeated") ?? "1") ?? 1, maxColumns)
                for k in 0..<n where col + k < maxColumns {
                    if let w = c.attr("style-name").flatMap({ styles[$0]?.columnWidth }) { sheet.columnWidths[col + k] = w }
                    if c.attr("visibility") == "collapse" { sheet.columnWidths[col + k] = 0 }
                    if let d = c.attr("default-cell-style-name"), d != "Default" { columnStyles[col + k] = d }
                }
                col += n
            }
            var rows: [[PreviewCell]] = []
            var lastContentRow = -1
            for r in descendants(table, "table-row") {
                let repeatRows = Int(r.attr("number-rows-repeated") ?? "1") ?? 1
                var cells: [PreviewCell] = []
                var lastContentCol = -1
                var c = 0
                for case let x as XMLElement in r.children ?? [] where x.localName == "table-cell" || x.localName == "covered-table-cell" {
                    let repeatCols = Int(x.attr("number-columns-repeated") ?? "1") ?? 1
                    var cell = PreviewCell()
                    cell.covered = x.localName == "covered-table-cell"
                    cell.text = x.children("p").map(odfText).joined(separator: "\n")
                    let type = x.attr("value-type")
                    cell.numeric = ["float", "percentage", "currency", "date", "time"].contains(type ?? "")
                    if cell.text.isEmpty, let type, let v = x.attr(type == "date" ? "date-value" : type == "boolean" ? "boolean-value" : "value") { cell.text = v }
                    let st = resolved(x.attr("style-name") ?? r.attr("default-cell-style-name") ?? columnStyles[c])
                    cell.bold = st.bold ?? false
                    cell.italic = st.italic ?? false
                    cell.align = st.align
                    cell.background = st.background
                    cell.color = st.color
                    cell.colSpan = Int(x.attr("number-columns-spanned") ?? "1") ?? 1
                    cell.rowSpan = Int(x.attr("number-rows-spanned") ?? "1") ?? 1
                    let visible = !cell.text.isEmpty || cell.background != nil
                    for _ in 0..<min(repeatCols, max(0, maxColumns - c)) {
                        cells.append(cell)
                        if visible || cell.covered && lastContentCol >= 0 { lastContentCol = cells.count - 1 }
                    }
                    c += repeatCols
                    if c >= maxColumns { break }
                }
                cells = Array(cells.prefix(lastContentCol + 1))
                if rows.count + (cells.isEmpty ? 0 : 1) > maxRows {
                    if !cells.isEmpty { sheet.truncatedRows = true; break }
                    continue
                }
                for _ in 0..<min(repeatRows, maxRows - rows.count) { rows.append(cells) }
                if !cells.isEmpty { lastContentRow = rows.count - 1 }
            }
            sheet.rows = Array(rows.prefix(lastContentRow + 1))
            sheets.append(sheet)
        }
        return sheets
    }

    /// Rows and columns may sit inside header/group wrappers.
    static func descendants(_ e: XMLElement, _ name: String) -> [XMLElement] {
        var out: [XMLElement] = []
        for case let c as XMLElement in e.children ?? [] {
            if c.localName == name { out.append(c) }
            else if c.localName != "table-cell" && c.localName != "table-row" && c.localName != "shapes" { out += descendants(c, name) }
        }
        return out
    }

    /// Text of an ODF paragraph: spans, <text:s>, tabs and line breaks.
    static func odfText(_ e: XMLElement) -> String {
        var out = ""
        for node in e.children ?? [] {
            if node.kind == .text { out += node.stringValue ?? ""; continue }
            guard let x = node as? XMLElement else { continue }
            switch x.localName {
            case "s": out += String(repeating: " ", count: Int(x.attr("c") ?? "1") ?? 1)
            case "tab": out += "\t"
            case "line-break": out += "\n"
            case "annotation", "note": break
            default: out += odfText(x)
            }
        }
        return out
    }

    static func color(_ s: String?) -> NSColor? {
        guard let s, s.hasPrefix("#"), s.count == 7, let v = Int(s.dropFirst(), radix: 16) else { return nil }
        return NSColor(srgbRed: CGFloat(v >> 16 & 0xFF) / 255, green: CGFloat(v >> 8 & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }

    /// "2.258cm", "0.889in", "64pt", "20mm" → points.
    static func length(_ s: String?) -> CGFloat? {
        guard let s else { return nil }
        let units: [(String, CGFloat)] = [("cm", 72 / 2.54), ("mm", 72 / 25.4), ("in", 72), ("pt", 1), ("pc", 12), ("px", 0.75)]
        for (u, f) in units where s.hasSuffix(u) { return Double(s.dropLast(u.count)).map { CGFloat($0) * f } }
        return nil
    }
}
