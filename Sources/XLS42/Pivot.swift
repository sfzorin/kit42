import AppKit
import Kit42

extension PivotSpec.Aggregate {
    var title: String { [L("Sum"), L("Count"), L("Average"), L("Min"), L("Max")][rawValue] }
}

/// Pivot table: groups the source rows by one (or two) fields and aggregates a value field.
enum Pivot {
    /// Header texts of the source's first row.
    static func headers(_ sheet: Sheet, _ source: CellRange) -> [String] {
        source.cols.map { c in
            let v = sheet[CellRef(row: source.start.row, col: c)].value
            return v.isEmpty ? L("Column %@", CellRef.columnName(c)) : v.plain
        }
    }

    /// The block of filled cells around `ref` (Excel's "current region").
    static func currentRegion(_ sheet: Sheet, around ref: CellRef) -> CellRange? {
        func filled(_ r: Int, _ c: Int) -> Bool { r >= 0 && c >= 0 && !(sheet.cells[CellRef(row: r, col: c)]?.value.isEmpty ?? true) }
        guard sheet.usedRange != nil else { return nil }
        var r = CellRange(ref, ref)
        var grew = true
        while grew {
            grew = false
            if r.start.row > 0, r.cols.contains(where: { filled(r.start.row - 1, $0) }) { r.start.row -= 1; grew = true }
            if r.cols.contains(where: { filled(r.end.row + 1, $0) }) { r.end.row += 1; grew = true }
            if r.start.col > 0, r.rows.contains(where: { filled($0, r.start.col - 1) }) { r.start.col -= 1; grew = true }
            if r.rows.contains(where: { filled($0, r.end.col + 1) }) { r.end.col += 1; grew = true }
            if r.count > 5_000_000 { break }
        }
        return r.count > 1 || filled(ref.row, ref.col) ? r : nil
    }

    private struct Key: Hashable { let text: String; let number: Double? }

    private static func key(_ v: Value, _ style: CellStyle) -> Key {
        if case .number(let d) = v { return Key(text: NumberFormat.format(v, style.numberFormat).text, number: d) }
        if case .bool(let b) = v { return Key(text: b ? L("TRUE") : L("FALSE"), number: nil) }
        return Key(text: v.isEmpty ? L("(blank)") : v.plain, number: nil)
    }

    private static func ordered(_ keys: Set<Key>) -> [Key] {
        keys.sorted { a, b in
            switch (a.number, b.number) {
            case let (x?, y?): return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.text.localizedStandardCompare(b.text) == .orderedAscending
            }
        }
    }

    private static func aggregate(_ values: [Value], _ kind: PivotSpec.Aggregate) -> Value {
        let numbers = values.compactMap { v -> Double? in if case .number(let d) = v { return d }; return nil }
        switch kind {
        case .count: return .number(Double(values.filter { !$0.isEmpty }.count))
        case .sum: return .number(numbers.reduce(0, +))
        case .average: return numbers.isEmpty ? .error("#DIV/0!") : .number(numbers.reduce(0, +) / Double(numbers.count))
        case .min: return numbers.min().map(Value.number) ?? .number(0)
        case .max: return numbers.max().map(Value.number) ?? .number(0)
        }
    }

    /// Builds the result sheet: header row, one row per row key, a column per column key, totals.
    static func build(_ spec: PivotSpec, workbook: Workbook, name: String) -> Sheet? {
        guard let si = workbook.sheetIndex(named: spec.sourceSheet), spec.source.rows.count >= 2 else { return nil }
        let src = workbook.sheets[si]
        let headers = headers(src, spec.source)
        guard spec.rowField < headers.count, spec.valueField < headers.count, (spec.colField ?? 0) < headers.count else { return nil }
        let c0 = spec.source.start.col
        var buckets: [Key: [Key?: [Value]]] = [:]
        var rowKeys = Set<Key>(), colKeys = Set<Key>()
        var byRow: [Key: [Value]] = [:], byCol: [Key: [Value]] = [:], all: [Value] = []
        for r in (spec.source.start.row + 1)...spec.source.end.row {
            let rc = src[CellRef(row: r, col: c0 + spec.rowField)]
            let value = src[CellRef(row: r, col: c0 + spec.valueField)].value
            if rc.value.isEmpty && value.isEmpty { continue }
            let rk = key(rc.value, rc.style)
            let ck = spec.colField.map { f -> Key in let c = src[CellRef(row: r, col: c0 + f)]; return key(c.value, c.style) }
            rowKeys.insert(rk)
            if let ck { colKeys.insert(ck); byCol[ck, default: []].append(value) }
            buckets[rk, default: [:]][ck, default: []].append(value)
            byRow[rk, default: []].append(value)
            all.append(value)
        }
        let rows = ordered(rowKeys), cols = ordered(colKeys)
        let valueStyle = src[CellRef(row: spec.source.start.row + 1, col: c0 + spec.valueField)].style
        let numberFormat = spec.aggregate == .count ? "General" : (valueStyle.numberFormat == "General" ? "General" : valueStyle.numberFormat)
        var sheet = Sheet(name: name)
        func put(_ r: Int, _ c: Int, _ v: Value, header: Bool = false, total: Bool = false) {
            var cell = Cell()
            cell.value = v
            cell.input = v.isError ? v.plain : XLSX.inputText(for: v, style: cell.style)
            if case .string(let s) = v, XLSX.constant(s) != v { cell.input = "'" + s }
            if v.isError { cell.input = "=" + (v == .error("#DIV/0!") ? "1/0" : "NA()") }
            if case .number = v { cell.style.numberFormat = numberFormat }
            if header {
                cell.style.bold = true
                cell.style.fill = NSColor(srgbRed: 0.85, green: 0.89, blue: 0.95, alpha: 1)
                cell.style.bottom = BorderSide(style: "thin", color: NSColor(white: 0.45, alpha: 1))
            }
            if total {
                cell.style.bold = true
                cell.style.top = BorderSide(style: "thin", color: NSColor(white: 0.45, alpha: 1))
            }
            sheet[CellRef(row: r, col: c)] = cell
        }
        let caption = "\(spec.aggregate.title) – \(headers[spec.valueField])"
        put(0, 0, .string(spec.colField == nil ? headers[spec.rowField] : caption), header: true)
        if let cf = spec.colField {
            // Row 0: caption + column field name; row 1: row field name + column keys.
            put(0, 1, .string(headers[cf]), header: true)
            for i in stride(from: 2, through: cols.count + 1, by: 1) { put(0, i, .empty, header: true) }
            put(1, 0, .string(headers[spec.rowField]), header: true)
            for (i, k) in cols.enumerated() { put(1, i + 1, k.number.map(Value.number) ?? .string(k.text), header: true) }
            put(1, cols.count + 1, .string(L("Grand Total")), header: true)
            for (j, rk) in rows.enumerated() {
                put(j + 2, 0, rk.number.map(Value.number) ?? .string(rk.text))
                for (i, ck) in cols.enumerated() {
                    if let vals = buckets[rk]?[ck] { put(j + 2, i + 1, aggregate(vals, spec.aggregate)) }
                }
                put(j + 2, cols.count + 1, aggregate(byRow[rk] ?? [], spec.aggregate), total: false)
                sheet.cells[CellRef(row: j + 2, col: cols.count + 1)]?.style.bold = true
            }
            let t = rows.count + 2
            put(t, 0, .string(L("Grand Total")), total: true)
            for (i, ck) in cols.enumerated() { put(t, i + 1, aggregate(byCol[ck] ?? [], spec.aggregate), total: true) }
            put(t, cols.count + 1, aggregate(all, spec.aggregate), total: true)
        } else {
            put(0, 1, .string(caption), header: true)
            for (j, rk) in rows.enumerated() {
                put(j + 1, 0, rk.number.map(Value.number) ?? .string(rk.text))
                put(j + 1, 1, aggregate(byRow[rk] ?? [], spec.aggregate))
            }
            put(rows.count + 1, 0, .string(L("Grand Total")), total: true)
            put(rows.count + 1, 1, aggregate(all, spec.aggregate), total: true)
        }
        // Keys keep the source's number format (dates stay dates).
        let rowStyle = src[CellRef(row: spec.source.start.row + 1, col: c0 + spec.rowField)].style.numberFormat
        for (ref, cell) in sheet.cells where ref.col == 0 && !cell.style.bold { sheet.cells[ref]?.style.numberFormat = rowStyle }
        sheet.columnWidths[0] = 120
        for c in 1...max(1, cols.count + 1) { sheet.columnWidths[c] = 90 }
        sheet.frozenRows = spec.colField == nil ? 1 : 2
        sheet.pivot = spec
        return sheet
    }
}

extension SheetWindowController {
    /// Data › Pivot Table…: choose the source and fields; the result goes to a new sheet.
    @objc func pivotTableAction(_ sender: Any?) {
        guard doc != nil else { return }
        grid.commitEdit(move: nil)
        let sel = clampedSelection
        let initial = sel.count > 1 ? sel : Pivot.currentRegion(sheet, around: grid.active) ?? sel
        let source = NSTextField(string: initial.a1)
        let rowField = NSPopUpButton(frame: .zero, pullsDown: false)
        let colField = NSPopUpButton(frame: .zero, pullsDown: false)
        let valueField = NSPopUpButton(frame: .zero, pullsDown: false)
        let aggregate = NSPopUpButton(frame: .zero, pullsDown: false)
        aggregate.addItems(withTitles: PivotSpec.Aggregate.allCases.map(\.title))
        let current = sheet
        let filler = PivotFieldFiller(source: source, popups: [rowField, colField, valueField]) { text in
            CellRange(text.replacingOccurrences(of: "$", with: "")).map { Pivot.headers(current, $0) } ?? []
        }
        source.delegate = filler
        filler.fill()
        let alert = NSAlert.form(L("Pivot Table"), info: L("The first row of the source holds the field names. The result is placed on a new sheet."),
                                 ok: L("Create"), rows: [(L("Source range:"), source), (L("Rows:"), rowField), (L("Columns:"), colField),
                                                        (L("Values:"), valueField), (L("Summarize by:"), aggregate)])
        guard alert.runModal() == .alertFirstButtonReturn,
              let range = CellRange(source.stringValue.replacingOccurrences(of: "$", with: "")), range.rows.count >= 2 else { return }
        let spec = PivotSpec(sourceSheet: sheet.name, source: range, rowField: max(0, rowField.indexOfSelectedItem),
                             colField: colField.indexOfSelectedItem > 0 ? colField.indexOfSelectedItem - 1 : nil,
                             valueField: max(0, valueField.indexOfSelectedItem), aggregate: PivotSpec.Aggregate(rawValue: aggregate.indexOfSelectedItem) ?? .sum)
        createPivot(spec)
    }

    /// Adds the pivot sheet after the current one and switches to it.
    func createPivot(_ spec: PivotSpec) {
        guard let doc else { return }
        var n = 1
        while doc.workbook.sheetIndex(named: L("Pivot%d", n)) != nil { n += 1 }
        guard let result = Pivot.build(spec, workbook: doc.workbook, name: L("Pivot%d", n)) else { NSSound.beep(); return }
        let at = sheetIndex + 1
        doc.change(L("Pivot Table")) { $0.sheets.insert(result, at: at) }
        selectSheet(at)
    }

    /// Data › Refresh Pivot Table: rebuilds the current pivot sheet from its saved settings.
    @objc func refreshPivotAction(_ sender: Any?) {
        guard let doc, let spec = sheet.pivot, let result = Pivot.build(spec, workbook: doc.workbook, name: sheet.name) else { NSSound.beep(); return }
        doc.change(L("Refresh Pivot Table")) { $0.sheets[sheetIndex] = result }
    }
}

/// Keeps the field popups of the pivot dialog in sync with the source range text.
private final class PivotFieldFiller: NSObject, NSTextFieldDelegate {
    let source: NSTextField
    let popups: [NSPopUpButton]
    let headers: (String) -> [String]

    init(source: NSTextField, popups: [NSPopUpButton], headers: @escaping (String) -> [String]) {
        self.source = source
        self.popups = popups
        self.headers = headers
        super.init()
        objc_setAssociatedObject(source, "filler", self, .OBJC_ASSOCIATION_RETAIN)
    }

    func fill() {
        let names = headers(source.stringValue)
        for (i, p) in popups.enumerated() {
            let old = p.indexOfSelectedItem
            p.removeAllItems()
            if i == 1 { p.addItem(withTitle: L("(none)")) }
            p.addItems(withTitles: names.enumerated().map { "\($0.element)" + String(repeating: "\u{200B}", count: $0.offset) })
            if old >= 0, old < p.numberOfItems { p.selectItem(at: old) }
        }
        // Defaults: rows = first field, values = last numeric-looking field.
        if popups[2].indexOfSelectedItem <= 0, names.count > 1 { popups[2].selectItem(at: names.count - 1) }
    }

    func controlTextDidChange(_ obj: Notification) { fill() }
}
