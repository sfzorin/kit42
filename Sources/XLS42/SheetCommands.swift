import AppKit
import Kit42

/// Sheet menu (rename, move/copy, tab colour, hide/show), hyperlinks, cell styles, View › Split and the status bar.
extension SheetWindowController {
    // MARK: - Sheets

    var visibleSheets: [Int] { (doc?.workbook.sheets ?? []).indices.filter { !(doc?.workbook.sheets[$0].hidden ?? false) } }

    @objc func renameSheetAction(_ sender: Any?) { renameSheet(at: sheetIndex) }
    @objc func deleteSheetAction(_ sender: Any?) { deleteSheet(at: sheetIndex) }

    @objc func moveCopySheetAction(_ sender: Any?) {
        guard let doc else { return }
        let i = commandTag(of: sender) > 0 ? commandTag(of: sender) - 1 : sheetIndex
        let names = doc.workbook.sheets.map(\.name)
        let before = popup(names + [L("- move to end position -")], selected: min(i + 1, names.count))
        let copy = checkbox(L("Copy"), false)
        let name = field(names[i], width: 200)
        let rows: [[NSView]] = [[label(L("Insert before:")), before], [NSGridCell.emptyContentView, copy], [label(L("New name:")), name]]
        guard runDialog(L("Move/Copy Sheet"), info: L("Sheet “%@”", names[i]), ok: L("OK"), rows: rows) == .alertFirstButtonReturn else { return }
        moveSheet(i, before: before.indexOfSelectedItem, copy: copy.state == .on, name: name.stringValue)
    }

    /// Moves (or copies) sheet `i` in front of sheet `before` (count = at the end). Copies get a unique name.
    func moveSheet(_ i: Int, before: Int, copy: Bool, name: String? = nil) {
        guard let doc, doc.workbook.sheets.indices.contains(i), guardStructure(), grid.commitEdit(move: nil) else { return }
        let before = max(0, min(before, doc.workbook.sheets.count))
        var s = doc.workbook.sheets[i]
        var newName = (name?.trimmingCharacters(in: .whitespaces)).flatMap { $0.isEmpty ? nil : $0 } ?? s.name
        guard Self.validSheetName(newName) else { NSSound.beep(); return }
        if copy {
            newName = Self.uniqueSheetName(newName, in: doc.workbook)
            Self.renameReferences(&s, from: s.name, to: newName)
            s.name = newName
            s.pivot = nil
            doc.change(L("Copy Sheet")) { $0.sheets.insert(s, at: min(before, $0.sheets.count)) }
            sheetIndex = min(before, doc.workbook.sheets.count - 1)
        } else {
            let old = s.name
            guard doc.workbook.sheetIndex(named: newName).map({ $0 == i }) ?? true else { NSSound.beep(); return }
            s.name = newName
            doc.change(L("Move Sheet")) { wb in
                wb.sheets.remove(at: i)
                let to = before > i ? before - 1 : before
                wb.sheets.insert(s, at: min(to, wb.sheets.count))
                if newName != old { Self.renameReferences(&wb, from: old, to: newName) }
            }
            sheetIndex = doc.workbook.sheetIndex(named: newName) ?? 0
        }
        workbookDidChange()
    }

    static func validSheetName(_ name: String) -> Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && name.utf16.count <= 31
            && !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
            && !name.contains(where: { "[]:*?/\\".contains($0) }) && !name.hasPrefix("'") && !name.hasSuffix("'")
    }

    /// Names are limited in UTF-16 units; test the actual truncated candidate for collisions.
    static func uniqueSheetName(_ proposed: String, in workbook: Workbook) -> String {
        if workbook.sheetIndex(named: proposed) == nil { return proposed }
        var number = 2
        while true {
            let suffix = " (\(number))"
            let budget = max(0, 31 - suffix.utf16.count)
            var prefix = "", length = 0
            for character in proposed {
                let size = String(character).utf16.count
                guard length + size <= budget else { break }
                prefix.append(character); length += size
            }
            let candidate = prefix + suffix
            if workbook.sheetIndex(named: candidate) == nil { return candidate }
            number += 1
        }
    }

    static func renameReferences(_ wb: inout Workbook, from old: String, to name: String) {
        for key in wb.names.keys { wb.names[key] = renamedReference(wb.names[key]!, from: old, to: name) }
        for si in wb.sheets.indices { renameReferences(&wb.sheets[si], from: old, to: name) }
    }

    private static func renamedReference(_ text: String, from old: String, to name: String) -> String {
        guard let expression = try? Formula.parse(text.hasPrefix("=") ? text : "=" + text) else { return text }
        let renamed = Formula.serialize(renameSheetRefs(expression, from: old, to: name))
        guard renamed != Formula.serialize(expression) else { return text }
        return (text.hasPrefix("=") ? "=" : "") + renamed
    }

    static func renameReferences(_ sheet: inout Sheet, from old: String, to name: String) {
        if sheet.pivot?.sourceSheet.caseInsensitiveCompare(old) == .orderedSame { sheet.pivot?.sourceSheet = name }
        for (ref, cell) in sheet.cells where cell.isFormula {
            sheet.cells[ref]?.input = renamedReference(cell.input, from: old, to: name)
        }
        for i in sheet.validations.indices {
            sheet.validations[i].formula1 = renamedReference(sheet.validations[i].formula1, from: old, to: name)
            sheet.validations[i].formula2 = renamedReference(sheet.validations[i].formula2, from: old, to: name)
        }
        for i in sheet.conditionalFormats.indices {
            switch sheet.conditionalFormats[i].kind {
            case .expression(let f): sheet.conditionalFormats[i].kind = .expression(renamedReference(f, from: old, to: name))
            case .cellIs(let op, let values): sheet.conditionalFormats[i].kind = .cellIs(op: op, values: values.map { renamedReference($0, from: old, to: name) })
            default: break
            }
        }
        for i in sheet.charts.indices {
            for j in sheet.charts[i].series.indices {
                if sheet.charts[i].series[j].name.hasPrefix("=") {
                    sheet.charts[i].series[j].name = renamedReference(sheet.charts[i].series[j].name, from: old, to: name)
                }
                sheet.charts[i].series[j].values = renamedReference(sheet.charts[i].series[j].values, from: old, to: name)
                sheet.charts[i].series[j].categories = sheet.charts[i].series[j].categories.map { renamedReference($0, from: old, to: name) }
            }
        }
        for (ref, target) in sheet.hyperlinks where target.hasPrefix("#") {
            sheet.hyperlinks[ref] = "#" + renamedReference(String(target.dropFirst()), from: old, to: name)
        }
    }

    @objc func tabColorAction(_ sender: Any?) {
        let i = commandTag(of: sender) > 0 ? commandTag(of: sender) - 1 : sheetIndex
        let well = NSColorWell(frame: NSRect(x: 0, y: 0, width: 60, height: 26))
        well.color = sheet.tabColor ?? .systemBlue
        let none = checkbox(L("No colour"), doc?.workbook.sheets[i].tabColor == nil)
        let presets = [NSColor.systemRed, .systemOrange, .systemYellow, .systemGreen, .systemTeal, .systemBlue, .systemPurple, .systemGray]
        let swatches = NSStackView(views: presets.map { c in
            let b = ColorSwatchButton(color: c) { [weak well, weak none] in well?.color = c; none?.state = .off }
            return b
        })
        swatches.spacing = 4
        let rows: [[NSView]] = [[label(L("Colour:")), swatches], [NSGridCell.emptyContentView, well], [NSGridCell.emptyContentView, none]]
        guard runDialog(L("Tab Colour"), ok: L("OK"), rows: rows) == .alertFirstButtonReturn else { return }
        setTabColor(none.state == .on ? nil : well.color.usingColorSpace(.sRGB), sheet: i)
    }

    func setTabColor(_ color: NSColor?, sheet i: Int) {
        guard let doc, doc.workbook.sheets.indices.contains(i), grid.commitEdit(move: nil) else { return }
        doc.change(L("Tab Colour"), recalc: false) { $0.sheets[i].tabColor = color }
    }

    @objc func hideSheetAction(_ sender: Any?) {
        let i = commandTag(of: sender) > 0 ? commandTag(of: sender) - 1 : sheetIndex
        hideSheet(i)
    }

    func hideSheet(_ i: Int) {
        guard let doc, guardStructure(), visibleSheets.count > 1, doc.workbook.sheets.indices.contains(i), grid.commitEdit(move: nil) else { NSSound.beep(); return }
        doc.change(L("Hide Sheet"), recalc: false) { $0.sheets[i].hidden = true }
        if i == sheetIndex, let next = visibleSheets.first(where: { $0 > i }) ?? visibleSheets.last { selectSheet(next) } else { workbookDidChange() }
    }

    @objc func showSheetAction(_ sender: Any?) {
        guard let doc else { return }
        let hidden = doc.workbook.sheets.indices.filter { doc.workbook.sheets[$0].hidden }
        guard !hidden.isEmpty else { NSSound.beep(); return }
        let list = popup(hidden.map { doc.workbook.sheets[$0].name })
        guard runDialog(L("Show Sheet"), ok: L("Show"), rows: [[label(L("Hidden sheets:")), list]]) == .alertFirstButtonReturn else { return }
        showSheet(hidden[list.indexOfSelectedItem])
    }

    func showSheet(_ i: Int) {
        guard let doc, doc.workbook.sheets.indices.contains(i), guardStructure(), grid.commitEdit(move: nil) else { return }
        doc.change(L("Show Sheet"), recalc: false) { $0.sheets[i].hidden = false }
        selectSheet(i)
    }

    /// Workbook structure protection (Tools › Protect Workbook): no adding, deleting, moving, hiding sheets.
    func guardStructure() -> Bool {
        guard doc?.workbook.structureProtected == true else { return true }
        lastAlertMessage = L("The workbook structure is protected")
        if !suppressAlerts { report(L("The workbook structure is protected")) }
        return false
    }

    @objc func protectWorkbookAction(_ sender: Any?) {
        doc?.change(L("Protect Workbook"), recalc: false) { $0.structureProtected.toggle() }
    }

    // MARK: - Hyperlinks

    @objc func insertHyperlinkAction(_ sender: Any?) {
        guard grid.commitEdit(move: nil) else { return }
        let ref = grid.active
        let existing = sheet.hyperlinks[ref] ?? ""
        let text = field(sheet[ref].value.isEmpty ? "" : NumberFormat.format(sheet[ref].value, "General").text, width: 260)
        let address = field(existing, width: 260, placeholder: L("https://…, mailto:…, a file, or #Sheet2!A1"))
        switch runDialog(L("Hyperlink"), ok: L("OK"), extra: existing.isEmpty ? nil : L("Remove Link"),
                         rows: [[label(L("Text:")), text], [label(L("Address:")), address]]) {
        case .alertFirstButtonReturn: setHyperlink(address.stringValue.isEmpty ? nil : address.stringValue, text: text.stringValue, at: ref)
        case .alertThirdButtonReturn: setHyperlink(nil, text: nil, at: ref)
        default: break
        }
    }

    @objc func removeHyperlinkAction(_ sender: Any?) { setHyperlink(nil, text: nil, at: grid.active) }

    /// Adds (or removes, target nil) a hyperlink; the cell gets the text (or the address) and the Hyperlink style.
    func setHyperlink(_ target: String?, text: String?, at ref: CellRef) {
        guard grid.commitEdit(move: nil), let doc, guardEditable(CellRange(ref, ref)) else { return }
        var link = target?.trimmingCharacters(in: .whitespaces)
        if let l = link, !l.hasPrefix("#"), !l.contains(":"), !l.hasPrefix("/"), l.contains(".") { link = "https://" + l }
        doc.change(link == nil ? L("Remove Hyperlink") : L("Hyperlink")) { wb in
            wb.sheets[sheetIndex].hyperlinks[ref] = link
            var cell = wb.sheets[sheetIndex][ref]
            if let link {
                let t = (text ?? "").isEmpty ? (cell.value.isEmpty ? link : nil) : text
                if let t, !cell.isFormula { cell.input = t; cell.value = .string(t) }
                if cell.style.styleName == nil, cell.style.textColor == nil { cell.style = CellStyles.applied(CellStyles.presets.first { $0.name == "Hyperlink" }!, to: cell.style) }
            } else if cell.style.styleName == "Hyperlink" {
                cell.style.textColor = nil; cell.style.underline = false; cell.style.styleName = nil
            }
            wb.sheets[sheetIndex][ref] = cell
        }
    }

    /// Target of a hyperlink cell: Insert › Hyperlink, or a HYPERLINK() formula.
    func hyperlinkTarget(at ref: CellRef) -> String? {
        if let t = sheet.hyperlinks[ref] { return t }
        let cell = sheet[ref]
        guard cell.isFormula, cell.input.uppercased().contains("HYPERLINK("), let doc, let e = Calculator.expression(cell.input) else { return nil }
        func find(_ e: Expr) -> Expr? {
            switch e {
            case .call("HYPERLINK", let args) where !args.isEmpty: return args[0]
            case .call(_, let args): return args.lazy.compactMap(find).first
            case .binary(_, let l, let r): return find(l) ?? find(r)
            case .unary(_, let x), .percent(let x): return find(x)
            default: return nil
            }
        }
        guard let arg = find(e) else { return nil }
        let calc = Calculator(doc.workbook)
        let v = calc.scalar(calc.eval(arg, sheet: sheetIndex, at: ref), at: ref)
        let s = calc.text(v)
        return s.isEmpty ? nil : s
    }

    /// Opens a link: places in the workbook select the cell, others go to the browser, mail or Finder.
    func openHyperlink(_ target: String) {
        lastOpenedLink = target
        if target.hasPrefix("#") {
            guard grid.commitEdit(move: nil) else { return }
            var place = String(target.dropFirst())
            var si = sheetIndex
            if let bang = place.lastIndex(of: "!") {
                var name = String(place[..<bang])
                if name.hasPrefix("'"), name.hasSuffix("'"), name.count > 1 { name = String(name.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'") }
                if let i = doc?.workbook.sheetIndex(named: name) { si = i }
                place = String(place[place.index(after: bang)...])
            } else if let i = doc?.workbook.names.first(where: { $0.key.caseInsensitiveCompare(place) == .orderedSame })?.value, let r = parseRange(i) {
                si = r.sheet
                place = r.range.a1
            }
            if si != sheetIndex { selectSheet(si) }
            if let r = CellRange(place.replacingOccurrences(of: "$", with: "")) {
                grid.select(r.start)
                if r.count > 1 { grid.select(r.end, extend: true) }
            }
            return
        }
        guard !suppressAlerts else { return }
        var url = URL(string: target)
        if url?.scheme == nil {
            let path = (target as NSString).expandingTildeInPath
            url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : doc?.fileURL?.deletingLastPathComponent().appendingPathComponent(path)
        }
        if let url { NSWorkspace.shared.open(url) }
    }

    @objc func openHyperlinkAction(_ sender: Any?) {
        if let t = hyperlinkTarget(at: grid.active) { openHyperlink(t) } else { NSSound.beep() }
    }

    // MARK: - Cell styles

    static var cellStyleCommands: [Command] {
        CellStyles.presets.enumerated().map { Command($0.element.title, #selector(applyCellStyleAction(_:)), tag: $0.offset) }
    }

    @objc func applyCellStyleAction(_ sender: Any?) {
        if let name = (sender as? NSMenuItem)?.representedObject as? String { applyCellStyle(named: name); return }
        let i = commandTag(of: sender)
        guard i >= 0, i < CellStyles.presets.count else { return }
        applyCellStyle(CellStyles.presets[i])
    }

    /// Named styles of the document that aren't presets (from LibreOffice or Excel files), for the Cell Styles menu.
    var documentStyleNames: [String] {
        guard let wb = doc?.workbook else { return [] }
        var names = Set(wb.cellStyles.keys)
        for s in wb.sheets { for c in s.cells.values { if let n = c.style.styleName { names.insert(n) } } }
        return names.filter { CellStyles.preset(named: $0) == nil && $0 != "Normal" }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Applies a preset, or a document style by name (its saved formatting).
    func applyCellStyle(named name: String) {
        guard grid.commitEdit(move: nil) else { return }
        if let p = CellStyles.preset(named: name) { applyCellStyle(p); return }
        let range = clampedSelection
        guard let doc, guardCellOperation(range), guardEditable(range) else { return }
        let def = CellStyles.definition(name, in: doc.workbook)
            ?? doc.workbook.sheets.lazy.flatMap { $0.cells.values }.first { $0.style.styleName == name }?.style
        guard let def else { NSSound.beep(); return }
        doc.change(L("Cell Style"), recalc: false) { wb in
            for ref in range.cells {
                var cell = wb.sheets[sheetIndex][ref]
                cell.style = CellStyles.applied(document: def, name: name, to: cell.style)
                wb.sheets[sheetIndex][ref] = cell
            }
        }
    }

    func applyCellStyle(_ preset: CellStyles.Preset) {
        guard grid.commitEdit(move: nil) else { return }
        let range = clampedSelection
        guard let doc, guardCellOperation(range), guardEditable(range) else { return }
        doc.change(L("Cell Style"), recalc: false) { wb in
            for ref in range.cells {
                var cell = wb.sheets[sheetIndex][ref]
                cell.style = CellStyles.applied(preset, to: cell.style)
                wb.sheets[sheetIndex][ref] = cell
            }
        }
    }

    // MARK: - Split window

    @objc func toggleSplitAction(_ sender: Any?) {
        if grid.split != nil { setSplit(nil); return }
        if sheet.frozenRows > 0 || sheet.frozenCols > 0 {
            doc?.change(L("Unfreeze Panes"), recalc: false) { wb in wb.sheets[sheetIndex].frozenRows = 0; wb.sheets[sheetIndex].frozenCols = 0 }
        }
        // At the active cell; at the window's middle when the active cell is the top-left one.
        let size = grid.viewportSize
        var p = grid.toViewport(grid.rect(grid.active).origin)
        if p.x <= 1 && p.y <= 1 { p = NSPoint(x: (size.width / 2).rounded(), y: (size.height / 2).rounded()) }
        if p.x >= size.width - 20 { p.x = 0 }
        if p.y >= size.height - 20 { p.y = 0 }
        setSplit(NSPoint(x: max(0, p.x), y: max(0, p.y)))
    }

    func setSplit(_ position: NSPoint?) {
        grid.splitScroll = grid.scrollOrigin
        grid.split = position.flatMap { $0.x > 0 || $0.y > 0 ? $0 : nil }
        freezeOverlay.panesNeedDisplay()
        headersNeedDisplay()
        grid.needsDisplay = true
        // The split is part of the document (saved in the view settings of .xlsx/.ods), not an undo step.
        if let doc, sheetIndex < doc.workbook.sheets.count {
            let before = doc.workbook.sheets[sheetIndex].split
            storeSplit()
            if doc.workbook.sheets[sheetIndex].split != before { doc.updateChangeCount(.changeDone) }
        }
    }

    /// The window's split (position and pane scroll positions) → the sheet model, for saving and sheet switches.
    func storeSplit() {
        guard let doc, sheetIndex < doc.workbook.sheets.count else { return }
        guard let p = grid.split else { doc.workbook.sheets[sheetIndex].split = nil; return }
        let z = grid.zoom
        let o = grid.scrollOrigin, po = grid.splitScroll
        var s = SheetSplit(x: (p.x / z).rounded(), y: (p.y / z).rounded())
        s.topLeft = grid.cell(at: NSPoint(x: po.x + 1, y: po.y + 1))
        s.bottomRight = grid.cell(at: NSPoint(x: o.x + p.x + 1, y: o.y + p.y + 1))
        let a = grid.active
        let right = p.x == 0 || a.col >= s.bottomRight.col, bottom = p.y == 0 || a.row >= s.bottomRight.row
        s.activePane = (bottom ? "bottom" : "top") + (right ? "Right" : "Left")
        doc.workbook.sheets[sheetIndex].split = s
    }

    /// Shows the sheet's saved split (from the file or before a sheet switch); removes the split when it has none.
    func restoreSplit() {
        guard let s = sheet.split, sheet.frozenRows == 0, sheet.frozenCols == 0 else {
            if grid.split != nil {
                grid.split = nil
                freezeOverlay.panesNeedDisplay(); headersNeedDisplay(); grid.needsDisplay = true
            }
            return
        }
        let z = grid.zoom
        let p = NSPoint(x: s.x * z, y: s.y * z)
        grid.split = p.x > 0 || p.y > 0 ? p : nil
        grid.splitScroll = NSPoint(x: p.x > 0 ? grid.x(s.topLeft.col) : 0, y: p.y > 0 ? grid.y(s.topLeft.row) : 0)
        let clip = scrollView.contentView
        let target = NSPoint(x: max(0, min(grid.x(s.bottomRight.col) - p.x, grid.frame.width - clip.bounds.width)),
                             y: max(0, min(grid.y(s.bottomRight.row) - p.y, grid.frame.height - clip.bounds.height)))
        clip.scroll(to: target)
        scrollView.reflectScrolledClipView(clip)
        freezeOverlay.panesNeedDisplay()
        headersNeedDisplay()
        grid.needsDisplay = true
    }

    // MARK: - Status bar

    /// Functions shown for the selection (Calc's status bar choice), saved in preferences.
    static let statusFunctionNames = ["Average", "Count", "Count Numbers", "Minimum", "Maximum", "Sum"]

    var statusFunctions: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "xls.statusFunctions") ?? ["Average", "Count", "Sum"]) }
        set { UserDefaults.standard.set(newValue.sorted(), forKey: "xls.statusFunctions") }
    }

    /// Text of the selection statistics ("Sum: 60   Average: 20   Count: 3").
    func statusText(for sel: CellRange) -> String {
        guard sel.count > 1 else { return "" }
        var sum = 0.0, count = 0, numeric = 0, minV = Double.infinity, maxV = -Double.infinity
        for (ref, cell) in sheet.cells where sel.contains(ref) && !cell.value.isEmpty && !sheet.isRowHidden(ref.row) {
            count += 1
            if case .number(let d) = cell.value { sum += d; numeric += 1; minV = min(minV, d); maxV = max(maxV, d) }
        }
        let f = statusFunctions
        var parts: [String] = []
        if numeric > 0 {
            if f.contains("Sum") { parts.append(L("Sum: %@", NumberFormat.general(sum))) }
            if f.contains("Average") { parts.append(L("Average: %@", NumberFormat.general(sum / Double(numeric)))) }
            if f.contains("Minimum") { parts.append(L("Min: %@", NumberFormat.general(minV))) }
            if f.contains("Maximum") { parts.append(L("Max: %@", NumberFormat.general(maxV))) }
            if f.contains("Count Numbers") { parts.append(L("Numbers: %d", numeric)) }
        }
        if f.contains("Count") { parts.append(L("Count: %d", count)) }
        return parts.joined(separator: "   ")
    }

    var statusMenu: NSMenu {
        let m = NSMenu()
        for name in Self.statusFunctionNames {
            let item = m.addItem(withTitle: L(name), action: #selector(toggleStatusFunction(_:)), keyEquivalent: "")
            item.representedObject = name
            item.state = statusFunctions.contains(name) ? .on : .off
            item.target = self
        }
        return m
    }

    @objc func toggleStatusFunction(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        var f = statusFunctions
        if f.contains(name) { f.remove(name) } else { f.insert(name) }
        statusFunctions = f
        status.menu = statusMenu
        selectionDidChange()
    }
}

/// Small colour button for the tab colour dialog.
final class ColorSwatchButton: NSButton {
    let swatch: NSColor
    let onClick: () -> Void

    init(color: NSColor, onClick: @escaping () -> Void) {
        swatch = color
        self.onClick = onClick
        super.init(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
        isBordered = false
        title = ""
        target = self
        action = #selector(clicked)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 20).isActive = true
        heightAnchor.constraint(equalToConstant: 20).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    @objc private func clicked() { onClick() }

    override func draw(_ dirtyRect: NSRect) {
        swatch.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 4, yRadius: 4).fill()
    }
}

/// Sheet tab with an optional colour strip (Sheet › Tab Colour).
final class SheetTabButton: NSButton {
    var tabColor: NSColor?

    /// Neutral tabs: the current sheet is a raised light tab (not an accent-filled button), others are plain text.
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 2), xRadius: 6, yRadius: 6)
        if state == .on {
            NSColor.controlBackgroundColor.setFill()
            path.fill()
            NSColor.labelColor.withAlphaComponent(0.15).setStroke()
            path.lineWidth = 0.5
            path.stroke()
        } else if isHighlighted {
            NSColor.labelColor.withAlphaComponent(0.08).setFill()
            path.fill()
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? .systemFont(ofSize: 12),
            .foregroundColor: state == .on ? NSColor.labelColor : NSColor.secondaryLabelColor,
        ]
        let text = title as NSString, size = text.size(withAttributes: attributes)
        text.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2), withAttributes: attributes)
        guard let c = tabColor else { return }
        c.setFill()
        NSBezierPath(roundedRect: NSRect(x: 4, y: bounds.height - 4, width: bounds.width - 8, height: 3), xRadius: 1.5, yRadius: 1.5).fill()
    }
}
