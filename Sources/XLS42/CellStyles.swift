import AppKit
import Kit42

/// Format › Cell Styles: the presets, then the front document's own named styles (added when the menu opens).
final class CellStyleMenu: NSObject, NSMenuDelegate {
    static let shared = CellStyleMenu()
    static let firstTag = 1000

    static func install(in menu: NSMenu?) {
        func find(_ m: NSMenu) -> NSMenu? {
            for item in m.items {
                guard let sub = item.submenu else { continue }
                if sub.items.contains(where: { $0.action == #selector(SheetWindowController.applyCellStyleAction(_:)) }) { return sub }
                if let found = find(sub) { return found }
            }
            return nil
        }
        if let m = menu, let sub = find(m) { sub.delegate = shared }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        for item in menu.items where item.tag >= Self.firstTag - 1 { menu.removeItem(item) }
        let editor = (NSApp.mainWindow?.windowController ?? NSApp.keyWindow?.windowController) as? SheetWindowController
        let names = editor?.documentStyleNames ?? []
        guard !names.isEmpty else { return }
        let sep = NSMenuItem.separator()
        sep.tag = Self.firstTag - 1
        menu.addItem(sep)
        for (i, name) in names.enumerated() {
            let item = NSMenuItem(title: L(name), action: #selector(SheetWindowController.applyCellStyleAction(_:)), keyEquivalent: "")
            item.representedObject = name
            item.tag = Self.firstTag + i
            menu.addItem(item)
        }
    }
}

/// Named cell styles (Format › Cell Styles): Excel's built-in set, saved as cellStyles in .xlsx.
enum CellStyles {
    struct Preset {
        let name: String          // as stored in files (Excel's name)
        let apply: (inout CellStyle) -> Void
        var title: String { L(name) }
    }

    /// Excel builtinId of each style (cellStyle/@builtinId).
    static let builtinIds: [String: Int] = [
        "Normal": 0, "Comma": 3, "Currency": 4, "Percent": 5, "Hyperlink": 8, "Note": 10, "Warning Text": 11, "Title": 15,
        "Heading 1": 16, "Heading 2": 17, "Heading 3": 18, "Input": 20, "Output": 21, "Calculation": 22, "Total": 25,
        "Good": 26, "Bad": 27, "Neutral": 28, "Accent1": 29, "Accent2": 33, "Accent3": 37, "Accent4": 41, "Explanatory Text": 53,
    ]

    static func hex(_ s: String) -> NSColor { XLSX.hexColor(s) ?? .black }

    static let presets: [Preset] = [
        Preset(name: "Normal") { $0 = .default },
        Preset(name: "Title") { s in s.fontSize = 18; s.bold = false; s.textColor = hex("44546A") },
        Preset(name: "Heading 1") { s in
            s.fontSize = 15; s.bold = true; s.textColor = hex("44546A")
            s.bottom = BorderSide(style: "thick", color: hex("4472C4"))
        },
        Preset(name: "Heading 2") { s in
            s.fontSize = 13; s.bold = true; s.textColor = hex("44546A")
            s.bottom = BorderSide(style: "thick", color: hex("A9C4EB"))
        },
        Preset(name: "Heading 3") { s in
            s.fontSize = 11; s.bold = true; s.textColor = hex("44546A")
            s.bottom = BorderSide(style: "medium", color: hex("8EA9DB"))
        },
        Preset(name: "Good") { s in s.fill = hex("C6EFCE"); s.textColor = hex("006100") },
        Preset(name: "Bad") { s in s.fill = hex("FFC7CE"); s.textColor = hex("9C0006") },
        Preset(name: "Neutral") { s in s.fill = hex("FFEB9C"); s.textColor = hex("9C5700") },
        Preset(name: "Accent1") { s in s.fill = hex("4472C4"); s.textColor = .white },
        Preset(name: "Accent2") { s in s.fill = hex("ED7D31"); s.textColor = .white },
        Preset(name: "Accent3") { s in s.fill = hex("A5A5A5"); s.textColor = .white },
        Preset(name: "Input") { s in
            s.fill = hex("FFCC99"); s.textColor = hex("3F3F76")
            let b = BorderSide(style: "thin", color: hex("7F7F7F"))
            (s.left, s.right, s.top, s.bottom) = (b, b, b, b)
        },
        Preset(name: "Calculation") { s in
            s.fill = hex("F2F2F2"); s.textColor = hex("FA7D00"); s.bold = true
            let b = BorderSide(style: "thin", color: hex("7F7F7F"))
            (s.left, s.right, s.top, s.bottom) = (b, b, b, b)
        },
        Preset(name: "Note") { s in
            s.fill = hex("FFFFCC")
            let b = BorderSide(style: "thin", color: hex("B2B2B2"))
            (s.left, s.right, s.top, s.bottom) = (b, b, b, b)
        },
        Preset(name: "Warning Text") { s in s.textColor = hex("FF0000") },
        Preset(name: "Explanatory Text") { s in s.italic = true; s.textColor = hex("7F7F7F") },
        Preset(name: "Total") { s in
            s.bold = true
            s.top = BorderSide(style: "thin", color: hex("4472C4"))
            s.bottom = BorderSide(style: "double", color: hex("4472C4"))
        },
        Preset(name: "Hyperlink") { s in s.textColor = hex("0563C1"); s.underline = true },
        Preset(name: "Currency") { s in s.numberFormat = SheetWindowController.currencyFormat },
        Preset(name: "Percent") { s in s.numberFormat = "0%" },
        Preset(name: "Comma") { s in s.numberFormat = "#,##0.00" },
    ]

    static func preset(named name: String) -> Preset? { presets.first { $0.name == name } }

    /// LibreOffice names of styles that Excel names differently (Accent 1 ↔ Accent1); others keep their name.
    static let odfNames = ["Accent1": "Accent 1", "Accent2": "Accent 2", "Accent3": "Accent 3"]

    /// Name used in XLS42 (Excel's) for a style name read from a file: LibreOffice's "Accent 1" and
    /// "Excel Built-in Good" (its name for Excel's built-in styles) become "Accent1" and "Good".
    static func internalName(_ fileName: String) -> String {
        var n = fileName
        if n.hasPrefix("Excel Built-in ") { n.removeFirst("Excel Built-in ".count) }
        if n.hasPrefix("Excel_20_Built-in_20_") { n.removeFirst("Excel_20_Built-in_20_".count) }
        return odfNames.first { $0.value == n }?.key ?? n
    }

    static func odfName(_ name: String) -> String { odfNames[name] ?? name }

    /// The formatting a named style stands for: the document's definition, else the preset's.
    static func definition(_ name: String, in wb: Workbook) -> CellStyle? {
        if let s = wb.cellStyles[name] { return s }
        guard let p = preset(named: name) else { return nil }
        return applied(p, to: .default)
    }

    /// Named styles to write: the document's own and every name used by a cell (first-use order, then by name).
    static func definitions(_ wb: Workbook) -> [(name: String, style: CellStyle)] {
        var names: [String] = []
        var seen = Set<String>()
        for sheet in wb.sheets {
            for ref in sheet.cells.keys.sorted() {
                if let n = sheet.cells[ref]?.style.styleName, n != "Normal", !seen.contains(n) { seen.insert(n); names.append(n) }
            }
        }
        for n in wb.cellStyles.keys.sorted() where !seen.contains(n) && n != "Normal" { seen.insert(n); names.append(n) }
        return names.compactMap { n in
            var s = definition(n, in: wb) ?? wb.sheets.lazy.flatMap { $0.cells.values }.first { $0.style.styleName == n }?.style
            s?.styleName = n
            return s.map { (n, $0) }
        }
    }

    /// A document style (not a preset) applied like a preset: its formatting replaces the cell's.
    static func applied(document style: CellStyle, name: String, to cell: CellStyle) -> CellStyle {
        var s = style
        s.styleName = name
        s.locked = cell.locked
        s.hiddenFormula = cell.hiddenFormula
        return s
    }

    /// The style with a preset applied: attributes the preset sets replace the cell's, the rest stays.
    static func applied(_ preset: Preset, to style: CellStyle) -> CellStyle {
        var s = style
        if preset.name == "Normal" {
            s = .default
            s.locked = style.locked
            return s
        }
        if ["Currency", "Percent", "Comma"].contains(preset.name) {
            preset.apply(&s)
            s.styleName = preset.name
            return s
        }
        // Start from the plain look so presets don't mix (fill of Good + border of Note…), keep number format/alignment.
        var base = CellStyle.default
        base.numberFormat = style.numberFormat
        base.hAlign = style.hAlign
        base.vAlign = style.vAlign
        base.wrap = style.wrap
        base.indent = style.indent
        base.locked = style.locked
        base.fontName = style.fontName
        s = base
        preset.apply(&s)
        s.styleName = preset.name
        return s
    }
}
