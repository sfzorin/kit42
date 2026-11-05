import AppKit
import Kit42

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
