import AppKit
import Kit42

extension Calculator {
    /// Day of week 0 = Monday … 6 = Sunday of a serial date.
    static func isoWeekday(_ serial: Double) -> Int { ((Int(floor(serial)) + 5) % 7 + 7) % 7 }

    /// Weekend days (0 = Monday … 6 = Sunday) from NETWORKDAYS.INTL/WORKDAY.INTL's weekend argument.
    func weekendMask(_ v: Value) throws -> [Bool] {
        var mask = Array(repeating: false, count: 7)
        switch v {
        case .empty:
            mask[5] = true; mask[6] = true
        case .string(let s):
            guard s.count == 7, s.allSatisfy({ $0 == "0" || $0 == "1" }), s != "1111111" else { throw XLError.value }
            for (i, ch) in s.enumerated() { mask[i] = ch == "1" }
        default:
            let k = try Self.integer(num(v))
            switch k {
            case 1...7: mask[(k + 4) % 7] = true; mask[(k + 5) % 7] = true
            case 11...17: mask[(k - 12 + 7) % 7] = true
            default: throw XLError.num
            }
        }
        return mask
    }

    func holidays(_ x: FArgs, _ i: Int) throws -> Set<Double> {
        guard x.has(i) else { return [] }
        return Set(try x.nums(i).map { value in
            guard value >= 0, value + dateOffset <= 2_958_465 else { throw XLError.num }
            return floor(value) + dateOffset
        })
    }

    /// Positions of `delimiters` in `text` from the left, non-overlapping (TEXTBEFORE/TEXTAFTER/TEXTSPLIT).
    static func delimiterRanges(_ text: String, _ delimiters: [String], caseInsensitive: Bool) -> [Range<String.Index>] {
        var out: [Range<String.Index>] = []
        var from = text.startIndex
        let options: String.CompareOptions = caseInsensitive ? [.caseInsensitive] : []
        while from < text.endIndex {
            var best: Range<String.Index>?
            for d in delimiters where !d.isEmpty {
                if let r = text.range(of: d, options: options, range: from..<text.endIndex), best == nil || r.lowerBound < best!.lowerBound
                    || (r.lowerBound == best!.lowerBound && r.upperBound > best!.upperBound) { best = r }
            }
            guard let b = best else { break }
            out.append(b)
            from = b.upperBound
        }
        return out
    }

    func regex(_ pattern: String, caseInsensitive: Bool) throws -> NSRegularExpression {
        do { return try NSRegularExpression(pattern: pattern, options: caseInsensitive ? [.caseInsensitive] : []) } catch { throw XLError.value }
    }

    func textDateFunction(_ name: String, _ x: FArgs) throws -> Operand? {
        func r(_ d: Double) throws -> Operand {
            guard d.isFinite else { throw XLError.num }
            return .value(.number(d))
        }
        func s(_ v: String) -> Operand { .value(.string(v)) }
        switch name {
        case "PROPER":
            var out = "", afterLetter = false
            for ch in try x.t(0) {
                out += afterLetter ? ch.lowercased() : ch.uppercased()
                afterLetter = ch.isLetter
            }
            return s(out)
        case "CLEAN":
            return s(String(String.UnicodeScalarView(try x.t(0).unicodeScalars.filter { $0.value >= 32 })))
        case "NUMBERVALUE":
            var text = try x.t(0)
            let dec = x.has(1) ? try x.t(1) : NumberFormat.decimal
            let group = x.has(2) ? try x.t(2) : (NumberFormat.decimal == "," ? "\u{00A0}" : ",")
            guard let d0 = dec.first else { throw XLError.value }
            text = text.filter { !$0.isWhitespace }
            var percent = 0
            while text.hasSuffix("%") { text.removeLast(); percent += 1 }
            if let g = group.first, g != d0 { text = text.replacingOccurrences(of: String(g), with: "") }
            guard text.filter({ $0 == d0 }).count <= 1 else { throw XLError.value }
            text = text.replacingOccurrences(of: String(d0), with: ".")
            if text.isEmpty { return .value(.number(0)) }
            guard let v = Double(text) else { throw XLError.value }
            return try r(v / pow(100, Double(percent)))
        case "FIXED", "DOLLAR":
            let v = try x.n(0), decimals = try x.int(1, 2)
            guard decimals <= 127 else { throw XLError.value }
            let f = pow(10, Double(decimals))
            let rounded = ((v * f * 1e9).rounded() / 1e9).rounded(.toNearestOrAwayFromZero) / f
            let zeros = decimals > 0 ? "." + String(repeating: "0", count: decimals) : ""
            if name == "FIXED" {
                let code = (try x.b(2, false) ? "0" : "#,##0") + zeros
                return s(NumberFormat.format(.number(rounded), code).text)
            }
            let symbol = Locale.current.currencySymbol ?? "$"
            let body = "#,##0" + zeros
            let code = Locale.current.currency?.identifier == "USD" || NumberFormat.decimal == "."
                ? "\"\(symbol)\"\(body);(\"\(symbol)\"\(body))" : "\(body) \"\(symbol)\";-\(body) \"\(symbol)\""
            return s(NumberFormat.format(.number(rounded), code).text)
        case "TEXTBEFORE", "TEXTAFTER":
            try x.need(2)
            let text = try x.t(0)
            let delims = x.m(1).values.map(self.text)
            var k = try x.int(2, 1)
            let ci = try x.int(3, 0) == 1, matchEnd = try x.int(4, 0) == 1
            guard k != 0, abs(k) <= max(1, text.count) else { throw XLError.value }
            if delims.allSatisfy(\.isEmpty) {
                return s(k > 0 ? (name == "TEXTBEFORE" ? "" : text) : (name == "TEXTBEFORE" ? text : ""))
            }
            var found = Self.delimiterRanges(text, delims, caseInsensitive: ci)
            if matchEnd {
                if k > 0 { found.append(text.endIndex..<text.endIndex) } else { found.insert(text.startIndex..<text.startIndex, at: 0) }
            }
            guard abs(k) <= found.count else {
                if x.has(5) { return x.op(5) }
                throw XLError.na
            }
            if k < 0 { k = found.count + k + 1 }
            let hit = found[k - 1]
            return s(name == "TEXTBEFORE" ? String(text[..<hit.lowerBound]) : String(text[hit.upperBound...]))
        case "TEXTSPLIT":
            try x.need(2)
            let text = try x.t(0)
            let colD: [String] = x.has(1) ? x.m(1).values.map(self.text) : []
            let rowD: [String] = x.has(2) ? x.m(2).values.map(self.text) : []
            let ignoreEmpty = try x.b(3, false), ci = try x.int(4, 0) == 1
            let pad = x.has(5) ? x.a(5) : .error("#N/A")
            guard !colD.allSatisfy(\.isEmpty) || !rowD.allSatisfy(\.isEmpty) else { throw XLError.value }
            func split(_ t: String, _ d: [String]) -> [String] {
                guard !d.allSatisfy(\.isEmpty) else { return [t] }
                var parts: [String] = [], from = t.startIndex
                for range in Self.delimiterRanges(t, d, caseInsensitive: ci) {
                    parts.append(String(t[from..<range.lowerBound]))
                    from = range.upperBound
                }
                parts.append(String(t[from...]))
                return ignoreEmpty ? parts.filter { !$0.isEmpty } : parts
            }
            let rows = split(text, rowD).map { split($0, colD) }
            let w = rows.map(\.count).max() ?? 0
            let m = Matrix(rows: rows.count, cols: max(1, w), values: rows.flatMap { r in r.map { Value.string($0) } + Array(repeating: pad, count: max(1, w) - r.count) })
            return m.count == 1 ? .value(m.values[0]) : x.matrixOp(m)
        case "REGEX":
            try x.need(2)
            let text = try x.t(0), re = try regex(try x.t(1), caseInsensitive: false)
            let ns = text as NSString
            let all = re.matches(in: text, range: NSRange(location: 0, length: ns.length))
            var occurrence = 1, global = false
            if x.has(3) {
                if case .string(let f) = x.a(3) { global = f.contains("g") } else { occurrence = try x.int(3) }
            }
            if !x.has(2) {
                guard occurrence >= 1, occurrence <= all.count else { throw XLError.na }
                return s(ns.substring(with: all[occurrence - 1].range))
            }
            let replacement = try x.t(2, "")
            if global || occurrence == 0 {
                return s(re.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: ns.length), withTemplate: replacement))
            }
            guard occurrence >= 1, occurrence <= all.count else { return s(text) }
            let m = all[occurrence - 1]
            let rep = re.replacementString(for: m, in: text, offset: 0, template: replacement)
            return s(ns.replacingCharacters(in: m.range, with: rep))
        case "REGEXTEST":
            try x.need(2)
            let text = try x.t(0), re = try regex(try x.t(1), caseInsensitive: try x.int(2, 0) == 1)
            return .value(.bool(re.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil))
        case "REGEXEXTRACT":
            try x.need(2)
            let text = try x.t(0), re = try regex(try x.t(1), caseInsensitive: try x.int(3, 0) == 1)
            let ns = text as NSString
            let mode = try x.int(2, 0)
            let all = re.matches(in: text, range: NSRange(location: 0, length: ns.length))
            guard let first = all.first else { throw XLError.na }
            switch mode {
            case 0: return s(ns.substring(with: first.range))
            case 1:
                let v = all.map { Value.string(ns.substring(with: $0.range)) }
                return v.count == 1 ? .value(v[0]) : x.matrixOp(Matrix(rows: v.count, cols: 1, values: v))
            case 2:
                let v = (1..<max(2, first.numberOfRanges)).map { i -> Value in
                    let rg = first.range(at: i)
                    return .string(rg.location == NSNotFound ? "" : ns.substring(with: rg))
                }
                return v.count == 1 ? .value(v[0]) : x.matrixOp(Matrix(rows: 1, cols: v.count, values: v))
            default: throw XLError.value
            }
        case "REGEXREPLACE":
            try x.need(3)
            let text = try x.t(0), re = try regex(try x.t(1), caseInsensitive: try x.int(4, 0) == 1)
            let replacement = try x.t(2), occurrence = try x.int(3, 0)
            let ns = text as NSString
            if occurrence == 0 { return s(re.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: ns.length), withTemplate: replacement)) }
            let all = re.matches(in: text, range: NSRange(location: 0, length: ns.length))
            let k = occurrence > 0 ? occurrence - 1 : all.count + occurrence
            guard k >= 0, k < all.count else { return s(text) }
            return s(ns.replacingCharacters(in: all[k].range, with: re.replacementString(for: all[k], in: text, offset: 0, template: replacement)))
        case "HYPERLINK":
            try x.need(1)
            return x.has(1) ? x.op(1) : .value(.string(try x.t(0)))

        // Dates
        case "DATEVALUE":
            let v = x.a(0)
            if case .number(let d) = v { return try r(floor(d)) }
            guard let d = DateMath.parse(try x.t(0), date1904: workbook.date1904) else { throw XLError.value }
            return try r(floor(d))
        case "TIMEVALUE":
            let t = try x.t(0)
            guard let d = DateMath.parse(t) ?? DateMath.parseTime(t) else { throw XLError.value }
            return try r(d - floor(d))
        case "WEEKNUM":
            let serial = floor(try x.n(0)) + dateOffset
            let type = try x.int(1, 1)
            guard serial >= dateOffset, let c = DateMath.components(serial), let jan1 = DateMath.serial(year: c.year!, month: 1, day: 1) else { throw XLError.num }
            if type == 21 { return try r(Double(Self.isoWeek(serial))) }
            let start: Int   // first day of the week, 0 = Monday
            switch type {
            case 1, 17: start = 6
            case 2, 11: start = 0
            case 12...16: start = type - 11
            default: throw XLError.num
            }
            let offset = (Self.isoWeekday(jan1) - start + 7) % 7
            return try r(floor((serial - jan1 + Double(offset)) / 7) + 1)
        case "ISOWEEKNUM":
            let serial = floor(try x.n(0)) + dateOffset
            guard serial >= dateOffset, serial <= 2_958_465 else { throw XLError.num }
            return try r(Double(Self.isoWeek(serial)))
        case "YEARFRAC":
            try x.need(2)
            var a = floor(try x.n(0)) + dateOffset, b = floor(try x.n(1)) + dateOffset
            let basis = try x.int(2, 0)
            guard a >= dateOffset, b >= dateOffset, a <= 2_958_465, b <= 2_958_465, (0...4).contains(basis) else { throw XLError.num }
            if a > b { swap(&a, &b) }
            return try r(Self.yearFrac(a, b, basis: basis))
        case "DAYS360":
            try x.need(2)
            let a = floor(try x.n(0)) + dateOffset, b = floor(try x.n(1)) + dateOffset
            guard a >= dateOffset, b >= dateOffset, a <= 2_958_465, b <= 2_958_465 else { throw XLError.num }
            return try r(Self.days360(a, b, european: try x.b(2, false)))
        case "NETWORKDAYS", "NETWORKDAYS.INTL":
            try x.need(2)
            var s1 = floor(try x.n(0)) + dateOffset, s2 = floor(try x.n(1)) + dateOffset
            let intl = name.hasSuffix("INTL")
            let mask = try weekendMask(intl && x.has(2) ? x.a(2) : .empty)
            let hol = try holidays(x, intl ? 3 : 2)
            let sign: Double = s2 < s1 ? -1 : 1
            if s2 < s1 { swap(&s1, &s2) }
            guard s1 >= dateOffset, s2 <= 2_958_465 else { throw XLError.num }
            var count = 0.0, d = s1
            while d <= s2 {
                if !mask[Self.isoWeekday(d)] && !hol.contains(d) { count += 1 }
                d += 1
            }
            return .value(.number(count * sign))
        case "WORKDAY", "WORKDAY.INTL":
            try x.need(2)
            var d = floor(try x.n(0)) + dateOffset
            var left = try x.int(1)
            let intl = name.hasSuffix("INTL")
            let mask = try weekendMask(intl && x.has(2) ? x.a(2) : .empty)
            let hol = try holidays(x, intl ? 3 : 2)
            guard d >= dateOffset, d <= 2_958_465, abs(left) < 3_000_000 else { throw XLError.num }
            let step: Double = left < 0 ? -1 : 1
            while left != 0 {
                d += step
                guard d >= dateOffset, d <= 2_958_465 else { throw XLError.num }
                if !mask[Self.isoWeekday(d)] && !hol.contains(d) { left -= Int(step) }
            }
            return .value(.number(d - dateOffset))
        default:
            return nil
        }
    }

    static func isoWeek(_ serial: Double) -> Int {
        // Thursday of this week decides the year.
        let wd = isoWeekday(serial)
        let thursday = serial - Double(wd) + 3
        guard let c = DateMath.components(thursday), let jan1 = DateMath.serial(year: c.year!, month: 1, day: 1) else { return 0 }
        return Int((thursday - jan1) / 7) + 1
    }

    static func isLeap(_ y: Int) -> Bool { (y % 4 == 0 && y % 100 != 0) || y % 400 == 0 }

    static func days360(_ a: Double, _ b: Double, european: Bool) -> Double {
        guard let ca = DateMath.components(a), let cb = DateMath.components(b) else { return 0 }
        var d1 = ca.day!, d2 = cb.day!
        let m1 = ca.month!, m2 = cb.month!, y1 = ca.year!, y2 = cb.year!
        if european {
            if d1 == 31 { d1 = 30 }
            if d2 == 31 { d2 = 30 }
        } else {
            let lastFeb1 = m1 == 2 && d1 == DateMath.daysInMonth(year: y1, month: 2)
            if lastFeb1 || d1 == 31 { d1 = 30 }
            if d2 == 31 && d1 >= 30 { d2 = 30 }
        }
        let days: Int = (y2 - y1) * 360 + (m2 - m1) * 30 + (d2 - d1)
        return Double(days)
    }

    static func yearFrac(_ a: Double, _ b: Double, basis: Int) -> Double {
        guard let ca = DateMath.components(a), let cb = DateMath.components(b) else { return 0 }
        let y1 = ca.year!, m1 = ca.month!, d1 = ca.day!, y2 = cb.year!, m2 = cb.month!, d2 = cb.day!
        switch basis {
        case 0:
            var dd1 = d1, dd2 = d2
            let feb1 = m1 == 2 && d1 == DateMath.daysInMonth(year: y1, month: 2)
            let feb2 = m2 == 2 && d2 == DateMath.daysInMonth(year: y2, month: 2)
            if feb1 && feb2 { dd2 = 30 }
            if feb1 { dd1 = 30 }
            if dd2 == 31 && dd1 >= 30 { dd2 = 30 }
            if dd1 == 31 { dd1 = 30 }
            let days: Int = (y2 - y1) * 360 + (m2 - m1) * 30 + (dd2 - dd1)
            return Double(days) / 360
        case 1:
            let days = b - a
            let withinYear = y1 == y2 || (y2 == y1 + 1 && (m1 > m2 || (m1 == m2 && d1 >= d2)))
            if withinYear {
                var leap = false
                if y1 == y2 { leap = isLeap(y1) }
                else {
                    // A 29 February between the dates (inclusive of the end).
                    if isLeap(y1), let feb29 = DateMath.serial(year: y1, month: 2, day: 29), a <= feb29 { leap = true }
                    if isLeap(y2), let feb29 = DateMath.serial(year: y2, month: 2, day: 29), b >= feb29 { leap = true }
                }
                return days / (leap ? 366 : 365)
            }
            let total = (y1...y2).map { isLeap($0) ? 366.0 : 365.0 }.reduce(0, +)
            return days / (total / Double(y2 - y1 + 1))
        case 2: return (b - a) / 360
        case 3: return (b - a) / 365
        default: return days360(a, b, european: true) / 360
        }
    }
}
