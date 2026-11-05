import AppKit
import Kit42

/// Evaluates conditional formatting rules for drawing. Built once per draw pass.
final class ConditionalEngine {
    private let sheet: Sheet
    private let calc: Calculator
    private let sheetIndex: Int
    private var stats: [Int: (min: Double, max: Double)] = [:]
    private var duplicates: [Int: Set<String>] = [:]

    init(sheet: Sheet, workbook: Workbook, sheetIndex: Int) {
        self.sheet = sheet
        self.sheetIndex = sheetIndex
        calc = Calculator(workbook)
    }

    private func numbers(_ rule: Int) -> (min: Double, max: Double) {
        if let s = stats[rule] { return s }
        let range = sheet.conditionalFormats[rule].range
        let values = sheet.cells.compactMap { ref, cell -> Double? in
            guard range.contains(ref), case .number(let d) = cell.value else { return nil }
            return d
        }
        let s = (values.min() ?? 0, values.max() ?? 0)
        stats[rule] = s
        return s
    }

    private func duplicateSet(_ rule: Int) -> Set<String> {
        if let d = duplicates[rule] { return d }
        var counts: [String: Int] = [:]
        for (ref, cell) in sheet.cells where sheet.conditionalFormats[rule].range.contains(ref) && !cell.value.isEmpty {
            counts[cell.value.plain.lowercased(), default: 0] += 1
        }
        let d = Set(counts.filter { $0.value > 1 }.keys)
        duplicates[rule] = d
        return d
    }

    /// Value of a rule operand ("100", "$B$1", "=A1*2") evaluated at the cell.
    private func operand(_ text: String, rule: ConditionalFormat, at ref: CellRef) -> Value {
        let formula = text.hasPrefix("=") ? text : "=" + text
        let shifted = Formula.shifted(formula, rows: ref.row - rule.range.start.row, cols: ref.col - rule.range.start.col)
        guard let e = Calculator.expression(shifted) else { return .error("#NAME?") }
        return calc.scalar(calc.eval(e, sheet: sheetIndex, at: ref), at: ref)
    }

    /// Applies matching rules' fill/text colour/bold to a copy of the cell.
    func apply(_ cell: inout Cell, at ref: CellRef) {
        for (i, rule) in sheet.conditionalFormats.enumerated() where rule.range.contains(ref) {
            switch rule.kind {
            case .colorScale(let colors):
                guard case .number(let v) = cell.value, colors.count >= 2 else { continue }
                let s = numbers(i)
                let t = s.max > s.min ? CGFloat((v - s.min) / (s.max - s.min)) : 0.5
                cell.style.fill = Self.interpolate(colors, t)
            case .dataBar:
                continue
            default:
                if matches(rule, index: i, cell: cell, at: ref) {
                    if let f = rule.fill { cell.style.fill = f }
                    if let c = rule.textColor { cell.style.textColor = c }
                    if rule.bold { cell.style.bold = true }
                }
            }
        }
    }

    private func matches(_ rule: ConditionalFormat, index: Int, cell: Cell, at ref: CellRef) -> Bool {
        switch rule.kind {
        case .cellIs(let op, let values):
            guard !cell.value.isEmpty, let first = values.first else { return false }
            let a = operand(first, rule: rule, at: ref)
            let c = calc.compare(cell.value, a)
            switch op {
            case "greaterThan": return c > 0
            case "lessThan": return c < 0
            case "greaterThanOrEqual": return c >= 0
            case "lessThanOrEqual": return c <= 0
            case "equal": return c == 0
            case "notEqual": return c != 0
            case "between", "notBetween":
                guard values.count > 1 else { return false }
                let b = operand(values[1], rule: rule, at: ref)
                let inside = c >= 0 && calc.compare(cell.value, b) <= 0
                return op == "between" ? inside : !inside
            default: return false
            }
        case .containsText(let text):
            return !text.isEmpty && cell.value.plain.localizedCaseInsensitiveContains(text)
        case .expression(let f):
            if case .bool(true) = operand(f, rule: rule, at: ref) { return true }
            if case .number(let d) = operand(f, rule: rule, at: ref) { return d != 0 }
            return false
        case .duplicates:
            return !cell.value.isEmpty && duplicateSet(index).contains(cell.value.plain.lowercased())
        default:
            return false
        }
    }

    /// Data bar for the cell: fraction of the cell width and colour.
    func bar(at ref: CellRef) -> (CGFloat, NSColor)? {
        for (i, rule) in sheet.conditionalFormats.enumerated() where rule.range.contains(ref) {
            guard case .dataBar(let color) = rule.kind, case .number(let v) = sheet[ref].value else { continue }
            let s = numbers(i)
            let lo = min(0, s.min), hi = s.max
            return (hi > lo ? CGFloat((v - lo) / (hi - lo)) : 1, color)
        }
        return nil
    }

    static func interpolate(_ colors: [NSColor], _ t: CGFloat) -> NSColor {
        let c = colors.compactMap { $0.usingColorSpace(.sRGB) }
        guard c.count >= 2 else { return colors.first ?? .white }
        let t = max(0, min(1, t))
        let (a, b, u): (NSColor, NSColor, CGFloat) = c.count == 2 ? (c[0], c[1], t) : (t < 0.5 ? (c[0], c[1], t * 2) : (c[1], c[2], (t - 0.5) * 2))
        return NSColor(srgbRed: a.redComponent + (b.redComponent - a.redComponent) * u,
                       green: a.greenComponent + (b.greenComponent - a.greenComponent) * u,
                       blue: a.blueComponent + (b.blueComponent - a.blueComponent) * u, alpha: 1)
    }
}
