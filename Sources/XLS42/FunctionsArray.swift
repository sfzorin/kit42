import Foundation
import Kit42

/// Arguments of one function call, evaluated on demand.
struct FArgs {
    let c: Calculator
    let args: [Expr]
    let sheet: Int
    let at: CellRef

    var count: Int { args.count }
    func has(_ i: Int) -> Bool {
        guard i < args.count else { return false }
        if case .missing = args[i] { return false }
        return true
    }
    func op(_ i: Int) -> Operand { i < args.count ? c.eval(args[i], sheet: sheet, at: at) : .value(.empty) }
    func a(_ i: Int) -> Value { c.arg(args, i, sheet, at) }
    func n(_ i: Int, _ d: Double? = nil) throws -> Double { try c.numArg(args, i, sheet, at, default: d) }
    /// Whole number (truncated), within ±2^53.
    func int(_ i: Int, _ d: Double? = nil) throws -> Int {
        let v = try n(i, d)
        guard v.isFinite, abs(v) < 9e15 else { throw XLError.num }
        return Int(v.rounded(.towardZero))
    }
    func t(_ i: Int, _ d: String? = nil) throws -> String {
        if !has(i), let d { return d }
        return try c.textArg(args, i, sheet, at)
    }
    func b(_ i: Int, _ d: Bool) throws -> Bool {
        guard has(i) else { return d }
        return try c.bool(a(i))
    }
    func m(_ i: Int) -> Matrix { c.matrix(op(i)) }
    /// Numbers of argument i (from references only numbers; direct values coerced).
    func nums(_ i: Int) throws -> [Double] {
        guard has(i) else { throw XLError.value }
        return try c.numbers([args[i]], sheet: sheet, at: at)
    }
    func allNums(countText: Bool = false) throws -> [Double] { try c.numbers(args, sheet: sheet, at: at, countText: countText) }
    func need(_ k: Int) throws { if args.count < k { throw XLError.value } }
    func matrixOp(_ m: Matrix) -> Operand { .matrix(m, origin: nil) }
}

extension Calculator {
    /// Functions beyond the core set in `call` (arrays, statistics, finance, engineering…).
    func extended(_ name: String, _ args: [Expr], sheet: Int, at: CellRef) throws -> Operand {
        let x = FArgs(c: self, args: args, sheet: sheet, at: at)
        if let r = try arrayFunction(name, x) { return r }
        if let r = try statFunction(name, x) { return r }
        if let r = try mathFunction(name, x) { return r }
        if let r = try textDateFunction(name, x) { return r }
        if let r = try financeInfoFunction(name, x) { return r }
        if let r = try lambdaCall(name, x) { return r }
        throw XLError.name
    }

    // MARK: - Shared helpers

    /// Sort order of SORT/SORTBY: numbers < text < logical < errors; blanks last.
    func sortCompare(_ a: Value, _ b: Value) -> Int {
        if a.isEmpty != b.isEmpty { return a.isEmpty ? 1 : -1 }
        return compare(a, b)
    }

    /// Position (0-based) of a value for XMATCH/XLOOKUP.
    /// mode: 0 exact, -1 exact or next smaller, 1 exact or next larger, 2 wildcards; search: 1 forward, -1 backward.
    func xfind(_ needle: Value, in hay: [Value], mode: Int, search: Int) -> Int? {
        let order = search < 0 ? Array(hay.indices.reversed()) : Array(hay.indices)
        switch mode {
        case 2:
            let match = criterion(needle.isEmpty ? .string("") : needle)
            return order.first { match(hay[$0]) }
        case -1, 1:
            if let p = order.first(where: { !hay[$0].isEmpty && compare(hay[$0], needle) == 0 }) { return p }
            var best: Int?
            for i in order where !hay[i].isEmpty && !hay[i].isError && sameKind(hay[i], needle) && compare(hay[i], needle) == mode {
                if let b = best {
                    if compare(hay[i], hay[b]) * mode < 0 { best = i }
                } else { best = i }
            }
            return best
        default:
            return order.first { !hay[$0].isEmpty && compare(hay[$0], needle) == 0 && sameKind(hay[$0], needle) }
        }
    }

    func sameKind(_ a: Value, _ b: Value) -> Bool {
        switch (a, b) {
        case (.number, .number), (.string, .string), (.bool, .bool), (.error, .error): return true
        case (.empty, _), (_, .empty): return true
        default: return false
        }
    }

    /// Rows (or columns) of a matrix as arrays.
    func lines(_ m: Matrix, byColumn: Bool) -> [[Value]] {
        byColumn ? (0..<m.cols).map { m.column($0) } : (0..<m.rows).map { m.row($0) }
    }

    func fromLines(_ l: [[Value]], byColumn: Bool) -> Matrix {
        let m = Matrix(l)
        return byColumn ? m.transposed : m
    }

    // MARK: - Arrays and lookups

    func arrayFunction(_ name: String, _ x: FArgs) throws -> Operand? {
        switch name {
        case "FILTER":
            try x.need(2)
            let arr = x.m(0), inc = x.m(1)
            let byColumn: Bool
            if inc.cols == 1, inc.rows == arr.rows { byColumn = false }
            else if inc.rows == 1, inc.cols == arr.cols { byColumn = true }
            else { throw XLError.value }
            var keep: [[Value]] = []
            let ls = lines(arr, byColumn: byColumn)
            for (i, line) in ls.enumerated() {
                let v = inc.values[i]
                if case .error(let e) = v { throw XLError(code: e) }
                if case .string = v { throw XLError.value }
                if try bool(v) { keep.append(line) }
            }
            guard !keep.isEmpty else {
                if x.has(2) { return x.op(2) }
                throw XLError.calc
            }
            return x.matrixOp(fromLines(keep, byColumn: byColumn))
        case "SORT":
            try x.need(1)
            let m = x.m(0)
            let byColumn = try x.b(3, false)
            let key = x.has(1) ? try x.int(1) : 1
            let order = x.has(2) ? try x.n(2) : 1
            guard order == 1 || order == -1 else { throw XLError.value }
            guard key >= 1, key <= (byColumn ? m.rows : m.cols) else { throw XLError.value }
            let ls = lines(m, byColumn: byColumn)
            let sorted = ls.enumerated().sorted { p, q in
                let c = sortCompare(p.element[key - 1], q.element[key - 1])
                if c == 0 { return p.offset < q.offset }
                if p.element[key - 1].isEmpty || q.element[key - 1].isEmpty { return c < 0 }
                return order > 0 ? c < 0 : c > 0
            }.map(\.element)
            return x.matrixOp(fromLines(sorted, byColumn: byColumn))
        case "SORTBY":
            try x.need(2)
            let m = x.m(0)
            var keys: [(Matrix, Double)] = []
            var i = 1
            while i < x.count {
                let k = x.m(i)
                let order = x.has(i + 1) ? try x.n(i + 1) : 1
                guard order == 1 || order == -1 else { throw XLError.value }
                keys.append((k, order))
                i += 2
            }
            guard let first = keys.first else { throw XLError.value }
            let byColumn = first.0.rows == 1 && first.0.cols == m.cols && m.rows != first.0.count
            let n = byColumn ? m.cols : m.rows
            guard keys.allSatisfy({ $0.0.count == n && ($0.0.rows == 1 || $0.0.cols == 1) }) else { throw XLError.value }
            let ls = lines(m, byColumn: byColumn)
            let idx = (0..<n).sorted { p, q in
                for (k, order) in keys {
                    let c = sortCompare(k.values[p], k.values[q])
                    if c != 0 {
                        if k.values[p].isEmpty || k.values[q].isEmpty { return c < 0 }
                        return order > 0 ? c < 0 : c > 0
                    }
                }
                return p < q
            }
            return x.matrixOp(fromLines(idx.map { ls[$0] }, byColumn: byColumn))
        case "UNIQUE":
            try x.need(1)
            let m = x.m(0)
            let byColumn = try x.b(1, false), once = try x.b(2, false)
            let ls = lines(m, byColumn: byColumn)
            func same(_ a: [Value], _ b: [Value]) -> Bool { zip(a, b).allSatisfy { compare($0, $1) == 0 && sameKind($0, $1) } }
            var groups: [([Value], Int)] = []
            for l in ls {
                if let i = groups.firstIndex(where: { same($0.0, l) }) { groups[i].1 += 1 } else { groups.append((l, 1)) }
            }
            let out = groups.filter { !once || $0.1 == 1 }.map(\.0)
            guard !out.isEmpty else { throw XLError.calc }
            return x.matrixOp(fromLines(out, byColumn: byColumn))
        case "SEQUENCE":
            try x.need(1)
            let rows = try x.int(0, 1), cols = try x.int(1, 1)
            let start = try x.n(2, 1), step = try x.n(3, 1)
            guard rows >= 1, cols >= 1 else { throw XLError.calc }
            guard rows <= Self.maximumMatrixCells / cols else { throw XLError.num }
            return x.matrixOp(Matrix(rows: rows, cols: cols, values: (0..<(rows * cols)).map { i in
                let value = start + Double(i) * step
                return value.isFinite ? .number(value) : .error("#NUM!")
            }))
        case "RANDARRAY":
            let rows = try x.int(0, 1), cols = try x.int(1, 1)
            let lo = try x.n(2, 0), hi = try x.n(3, 1), integer = try x.b(4, false)
            guard rows >= 1, cols >= 1 else { throw XLError.calc }
            guard lo <= hi else { throw XLError.value }
            guard rows <= Self.maximumMatrixCells / cols else { throw XLError.num }
            var integerBounds: ClosedRange<Int>?
            if integer {
                let lower = try Self.integer(lo.rounded(.up)), upper = try Self.integer(hi.rounded(.down))
                guard lower <= upper else { throw XLError.num }
                integerBounds = lower...upper
            } else {
                guard (hi - lo).isFinite else { throw XLError.num }
            }
            return x.matrixOp(Matrix(rows: rows, cols: cols, values: (0..<(rows * cols)).map { _ in
                if let bounds = integerBounds { return .number(Double(Int.random(in: bounds))) }
                return .number(lo == hi ? lo : Double.random(in: lo..<hi))
            }))
        case "TRANSPOSE":
            try x.need(1)
            return x.matrixOp(x.m(0).transposed)
        case "TOCOL", "TOROW":
            let m = x.m(0)
            let ignore = try x.int(1, 0), byColumn = try x.b(2, false)
            var out: [Value] = byColumn ? m.transposed.values : m.values
            if ignore == 1 || ignore == 3 { out.removeAll { $0.isEmpty } }
            if ignore == 2 || ignore == 3 { out.removeAll { $0.isError } }
            guard !out.isEmpty else { throw XLError.calc }
            return x.matrixOp(name == "TOCOL" ? Matrix(rows: out.count, cols: 1, values: out) : Matrix(rows: 1, cols: out.count, values: out))
        case "VSTACK", "HSTACK":
            var parts = (0..<x.count).filter(x.has).map { x.m($0) }
            guard !parts.isEmpty else { throw XLError.value }
            if name == "HSTACK" { parts = parts.map(\.transposed) }
            let w = parts.map(\.cols).max()!
            guard w > 0, parts.reduce(0, { $0 + $1.rows }) <= Self.maximumMatrixCells / w else { throw XLError.num }
            var rows: [[Value]] = []
            for p in parts { for r in 0..<p.rows { rows.append(p.row(r) + Array(repeating: .error("#N/A"), count: w - p.cols)) } }
            let out = Matrix(rows)
            return x.matrixOp(name == "HSTACK" ? out.transposed : out)
        case "CHOOSECOLS", "CHOOSEROWS":
            try x.need(2)
            let m = x.m(0)
            let byColumn = name == "CHOOSECOLS"
            let ls = lines(m, byColumn: byColumn)
            var picked: [[Value]] = []
            for i in 1..<x.count {
                for v in x.m(i).values {
                    var k = try Self.integer(num(v))
                    if k < 0 { k = ls.count + k + 1 }
                    guard k >= 1, k <= ls.count else { throw XLError.value }
                    guard ls[k - 1].isEmpty || picked.count < Self.maximumMatrixCells / ls[k - 1].count else { throw XLError.num }
                    picked.append(ls[k - 1])
                }
            }
            return x.matrixOp(fromLines(picked, byColumn: byColumn))
        case "TAKE", "DROP":
            try x.need(2)
            let m = x.m(0)
            var rows = Array(0..<m.rows), cols = Array(0..<m.cols)
            func cut(_ a: [Int], _ k: Int) -> [Int] {
                if name == "TAKE" { return k >= 0 ? Array(a.prefix(k)) : Array(a.suffix(-k)) }
                return k >= 0 ? Array(a.dropFirst(k)) : Array(a.dropLast(-k))
            }
            if x.has(1) { rows = cut(rows, try x.int(1)) }
            if x.has(2) { cols = cut(cols, try x.int(2)) }
            guard !rows.isEmpty, !cols.isEmpty else { throw XLError.calc }
            return x.matrixOp(Matrix(rows.map { r in cols.map { m[r, $0] } }))
        case "EXPAND":
            try x.need(2)
            let m = x.m(0)
            let rows = x.has(1) ? try x.int(1) : m.rows, cols = x.has(2) ? try x.int(2) : m.cols
            guard rows >= m.rows, cols >= m.cols else { throw XLError.value }
            guard cols > 0, rows <= Self.maximumMatrixCells / cols else { throw XLError.num }
            let pad = x.has(3) ? x.a(3) : .error("#N/A")
            return x.matrixOp(Matrix((0..<rows).map { r in (0..<cols).map { c in r < m.rows && c < m.cols ? m[r, c] : pad } }))
        case "WRAPROWS", "WRAPCOLS":
            try x.need(2)
            let v = x.m(0)
            guard v.rows == 1 || v.cols == 1 else { throw XLError.value }
            let k = try x.int(1)
            guard k >= 1, k <= Self.maximumMatrixCells, (v.count + k - 1) / k <= Self.maximumMatrixCells / k else { throw XLError.num }
            let pad = x.has(2) ? x.a(2) : .error("#N/A")
            var ls: [[Value]] = []
            var i = 0
            while i < v.count {
                var l = Array(v.values[i..<min(v.count, i + k)])
                l += Array(repeating: pad, count: k - l.count)
                ls.append(l)
                i += k
            }
            return x.matrixOp(fromLines(ls, byColumn: name == "WRAPCOLS"))
        case "XMATCH":
            try x.need(2)
            let hay = x.m(1)
            guard hay.rows == 1 || hay.cols == 1 else { throw XLError.value }
            let mode = try x.int(2, 0), search = try x.int(3, 1)
            guard [0, -1, 1, 2].contains(mode), [1, -1, 2, -2].contains(search) else { throw XLError.value }
            let needles = x.op(0)
            if needles.isMulti {
                return elementwise([needles]) { v in
                    guard let p = self.xfind(v[0], in: hay.values, mode: mode, search: search) else { throw XLError.na }
                    return .number(Double(p + 1))
                }
            }
            guard let p = xfind(x.a(0), in: hay.values, mode: mode, search: search) else { throw XLError.na }
            return .value(.number(Double(p + 1)))
        case "XLOOKUP":
            try x.need(3)
            let hay = x.m(1), results = x.m(2)
            guard hay.rows == 1 || hay.cols == 1 else { throw XLError.value }
            let mode = try x.int(4, 0), search = try x.int(5, 1)
            guard [0, -1, 1, 2].contains(mode), [1, -1, 2, -2].contains(search) else { throw XLError.value }
            let vertical = hay.cols == 1 && hay.rows > 1 || (hay.count == 1 && results.cols >= results.rows)
            guard vertical ? results.rows == hay.count : results.cols == hay.count else { throw XLError.value }
            guard let p = xfind(x.a(0), in: hay.values, mode: mode, search: search) else {
                if x.has(3) { return x.op(3) }
                throw XLError.na
            }
            if vertical {
                if results.cols == 1 { return .value(results[p, 0]) }
                return x.matrixOp(Matrix(rows: 1, cols: results.cols, values: results.row(p)))
            }
            if results.rows == 1 { return .value(results[0, p]) }
            return x.matrixOp(Matrix(rows: results.rows, cols: 1, values: results.column(p)))
        case "LOOKUP":
            try x.need(2)
            let needle = x.a(0)
            if case .error(let e) = needle { throw XLError(code: e) }
            let m = x.m(1)
            let hay: [Value], result: [Value]
            if x.has(2) {
                hay = m.values
                result = x.m(2).values
            } else if m.cols > m.rows {
                hay = m.row(0); result = m.row(m.rows - 1)
            } else {
                hay = m.column(0); result = m.column(m.cols - 1)
            }
            // Largest value ≤ the one looked up (same type), last such position — like Excel's binary search on sorted data.
            var pos: Int?
            for (i, v) in hay.enumerated() where !v.isEmpty && !v.isError && sameKind(v, needle) && compare(v, needle) <= 0 {
                if let p = pos, compare(v, hay[p]) < 0 { continue }
                pos = i
            }
            guard let p = pos, p < result.count else { throw XLError.na }
            return .value(result[p])
        case "ADDRESS":
            try x.need(2)
            let row = try x.int(0), col = try x.int(1)
            let absNum = try x.int(2, 1), a1 = try x.b(3, true)
            guard row >= 1, col >= 1, row <= RefPart.maxRow + 1, col <= RefPart.maxCol + 1, (1...4).contains(absNum) else { throw XLError.value }
            var text: String
            if a1 {
                let absRow = absNum == 1 || absNum == 2, absCol = absNum == 1 || absNum == 3
                text = (absCol ? "$" : "") + CellRef.columnName(col - 1) + (absRow ? "$" : "") + "\(row)"
            } else {
                let absRow = absNum == 1 || absNum == 2, absCol = absNum == 1 || absNum == 3
                text = "R" + (absRow ? "\(row)" : "[\(row)]") + "C" + (absCol ? "\(col)" : "[\(col)]")
            }
            if x.has(4) {
                let s = try x.t(4)
                if !s.isEmpty { text = Formula.sheetPrefix(s) + text }
            }
            return .value(.string(text))
        case "INDEX":
            try x.need(2)
            let o = x.op(0)
            let m = matrix(o)
            var origin: CellRef?
            if case .matrix(_, let org) = o { origin = org }
            var row = x.has(1) ? try x.int(1) : 0, col = x.has(2) ? try x.int(2) : 0
            if x.count == 2 || !x.has(2), m.rows == 1, m.cols > 1 { col = row; row = 1 }
            if col == 0, m.cols == 1 { col = 1 }
            if row == 0, m.rows == 1 { row = 1 }
            guard row >= 0, col >= 0, row <= m.rows, col <= m.cols else { throw XLError.ref }
            if row == 0, col == 0 { return o }
            if row == 0 {
                return .matrix(Matrix(rows: m.rows, cols: 1, values: m.column(col - 1)), origin: origin.map { CellRef(row: $0.row, col: $0.col + col - 1) })
            }
            if col == 0 {
                return .matrix(Matrix(rows: 1, cols: m.cols, values: m.row(row - 1)), origin: origin.map { CellRef(row: $0.row + row - 1, col: $0.col) })
            }
            return .matrix(Matrix(rows: 1, cols: 1, values: [m[row - 1, col - 1]]), origin: origin.map { CellRef(row: $0.row + row - 1, col: $0.col + col - 1) })
        case "MMULT":
            try x.need(2)
            let a = try numericMatrix(x.m(0)), b = try numericMatrix(x.m(1))
            guard a.cols == b.rows else { throw XLError.value }
            guard b.cols > 0, a.rows <= Self.maximumMatrixCells / b.cols else { throw XLError.num }
            var out = [Value]()
            for i in 0..<a.rows {
                for j in 0..<b.cols {
                    var s = 0.0
                    for k in 0..<a.cols { s += a.v[i * a.cols + k] * b.v[k * b.cols + j] }
                    out.append(s.isFinite ? .number(s) : .error("#NUM!"))
                }
            }
            return x.matrixOp(Matrix(rows: a.rows, cols: b.cols, values: out))
        case "MDETERM":
            let a = try numericMatrix(x.m(0))
            guard a.rows == a.cols else { throw XLError.value }
            return .value(.number(LinearAlgebra.determinant(a.v, a.rows)))
        case "MINVERSE":
            let a = try numericMatrix(x.m(0))
            guard a.rows == a.cols else { throw XLError.value }
            guard let inv = LinearAlgebra.inverse(a.v, a.rows) else { throw XLError.num }
            return x.matrixOp(Matrix(rows: a.rows, cols: a.rows, values: inv.map { .number($0) }))
        case "MUNIT":
            let n = try x.int(0)
            guard n >= 1 else { throw XLError.value }
            guard n <= Self.maximumMatrixCells / n else { throw XLError.num }
            return x.matrixOp(Matrix(rows: n, cols: n, values: (0..<(n * n)).map { .number($0 / n == $0 % n ? 1 : 0) }))
        case "FREQUENCY":
            try x.need(2)
            let data = try x.nums(0), bins = try x.nums(1).sorted()
            var counts = Array(repeating: 0.0, count: bins.count + 1)
            for d in data {
                if let i = bins.firstIndex(where: { d <= $0 }) { counts[i] += 1 } else { counts[bins.count] += 1 }
            }
            // Counts follow the order of the bins as given.
            let given = try x.nums(1)
            var out = given.map { b -> Double in counts[bins.firstIndex(of: b)!] }
            // Duplicate bins count once (the first gets the values).
            var seen = Set<Double>()
            for (i, b) in given.enumerated() { if !seen.insert(b).inserted { out[i] = 0 } }
            out.append(counts[bins.count])
            return x.matrixOp(Matrix(rows: out.count, cols: 1, values: out.map { .number($0) }))
        default:
            return nil
        }
    }

    /// All numbers or #VALUE!.
    func numericMatrix(_ m: Matrix) throws -> (rows: Int, cols: Int, v: [Double]) {
        var v: [Double] = []
        v.reserveCapacity(m.count)
        for x in m.values {
            switch x {
            case .number(let d): v.append(d)
            case .error(let e): throw XLError(code: e)
            default: throw XLError.value
            }
        }
        return (m.rows, m.cols, v)
    }

    // MARK: - LET and LAMBDA

    func lambdaCall(_ name: String, _ x: FArgs) throws -> Operand? {
        switch name {
        case "LET":
            guard x.count >= 3, x.count % 2 == 1 else { throw XLError.value }
            locals.append([:])
            defer { locals.removeLast() }
            for i in stride(from: 0, to: x.count - 1, by: 2) {
                guard case .name(let n) = x.args[i] else { throw XLError.value }
                let v = x.op(i + 1)
                locals[locals.count - 1][n.uppercased()] = v
            }
            return x.op(x.count - 1)
        case "LAMBDA":
            throw XLError.calc
        default:
            // A defined name holding LAMBDA(params…, body) works as a function.
            guard let def = workbook.names.first(where: { $0.key.caseInsensitiveCompare(name) == .orderedSame })?.value,
                  let e = Self.expression("=" + def), case .call("LAMBDA", let parts) = e, !parts.isEmpty else { return nil }
            let params = parts.dropLast()
            guard x.count <= params.count else { throw XLError.value }
            var scope: [String: Operand] = [:]
            for (i, p) in params.enumerated() {
                guard case .name(let n) = p else { throw XLError.value }
                scope[n.uppercased()] = x.has(i) ? x.op(i) : .value(.empty)
            }
            locals.append(scope)
            defer { locals.removeLast() }
            return eval(parts.last!, sheet: x.sheet, at: x.at)
        }
    }
}

/// Small dense linear algebra for MMULT/MINVERSE/LINEST (row-major n×n).
enum LinearAlgebra {
    static func determinant(_ a: [Double], _ n: Int) -> Double {
        var m = a, det = 1.0
        for c in 0..<n {
            var p = c
            for r in c..<n where abs(m[r * n + c]) > abs(m[p * n + c]) { p = r }
            if m[p * n + c] == 0 { return 0 }
            if p != c { for k in 0..<n { m.swapAt(p * n + k, c * n + k) }; det = -det }
            det *= m[c * n + c]
            for r in (c + 1)..<max(c + 1, n) {
                let f = m[r * n + c] / m[c * n + c]
                for k in c..<n { m[r * n + k] -= f * m[c * n + k] }
            }
        }
        return det
    }

    static func inverse(_ a: [Double], _ n: Int) -> [Double]? {
        var m = a
        var inv = (0..<(n * n)).map { $0 / n == $0 % n ? 1.0 : 0.0 }
        for c in 0..<n {
            var p = c
            for r in c..<n where abs(m[r * n + c]) > abs(m[p * n + c]) { p = r }
            guard abs(m[p * n + c]) > 1e-300 else { return nil }
            if p != c { for k in 0..<n { m.swapAt(p * n + k, c * n + k); inv.swapAt(p * n + k, c * n + k) } }
            let d = m[c * n + c]
            for k in 0..<n { m[c * n + k] /= d; inv[c * n + k] /= d }
            for r in 0..<n where r != c {
                let f = m[r * n + c]
                guard f != 0 else { continue }
                for k in 0..<n { m[r * n + k] -= f * m[c * n + k]; inv[r * n + k] -= f * inv[c * n + k] }
            }
        }
        return inv
    }

    /// Least squares fit y ≈ X·β (X n×k row-major). Returns β and (XᵀX)⁻¹.
    static func leastSquares(_ X: [Double], n: Int, k: Int, _ y: [Double]) -> (beta: [Double], xtxInv: [Double])? {
        var xtx = Array(repeating: 0.0, count: k * k), xty = Array(repeating: 0.0, count: k)
        for i in 0..<n {
            for a in 0..<k {
                xty[a] += X[i * k + a] * y[i]
                for b in 0..<k { xtx[a * k + b] += X[i * k + a] * X[i * k + b] }
            }
        }
        guard let inv = inverse(xtx, k) else { return nil }
        var beta = Array(repeating: 0.0, count: k)
        for a in 0..<k { for b in 0..<k { beta[a] += inv[a * k + b] * xty[b] } }
        return (beta, inv)
    }
}
