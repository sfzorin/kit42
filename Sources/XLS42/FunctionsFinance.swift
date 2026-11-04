import Foundation
import Kit42

/// Time value of money as in Excel/LibreOffice (type 0: end of period, 1: beginning).
enum Finance {
    static func pmt(_ rate: Double, _ nper: Double, _ pv: Double, _ fv: Double, _ type: Double) -> Double {
        if rate == 0 { return -(pv + fv) / nper }
        let f = pow(1 + rate, nper)
        return -(rate * (pv * f + fv)) / ((1 + rate * type) * (f - 1))
    }

    static func fv(_ rate: Double, _ nper: Double, _ pmt: Double, _ pv: Double, _ type: Double) -> Double {
        if rate == 0 { return -(pv + pmt * nper) }
        let f = pow(1 + rate, nper)
        return -(pv * f + pmt * (1 + rate * type) * (f - 1) / rate)
    }

    static func ipmt(_ rate: Double, _ per: Double, _ nper: Double, _ pv: Double, _ fv: Double, _ type: Double) -> Double {
        let p = pmt(rate, nper, pv, fv, type)
        var i: Double
        if per == 1 { i = type > 0 ? 0 : -pv }
        else if type > 0 { i = Finance.fv(rate, per - 2, p, pv, 1) - p }
        else { i = Finance.fv(rate, per - 1, p, pv, 0) }
        return i * rate
    }

    /// Newton's method with a bisection fallback; nil when it doesn't converge.
    static func solve(_ guess: Double, _ f: (Double) -> Double) -> Double? {
        var x = guess
        for _ in 0..<200 {
            let y = f(x)
            if abs(y) < 1e-12 { return x }
            let h = max(1e-7, abs(x) * 1e-7)
            let d = (f(x + h) - f(x - h)) / (2 * h)
            guard d != 0, d.isFinite else { break }
            var next = x - y / d
            if next <= -1 { next = (x - 1) / 2 }
            if abs(next - x) < 1e-14 * max(1, abs(x)) { return next }
            x = next
        }
        return abs(f(x)) < 1e-7 ? x : nil
    }
}

extension Calculator {
    func financeInfoFunction(_ name: String, _ x: FArgs) throws -> Operand? {
        func r(_ d: Double) throws -> Operand {
            guard d.isFinite else { throw XLError.num }
            return .value(.number(d))
        }
        switch name {
        case "PMT":
            try x.need(3)
            return try r(Finance.pmt(x.n(0), x.n(1), x.n(2), x.n(3, 0), x.n(4, 0)))
        case "FV":
            try x.need(3)
            return try r(Finance.fv(x.n(0), x.n(1), x.n(2), x.n(3, 0), x.n(4, 0)))
        case "PV":
            try x.need(3)
            let rate = try x.n(0), nper = try x.n(1), pmt = try x.n(2), fv = try x.n(3, 0), type = try x.n(4, 0)
            if rate == 0 { return try r(-(fv + pmt * nper)) }
            let f = pow(1 + rate, nper)
            return try r(-(fv + pmt * (1 + rate * type) * (f - 1) / rate) / f)
        case "NPER":
            try x.need(3)
            let rate = try x.n(0), pmt = try x.n(1), pv = try x.n(2), fv = try x.n(3, 0), type = try x.n(4, 0)
            if rate == 0 {
                guard pmt != 0 else { throw XLError.num }
                return try r(-(pv + fv) / pmt)
            }
            let a = pmt * (1 + rate * type) - fv * rate, b = pmt * (1 + rate * type) + pv * rate
            guard a / b > 0 else { throw XLError.num }
            return try r(log(a / b) / log(1 + rate))
        case "IPMT", "PPMT":
            try x.need(4)
            let rate = try x.n(0), per = try x.n(1), nper = try x.n(2), pv = try x.n(3), fv = try x.n(4, 0), type = try x.n(5, 0) != 0 ? 1.0 : 0
            guard per >= 1, per <= nper else { throw XLError.num }
            let i = Finance.ipmt(rate, per, nper, pv, fv, type)
            return try r(name == "IPMT" ? i : Finance.pmt(rate, nper, pv, fv, type) - i)
        case "ISPMT":
            let rate = try x.n(0), per = try x.n(1), nper = try x.n(2), pv = try x.n(3)
            guard nper != 0 else { throw XLError.div0 }
            return try r(pv * rate * (per / nper - 1))
        case "CUMIPMT", "CUMPRINC":
            try x.need(6)
            let rate = try x.n(0), nper = try x.n(1).rounded(.towardZero), pv = try x.n(2)
            let start = try x.n(3).rounded(.towardZero), end = try x.n(4).rounded(.towardZero), type = try x.n(5)
            guard rate > 0, nper > 0, pv > 0, start >= 1, end >= start, end <= nper, type == 0 || type == 1 else { throw XLError.num }
            var total = 0.0
            let p = Finance.pmt(rate, nper, pv, 0, type)
            for per in Int(start)...Int(end) {
                let i = Finance.ipmt(rate, Double(per), nper, pv, 0, type)
                total += name == "CUMIPMT" ? i : p - i
            }
            return try r(total)
        case "RATE":
            try x.need(3)
            let nper = try x.n(0), pmt = try x.n(1), pv = try x.n(2), fv = try x.n(3, 0), type = try x.n(4, 0), guess = try x.n(5, 0.1)
            guard nper > 0 else { throw XLError.num }
            let f: (Double) -> Double = { rate in
                if abs(rate) < 1e-12 { return pv + pmt * nper + fv }
                let g = pow(1 + rate, nper)
                return pv * g + pmt * (1 + rate * type) * (g - 1) / rate + fv
            }
            guard let rate = Finance.solve(guess, f) else { throw XLError.num }
            return try r(rate)
        case "NPV":
            try x.need(2)
            let rate = try x.n(0)
            guard rate != -1 else { throw XLError.div0 }
            let v = try x.c.numbers(Array(x.args.dropFirst()), sheet: x.sheet, at: x.at)
            return try r(v.enumerated().map { $0.element / pow(1 + rate, Double($0.offset + 1)) }.reduce(0, +))
        case "XNPV":
            try x.need(3)
            let rate = try x.n(0)
            let (v, d) = try numberPairs(x, 1, 2)
            guard !v.isEmpty, v.count == x.m(1).count, let d0 = d.first, d.allSatisfy({ $0 >= d0 }) else { throw XLError.num }
            return try r(zip(v, d).map { $0 / pow(1 + rate, (floor($1) - floor(d0)) / 365) }.reduce(0, +))
        case "IRR":
            try x.need(1)
            let v = try x.nums(0)
            guard v.contains(where: { $0 > 0 }), v.contains(where: { $0 < 0 }) else { throw XLError.num }
            let f: (Double) -> Double = { rate in v.enumerated().map { $0.element / pow(1 + rate, Double($0.offset)) }.reduce(0, +) }
            guard let rate = Finance.solve(try x.n(1, 0.1), f) else { throw XLError.num }
            return try r(rate)
        case "XIRR":
            try x.need(2)
            let (v, d) = try numberPairs(x, 0, 1)
            guard v.contains(where: { $0 > 0 }), v.contains(where: { $0 < 0 }), let d0 = d.first else { throw XLError.num }
            let f: (Double) -> Double = { rate in zip(v, d).map { $0 / pow(1 + rate, (floor($1) - floor(d0)) / 365) }.reduce(0, +) }
            guard let rate = Finance.solve(try x.n(2, 0.1), f) else { throw XLError.num }
            return try r(rate)
        case "MIRR":
            try x.need(3)
            let v = try x.nums(0), fr = try x.n(1), rr = try x.n(2)
            let n = Double(v.count)
            guard n >= 2 else { throw XLError.div0 }
            var npvPos = 0.0, npvNeg = 0.0
            for (i, c) in v.enumerated() {
                if c > 0 { npvPos += c / pow(1 + rr, Double(i)) } else { npvNeg += c / pow(1 + fr, Double(i)) }
            }
            guard npvNeg != 0, npvPos != 0 else { throw XLError.div0 }
            return try r(pow(-npvPos * pow(1 + rr, n - 1) / npvNeg, 1 / (n - 1)) - 1)
        case "SLN":
            let cost = try x.n(0), salvage = try x.n(1), life = try x.n(2)
            guard life != 0 else { throw XLError.div0 }
            return try r((cost - salvage) / life)
        case "SYD":
            let cost = try x.n(0), salvage = try x.n(1), life = try x.n(2), per = try x.n(3)
            guard life > 0, per > 0, per <= life else { throw XLError.num }
            return try r((cost - salvage) * (life - per + 1) * 2 / (life * (life + 1)))
        case "DDB":
            let cost = try x.n(0), salvage = try x.n(1), life = try x.n(2), period = try x.n(3), factor = try x.n(4, 2)
            guard cost >= 0, salvage >= 0, life > 0, period > 0, period <= life, factor > 0 else { throw XLError.num }
            var value = cost, dep = 0.0
            var p = 1.0
            while p <= period.rounded(.up) {
                dep = min(value * factor / life, max(0, value - salvage))
                value -= dep
                p += 1
            }
            return try r(dep)
        case "DB":
            let cost = try x.n(0), salvage = try x.n(1), life = try x.n(2), period = try x.n(3).rounded(.towardZero), month = try x.n(4, 12).rounded(.towardZero)
            guard cost >= 0, salvage >= 0, life > 0, period >= 1, month >= 1, month <= 12, period <= life + (month < 12 ? 1 : 0) else { throw XLError.num }
            if cost == 0 { return .value(.number(0)) }
            let rate = ((1 - pow(salvage / cost, 1 / life)) * 1000).rounded() / 1000
            var total = cost * rate * month / 12
            if period == 1 { return try r(total) }
            var dep = total
            for p in 2...Int(period) {
                dep = Double(p) == life + 1 ? (cost - total) * rate * (12 - month) / 12 : (cost - total) * rate
                total += dep
            }
            return try r(dep)
        case "EFFECT":
            let nominal = try x.n(0), n = try x.n(1).rounded(.towardZero)
            guard nominal > 0, n >= 1 else { throw XLError.num }
            return try r(pow(1 + nominal / n, n) - 1)
        case "NOMINAL":
            let eff = try x.n(0), n = try x.n(1).rounded(.towardZero)
            guard eff > 0, n >= 1 else { throw XLError.num }
            return try r(n * (pow(1 + eff, 1 / n) - 1))
        case "FVSCHEDULE":
            var p = try x.n(0)
            for rate in try x.nums(1) { p *= 1 + rate }
            return try r(p)
        case "PDURATION":
            let rate = try x.n(0), pv = try x.n(1), fv = try x.n(2)
            guard rate > 0, pv > 0, fv > 0 else { throw XLError.num }
            return try r((log(fv) - log(pv)) / log(1 + rate))
        case "RRI":
            let n = try x.n(0), pv = try x.n(1), fv = try x.n(2)
            guard n > 0, pv != 0 else { throw XLError.num }
            return try r(pow(fv / pv, 1 / n) - 1)

        // Information
        case "ISEVEN", "ISODD":
            let v = x.a(0)
            if case .error(let e) = v { throw XLError(code: e) }
            if case .string = v { throw XLError.value }
            let n = try num(v).rounded(.towardZero)
            let even = n.truncatingRemainder(dividingBy: 2) == 0
            return .value(.bool(name == "ISEVEN" ? even : !even))
        case "ISFORMULA", "FORMULATEXT":
            guard x.count >= 1, let (si, cells) = referencedCells(x.args[0], sheet: x.sheet), let ref = cells.first else {
                if name == "ISFORMULA" { throw XLError.value }
                throw XLError.na
            }
            let cell = workbook.sheets[si][ref]
            if name == "ISFORMULA" { return .value(.bool(cell.isFormula)) }
            guard cell.isFormula else { throw XLError.na }
            return .value(.string(cell.input))
        case "ISREF":
            guard x.count >= 1 else { throw XLError.value }
            switch x.args[0] {
            case .ref, .range: return .value(.bool(true))
            case .call(let n, _) where ["OFFSET", "INDIRECT", "INDEX"].contains(n):
                if case .matrix(_, let o) = x.op(0), o != nil { return .value(.bool(true)) }
                return .value(.bool(false))
            case .name(let n):
                if let def = workbook.names.first(where: { $0.key.caseInsensitiveCompare(n) == .orderedSame })?.value,
                   let e = Self.expression("=" + def) {
                    if case .ref = e { return .value(.bool(true)) }
                    if case .range = e { return .value(.bool(true)) }
                }
                return .value(.bool(false))
            default: return .value(.bool(false))
            }
        case "TYPE":
            let o = x.op(0)
            if o.isMulti { return .value(.number(64)) }
            switch scalar(o, at: x.at) {
            case .number, .empty: return .value(.number(1))
            case .string: return .value(.number(2))
            case .bool: return .value(.number(4))
            case .error: return .value(.number(16))
            }
        case "ERROR.TYPE":
            guard case .error(let e) = x.a(0) else { throw XLError.na }
            let codes = ["#NULL!": 1, "#DIV/0!": 2, "#VALUE!": 3, "#REF!": 4, "#NAME?": 5, "#NUM!": 6, "#N/A": 7, "#GETTING_DATA": 8,
                         "#SPILL!": 9, "#CALC!": 14]
            guard let c = codes[e] else { throw XLError.na }
            return .value(.number(Double(c)))
        case "SHEET":
            if x.count == 0 { return .value(.number(Double(x.sheet + 1))) }
            if let (si, _) = referencedCells(x.args[0], sheet: x.sheet) { return .value(.number(Double(si + 1))) }
            if case .string(let s) = x.a(0) {
                guard let i = workbook.sheetIndex(named: s) else { throw XLError.na }
                return .value(.number(Double(i + 1)))
            }
            throw XLError.na
        case "SHEETS":
            if x.count == 0 { return .value(.number(Double(workbook.sheets.count))) }
            guard referencedCells(x.args[0], sheet: x.sheet) != nil else { throw XLError.na }
            return .value(.number(1))
        case "CELL":
            try x.need(1)
            let info = try x.t(0).lowercased()
            var si = x.sheet, ref = x.at
            if x.count > 1 {
                guard let (s, cells) = referencedCells(x.args[1], sheet: x.sheet), let first = cells.first else { throw XLError.value }
                si = s; ref = first
            }
            let sheet = workbook.sheets[si]
            let cell = sheet[ref]
            switch info {
            case "address": return .value(.string("$" + CellRef.columnName(ref.col) + "$\(ref.row + 1)"))
            case "col": return .value(.number(Double(ref.col + 1)))
            case "row": return .value(.number(Double(ref.row + 1)))
            case "contents": return .value(value(sheet: si, ref: ref))
            case "type":
                let v = value(sheet: si, ref: ref)
                if v.isEmpty && !cell.isFormula { return .value(.string("b")) }
                if case .string = v { return .value(.string("l")) }
                return .value(.string("v"))
            case "width": return .value(.number((XLSX.columnChars(sheet.width(ref.col))).rounded(.towardZero)))
            case "protect": return .value(.number(cell.style.locked ? 1 : 0))
            case "prefix":
                guard case .string = value(sheet: si, ref: ref) else { return .value(.string("")) }
                return .value(.string(cell.style.hAlign == "right" ? "\"" : cell.style.hAlign == "center" ? "^" : "'"))
            case "format":
                let code = cell.style.numberFormat
                if code == "General" { return .value(.string("G")) }
                let decimals = code.split(separator: ".").dropFirst().first.map { $0.prefix { $0 == "0" }.count } ?? 0
                if NumberFormat.isDateFormat(code) { return .value(.string("D1")) }
                if code.contains("%") { return .value(.string("P\(decimals)")) }
                if code.contains("E+") { return .value(.string("S\(decimals)")) }
                if code.contains("$") || code.contains("₽") || code.contains("€") { return .value(.string("C\(decimals)")) }
                return .value(.string((code.contains(",") ? "," : "F") + "\(decimals)"))
            case "filename", "sheet":
                return .value(.string(sheet.name))
            default: throw XLError.value
            }
        case "INFO":
            switch try x.t(0).lowercased() {
            case "numfile": return .value(.number(Double(workbook.sheets.count)))
            case "recalc": return .value(.string("Automatic"))
            case "release": return .value(.string(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"))
            case "system": return .value(.string("mac"))
            case "osversion": return .value(.string(ProcessInfo.processInfo.operatingSystemVersionString))
            case "origin": return .value(.string("$A:$A$1"))
            case "directory": return .value(.string(FileManager.default.homeDirectoryForCurrentUser.path + "/"))
            default: throw XLError.value
            }
        default:
            return nil
        }
    }
}
