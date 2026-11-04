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
        guard let doc, i < doc.workbook.sheets.count, guardStructure() else { return }
        var s = doc.workbook.sheets[i]
        var newName = (name?.trimmingCharacters(in: .whitespaces)).flatMap { $0.isEmpty ? nil : $0 } ?? s.name
        if copy {
            if doc.workbook.sheetIndex(named: newName) != nil {
                var n = 2
                while doc.workbook.sheetIndex(named: "\(s.name) (\(n))") != nil { n += 1 }
                newName = "\(s.name) (\(n))"
            }
            s.name = newName
            s.pivot = nil
            doc.change(L("Copy Sheet")) { $0.sheets.insert(s, at: min(before, $0.sheets.count)) }
            sheetIndex = min(before, doc.workbook.sheets.count - 1)
        } else {
            let old = s.name
            if newName != old, doc.workbook.sheetIndex(named: newName) == nil { s.name = newName } else { newName = old }
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

    static func renameReferences(_ wb: inout Workbook, from old: String, to name: String) {
        for si in wb.sheets.indices {
            if wb.sheets[si].pivot?.sourceSheet.caseInsensitiveCompare(old) == .orderedSame { wb.sheets[si].pivot?.sourceSheet = name }
            for (ref, cell) in wb.sheets[si].cells where cell.isFormula && cell.input.localizedCaseInsensitiveContains(old) {
                guard let e = try? Formula.parse(cell.input) else { continue }
                wb.sheets[si].cells[ref]?.input = "=" + Formula.serialize(renameSheetRefs(e, from: old, to: name))
            }
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
        doc?.change(L("Tab Colour"), recalc: false) { $0.sheets[i].tabColor = color }
    }

    @objc func hideSheetAction(_ sender: Any?) {
        let i = commandTag(of: sender) > 0 ? commandTag(of: sender) - 1 : sheetIndex
        hideSheet(i)
    }

    func hideSheet(_ i: Int) {
        guard let doc, guardStructure(), visibleSheets.count > 1, i < doc.workbook.sheets.count else { NSSound.beep(); return }
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
        guard let doc, guardStructure() else { return }
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
        grid.commitEdit(move: nil)
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
        guard let doc, guardEditable(CellRange(ref, ref)) else { return }
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
            var place = String(target.dropFirst())
            var si = sheetIndex
            if let bang = place.lastIndex(of: "!") {
                var name = String(place[..<bang])
                if name.hasPrefix("'"), name.hasSuffix("'"), name.count > 1 { name = String(name.dropFirst().dropLast()) }
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
        let i = commandTag(of: sender)
        guard i >= 0, i < CellStyles.presets.count else { return }
        applyCellStyle(CellStyles.presets[i])
    }

    func applyCellStyle(_ preset: CellStyles.Preset) {
        let range = clampedSelection
        guard let doc, guardEditable(range) else { return }
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

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let c = tabColor else { return }
        c.setFill()
        NSBezierPath(roundedRect: NSRect(x: 4, y: bounds.height - 4, width: bounds.width - 8, height: 3), xRadius: 1.5, yRadius: 1.5).fill()
    }
}
