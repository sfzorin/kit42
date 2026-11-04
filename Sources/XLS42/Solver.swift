import Foundation
import Kit42

/// Tools › Solver model: an objective cell to maximise/minimise/reach, variable cells and constraints.
struct SolverModel {
    enum Goal: Equatable { case max, min, value(Double) }
    enum Op: String, CaseIterable { case le = "<=", ge = ">=", eq = "=", int = "int", bin = "bin" }
    struct Constraint: Equatable {
        var lhs: CellRange
        var op: Op
        /// Number or reference ("10", "$D$2", "D2:D4").
        var rhs: String = ""
    }
    var objective: CellRef
    var goal: Goal = .max
    var variables: [CellRef]
    var constraints: [Constraint] = []
    var nonNegative = true
    /// Linear engine (simplex, branch and bound for integers); nonlinear models use Nelder–Mead.
    var linear = true
}

struct SolverResult {
    enum Status { case optimal, infeasible, unbounded, approximate, failed }
    var values: [Double]
    var objective: Double
    var status: Status
    var engine: String
}

enum Solver {
    /// The model as functions of the variable vector: objective and constraint rows g(x) op 0.
    struct Problem {
        var n: Int
        var objective: ([Double]) -> Double?
        var rows: [(g: ([Double]) -> Double?, op: SolverModel.Op)]
        var integer: Set<Int>
        var binary: Set<Int>
    }

    static func problem(_ wb: Workbook, sheet si: Int, model: SolverModel) -> Problem? {
        let vars = model.variables
        // One recalculation per point; values of all needed cells at once.
        var cacheKey: [Double] = [], cache: [CellRef: Value] = [:]
        var needed = Set([model.objective])
        var rhsRefs: [[CellRef]?] = []
        for c in model.constraints {
            needed.formUnion(c.lhs.cells)
            if let r = CellRange(c.rhs.replacingOccurrences(of: "$", with: "")) { needed.formUnion(r.cells); rhsRefs.append(r.cells) } else { rhsRefs.append(nil) }
        }
        func values(_ x: [Double]) -> [CellRef: Value] {
            if x == cacheKey { return cache }
            var w = wb
            for (ref, v) in zip(vars, x) {
                var c = w.sheets[si][ref]
                c.input = Value.formatGeneral(v)
                c.value = .number(v)
                w.sheets[si][ref] = c
            }
            let calc = Calculator(w)
            var out: [CellRef: Value] = [:]
            for r in needed { out[r] = calc.value(sheet: si, ref: r) }
            cacheKey = x; cache = out
            return out
        }
        func num(_ v: Value?) -> Double? {
            switch v {
            case .number(let d)?: return d.isFinite ? d : nil
            case .empty?, .none: return 0
            case .bool(let b)?: return b ? 1 : 0
            default: return nil
            }
        }
        var rows: [(([Double]) -> Double?, SolverModel.Op)] = []
        var integer = Set<Int>(), binary = Set<Int>()
        for (k, c) in model.constraints.enumerated() {
            if c.op == .int || c.op == .bin {
                for ref in c.lhs.cells {
                    guard let i = vars.firstIndex(of: ref) else { return nil }
                    integer.insert(i)
                    if c.op == .bin { binary.insert(i) }
                }
                continue
            }
            let lhs = c.lhs.cells
            let constant = Double(c.rhs.replacingOccurrences(of: ",", with: "."))
            guard constant != nil || rhsRefs[k] != nil else { return nil }
            for (i, ref) in lhs.enumerated() {
                let rref: CellRef? = rhsRefs[k].map { $0.count == lhs.count ? $0[i] : $0[0] }
                rows.append(({ x in
                    let v = values(x)
                    guard let l = num(v[ref]) else { return nil }
                    let r = rref.map { num(v[$0]) } ?? constant
                    guard let r else { return nil }
                    return l - r
                }, c.op))
            }
        }
        for i in binary { rows.append(({ x in x[i] - 1 }, .le)) }
        let goal = model.goal
        let obj: ([Double]) -> Double? = { x in num(values(x)[model.objective]) }
        if case .value(let t) = goal {
            rows.append(({ x in obj(x).map { $0 - t } }, .eq))
        }
        return Problem(n: vars.count, objective: obj, rows: rows.map { ($0.0, $0.1) }, integer: integer, binary: binary)
    }

    static func solve(_ wb: Workbook, sheet si: Int, model: SolverModel) -> SolverResult? {
        guard !model.variables.isEmpty, let p = problem(wb, sheet: si, model: model) else { return nil }
        let sign: Double = model.goal == .min ? -1 : 1
        let isTarget: Bool = { if case .value = model.goal { return true }; return false }()
        if model.linear, let lin = linearize(p) {
            var result = simplexSolve(lin, maximize: lin.c.map { isTarget ? 0 : $0 * sign }, nonNegative: model.nonNegative, integer: p.integer)
            if result.status == .optimal || result.status == .infeasible || result.status == .unbounded {
                if let o = p.objective(result.values) { result.objective = o }
                return result
            }
        }
        return nelderMead(p, sign: isTarget ? 0 : sign, start: model.variables.map { ref in
            if case .number(let d) = wb.sheets[si][ref].value { return d }; return 0 }, nonNegative: model.nonNegative)
    }

    // MARK: - Linear models

    struct Linear {
        var c: [Double]          // objective coefficients
        var a: [[Double]]        // constraint rows: a·x + b0 op 0
        var b0: [Double]
        var ops: [SolverModel.Op]
    }

    /// Coefficients by finite differences; nil when the model isn't linear (checked at two other points).
    static func linearize(_ p: Problem) -> Linear? {
        let n = p.n
        let zero = Array(repeating: 0.0, count: n)
        func row(_ f: ([Double]) -> Double?) -> (coef: [Double], base: Double)? {
            guard let base = f(zero) else { return nil }
            var coef: [Double] = []
            for j in 0..<n {
                var e = zero; e[j] = 1
                guard let v = f(e) else { return nil }
                coef.append(v - base)
            }
            return (coef, base)
        }
        guard let obj = row(p.objective) else { return nil }
        var rows: [([Double], Double)] = []
        for r in p.rows { guard let x = row(r.g) else { return nil }; rows.append(x) }
        // Linearity check at two more points.
        for scale in [3.7, -1.3] {
            let x = (0..<n).map { Double($0 + 1) * scale }
            func ok(_ f: ([Double]) -> Double?, _ coef: [Double], _ base: Double) -> Bool {
                guard let v = f(x) else { return false }
                let predicted = base + zip(coef, x).map(*).reduce(0, +)
                return abs(v - predicted) <= 1e-7 * max(1, abs(v), abs(predicted))
            }
            guard ok(p.objective, obj.coef, obj.base) else { return nil }
            for (k, r) in p.rows.enumerated() { guard ok(r.g, rows[k].0, rows[k].1) else { return nil } }
        }
        return Linear(c: obj.coef, a: rows.map(\.0), b0: rows.map(\.1), ops: p.rows.map(\.op))
    }

    /// Simplex (two phases, Bland's rule) with branch and bound for integer variables.
    static func simplexSolve(_ lin: Linear, maximize c: [Double], nonNegative: Bool, integer: Set<Int>) -> SolverResult {
        let n = lin.c.count
        // Free variables become x = p − q.
        let cols = nonNegative ? n : 2 * n
        func expand(_ v: [Double]) -> [Double] { nonNegative ? v : v + v.map { -$0 } }
        func collapse(_ v: [Double]) -> [Double] { nonNegative ? v : (0..<n).map { v[$0] - v[$0 + n] } }
        var baseRows: [([Double], SolverModel.Op, Double)] = []
        for (k, a) in lin.a.enumerated() { baseRows.append((expand(a), lin.ops[k], -lin.b0[k])) }
        let objective = expand(c)

        var best: (x: [Double], value: Double)?
        var nodes = 0
        var unbounded = false
        func branch(_ extra: [([Double], SolverModel.Op, Double)]) {
            nodes += 1
            guard nodes < 4000 else { return }
            guard let (x, value, status) = LP.maximize(objective, rows: baseRows + extra, columns: cols) else { return }
            if status == .unbounded { unbounded = true; return }
            if let b = best, value <= b.value + 1e-9 { return }
            let xs = collapse(x)
            if let j = integer.sorted().first(where: { abs(xs[$0] - xs[$0].rounded()) > 1e-7 }) {
                let v = xs[j]
                var e = Array(repeating: 0.0, count: n); e[j] = 1
                branch(extra + [(expand(e), .le, floor(v))])
                branch(extra + [(expand(e), .ge, ceil(v))])
                return
            }
            best = (xs.enumerated().map { integer.contains($0.offset) ? $0.element.rounded() : $0.element }, value)
        }
        branch([])
        if let best { return SolverResult(values: best.x, objective: best.value, status: .optimal, engine: "simplex") }
        return SolverResult(values: Array(repeating: 0, count: n), objective: 0, status: unbounded ? .unbounded : .infeasible, engine: "simplex")
    }

    // MARK: - Nonlinear models

    static func nelderMead(_ p: Problem, sign: Double, start: [Double], nonNegative: Bool) -> SolverResult {
        func violation(_ x: [Double]) -> Double {
            var v = 0.0
            if nonNegative { for xi in x where xi < 0 { v += xi * xi } }
            for r in p.rows {
                guard let g = r.g(x) else { return .infinity }
                switch r.op {
                case .le: if g > 0 { v += g * g }
                case .ge: if g < 0 { v += g * g }
                default: v += g * g
                }
            }
            return v
        }
        func penalized(_ x: [Double], _ mu: Double) -> Double {
            guard let o = p.objective(x) else { return .infinity }
            return -sign * o + mu * violation(x)
        }
        var x = start.map { nonNegative ? max(0, $0) : $0 }
        var mu = 10.0
        for _ in 0..<8 {
            x = minimize({ penalized($0, mu) }, from: x)
            if violation(x) < 1e-12 { break }
            mu *= 100
        }
        // Integer variables: round, then improve one step at a time.
        if !p.integer.isEmpty {
            for j in p.integer { x[j] = x[j].rounded() }
            var improved = true, rounds = 0
            while improved, rounds < 200 {
                improved = false; rounds += 1
                let current = penalized(x, 1e6)
                for j in p.integer {
                    for d in [-1.0, 1.0] {
                        var y = x; y[j] += d
                        if penalized(y, 1e6) < current - 1e-12 { x = y; improved = true; break }
                    }
                }
            }
        }
        let feasible = violation(x) < 1e-8
        return SolverResult(values: x, objective: p.objective(x) ?? 0, status: feasible ? .approximate : .infeasible, engine: "Nelder–Mead")
    }

    /// Nelder–Mead downhill simplex with restarts.
    static func minimize(_ f: ([Double]) -> Double, from start: [Double]) -> [Double] {
        let n = start.count
        var best = start
        for restart in 0..<4 {
            var simplex = [best]
            for i in 0..<n {
                var p = best
                p[i] += max(0.5, abs(p[i]) * 0.1) / Double(restart + 1)
                simplex.append(p)
            }
            var values = simplex.map(f)
            for _ in 0..<(400 * max(1, n)) {
                let order = values.indices.sorted { values[$0] < values[$1] }
                simplex = order.map { simplex[$0] }; values = order.map { values[$0] }
                if abs(values[n] - values[0]) <= 1e-13 * (abs(values[0]) + 1e-13) { break }
                var centroid = Array(repeating: 0.0, count: n)
                for p in simplex.dropLast() { for i in 0..<n { centroid[i] += p[i] / Double(n) } }
                func along(_ t: Double) -> [Double] { (0..<n).map { centroid[$0] + t * (simplex[n][$0] - centroid[$0]) } }
                let r = along(-1), fr = f(r)
                if fr < values[0] {
                    let e = along(-2), fe = f(e)
                    if fe < fr { simplex[n] = e; values[n] = fe } else { simplex[n] = r; values[n] = fr }
                } else if fr < values[n - 1] {
                    simplex[n] = r; values[n] = fr
                } else {
                    let k = along(fr < values[n] ? -0.5 : 0.5), fk = f(k)
                    if fk < min(fr, values[n]) { simplex[n] = k; values[n] = fk }
                    else {
                        for i in 1...n {
                            simplex[i] = (0..<n).map { simplex[0][$0] + 0.5 * (simplex[i][$0] - simplex[0][$0]) }
                            values[i] = f(simplex[i])
                        }
                    }
                }
            }
            let i = values.indices.min { values[$0] < values[$1] }!
            if f(simplex[i]) <= f(best) { best = simplex[i] }
        }
        return best
    }
}

/// Dense two-phase simplex: maximize c·x subject to rows (a·x op b), x ≥ 0.
enum LP {
    enum Status { case optimal, unbounded }

    static func maximize(_ c: [Double], rows: [([Double], SolverModel.Op, Double)], columns n: Int) -> ([Double], Double, Status)? {
        // Normalize to b ≥ 0.
        var rs = rows.map { r -> ([Double], SolverModel.Op, Double) in
            guard r.2 < 0 else { return r }
            let op: SolverModel.Op = r.1 == .le ? .ge : r.1 == .ge ? .le : r.1
            return (r.0.map { -$0 }, op, -r.2)
        }
        rs = rs.filter { $0.1 != .int && $0.1 != .bin }
        let m = rs.count
        let slackCount = rs.filter { $0.1 != .eq }.count
        let artCount = rs.filter { $0.1 != .le }.count
        let width = n + slackCount + artCount + 1   // last column: right-hand side
        var t = Array(repeating: Array(repeating: 0.0, count: width), count: m)
        var basis = Array(repeating: 0, count: m)
        var s = n, a = n + slackCount
        var artificial = Set<Int>()
        for (i, r) in rs.enumerated() {
            for j in 0..<n { t[i][j] = r.0[j] }
            t[i][width - 1] = r.2
            switch r.1 {
            case .le: t[i][s] = 1; basis[i] = s; s += 1
            case .ge: t[i][s] = -1; s += 1; t[i][a] = 1; basis[i] = a; artificial.insert(a); a += 1
            default: t[i][a] = 1; basis[i] = a; artificial.insert(a); a += 1
            }
        }
        func pivot(_ r: Int, _ col: Int) {
            let p = t[r][col]
            for j in 0..<width { t[r][j] /= p }
            for i in 0..<m where i != r {
                let f = t[i][col]
                if f != 0 { for j in 0..<width { t[i][j] -= f * t[r][j] } }
            }
            basis[r] = col
        }
        /// Runs simplex on the objective row (maximize obj·x); returns false when unbounded.
        func run(_ obj: [Double], allowed: (Int) -> Bool) -> Bool {
            for _ in 0..<5000 {
                // Reduced costs: obj_j − Σ obj_basis · column.
                var enter: Int?
                for j in 0..<(width - 1) where allowed(j) && !basis.contains(j) {
                    var rc = obj[j]
                    for i in 0..<m { rc -= obj[basis[i]] * t[i][j] }
                    if rc > 1e-10 { enter = j; break }   // Bland: first improving column
                }
                guard let col = enter else { return true }
                var leave: Int?, ratio = Double.infinity
                for i in 0..<m where t[i][col] > 1e-12 {
                    let q = t[i][width - 1] / t[i][col]
                    if q < ratio - 1e-12 || (abs(q - ratio) <= 1e-12 && leave.map { basis[i] < basis[$0] } ?? true) { ratio = q; leave = i }
                }
                guard let row = leave else { return false }
                pivot(row, col)
            }
            return true
        }
        // Phase 1: minimize the artificial variables.
        if !artificial.isEmpty {
            var obj1 = Array(repeating: 0.0, count: width - 1)
            for j in artificial { obj1[j] = -1 }
            _ = run(obj1) { _ in true }
            var infeasibility = 0.0
            for i in 0..<m where artificial.contains(basis[i]) { infeasibility += t[i][width - 1] }
            if infeasibility > 1e-7 { return nil }
            // Drive remaining artificial variables out of the basis.
            for i in 0..<m where artificial.contains(basis[i]) {
                if let j = (0..<(n + slackCount)).first(where: { abs(t[i][$0]) > 1e-10 }) { pivot(i, j) }
            }
        }
        var obj2 = Array(repeating: 0.0, count: width - 1)
        for j in 0..<n { obj2[j] = c[j] }
        guard run(obj2, allowed: { !artificial.contains($0) }) else { return (Array(repeating: 0, count: n), 0, .unbounded) }
        var x = Array(repeating: 0.0, count: n)
        for i in 0..<m where basis[i] < n { x[basis[i]] = t[i][width - 1] }
        return (x, zip(c, x).map(*).reduce(0, +), .optimal)
    }
}
