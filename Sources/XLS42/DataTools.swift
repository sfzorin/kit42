import AppKit
import Kit42

/// Data commands on the workbook model (no UI): sorting, standard/advanced filters, subtotals,
/// duplicates, text to columns, series, goal seek. The dialogs in DataDialogs.swift call these.
enum DataTools {
    // MARK: - Rows and columns

    /// Inserts (count > 0) or deletes (count < 0) rows/columns at `index`, moving everything after it
    /// and adjusting formulas in every sheet.
    static func shiftCells(_ wb: inout Workbook, sheet sheetIndex: Int, rows: Bool, at index: Int, count: Int) {
        let sheetName = wb.sheets[sheetIndex].name
        var s = wb.sheets[sheetIndex]
        func moved(_ v: Int) -> Int? {
            if count > 0 { return v >= index ? v + count : v }
            if v >= index && v < index - count { return nil }
            return v >= index - count ? v + count : v
        }
        func movedRef(_ r: CellRef) -> CellRef? {
            guard let v = moved(rows ? r.row : r.col) else { return nil }
            return rows ? CellRef(row: v, col: r.col) : CellRef(row: r.row, col: v)
        }
        var cells: [CellRef: Cell] = [:]
        for (ref, cell) in s.cells { if let to = movedRef(ref) { cells[to] = cell } }
        s.cells = cells
        s.comments = Dictionary(uniqueKeysWithValues: s.comments.compactMap { k, v in movedRef(k).map { ($0, v) } })
        s.hyperlinks = Dictionary(uniqueKeysWithValues: s.hyperlinks.compactMap { k, v in movedRef(k).map { ($0, v) } })
        if rows {
            s.rowHeights = Dictionary(uniqueKeysWithValues: s.rowHeights.compactMap { k, v in moved(k).map { ($0, v) } })
            s.rowLevels = Dictionary(uniqueKeysWithValues: s.rowLevels.compactMap { k, v in moved(k).map { ($0, v) } })
            s.outlineHiddenRows = Set(s.outlineHiddenRows.compactMap(moved))
            s.filterHidden = Set(s.filterHidden.compactMap(moved))
            s.rowBreaks = Set(s.rowBreaks.compactMap(moved))
        } else {
            s.columnWidths = Dictionary(uniqueKeysWithValues: s.columnWidths.compactMap { k, v in moved(k).map { ($0, v) } })
            s.colLevels = Dictionary(uniqueKeysWithValues: s.colLevels.compactMap { k, v in moved(k).map { ($0, v) } })
            s.outlineHiddenCols = Set(s.outlineHiddenCols.compactMap(moved))
        }
        func movedRange(_ m: CellRange) -> CellRange? {
            let a = rows ? m.start.row : m.start.col, b = rows ? m.end.row : m.end.col
            guard let na = moved(a) ?? (count < 0 ? index : nil), let nb = moved(b) ?? (count < 0 ? index - 1 : nil), nb >= na else { return nil }
            return rows ? CellRange(CellRef(row: na, col: m.start.col), CellRef(row: nb, col: m.end.col))
                        : CellRange(CellRef(row: m.start.row, col: na), CellRef(row: m.end.row, col: nb))
        }
        s.merges = s.merges.compactMap { m in movedRange(m).flatMap { $0.count > 1 ? $0 : nil } }
        s.validations = s.validations.compactMap { v in
            var v = v
            v.ranges = v.ranges.compactMap(movedRange)
            return v.ranges.isEmpty ? nil : v
        }
        s.conditionalFormats = s.conditionalFormats.compactMap { c in
            var c = c
            guard let r = movedRange(c.range) else { return nil }
            c.range = r
            return c
        }
        if let f = s.autoFilter { s.autoFilter = movedRange(f) }
        if let p = s.printArea { s.printArea = movedRange(p) }
        s.arrays = Dictionary(uniqueKeysWithValues: s.arrays.compactMap { k, v in movedRef(k).flatMap { a in movedRange(v).map { (a, $0) } } })
        if let m = s.solver {
            // The Solver model follows its cells (dropped with its objective cell).
            if let objective = movedRef(m.objective) {
                var n = m
                n.objective = objective
                n.variables = m.variables.compactMap(movedRef)
                n.constraints = m.constraints.compactMap { c in
                    guard let lhs = movedRange(c.lhs) else { return nil }
                    var c = c
                    c.lhs = lhs
                    if CellRange(c.rhs.replacingOccurrences(of: "$", with: "")) != nil {
                        c.rhs = String(Formula.adjusted("=" + c.rhs, sheet: sheetName, formulaSheet: sheetName, rows: rows, at: index, count: count).dropFirst())
                    }
                    return c
                }
                s.solver = n
            } else { s.solver = nil }
        }
        wb.sheets[sheetIndex] = s
        for si in wb.sheets.indices {
            let formulaSheet = wb.sheets[si].name
            for (ref, cell) in wb.sheets[si].cells where cell.isFormula {
                wb.sheets[si].cells[ref]?.input = Formula.adjusted(cell.input, sheet: sheetName, formulaSheet: formulaSheet,
                                                                   rows: rows, at: index, count: count)
            }
        }
    }

    // MARK: - Sorting

    struct SortKey: Equatable {
        /// Column (top to bottom) or row (left to right) on the sheet.
        var index: Int
        var ascending = true
    }

    struct SortOptions: Equatable {
        var header = true
        var caseSensitive = false
        var natural = false
        var leftToRight = false
        /// Values in this order sort first (weekdays, months, a user list).
        var customList: [String]?
    }

    /// Built-in custom sort orders (like Calc's sort lists), English and the interface language.
    static var builtinLists: [[String]] {
        var lists: [[String]] = [
            ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"],
            ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"],
            ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"],
            ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"],
        ]
        let f = DateFormatter()
        f.locale = Locale.current
        if !(f.locale.language.languageCode?.identifier ?? "en").hasPrefix("en") {
            lists += [f.shortWeekdaySymbols, f.weekdaySymbols, f.shortStandaloneMonthSymbols, f.standaloneMonthSymbols].map { $0.map { $0.replacingOccurrences(of: ".", with: "") } }
        }
        return lists
    }

    /// User sort lists (Data › Sort Lists…), one comma-separated list per entry.
    static var userLists: [[String]] {
        get { (UserDefaults.standard.stringArray(forKey: "xls.sortLists") ?? []).map { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } } }
        set { UserDefaults.standard.set(newValue.map { $0.joined(separator: ", ") }, forKey: "xls.sortLists") }
    }

    /// Order of two values: numbers before text before logical values, blanks always last.
    static func sortCompare(_ a: Value, _ b: Value, _ o: SortOptions, calc: Calculator) -> Int {
        let ea = a.isEmpty || a == .string(""), eb = b.isEmpty || b == .string("")
        if ea != eb { return ea ? 2 : -2 }   // ±2: blanks stay last in both directions
        if ea { return 0 }
        if let list = o.customList {
            func pos(_ v: Value) -> Int? {
                let t = calc.text(v)
                return list.firstIndex { $0.compare(t, options: .caseInsensitive) == .orderedSame }
            }
            switch (pos(a), pos(b)) {
            case let (x?, y?): return x < y ? -1 : x > y ? 1 : 0
            case (_?, nil): return -1
            case (nil, _?): return 1
            default: break
            }
        }
        if case .string(let x) = a, case .string(let y) = b {
            var options: String.CompareOptions = o.caseSensitive ? [] : [.caseInsensitive]
            if o.natural { options.insert(.numeric) }
            var r = x.compare(y, options: options, range: nil, locale: Locale.current)
            if r == .orderedSame, o.caseSensitive, x != y {
                // Same letters: lower case first (as in Calc).
                r = x.compare(y, options: [], range: nil, locale: Locale(identifier: "en_US_POSIX")) == .orderedAscending ? .orderedDescending : .orderedAscending
            }
            return r == .orderedAscending ? -1 : r == .orderedSame ? 0 : 1
        }
        return calc.compare(a, b)
    }

    /// Whether the first row (or column) of a range looks like labels: text over at least one numeric column.
    static func detectHeader(_ s: Sheet, _ range: CellRange, leftToRight: Bool = false) -> Bool {
        guard leftToRight ? range.cols.count > 1 : range.rows.count > 1 else { return false }
        let firstLine = leftToRight ? range.rows.map { CellRef(row: $0, col: range.start.col) } : range.cols.map { CellRef(row: range.start.row, col: $0) }
        let secondLine = leftToRight ? range.rows.map { CellRef(row: $0, col: range.start.col + 1) } : range.cols.map { CellRef(row: range.start.row + 1, col: $0) }
        let firstText = firstLine.allSatisfy { r in
            if case .number = s[r].value { return false }
            return !s[r].value.isEmpty
        }
        guard firstText else { return false }
        // Labels when the data below isn't all text, or the first row is styled differently (bold).
        let below = zip(firstLine, secondLine).contains { a, b in
            if case .number = s[b].value { return true }
            return s[a].style.bold != s[b].style.bold
        }
        return below || firstLine.contains { s[$0].style.bold }
    }

    /// Sorts the cells of `range` (rows, or columns when left to right) by the keys. Formulas keep their
    /// relative references consistent (a moved formula refers to the same relative cells, as in Calc).
    static func sort(_ wb: inout Workbook, sheet si: Int, range: CellRange, keys: [SortKey], options: SortOptions) {
        guard !keys.isEmpty else { return }
        let s = wb.sheets[si]
        let calc = Calculator(wb)
        let lines = options.leftToRight ? Array(range.cols.dropFirst(options.header ? 1 : 0)) : Array(range.rows.dropFirst(options.header ? 1 : 0))
        guard lines.count > 1 else { return }
        func value(_ line: Int, _ key: Int) -> Value {
            options.leftToRight ? s[CellRef(row: key, col: line)].value : s[CellRef(row: line, col: key)].value
        }
        let order = lines.enumerated().sorted { p, q in
            for k in keys {
                let c = sortCompare(value(p.element, k.index), value(q.element, k.index), options, calc: calc)
                if c == 0 { continue }
                if abs(c) == 2 { return c < 0 }
                return k.ascending ? c < 0 : c > 0
            }
            return p.offset < q.offset
        }.map(\.element)
        let original = wb.sheets[si]
        for (i, from) in order.enumerated() {
            let to = lines[i]
            guard to != from else { continue }
            let span = options.leftToRight ? Array(range.rows) : Array(range.cols)
            for other in span {
                let src = options.leftToRight ? CellRef(row: other, col: from) : CellRef(row: from, col: other)
                let dst = options.leftToRight ? CellRef(row: other, col: to) : CellRef(row: to, col: other)
                var cell = original[src]
                if cell.isFormula {
                    cell.input = options.leftToRight ? Formula.shifted(cell.input, rows: 0, cols: to - from) : Formula.shifted(cell.input, rows: to - from, cols: 0)
                }
                if cell.input.isEmpty, !cell.value.isEmpty { cell.value = .empty }   // spilled values recompute
                wb.sheets[si][dst] = cell
                if let c = original.comments[src] { wb.sheets[si].comments[dst] = c } else { wb.sheets[si].comments[dst] = nil }
                if let h = original.hyperlinks[src] { wb.sheets[si].hyperlinks[dst] = h } else { wb.sheets[si].hyperlinks[dst] = nil }
            }
        }
    }

    // MARK: - Filters

    /// Whether a value meets a filter condition. `column` (all values of the column) is needed for top/bottom N.
    static func matches(_ v: Value, _ c: FilterCondition, caseSensitive: Bool, column: [Value], calc: Calculator, format: String = "General") -> Bool {
        let blank = v.isEmpty || v == .string("")
        switch c.op {
        case .empty: return blank
        case .notEmpty: return !blank
        case .top, .bottom, .topPercent, .bottomPercent:
            guard case .number(let d) = v, let n = Double(c.value.replacingOccurrences(of: ",", with: ".")), n.isFinite, n > 0 else { return false }
            let nums = column.compactMap { x -> Double? in if case .number(let d) = x { return d }; return nil }.sorted(by: c.op == .top || c.op == .topPercent ? (>) : (<))
            guard !nums.isEmpty else { return false }
            let k = c.op == .top || c.op == .bottom ? Int(min(Double(nums.count), n)) : max(1, Int(Double(nums.count) * min(100, n) / 100))
            let threshold = nums[min(nums.count, max(1, k)) - 1]
            return c.op == .top || c.op == .topPercent ? d >= threshold : d <= threshold
        default: break
        }
        let display = NumberFormat.format(v, format, date1904: calc.workbook.date1904).text
        let text = caseSensitive ? display : display.lowercased()
        let needle = caseSensitive ? c.value : c.value.lowercased()
        switch c.op {
        case .contains: return text.contains(needle)
        case .notContains: return !text.contains(needle)
        case .beginsWith: return text.hasPrefix(needle)
        case .endsWith: return text.hasSuffix(needle)
        default: break
        }
        // Comparisons: numbers numerically (dates typed as dates too), text alphabetically; = and <> allow * and ?.
        let operand: Value = XLSX.constant(c.value, date1904: calc.workbook.date1904)
        if c.op == .equal || c.op == .notEqual {
            var eq: Bool
            if case .string(let p) = operand, p.contains(where: { "*?".contains($0) }) {
                eq = calc.criterion(.string(p))(v)
            } else if case .number(let a) = v, case .number(let b) = operand {
                eq = abs(a - b) < 1e-9 * max(1, abs(a))
            } else if case .string = operand {
                eq = caseSensitive ? display == c.value || calc.text(v) == c.value
                                   : display.caseInsensitiveCompare(c.value) == .orderedSame || calc.text(v).caseInsensitiveCompare(c.value) == .orderedSame
            } else {
                eq = calc.compare(v, operand) == 0 && !blank
            }
            if c.value.isEmpty { eq = blank }
            return c.op == .equal ? eq : !eq
        }
        guard !blank else { return false }
        if case .number = operand, case .string = v { return false }
        if case .string = operand, case .number = v { return false }
        let r = calc.compare(v, operand)
        switch c.op {
        case .greaterThan: return r > 0
        case .lessThan: return r < 0
        case .greaterThanOrEqual: return r >= 0
        case .lessThanOrEqual: return r <= 0
        default: return false
        }
    }

    static func matches(_ v: Value, _ f: ColumnFilter, column: [Value], calc: Calculator, format: String) -> Bool {
        let results = f.conditions.map { matches(v, $0, caseSensitive: false, column: column, calc: calc, format: format) }
        return f.and ? results.allSatisfy { $0 } : results.contains(true)
    }

    /// Hides the rows of the AutoFilter range that fail any column's value list or conditions.
    static func refilter(_ s: inout Sheet, workbook: Workbook) {
        s.filterHidden = []
        guard let f = s.autoFilter, f.end.row > f.start.row else { return }
        let calc = Calculator(workbook)
        let rows = (f.start.row + 1)...f.end.row
        var columns: [Int: [Value]] = [:]
        for col in s.customFilters.keys { columns[col] = rows.map { s[CellRef(row: $0, col: col)].value } }
        for r in rows {
            for (col, values) in s.filterValues {
                let c = s[CellRef(row: r, col: col)]
                if !values.contains(NumberFormat.format(c.value, c.style.numberFormat, date1904: workbook.date1904).text) { s.filterHidden.insert(r); break }
            }
            if s.filterHidden.contains(r) { continue }
            for (col, filter) in s.customFilters {
                let c = s[CellRef(row: r, col: col)]
                if !matches(c.value, filter, column: columns[col] ?? [], calc: calc, format: c.style.numberFormat) { s.filterHidden.insert(r); break }
            }
        }
    }

    /// One row of the Standard Filter dialog: field (sheet column), condition, joined to the previous row by OR.
    struct Criterion: Equatable {
        var field: Int
        var condition: FilterCondition
        var or = false
    }

    /// Rows of `range` (below the header) meeting the criteria; AND binds tighter than OR.
    static func passingRows(_ s: Sheet, range: CellRange, criteria: [Criterion], caseSensitive: Bool, header: Bool, calc: Calculator) -> [Int] {
        let rows = Array(range.rows.dropFirst(header ? 1 : 0))
        var columns: [Int: [Value]] = [:]
        for c in criteria { columns[c.field] = rows.map { s[CellRef(row: $0, col: c.field)].value } }
        return rows.filter { r in
            guard !criteria.isEmpty else { return true }
            var anyGroup = false, group = true
            for (i, c) in criteria.enumerated() {
                if i > 0, c.or { anyGroup = anyGroup || group; group = true }
                let cell = s[CellRef(row: r, col: c.field)]
                group = group && matches(cell.value, c.condition, caseSensitive: caseSensitive, column: columns[c.field] ?? [], calc: calc, format: cell.style.numberFormat)
            }
            return anyGroup || group
        }
    }

    /// Removes rows whose cells (in the range's columns) repeat an earlier row.
    static func uniqueRows(_ s: Sheet, _ rows: [Int], cols: ClosedRange<Int>, date1904: Bool = false) -> [Int] {
        var seen = Set<[String]>()
        return rows.filter { r in
            seen.insert(cols.map { c in
                let cell = s[CellRef(row: r, col: c)]
                return NumberFormat.format(cell.value, cell.style.numberFormat, date1904: date1904).text.lowercased()
            }).inserted
        }
    }

    /// Copies the header and the given rows of `range` to `to` (values and formats).
    static func copyRows(_ wb: inout Workbook, from si: Int, range: CellRange, rows: [Int], header: Bool, to: (sheet: Int, ref: CellRef)) {
        let s = wb.sheets[si]
        let all = (header ? [range.start.row] : []) + rows
        // Clear the previous output below the destination (as tall as the source).
        for r in 0..<range.rows.count {
            for c in 0..<range.cols.count { wb.sheets[to.sheet][CellRef(row: to.ref.row + r, col: to.ref.col + c)] = Cell() }
        }
        for (i, r) in all.enumerated() {
            for (j, c) in range.cols.enumerated() {
                var cell = s[CellRef(row: r, col: c)]
                if cell.isFormula || cell.input.isEmpty {
                    cell.input = XLSX.inputText(for: cell.value, style: cell.style, date1904: wb.date1904)
                    cell.array = false
                }
                wb.sheets[to.sheet][CellRef(row: to.ref.row + i, col: to.ref.col + j)] = cell
            }
        }
    }

    /// Standard filter: hides the other rows, or copies the result to `copyTo`. Simple criteria
    /// (AND across columns, at most two conditions per column) are kept as AutoFilter conditions (saved to .xlsx).
    static func standardFilter(_ wb: inout Workbook, sheet si: Int, range: CellRange, criteria: [Criterion], caseSensitive: Bool,
                               unique: Bool, header: Bool, copyTo: (sheet: Int, ref: CellRef)?) {
        let calc = Calculator(wb)
        var rows = passingRows(wb.sheets[si], range: range, criteria: criteria, caseSensitive: caseSensitive, header: header, calc: calc)
        if unique { rows = uniqueRows(wb.sheets[si], rows, cols: range.cols, date1904: wb.date1904) }
        if let copyTo {
            copyRows(&wb, from: si, range: range, rows: rows, header: header, to: copyTo)
            return
        }
        var s = wb.sheets[si]
        s.autoFilter = range
        s.filterValues = [:]
        s.customFilters = [:]
        let byField = Dictionary(grouping: criteria, by: \.field)
        let simple = !criteria.enumerated().contains { i, c in i > 0 && c.or && criteria[i - 1].field != c.field }
            && byField.values.allSatisfy { $0.count <= 2 } && !caseSensitive && !unique
        if simple {
            for (field, cs) in byField {
                s.customFilters[field] = ColumnFilter(conditions: cs.map(\.condition), and: !(cs.count == 2 && cs[1].or))
            }
        }
        let kept = Set(rows)
        s.filterHidden = Set(range.rows.dropFirst(header ? 1 : 0).filter { !kept.contains($0) })
        wb.sheets[si] = s
    }

    /// Advanced filter with a criteria range: header names matching the list's, each row a set of AND conditions,
    /// rows joined by OR. Plain text means "begins with" (as in Excel); ">5", "<>x", "=abc", wildcards work.
    static func advancedFilter(_ wb: inout Workbook, sheet si: Int, list: CellRange, criteria: (sheet: Int, range: CellRange),
                               unique: Bool, copyTo: (sheet: Int, ref: CellRef)?) -> Bool {
        let calc = Calculator(wb)
        let s = wb.sheets[si], cs = wb.sheets[criteria.sheet]
        let headers = list.cols.map { calc.text(s[CellRef(row: list.start.row, col: $0)].value).lowercased() }
        var groups: [[(Int, (Value) -> Bool)]] = []
        for r in criteria.range.rows.dropFirst() {
            var group: [(Int, (Value) -> Bool)] = []
            for c in criteria.range.cols {
                let v = cs[CellRef(row: r, col: c)].value
                guard !v.isEmpty else { continue }
                let name = calc.text(cs[CellRef(row: criteria.range.start.row, col: c)].value).lowercased()
                guard let k = headers.firstIndex(of: name) else { return false }
                var crit = v
                if case .string(let t) = v, !t.hasPrefix("=") && !t.hasPrefix("<") && !t.hasPrefix(">") { crit = .string(t + "*") }
                if case .string(let t) = v, t.hasPrefix("="), !t.hasPrefix("=="), !t.dropFirst().hasPrefix(">"), !t.dropFirst().hasPrefix("<") { crit = .string(t) }
                group.append((list.start.col + k, calc.criterion(crit)))
            }
            if !group.isEmpty { groups.append(group) }
        }
        var rows = Array(list.rows.dropFirst()).filter { r in
            groups.isEmpty || groups.contains { g in g.allSatisfy { col, test in test(s[CellRef(row: r, col: col)].value) } }
        }
        if unique { rows = uniqueRows(s, rows, cols: list.cols, date1904: wb.date1904) }
        if let copyTo {
            copyRows(&wb, from: si, range: list, rows: rows, header: true, to: copyTo)
        } else {
            let kept = Set(rows)
            wb.sheets[si].autoFilter = list
            wb.sheets[si].filterValues = [:]
            wb.sheets[si].customFilters = [:]
            wb.sheets[si].filterHidden = Set(list.rows.dropFirst().filter { !kept.contains($0) })
        }
        return true
    }

    // MARK: - Subtotals

    /// SUBTOTAL function numbers in the dialog's order: sum, count, average, max, min, product, count numbers, stdev, stdevp, var, varp.
    static let subtotalFunctions: [(code: Int, name: String)] = [
        (9, "Sum"), (3, "Count"), (1, "Average"), (4, "Max"), (5, "Min"), (6, "Product"), (2, "Count Numbers"),
        (7, "StDev"), (8, "StDevP"), (10, "Var"), (11, "VarP"),
    ]

    static func isSubtotalRow(_ s: Sheet, _ r: Int, cols: ClosedRange<Int>) -> Bool {
        cols.contains { c in
            let cell = s[CellRef(row: r, col: c)]
            return cell.isFormula && cell.input.uppercased().contains("SUBTOTAL(")
        }
    }

    /// Removes subtotal rows (rows with SUBTOTAL formulas) and the outline of `range`. Returns the remaining range.
    @discardableResult
    static func removeSubtotals(_ wb: inout Workbook, sheet si: Int, range: CellRange) -> CellRange {
        var end = range.end.row
        for r in range.rows.reversed() where r > range.start.row && isSubtotalRow(wb.sheets[si], r, cols: range.cols) {
            shiftCells(&wb, sheet: si, rows: true, at: r, count: -1)
            end -= 1
        }
        for r in range.start.row...max(range.start.row, end) {
            wb.sheets[si].rowLevels[r] = nil
            wb.sheets[si].outlineHiddenRows.remove(r)
            wb.sheets[si].rowBreaks.remove(r)
        }
        return CellRange(range.start, CellRef(row: max(range.start.row, end), col: range.end.col))
    }

    /// Inserts a SUBTOTAL row after each group of equal values in `groupBy` (header in the first row),
    /// a grand total at the end, and outline levels (details 2, subtotals 1). Returns the new range.
    @discardableResult
    static func subtotals(_ wb: inout Workbook, sheet si: Int, range: CellRange, groupBy: Int, function: Int, columns: [Int],
                          replace: Bool, pageBreaks: Bool) -> CellRange {
        var range = range
        if replace { range = removeSubtotals(&wb, sheet: si, range: range) }
        guard range.rows.count > 1 else { return range }
        let first = range.start.row + 1
        func key(_ r: Int) -> String {
            let c = wb.sheets[si][CellRef(row: r, col: groupBy)]
            return NumberFormat.format(c.value, c.style.numberFormat, date1904: wb.date1904).text
        }
        // Groups as (first row, last row, label) before inserting anything.
        var groups: [(Int, Int, String)] = []
        var start = first
        for r in first...range.end.row where r == range.end.row || key(r + 1).lowercased() != key(r).lowercased() {
            groups.append((start, r, key(r)))
            start = r + 1
        }
        var offset = 0
        var totalRows: [Int] = []
        var detailRanges: [ClosedRange<Int>] = []
        for (a, b, label) in groups {
            let ga = a + offset, gb = b + offset
            let at = gb + 1
            shiftCells(&wb, sheet: si, rows: true, at: at, count: 1)
            offset += 1
            var labelCell = Cell()
            labelCell.input = L("%@ Total", label)
            labelCell.value = .string(labelCell.input)
            labelCell.style.bold = true
            wb.sheets[si][CellRef(row: at, col: groupBy)] = labelCell
            for c in columns {
                var cell = Cell()
                cell.input = "=SUBTOTAL(\(function),\(CellRange(CellRef(row: ga, col: c), CellRef(row: gb, col: c)).a1))"
                cell.style = wb.sheets[si][CellRef(row: gb, col: c)].style
                cell.style.bold = true
                wb.sheets[si][CellRef(row: at, col: c)] = cell
            }
            totalRows.append(at)
            detailRanges.append(ga...gb)
            if pageBreaks, (a, b, label) != groups.last! { wb.sheets[si].rowBreaks.insert(at + 1) }
        }
        let lastData = range.end.row + offset
        let grand = lastData + 1
        shiftCells(&wb, sheet: si, rows: true, at: grand, count: 1)
        var labelCell = Cell()
        labelCell.input = L("Grand Total")
        labelCell.value = .string(labelCell.input)
        labelCell.style.bold = true
        wb.sheets[si][CellRef(row: grand, col: groupBy)] = labelCell
        for c in columns {
            var cell = Cell()
            cell.input = "=SUBTOTAL(\(function),\(CellRange(CellRef(row: first, col: c), CellRef(row: lastData, col: c)).a1))"
            cell.style = wb.sheets[si][CellRef(row: lastData, col: c)].style
            cell.style.bold = true
            wb.sheets[si][CellRef(row: grand, col: c)] = cell
        }
        for r in detailRanges { wb.sheets[si].changeOutline(r, rows: true, by: 2) }
        for r in totalRows { wb.sheets[si].changeOutline(r...r, rows: true, by: 1) }
        return CellRange(range.start, CellRef(row: grand, col: range.end.col))
    }

    // MARK: - Duplicates, text to columns, series

    /// Removes rows of `range` whose values in `columns` repeat an earlier row; the rest move up inside the range.
    /// Returns the number of rows removed.
    @discardableResult
    static func removeDuplicates(_ wb: inout Workbook, sheet si: Int, range: CellRange, columns: [Int], header: Bool) -> Int {
        let s = wb.sheets[si]
        let rows = Array(range.rows.dropFirst(header ? 1 : 0))
        var seen = Set<[String]>(), keep: [Int] = []
        for r in rows {
            let key = columns.map { c -> String in
                let cell = s[CellRef(row: r, col: c)]
                return NumberFormat.format(cell.value, cell.style.numberFormat, date1904: wb.date1904).text.lowercased()
            }
            if seen.insert(key).inserted { keep.append(r) }
        }
        guard keep.count < rows.count else { return 0 }
        for (i, from) in keep.enumerated() {
            let to = rows[i]
            guard to != from else { continue }
            for c in range.cols {
                var cell = s[CellRef(row: from, col: c)]
                if cell.isFormula { cell.input = Formula.shifted(cell.input, rows: to - from, cols: 0) }
                wb.sheets[si][CellRef(row: to, col: c)] = cell
            }
        }
        for r in rows.dropFirst(keep.count) { for c in range.cols { wb.sheets[si][CellRef(row: r, col: c)] = Cell() } }
        return rows.count - keep.count
    }

    enum ColumnType: Int, CaseIterable { case general, text, dateDMY, dateMDY, dateYMD, skip }

    struct SplitOptions: Equatable {
        var delimiters: Set<Character> = [","]
        var consecutiveAsOne = false
        var quote: Character? = "\""
        /// Fixed widths: positions (characters) where columns start; nil for delimited text.
        var fixedBreaks: [Int]?
        var types: [ColumnType] = []
    }

    static func split(_ text: String, _ o: SplitOptions) -> [String] {
        if let breaks = o.fixedBreaks {
            let chars = Array(text)
            let bounds = [0] + breaks.filter { $0 > 0 && $0 < chars.count }.sorted() + [chars.count]
            return zip(bounds, bounds.dropFirst()).map { String(chars[$0..<$1]).trimmingCharacters(in: .whitespaces) }
        }
        var parts: [String] = [], field = "", quoted = false, lastWasDelimiter = false
        for ch in text {
            if let q = o.quote, ch == q { quoted.toggle(); lastWasDelimiter = false; continue }
            if !quoted, o.delimiters.contains(ch) {
                if o.consecutiveAsOne, lastWasDelimiter { continue }
                parts.append(field); field = ""; lastWasDelimiter = true
                continue
            }
            field.append(ch)
            lastWasDelimiter = false
        }
        parts.append(field)
        return parts
    }

    static func typed(_ s: String, _ t: ColumnType, date1904: Bool = false) -> Cell? {
        var c = Cell()
        switch t {
        case .skip: return nil
        case .text:
            c.input = s.isEmpty ? "" : (XLSX.constant(s, date1904: date1904) == .string(s) ? s : "'" + s)
            c.value = .string(s)
            c.style.numberFormat = "@"
        case .general:
            c.input = s
            c.value = XLSX.constant(s, date1904: date1904)
            if case .number = c.value, Double(s.replacingOccurrences(of: ",", with: ".")) == nil, DateMath.parse(s, date1904: date1904) != nil {
                c.style.numberFormat = s.contains(":") ? "dd.mm.yyyy hh:mm" : "dd.mm.yyyy"
            }
        case .dateDMY, .dateMDY, .dateYMD:
            let n = s.split(whereSeparator: { "./- ".contains($0) }).compactMap { Int($0) }
            guard n.count >= 3 else { return typed(s, .general, date1904: date1904) }
            let (d, m, y) = t == .dateDMY ? (n[0], n[1], n[2]) : t == .dateMDY ? (n[1], n[0], n[2]) : (n[2], n[1], n[0])
            guard let serial = DateMath.serial(year: y < 100 ? y + (y < 30 ? 2000 : 1900) : y, month: m, day: d) else { return typed(s, .general, date1904: date1904) }
            c.value = .number(serial - (date1904 ? 1462 : 0))
            c.style.numberFormat = "dd.mm.yyyy"
            c.input = XLSX.inputText(for: c.value, style: c.style, date1904: date1904)
        }
        return c
    }

    /// Splits the text of the first column of `range` into columns to the right (in place).
    static func textToColumns(_ wb: inout Workbook, sheet si: Int, range: CellRange, options: SplitOptions) {
        let col = range.start.col
        for r in range.rows {
            let source = wb.sheets[si][CellRef(row: r, col: col)]
            guard !source.isFormula else { continue }
            let text = Calculator(wb).text(source.value)
            guard !text.isEmpty else { continue }
            var out = col
            for (i, part) in split(text, options).enumerated() {
                let t = i < options.types.count ? options.types[i] : .general
                guard var cell = typed(part, t, date1904: wb.date1904) else { continue }
                if out == col { cell.style = mergeFormat(source.style, cell.style) }
                wb.sheets[si][CellRef(row: r, col: out)] = cell
                out += 1
            }
        }
    }

    private static func mergeFormat(_ base: CellStyle, _ new: CellStyle) -> CellStyle {
        var s = base
        s.numberFormat = new.numberFormat == "General" ? (base.numberFormat == "@" ? "General" : base.numberFormat) : new.numberFormat
        return s
    }

    enum SeriesType: Int, CaseIterable { case linear, growth, date, autofill }
    enum DateUnit: Int, CaseIterable { case day, weekday, month, year }
    enum Direction: Int, CaseIterable { case down, right, up, left }

    /// Fill › Series: each column (row) of the range continues from its first (last for up/left) cell.
    static func fillSeries(_ wb: inout Workbook, sheet si: Int, range: CellRange, direction: Direction, type: SeriesType,
                           unit: DateUnit, step: Double, stop: Double?) {
        guard step.isFinite, stop?.isFinite != false, type != .date || abs(step) <= 3_000_000 else { return }
        let vertical = direction == .down || direction == .up
        let forward = direction == .down || direction == .right
        let lines = vertical ? Array(range.cols) : Array(range.rows)
        for line in lines {
            var refs: [CellRef] = vertical ? range.rows.map { CellRef(row: $0, col: line) } : range.cols.map { CellRef(row: line, col: $0) }
            if !forward { refs.reverse() }
            let startCell = wb.sheets[si][refs[0]]
            guard case .number(let start) = startCell.value, start.isFinite else { continue }
            let dateOffset: Double = wb.date1904 ? 1462 : 0
            if type == .date, !(0...2_958_465).contains(start + dateOffset) { continue }
            let increasing = type == .growth ? start * step >= start : step >= 0
            var v = start
            for ref in refs.dropFirst() {
                switch type {
                case .linear, .autofill: v += step
                case .growth: v *= step
                case .date:
                    switch unit {
                    case .day: v += step
                    case .weekday:
                        var left = abs(Int(step)), d = v + dateOffset
                        let sign: Double = step < 0 ? -1 : 1
                        if left > 0, Calculator.isoWeekday(d) >= 5 {
                            repeat { d += sign } while Calculator.isoWeekday(d) >= 5
                            left -= 1
                        }
                        d += Double(left / 5) * 7 * sign
                        left %= 5
                        while left > 0 { d += sign; if Calculator.isoWeekday(d) < 5 { left -= 1 } }
                        v = d - dateOffset
                    case .month, .year:
                        guard let c = DateMath.components(start + dateOffset) else { break }
                        let k = Int(step) * (unit == .year ? 12 : 1) * ((vertical ? abs(ref.row - refs[0].row) : abs(ref.col - refs[0].col)))
                        var y = c.year!, m = c.month! + k
                        y += Int(floor(Double(m - 1) / 12)); m = ((m - 1) % 12 + 12) % 12 + 1
                        guard (1900...9999).contains(y) else { v = .nan; break }
                        guard let date = DateMath.serial(year: y, month: m, day: min(c.day!, DateMath.daysInMonth(year: y, month: m))) else { v = .nan; break }
                        v = date - dateOffset + (start - floor(start))
                    }
                }
                guard v.isFinite, type != .date || (0...2_958_465).contains(v + dateOffset) else { break }
                if let stop, increasing ? v > stop + 1e-12 : v < stop - 1e-12 { break }
                var cell = wb.sheets[si][ref]
                cell.value = .number(v)
                cell.style.numberFormat = startCell.style.numberFormat
                cell.input = XLSX.inputText(for: cell.value, style: cell.style, date1904: wb.date1904)
                wb.sheets[si][ref] = cell
            }
        }
    }

    /// Fill Up / Fill Left: the last row (column) copied over the range, formulas shifted.
    static func fill(_ wb: inout Workbook, sheet si: Int, range: CellRange, direction: Direction) {
        for ref in range.cells {
            let source: CellRef
            switch direction {
            case .down: source = CellRef(row: range.start.row, col: ref.col)
            case .right: source = CellRef(row: ref.row, col: range.start.col)
            case .up: source = CellRef(row: range.end.row, col: ref.col)
            case .left: source = CellRef(row: ref.row, col: range.end.col)
            }
            guard source != ref else { continue }
            var c = wb.sheets[si][source]
            if c.isFormula { c.input = Formula.shifted(c.input, rows: ref.row - source.row, cols: ref.col - source.col) }
            wb.sheets[si][ref] = c
        }
    }

    // MARK: - Goal Seek

    /// Value of `formula` with `variable` set to x (recalculating only what it depends on).
    static func evaluate(_ wb: Workbook, sheet si: Int, formula: CellRef, variables: [CellRef], values: [Double]) -> Double? {
        var w = wb
        for (ref, x) in zip(variables, values) {
            var c = w.sheets[si][ref]
            c.input = Value.formatGeneral(x)
            c.value = .number(x)
            w.sheets[si][ref] = c
        }
        let done = DispatchSemaphore(value: 0)
        var result: Value = .empty
        // A big stack for long dependency chains, as in recalculation.
        let thread = Thread {
            result = Calculator(w).value(sheet: si, ref: formula)
            done.signal()
        }
        thread.stackSize = 64 << 20
        thread.start()
        done.wait()
        if case .number(let d) = result, d.isFinite { return d }
        return nil
    }

    /// Finds x so that `formula` equals `target` (secant method, then bracketing and bisection).
    static func goalSeek(_ wb: Workbook, sheet si: Int, formula: CellRef, target: Double, variable: CellRef) -> Double? {
        func f(_ x: Double) -> Double? { evaluate(wb, sheet: si, formula: formula, variables: [variable], values: [x]).map { $0 - target } }
        var x0: Double = { if case .number(let d) = wb.sheets[si][variable].value { return d }; return 0 }()
        guard let y0 = f(x0) else { return nil }
        if abs(y0) < 1e-10 * max(1, abs(target)) { return x0 }
        var x1 = x0 == 0 ? 0.01 : x0 * 1.01
        guard var fy0 = Optional(y0), var fy1 = f(x1) else { return nil }
        for _ in 0..<200 {
            if abs(fy1) < 1e-10 * max(1, abs(target)) { return x1 }
            let d = fy1 - fy0
            guard d != 0 else { break }
            let x2 = x1 - fy1 * (x1 - x0) / d
            guard x2.isFinite, let y2 = f(x2) else { break }
            (x0, fy0, x1, fy1) = (x1, fy1, x2, y2)
        }
        if abs(fy1) < 1e-7 * max(1, abs(target)) { return x1 }
        // Bracket a sign change around the starting value and bisect.
        let start: Double = { if case .number(let d) = wb.sheets[si][variable].value { return d }; return 0 }()
        var width = max(1, abs(start))
        for _ in 0..<60 {
            let a = start - width, b = start + width
            if let fa = f(a), let fb = f(b), fa * fb <= 0 {
                var lo = a, hi = b, flo = fa
                for _ in 0..<200 {
                    let mid = (lo + hi) / 2
                    guard let fm = f(mid) else { return nil }
                    if abs(fm) < 1e-10 * max(1, abs(target)) || hi - lo < 1e-12 * max(1, abs(mid)) { return mid }
                    if (fm < 0) == (flo < 0) { lo = mid; flo = fm } else { hi = mid }
                }
                return (lo + hi) / 2
            }
            width *= 2
        }
        return nil
    }
}
