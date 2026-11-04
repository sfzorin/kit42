import Kit42
import Foundation

struct Matrix {
    var rows: Int
    var cols: Int
    var values: [Value]
    subscript(r: Int, c: Int) -> Value { values[r * cols + c] }

    init(rows: Int, cols: Int, values: [Value]) {
        self.rows = rows
        self.cols = cols
        self.values = values
    }

    init(rows: Int, cols: Int, fill: Value) { self.init(rows: rows, cols: cols, values: Array(repeating: fill, count: rows * cols)) }

    /// Rows of equal length (the first row sets the width; short rows are padded with #N/A).
    init(_ rows: [[Value]]) {
        let w = rows.map(\.count).max() ?? 0
        self.init(rows: rows.count, cols: w, values: rows.flatMap { $0 + Array(repeating: .error("#N/A"), count: w - $0.count) })
    }

    var count: Int { values.count }
    func row(_ r: Int) -> [Value] { Array(values[(r * cols)..<(r * cols + cols)]) }
    func column(_ c: Int) -> [Value] { (0..<rows).map { self[$0, c] } }
    var transposed: Matrix {
        var out: [Value] = []
        out.reserveCapacity(values.count)
        for c in 0..<cols { for r in 0..<rows { out.append(self[r, c]) } }
        return Matrix(rows: cols, cols: rows, values: out)
    }

    /// Element for elementwise operations: single rows/columns repeat, other positions outside are #N/A.
    func at(_ r: Int, _ c: Int) -> Value {
        let rr = rows == 1 ? 0 : r, cc = cols == 1 ? 0 : c
        guard rr < rows, cc < cols else { return .error("#N/A") }
        return self[rr, cc]
    }
}

enum Operand {
    case value(Value)
    case matrix(Matrix, origin: CellRef?)

    /// More than one value (an array result rather than a single cell).
    var isMulti: Bool { if case .matrix(let m, _) = self { return m.count != 1 }; return false }
}

struct XLError: Error {
    let code: String
    static let value = XLError(code: "#VALUE!")
    static let div0 = XLError(code: "#DIV/0!")
    static let ref = XLError(code: "#REF!")
    static let name = XLError(code: "#NAME?")
    static let na = XLError(code: "#N/A")
    static let num = XLError(code: "#NUM!")
    static let spill = XLError(code: "#SPILL!")
    static let calc = XLError(code: "#CALC!")
}

/// Evaluates every formula of a workbook. Excel semantics for coercion, comparison,
/// error propagation, criteria (SUMIF/COUNTIF), lookups and serial dates. Operators and scalar
/// functions work element by element on arrays; dynamic-array formulas (FILTER, SORT, SEQUENCE…)
/// and array formulas spill their result into the cells below and to the right (#SPILL! when blocked).
final class Calculator {
    private(set) var workbook: Workbook
    private var cache: [Int: [CellRef: Value]] = [:]
    private var visiting = Set<[Int]>()
    private var nameDepth = 0
    /// LET bindings and LAMBDA parameters, innermost last.
    var locals: [[String: Operand]] = []
    private static var parsed: [String: Expr] = [:]
    private static var dynamic: [String: Bool] = [:]
    private static let parseLock = NSLock()
    /// Values spilled by array results (not the anchor cells), and each anchor's spill range.
    private(set) var spilled: [Int: [CellRef: Value]] = [:]
    private(set) var spillRanges: [Int: [CellRef: CellRange]] = [:]
    /// Formulas that may spill, per sheet; `spillsDone`: every one of them is evaluated.
    private var anchors: [Int: [CellRef]] = [:]
    private var spillsDone = Set<Int>()
    /// Evaluation depth guard (LAMBDA recursion, deep nesting).
    var depth = 0

    init(_ workbook: Workbook) {
        self.workbook = workbook
        for (si, sheet) in workbook.sheets.enumerated() {
            let list = sheet.cells.filter { $0.value.isFormula && ($0.value.array || Self.isDynamic($0.value.input)) }.keys.sorted()
            if !list.isEmpty { anchors[si] = list }
        }
    }

    /// Recalculates all formulas and returns the workbook with fresh cached values.
    /// Runs on a thread with a large stack so long dependency chains don't overflow.
    static func recalculate(_ workbook: Workbook) -> Workbook {
        // Values spilled by the last calculation are recomputed.
        // (The cells stay, empty, so ranges over the previous spill area still reach them.)
        var input = workbook
        for si in input.sheets.indices {
            input.sheets[si].spills = [:]
            for (ref, cell) in input.sheets[si].cells where cell.input.isEmpty && !cell.value.isEmpty {
                input.sheets[si].cells[ref]?.value = .empty
            }
        }
        var result = input
        let done = DispatchSemaphore(value: 0)
        let thread = Thread {
            let calc = Calculator(input)
            for (si, sheet) in input.sheets.enumerated() {
                for (ref, cell) in sheet.cells where cell.isFormula { _ = calc.value(sheet: si, ref: ref) }
            }
            for (si, values) in calc.cache {
                for (ref, v) in values { result.sheets[si].cells[ref]?.value = v }
            }
            for (si, values) in calc.spilled {
                for (ref, v) in values {
                    if result.sheets[si].cells[ref] == nil { result.sheets[si].cells[ref] = Cell() }
                    result.sheets[si].cells[ref]?.value = v
                }
            }
            for (si, ranges) in calc.spillRanges { result.sheets[si].spills = ranges }
            // Drop cells left over from a spill that shrank.
            for si in result.sheets.indices {
                for (ref, cell) in result.sheets[si].cells where cell.isBlank && calc.spilled[si]?[ref] == nil { result.sheets[si].cells[ref] = nil }
            }
            done.signal()
        }
        thread.stackSize = 256 << 20
        thread.start()
        done.wait()
        return result
    }

    static func expression(_ input: String) -> Expr? {
        parseLock.lock(); defer { parseLock.unlock() }
        if let e = parsed[input] { return e }
        guard let e = try? Formula.parse(input) else { return nil }
        if parsed.count > 50_000 { parsed.removeAll() }
        parsed[input] = e
        return e
    }

    /// Functions whose array results spill (Excel 365 dynamic arrays).
    static let dynamicFunctions: Set<String> = [
        "FILTER", "SORT", "SORTBY", "UNIQUE", "SEQUENCE", "RANDARRAY", "TRANSPOSE", "TEXTSPLIT", "MODE.MULT", "LINEST",
        "TREND", "GROWTH", "MMULT", "MINVERSE", "MUNIT", "FREQUENCY", "XLOOKUP", "VSTACK", "HSTACK", "TOCOL", "TOROW",
        "CHOOSECOLS", "CHOOSEROWS", "TAKE", "DROP", "EXPAND", "WRAPROWS", "WRAPCOLS", "LET", "REGEXEXTRACT", "LOGEST",
    ]

    /// The formula uses a dynamic-array function, so an array result spills.
    static func isDynamic(_ input: String) -> Bool {
        parseLock.lock()
        if let d = dynamic[input] { parseLock.unlock(); return d }
        parseLock.unlock()
        var found = false
        func walk(_ e: Expr) {
            guard !found else { return }
            switch e {
            case .call(let n, let args):
                if dynamicFunctions.contains(n) { found = true; return }
                args.forEach(walk)
            case .binary(_, let l, let r): walk(l); walk(r)
            case .unary(_, let x), .percent(let x): walk(x)
            default: break
            }
        }
        if let e = expression(input) { walk(e) }
        parseLock.lock()
        if dynamic.count > 50_000 { dynamic.removeAll() }
        dynamic[input] = found
        parseLock.unlock()
        return found
    }

    // MARK: - Cells

    func value(sheet: Int, ref: CellRef) -> Value {
        guard sheet < workbook.sheets.count else { return .empty }
        guard let cell = workbook.sheets[sheet].cells[ref], cell.isFormula else {
            if let cell = workbook.sheets[sheet].cells[ref], !cell.input.isEmpty { return cell.value }
            return spillValue(sheet: sheet, ref: ref)
        }
        if let v = cache[sheet]?[ref] { return v }
        let key = [sheet, ref.row, ref.col]
        if visiting.contains(key) { return .error("#REF!") }
        visiting.insert(key)
        defer { visiting.remove(key) }
        let v: Value
        if let e = Self.expression(cell.input) {
            let result = eval(e, sheet: sheet, at: ref)
            if result.isMulti, cell.array || Self.isDynamic(cell.input), case .matrix(let m, _) = result {
                v = spill(m, sheet: sheet, at: ref)
            } else {
                v = scalar(result, at: ref)
            }
        } else {
            v = .error("#NAME?")
        }
        let stored: Value = v.isEmpty ? .number(0) : v
        cache[sheet, default: [:]][ref] = stored
        return stored
    }

    /// Bottom-right corner of the sheet's spilled results (evaluating its array formulas first).
    private func spillExtent(sheet: Int) -> CellRef? {
        guard anchors[sheet] != nil else { return nil }
        _ = spillValue(sheet: sheet, ref: CellRef(row: RefPart.maxRow, col: RefPart.maxCol))
        guard let ranges = spillRanges[sheet], !ranges.isEmpty else { return nil }
        return CellRef(row: ranges.values.map(\.end.row).max()!, col: ranges.values.map(\.end.col).max()!)
    }

    /// Value an empty cell gets from a spilling formula (evaluates the sheet's array formulas first).
    private func spillValue(sheet: Int, ref: CellRef) -> Value {
        guard let list = anchors[sheet] else { return .empty }
        if !spillsDone.contains(sheet) {
            var all = true
            for a in list where cache[sheet]?[a] == nil {
                if visiting.contains([sheet, a.row, a.col]) { all = false; continue }
                _ = value(sheet: sheet, ref: a)
            }
            if all { spillsDone.insert(sheet) }
        }
        return spilled[sheet]?[ref] ?? .empty
    }

    /// Writes an array result from `at` down and right; #SPILL! when a cell in the way isn't empty.
    private func spill(_ m: Matrix, sheet: Int, at: CellRef) -> Value {
        guard m.rows > 0, m.cols > 0 else { return .error("#CALC!") }
        guard m.count <= 2_000_000, at.row + m.rows - 1 <= RefPart.maxRow, at.col + m.cols - 1 <= RefPart.maxCol else { return .error("#SPILL!") }
        let s = workbook.sheets[sheet]
        let range = CellRange(at, CellRef(row: at.row + m.rows - 1, col: at.col + m.cols - 1))
        for r in range.rows {
            for c in range.cols where r != at.row || c != at.col {
                let ref = CellRef(row: r, col: c)
                if let cell = s.cells[ref], !cell.input.isEmpty { return .error("#SPILL!") }
                if spilled[sheet]?[ref] != nil { return .error("#SPILL!") }
            }
        }
        if s.merges.contains(where: { m in range.contains(m.start) || range.contains(m.end) }) { return .error("#SPILL!") }
        for r in 0..<m.rows {
            for c in 0..<m.cols where r != 0 || c != 0 {
                let v = m[r, c]
                spilled[sheet, default: [:]][CellRef(row: at.row + r, col: at.col + c)] = v.isEmpty ? .number(0) : v
            }
        }
        spillRanges[sheet, default: [:]][at] = range
        return m[0, 0]
    }

    // MARK: - Expressions

    func eval(_ e: Expr, sheet: Int, at: CellRef) -> Operand {
        do { return try evalThrowing(e, sheet: sheet, at: at) } catch let err as XLError {
            return .value(.error(err.code))
        } catch { return .value(.error("#VALUE!")) }
    }

    func sheetIndex(_ name: String?, _ current: Int) throws -> Int {
        guard let name else { return current }
        guard let i = workbook.sheetIndex(named: name) else { throw XLError.ref }
        return i
    }

    func rangeMatrix(sheet s: Int, _ a: RefPart, _ b: RefPart) -> (Matrix, CellRef) {
        let sheet = workbook.sheets[s]
        var used = sheet.usedRange
        // Spilled results count as used cells (whole columns over a spill).
        if let extent = spillExtent(sheet: s) {
            used = used.map { CellRange($0.start, CellRef(row: max($0.end.row, extent.row), col: max($0.end.col, extent.col))) } ?? CellRange(extent, extent)
        }
        var r1 = a.wholeColumn ? 0 : min(a.row, b.row)
        var r2 = a.wholeColumn ? (used?.end.row ?? 0) : max(a.row, b.row)
        var c1 = a.wholeRow ? 0 : min(a.col, b.col)
        var c2 = a.wholeRow ? (used?.end.col ?? 0) : max(a.col, b.col)
        // Keep huge ranges (A1:A1048576) within the used area.
        if let used {
            r2 = min(r2, max(used.end.row, r1))
            c2 = min(c2, max(used.end.col, c1))
        } else { r2 = r1; c2 = c1 }
        r1 = max(0, r1); c1 = max(0, c1)
        var values: [Value] = []
        values.reserveCapacity((r2 - r1 + 1) * (c2 - c1 + 1))
        for r in r1...r2 { for c in c1...c2 { values.append(value(sheet: s, ref: CellRef(row: r, col: c))) } }
        return (Matrix(rows: r2 - r1 + 1, cols: c2 - c1 + 1, values: values), CellRef(row: r1, col: c1))
    }

    private func evalThrowing(_ e: Expr, sheet: Int, at: CellRef) throws -> Operand {
        switch e {
        case .number(let d): return .value(.number(d))
        case .string(let s): return .value(.string(s))
        case .bool(let b): return .value(.bool(b))
        case .error(let c): return .value(.error(c))
        case .missing: return .value(.empty)
        case .array(let m): return .matrix(m, origin: nil)
        case .name(let n):
            let up = n.uppercased()
            for scope in locals.reversed() { if let v = scope[up] { return v } }
            if up == "TRUE" { return .value(.bool(true)) }
            if up == "FALSE" { return .value(.bool(false)) }
            // Defined names (workbook scope), resolved by their formula text.
            guard let def = workbook.names.first(where: { $0.key.caseInsensitiveCompare(n) == .orderedSame })?.value,
                  nameDepth < 20, let e = Self.expression("=" + def) else { throw XLError.name }
            nameDepth += 1
            defer { nameDepth -= 1 }
            return try evalThrowing(e, sheet: sheet, at: at)
        case .ref(let sheetName, let p):
            let s = try sheetIndex(sheetName, sheet)
            return .matrix(Matrix(rows: 1, cols: 1, values: [value(sheet: s, ref: CellRef(row: p.row, col: p.col))]),
                           origin: CellRef(row: p.row, col: p.col))
        case .range(let sheetName, let a, let b):
            let s = try sheetIndex(sheetName, sheet)
            let (m, origin) = rangeMatrix(sheet: s, a, b)
            return .matrix(m, origin: origin)
        case .unary(let op, let x):
            let o = eval(x, sheet: sheet, at: at)
            if o.isMulti { return elementwise([o]) { v in let d = try self.num(v[0]); return .number(op == "-" ? -d : d) } }
            let v = try num(scalar(o, at: at))
            return .value(.number(op == "-" ? -v : v))
        case .percent(let x):
            let o = eval(x, sheet: sheet, at: at)
            if o.isMulti { return elementwise([o]) { v in .number(try self.num(v[0]) / 100) } }
            return .value(.number(try num(scalar(o, at: at)) / 100))
        case .binary(let op, let l, let r):
            let lo = eval(l, sheet: sheet, at: at), ro = eval(r, sheet: sheet, at: at)
            if lo.isMulti || ro.isMulti { return elementwise([lo, ro]) { v in try self.binary(op, v[0], v[1]) } }
            let a = scalar(lo, at: at)
            let b = scalar(ro, at: at)
            if case .error(let c) = a { throw XLError(code: c) }
            if case .error(let c) = b { throw XLError(code: c) }
            return .value(try binary(op, a, b))
        case .call(let name, let args):
            depth += 1
            defer { depth -= 1 }
            guard depth < 400 else { throw XLError.num }
            return try call(name, args, sheet: sheet, at: at)
        }
    }

    /// Applies `f` element by element (single rows/columns broadcast; errors in an element stay in that element).
    func elementwise(_ ops: [Operand], _ f: ([Value]) throws -> Value) -> Operand {
        let ms = ops.map(matrix)
        let rows = ms.map(\.rows).max() ?? 1, cols = ms.map(\.cols).max() ?? 1
        var out: [Value] = []
        out.reserveCapacity(rows * cols)
        for r in 0..<rows {
            for c in 0..<cols {
                let args = ms.map { $0.at(r, c) }
                if let e = args.first(where: \.isError) { out.append(e); continue }
                do { out.append(try f(args)) } catch let err as XLError { out.append(.error(err.code)) } catch { out.append(.error("#VALUE!")) }
            }
        }
        // Keep the range's position for implicit intersection (=A1:A3*2 in row 2 → A2*2).
        var origin: CellRef?
        for case .matrix(let m, let o) in ops where m.rows == rows && m.cols == cols && o != nil { origin = o; break }
        return .matrix(Matrix(rows: rows, cols: cols, values: out), origin: origin)
    }

    func binary(_ op: String, _ a: Value, _ b: Value) throws -> Value {
        if case .error(let c) = a { throw XLError(code: c) }
        if case .error(let c) = b { throw XLError(code: c) }
        switch op {
        case "+": return .number(try num(a) + num(b))
        case "-": return .number(try num(a) - num(b))
        case "*": return .number(try num(a) * num(b))
        case "/":
            let d = try num(b)
            guard d != 0 else { throw XLError.div0 }
            return .number(try num(a) / d)
        case "^":
            let r = pow(try num(a), try num(b))
            guard r.isFinite else { throw XLError.num }
            return .number(r)
        case "&": return .string(text(a) + text(b))
        default:
            let c = compare(a, b)
            switch op {
            case "=": return .bool(c == 0)
            case "<>": return .bool(c != 0)
            case "<": return .bool(c < 0)
            case ">": return .bool(c > 0)
            case "<=": return .bool(c <= 0)
            default: return .bool(c >= 0)
            }
        }
    }

    /// Implicit intersection: a range used where one value is expected.
    func scalar(_ op: Operand, at: CellRef) -> Value {
        switch op {
        case .value(let v): return v
        case .matrix(let m, let origin):
            if m.rows == 1, m.cols == 1 { return m.values[0] }
            if let o = origin {
                if m.cols == 1, at.row >= o.row, at.row < o.row + m.rows { return m[at.row - o.row, 0] }
                if m.rows == 1, at.col >= o.col, at.col < o.col + m.cols { return m[0, at.col - o.col] }
            }
            return m.values.first ?? .empty
        }
    }

    // MARK: - Coercion

    func num(_ v: Value) throws -> Double {
        switch v {
        case .empty: return 0
        case .number(let d): return d
        case .bool(let b): return b ? 1 : 0
        case .string(let s):
            if let d = parseNumber(s) { return d }
            throw XLError.value
        case .error(let c): throw XLError(code: c)
        }
    }

    func parseNumber(_ s: String) -> Double? {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return nil }
        if let d = Double(t) { return d }
        if let d = Double(t.replacingOccurrences(of: ",", with: ".").replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "\u{00A0}", with: "")) { return d }
        if t.hasSuffix("%"), let d = parseNumber(String(t.dropLast())) { return d / 100 }
        if let date = DateMath.parse(t) { return date }
        return nil
    }

    func text(_ v: Value) -> String {
        switch v {
        case .empty: return ""
        case .number(let d): return Value.formatGeneral(d)
        case .string(let s): return s
        case .bool(let b): return b ? "TRUE" : "FALSE"
        case .error(let c): return c
        }
    }

    func bool(_ v: Value) throws -> Bool {
        switch v {
        case .empty: return false
        case .bool(let b): return b
        case .number(let d): return d != 0
        case .string(let s):
            switch s.uppercased() {
            case "TRUE", "ИСТИНА", "DOĞRU": return true
            case "FALSE", "ЛОЖЬ", "YANLIŞ": return false
            default: throw XLError.value
            }
        case .error(let c): throw XLError(code: c)
        }
    }

    /// Excel ordering: numbers < text < booleans; text case-insensitive; empty equals 0 / "".
    func compare(_ a: Value, _ b: Value) -> Int {
        func rank(_ v: Value) -> Int {
            switch v {
            case .number, .empty: return 0
            case .string: return 1
            case .bool: return 2
            case .error: return 3
            }
        }
        var a = a, b = b
        if a.isEmpty { if case .string = b { a = .string("") } else if case .bool = b { a = .bool(false) } }
        if b.isEmpty { if case .string = a { b = .string("") } else if case .bool = a { b = .bool(false) } }
        let ra = rank(a), rb = rank(b)
        if ra != rb { return ra < rb ? -1 : 1 }
        switch (a, b) {
        case (.string(let x), .string(let y)):
            let r = x.compare(y, options: [.caseInsensitive, .diacriticInsensitive], locale: Locale.current)
            return r == .orderedAscending ? -1 : r == .orderedSame ? 0 : 1
        case (.bool(let x), .bool(let y)): return x == y ? 0 : (!x ? -1 : 1)
        default:
            let x = (try? num(a)) ?? 0, y = (try? num(b)) ?? 0
            return x < y ? -1 : x > y ? 1 : 0
        }
    }

    // MARK: - Argument helpers

    func values(_ op: Operand) -> [Value] {
        switch op {
        case .value(let v): return [v]
        case .matrix(let m, _): return m.values
        }
    }

    func matrix(_ op: Operand) -> Matrix {
        switch op {
        case .value(let v): return Matrix(rows: 1, cols: 1, values: [v])
        case .matrix(let m, _): return m
        }
    }

    func isReference(_ e: Expr) -> Bool {
        switch e { case .ref, .range: return true; default: return false }
    }

    /// Numbers for SUM/AVERAGE/MIN/…: in references only numbers count; direct arguments are coerced.
    func numbers(_ args: [Expr], sheet: Int, at: CellRef, countText: Bool = false) throws -> [Double] {
        var out: [Double] = []
        for arg in args {
            if case .missing = arg { continue }
            let op = eval(arg, sheet: sheet, at: at)
            let fromRef: Bool
            if case .matrix = op { fromRef = true } else { fromRef = isReference(arg) }
            for v in values(op) {
                switch v {
                case .number(let d): out.append(d)
                case .error(let c): throw XLError(code: c)
                case .bool(let b): if !fromRef || countText { out.append(b ? 1 : 0) }
                case .string(let s):
                    if fromRef { if countText { out.append(0) } } else { out.append(try num(.string(s))) }
                case .empty: break
                }
            }
        }
        return out
    }

    func arg(_ args: [Expr], _ i: Int, _ sheet: Int, _ at: CellRef) -> Value {
        guard i < args.count else { return .empty }
        if case .missing = args[i] { return .empty }
        return scalar(eval(args[i], sheet: sheet, at: at), at: at)
    }

    func numArg(_ args: [Expr], _ i: Int, _ sheet: Int, _ at: CellRef, default d: Double? = nil) throws -> Double {
        if i >= args.count || { if case .missing = args[i] { return true }; return false }() {
            if let d { return d }
            throw XLError.value
        }
        let v = arg(args, i, sheet, at)
        if case .error(let c) = v { throw XLError(code: c) }
        return try num(v)
    }

    func textArg(_ args: [Expr], _ i: Int, _ sheet: Int, _ at: CellRef, default d: String? = nil) throws -> String {
        if i >= args.count, let d { return d }
        let v = arg(args, i, sheet, at)
        if case .error(let c) = v { throw XLError(code: c) }
        return text(v)
    }

    // MARK: - Criteria (SUMIF, COUNTIF, …)

    func criterion(_ c: Value) -> (Value) -> Bool {
        var op = "=", operand = c
        if case .string(let s) = c {
            for p in ["<=", ">=", "<>", "<", ">", "="] where s.hasPrefix(p) {
                op = p
                operand = .string(String(s.dropFirst(p.count)))
                break
            }
            if case .string(let rest) = operand, let d = parseNumber(rest) { operand = .number(d) }
        }
        if case .string(let pattern) = operand, op == "=" || op == "<>", pattern.contains(where: { "*?~".contains($0) }) {
            let regex = wildcardRegex(pattern)
            return { v in
                let s = self.text(v)
                let m = regex?.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
                return op == "=" ? m : !m
            }
        }
        if case .string(let s) = operand, s.isEmpty {
            return { v in
                let blank = v.isEmpty || v == .string("")
                return op == "<>" ? !blank : blank
            }
        }
        return { v in
            if case .number = operand, case .string = v, op != "<>" { return false }
            if case .string = operand, case .number = v { return op == "<>" }
            if v.isEmpty, op != "<>" {
                if case .number(let d) = operand { return op == "=" ? d == 0 : self.compareOp(op, self.compare(.number(0), operand)) }
                return false
            }
            return self.compareOp(op, self.compare(v, operand))
        }
    }

    func compareOp(_ op: String, _ c: Int) -> Bool {
        switch op {
        case "=": return c == 0
        case "<>": return c != 0
        case "<": return c < 0
        case ">": return c > 0
        case "<=": return c <= 0
        default: return c >= 0
        }
    }

    var regexCache: [String: NSRegularExpression] = [:]

    func wildcardRegex(_ pattern: String, anchored: Bool = true) -> NSRegularExpression? {
        let key = (anchored ? "^" : "") + pattern
        if let r = regexCache[key] { return r }
        var re = anchored ? "^" : ""
        var escape = false
        for ch in pattern {
            if escape { re += NSRegularExpression.escapedPattern(for: String(ch)); escape = false; continue }
            switch ch {
            case "~": escape = true
            case "*": re += ".*"
            case "?": re += "."
            default: re += NSRegularExpression.escapedPattern(for: String(ch))
            }
        }
        if anchored { re += "$" }
        let r = try? NSRegularExpression(pattern: re, options: [.caseInsensitive, .dotMatchesLineSeparators])
        regexCache[key] = r
        return r
    }

    // MARK: - Lookup helpers

    /// Position in a vector: exact (with wildcards) or approximate (largest ≤ value / smallest ≥ value).
    func lookupIndex(_ needle: Value, in hay: [Value], mode: Int) -> Int? {
        if mode == 0 {
            if case .string(let s) = needle, s.contains(where: { "*?".contains($0) }) {
                let match = criterion(needle)
                return hay.firstIndex(where: match)
            }
            return hay.firstIndex { compare($0, needle) == 0 && !$0.isEmpty }
        }
        var best: Int?
        for (i, v) in hay.enumerated() where !v.isEmpty {
            let c = compare(v, needle)
            if c == 0 { return i }
            if mode == 1, c < 0 { best = i }
            if mode == -1, c > 0 { best = i }
            if mode == 1, c > 0, best != nil { break }
        }
        return best
    }

    // MARK: - Functions

    /// "R2C3", "R[1]C[-1]", "Sheet!R1C1:R2C2" → A1 text (relative parts from `at`).
    static func r1c1ToA1(_ text: String, at: CellRef) throws -> String {
        var sheet = ""
        var body = Substring(text)
        if let bang = body.lastIndex(of: "!") { sheet = String(body[...bang]); body = body[body.index(after: bang)...] }
        func part(_ p: Substring) throws -> String {
            let up = p.uppercased()
            guard let re = try? NSRegularExpression(pattern: "^R(\\[-?\\d+\\]|\\d+)?C(\\[-?\\d+\\]|\\d+)?$"),
                  let m = re.firstMatch(in: up, range: NSRange(up.startIndex..., in: up)) else { throw XLError.ref }
            func value(_ i: Int, base: Int) -> (Int, Bool) {
                guard let r = Range(m.range(at: i), in: up) else { return (base, false) }
                let s = up[r]
                if s.hasPrefix("[") { return (base + (Int(s.dropFirst().dropLast()) ?? 0), false) }
                return ((Int(s) ?? 1) - 1, true)
            }
            let (row, absRow) = value(1, base: at.row), (col, absCol) = value(2, base: at.col)
            guard row >= 0, col >= 0 else { throw XLError.ref }
            return (absCol ? "$" : "") + CellRef.columnName(col) + (absRow ? "$" : "") + "\(row + 1)"
        }
        return sheet + (try body.split(separator: ":").map(part).joined(separator: ":"))
    }

    /// Evaluates the arguments once; arrays make the function run per element (broadcast like operators).
    private func lift(_ name: String, _ args: [Expr], sheet: Int, at: CellRef) throws -> Operand {
        let ops: [Operand?] = args.map { e in
            if case .missing = e { return nil }
            return eval(e, sheet: sheet, at: at)
        }
        func literal(_ v: Value) -> Expr { .array(Matrix(rows: 1, cols: 1, values: [v])) }
        guard ops.contains(where: { $0?.isMulti ?? false }) else {
            let lits = ops.map { $0.map { literal(scalar($0, at: at)) } ?? .missing }
            return try call(name, lits, sheet: sheet, at: at, lifted: true)
        }
        let ms = ops.map { $0.map(matrix) }
        let rows = ms.compactMap { $0?.rows }.max() ?? 1, cols = ms.compactMap { $0?.cols }.max() ?? 1
        var out: [Value] = []
        out.reserveCapacity(rows * cols)
        for r in 0..<rows {
            for c in 0..<cols {
                let lits = ms.map { $0.map { literal($0.at(r, c)) } ?? .missing }
                let v = scalar(eval(.call(name, lits), sheet: sheet, at: at), at: at)
                out.append(v)
            }
        }
        var origin: CellRef?
        for case .matrix(let m, let o)? in ops where m.rows == rows && m.cols == cols && o != nil { origin = o; break }
        return .matrix(Matrix(rows: rows, cols: cols, values: out), origin: origin)
    }

    /// Like `elementwise`, but errors are passed to `f` (IFERROR over arrays).
    private func elementwiseKeepingErrors(_ a: Operand, _ b: Matrix, _ f: (Value, Value) -> Value) -> Operand {
        let am = matrix(a)
        let rows = max(am.rows, b.rows), cols = max(am.cols, b.cols)
        var out: [Value] = []
        for r in 0..<rows { for c in 0..<cols { out.append(f(am.at(r, c), b.at(r, c))) } }
        return .matrix(Matrix(rows: rows, cols: cols, values: out), origin: nil)
    }

    /// Scalar functions applied element by element when an argument is an array (=LEN(A1:A3), =ROUND(B1:B5*2;1)).
    static let liftable: Set<String> = [
        "ABS", "SIGN", "INT", "TRUNC", "ROUND", "ROUNDUP", "ROUNDDOWN", "MROUND", "CEILING", "CEILING.MATH", "CEILING.PRECISE",
        "FLOOR", "FLOOR.MATH", "FLOOR.PRECISE", "ISO.CEILING", "EVEN", "ODD", "MOD", "POWER", "SQRT", "EXP", "LN", "LOG", "LOG10",
        "FACT", "DEGREES", "RADIANS", "SIN", "COS", "TAN", "ASIN", "ACOS", "ATAN", "ATAN2", "SINH", "COSH", "TANH", "ASINH", "ACOSH",
        "ATANH", "COT", "COTH", "CSC", "CSCH", "SEC", "SECH", "ACOT", "ACOTH", "QUOTIENT", "COMBIN", "PERMUT", "SQRTPI",
        "LEN", "LEFT", "RIGHT", "MID", "UPPER", "LOWER", "PROPER", "TRIM", "CLEAN", "SUBSTITUTE", "REPLACE", "FIND", "SEARCH",
        "REPT", "EXACT", "CHAR", "UNICHAR", "CODE", "UNICODE", "TEXT", "VALUE", "NUMBERVALUE", "FIXED", "DOLLAR", "TEXTBEFORE",
        "TEXTAFTER", "DATE", "TIME", "YEAR", "MONTH", "DAY", "WEEKDAY", "HOUR", "MINUTE", "SECOND", "EDATE", "EOMONTH", "DAYS",
        "DATEDIF", "WEEKNUM", "ISOWEEKNUM", "YEARFRAC", "DAYS360", "DATEVALUE", "TIMEVALUE", "ISBLANK", "ISNUMBER", "ISTEXT",
        "ISLOGICAL", "ISERROR", "ISERR", "ISNA", "ISEVEN", "ISODD", "N", "T", "NORM.DIST", "NORM.S.DIST", "NORM.INV", "NORM.S.INV",
        "NORMDIST", "NORMSDIST", "NORMINV", "NORMSINV", "DEC2BIN", "DEC2HEX", "DEC2OCT", "BIN2DEC", "HEX2DEC", "OCT2DEC",
        "BITAND", "BITOR", "BITXOR", "CONVERT", "REGEX", "REGEXTEST", "REGEXREPLACE", "ROMAN", "ARABIC", "BASE", "DECIMAL",
        "ERROR.TYPE", "NOT", "BINOM.DIST", "POISSON.DIST", "EXPON.DIST", "T.DIST", "CHISQ.DIST", "GAMMA", "GAMMALN", "PMT", "FV",
        "PV", "IPMT", "PPMT", "NPER", "EFFECT", "NOMINAL", "DELTA", "GESTEP", "HYPERLINK",
    ]

    func call(_ name: String, _ args: [Expr], sheet: Int, at: CellRef, lifted: Bool = false) throws -> Operand {
        // Arrays in IF / IFERROR / IFNA conditions, and scalar functions over arrays.
        if !lifted {
            switch name {
            case "IF" where !args.isEmpty:
                let cond = eval(args[0], sheet: sheet, at: at)
                if cond.isMulti {
                    let yes = args.count > 1 ? eval(args[1], sheet: sheet, at: at) : .value(.bool(true))
                    let no = args.count > 2 ? eval(args[2], sheet: sheet, at: at) : .value(.bool(false))
                    let cm = matrix(cond), ym = matrix(yes), nm = matrix(no)
                    let rows = max(cm.rows, ym.rows, nm.rows), cols = max(cm.cols, ym.cols, nm.cols)
                    var out: [Value] = []
                    for r in 0..<rows {
                        for c in 0..<cols {
                            let v = cm.at(r, c)
                            if case .error = v { out.append(v); continue }
                            guard let b = try? bool(v) else { out.append(.error("#VALUE!")); continue }
                            let picked = b ? ym.at(r, c) : nm.at(r, c)
                            out.append(picked.isEmpty ? .number(0) : picked)
                        }
                    }
                    return .matrix(Matrix(rows: rows, cols: cols, values: out), origin: nil)
                }
                return try call(name, [.array(Matrix(rows: 1, cols: 1, values: [scalar(cond, at: at)]))] + args.dropFirst(), sheet: sheet, at: at, lifted: true)
            case "IFERROR", "IFNA":
                guard args.count >= 2 else { throw XLError.value }
                let v = eval(args[0], sheet: sheet, at: at)
                if v.isMulti {
                    let alt = matrix(eval(args[1], sheet: sheet, at: at))
                    return elementwiseKeepingErrors(v, alt) { x, y in
                        if case .error(let c) = x, name == "IFERROR" || c == "#N/A" { return y }
                        return x
                    }
                }
                let one = scalar(v, at: at)
                if case .error(let c) = one, name == "IFERROR" || c == "#N/A" { return eval(args[1], sheet: sheet, at: at) }
                return .value(one)
            default:
                if Self.liftable.contains(name) { return try lift(name, args, sheet: sheet, at: at) }
            }
        }
        func a(_ i: Int) -> Value { arg(args, i, sheet, at) }
        func n(_ i: Int, _ d: Double? = nil) throws -> Double { try numArg(args, i, sheet, at, default: d) }
        func t(_ i: Int, _ d: String? = nil) throws -> String { try textArg(args, i, sheet, at, default: d) }
        func op(_ i: Int) -> Operand { i < args.count ? eval(args[i], sheet: sheet, at: at) : .value(.empty) }
        func nums() throws -> [Double] { try numbers(args, sheet: sheet, at: at) }
        func r(_ d: Double) throws -> Operand {
            guard d.isFinite else { throw XLError.num }
            return .value(.number(d))
        }
        func need(_ count: Int) throws { if args.count < count { throw XLError.value } }

        switch name {
        // Math & aggregates
        case "SUM": return try r(nums().reduce(0, +))
        case "PRODUCT": return try r(nums().reduce(1, *))
        case "AVERAGE":
            let v = try nums()
            guard !v.isEmpty else { throw XLError.div0 }
            return try r(v.reduce(0, +) / Double(v.count))
        case "AVERAGEA":
            let v = try numbers(args, sheet: sheet, at: at, countText: true)
            guard !v.isEmpty else { throw XLError.div0 }
            return try r(v.reduce(0, +) / Double(v.count))
        case "MIN": return try r(nums().min() ?? 0)
        case "MAX": return try r(nums().max() ?? 0)
        case "COUNT":
            return .value(.number(Double(args.flatMap { values(eval($0, sheet: sheet, at: at)) }.filter {
                if case .number = $0 { return true }; return false }.count)))
        case "COUNTA":
            return .value(.number(Double(args.flatMap { values(eval($0, sheet: sheet, at: at)) }.filter { !$0.isEmpty }.count)))
        case "COUNTBLANK":
            return .value(.number(Double(values(op(0)).filter { $0.isEmpty || $0 == .string("") }.count)))
        case "SUMSQ": return try r(nums().map { $0 * $0 }.reduce(0, +))
        case "MEDIAN":
            let v = try nums().sorted()
            guard !v.isEmpty else { throw XLError.num }
            return try r(v.count % 2 == 1 ? v[v.count / 2] : (v[v.count / 2 - 1] + v[v.count / 2]) / 2)
        case "MODE", "MODE.SNGL":
            let v = try nums()
            var counts: [Double: Int] = [:]
            v.forEach { counts[$0, default: 0] += 1 }
            guard let best = v.first(where: { counts[$0] == counts.values.max() && counts[$0]! > 1 }) else { throw XLError.na }
            return try r(best)
        case "STDEV", "STDEV.S", "STDEV.P", "VAR", "VAR.S", "VAR.P":
            let v = try nums()
            let population = name.hasSuffix(".P")
            guard v.count > (population ? 0 : 1) else { throw XLError.div0 }
            let mean = v.reduce(0, +) / Double(v.count)
            let variance = v.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(v.count - (population ? 0 : 1))
            return try r(name.hasPrefix("VAR") ? variance : variance.squareRoot())
        case "LARGE", "SMALL":
            try need(2)
            let v = try numbers([args[0]], sheet: sheet, at: at).sorted(by: name == "LARGE" ? (>) : (<))
            let k = Int(try n(1))
            guard k >= 1, k <= v.count else { throw XLError.num }
            return try r(v[k - 1])
        case "RANK", "RANK.EQ":
            try need(2)
            let x = try n(0)
            let v = try numbers([args[1]], sheet: sheet, at: at)
            let ascending = try n(2, 0) != 0
            guard v.contains(x) else { throw XLError.na }
            return try r(Double(v.filter { ascending ? $0 < x : $0 > x }.count + 1))
        case "SUMPRODUCT":
            let ms = args.map { matrix(eval($0, sheet: sheet, at: at)) }
            guard let first = ms.first else { throw XLError.value }
            guard ms.allSatisfy({ $0.rows == first.rows && $0.cols == first.cols }) else { throw XLError.value }
            var total = 0.0
            for i in 0..<first.values.count {
                var p = 1.0
                for m in ms {
                    if case .error(let c) = m.values[i] { throw XLError(code: c) }
                    if case .number(let d) = m.values[i] { p *= d } else { p = 0 }
                }
                total += p
            }
            return try r(total)
        case "ABS": return try r(abs(n(0)))
        case "SIGN": let x = try n(0); return try r(x > 0 ? 1 : x < 0 ? -1 : 0)
        case "INT": return try r(floor(n(0)))
        case "TRUNC":
            let f = pow(10, try n(1, 0))
            return try r((try n(0) * f).rounded(.towardZero) / f)
        case "ROUND", "ROUNDUP", "ROUNDDOWN":
            let x = try n(0), digits = try n(1, 0)
            let f = pow(10, digits)
            let rule: FloatingPointRoundingRule = name == "ROUND" ? .toNearestOrAwayFromZero : name == "ROUNDUP" ? .awayFromZero : .towardZero
            // Guard against binary noise (2.675 → 2.68 like Excel).
            let scaled = (x * f * 1e9).rounded() / 1e9
            return try r(scaled.rounded(rule) / f)
        case "MROUND":
            let x = try n(0), m = try n(1)
            guard m != 0 else { return .value(.number(0)) }
            guard x * m >= 0 else { throw XLError.num }
            return try r((x / m).rounded(.toNearestOrAwayFromZero) * m)
        case "CEILING":
            let x = try n(0), s = try n(1, x >= 0 ? 1 : -1)
            guard s != 0 else { return .value(.number(0)) }
            guard !(x > 0 && s < 0) else { throw XLError.num }
            return try r((x / s).rounded(.up) * s)
        case "FLOOR":
            let x = try n(0), s = try n(1, 1)
            guard s != 0 else { if x == 0 { return .value(.number(0)) }; throw XLError.div0 }
            guard !(x > 0 && s < 0) else { throw XLError.num }
            return try r((x / s).rounded(.down) * s)
        case "EVEN": let x = try n(0); let c = (abs(x) / 2).rounded(.up) * 2; return try r(x < 0 ? -c : c)
        case "ODD":
            let x = try n(0)
            var c = abs(x).rounded(.up)
            if Int(c) % 2 == 0 { c += 1 }
            return try r(x < 0 ? -c : c)
        case "MOD":
            let x = try n(0), d = try n(1)
            guard d != 0 else { throw XLError.div0 }
            return try r(x - d * floor(x / d))
        case "POWER": return try r(pow(n(0), n(1)))
        case "SQRT":
            let x = try n(0)
            guard x >= 0 else { throw XLError.num }
            return try r(x.squareRoot())
        case "EXP": return try r(exp(n(0)))
        case "LN":
            let x = try n(0)
            guard x > 0 else { throw XLError.num }
            return try r(log(x))
        case "LOG10":
            let x = try n(0)
            guard x > 0 else { throw XLError.num }
            return try r(log10(x))
        case "LOG":
            let x = try n(0), base = try n(1, 10)
            guard x > 0, base > 0, base != 1 else { throw XLError.num }
            return try r(log(x) / log(base))
        case "PI": return .value(.number(Double.pi))
        case "RAND": return .value(.number(Double.random(in: 0..<1)))
        case "RANDBETWEEN":
            let lo = try n(0).rounded(.up), hi = try n(1).rounded(.down)
            guard lo <= hi else { throw XLError.num }
            return try r(Double(Int.random(in: Int(lo)...Int(hi))))
        case "FACT":
            let x = Int(try n(0))
            guard x >= 0, x <= 170 else { throw XLError.num }
            return try r((1...max(1, x)).reduce(1.0) { $0 * Double($1) })
        case "DEGREES": return try r(n(0) * 180 / .pi)
        case "RADIANS": return try r(n(0) * .pi / 180)
        case "SIN": return try r(sin(n(0)))
        case "COS": return try r(cos(n(0)))
        case "TAN": return try r(tan(n(0)))

        // Conditional aggregates
        case "SUMIF", "AVERAGEIF", "COUNTIF":
            try need(2)
            let range = matrix(op(0))
            let test = criterion(a(1))
            let sumRange = name == "COUNTIF" ? range : (args.count > 2 ? matrix(op(2)) : range)
            var total = 0.0, count = 0
            for i in 0..<range.values.count where test(range.values[i]) {
                count += 1
                if name != "COUNTIF", i < sumRange.values.count, case .number(let d) = sumRange.values[i] { total += d }
            }
            if name == "COUNTIF" { return .value(.number(Double(count))) }
            if name == "SUMIF" { return try r(total) }
            guard count > 0 else { throw XLError.div0 }
            return try r(total / Double(count))
        case "SUMIFS", "AVERAGEIFS", "COUNTIFS", "MAXIFS", "MINIFS":
            let counting = name == "COUNTIFS"
            let start = counting ? 0 : 1
            guard args.count >= start + 2, (args.count - start) % 2 == 0 else { throw XLError.value }
            let target = counting ? nil : matrix(op(0))
            var pairs: [(Matrix, (Value) -> Bool)] = []
            for i in stride(from: start, to: args.count, by: 2) { pairs.append((matrix(op(i)), criterion(a(i + 1)))) }
            let size = pairs[0].0.values.count
            guard pairs.allSatisfy({ $0.0.values.count == size }), target.map({ $0.values.count == size }) ?? true else { throw XLError.value }
            var picked: [Double] = [], count = 0
            for i in 0..<size where pairs.allSatisfy({ $0.1($0.0.values[i]) }) {
                count += 1
                if let target, case .number(let d) = target.values[i] { picked.append(d) }
            }
            switch name {
            case "COUNTIFS": return .value(.number(Double(count)))
            case "SUMIFS": return try r(picked.reduce(0, +))
            case "MAXIFS": return try r(picked.max() ?? 0)
            case "MINIFS": return try r(picked.min() ?? 0)
            default:
                guard !picked.isEmpty else { throw XLError.div0 }
                return try r(picked.reduce(0, +) / Double(picked.count))
            }
        // Logic
        case "IF":
            try need(1)
            let cond = a(0)
            if case .error(let c) = cond { throw XLError(code: c) }
            if try bool(cond) { return args.count > 1 ? op(1) : .value(.bool(true)) }
            return args.count > 2 ? op(2) : .value(.bool(false))
        case "IFS":
            for i in stride(from: 0, to: args.count - 1, by: 2) where try bool(a(i)) { return op(i + 1) }
            throw XLError.na
        case "AND", "OR", "XOR":
            var results: [Bool] = []
            for arg in args {
                for v in values(eval(arg, sheet: sheet, at: at)) {
                    if case .error(let c) = v { throw XLError(code: c) }
                    if v.isEmpty { continue }
                    if case .string = v, isReference(arg) { continue }
                    results.append(try bool(v))
                }
            }
            guard !results.isEmpty else { throw XLError.value }
            if name == "AND" { return .value(.bool(results.allSatisfy { $0 })) }
            if name == "OR" { return .value(.bool(results.contains(true))) }
            return .value(.bool(results.filter { $0 }.count % 2 == 1))
        case "NOT": return .value(.bool(!(try bool(a(0)))))
        case "TRUE": return .value(.bool(true))
        case "FALSE": return .value(.bool(false))
        case "SWITCH":
            try need(3)
            let v = a(0)
            var i = 1
            while i + 1 < args.count {
                if compare(v, a(i)) == 0 { return op(i + 1) }
                i += 2
            }
            if i < args.count { return op(i) }
            throw XLError.na
        case "CHOOSE":
            let i = Int(try n(0))
            guard i >= 1, i < args.count else { throw XLError.value }
            return op(i)

        // Lookup
        case "VLOOKUP", "HLOOKUP":
            try need(3)
            let needle = a(0)
            let table = matrix(op(1))
            let index = Int(try n(2)) - 1
            let approx = args.count > 3 ? try bool(a(3)) : true
            let vertical = name == "VLOOKUP"
            guard index >= 0, index < (vertical ? table.cols : table.rows) else { throw XLError.ref }
            let hay = vertical ? (0..<table.rows).map { table[$0, 0] } : (0..<table.cols).map { table[0, $0] }
            guard let pos = lookupIndex(needle, in: hay, mode: approx ? 1 : 0) else { throw XLError.na }
            return .value(vertical ? table[pos, index] : table[index, pos])
        case "MATCH":
            try need(2)
            let m = matrix(op(1))
            let mode = Int(try n(2, 1))
            let needles = op(0)
            if needles.isMulti {
                return elementwise([needles]) { v in
                    guard let pos = self.lookupIndex(v[0], in: m.values, mode: mode < 0 ? -1 : mode > 0 ? 1 : 0) else { throw XLError.na }
                    return .number(Double(pos + 1))
                }
            }
            guard let pos = lookupIndex(a(0), in: m.values, mode: mode < 0 ? -1 : mode > 0 ? 1 : 0) else { throw XLError.na }
            return .value(.number(Double(pos + 1)))
        case "ROW", "COLUMN":
            if args.isEmpty { return .value(.number(Double((name == "ROW" ? at.row : at.col) + 1))) }
            if case .ref(_, let p) = args[0] { return .value(.number(Double((name == "ROW" ? p.row : p.col) + 1))) }
            if case .range(_, let p, _) = args[0] { return .value(.number(Double((name == "ROW" ? p.row : p.col) + 1))) }
            if case .matrix(_, let o?) = op(0) { return .value(.number(Double((name == "ROW" ? o.row : o.col) + 1))) }
            throw XLError.value
        case "ROWS", "COLUMNS":
            let m = matrix(op(0))
            return .value(.number(Double(name == "ROWS" ? m.rows : m.cols)))
        case "INDIRECT":
            var refText = try t(0)
            if args.count > 1, !(try bool(a(1))) { refText = try Self.r1c1ToA1(refText, at: at) }
            guard let e = try? Formula.parse("=" + refText) else { throw XLError.ref }
            switch e {
            case .ref, .range: return eval(e, sheet: sheet, at: at)
            case .name: return eval(e, sheet: sheet, at: at)
            default: throw XLError.ref
            }
        case "OFFSET":
            try need(3)
            guard case .ref(let sn, let p) = args[0] else {
                if case .range(let sn, let p, let q) = args[0] {
                    let dr = Int(try n(1)), dc = Int(try n(2))
                    let h = Int(try n(3, Double(abs(q.row - p.row) + 1))), w = Int(try n(4, Double(abs(q.col - p.col) + 1)))
                    let s = try sheetIndex(sn, sheet)
                    let a1 = RefPart(row: p.row + dr, col: p.col + dc), b1 = RefPart(row: p.row + dr + h - 1, col: p.col + dc + w - 1)
                    guard a1.row >= 0, a1.col >= 0 else { throw XLError.ref }
                    let (m, o) = rangeMatrix(sheet: s, a1, b1)
                    return .matrix(m, origin: o)
                }
                throw XLError.value
            }
            let dr = Int(try n(1)), dc = Int(try n(2)), h = Int(try n(3, 1)), w = Int(try n(4, 1))
            let s = try sheetIndex(sn, sheet)
            let a1 = RefPart(row: p.row + dr, col: p.col + dc), b1 = RefPart(row: p.row + dr + h - 1, col: p.col + dc + w - 1)
            guard a1.row >= 0, a1.col >= 0, h > 0, w > 0 else { throw XLError.ref }
            let (m, o) = rangeMatrix(sheet: s, a1, b1)
            return .matrix(m, origin: o)

        // Text
        case "LEN": return .value(.number(Double(try t(0).count)))
        case "LEFT", "RIGHT":
            let s = try t(0)
            let k = Int(try n(1, 1))
            guard k >= 0 else { throw XLError.value }
            return .value(.string(String(name == "LEFT" ? s.prefix(k) : s.suffix(k))))
        case "MID":
            let s = Array(try t(0))
            let start = Int(try n(1)) - 1, len = Int(try n(2))
            guard start >= 0, len >= 0 else { throw XLError.value }
            guard start < s.count else { return .value(.string("")) }
            return .value(.string(String(s[start..<min(s.count, start + len)])))
        case "UPPER": return .value(.string(try t(0).uppercased()))
        case "LOWER": return .value(.string(try t(0).lowercased()))
        case "TRIM": return .value(.string(try t(0).split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")))
        case "CONCATENATE", "CONCAT":
            var s = ""
            for arg in args {
                for v in values(eval(arg, sheet: sheet, at: at)) {
                    if case .error(let c) = v { throw XLError(code: c) }
                    s += text(v)
                }
            }
            return .value(.string(s))
        case "TEXTJOIN":
            try need(3)
            let delim = try t(0), skip = try bool(a(1))
            var parts: [String] = []
            for arg in args.dropFirst(2) {
                for v in values(eval(arg, sheet: sheet, at: at)) {
                    if case .error(let c) = v { throw XLError(code: c) }
                    let s = text(v)
                    if skip && s.isEmpty { continue }
                    parts.append(s)
                }
            }
            return .value(.string(parts.joined(separator: delim)))
        case "SUBSTITUTE":
            let s = try t(0), old = try t(1), new = try t(2)
            guard !old.isEmpty else { return .value(.string(s)) }
            if args.count > 3 {
                let k = Int(try n(3))
                var count = 0
                var result = ""
                var rest = Substring(s)
                while let range = rest.range(of: old) {
                    count += 1
                    result += rest[..<range.lowerBound]
                    result += count == k ? new : old
                    rest = rest[range.upperBound...]
                }
                return .value(.string(result + rest))
            }
            return .value(.string(s.replacingOccurrences(of: old, with: new)))
        case "REPLACE":
            var s = Array(try t(0))
            let start = max(0, Int(try n(1)) - 1), len = max(0, Int(try n(2)))
            let new = Array(try t(3))
            let lo = min(start, s.count), hi = min(s.count, start + len)
            s.replaceSubrange(lo..<hi, with: new)
            return .value(.string(String(s)))
        case "FIND", "SEARCH":
            let needle = try t(0), hay = try t(1)
            let start = Int(try n(2, 1)) - 1
            guard start >= 0, start <= hay.count else { throw XLError.value }
            let from = hay.index(hay.startIndex, offsetBy: start)
            let range: Range<String.Index>?
            if name == "SEARCH" {
                if needle.contains(where: { "*?".contains($0) }), let re = wildcardRegex(needle, anchored: false),
                   let m = re.firstMatch(in: hay, range: NSRange(from..., in: hay)) {
                    range = Range(m.range, in: hay)
                } else {
                    range = hay.range(of: needle, options: .caseInsensitive, range: from..<hay.endIndex)
                }
            } else {
                range = hay.range(of: needle, range: from..<hay.endIndex)
            }
            guard let range else { throw XLError.value }
            return .value(.number(Double(hay.distance(from: hay.startIndex, to: range.lowerBound) + 1)))
        case "REPT":
            let k = Int(try n(1))
            guard k >= 0 else { throw XLError.value }
            return .value(.string(String(repeating: try t(0), count: k)))
        case "EXACT": return .value(.bool(try t(0) == t(1)))
        case "CHAR": return .value(.string(String(UnicodeScalar(UInt8(max(1, min(255, Int(try n(0)))))))))
        case "UNICHAR":
            guard let u = UnicodeScalar(Int(try n(0))) else { throw XLError.value }
            return .value(.string(String(u)))
        case "CODE", "UNICODE":
            guard let u = try t(0).unicodeScalars.first else { throw XLError.value }
            return .value(.number(Double(u.value)))
        case "T":
            if case .string(let s) = a(0) { return .value(.string(s)) }
            return .value(.string(""))
        case "N":
            switch a(0) { case .number(let d): return .value(.number(d)); case .bool(let b): return .value(.number(b ? 1 : 0)); default: return .value(.number(0)) }
        case "TEXT":
            let v = a(0)
            if case .error(let c) = v { throw XLError(code: c) }
            return .value(.string(NumberFormat.format(v, try t(1), date1904: workbook.date1904).text))
        case "VALUE":
            let v = a(0)
            if case .number = v { return .value(v) }
            guard let d = parseNumber(text(v)) else { throw XLError.value }
            return .value(.number(d))

        // Dates
        case "TODAY": return .value(.number(floor(DateMath.serial(Date()))))
        case "NOW": return .value(.number(DateMath.serial(Date())))
        case "DATE":
            guard let s = DateMath.serial(year: Int(try n(0)), month: Int(try n(1)), day: Int(try n(2))) else { throw XLError.num }
            return .value(.number(s))
        case "TIME":
            return try r(((try n(0)) * 3600 + (try n(1)) * 60 + (try n(2))).truncatingRemainder(dividingBy: 86400) / 86400)
        case "YEAR", "MONTH", "DAY", "WEEKDAY":
            let serial = try n(0)
            guard serial >= 0, let c = DateMath.components(serial) else { throw XLError.num }
            switch name {
            case "YEAR": return .value(.number(Double(c.year!)))
            case "MONTH": return .value(.number(Double(c.month!)))
            case "DAY": return .value(.number(Double(c.day!)))
            default:
                let w = c.weekday!   // 1 = Sunday
                let type = Int(try n(1, 1))
                switch type {
                case 1, 17: return .value(.number(Double(w)))
                case 2, 11: return .value(.number(Double((w + 5) % 7 + 1)))
                case 3: return .value(.number(Double((w + 5) % 7)))
                case 12...16: return .value(.number(Double(((w + 5) % 7 - (type - 11) + 7) % 7 + 1)))
                default: throw XLError.num
                }
            }
        case "HOUR", "MINUTE", "SECOND":
            let f = try n(0)
            let secs = Int(((f - floor(f)) * 86400).rounded())
            return .value(.number(Double(name == "HOUR" ? secs / 3600 : name == "MINUTE" ? secs / 60 % 60 : secs % 60)))
        case "EDATE", "EOMONTH":
            guard let c = DateMath.components(try n(0)) else { throw XLError.num }
            let months = Int(try n(1))
            var y = c.year!, m = c.month! + months
            y += Int(floor(Double(m - 1) / 12)); m = ((m - 1) % 12 + 12) % 12 + 1
            let lastDay = DateMath.daysInMonth(year: y, month: m)
            let day = name == "EOMONTH" ? lastDay : min(c.day!, lastDay)
            guard let s = DateMath.serial(year: y, month: m, day: day) else { throw XLError.num }
            return .value(.number(s))
        case "DAYS": return try r(floor(n(0)) - floor(n(1)))
        case "DATEDIF":
            let s1 = try n(0), s2 = try n(1)
            guard s2 >= s1, let a1 = DateMath.components(s1), let b1 = DateMath.components(s2) else { throw XLError.num }
            var months = (b1.year! - a1.year!) * 12 + (b1.month! - a1.month!)
            if b1.day! < a1.day! { months -= 1 }
            switch try t(2).uppercased() {
            case "Y": return .value(.number(Double(months / 12)))
            case "M": return .value(.number(Double(months)))
            case "D": return .value(.number(floor(s2) - floor(s1)))
            case "YM": return .value(.number(Double(months % 12)))
            case "YD":
                var y = b1.year!
                if (b1.month!, b1.day!) < (a1.month!, a1.day!) { y -= 1 }
                guard let anniversary = DateMath.serial(year: y, month: a1.month!, day: min(a1.day!, DateMath.daysInMonth(year: y, month: a1.month!))) else { throw XLError.num }
                return .value(.number(floor(s2) - anniversary))
            case "MD":
                var d = b1.day! - a1.day!
                if d < 0 { d += DateMath.daysInMonth(year: b1.month! == 1 ? b1.year! - 1 : b1.year!, month: b1.month! == 1 ? 12 : b1.month! - 1) }
                return .value(.number(Double(d)))
            default: throw XLError.num
            }
        // Information
        case "ISBLANK": return .value(.bool(a(0).isEmpty))
        case "ISNUMBER": if case .number = a(0) { return .value(.bool(true)) }; return .value(.bool(false))
        case "ISTEXT": if case .string = a(0) { return .value(.bool(true)) }; return .value(.bool(false))
        case "ISLOGICAL": if case .bool = a(0) { return .value(.bool(true)) }; return .value(.bool(false))
        case "ISERROR": return .value(.bool(a(0).isError))
        case "ISERR": if case .error(let c) = a(0) { return .value(.bool(c != "#N/A")) }; return .value(.bool(false))
        case "ISNA": return .value(.bool(a(0) == .error("#N/A")))
        case "NA": throw XLError.na

        default:
            return try extended(name, args, sheet: sheet, at: at)
        }
    }
}

/// Excel serial dates (1900 system: day 1 = 1900-01-01, with the historic 1900 leap-year bug).
enum DateMath {
    static var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
    static let base = calendar.date(from: DateComponents(year: 1899, month: 12, day: 30))!

    static func serial(_ date: Date) -> Double {
        let local = date.addingTimeInterval(TimeInterval(TimeZone.current.secondsFromGMT(for: date)))
        return local.timeIntervalSince(base) / 86400
    }

    static func serial(year: Int, month: Int, day: Int) -> Double? {
        var y = year
        if y < 1900 { y += 1900 }
        guard let d = calendar.date(from: DateComponents(year: y, month: month, day: day)) else { return nil }
        let s = (d.timeIntervalSince(base) / 86400).rounded()
        return s >= 0 ? s : nil
    }

    static func date(_ serial: Double) -> Date { base.addingTimeInterval(serial * 86400) }

    static func components(_ serial: Double) -> DateComponents? {
        guard serial.isFinite, serial >= 0, serial < 3_000_000 else { return nil }
        return calendar.dateComponents([.year, .month, .day, .weekday, .hour, .minute, .second], from: date(floor(serial) + 0.000001))
    }

    static func daysInMonth(year: Int, month: Int) -> Int {
        calendar.range(of: .day, in: .month, for: calendar.date(from: DateComponents(year: year, month: month, day: 1))!)!.count
    }

    /// "31.12.2024", "2024-12-31", "12/31/2024", optional " 10:30".
    static func parse(_ s: String) -> Double? {
        let parts = s.split(separator: " ")
        guard let datePart = parts.first else { return nil }
        var y = 0, m = 0, d = 0
        let nums = datePart.split(whereSeparator: { ".-/".contains($0) }).compactMap { Int($0) }
        guard nums.count == 3 else { return parseTime(s) }
        if datePart.contains("-"), nums[0] > 31 { (y, m, d) = (nums[0], nums[1], nums[2]) }
        else if datePart.contains("/") { (m, d, y) = (nums[0], nums[1], nums[2]) }
        else { (d, m, y) = (nums[0], nums[1], nums[2]) }
        if y < 100 { y += y < 30 ? 2000 : 1900 }
        guard (1...12).contains(m), (1...31).contains(d), let base = serial(year: y, month: m, day: d) else { return nil }
        if parts.count > 1, let t = parseTime(String(parts[1])) { return base + t }
        return base
    }

    static func parseTime(_ s: String) -> Double? {
        let p = s.split(separator: ":").compactMap { Double($0) }
        guard p.count >= 2, p.count <= 3, p[0] < 24, p[1] < 60 else { return nil }
        return (p[0] * 3600 + p[1] * 60 + (p.count > 2 ? p[2] : 0)) / 86400
    }
}
