import Foundation
import Kit42

extension Calculator {
    /// Cells covered by a reference argument (for SUBTOTAL/AGGREGATE, ISFORMULA, CELL…).
    func referencedCells(_ e: Expr, sheet: Int) -> (sheet: Int, cells: [CellRef])? {
        switch e {
        case .ref(let s, let p):
            guard let si = try? sheetIndex(s, sheet) else { return nil }
            return (si, [CellRef(row: p.row, col: p.col)])
        case .range, .name:
            guard let (si, range) = try? referencedRange(e, sheet: sheet) else { return nil }
            // Blank cells do not affect aggregates. Keep the first address for CELL/ISFORMULA.
            return (si, Set(storedReferenceCells(sheet: si, range: range)).union([range.start]).sorted())
        default: return nil
        }
    }

    /// Values for SUBTOTAL/AGGREGATE: skips nested SUBTOTAL/AGGREGATE formulas, rows hidden by a filter
    /// (and any hidden row when `skipHidden`), and errors when `skipErrors`.
    func subtotalValues(_ args: ArraySlice<Expr>, sheet: Int, at: CellRef, skipHidden: Bool, skipNested: Bool, skipErrors: Bool) throws -> [Value] {
        var out: [Value] = []
        for e in args {
            if let (si, cells) = referencedCells(e, sheet: sheet) {
                let s = workbook.sheets[si]
                for ref in cells {
                    if skipHidden ? s.isRowHidden(ref.row) : s.filterHidden.contains(ref.row) { continue }
                    if skipNested, let c = s.cells[ref], c.isFormula {
                        let up = c.input.uppercased()
                        if up.contains("SUBTOTAL(") || up.contains("AGGREGATE(") { continue }
                    }
                    let v = value(sheet: si, ref: ref)
                    if v.isError, skipErrors { continue }
                    out.append(v)
                }
            } else {
                for v in matrix(eval(e, sheet: sheet, at: at)).values {
                    if v.isError, skipErrors { continue }
                    out.append(v)
                }
            }
        }
        return out
    }

    /// Function 1…19 of AGGREGATE (1–11 shared with SUBTOTAL) over the collected values.
    func aggregate(_ fn: Int, _ values: [Value], k: Double?) throws -> Double {
        if fn == 3 { return Double(values.filter { !$0.isEmpty }.count) }
        if let e = values.first(where: \.isError), case .error(let code) = e { throw XLError(code: code) }
        let nums = values.compactMap { v -> Double? in if case .number(let d) = v { return d }; return nil }
        func variance(_ sample: Bool) throws -> Double {
            guard nums.count > (sample ? 1 : 0) else { throw XLError.div0 }
            let m = Self.mean(nums)
            return nums.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(nums.count - (sample ? 1 : 0))
        }
        switch fn {
        case 1: guard !nums.isEmpty else { throw XLError.div0 }; return Self.mean(nums)
        case 2: return Double(nums.count)
        case 4: return nums.max() ?? 0
        case 5: return nums.min() ?? 0
        case 6: return nums.reduce(1, *)
        case 7: return try variance(true).squareRoot()
        case 8: return try variance(false).squareRoot()
        case 9: return nums.reduce(0, +)
        case 10: return try variance(true)
        case 11: return try variance(false)
        case 12:
            let s = nums.sorted()
            guard !s.isEmpty else { throw XLError.num }
            return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
        case 13:
            var counts: [Double: Int] = [:]
            nums.forEach { counts[$0, default: 0] += 1 }
            guard let best = nums.first(where: { counts[$0] == counts.values.max() && counts[$0]! > 1 }) else { throw XLError.na }
            return best
        case 14, 15:
            guard let k else { throw XLError.value }
            let s = nums.sorted(by: fn == 14 ? (>) : (<))
            let i = try Self.integer(k)
            guard i >= 1, i <= s.count else { throw XLError.num }
            return s[i - 1]
        case 16, 17, 18, 19:
            guard var k, !nums.isEmpty else { throw XLError.num }
            let s = nums.sorted()
            if fn == 17 || fn == 19 { k = k.rounded(.towardZero) / 4 }
            if fn >= 18 { return try Self.percentileExc(s, k) }
            guard k >= 0, k <= 1 else { throw XLError.num }
            return Self.percentileInc(s, k)
        default: throw XLError.value
        }
    }

    static func gcd(_ a: Double, _ b: Double) -> Double {
        var a = a, b = b
        while b > 0.5 { (a, b) = (b, a.truncatingRemainder(dividingBy: b)) }
        return a
    }

    static func combin(_ n: Double, _ k: Double) -> Double {
        if k < 0 || k > n { return .nan }
        let k = min(k, n - k)
        if n <= 1000 {
            var r = 1.0
            if k >= 1 { for i in 1...Int(k) { r = r * (n - k + Double(i)) / Double(i) } }
            return r.rounded()
        }
        return exp(lgamma(n + 1) - lgamma(k + 1) - lgamma(n - k + 1)).rounded()
    }

    func mathFunction(_ name: String, _ x: FArgs) throws -> Operand? {
        func r(_ d: Double) throws -> Operand {
            guard d.isFinite else { throw XLError.num }
            return .value(.number(d))
        }
        func one() throws -> Double { try x.n(0) }
        switch name {
        case "SUBTOTAL":
            try x.need(2)
            let code = try x.int(0)
            let fn = code % 100
            guard (1...11).contains(fn), code < 112 else { throw XLError.value }
            let values = try subtotalValues(x.args.dropFirst(), sheet: x.sheet, at: x.at, skipHidden: code > 100, skipNested: true, skipErrors: false)
            return try r(aggregate(fn, values, k: nil))
        case "AGGREGATE":
            try x.need(3)
            let fn = try x.int(0), opt = try x.int(1)
            guard (1...19).contains(fn), (0...7).contains(opt) else { throw XLError.value }
            let skipHidden = [1, 3, 5, 7].contains(opt), skipErrors = [2, 3, 6, 7].contains(opt), skipNested = opt <= 3
            let refs = fn >= 14 ? x.args[2...2] : x.args.dropFirst(2)
            let values = try subtotalValues(refs, sheet: x.sheet, at: x.at, skipHidden: skipHidden, skipNested: skipNested, skipErrors: skipErrors)
            return try r(aggregate(fn, values, k: fn >= 14 ? try x.n(3) : nil))
        case "QUOTIENT":
            let d = try x.n(1)
            guard d != 0 else { throw XLError.div0 }
            return try r((try one() / d).rounded(.towardZero))
        case "GCD", "LCM":
            let v = try x.allNums().map { $0.rounded(.towardZero) }
            guard v.allSatisfy({ $0 >= 0 && $0 < 9.007e15 }) else { throw XLError.num }
            if name == "GCD" { return try r(v.reduce(0) { Self.gcd($0, $1) }) }
            if v.contains(0) { return .value(.number(0)) }
            return try r(v.reduce(1) { $0 / Self.gcd($0, $1) * $1 })
        case "COMBIN", "COMBINA", "PERMUT", "PERMUTATIONA":
            let n = try x.n(0).rounded(.towardZero), k = try x.n(1).rounded(.towardZero)
            guard n >= 0, k >= 0 else { throw XLError.num }
            switch name {
            case "COMBIN": guard k <= n else { throw XLError.num }; return try r(Self.combin(n, k))
            case "COMBINA": guard n > 0 || k == 0 else { throw XLError.num }; return try r(k == 0 ? 1 : Self.combin(n + k - 1, k))
            case "PERMUT":
                guard k <= n, k <= 170 else { throw XLError.num }
                var p = 1.0
                if k >= 1 { for i in 0..<Int(k) { p *= n - Double(i) } }
                return try r(p)
            default: return try r(pow(n, k))
            }
        case "SUMX2MY2", "SUMX2PY2", "SUMXMY2":
            try x.need(2)
            let (a, b) = try numberPairs(x, 0, 1)
            var total = 0.0
            for (p, q) in zip(a, b) {
                switch name {
                case "SUMX2MY2": total += p * p - q * q
                case "SUMX2PY2": total += p * p + q * q
                default: total += (p - q) * (p - q)
                }
            }
            return try r(total)
        case "ASIN", "ACOS":
            let v = try one()
            guard abs(v) <= 1 else { throw XLError.num }
            return try r(name == "ASIN" ? asin(v) : acos(v))
        case "ATAN": return try r(atan(one()))
        case "ATAN2":
            let a = try x.n(0), b = try x.n(1)
            guard a != 0 || b != 0 else { throw XLError.div0 }
            return try r(atan2(b, a))
        case "SINH": return try r(sinh(one()))
        case "COSH": return try r(cosh(one()))
        case "TANH": return try r(tanh(one()))
        case "ASINH": return try r(asinh(one()))
        case "ACOSH":
            let v = try one()
            guard v >= 1 else { throw XLError.num }
            return try r(acosh(v))
        case "ATANH":
            let v = try one()
            guard abs(v) < 1 else { throw XLError.num }
            return try r(atanh(v))
        case "COT", "CSC", "COTH", "CSCH":
            let v = try one()
            guard v != 0 else { throw XLError.div0 }
            switch name {
            case "COT": return try r(1 / tan(v))
            case "CSC": return try r(1 / sin(v))
            case "COTH": return try r(1 / tanh(v))
            default: return try r(1 / sinh(v))
            }
        case "SEC": return try r(1 / cos(one()))
        case "SECH": return try r(1 / cosh(one()))
        case "ACOT": return try r(Double.pi / 2 - atan(one()))
        case "ACOTH":
            let v = try one()
            guard abs(v) > 1 else { throw XLError.num }
            return try r(0.5 * log((v + 1) / (v - 1)))
        case "SQRTPI":
            let v = try one()
            guard v >= 0 else { throw XLError.num }
            return try r((v * Double.pi).squareRoot())
        case "FACTDOUBLE":
            let v = try one().rounded(.towardZero)
            guard v >= -1 else { throw XLError.num }
            var p = 1.0, i = v
            while i > 1 { p *= i; i -= 2 }
            return try r(p)
        case "MULTINOMIAL":
            let v = try x.allNums().map { $0.rounded(.towardZero) }
            guard v.allSatisfy({ $0 >= 0 }) else { throw XLError.num }
            return try r(exp(lgamma(v.reduce(0, +) + 1) - v.map { lgamma($0 + 1) }.reduce(0, +)).rounded())
        case "CEILING.PRECISE", "ISO.CEILING", "FLOOR.PRECISE":
            let v = try one(), s = abs(try x.n(1, 1))
            guard s != 0 else { return .value(.number(0)) }
            return try r((name.hasPrefix("FLOOR") ? (v / s).rounded(.down) : (v / s).rounded(.up)) * s)
        case "CEILING.MATH", "FLOOR.MATH":
            let v = try one(), s = abs(try x.n(1, 1)), mode = try x.n(2, 0)
            guard s != 0 else { return .value(.number(0)) }
            let q = v / s
            let rounded: Double
            if name == "CEILING.MATH" { rounded = v < 0 && mode != 0 ? q.rounded(.down) : q.rounded(.up) }
            else { rounded = v < 0 && mode != 0 ? q.rounded(.up) : q.rounded(.down) }
            return try r(rounded * s)
        case "ROMAN":
            let v = try Self.integer(one())
            guard v >= 0, v <= 3999 else { throw XLError.value }
            let table: [(Int, String)] = [(1000, "M"), (900, "CM"), (500, "D"), (400, "CD"), (100, "C"), (90, "XC"), (50, "L"), (40, "XL"),
                                          (10, "X"), (9, "IX"), (5, "V"), (4, "IV"), (1, "I")]
            var n = v, s = ""
            for (k, l) in table { while n >= k { s += l; n -= k } }
            return .value(.string(s))
        case "ARABIC":
            let s = try x.t(0).trimmingCharacters(in: .whitespaces).uppercased()
            let neg = s.hasPrefix("-")
            let body = neg ? String(s.dropFirst()) : s
            let vals: [Character: Int] = ["I": 1, "V": 5, "X": 10, "L": 50, "C": 100, "D": 500, "M": 1000]
            var total = 0, prev = 0
            for ch in body.reversed() {
                guard let v = vals[ch] else { throw XLError.value }
                if v < prev { total -= v } else { total += v; prev = v }
            }
            return .value(.number(Double(neg ? -total : total)))
        case "BASE":
            let v = try one().rounded(.towardZero), radix = try x.int(1), minLen = try x.int(2, 0)
            guard v >= 0, v < 9.007e15, (2...36).contains(radix), minLen >= 0, minLen <= 255 else { throw XLError.num }
            var s = String(Int64(v), radix: radix).uppercased()
            if s.count < minLen { s = String(repeating: "0", count: minLen - s.count) + s }
            return .value(.string(s))
        case "DECIMAL":
            let s = try x.t(0).trimmingCharacters(in: .whitespaces), radix = try x.int(1)
            guard (2...36).contains(radix), let v = Int64(s.isEmpty ? "0" : s, radix: radix), v >= 0 else { throw XLError.num }
            return .value(.number(Double(v)))
        case "SERIESSUM":
            let v = try x.n(0), n0 = try x.n(1), m = try x.n(2)
            let coeffs = try x.nums(3)
            return try r(coeffs.enumerated().map { $0.element * pow(v, n0 + Double($0.offset) * m) }.reduce(0, +))

        // Engineering
        case "DEC2BIN", "DEC2OCT", "DEC2HEX":
            let v = try one().rounded(.towardZero)
            let radix = name == "DEC2BIN" ? 2 : name == "DEC2OCT" ? 8 : 16
            let bits = radix == 2 ? 10 : radix == 8 ? 30 : 40
            let limit = pow(2, Double(bits - 1))
            guard v >= -limit, v < limit else { throw XLError.num }
            var s: String
            if v < 0 { s = String(Int64(pow(2, Double(bits)) + v), radix: radix).uppercased() }
            else {
                s = String(Int64(v), radix: radix).uppercased()
                if x.has(1) {
                    let places = try x.int(1)
                    guard places >= s.count, places <= 10 else { throw XLError.num }
                    s = String(repeating: "0", count: places - s.count) + s
                }
            }
            return .value(.string(s))
        case "BIN2DEC", "OCT2DEC", "HEX2DEC", "BIN2OCT", "BIN2HEX", "OCT2BIN", "OCT2HEX", "HEX2BIN", "HEX2OCT":
            let from = name.hasPrefix("BIN") ? 2 : name.hasPrefix("OCT") ? 8 : 16
            let bits = from == 2 ? 10 : from == 8 ? 30 : 40
            var text = try x.t(0).trimmingCharacters(in: .whitespaces)
            if case .number(let d) = x.a(0) { text = Value.formatGeneral(d) }
            guard text.count <= 10, let raw = Int64(text.isEmpty ? "0" : text, radix: from), raw >= 0 else { throw XLError.num }
            var v = Double(raw)
            if text.count == 10, raw >= Int64(pow(2, Double(bits - 1))) { v -= pow(2, Double(bits)) }
            if name.hasSuffix("DEC") { return try r(v) }
            let to = name.hasSuffix("BIN") ? 2 : name.hasSuffix("OCT") ? 8 : 16
            let toBits = to == 2 ? 10 : to == 8 ? 30 : 40
            let limit = pow(2, Double(toBits - 1))
            guard v >= -limit, v < limit else { throw XLError.num }
            var s: String
            if v < 0 { s = String(Int64(pow(2, Double(toBits)) + v), radix: to).uppercased() }
            else {
                s = String(Int64(v), radix: to).uppercased()
                if x.has(1) {
                    let places = try x.int(1)
                    guard places >= s.count, places <= 10 else { throw XLError.num }
                    s = String(repeating: "0", count: places - s.count) + s
                }
            }
            return .value(.string(s))
        case "BITAND", "BITOR", "BITXOR":
            let a = try x.n(0), b = try x.n(1)
            let limit: Double = 281_474_976_710_656
            guard a >= 0, b >= 0, a < limit, b < limit, a == a.rounded(), b == b.rounded() else { throw XLError.num }
            let p = UInt64(a), q = UInt64(b)
            return .value(.number(Double(name == "BITAND" ? p & q : name == "BITOR" ? p | q : p ^ q)))
        case "BITLSHIFT", "BITRSHIFT":
            let a = try x.n(0), s = try x.int(1)
            let limit: Double = 281_474_976_710_656
            guard a >= 0, a < limit, a == a.rounded(), abs(s) <= 53 else { throw XLError.num }
            let shift = name == "BITLSHIFT" ? s : -s
            guard shift <= 0 || a < limit / pow(2, Double(shift)) else { throw XLError.num }
            let v = UInt64(a)
            let out = shift >= 0 ? v << UInt64(shift) : v >> UInt64(-shift)
            guard Double(out) < limit else { throw XLError.num }
            return .value(.number(Double(out)))
        case "DELTA": return .value(.number(try x.n(0) == x.n(1, 0) ? 1 : 0))
        case "GESTEP": return .value(.number(try x.n(0) >= x.n(1, 0) ? 1 : 0))
        case "CONVERT":
            try x.need(3)
            let v = try x.n(0)
            guard let out = UnitConversion.convert(v, from: try x.t(1), to: try x.t(2)) else { throw XLError.na }
            return try r(out)
        default:
            return nil
        }
    }
}

/// CONVERT: units by category with SI and binary prefixes (Excel's table, common units).
enum UnitConversion {
    enum Kind { case mass, length, time, pressure, force, energy, power, magnetism, temperature, volume, area, information, speed }
    /// unit → (kind, factor to the base unit, accepts prefixes)
    static let units: [String: (Kind, Double, Bool)] = [
        // mass (gram)
        "g": (.mass, 1, true), "sg": (.mass, 14593.902937206364, false), "lbm": (.mass, 453.59237, false), "u": (.mass, 1.66053886e-24, true),
        "ozm": (.mass, 28.349523125, false), "grain": (.mass, 0.06479891, false), "cwt": (.mass, 45359.237, false), "shweight": (.mass, 45359.237, false),
        "uk_cwt": (.mass, 50802.34544, false), "lcwt": (.mass, 50802.34544, false), "stone": (.mass, 6350.29318, false), "ton": (.mass, 907184.74, false),
        "uk_ton": (.mass, 1016046.9088, false), "LTON": (.mass, 1016046.9088, false), "brton": (.mass, 1016046.9088, false),
        // length (metre)
        "m": (.length, 1, true), "mi": (.length, 1609.344, false), "Nmi": (.length, 1852, false), "in": (.length, 0.0254, false),
        "ft": (.length, 0.3048, false), "yd": (.length, 0.9144, false), "ang": (.length, 1e-10, true), "ell": (.length, 1.143, false),
        "ly": (.length, 9.4607304725808e15, true), "parsec": (.length, 3.08567758128155e16, true), "pc": (.length, 3.08567758128155e16, true),
        "Picapt": (.length, 0.0254 / 72, false), "Pica": (.length, 0.0254 / 72, false), "pica": (.length, 0.0254 / 6, false),
        "survey_mi": (.length, 1609.3472186944373, false),
        // time (second)
        "yr": (.time, 31557600, false), "day": (.time, 86400, false), "d": (.time, 86400, false), "hr": (.time, 3600, false),
        "mn": (.time, 60, false), "min": (.time, 60, false), "sec": (.time, 1, true), "s": (.time, 1, true),
        // pressure (pascal)
        "Pa": (.pressure, 1, true), "p": (.pressure, 1, true), "atm": (.pressure, 101325, true), "at": (.pressure, 101325, true),
        "mmHg": (.pressure, 133.322, true), "psi": (.pressure, 6894.75729316836, true), "Torr": (.pressure, 133.322368421053, false),
        // force (newton)
        "N": (.force, 1, true), "dyn": (.force, 1e-5, true), "dy": (.force, 1e-5, true), "lbf": (.force, 4.4482216152605, false),
        "pond": (.force, 0.00980665, true),
        // energy (joule)
        "J": (.energy, 1, true), "e": (.energy, 1e-7, true), "c": (.energy, 4.184, true), "cal": (.energy, 4.1868, true),
        "eV": (.energy, 1.602176487e-19, true), "ev": (.energy, 1.602176487e-19, true), "HPh": (.energy, 2684519.53769617, false),
        "hh": (.energy, 2684519.53769617, false), "Wh": (.energy, 3600, true), "wh": (.energy, 3600, true),
        "flb": (.energy, 0.0421401100938048, false), "BTU": (.energy, 1055.05585262, false), "btu": (.energy, 1055.05585262, false),
        // power (watt)
        "W": (.power, 1, true), "w": (.power, 1, true), "HP": (.power, 745.69987158227, false), "h": (.power, 745.69987158227, false),
        "PS": (.power, 735.49875, false),
        // magnetism (tesla)
        "T": (.magnetism, 1, true), "ga": (.magnetism, 1e-4, true),
        // volume (litre)
        "l": (.volume, 1, true), "L": (.volume, 1, true), "lt": (.volume, 1, true), "tsp": (.volume, 0.00492892159375, false),
        "tspm": (.volume, 0.005, false), "tbs": (.volume, 0.01478676478125, false), "oz": (.volume, 0.0295735295625, false),
        "cup": (.volume, 0.2365882365, false), "pt": (.volume, 0.473176473, false), "us_pt": (.volume, 0.473176473, false),
        "uk_pt": (.volume, 0.56826125, false), "qt": (.volume, 0.946352946, false), "uk_qt": (.volume, 1.1365225, false),
        "gal": (.volume, 3.785411784, false), "uk_gal": (.volume, 4.54609, false), "m3": (.volume, 1000, true),
        "mi3": (.volume, 4168181825440.58, false), "yd3": (.volume, 764.554857984, false), "ft3": (.volume, 28.316846592, false),
        "in3": (.volume, 0.016387064, false), "barrel": (.volume, 158.987294928, false), "bushel": (.volume, 35.23907016688, false),
        "MTON": (.volume, 1132.67386368, false),
        // area (square metre)
        "m2": (.area, 1, true), "ha": (.area, 10000, false), "ar": (.area, 100, true), "uk_acre": (.area, 4046.8564224, false),
        "us_acre": (.area, 4046.87260987425, false), "mi2": (.area, 2589988.110336, false), "ft2": (.area, 0.09290304, false),
        "yd2": (.area, 0.83612736, false), "in2": (.area, 0.00064516, false), "Nmi2": (.area, 3429904, false),
        // information (bit)
        "bit": (.information, 1, true), "byte": (.information, 8, true),
        // speed (m/s)
        "m/s": (.speed, 1, true), "m/sec": (.speed, 1, true), "m/h": (.speed, 1 / 3600, true), "m/hr": (.speed, 1 / 3600, true),
        "mph": (.speed, 0.44704, false), "kn": (.speed, 1852.0 / 3600, false), "admkn": (.speed, 0.514773333333333, false),
    ]
    static let prefixes: [String: Double] = [
        "Y": 1e24, "Z": 1e21, "E": 1e18, "P": 1e15, "T": 1e12, "G": 1e9, "M": 1e6, "k": 1e3, "h": 1e2, "da": 1e1, "e": 1e1,
        "d": 1e-1, "c": 1e-2, "m": 1e-3, "u": 1e-6, "n": 1e-9, "p": 1e-12, "f": 1e-15, "a": 1e-18, "z": 1e-21, "y": 1e-24,
        "ki": 1024, "Mi": 1048576, "Gi": 1073741824, "Ti": 1099511627776, "Pi": 1125899906842624, "Ei": 1152921504606846976,
    ]
    static let temperatures: Set<String> = ["C", "cel", "F", "fah", "K", "kel", "Rank", "Reau"]

    static func resolve(_ u: String) -> (Kind, Double)? {
        if let (k, f, _) = units[u] { return (k, f) }
        for (p, pf) in prefixes.sorted(by: { $0.key.count > $1.key.count }) where u.hasPrefix(p) {
            let rest = String(u.dropFirst(p.count))
            if let (k, f, ok) = units[rest], ok {
                // Squared/cubed units take the prefix to the power.
                var factor = pf
                if rest.hasSuffix("2"), k == .area { factor = pf * pf }
                if rest.hasSuffix("3"), k == .volume { factor = pf * pf * pf }
                if p.hasSuffix("i"), k != .information { return nil }
                return (k, f * factor)
            }
        }
        return nil
    }

    static func kelvin(_ v: Double, _ u: String) -> Double? {
        switch u {
        case "C", "cel": return v + 273.15
        case "F", "fah": return (v - 32) * 5 / 9 + 273.15
        case "K", "kel": return v
        case "Rank": return v * 5 / 9
        case "Reau": return v * 1.25 + 273.15
        default: return nil
        }
    }

    static func fromKelvin(_ k: Double, _ u: String) -> Double? {
        switch u {
        case "C", "cel": return k - 273.15
        case "F", "fah": return (k - 273.15) * 9 / 5 + 32
        case "K", "kel": return k
        case "Rank": return k * 9 / 5
        case "Reau": return (k - 273.15) * 0.8
        default: return nil
        }
    }

    static func convert(_ v: Double, from: String, to: String) -> Double? {
        if temperatures.contains(from) || temperatures.contains(to) {
            // Kelvin also takes prefixes (mK…), others don't.
            guard let k = kelvin(v, from) ?? prefixedKelvin(v, from) else { return nil }
            return fromKelvin(k, to) ?? prefixedFromKelvin(k, to)
        }
        guard let (k1, f1) = resolve(from), let (k2, f2) = resolve(to), k1 == k2 else { return nil }
        return v * f1 / f2
    }

    private static func prefixedKelvin(_ v: Double, _ u: String) -> Double? {
        for (p, pf) in prefixes where u == p + "K" || u == p + "kel" { return v * pf }
        return nil
    }

    private static func prefixedFromKelvin(_ k: Double, _ u: String) -> Double? {
        for (p, pf) in prefixes where u == p + "K" || u == p + "kel" { return k / pf }
        return nil
    }
}
