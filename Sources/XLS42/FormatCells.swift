import AppKit
import Kit42

/// Format › Cells… (⌥⌘1): numbers (categories, custom code, preview), font and effects, alignment (rotation,
/// indent, wrap, shrink to fit), borders (line style, colour, outer/inner lines), background, protection.
/// Only what the user changed is applied, so a multi-cell selection keeps its other formatting.
struct FormatCellsState: Equatable {
    var numberFormat: String
    var fontName: String
    var fontSize: CGFloat
    var bold: Bool, italic: Bool, underline: Bool, doubleUnderline: Bool, strike: Bool
    var textColor: NSColor?
    var hAlign: String?
    var vAlign: String
    var indent: Int
    var rotation: Int
    var wrap: Bool, shrink: Bool
    var borderStyle = "thin"
    var borderColor: NSColor = .black
    var left: Bool, right: Bool, top: Bool, bottom: Bool
    var innerH = false, innerV = false
    var fill: NSColor?
    var locked: Bool, hiddenFormula: Bool

    init(_ s: CellStyle) {
        numberFormat = s.numberFormat
        fontName = s.fontName ?? "Calibri"
        fontSize = s.fontSize
        bold = s.bold; italic = s.italic; underline = s.underline && !s.doubleUnderline; doubleUnderline = s.doubleUnderline; strike = s.strike
        textColor = s.textColor
        hAlign = s.hAlign; vAlign = s.vAlign; indent = s.indent; rotation = s.rotation; wrap = s.wrap; shrink = s.shrink
        left = s.left != nil; right = s.right != nil; top = s.top != nil; bottom = s.bottom != nil
        if let b = s.left ?? s.top ?? s.right ?? s.bottom { borderStyle = b.style; borderColor = b.color }
        fill = s.fill
        locked = s.locked; hiddenFormula = s.hiddenFormula
    }

    /// Edit applying the differences between `initial` and `self` to a cell at `ref` of `range`.
    func changes(from initial: FormatCellsState) -> (inout CellStyle, CellRef, CellRange) -> Void {
        let f = self
        return { s, ref, range in
            if f.numberFormat != initial.numberFormat { s.numberFormat = f.numberFormat }
            if f.fontName != initial.fontName { s.fontName = f.fontName }
            if f.fontSize != initial.fontSize { s.fontSize = f.fontSize }
            if f.bold != initial.bold { s.bold = f.bold }
            if f.italic != initial.italic { s.italic = f.italic }
            if f.underline != initial.underline || f.doubleUnderline != initial.doubleUnderline {
                s.underline = f.underline || f.doubleUnderline
                s.doubleUnderline = f.doubleUnderline
            }
            if f.strike != initial.strike { s.strike = f.strike }
            if f.textColor != initial.textColor { s.textColor = f.textColor }
            if f.hAlign != initial.hAlign { s.hAlign = f.hAlign }
            if f.vAlign != initial.vAlign { s.vAlign = f.vAlign }
            if f.indent != initial.indent { s.indent = f.indent }
            if f.rotation != initial.rotation { s.rotation = f.rotation }
            if f.wrap != initial.wrap { s.wrap = f.wrap }
            if f.shrink != initial.shrink { s.shrink = f.shrink }
            if f.fill != initial.fill { s.fill = f.fill }
            if f.locked != initial.locked { s.locked = f.locked }
            if f.hiddenFormula != initial.hiddenFormula { s.hiddenFormula = f.hiddenFormula }
            // Borders: outer lines on the range edges, inner lines between its cells.
            let side = BorderSide(style: f.borderStyle, color: f.borderColor)
            let restyle = f.borderStyle != initial.borderStyle || f.borderColor != initial.borderColor
            func set(_ key: WritableKeyPath<CellStyle, BorderSide?>, _ on: Bool, _ was: Bool, applies: Bool) {
                guard applies else { return }
                if on != was { s[keyPath: key] = on ? side : nil } else if on, restyle { s[keyPath: key] = side }
            }
            let atLeft = ref.col == range.start.col, atRight = ref.col == range.end.col
            let atTop = ref.row == range.start.row, atBottom = ref.row == range.end.row
            set(\.left, f.left, initial.left, applies: atLeft)
            set(\.right, f.right, initial.right, applies: atRight)
            set(\.top, f.top, initial.top, applies: atTop)
            set(\.bottom, f.bottom, initial.bottom, applies: atBottom)
            set(\.left, f.innerV, initial.innerV, applies: !atLeft)
            set(\.right, f.innerV, initial.innerV, applies: !atRight)
            set(\.top, f.innerH, initial.innerH, applies: !atTop)
            set(\.bottom, f.innerH, initial.innerH, applies: !atBottom)
            if initial != f { s.styleName = nil }
        }
    }
}

extension SheetWindowController {
    /// Number format categories of the dialog with their codes.
    static var numberCategories: [(title: String, codes: [String])] {
        [(L("General"), ["General"]), (L("Number"), ["0", "0.00", "#,##0", "#,##0.00", "#,##0.00;[Red]-#,##0.00"]),
         (L("Percent"), ["0%", "0.00%"]), (L("Currency"), [currencyFormat, "[$$-409]#,##0.00", "#,##0.00 [$€-1]", "#,##0.00 \"₽\""]),
         (L("Date"), ["dd.mm.yyyy", "d mmmm yyyy", "yyyy-mm-dd", "mm/dd/yyyy", "dd.mm.yy", "mmmm yyyy", "dddd, d mmmm yyyy"]),
         (L("Time"), ["hh:mm", "hh:mm:ss", "h:mm AM/PM", "[h]:mm:ss", "dd.mm.yyyy hh:mm"]),
         (L("Scientific"), ["0.00E+00", "##0.0E+0"]), (L("Fraction"), ["# ?/?", "# ??/??"]), (L("Text"), ["@"]),
         (L("Custom"), [])]
    }

    /// Format code for a category and options (decimals, thousands separator, red negatives).
    static func numberCode(category: Int, decimals: Int, thousands: Bool, redNegative: Bool) -> String? {
        let zeros = decimals > 0 ? "." + String(repeating: "0", count: decimals) : ""
        let base: String
        switch category {
        case 1: base = (thousands ? "#,##0" : "0") + zeros
        case 2: base = "0" + zeros + "%"
        case 3: base = currencyFormat.replacingOccurrences(of: ".00", with: zeros)
        case 6: base = "0" + zeros + "E+00"
        default: return nil
        }
        return redNegative ? base + ";[Red]-" + base : base
    }

    @objc func formatCellsAction(_ sender: Any?) {
        grid.commitEdit(move: nil)
        let range = clampedSelection
        let style = sheet[grid.active].style
        let initial = FormatCellsState(style)
        var state = initial
        let sample = sheet[grid.active].value.isEmpty ? Value.number(-1234.5678) : sheet[grid.active].value

        // Numbers
        let categories = Self.numberCategories
        let category = popup(categories.map(\.title))
        let formats = popup([])
        let decimals = NSStepper(), decimalsField = field("2", width: 40)
        decimals.minValue = 0; decimals.maxValue = 10; decimals.integerValue = 2
        let thousands = checkbox(L("Thousands separator"), true)
        let red = checkbox(L("Negative numbers red"), false)
        let code = field(style.numberFormat, width: 260)
        let preview = label("")
        preview.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        let currentCategory = categories.firstIndex { $0.codes.contains(style.numberFormat) } ?? (style.numberFormat == "General" ? 0 : categories.count - 1)
        category.selectItem(at: currentCategory)
        func refreshPreview() {
            let r = NumberFormat.format(sample, code.stringValue.isEmpty ? "General" : code.stringValue)
            preview.stringValue = r.text
            preview.textColor = r.color ?? .labelColor
        }
        func fillFormats() {
            formats.removeAllItems()
            let codes = categories[category.indexOfSelectedItem].codes
            formats.addItems(withTitles: codes.map { c in "\(NumberFormat.format(sample, c).text)    \(c)" })
            if let i = codes.firstIndex(of: code.stringValue) { formats.selectItem(at: i) }
            formats.isEnabled = !codes.isEmpty
            let numeric = [1, 2, 3, 6].contains(category.indexOfSelectedItem)
            decimals.isEnabled = numeric; decimalsField.isEnabled = numeric; red.isEnabled = numeric
            thousands.isEnabled = category.indexOfSelectedItem == 1
        }
        let actions = DialogActions {}
        let numberActions = NumberDialogActions(
            category: { fillFormats(); if let c = categories[category.indexOfSelectedItem].codes.first { code.stringValue = c }; refreshPreview() },
            format: {
                let codes = categories[category.indexOfSelectedItem].codes
                if formats.indexOfSelectedItem >= 0, formats.indexOfSelectedItem < codes.count { code.stringValue = codes[formats.indexOfSelectedItem] }
                refreshPreview()
            },
            options: {
                decimalsField.integerValue = decimals.integerValue
                if let c = Self.numberCode(category: category.indexOfSelectedItem, decimals: decimals.integerValue, thousands: thousands.state == .on,
                                           redNegative: red.state == .on) { code.stringValue = c }
                refreshPreview()
            },
            code: { refreshPreview() })
        category.target = numberActions; category.action = #selector(NumberDialogActions.categoryChanged)
        formats.target = numberActions; formats.action = #selector(NumberDialogActions.formatChanged)
        for c in [decimals, thousands, red] as [NSControl] { c.target = numberActions; c.action = #selector(NumberDialogActions.optionsChanged) }
        code.delegate = numberActions
        fillFormats(); refreshPreview()
        let numbersTab = gridView([[label(L("Category:")), category], [label(L("Format:")), formats],
                                   [label(L("Decimal places:")), NSStackView(views: [decimalsField, decimals])], [NSGridCell.emptyContentView, thousands],
                                   [NSGridCell.emptyContentView, red], [label(L("Format code:")), code], [label(L("Preview:")), preview]])

        // Font
        let fonts = ["Calibri", "Arial", "Helvetica Neue", "Times New Roman", "Georgia", "Verdana", "Courier New", "Menlo"]
        let fontPopup = popup(fonts.contains(state.fontName) ? fonts : fonts + [state.fontName])
        fontPopup.selectItem(withTitle: state.fontName)
        let size = field(Value.formatGeneral(Double(state.fontSize)), width: 60)
        let bold = checkbox(L("Bold"), state.bold), italic = checkbox(L("Italic"), state.italic)
        let underline = popup([L("None"), L("Single"), L("Double")], selected: state.doubleUnderline ? 2 : state.underline ? 1 : 0)
        let strike = checkbox(L("Strikethrough"), state.strike)
        let autoColor = checkbox(L("Automatic colour"), state.textColor == nil)
        let color = NSColorWell(frame: NSRect(x: 0, y: 0, width: 50, height: 24))
        color.color = state.textColor ?? .black
        let fontTab = gridView([[label(L("Font:")), fontPopup], [label(L("Size:")), size], [NSGridCell.emptyContentView, bold], [NSGridCell.emptyContentView, italic],
                                [label(L("Underline:")), underline], [NSGridCell.emptyContentView, strike], [label(L("Font colour:")), color], [NSGridCell.emptyContentView, autoColor]])

        // Alignment
        let hTitles = [L("General"), L("Left"), L("Center"), L("Right"), L("Justified"), L("Fill")]
        let hValues: [String?] = [nil, "left", "center", "right", "justify", "fill"]
        let hPopup = popup(hTitles, selected: hValues.firstIndex(of: state.hAlign) ?? 0)
        let vTitles = [L("Top"), L("Middle"), L("Bottom")], vValues = ["top", "center", "bottom"]
        let vPopup = popup(vTitles, selected: vValues.firstIndex(of: state.vAlign) ?? 2)
        let indent = field("\(state.indent)", width: 50)
        let rotation = field(state.rotation == 255 ? "0" : "\(state.rotation)", width: 50)
        let stacked = checkbox(L("Vertically stacked"), state.rotation == 255)
        let wrap = checkbox(L("Wrap text automatically"), state.wrap)
        let shrink = checkbox(L("Shrink to fit cell size"), state.shrink)
        let alignTab = gridView([[label(L("Horizontal:")), hPopup], [label(L("Vertical:")), vPopup], [label(L("Indent:")), indent],
                                 [label(L("Text rotation (°):")), rotation], [NSGridCell.emptyContentView, stacked],
                                 [NSGridCell.emptyContentView, wrap], [NSGridCell.emptyContentView, shrink]])

        // Borders
        let lineTitles = [L("Thin"), L("Medium"), L("Thick"), L("Dashed"), L("Dotted"), L("Double"), L("Hair")]
        let lineValues = ["thin", "medium", "thick", "dashed", "dotted", "double", "hair"]
        let line = popup(lineTitles, selected: lineValues.firstIndex(of: state.borderStyle) ?? 0)
        let lineColor = NSColorWell(frame: NSRect(x: 0, y: 0, width: 50, height: 24))
        lineColor.color = state.borderColor
        let bl = checkbox(L("Left"), state.left), br = checkbox(L("Right"), state.right), bt = checkbox(L("Top"), state.top), bb = checkbox(L("Bottom"), state.bottom)
        let ih = checkbox(L("Inner horizontal"), false), iv = checkbox(L("Inner vertical"), false)
        ih.isEnabled = range.rows.count > 1; iv.isEnabled = range.cols.count > 1
        let presetActions = BorderPresetActions(all: [bl, br, bt, bb, ih, iv])
        let none = NSButton(title: L("None"), target: presetActions, action: #selector(BorderPresetActions.none))
        let outer = NSButton(title: L("Outline"), target: presetActions, action: #selector(BorderPresetActions.outline))
        let all = NSButton(title: L("All"), target: presetActions, action: #selector(BorderPresetActions.everything))
        let bordersTab = gridView([[label(L("Presets:")), NSStackView(views: [none, outer, all])], [label(L("Line:")), line], [label(L("Colour:")), lineColor],
                                   [label(L("Outer:")), NSStackView(views: [bl, br, bt, bb])], [label(L("Inner:")), NSStackView(views: [ih, iv])]])

        // Background, protection
        let noFill = checkbox(L("No fill"), state.fill == nil)
        let fill = NSColorWell(frame: NSRect(x: 0, y: 0, width: 50, height: 24))
        fill.color = state.fill ?? .white
        let backgroundTab = gridView([[label(L("Background colour:")), fill], [NSGridCell.emptyContentView, noFill]])
        let locked = checkbox(L("Locked"), state.locked), hidden = checkbox(L("Hide formula"), state.hiddenFormula)
        let protectionTab = gridView([[NSGridCell.emptyContentView, locked], [NSGridCell.emptyContentView, hidden],
                                      [NSGridCell.emptyContentView, label(L("Takes effect when the sheet is protected (Sheet › Protect Sheet…)."))]])

        let tabs = NSTabView(frame: NSRect(x: 0, y: 0, width: 520, height: 330))
        for (title, view) in [(L("Numbers"), numbersTab), (L("Font"), fontTab), (L("Alignment"), alignTab), (L("Borders"), bordersTab),
                              (L("Background"), backgroundTab), (L("Cell Protection"), protectionTab)] {
            let item = NSTabViewItem(identifier: title)
            item.label = title
            let container = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 290))
            view.frame.origin = NSPoint(x: 16, y: max(8, 280 - view.fittingSize.height))
            view.frame.size = view.fittingSize
            container.addSubview(view)
            item.view = container
            tabs.addTabViewItem(item)
        }
        let alert = NSAlert()
        alert.messageText = L("Format Cells")
        alert.informativeText = L("Range %@", range.a1)
        alert.addButton(withTitle: L("OK"))
        alert.addButton(withTitle: L("Cancel"))
        alert.accessoryView = tabs
        let response = alert.runModal()
        withExtendedLifetime((actions, numberActions, presetActions)) {}
        guard response == .alertFirstButtonReturn else { return }
        state.numberFormat = code.stringValue.isEmpty ? "General" : code.stringValue
        state.fontName = fontPopup.titleOfSelectedItem ?? state.fontName
        if let v = Double(size.stringValue.replacingOccurrences(of: ",", with: ".")), v >= 1, v <= 409 { state.fontSize = CGFloat(v) }
        state.bold = bold.state == .on; state.italic = italic.state == .on; state.strike = strike.state == .on
        state.underline = underline.indexOfSelectedItem == 1; state.doubleUnderline = underline.indexOfSelectedItem == 2
        state.textColor = autoColor.state == .on ? nil : color.color.usingColorSpace(.sRGB)
        if autoColor.state == .on, initial.textColor == nil { state.textColor = nil }
        state.hAlign = hValues[hPopup.indexOfSelectedItem]
        state.vAlign = vValues[vPopup.indexOfSelectedItem]
        state.indent = max(0, min(15, Int(indent.stringValue) ?? 0))
        state.rotation = stacked.state == .on ? 255 : max(-90, min(90, Int(rotation.stringValue) ?? 0))
        state.wrap = wrap.state == .on; state.shrink = shrink.state == .on
        state.borderStyle = lineValues[line.indexOfSelectedItem]
        state.borderColor = lineColor.color.usingColorSpace(.sRGB) ?? .black
        if state.borderColor == initial.borderColor.usingColorSpace(.sRGB) { state.borderColor = initial.borderColor }
        state.left = bl.state == .on; state.right = br.state == .on; state.top = bt.state == .on; state.bottom = bb.state == .on
        state.innerH = ih.state == .on; state.innerV = iv.state == .on
        state.fill = noFill.state == .on ? nil : fill.color.usingColorSpace(.sRGB)
        if noFill.state == .off, initial.fill != nil, fill.color.usingColorSpace(.sRGB) == initial.fill?.usingColorSpace(.sRGB) { state.fill = initial.fill }
        if autoColor.state == .off, initial.textColor != nil, color.color.usingColorSpace(.sRGB) == initial.textColor?.usingColorSpace(.sRGB) { state.textColor = initial.textColor }
        state.locked = locked.state == .on; state.hiddenFormula = hidden.state == .on
        applyFormatCells(state, from: initial, range: range)
    }

    func gridView(_ rows: [[NSView]]) -> NSGridView {
        let width = rows.map(\.count).max() ?? 1
        let g = NSGridView(views: rows.map { $0 + Array(repeating: NSGridCell.emptyContentView, count: width - $0.count) })
        g.rowSpacing = 8
        g.columnSpacing = 8
        g.column(at: 0).xPlacement = .trailing
        return g
    }

    /// Applies the dialog's changes to every cell of the range (one undo step).
    func applyFormatCells(_ state: FormatCellsState, from initial: FormatCellsState, range: CellRange) {
        guard state != initial, let doc, guardEditable(range) else { return }
        let edit = state.changes(from: initial)
        doc.change(L("Format Cells"), recalc: state.numberFormat != initial.numberFormat) { wb in
            for ref in range.cells {
                var cell = wb.sheets[sheetIndex][ref]
                edit(&cell.style, ref, range)
                if state.numberFormat == "@", case .number = cell.value, !cell.isFormula { cell.value = .string(cell.input) }
                wb.sheets[sheetIndex][ref] = cell
            }
        }
    }
}

final class NumberDialogActions: NSObject, NSTextFieldDelegate {
    let category: () -> Void, format: () -> Void, options: () -> Void, code: () -> Void
    init(category: @escaping () -> Void, format: @escaping () -> Void, options: @escaping () -> Void, code: @escaping () -> Void) {
        self.category = category; self.format = format; self.options = options; self.code = code
    }
    @objc func categoryChanged() { category() }
    @objc func formatChanged() { format() }
    @objc func optionsChanged() { options() }
    func controlTextDidChange(_ obj: Notification) { code() }
}

final class BorderPresetActions: NSObject {
    let all: [NSButton]
    init(all: [NSButton]) { self.all = all }
    @objc func none() { all.forEach { $0.state = .off } }
    @objc func outline() { for (i, b) in all.enumerated() { b.state = i < 4 ? .on : .off } }
    @objc func everything() { all.forEach { if $0.isEnabled { $0.state = .on } } }
}
