import Foundation
import Kit42

/// Probability distributions and special functions (as Excel/LibreOffice compute them).
enum Distributions {
    static func normCDF(_ z: Double) -> Double { 0.5 * erfc(-z / 2.0.squareRoot()) }
    static func normPDF(_ z: Double) -> Double { exp(-z * z / 2) / (2 * Double.pi).squareRoot() }

    /// Inverse standard normal (Wichura, AS 241, ~1e-16).
    static func normInv(_ p: Double) -> Double {
        let q = p - 0.5
        if abs(q) <= 0.425 {
            let r = 0.180625 - q * q
            let num = ((((((r * 2509.0809287301226727 + 33430.575583588128105) * r + 67265.770927008700853) * r
                        + 45921.953931549871457) * r + 13731.693765509461125) * r + 1971.5909503065514427) * r
                        + 133.14166789178437745) * r + 3.387132872796366608
            let den = ((((((r * 5226.495278852545925 + 28729.085735721942674) * r + 39307.89580009271061) * r
                        + 21213.794301586595867) * r + 5394.1960214247511077) * r + 687.1870074920579083) * r
                        + 42.313330701600911252) * r + 1
            return q * num / den
        }
        var r = q < 0 ? p : 1 - p
        r = (-log(r)).squareRoot()
        var v: Double
        if r <= 5 {
            r -= 1.6
            v = (((((((r * 7.7454501427834140764e-4 + 0.0227238449892691845833) * r + 0.24178072517745061177) * r
                  + 1.27045825245236838258) * r + 3.64784832476320460504) * r + 5.7694972214606914055) * r
                  + 4.6303378461565452959) * r + 1.42343711074968357734)
                / (((((((r * 1.05075007164441684324e-9 + 5.475938084995344946e-4) * r + 0.0151986665636164571966) * r
                    + 0.14810397642748007459) * r + 0.68976733498510000455) * r + 1.6763848301838038494) * r
                    + 2.05319162663775882187) * r + 1)
        } else {
            r -= 5
            v = (((((((r * 2.01033439929228813265e-7 + 2.71155556874348757815e-5) * r + 0.0012426609473880784386) * r
                  + 0.026532189526576123093) * r + 0.29656057182850489123) * r + 1.7848265399172913358) * r
                  + 5.4637849111641143699) * r + 6.6579046435011037772)
                / (((((((r * 2.04426310338993978564e-15 + 1.4215117583164458887e-7) * r + 1.8463183175100546818e-5) * r
                    + 7.868691311456132591e-4) * r + 0.0148753612908506148525) * r + 0.13692988092273580531) * r
                    + 0.59983220655588793769) * r + 1)
        }
        return q < 0 ? -v : v
    }

    /// Regularized lower incomplete gamma P(a, x).
    static func gammaP(_ a: Double, _ x: Double) -> Double {
        guard x > 0 else { return 0 }
        if x < a + 1 {
            var sum = 1 / a, term = sum, n = a
            for _ in 0..<10_000 {
                n += 1
                term *= x / n
                sum += term
                if abs(term) < abs(sum) * 1e-16 { break }
            }
            let lx: Double = log(x), la: Double = lgamma(a)
            return sum * exp(-x + a * lx - la)
        }
        return 1 - gammaQcf(a, x)
    }

    /// Q(a, x) by continued fraction (x ≥ a + 1).
    static func gammaQcf(_ a: Double, _ x: Double) -> Double {
        let tiny = 1e-300
        var b = x + 1 - a, c = 1 / tiny, d = 1 / b, h = d
        for i in 1...10_000 {
            let an = -Double(i) * (Double(i) - a)
            b += 2
            d = an * d + b; if abs(d) < tiny { d = tiny }
            c = b + an / c; if abs(c) < tiny { c = tiny }
            d = 1 / d
            let del = d * c
            h *= del
            if abs(del - 1) < 1e-16 { break }
        }
        let lx: Double = log(x), la: Double = lgamma(a)
        return exp(-x + a * lx - la) * h
    }

    /// Regularized incomplete beta I_x(a, b).
    static func betaI(_ x: Double, _ a: Double, _ b: Double) -> Double {
        if x <= 0 { return 0 }
        if x >= 1 { return 1 }
        let lnBeta: Double = lgamma(a + b) - lgamma(a) - lgamma(b)
        let lx: Double = log(x), l1x: Double = log(1 - x)
        let bt = exp(lnBeta + a * lx + b * l1x)
        if x < (a + 1) / (a + b + 2) { return bt * betacf(x, a, b) / a }
        return 1 - bt * betacf(1 - x, b, a) / b
    }

    private static func betacf(_ x: Double, _ a: Double, _ b: Double) -> Double {
        let tiny = 1e-300
        let qab = a + b, qap = a + 1, qam = a - 1
        var c = 1.0, d = 1 - qab * x / qap
        if abs(d) < tiny { d = tiny }
        d = 1 / d
        var h = d
        for m in 1...10_000 {
            let m = Double(m), m2 = 2 * m
            var aa = m * (b - m) * x / ((qam + m2) * (a + m2))
            d = 1 + aa * d; if abs(d) < tiny { d = tiny }
            c = 1 + aa / c; if abs(c) < tiny { c = tiny }
            d = 1 / d
            h *= d * c
            aa = -(a + m) * (qab + m) * x / ((a + m2) * (qap + m2))
            d = 1 + aa * d; if abs(d) < tiny { d = tiny }
            c = 1 + aa / c; if abs(c) < tiny { c = tiny }
            d = 1 / d
            let del = d * c
            h *= del
            if abs(del - 1) < 1e-16 { break }
        }
        return h
    }

    static func tCDF(_ t: Double, _ df: Double) -> Double {
        let x = df / (df + t * t)
        let tail = 0.5 * betaI(x, df / 2, 0.5)
        return t >= 0 ? 1 - tail : tail
    }

    static func tPDF(_ t: Double, _ df: Double) -> Double {
        let c: Double = exp(lgamma((df + 1) / 2) - lgamma(df / 2)) / (df * Double.pi).squareRoot()
        return c * pow(1 + t * t / df, -(df + 1) / 2)
    }

    static func fCDF(_ x: Double, _ d1: Double, _ d2: Double) -> Double {
        x <= 0 ? 0 : betaI(d1 * x / (d1 * x + d2), d1 / 2, d2 / 2)
    }

    static func fPDF(_ x: Double, _ d1: Double, _ d2: Double) -> Double {
        guard x > 0 else { return 0 }
        let lnB: Double = lgamma(d1 / 2) + lgamma(d2 / 2) - lgamma((d1 + d2) / 2)
        let t1: Double = (d1 / 2) * log(d1 / d2), t2: Double = (d1 / 2 - 1) * log(x)
        let t3: Double = ((d1 + d2) / 2) * log(1 + d1 * x / d2)
        return exp(t1 + t2 - t3 - lnB)
    }

    static func gammaPDF(_ x: Double, _ a: Double, _ b: Double) -> Double {
        if x == 0 { return a == 1 ? 1 / b : (a < 1 ? .infinity : 0) }
        let la: Double = lgamma(a), lx: Double = log(x), lb: Double = log(b)
        return exp((a - 1) * lx - x / b - la - a * lb)
    }

    static func betaPDF(_ x: Double, _ a: Double, _ b: Double) -> Double {
        guard x > 0, x < 1 else { return 0 }
        let lnB: Double = lgamma(a) + lgamma(b) - lgamma(a + b)
        let lx: Double = log(x), l1x: Double = log(1 - x)
        return exp((a - 1) * lx + (b - 1) * l1x - lnB)
    }

    /// Inverts an increasing cdf on [lo, hi] by bisection (then a few secant steps).
    static func invert(_ p: Double, lo: Double, hi: Double, _ cdf: (Double) -> Double) -> Double? {
        var lo = lo, hi = hi
        // Grow the upper bound for unbounded distributions.
        var guardCount = 0
        while cdf(hi) < p, guardCount < 200 { lo = hi; hi *= 2; guardCount += 1 }
        guard cdf(hi) >= p else { return nil }
        for _ in 0..<300 {
            let mid = (lo + hi) / 2
            if mid == lo || mid == hi { break }
            if cdf(mid) < p { lo = mid } else { hi = mid }
            if hi - lo <= 1e-15 * max(1, abs(mid)) { break }
        }
        return (lo + hi) / 2
    }

    static func binomPMF(_ k: Double, _ n: Double, _ p: Double) -> Double {
        if p == 0 { return k == 0 ? 1 : 0 }
        if p == 1 { return k == n ? 1 : 0 }
        let lc: Double = lgamma(n + 1) - lgamma(k + 1) - lgamma(n - k + 1)
        let lp: Double = log(p), lq: Double = log(1 - p)
        return exp(lc + k * lp + (n - k) * lq)
    }

    static func poissonPMF(_ k: Double, _ m: Double) -> Double {
        if m == 0 { return k == 0 ? 1 : 0 }
        let lm: Double = log(m), lk: Double = lgamma(k + 1)
        return exp(k * lm - m - lk)
    }
}

extension Calculator {
    /// Pairs of numbers at the same positions of two arrays (other pairs skipped); sizes must match.
    func numberPairs(_ x: FArgs, _ i: Int, _ j: Int) throws -> ([Double], [Double]) {
        let a = x.m(i), b = x.m(j)
        guard a.count == b.count else { throw XLError.na }
        var xs: [Double] = [], ys: [Double] = []
        for k in 0..<a.count {
            if case .error(let e) = a.values[k] { throw XLError(code: e) }
            if case .error(let e) = b.values[k] { throw XLError(code: e) }
            if case .number(let p) = a.values[k], case .number(let q) = b.values[k] { xs.append(p); ys.append(q) }
        }
        return (xs, ys)
    }

    static func mean(_ v: [Double]) -> Double { v.reduce(0, +) / Double(v.count) }

    static func percentileInc(_ s: [Double], _ k: Double) -> Double {
        let h = (Double(s.count) - 1) * k
        let lo = Int(floor(h))
        if lo + 1 >= s.count { return s[s.count - 1] }
        return s[lo] + (h - Double(lo)) * (s[lo + 1] - s[lo])
    }

    static func percentileExc(_ s: [Double], _ k: Double) throws -> Double {
        let n = Double(s.count)
        guard k > 0, k < 1, k >= 1 / (n + 1), k <= n / (n + 1) else { throw XLError.num }
        let h = (n + 1) * k - 1
        let lo = Int(floor(h))
        if lo + 1 >= s.count { return s[s.count - 1] }
        return s[lo] + (h - Double(lo)) * (s[lo + 1] - s[lo])
    }

    /// Regression of y on columns of X (with intercept when `const`) for LINEST/TREND/GROWTH.
    struct Regression {
        var slopes: [Double]   // per x variable, in input order
        var intercept: Double
        var xs: [[Double]]     // observations × variables
        var y: [Double]
        var xtxInv: [Double]
        var const: Bool
    }

    /// known_y and known_x of LINEST/TREND as observations × variables.
    func regressionData(_ x: FArgs, yIndex: Int, xIndex: Int, log: Bool) throws -> (y: [Double], xs: [[Double]], byRows: Bool) {
        let ym = x.m(yIndex)
        var y = try numericMatrix(ym).v
        if log {
            guard y.allSatisfy({ $0 > 0 }) else { throw XLError.num }
            y = y.map { Foundation.log($0) }
        }
        let n = y.count
        var xs: [[Double]]
        let byRows = ym.rows == 1 && ym.cols > 1
        if x.has(xIndex) {
            let xm = x.m(xIndex)
            let v = try numericMatrix(xm)
            if xm.count == n {
                xs = v.v.map { [$0] }
            } else if ym.cols == 1, xm.rows == n {
                xs = (0..<n).map { r in (0..<xm.cols).map { v.v[r * xm.cols + $0] } }
            } else if ym.rows == 1, xm.cols == n {
                xs = (0..<n).map { c in (0..<xm.rows).map { v.v[$0 * xm.cols + c] } }
            } else { throw XLError.ref }
        } else {
            xs = (1...max(1, n)).map { [Double($0)] }
        }
        return (y, xs, byRows)
    }

    func regress(_ y: [Double], _ xs: [[Double]], const: Bool) throws -> Regression {
        let n = y.count, k = xs.first?.count ?? 0
        let cols = k + (const ? 1 : 0)
        guard n > 0, n >= cols || (n == 1 && !const) else { throw XLError.num }
        var X: [Double] = []
        for row in xs { X += row; if const { X.append(1) } }
        guard let fit = LinearAlgebra.leastSquares(X, n: n, k: cols, y) else {
            // Collinear x: Excel/LibreOffice still fit; fall back to zero slopes.
            throw XLError.num
        }
        return Regression(slopes: Array(fit.beta.prefix(k)), intercept: const ? fit.beta[k] : 0, xs: xs, y: y, xtxInv: fit.xtxInv, const: const)
    }

    func statFunction(_ name: String, _ x: FArgs) throws -> Operand? {
        func r(_ d: Double) throws -> Operand {
            guard d.isFinite else { throw XLError.num }
            return .value(.number(d))
        }
        func variance(_ v: [Double], sample: Bool) throws -> Double {
            guard v.count > (sample ? 1 : 0) else { throw XLError.div0 }
            let m = Self.mean(v)
            return v.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(v.count - (sample ? 1 : 0))
        }
        func prob(_ p: Double) throws { guard p >= 0, p <= 1 else { throw XLError.num } }
        func openProb(_ p: Double) throws { guard p > 0, p < 1 else { throw XLError.num } }

        switch name {
        case "STDEVA", "STDEVPA", "VARA", "VARPA":
            let v = try x.allNums(countText: true)
            let s = try variance(v, sample: !name.contains("P"))
            return try r(name.hasPrefix("VAR") ? s : s.squareRoot())
        case "STDEVP": return try r(variance(x.allNums(), sample: false).squareRoot())
        case "VARP": return try r(variance(x.allNums(), sample: false))
        case "MAXA", "MINA":
            let v = try x.allNums(countText: true)
            return try r(v.isEmpty ? 0 : (name == "MAXA" ? v.max()! : v.min()!))
        case "AVEDEV":
            let v = try x.allNums()
            guard !v.isEmpty else { throw XLError.num }
            let m = Self.mean(v)
            return try r(v.map { abs($0 - m) }.reduce(0, +) / Double(v.count))
        case "DEVSQ":
            let v = try x.allNums()
            guard !v.isEmpty else { return .value(.number(0)) }
            let m = Self.mean(v)
            return try r(v.map { ($0 - m) * ($0 - m) }.reduce(0, +))
        case "GEOMEAN":
            let v = try x.allNums()
            guard !v.isEmpty, v.allSatisfy({ $0 > 0 }) else { throw XLError.num }
            return try r(exp(v.map(log).reduce(0, +) / Double(v.count)))
        case "HARMEAN":
            let v = try x.allNums()
            guard !v.isEmpty, v.allSatisfy({ $0 > 0 }) else { throw XLError.num }
            return try r(Double(v.count) / v.map { 1 / $0 }.reduce(0, +))
        case "KURT":
            let v = try x.allNums()
            let n = Double(v.count)
            guard v.count >= 4 else { throw XLError.div0 }
            let m = Self.mean(v), s = try variance(v, sample: true).squareRoot()
            guard s > 0 else { throw XLError.div0 }
            let sum4 = v.map { pow(($0 - m) / s, 4) }.reduce(0, +)
            return try r(n * (n + 1) / ((n - 1) * (n - 2) * (n - 3)) * sum4 - 3 * (n - 1) * (n - 1) / ((n - 2) * (n - 3)))
        case "SKEW", "SKEW.P":
            let v = try x.allNums()
            let n = Double(v.count)
            guard v.count >= (name == "SKEW" ? 3 : 1) else { throw XLError.div0 }
            let m = Self.mean(v)
            if name == "SKEW" {
                let s = try variance(v, sample: true).squareRoot()
                guard s > 0 else { throw XLError.div0 }
                return try r(n / ((n - 1) * (n - 2)) * v.map { pow(($0 - m) / s, 3) }.reduce(0, +))
            }
            let s = try variance(v, sample: false).squareRoot()
            guard s > 0 else { throw XLError.div0 }
            return try r(v.map { pow(($0 - m) / s, 3) }.reduce(0, +) / n)
        case "STANDARDIZE":
            let v = try x.n(0), m = try x.n(1), s = try x.n(2)
            guard s > 0 else { throw XLError.num }
            return try r((v - m) / s)
        case "MODE.MULT":
            let v = try x.allNums()
            var counts: [Double: Int] = [:]
            v.forEach { counts[$0, default: 0] += 1 }
            let best = counts.values.max() ?? 0
            guard best > 1 else { throw XLError.na }
            var seen = Set<Double>(), out: [Value] = []
            for d in v where counts[d] == best && seen.insert(d).inserted { out.append(.number(d)) }
            return x.matrixOp(Matrix(rows: out.count, cols: 1, values: out))
        case "RANK.AVG":
            try x.need(2)
            let v0 = try x.n(0)
            let v = try x.nums(1)
            let asc = try x.n(2, 0) != 0
            let equal = v.filter { $0 == v0 }.count
            guard equal > 0 else { throw XLError.na }
            let better = v.filter { asc ? $0 < v0 : $0 > v0 }.count
            return try r(Double(better) + Double(equal + 1) / 2)
        case "PERCENTILE", "PERCENTILE.INC", "PERCENTILE.EXC", "QUARTILE", "QUARTILE.INC", "QUARTILE.EXC":
            try x.need(2)
            let s = try x.nums(0).sorted()
            guard !s.isEmpty else { throw XLError.num }
            var k = try x.n(1)
            if name.hasPrefix("QUARTILE") {
                k = k.rounded(.towardZero)
                guard name.hasSuffix("EXC") ? (1...3).contains(k) : (0...4).contains(k) else { throw XLError.num }
                k /= 4
            }
            if name.hasSuffix("EXC") { return try r(Self.percentileExc(s, k)) }
            guard k >= 0, k <= 1 else { throw XLError.num }
            return try r(Self.percentileInc(s, k))
        case "PERCENTRANK", "PERCENTRANK.INC", "PERCENTRANK.EXC":
            try x.need(2)
            let s = try x.nums(0).sorted()
            let v = try x.n(1)
            let sig = try x.int(2, 3)
            guard !s.isEmpty, sig >= 1 else { throw XLError.num }
            guard v >= s.first!, v <= s.last! else { throw XLError.na }
            let exc = name.hasSuffix("EXC")
            let n = Double(s.count)
            let less = Double(s.filter { $0 < v }.count)
            var pr: Double
            if s.contains(v) {
                if s.count == 1 { pr = 1 } else { pr = exc ? (less + 1) / (n + 1) : less / (n - 1) }
            } else {
                let a = s[Int(less) - 1], b = s[Int(less)]
                let frac = (v - a) / (b - a)
                pr = exc ? (less + frac) / (n + 1) : (less - 1 + frac) / (n - 1)
            }
            let f = pow(10, Double(sig))
            return try r(floor(pr * f + 1e-9) / f)
        case "CORREL", "PEARSON", "RSQ":
            try x.need(2)
            let (a, b) = try numberPairs(x, 0, 1)
            guard a.count >= 2 else { throw XLError.div0 }
            let ma = Self.mean(a), mb = Self.mean(b)
            var sab = 0.0, saa = 0.0, sbb = 0.0
            for i in a.indices { sab += (a[i] - ma) * (b[i] - mb); saa += (a[i] - ma) * (a[i] - ma); sbb += (b[i] - mb) * (b[i] - mb) }
            guard saa > 0, sbb > 0 else { throw XLError.div0 }
            let c = sab / (saa * sbb).squareRoot()
            return try r(name == "RSQ" ? c * c : c)
        case "SLOPE", "INTERCEPT", "STEYX":
            try x.need(2)
            let (y, xs) = try numberPairs(x, 0, 1)
            guard y.count >= (name == "STEYX" ? 3 : 1) else { throw XLError.div0 }
            let mx = Self.mean(xs), my = Self.mean(y)
            var sxy = 0.0, sxx = 0.0, syy = 0.0
            for i in y.indices { sxy += (xs[i] - mx) * (y[i] - my); sxx += (xs[i] - mx) * (xs[i] - mx); syy += (y[i] - my) * (y[i] - my) }
            guard sxx > 0 else { throw XLError.div0 }
            let slope = sxy / sxx
            if name == "SLOPE" { return try r(slope) }
            if name == "INTERCEPT" { return try r(my - slope * mx) }
            return try r(((syy - sxy * sxy / sxx) / Double(y.count - 2)).squareRoot())
        case "FORECAST", "FORECAST.LINEAR":
            try x.need(3)
            let v = try x.n(0)
            let (y, xs) = try numberPairs(x, 1, 2)
            guard !y.isEmpty else { throw XLError.div0 }
            let mx = Self.mean(xs), my = Self.mean(y)
            var sxy = 0.0, sxx = 0.0
            for i in y.indices { sxy += (xs[i] - mx) * (y[i] - my); sxx += (xs[i] - mx) * (xs[i] - mx) }
            guard sxx > 0 else { throw XLError.div0 }
            return try r(my + sxy / sxx * (v - mx))
        case "COVAR", "COVARIANCE.P", "COVARIANCE.S":
            try x.need(2)
            let (a, b) = try numberPairs(x, 0, 1)
            let sample = name == "COVARIANCE.S"
            guard a.count > (sample ? 1 : 0) else { throw XLError.div0 }
            let ma = Self.mean(a), mb = Self.mean(b)
            var s = 0.0
            for i in a.indices { s += (a[i] - ma) * (b[i] - mb) }
            return try r(s / Double(a.count - (sample ? 1 : 0)))
        case "LINEST", "LOGEST":
            try x.need(1)
            let (y, xs, _) = try regressionData(x, yIndex: 0, xIndex: 1, log: name == "LOGEST")
            let const = try x.b(2, true), stats = try x.b(3, false)
            let reg = try regress(y, xs, const: const)
            let k = reg.slopes.count, n = y.count
            func out(_ v: Double) -> Value { name == "LOGEST" ? .number(exp(v)) : .number(v) }
            var rows: [[Value]] = [reg.slopes.reversed().map(out) + [out(reg.intercept)]]
            if stats {
                let fitted = reg.xs.map { row in zip(row, reg.slopes).map(*).reduce(0, +) + reg.intercept }
                let my = Self.mean(y)
                let ssresid = zip(y, fitted).map { ($0 - $1) * ($0 - $1) }.reduce(0, +)
                let sstot = const ? y.map { ($0 - my) * ($0 - my) }.reduce(0, +) : y.map { $0 * $0 }.reduce(0, +)
                let ssreg = sstot - ssresid
                let df = n - k - (const ? 1 : 0)
                let sey = df > 0 ? (ssresid / Double(df)).squareRoot() : 0
                let cols = k + (const ? 1 : 0)
                let se = (0..<cols).map { (reg.xtxInv[$0 * cols + $0] * sey * sey).squareRoot() }
                var seRow: [Value] = (0..<k).reversed().map { .number(se[$0]) }
                seRow.append(const ? .number(se[k]) : .error("#N/A"))
                let r2 = sstot > 0 ? ssreg / sstot : 1
                let f = df > 0 && ssresid > 0 ? (ssreg / Double(k)) / (ssresid / Double(df)) : 0
                func padded(_ a: [Value]) -> [Value] { a + Array(repeating: .error("#N/A"), count: k + 1 - a.count) }
                rows.append(seRow)
                rows.append(padded([.number(r2), .number(sey)]))
                rows.append(padded([.number(f), .number(Double(df))]))
                rows.append(padded([.number(ssreg), .number(ssresid)]))
            }
            return x.matrixOp(Matrix(rows))
        case "TREND", "GROWTH":
            try x.need(1)
            let (y, xs, byRows) = try regressionData(x, yIndex: 0, xIndex: 1, log: name == "GROWTH")
            let const = try x.b(3, true)
            let reg = try regress(y, xs, const: const)
            var newXs = xs
            var shape = (rows: byRows ? 1 : xs.count, cols: byRows ? xs.count : 1)
            if x.has(2) {
                let nm = x.m(2)
                let v = try numericMatrix(nm)
                let k = reg.slopes.count
                if k == 1 {
                    newXs = v.v.map { [$0] }
                    shape = (nm.rows, nm.cols)
                } else if !byRows, nm.cols == k {
                    newXs = (0..<nm.rows).map { r in (0..<k).map { v.v[r * nm.cols + $0] } }
                    shape = (nm.rows, 1)
                } else if byRows, nm.rows == k {
                    newXs = (0..<nm.cols).map { c in (0..<k).map { v.v[$0 * nm.cols + c] } }
                    shape = (1, nm.cols)
                } else { throw XLError.ref }
            }
            let values: [Value] = newXs.map { row in
                let f = zip(row, reg.slopes).map(*).reduce(0, +) + reg.intercept
                return .number(name == "GROWTH" ? exp(f) : f)
            }
            if values.count == 1 { return .value(values[0]) }
            return x.matrixOp(Matrix(rows: shape.rows, cols: shape.cols, values: values))

        // Distributions
        case "NORM.DIST", "NORMDIST":
            try x.need(name == "NORMDIST" ? 4 : 3)
            let v = try x.n(0), m = try x.n(1), s = try x.n(2), cum = try x.b(3, false)
            guard s > 0 else { throw XLError.num }
            let z = (v - m) / s
            return try r(cum ? Distributions.normCDF(z) : Distributions.normPDF(z) / s)
        case "NORM.S.DIST":
            try x.need(1)
            let z = try x.n(0), cum = try x.b(1, true)
            return try r(cum ? Distributions.normCDF(z) : Distributions.normPDF(z))
        case "NORMSDIST": return try r(Distributions.normCDF(x.n(0)))
        case "PHI": return try r(Distributions.normPDF(x.n(0)))
        case "GAUSS": return try r(Distributions.normCDF(x.n(0)) - 0.5)
        case "NORM.INV", "NORMINV":
            try x.need(3)
            let p = try x.n(0), m = try x.n(1), s = try x.n(2)
            try openProb(p)
            guard s > 0 else { throw XLError.num }
            return try r(m + s * Distributions.normInv(p))
        case "NORM.S.INV", "NORMSINV":
            let p = try x.n(0)
            try openProb(p)
            return try r(Distributions.normInv(p))
        case "LOGNORM.DIST", "LOGNORMDIST":
            try x.need(3)
            let v = try x.n(0), m = try x.n(1), s = try x.n(2), cum = name == "LOGNORMDIST" ? true : try x.b(3, false)
            guard v > 0, s > 0 else { throw XLError.num }
            let z = (log(v) - m) / s
            return try r(cum ? Distributions.normCDF(z) : Distributions.normPDF(z) / (s * v))
        case "LOGNORM.INV", "LOGINV":
            let p = try x.n(0), m = try x.n(1), s = try x.n(2)
            try openProb(p)
            guard s > 0 else { throw XLError.num }
            return try r(exp(m + s * Distributions.normInv(p)))
        case "CONFIDENCE", "CONFIDENCE.NORM", "CONFIDENCE.T":
            let alpha = try x.n(0), s = try x.n(1), n = Double(try x.int(2))
            guard alpha > 0, alpha < 1, s > 0, n >= 1 else { throw XLError.num }
            if name == "CONFIDENCE.T" {
                guard n >= 2 else { throw XLError.div0 }
                guard let t = Distributions.invert(1 - alpha / 2, lo: 0, hi: 10, { Distributions.tCDF($0, n - 1) }) else { throw XLError.num }
                return try r(t * s / n.squareRoot())
            }
            return try r(Distributions.normInv(1 - alpha / 2) * s / n.squareRoot())
        case "T.DIST":
            try x.need(3)
            let t = try x.n(0), df = try x.n(1).rounded(.towardZero), cum = try x.b(2, false)
            guard df >= 1 else { throw XLError.num }
            return try r(cum ? Distributions.tCDF(t, df) : Distributions.tPDF(t, df))
        case "T.DIST.2T", "T.DIST.RT", "TDIST":
            let t = try x.n(0), df = try x.n(1).rounded(.towardZero)
            guard df >= 1 else { throw XLError.num }
            var tails = name == "T.DIST.2T" ? 2 : 1
            if name == "TDIST" { tails = try x.int(2); guard tails == 1 || tails == 2, t >= 0 else { throw XLError.num } }
            if name == "T.DIST.2T" { guard t >= 0 else { throw XLError.num } }
            let right = 1 - Distributions.tCDF(t, df)
            return try r(tails == 2 ? 2 * right : right)
        case "T.INV", "T.INV.2T", "TINV":
            let p = try x.n(0), df = try x.n(1).rounded(.towardZero)
            guard df >= 1 else { throw XLError.num }
            if name == "T.INV" {
                try openProb(p)
                if p == 0.5 { return .value(.number(0)) }
                let q = p > 0.5 ? p : 1 - p
                guard let t = Distributions.invert(q, lo: 0, hi: 10, { Distributions.tCDF($0, df) }) else { throw XLError.num }
                return try r(p > 0.5 ? t : -t)
            }
            guard p > 0, p <= 1 else { throw XLError.num }
            guard let t = Distributions.invert(1 - p / 2, lo: 0, hi: 10, { Distributions.tCDF($0, df) }) else { throw XLError.num }
            return try r(t)
        case "CHISQ.DIST":
            try x.need(3)
            let v = try x.n(0), df = try x.n(1).rounded(.towardZero), cum = try x.b(2, false)
            guard v >= 0, df >= 1 else { throw XLError.num }
            return try r(cum ? Distributions.gammaP(df / 2, v / 2) : Distributions.gammaPDF(v, df / 2, 2))
        case "CHISQ.DIST.RT", "CHIDIST":
            let v = try x.n(0), df = try x.n(1).rounded(.towardZero)
            guard v >= 0, df >= 1 else { throw XLError.num }
            return try r(1 - Distributions.gammaP(df / 2, v / 2))
        case "CHISQ.INV", "CHISQ.INV.RT", "CHIINV":
            let p = try x.n(0), df = try x.n(1).rounded(.towardZero)
            try prob(p)
            guard df >= 1 else { throw XLError.num }
            let target = name == "CHISQ.INV" ? p : 1 - p
            if target == 0 { return .value(.number(0)) }
            guard target < 1, let v = Distributions.invert(target, lo: 0, hi: max(10, df * 4), { Distributions.gammaP(df / 2, $0 / 2) }) else { throw XLError.num }
            return try r(v)
        case "F.DIST", "F.DIST.RT", "FDIST":
            let v = try x.n(0), d1 = try x.n(1).rounded(.towardZero), d2 = try x.n(2).rounded(.towardZero)
            guard v >= 0, d1 >= 1, d2 >= 1 else { throw XLError.num }
            if name == "F.DIST" {
                return try r(try x.b(3, false) ? Distributions.fCDF(v, d1, d2) : Distributions.fPDF(v, d1, d2))
            }
            return try r(1 - Distributions.fCDF(v, d1, d2))
        case "F.INV", "F.INV.RT", "FINV":
            let p = try x.n(0), d1 = try x.n(1).rounded(.towardZero), d2 = try x.n(2).rounded(.towardZero)
            try prob(p)
            guard d1 >= 1, d2 >= 1 else { throw XLError.num }
            let target = name == "F.INV" ? p : 1 - p
            if target == 0 { return .value(.number(0)) }
            guard target < 1, let v = Distributions.invert(target, lo: 0, hi: 10, { Distributions.fCDF($0, d1, d2) }) else { throw XLError.num }
            return try r(v)
        case "GAMMA.DIST", "GAMMADIST":
            try x.need(4)
            let v = try x.n(0), a = try x.n(1), b = try x.n(2), cum = try x.b(3, false)
            guard v >= 0, a > 0, b > 0 else { throw XLError.num }
            return try r(cum ? Distributions.gammaP(a, v / b) : Distributions.gammaPDF(v, a, b))
        case "GAMMA.INV", "GAMMAINV":
            let p = try x.n(0), a = try x.n(1), b = try x.n(2)
            try prob(p)
            guard a > 0, b > 0 else { throw XLError.num }
            if p == 0 { return .value(.number(0)) }
            guard p < 1, let v = Distributions.invert(p, lo: 0, hi: max(10, a * b * 4), { Distributions.gammaP(a, $0 / b) }) else { throw XLError.num }
            return try r(v)
        case "BETA.DIST", "BETADIST":
            try x.need(3)
            let v = try x.n(0), a = try x.n(1), b = try x.n(2)
            let cum = name == "BETADIST" ? true : try x.b(3, false)
            let lo = try x.n(name == "BETADIST" ? 3 : 4, 0), hi = try x.n(name == "BETADIST" ? 4 : 5, 1)
            guard a > 0, b > 0, lo < hi, v >= lo, v <= hi else { throw XLError.num }
            let z = (v - lo) / (hi - lo)
            return try r(cum ? Distributions.betaI(z, a, b) : Distributions.betaPDF(z, a, b) / (hi - lo))
        case "BETA.INV", "BETAINV":
            let p = try x.n(0), a = try x.n(1), b = try x.n(2)
            let lo = try x.n(3, 0), hi = try x.n(4, 1)
            try prob(p)
            guard a > 0, b > 0, lo < hi else { throw XLError.num }
            guard let z = Distributions.invert(p, lo: 0, hi: 1, { Distributions.betaI($0, a, b) }) else { throw XLError.num }
            return try r(lo + z * (hi - lo))
        case "WEIBULL.DIST", "WEIBULL":
            let v = try x.n(0), a = try x.n(1), b = try x.n(2), cum = try x.b(3, false)
            guard v >= 0, a > 0, b > 0 else { throw XLError.num }
            if cum { return try r(1 - exp(-pow(v / b, a))) }
            return try r(a / pow(b, a) * pow(v, a - 1) * exp(-pow(v / b, a)))
        case "EXPON.DIST", "EXPONDIST":
            try x.need(3)
            let v = try x.n(0), l = try x.n(1), cum = try x.b(2, false)
            guard v >= 0, l > 0 else { throw XLError.num }
            return try r(cum ? 1 - exp(-l * v) : l * exp(-l * v))
        case "BINOM.DIST", "BINOMDIST":
            try x.need(4)
            let k = try x.n(0).rounded(.towardZero), n = try x.n(1).rounded(.towardZero), p = try x.n(2), cum = try x.b(3, false)
            guard k >= 0, k <= n, n >= 0 else { throw XLError.num }
            try prob(p)
            if cum { return try r(min(1, (0...Int(k)).map { Distributions.binomPMF(Double($0), n, p) }.reduce(0, +))) }
            return try r(Distributions.binomPMF(k, n, p))
        case "BINOM.INV", "CRITBINOM":
            let n = try x.n(0).rounded(.towardZero), p = try x.n(1), alpha = try x.n(2)
            guard n >= 0 else { throw XLError.num }
            try prob(p); try prob(alpha)
            var total = 0.0
            for k in 0...Int(n) {
                total += Distributions.binomPMF(Double(k), n, p)
                if total >= alpha * (1 - 1e-14) { return .value(.number(Double(k))) }
            }
            return .value(.number(n))
        case "POISSON.DIST", "POISSON":
            try x.need(3)
            let k = try x.n(0).rounded(.towardZero), m = try x.n(1), cum = try x.b(2, false)
            guard k >= 0, m >= 0 else { throw XLError.num }
            if cum { return try r(min(1, (0...Int(k)).map { Distributions.poissonPMF(Double($0), m) }.reduce(0, +))) }
            return try r(Distributions.poissonPMF(k, m))
        case "FISHER":
            let v = try x.n(0)
            guard v > -1, v < 1 else { throw XLError.num }
            return try r(0.5 * log((1 + v) / (1 - v)))
        case "FISHERINV":
            let v = try x.n(0)
            return try r((exp(2 * v) - 1) / (exp(2 * v) + 1))
        case "GAMMA":
            let v = try x.n(0)
            guard !(v <= 0 && v == v.rounded()) else { throw XLError.num }
            return try r(tgamma(v))
        case "GAMMALN", "GAMMALN.PRECISE":
            let v = try x.n(0)
            guard v > 0 else { throw XLError.num }
            return try r(lgamma(v))
        case "ERF", "ERF.PRECISE":
            let lo = try x.n(0)
            if x.has(1), name == "ERF" { return try r(erf(try x.n(1)) - erf(lo)) }
            return try r(erf(lo))
        case "ERFC", "ERFC.PRECISE":
            return try r(erfc(try x.n(0)))
        default:
            return nil
        }
    }
}
