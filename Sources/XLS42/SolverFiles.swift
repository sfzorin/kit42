import Foundation
import Kit42

/// The Solver model in files, as Excel and LibreOffice keep it: hidden sheet-scoped names
/// `solver_opt`, `solver_typ`, `solver_val`, `solver_adj`, `solver_lhsN/relN/rhsN`, `solver_num`, `solver_neg`,
/// `solver_eng`, `solver_lin`… — `definedName localSheetId=… hidden="1"` in .xlsx, and in .ods the sheet's own
/// `table:named-expressions` (named ranges with `table:range-usable-as="hidden"`, expressions with `loext:hidden`),
/// which is what LibreOffice 24.2+ writes for its own solver model (plus `solver_lo_eng`).
enum SolverFiles {
    /// One name: cell ranges (written as a reference) or a value/expression text.
    enum Item: Equatable {
        case ranges([CellRange])
        case value(String)
    }

    /// rel codes: 1 ≤, 2 =, 3 ≥, 4 integer, 5 binary (6 = AllDifferent isn't supported).
    static let relCodes: [SolverModel.Op: Int] = [.le: 1, .eq: 2, .ge: 3, .int: 4, .bin: 5]

    /// Excel's defaults for the options XLS42 doesn't use, so Excel finds a complete model.
    static let excelDefaults: [String: String] = [
        "solver_cvg": "0.0001", "solver_drv": "1", "solver_est": "1", "solver_itr": "2147483647", "solver_mip": "2147483647",
        "solver_mni": "30", "solver_mrt": "0.075", "solver_msl": "2", "solver_nod": "2147483647", "solver_nwt": "1",
        "solver_pre": "0.000001", "solver_rbv": "1", "solver_rlx": "2", "solver_rsd": "0", "solver_scl": "1",
        "solver_sho": "2", "solver_ssz": "100", "solver_tim": "2147483647", "solver_tol": "0.01", "solver_ver": "3",
    ]
    static let linearEngine = "com.sun.star.comp.Calc.CoinMPSolver"
    static let nonlinearEngine = "com.sun.star.comp.Calc.SwarmSolver"

    static func isSolverName(_ name: String) -> Bool { name.lowercased().hasPrefix("solver_") }

    // MARK: Model → names

    static func items(_ m: SolverModel) -> [(String, Item)] {
        var out: [(String, Item)] = []
        out.append(("solver_opt", .ranges([CellRange(m.objective, m.objective)])))
        switch m.goal {
        case .max: out += [("solver_typ", .value("1")), ("solver_val", .value("0"))]
        case .min: out += [("solver_typ", .value("2")), ("solver_val", .value("0"))]
        case .value(let v): out += [("solver_typ", .value("3")), ("solver_val", .value(Value.formatGeneral(v)))]
        }
        out.append(("solver_adj", .ranges(ODS.ranges(m.variables))))
        for (i, c) in m.constraints.enumerated() {
            let n = i + 1
            out.append(("solver_lhs\(n)", .ranges([c.lhs])))
            out.append(("solver_rel\(n)", .value(String(relCodes[c.op] ?? 1))))
            switch c.op {
            case .int: out.append(("solver_rhs\(n)", .value("\"integer\"")))
            case .bin: out.append(("solver_rhs\(n)", .value("\"binary\"")))
            default:
                let rhs = c.rhs.trimmingCharacters(in: .whitespaces)
                if let r = CellRange(rhs.replacingOccurrences(of: "$", with: "")), !rhs.isEmpty, rhs.first?.isLetter == true || rhs.first == "$" {
                    out.append(("solver_rhs\(n)", .ranges([r])))
                } else {
                    var v = rhs.hasPrefix("=") ? String(rhs.dropFirst()) : rhs
                    if Double(v) == nil, let d = Double(v.replacingOccurrences(of: ",", with: ".")) { v = Value.formatGeneral(d) }
                    out.append(("solver_rhs\(n)", .value(v.isEmpty ? "0" : v)))
                }
            }
        }
        out.append(("solver_num", .value(String(m.constraints.count))))
        out.append(("solver_neg", .value(m.nonNegative ? "1" : "2")))
        out.append(("solver_eng", .value(m.linear ? "2" : "1")))
        out.append(("solver_lin", .value(m.linear ? "1" : "2")))
        // LibreOffice's engine: keep the one from the file when it fits the method.
        let keptEngine = m.extra["solver_lo_eng"].map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
        let engine = keptEngine.flatMap { isLinearEngine($0) == m.linear ? $0 : nil } ?? (m.linear ? linearEngine : nonlinearEngine)
        out.append(("solver_lo_eng", .value("\"\(engine)\"")))
        let own = Set(out.map(\.0))
        var rest = excelDefaults
        for (k, v) in m.extra where !own.contains(k) && !k.hasPrefix("solver_lhs") && !k.hasPrefix("solver_rel") && !k.hasPrefix("solver_rhs") { rest[k] = v }
        for k in rest.keys.sorted() where !own.contains(k) { out.append((k, .value(rest[k]!))) }
        return out.sorted { $0.0 < $1.0 }
    }

    static func isLinearEngine(_ name: String) -> Bool {
        name.contains("CoinMP") || name.contains("Lpsolve") || name.contains("LpSolve")
    }

    /// Excel reference text: `Sheet1!$A$1:$B$2` (several ranges joined by ",").
    static func excelRefs(_ ranges: [CellRange], sheet: String) -> String {
        ranges.map { r in
            let a = "$\(CellRef.columnName(r.start.col))$\(r.start.row + 1)"
            let b = "$\(CellRef.columnName(r.end.col))$\(r.end.row + 1)"
            return Formula.sheetPrefix(sheet) + (r.count == 1 ? a : a + ":" + b)
        }.joined(separator: ",")
    }

    /// `<definedName …>` elements of one sheet's model for workbook.xml.
    static func xlsxNames(_ m: SolverModel, sheet: String, index: Int) -> [String] {
        items(m).map { name, item in
            let text: String
            switch item {
            case .ranges(let r): text = excelRefs(r, sheet: sheet)
            case .value(let v): text = v
            }
            return "<definedName name=\"\(name)\" localSheetId=\"\(index)\" hidden=\"1\">\(xmlEscape(text))</definedName>"
        }
    }

    /// `<table:named-expressions>` for a sheet's model (inside its `table:table`, as LibreOffice writes it).
    static func odsNames(_ m: SolverModel, sheet: String) -> String {
        let base = ODS.odfCell(sheet, CellRef(row: 0, col: 0))
        var x = "<table:named-expressions>"
        for (name, item) in items(m) {
            switch item {
            case .ranges(let rs):
                let address = rs.map { $0.count == 1 ? ODS.odfCell(sheet, $0.start) : ODS.odfRange(sheet, $0) }.joined(separator: " ")
                x += "<table:named-range table:name=\"\(name)\" table:base-cell-address=\"\(xmlEscape(base))\" table:cell-range-address=\"\(xmlEscape(address))\" table:range-usable-as=\"hidden\"/>"
            case .value(let v):
                x += "<table:named-expression table:name=\"\(name)\" table:base-cell-address=\"\(xmlEscape(base))\" table:expression=\"\(xmlEscape(v))\" loext:hidden=\"true\"/>"
            }
        }
        return x + "</table:named-expressions>"
    }

    // MARK: Names → model

    /// Model from the names of one sheet (values as Excel text: references with or without the sheet).
    static func model(_ names: [String: String], sheet: String) -> SolverModel? {
        var lower: [String: String] = [:]
        for (k, v) in names { lower[k.lowercased()] = v.trimmingCharacters(in: .whitespaces) }
        func refs(_ text: String?) -> [CellRange] {
            guard var t = text, !t.isEmpty else { return [] }
            if t.hasPrefix("=") { t.removeFirst() }
            return ODS.splitArguments(t).compactMap { part in
                var p = part
                if let bang = p.lastIndex(of: "!") { p = String(p[p.index(after: bang)...]) }
                return CellRange(p.replacingOccurrences(of: "$", with: ""))
            }
        }
        guard let objective = refs(lower["solver_opt"]).first?.start else { return nil }
        let variables = refs(lower["solver_adj"]).flatMap(\.cells)
        var m = SolverModel(objective: objective, variables: variables)
        let value = Double(lower["solver_val"] ?? "") ?? 0
        switch lower["solver_typ"] {
        case "2": m.goal = .min
        case "3": m.goal = .value(value)
        default: m.goal = .max
        }
        let count = Int(lower["solver_num"] ?? "") ?? names.keys.filter { $0.lowercased().hasPrefix("solver_lhs") }.count
        if count > 0 {
            for n in 1...min(count, 500) {
                guard let lhs = refs(lower["solver_lhs\(n)"]).first, let rel = lower["solver_rel\(n)"].flatMap({ Int($0) }),
                      let op = relCodes.first(where: { $0.value == rel })?.key else { continue }
                var rhs = lower["solver_rhs\(n)"] ?? "0"
                if rhs.hasPrefix("=") { rhs.removeFirst() }
                if op == .int || op == .bin { rhs = "" }
                else if let r = refs(rhs).first, rhs.contains("$") || rhs.contains("!") || CellRange(rhs) != nil, Double(rhs) == nil {
                    rhs = r.count == 1 ? "$\(CellRef.columnName(r.start.col))$\(r.start.row + 1)"
                        : "$\(CellRef.columnName(r.start.col))$\(r.start.row + 1):$\(CellRef.columnName(r.end.col))$\(r.end.row + 1)"
                }
                m.constraints.append(.init(lhs: lhs, op: op, rhs: rhs))
            }
        }
        m.nonNegative = lower["solver_neg"].map { $0 != "2" && $0 != "0" && $0.lowercased() != "false" } ?? true
        if let eng = lower["solver_eng"] { m.linear = eng == "2" }
        else if let lo = lower["solver_lo_eng"] { m.linear = isLinearEngine(lo) }
        else if let lin = lower["solver_lin"] { m.linear = lin == "1" }
        let interpreted: Set<String> = ["solver_opt", "solver_typ", "solver_val", "solver_adj", "solver_num", "solver_neg", "solver_eng", "solver_lin"]
        for (k, v) in lower where !interpreted.contains(k) && !k.hasPrefix("solver_lhs") && !k.hasPrefix("solver_rel") && !k.hasPrefix("solver_rhs") {
            m.extra[k] = v
        }
        return m
    }

    /// Text for `--info`.
    static func describe(_ m: SolverModel) -> String {
        let goal: String
        switch m.goal {
        case .max: goal = "max"
        case .min: goal = "min"
        case .value(let v): goal = "value \(Value.formatGeneral(v))"
        }
        let vars = ODS.ranges(m.variables).map(\.a1).joined(separator: ",")
        let cons = m.constraints.map { "\($0.lhs.a1) \($0.op.rawValue) \($0.rhs)".trimmingCharacters(in: .whitespaces) }.joined(separator: "; ")
        return "solver \(goal) \(m.objective.a1) by \(vars) [\(cons)] \(m.nonNegative ? "non-negative" : "free") \(m.linear ? "linear" : "nonlinear")"
    }
}
