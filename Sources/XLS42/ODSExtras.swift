import Foundation
import CryptoKit
import Kit42

/// ODS parts for data validation (table:content-validation), outline groups and sheet protection.
extension ODS {
    static let sha256Digest = "http://www.w3.org/2001/04/xmlenc#sha256"
    static let sha1Digest = "http://www.w3.org/2000/09/xmldsig#sha1"
    static let legacyExcelDigest = "http://docs.oasis-open.org/office/ns/table/legacy-hash-excel"

    /// LibreOffice's key for an Excel legacy hash: SHA-1 of the hash's two bytes (big-endian), base64.
    static func legacyProtectionKey(_ hash: String) -> String? {
        guard let v = UInt16(hash, radix: 16) else { return nil }
        return Data(Insecure.SHA1.hash(data: Data([UInt8(v >> 8), UInt8(v & 0xFF)]))).base64EncodedString()
    }

    /// Splits "a;b;c" (or "a,b") at top-level separators (outside quotes and brackets/parentheses).
    static func splitArguments(_ s: String) -> [String] {
        var out: [String] = [], cur = "", depth = 0, quoted = false
        for ch in s {
            if ch == "\"" { quoted.toggle() }
            if !quoted {
                if ch == "(" || ch == "[" { depth += 1 } else if ch == ")" || ch == "]" { depth -= 1 }
                if (ch == ";" || ch == ",") && depth == 0 { out.append(cur); cur = ""; continue }
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
            case "between": return "\(between)-is-between(\(a),\(b))"
            case "notBetween": return "\(between)-is-not-between(\(a),\(b))"
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
            return "of:\(test) and " + comparison("cell-content()", between: "cell-content")   // as LibreOffice writes it
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

    // MARK: - AutoFilter (database ranges with filter conditions)

    static let odfOperators: [FilterCondition.Op: String] = [
        .equal: "=", .notEqual: "!=", .greaterThan: ">", .lessThan: "<", .greaterThanOrEqual: ">=", .lessThanOrEqual: "<=",
        .contains: "contains", .notContains: "does-not-contain", .beginsWith: "begins-with", .endsWith: "ends-with",
        .top: "top values", .bottom: "bottom values", .topPercent: "top percent", .bottomPercent: "bottom percent",
        .empty: "empty", .notEmpty: "!empty",
    ]

    /// table:database-ranges for the AutoFilter of each sheet (value lists and conditions).
    static func databaseRangesXML(_ wb: Workbook) -> String {
        var x = ""
        for (si, sheet) in wb.sheets.enumerated() {
            guard let f = sheet.autoFilter else { continue }
            x += "<table:database-range table:name=\"__Anonymous_Sheet_DB__\(si)\" table:target-range-address=\"\(xmlEscape(odfRange(sheet.name, f)))\" table:display-filter-buttons=\"true\">"
            var items: [String] = []
            func condition(_ field: Int, _ c: FilterCondition) -> String {
                let numeric = Double(c.value.replacingOccurrences(of: ",", with: ".")) != nil
                return "<table:filter-condition table:field-number=\"\(field)\" table:value=\"\(xmlEscape(c.value))\" table:operator=\"\(xmlEscape(odfOperators[c.op] ?? "="))\" table:data-type=\"\(numeric ? "number" : "text")\"/>"
            }
            for (col, cf) in sheet.customFilters.sorted(by: { $0.key < $1.key }) where f.cols.contains(col) {
                let parts = cf.conditions.map { condition(col - f.start.col, $0) }
                items.append(cf.and || parts.count < 2 ? parts.joined() : "<table:filter-or>" + parts.joined() + "</table:filter-or>")
            }
            for (col, values) in sheet.filterValues.sorted(by: { $0.key < $1.key }) where f.cols.contains(col) && sheet.customFilters[col] == nil {
                let sorted = values.sorted()
                items.append("<table:filter-condition table:field-number=\"\(col - f.start.col)\" table:value=\"\(xmlEscape(sorted.first ?? ""))\" table:operator=\"=\">"
                             + sorted.map { "<table:filter-set-item table:value=\"\(xmlEscape($0))\"/>" }.joined() + "</table:filter-condition>")
            }
            if !items.isEmpty { x += "<table:filter><table:filter-and>" + items.joined() + "</table:filter-and></table:filter>" }
            x += "</table:database-range>"
        }
        return x.isEmpty ? "" : "<table:database-ranges>" + x + "</table:database-ranges>"
    }

    static func readDatabaseRanges(_ spreadsheet: XMLElement, _ wb: inout Workbook) {
        for db in spreadsheet.child("database-ranges")?.children("database-range") ?? [] {
            guard db.attr("display-filter-buttons") == "true" || db.child("filter") != nil,
                  let addr = db.attr("target-range-address"), let r = rangeFromODF(addr),
                  let range = CellRange(r.range.replacingOccurrences(of: "$", with: "")) else { continue }
            guard let si = r.sheet.flatMap({ wb.sheetIndex(named: $0) }) else { continue }
            wb.sheets[si].autoFilter = range
            var reverse = Dictionary(odfOperators.map { ($0.value, $0.key) }, uniquingKeysWith: { a, _ in a })
            reverse["!contains"] = .notContains; reverse["begins"] = .beginsWith; reverse["ends"] = .endsWith
            func parse(_ c: XMLElement) -> (Int, FilterCondition, [String])? {
                guard let field = c.attr("field-number").flatMap(Int.init) else { return nil }
                let op = reverse[(c.attr("operator") ?? "=").lowercased()] ?? .equal
                let set = c.children("filter-set-item").compactMap { $0.attr("value") }
                return (range.start.col + field, FilterCondition(op: op, value: c.attr("value") ?? ""), set)
            }
            guard let and = db.child("filter")?.child("filter-and") ?? db.child("filter") else { continue }
            for e in (and.children ?? []).compactMap({ $0 as? XMLElement }) {
                if e.localName == "filter-condition", let (col, cond, set) = parse(e) {
                    if set.count > 1 || (cond.op == .equal && !set.isEmpty) { wb.sheets[si].filterValues[col] = Set(set) }
                    else { wb.sheets[si].customFilters[col, default: ColumnFilter(conditions: [])].conditions.append(cond) }
                } else if e.localName == "filter-or" {
                    let parts = e.children("filter-condition").compactMap(parse)
                    if let col = parts.first?.0 { wb.sheets[si].customFilters[col] = ColumnFilter(conditions: parts.map(\.1), and: false) }
                }
            }
        }
    }
}
