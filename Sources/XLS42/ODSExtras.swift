import Foundation
import CryptoKit
import Kit42

/// ODS parts for data validation (table:content-validation), outline groups and sheet protection.
extension ODS {
    static let sha256Digest = "http://www.w3.org/2001/04/xmlenc#sha256"
    static let sha1Digest = "http://www.w3.org/2000/09/xmldsig#sha1"

    /// Splits "a;b;c" at top-level ";" (outside quotes and brackets/parentheses).
    static func splitArguments(_ s: String) -> [String] {
        var out: [String] = [], cur = "", depth = 0, quoted = false
        for ch in s {
            if ch == "\"" { quoted.toggle() }
            if !quoted {
                if ch == "(" || ch == "[" { depth += 1 } else if ch == ")" || ch == "]" { depth -= 1 }
                if ch == ";" && depth == 0 { out.append(cur); cur = ""; continue }
            }
            cur.append(ch)
        }
        out.append(cur)
        return out.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// OpenFormula operand → Excel formula text without "=".
    private static func excelOperand(_ s: String) -> String { String(excelFormula("=" + s).dropFirst()) }

    /// Excel formula text (no "=") → OpenFormula operand.
    private static func odfOperand(_ s: String) -> String {
        guard let e = try? Formula.parse("=" + s) else { return s }
        return odfFormula(e)
    }

    /// `table:condition` text of a rule.
    static func condition(_ v: DataValidation) -> String {
        let a = odfOperand(v.formula1), b = odfOperand(v.formula2)
        func comparison(_ subject: String, between: String) -> String {
            switch v.op {
            case "between": return "\(between)-is-between(\(a);\(b))"
            case "notBetween": return "\(between)-is-not-between(\(a);\(b))"
            default:
                let ops = ["equal": "=", "notEqual": "!=", "greaterThan": ">", "lessThan": "<", "greaterThanOrEqual": ">=", "lessThanOrEqual": "<="]
                return "\(subject)\(ops[v.op] ?? "=")\(a)"
            }
        }
        switch v.kind {
        case .list:
            let f = v.formula1
            if f.hasPrefix("\""), f.hasSuffix("\""), f.count >= 2 {
                let items = f.dropFirst().dropLast().replacingOccurrences(of: "\"\"", with: "\"").split(separator: ",", omittingEmptySubsequences: false)
                return "of:cell-content-is-in-list(" + items.map { "\"" + $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(separator: ";") + ")"
            }
            return "of:cell-content-is-in-list(\(a))"
        case .textLength: return "of:" + comparison("cell-content-text-length()", between: "cell-content-text-length")
        case .custom: return "of:is-true-formula(\(a))"
        default:
            let test = ["whole": "cell-content-is-whole-number()", "decimal": "cell-content-is-decimal-number()",
                        "date": "cell-content-is-date()", "time": "cell-content-is-time()"][v.kind.rawValue]!
            return "of:\(test) and " + comparison("cell-content()", between: "cell-content")
        }
    }

    /// Rule from a `table:condition` (ranges are added from the cells that use it).
    static func validation(condition raw: String) -> DataValidation? {
        var c = raw
        for prefix in ["of:", "oooc:", "msoxl:"] where c.hasPrefix(prefix) { c.removeFirst(prefix.count) }
        func args(after marker: String) -> [String]? {
            guard let r = c.range(of: marker + "(") else { return nil }
            var depth = 1, end = r.upperBound, quoted = false
            while end < c.endIndex {
                let ch = c[end]
                if ch == "\"" { quoted.toggle() }
                if !quoted { if ch == "(" { depth += 1 } else if ch == ")" { depth -= 1; if depth == 0 { break } } }
                end = c.index(after: end)
            }
            return splitArguments(String(c[r.upperBound..<end]))
        }
        if let items = args(after: "cell-content-is-in-list") {
            var v = DataValidation(ranges: [], kind: .list)
            if items.first?.hasPrefix("\"") == true {
                let texts = items.map { s -> String in
                    var t = s
                    if t.hasPrefix("\""), t.hasSuffix("\""), t.count >= 2 { t = String(t.dropFirst().dropLast()) }
                    return t.replacingOccurrences(of: "\"\"", with: "\"")
                }
                v.formula1 = "\"" + texts.joined(separator: ",").replacingOccurrences(of: "\"", with: "\"\"") + "\""
            } else {
                v.formula1 = excelOperand(items.first ?? "")
            }
            return v
        }
        if let f = args(after: "is-true-formula") {
            var v = DataValidation(ranges: [], kind: .custom)
            v.formula1 = excelOperand(f.first ?? "")
            return v
        }
        let kind: DataValidation.Kind
        if c.contains("text-length") { kind = .textLength }
        else if c.contains("is-whole-number") { kind = .whole }
        else if c.contains("is-decimal-number") { kind = .decimal }
        else if c.contains("is-date") { kind = .date }
        else if c.contains("is-time") { kind = .time }
        else { return nil }
        var v = DataValidation(ranges: [], kind: kind)
        if let b = args(after: "is-not-between") {
            v.op = "notBetween"
            v.formula1 = excelOperand(b.first ?? "")
            v.formula2 = excelOperand(b.count > 1 ? b[1] : "")
        } else if let b = args(after: "is-between") {
            v.op = "between"
            v.formula1 = excelOperand(b.first ?? "")
            v.formula2 = excelOperand(b.count > 1 ? b[1] : "")
        } else if let m = c.range(of: "(cell-content|cell-content-text-length)\\(\\)\\s*(<=|>=|!=|<>|=|<|>)\\s*(.+)$", options: .regularExpression) {
            let tail = String(c[m])
            guard let opRange = tail.range(of: "(<=|>=|!=|<>|=|<|>)", options: .regularExpression) else { return nil }
            let ops = ["=": "equal", "!=": "notEqual", "<>": "notEqual", ">": "greaterThan", "<": "lessThan", ">=": "greaterThanOrEqual", "<=": "lessThanOrEqual"]
            v.op = ops[String(tail[opRange])] ?? "equal"
            v.formula1 = excelOperand(String(tail[opRange.upperBound...]).trimmingCharacters(in: .whitespaces))
        } else { return nil }
        return v
    }

    /// `<table:content-validation>` element.
    static func validationXML(_ v: DataValidation, name: String, sheet: String) -> String {
        var x = "<table:content-validation table:name=\"\(name)\" table:condition=\"\(xmlEscape(condition(v)))\""
        x += " table:allow-empty-cell=\"\(v.allowBlank)\" table:base-cell-address=\"\(xmlEscape(odfRef(sheet, RefPart(row: v.anchor.row, col: v.anchor.col), nil, absoluteSheet: true)))\""
        if v.kind == .list { x += " table:display-list=\"\(v.showDropdown ? "unsorted" : "no")\"" }
        x += "><table:error-message table:message-type=\"\(v.errorStyle == "information" ? "information" : v.errorStyle == "warning" ? "warning" : "stop")\" table:display=\"true\""
        if !v.errorTitle.isEmpty { x += " table:title=\"\(xmlEscape(v.errorTitle))\"" }
        x += ">"
        if !v.errorMessage.isEmpty { x += v.errorMessage.split(separator: "\n").map { "<text:p>\(xmlEscape(String($0)))</text:p>" }.joined() }
        return x + "</table:error-message></table:content-validation>"
    }

    /// Reads `<table:content-validations>`: name → rule (without ranges).
    static func readValidations(_ spreadsheet: XMLElement) -> [String: DataValidation] {
        var out: [String: DataValidation] = [:]
        for e in spreadsheet.child("content-validations")?.children("content-validation") ?? [] {
            guard let name = e.attr("name"), let cond = e.attr("condition"), var v = validation(condition: cond) else { continue }
            v.allowBlank = e.attr("allow-empty-cell") != "false"
            v.showDropdown = e.attr("display-list") != "no"
            if let msg = e.child("error-message") {
                v.errorStyle = msg.attr("message-type") ?? "stop"
                v.errorTitle = msg.attr("title") ?? ""
                v.errorMessage = msg.children("p").map(\.allTextODF).joined(separator: "\n")
            }
            out[name] = v
        }
        return out
    }

    /// Cells → rectangles: contiguous rows per column, then neighbouring columns with equal runs merged.
    static func ranges(_ refs: [CellRef]) -> [CellRange] {
        var runs: [CellRange] = []
        for (col, cells) in Dictionary(grouping: refs, by: \.col).sorted(by: { $0.key < $1.key }) {
            for r in cells.map(\.row).sorted() {
                if let i = runs.lastIndex(where: { $0.start.col == col && $0.end.col == col }), runs[i].end.row + 1 == r {
                    runs[i].end.row = r
                } else if runs.last(where: { $0.start.col == col })?.rows.contains(r) != true {
                    runs.append(CellRange(CellRef(row: r, col: col), CellRef(row: r, col: col)))
                }
            }
        }
        var merged: [CellRange] = []
        for r in runs {
            if let i = merged.firstIndex(where: { $0.end.col + 1 == r.start.col && $0.start.row == r.start.row && $0.end.row == r.end.row }) {
                merged[i].end.col = r.end.col
            } else { merged.append(r) }
        }
        return merged
    }

    /// Protection key for new passwords (LibreOffice's default digest).
    static func protectionKey(_ password: String) -> String {
        Data(SHA256.hash(data: Data(password.utf8))).base64EncodedString()
    }

    /// Rows (or columns) under `e` with their group depth: table-row-group / table-column-group nest them.
    static func outlined(_ e: XMLElement, _ name: String, group: String, level: Int = 0) -> [(XMLElement, Int)] {
        var out: [(XMLElement, Int)] = []
        for case let c as XMLElement in e.children ?? [] {
            if c.localName == name { out.append((c, level)) }
            else if c.localName == group { out += outlined(c, name, group: group, level: level + 1) }
            else if c.localName != "table-cell" && c.localName != "table-row" { out += outlined(c, name, group: group, level: level) }
        }
        return out
    }

    /// Opening/closing group tags so that rows (columns) at `index` sit at their outline level.
    static func groupTags(_ sheet: Sheet, _ index: Int, rows: Bool, open: inout Int) -> String {
        let element = rows ? "table:table-row-group" : "table:table-column-group"
        let level = sheet.level(index, rows: rows)
        var x = ""
        while open > level { x += "</\(element)>"; open -= 1 }
        while open < level {
            open += 1
            let group = sheet.outlineGroups(rows: rows, level: open).first { $0.contains(index) } ?? index...index
            x += "<\(element)\(sheet.isCollapsed(group, rows: rows) ? " table:display=\"false\"" : "")>"
        }
        return x
    }
}
