import Kit42
import AppKit

/// Zero-based cell address.
struct CellRef: Hashable, Comparable {
    var row: Int
    var col: Int

    static func < (a: CellRef, b: CellRef) -> Bool { a.row != b.row ? a.row < b.row : a.col < b.col }

    static func columnName(_ col: Int) -> String {
        var n = col + 1, s = ""
        while n > 0 {
            let r = (n - 1) % 26
            s = String(UnicodeScalar(65 + r)!) + s
            n = (n - 1) / 26
        }
        return s
    }

    static func columnIndex(_ letters: Substring) -> Int? {
        var n = 0
        for ch in letters.uppercased().unicodeScalars {
            guard ch.value >= 65, ch.value <= 90 else { return nil }
            guard n <= (RefPart.maxCol + 1 - Int(ch.value - 64)) / 26 else { return nil }
            n = n * 26 + Int(ch.value - 64)
        }
        return n > 0 ? n - 1 : nil
    }

    var a1: String { Self.columnName(col) + "\(row + 1)" }

    /// Parses "B12" (no $, no sheet).
    init?(_ s: String) {
        let t = s.replacingOccurrences(of: "$", with: "")
        guard let i = t.firstIndex(where: \.isNumber), let col = Self.columnIndex(t[..<i]),
              let row = Int(t[i...]), row > 0, row <= RefPart.maxRow + 1 else { return nil }
        self.init(row: row - 1, col: col)
    }

    init(row: Int, col: Int) {
        self.row = row
        self.col = col
    }
}

struct CellRange: Hashable {
    var start: CellRef
    var end: CellRef

    init(_ a: CellRef, _ b: CellRef) {
        start = CellRef(row: min(a.row, b.row), col: min(a.col, b.col))
        end = CellRef(row: max(a.row, b.row), col: max(a.col, b.col))
    }

    init?(_ s: String) {
        let parts = s.split(separator: ":", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.count <= 2, let a = CellRef(String(parts[0])) else { return nil }
        let b = parts.count > 1 ? CellRef(String(parts[1])) : a
        guard let b else { return nil }
        self.init(a, b)
    }

    func contains(_ r: CellRef) -> Bool { r.row >= start.row && r.row <= end.row && r.col >= start.col && r.col <= end.col }
    var rows: ClosedRange<Int> { start.row...end.row }
    var cols: ClosedRange<Int> { start.col...end.col }
    var count: Int { rows.count * cols.count }
    var a1: String { start == end ? start.a1 : "\(start.a1):\(end.a1)" }

    var cells: [CellRef] { rows.flatMap { r in cols.map { CellRef(row: r, col: $0) } } }
}

enum Value: Equatable {
    case empty
    case number(Double)
    case string(String)
    case bool(Bool)
    case error(String)

    var isEmpty: Bool { if case .empty = self { return true }; return false }
    var isError: Bool { if case .error = self { return true }; return false }

    /// Text for editing / CSV (not number-formatted).
    var plain: String {
        switch self {
        case .empty: return ""
        case .number(let d): return Value.formatGeneral(d)
        case .string(let s): return s
        case .bool(let b): return b ? "ИСТИНА" : "ЛОЖЬ"
        case .error(let e): return e
        }
    }

    static func formatGeneral(_ d: Double) -> String {
        if d.isNaN || d.isInfinite { return "#ЧИСЛО!" }
        if d == d.rounded(), abs(d) < 1e15 { return String(Int64(d)) }
        let s = String(format: "%.10g", d)
        return s.contains("e") ? String(format: "%.5E", d) : s
    }

    /// Numeric text for editing and persistence must retain the value's full precision.
    static func numberLiteral(_ d: Double) -> String {
        guard d.isFinite else { return "#NUM!" }
        let text = String(d)
        return text.hasSuffix(".0") ? String(text.dropLast(2)) : text
    }
}

struct BorderSide: Hashable {
    var style: String = "thin"   // thin, medium, thick, dashed, dotted, double, hair
    var color: NSColor = .black

    var width: CGFloat {
        switch style {
        case "medium", "mediumDashed", "mediumDashDot": return 1.5
        case "thick", "double": return 2.5
        case "hair": return 0.5
        default: return 1
        }
    }
}

struct CellStyle: Hashable {
    var fontName: String?
    var fontSize: CGFloat = 11
    var bold = false
    var italic = false
    var underline = false
    var strike = false
    var textColor: NSColor?
    var fill: NSColor?
    var hAlign: String?          // left, center, right, general
    var vAlign: String = "bottom" // top, center, bottom
    var wrap = false
    var indent = 0
    var numberFormat = "General"
    /// Protected from editing while the sheet is protected (Excel default: locked).
    var locked = true
    /// Protection: the formula isn't shown while the sheet is protected.
    var hiddenFormula = false
    /// Text rotation in degrees (−90…90; 255 = stacked vertically) and shrink to fit.
    var rotation = 0
    var shrink = false
    var doubleUnderline = false
    /// Named cell style the formatting came from (Heading 1, Good, …).
    var styleName: String?
    var left: BorderSide?
    var right: BorderSide?
    var top: BorderSide?
    var bottom: BorderSide?

    static let `default` = CellStyle()

    func font(scale: CGFloat = 1) -> NSFont {
        let size = fontSize * scale
        var font: NSFont
        if let name = fontName, let installed = NSFont(name: name, size: size) {
            font = installed
        } else if let name = fontName, let fallback = Self.fontMap[name].flatMap({ NSFont(name: $0, size: size) }) {
            font = fallback
        } else {
            // Calibri/Aptos are narrower than Helvetica Neue; a slightly smaller size keeps Excel's column fit.
            // (Not the system font: its Cyrillic "к" extracts from PDFs as "ĸ".)
            let narrow = fontName == nil || ["Calibri", "Aptos", "Aptos Narrow", "Carlito"].contains(fontName!)
            font = NSFont(name: "Helvetica Neue", size: size * (narrow ? 0.9 : 1)) ?? NSFont.systemFont(ofSize: size)
        }
        var traits: NSFontDescriptor.SymbolicTraits = []
        if bold { traits.insert(.bold) }
        if italic { traits.insert(.italic) }
        if !traits.isEmpty {
            let d = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(traits))
            font = NSFont(descriptor: d, size: size) ?? font
        }
        return font
    }

    /// Office fonts often missing on macOS → close metric equivalents.
    static let fontMap: [String: String] = [
        "Cambria": "Georgia", "Times New Roman": "Times New Roman", "Courier New": "Menlo",
        "Consolas": "Menlo", "Segoe UI": "Helvetica Neue", "Tahoma": "Verdana", "Arial Narrow": "Arial",
    ]
}

struct Cell: Equatable {
    /// What the user typed: a constant ("12", "текст") or a formula ("=SUM(A1:A3)").
    var input: String = ""
    var style: CellStyle = .default
    /// Cached value: the constant, or the formula result after recalculation.
    var value: Value = .empty
    /// Array formula (Excel CSE / ODF matrix): its result fills the cells below and to the right.
    var array = false

    var isFormula: Bool { input.hasPrefix("=") && input.count > 1 }
    var isBlank: Bool { input.isEmpty && style == .default }
}

struct Sheet {
    var name: String
    var cells: [CellRef: Cell] = [:]
    var columnWidths: [Int: CGFloat] = [:]   // points
    var rowHeights: [Int: CGFloat] = [:]     // points
    var merges: [CellRange] = []
    var defaultColumnWidth: CGFloat = 48   // Excel default 64 px = 48 pt
    var defaultRowHeight: CGFloat = 15
    var frozenRows = 0
    var frozenCols = 0
    var showGridlines = true
    /// Range printed/exported for this sheet (Excel _xlnm.Print_Area).
    var printArea: CellRange?
    /// AutoFilter header range; rows hidden by the filter and the allowed values per column.
    var autoFilter: CellRange?
    var filterHidden: Set<Int> = []
    var filterValues: [Int: Set<String>] = [:]
    var comments: [CellRef: String] = [:]
    var conditionalFormats: [ConditionalFormat] = []
    var images: [SheetImage] = []
    var charts: [SheetChart] = []
    var validations: [DataValidation] = []
    /// Outline (grouping) levels 1…7 of rows/columns, and the members hidden by collapsing a group.
    var rowLevels: [Int: Int] = [:]
    var colLevels: [Int: Int] = [:]
    var outlineHiddenRows: Set<Int> = []
    var outlineHiddenCols: Set<Int> = []
    /// Sheet protection: when set, locked cells can't be edited.
    var protection: SheetProtection?
    /// Pivot table on this sheet (its settings, for Refresh; saved as a pivot table in .xlsx / .ods).
    var pivot: PivotSpec?
    /// Ranges filled by spilling array formulas (anchor → range), set by the recalculation.
    var spills: [CellRef: CellRange] = [:]
    /// Sheet tab colour and visibility.
    var tabColor: NSColor?
    var hidden = false
    /// Hyperlinks: URL, e-mail, file or "#Sheet!A1" for a place in the workbook.
    var hyperlinks: [CellRef: String] = [:]
    /// Standard filter conditions per column of the AutoFilter range (with value lists in `filterValues`).
    var customFilters: [Int: ColumnFilter] = [:]
    /// Manual page breaks before these rows (Subtotals › page break between groups).
    var rowBreaks: Set<Int> = []
    /// Legacy array formulas (Excel Ctrl+Shift+Enter, ODF matrices): anchor → the fixed range the result fills.
    var arrays: [CellRef: CellRange] = [:]
    /// Tools › Solver model kept with the sheet (Excel/LibreOffice hidden solver_… names).
    var solver: SolverModel?
    /// View › Split Window position and the first cells of the panes (saved in the file's view settings).
    var split: SheetSplit?

    init(name: String) { self.name = name }

    /// The legacy array formula whose range contains `ref`.
    func array(containing ref: CellRef) -> (anchor: CellRef, range: CellRange)? {
        if let r = arrays[ref] { return (ref, r) }
        return arrays.first { $0.value.contains(ref) }.map { ($0.key, $0.value) }
    }

    subscript(ref: CellRef) -> Cell {
        get { cells[ref] ?? Cell() }
        set { if newValue.isBlank { cells[ref] = nil } else { cells[ref] = newValue } }
    }

    func width(_ col: Int) -> CGFloat { outlineHiddenCols.contains(col) ? 0 : columnWidths[col] ?? defaultColumnWidth }
    func height(_ row: Int) -> CGFloat {
        filterHidden.contains(row) || outlineHiddenRows.contains(row) ? 0 : rowHeights[row] ?? defaultRowHeight
    }
    func isRowHidden(_ row: Int) -> Bool { height(row) == 0 }
    func isColumnHidden(_ col: Int) -> Bool { width(col) == 0 }

    var usedRange: CellRange? {
        guard !cells.isEmpty else { return nil }
        let rows = cells.keys.map(\.row), cols = cells.keys.map(\.col)
        return CellRange(CellRef(row: rows.min()!, col: cols.min()!), CellRef(row: rows.max()!, col: cols.max()!))
    }

    func merge(containing ref: CellRef) -> CellRange? { merges.first { $0.contains(ref) } }

    func validation(at ref: CellRef) -> DataValidation? { validations.last { $0.ranges.contains { $0.contains(ref) } } }
    var isProtected: Bool { protection != nil }
    var maxRowLevel: Int { rowLevels.values.max() ?? 0 }
    var maxColLevel: Int { colLevels.values.max() ?? 0 }
}

/// Split window: pane sizes in grid pixels at 100 % (Excel pixels, 0 = no split on that axis)
/// and the first cell shown in the top-left and in the bottom-right pane.
struct SheetSplit: Equatable {
    var x: CGFloat
    var y: CGFloat
    var topLeft = CellRef(row: 0, col: 0)
    var bottomRight = CellRef(row: 0, col: 0)
    var activePane = "bottomRight"

    /// Width of the row headers and height of the column headers at 100 % in Excel pixels: Excel and LibreOffice
    /// measure split positions from the window's edge, headers included (XlsxWriter: 390 and 300 twips).
    static let headerWidth: CGFloat = 26
    static let headerHeight: CGFloat = 20

    /// Excel's xSplit/ySplit (twips; 1 px = 15 twips at 96 dpi).
    var twips: (x: Int, y: Int) {
        (x > 0 ? Int(((x + Self.headerWidth) * 15).rounded()) : 0, y > 0 ? Int(((y + Self.headerHeight) * 15).rounded()) : 0)
    }

    /// LibreOffice's HorizontalSplitPosition/VerticalSplitPosition (pixels, headers included).
    var pixels: (x: Int, y: Int) {
        (x > 0 ? Int((x + Self.headerWidth).rounded()) : 0, y > 0 ? Int((y + Self.headerHeight).rounded()) : 0)
    }

    /// First cell of the pane below/right of the split lines (Excel's pane/@topLeftCell).
    var paneTopLeft: CellRef {
        CellRef(row: y > 0 ? bottomRight.row : topLeft.row, col: x > 0 ? bottomRight.col : topLeft.col)
    }

    /// Active pane name valid for the split's axes.
    var normalizedPane: String {
        let right = x > 0 && activePane.hasSuffix("Right"), bottom = y > 0 && activePane.hasPrefix("bottom")
        return bottom && right ? "bottomRight" : bottom ? "bottomLeft" : right ? "topRight" : "topLeft"
    }

    static let odsPanes = ["topLeft", "topRight", "bottomLeft", "bottomRight"]

    static func fromTwips(x tx: Double, y ty: Double, topLeft: CellRef?, paneTopLeft: CellRef?, activePane: String?) -> SheetSplit? {
        guard tx > 0 || ty > 0 else { return nil }
        return from(x: tx / 15, y: ty / 15, topLeft: topLeft, paneTopLeft: paneTopLeft, activePane: activePane)
    }

    /// From positions in pixels with the headers (Excel twips / 15, LibreOffice pixels).
    static func from(x px: Double, y py: Double, topLeft: CellRef?, paneTopLeft: CellRef?, activePane: String?) -> SheetSplit? {
        guard px > 0 || py > 0 else { return nil }
        let x = px > 0 ? max(4, CGFloat(px) - headerWidth) : 0, y = py > 0 ? max(4, CGFloat(py) - headerHeight) : 0
        let tl = topLeft ?? CellRef(row: 0, col: 0), pane = paneTopLeft ?? tl
        var s = SheetSplit(x: x.rounded(), y: y.rounded(), topLeft: tl, bottomRight: pane)
        // Without a split on an axis both panes scroll together there.
        if x == 0 { s.topLeft.col = pane.col }
        if y == 0 { s.topLeft.row = pane.row }
        s.activePane = activePane ?? "bottomRight"
        s.activePane = s.normalizedPane
        return s
    }
}

/// One condition of a standard filter or an AutoFilter custom filter.
struct FilterCondition: Equatable {
    enum Op: String, CaseIterable {
        case equal, notEqual, greaterThan, lessThan, greaterThanOrEqual, lessThanOrEqual
        case contains, notContains, beginsWith, endsWith, top, bottom, topPercent, bottomPercent, empty, notEmpty
    }
    var op: Op
    var value: String = ""
}

/// Conditions on one filter column, joined by AND or OR (Excel keeps at most two, or one top/bottom N).
struct ColumnFilter: Equatable {
    var conditions: [FilterCondition]
    var and = true
}

/// Data validation rule (Excel's subset): allowed values for a set of ranges.
struct DataValidation {
    enum Kind: String, CaseIterable { case list, whole, decimal, date, textLength, time, custom }
    var ranges: [CellRange]
    var kind: Kind
    /// between, notBetween, equal, notEqual, greaterThan, lessThan, greaterThanOrEqual, lessThanOrEqual
    var op = "between"
    /// Formula text as stored in .xlsx, without "=": `"a,b,c"` (literal list), `$H$1:$H$5`, `10`, `45366`.
    var formula1 = ""
    var formula2 = ""
    var allowBlank = true
    var showDropdown = true
    var errorStyle = "stop"   // stop, warning, information
    var errorTitle = ""
    var errorMessage = ""
}

/// Sheet protection; the password is kept only as hashes (Excel legacy 16-bit, ODF SHA-1).
struct SheetProtection: Equatable {
    var passwordHash: String?
    var odsKey: String?
    var odsDigest: String?
    /// Modern Excel hash (`algorithmName="SHA-512"`), kept from opened files.
    var sha512Hash: String?
    var sha512Salt: String?
    var spinCount = 100_000
}

/// Pivot table definition: grouped by row (and optional column) field, one aggregated value field.
struct PivotSpec {
    enum Aggregate: Int, CaseIterable { case sum, count, average, min, max }
    var sourceSheet: String
    var source: CellRange
    var rowField: Int        // column offsets within `source`
    var colField: Int?
    var valueField: Int
    var aggregate: Aggregate
    /// Top-left cell of the result on its sheet, and the range the result last covered.
    var anchor = CellRef(row: 0, col: 0)
    var location: CellRange?
    /// Field names of the source's header row when the pivot was made (fields follow their names on refresh).
    var fieldNames: [String] = []
    var name = "PivotTable1"
}

/// Conditional formatting rule (subset of Excel's): comparisons, text contains, colour scale, data bar.
struct ConditionalFormat {
    enum Kind {
        case cellIs(op: String, values: [String])   // greaterThan, lessThan, between, equal, notEqual, …
        case containsText(String)
        case expression(String)                       // formula relative to the range's top-left cell
        case colorScale([NSColor])                    // 2 or 3 colours, min → max
        case dataBar(NSColor)
        case duplicates
    }
    var range: CellRange
    var kind: Kind
    var fill: NSColor?
    var textColor: NSColor?
    var bold = false
}

/// Picture placed over cells (top-left anchor cell + offset, size in points).
struct SheetImage {
    var anchor: CellRef
    var offset: CGPoint = .zero
    var size: CGSize
    var data: Data
}

/// Chart drawn over cells, with series read from ranges.
struct SheetChart {
    enum Kind: String { case bar, column, line, pie, area, scatter }
    struct Series { var name: String; var categories: String?; var values: String }
    var kind: Kind
    var title: String
    var series: [Series]
    var anchor: CellRef
    var size: CGSize
}

struct Workbook {
    var sheets: [Sheet] = [Sheet(name: "Лист1")]
    /// Defined names: name → reference or formula text without "=" (e.g. "Лист1!$A$1:$A$10").
    var names: [String: String] = [:]
    /// Excel serial dates: 1900 system (default) or 1904.
    var date1904 = false
    /// Workbook structure protection: sheets can't be added, deleted, moved, renamed or hidden.
    var structureProtected = false
    /// Named cell styles defined in the file (besides Normal/Default): name → the style's formatting.
    var cellStyles: [String: CellStyle] = [:]

    func sheetIndex(named name: String) -> Int? {
        sheets.firstIndex { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }
}
