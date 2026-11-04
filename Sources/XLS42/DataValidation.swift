import AppKit
import Kit42

extension CellRange {
    func intersects(_ o: CellRange) -> Bool {
        start.row <= o.end.row && o.start.row <= end.row && start.col <= o.end.col && o.start.col <= end.col
    }

    /// This range minus `o`, as up to four rectangles.
    func subtracting(_ o: CellRange) -> [CellRange] {
        guard intersects(o) else { return [self] }
        var out: [CellRange] = []
        if start.row < o.start.row { out.append(CellRange(start, CellRef(row: o.start.row - 1, col: end.col))) }
        if end.row > o.end.row { out.append(CellRange(CellRef(row: o.end.row + 1, col: start.col), end)) }
        let r0 = max(start.row, o.start.row), r1 = min(end.row, o.end.row)
        if start.col < o.start.col { out.append(CellRange(CellRef(row: r0, col: start.col), CellRef(row: r1, col: o.start.col - 1))) }
        if end.col > o.end.col { out.append(CellRange(CellRef(row: r0, col: o.end.col + 1), CellRef(row: r1, col: end.col))) }
        return out
    }
}

extension DataValidation {
    static let operators = ["between", "notBetween", "equal", "notEqual", "greaterThan", "lessThan", "greaterThanOrEqual", "lessThanOrEqual"]
    static var operatorTitles: [String] {
        [L("between"), L("not between"), L("equal to"), L("not equal to"), L("greater than"), L("less than"),
         L("greater than or equal to"), L("less than or equal to")]
    }
    var usesSecondValue: Bool { op == "between" || op == "notBetween" }
    var anchor: CellRef { ranges.first?.start ?? CellRef(row: 0, col: 0) }

    /// Items of a list rule: a literal "a,b,c" or the values of a range.
    func listItems(_ workbook: Workbook, sheet: Int) -> [String] {
        let f = formula1.trimmingCharacters(in: .whitespaces)
        if f.hasPrefix("\""), f.hasSuffix("\""), f.count >= 2 {
            return f.dropFirst().dropLast().replacingOccurrences(of: "\"\"", with: "\"")
                .split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        }
        guard let e = try? Formula.parse("=" + f) else { return [] }
        let calc = Calculator(workbook)
        switch calc.eval(e, sheet: sheet, at: anchor) {
        case .matrix(let m, _): return m.values.filter { !$0.isEmpty }.map(Self.text)
        case .value(let v): return v.isEmpty ? [] : [Self.text(v)]
        }
    }

    private static func text(_ v: Value) -> String {
        if case .bool(let b) = v { return b ? "TRUE" : "FALSE" }
        return v.plain
    }

    /// Value of formula1/formula2 (constant or reference) as a number.
    private func bound(_ f: String, _ calc: Calculator, sheet: Int) -> Double? {
        let t = f.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        if let d = Double(t) { return d }
        if let d = DateMath.parse(t) { return d }
        guard let e = try? Formula.parse("=" + t) else { return nil }
        if case .number(let d) = calc.scalar(calc.eval(e, sheet: sheet, at: anchor), at: anchor) { return d }
        return nil
    }

    private func compare(_ x: Double, _ a: Double?, _ b: Double?) -> Bool {
        guard let a else { return true }
        switch op {
        case "between": return x >= a && x <= (b ?? a)
        case "notBetween": return x < a || x > (b ?? a)
        case "equal": return x == a
        case "notEqual": return x != a
        case "greaterThan": return x > a
        case "lessThan": return x < a
        case "greaterThanOrEqual": return x >= a
        case "lessThanOrEqual": return x <= a
        default: return true
        }
    }

    /// Whether `value` may be entered at `ref`.
    func accepts(_ value: Value, at ref: CellRef, workbook: Workbook, sheet: Int) -> Bool {
        if value.isEmpty { return true }
        let calc = Calculator(workbook)
        switch kind {
        case .list:
            let items = listItems(workbook, sheet: sheet)
            let t = Self.text(value)
            return items.contains { $0.compare(t, options: .caseInsensitive) == .orderedSame }
        case .whole, .decimal, .date, .time:
            guard case .number(let d) = value else { return false }
            if kind == .whole, d != d.rounded() { return false }
            let x = kind == .time ? d - floor(d) : d
            return compare(x, bound(formula1, calc, sheet: sheet), usesSecondValue ? bound(formula2, calc, sheet: sheet) : nil)
        case .textLength:
            return compare(Double(Self.text(value).count), bound(formula1, calc, sheet: sheet), usesSecondValue ? bound(formula2, calc, sheet: sheet) : nil)
        case .custom:
            var wb = workbook
            var cell = wb.sheets[sheet][ref]
            cell.value = value
            cell.input = value.plain
            wb.sheets[sheet][ref] = cell
            guard let e = try? Formula.parse("=" + formula1) else { return true }
            let c = Calculator(wb)
            let v = c.scalar(c.eval(e, sheet: sheet, at: ref), at: ref)
            return (try? c.bool(v)) ?? false
        }
    }

    /// Short human description, e.g. "Whole number between 1 and 10".
    var summary: String {
        let kinds: [Kind: String] = [.list: L("List"), .whole: L("Whole number"), .decimal: L("Decimal"), .date: L("Date"),
                                     .time: L("Time"), .textLength: L("Text length"), .custom: L("Custom formula")]
        if kind == .list || kind == .custom { return "\(kinds[kind]!): \(formula1)" }
        let i = Self.operators.firstIndex(of: op) ?? 0
        return "\(kinds[kind]!) \(Self.operatorTitles[i]) \(formula1)" + (usesSecondValue ? " – \(formula2)" : "")
    }
}

// MARK: - Commands

extension SheetWindowController {
    private static let validationKinds: [DataValidation.Kind?] = [nil, .list, .whole, .decimal, .date, .time, .textLength, .custom]

    /// Data › Validation…: rule for the selected cells.
    @objc func validationAction(_ sender: Any?) {
        guard doc != nil, guardEditable(nil) else { return }
        grid.commitEdit(move: nil)
        let range = grid.selection   // not clipped to the data: rules usually cover empty cells
        let existing = sheet.validation(at: grid.active)
        let allow = NSPopUpButton(frame: .zero, pullsDown: false)
        allow.addItems(withTitles: [L("Any value"), L("List"), L("Whole number"), L("Decimal"), L("Date"), L("Time"), L("Text length"), L("Custom formula")])
        let op = NSPopUpButton(frame: .zero, pullsDown: false)
        op.addItems(withTitles: DataValidation.operatorTitles)
        let first = NSTextField(string: ""), second = NSTextField(string: "")
        first.placeholderString = L("e.g. Yes,No or =$H$1:$H$5")
        let style = NSPopUpButton(frame: .zero, pullsDown: false)
        style.addItems(withTitles: [L("Stop"), L("Warning"), L("Information")])
        let title = NSTextField(string: ""), message = NSTextField(string: "")
        message.placeholderString = L("Shown when the value is not allowed")
        let blank = NSButton(checkboxWithTitle: L("Ignore blank"), target: nil, action: nil)
        let dropdown = NSButton(checkboxWithTitle: L("In-cell dropdown"), target: nil, action: nil)
        blank.state = .on
        dropdown.state = .on
        if let v = existing {
            allow.selectItem(at: Self.validationKinds.firstIndex(of: v.kind) ?? 0)
            op.selectItem(at: DataValidation.operators.firstIndex(of: v.op) ?? 0)
            first.stringValue = Self.displayBound(v.formula1, v.kind, list: true)
            second.stringValue = Self.displayBound(v.formula2, v.kind, list: false)
            style.selectItem(at: ["stop", "warning", "information"].firstIndex(of: v.errorStyle) ?? 0)
            title.stringValue = v.errorTitle
            message.stringValue = v.errorMessage
            blank.state = v.allowBlank ? .on : .off
            dropdown.state = v.showDropdown ? .on : .off
        }
        let alert = NSAlert.form(L("Data Validation"), info: L("Cells: %@", range.a1), ok: L("OK"),
                                 rows: [(L("Allow:"), allow), (L("Data:"), op), (L("Source / minimum:"), first), (L("Maximum:"), second),
                                        (L("Error style:"), style), (L("Error title:"), title), (L("Error message:"), message),
                                        ("", blank), ("", dropdown)])
        let toggler = ValidationFormToggler(alert: alert, allow: allow, op: op)
        allow.target = toggler; allow.action = #selector(ValidationFormToggler.update)
        op.target = toggler; op.action = #selector(ValidationFormToggler.update)
        toggler.update()
        alert.window.initialFirstResponder = first
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let kind = Self.validationKinds[max(0, allow.indexOfSelectedItem)]
        var rule: DataValidation?
        if let kind {
            var v = DataValidation(ranges: [range], kind: kind)
            v.op = DataValidation.operators[max(0, op.indexOfSelectedItem)]
            v.formula1 = Self.storedBound(first.stringValue, kind, list: true)
            v.formula2 = v.usesSecondValue && kind != .list && kind != .custom ? Self.storedBound(second.stringValue, kind, list: false) : ""
            v.errorStyle = ["stop", "warning", "information"][max(0, style.indexOfSelectedItem)]
            v.errorTitle = title.stringValue
            v.errorMessage = message.stringValue
            v.allowBlank = blank.state == .on
            v.showDropdown = dropdown.state == .on
            guard !v.formula1.isEmpty else { NSSound.beep(); return }
            rule = v
        }
        setValidation(rule, for: range)
    }

    @objc func clearValidationAction(_ sender: Any?) {
        guard guardEditable(nil) else { return }
        setValidation(nil, for: grid.selection)
    }

    /// Replaces the rules covering `range` with `rule` (nil removes them). One undo step.
    func setValidation(_ rule: DataValidation?, for range: CellRange) {
        doc?.change(L("Data Validation"), recalc: false) { wb in
            var list: [DataValidation] = []
            for var v in wb.sheets[sheetIndex].validations {
                v.ranges = v.ranges.flatMap { $0.subtracting(range) }
                if !v.ranges.isEmpty { list.append(v) }
            }
            if let rule { list.append(rule) }
            wb.sheets[sheetIndex].validations = list
        }
        grid.needsDisplay = true
    }

    /// Dialog text → stored formula: list items quoted, dates as serial numbers, "=A1" → "A1".
    static func storedBound(_ text: String, _ kind: DataValidation.Kind, list: Bool) -> String {
        let t = text.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("=") { return String(t.dropFirst()) }
        if kind == .list && list { return t.isEmpty ? "" : "\"" + t.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        if (kind == .date || kind == .time), Double(t) == nil, let d = DateMath.parse(t) { return Value.formatGeneral(d) }
        if let d = Double(t.replacingOccurrences(of: ",", with: ".")) { return Value.formatGeneral(d) }
        return t
    }

    static func displayBound(_ f: String, _ kind: DataValidation.Kind, list: Bool) -> String {
        if kind == .list && list, f.hasPrefix("\""), f.hasSuffix("\""), f.count >= 2 { return String(f.dropFirst().dropLast()).replacingOccurrences(of: "\"\"", with: "\"") }
        if f.isEmpty { return "" }
        if kind == .date, let d = Double(f) { return NumberFormat.format(.number(d), "dd.mm.yyyy").text }
        if kind == .time, let d = Double(f) { return NumberFormat.format(.number(d), "hh:mm").text }
        if Double(f) != nil { return f }
        return "=" + f
    }

    /// Checks typed input against the cell's rule; shows the rule's error. Returns false to reject.
    func validateInput(_ input: String, at ref: CellRef) -> Bool {
        guard let doc, let rule = sheet.validation(at: ref), !input.hasPrefix("=") || input.count == 1 else { return true }
        let value = XLSX.constant(input)
        if value.isEmpty && rule.allowBlank { return true }
        guard !rule.accepts(value, at: ref, workbook: doc.workbook, sheet: sheetIndex) else { return true }
        let text = rule.errorMessage.isEmpty ? L("The value doesn’t match the data validation rules for this cell.") + "\n" + rule.summary : rule.errorMessage
        lastAlertMessage = text
        if suppressAlerts { return rule.errorStyle != "stop" }
        let alert = NSAlert()
        alert.messageText = rule.errorTitle.isEmpty ? L("Invalid value") : rule.errorTitle
        alert.informativeText = text
        switch rule.errorStyle {
        case "warning":
            alert.alertStyle = .warning
            alert.messageText += " — " + L("Continue?")
            alert.addButton(withTitle: L("Yes"))
            alert.addButton(withTitle: L("No"))
            return alert.runModal() == .alertFirstButtonReturn
        case "information":
            alert.alertStyle = .informational
            alert.addButton(withTitle: L("OK"))
            alert.addButton(withTitle: L("Cancel"))
            return alert.runModal() == .alertFirstButtonReturn
        default:
            alert.alertStyle = .critical
            alert.addButton(withTitle: L("Retry"))
            alert.addButton(withTitle: L("Cancel"))
            if alert.runModal() == .alertFirstButtonReturn {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.grid.select(ref)
                    self.grid.beginEdit(initial: input)
                }
            }
            return false
        }
    }

    /// Drop-down of a list rule (arrow beside the active cell, or ⌥↓).
    func showValidationList(at ref: CellRef) {
        guard let doc, let rule = sheet.validation(at: ref), rule.kind == .list else { return }
        let menu = NSMenu()
        let current = sheet[ref].value.plain
        for item in rule.listItems(doc.workbook, sheet: sheetIndex) where !item.isEmpty {
            let mi = NSMenuItem(title: item, action: #selector(pickListValue(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = item
            mi.state = item == current ? .on : .off
            menu.addItem(mi)
        }
        guard !menu.items.isEmpty else { NSSound.beep(); return }
        let r = grid.rect(ref)
        menu.popUp(positioning: nil, at: NSPoint(x: r.minX, y: r.maxY + 2), in: grid)
    }

    @objc private func pickListValue(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String else { return }
        setInput(value, at: grid.active)
    }
}

/// Shows only the fields that matter for the chosen kind of validation rule.
private final class ValidationFormToggler: NSObject {
    let alert: NSAlert, allow: NSPopUpButton, op: NSPopUpButton

    init(alert: NSAlert, allow: NSPopUpButton, op: NSPopUpButton) {
        self.alert = alert
        self.allow = allow
        self.op = op
        super.init()
        objc_setAssociatedObject(alert, "toggler", self, .OBJC_ASSOCIATION_RETAIN)
    }

    @objc func update() {
        guard let grid = alert.accessoryView as? NSGridView else { return }
        let kind = allow.indexOfSelectedItem   // 0 any, 1 list, 2 whole, 3 decimal, 4 date, 5 time, 6 text length, 7 custom
        let ranged = kind >= 2 && kind <= 6
        let between = op.indexOfSelectedItem <= 1
        grid.row(at: 1).isHidden = !ranged
        grid.row(at: 2).isHidden = kind == 0
        grid.row(at: 3).isHidden = !(ranged && between)
        for i in 4...7 { grid.row(at: i).isHidden = kind == 0 }
        grid.row(at: 8).isHidden = kind != 1
        if let label = grid.cell(atColumnIndex: 0, rowIndex: 2).contentView as? NSTextField {
            label.stringValue = kind == 1 ? L("Source:") : kind == 7 ? L("Formula:") : between && ranged ? L("Minimum:") : L("Value:")
        }
        grid.frame.size = grid.fittingSize
        alert.layout()
    }
}
