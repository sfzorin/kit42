import AppKit
import Kit42
import PDFKit

/// PDF/print and CSV export of sheets.
enum SheetExport {
    enum Scope: Int { case sheet, workbook, selection }
    enum Orientation: Int { case auto, portrait, landscape }

    struct Options {
        var scope: Scope = .sheet
        var orientation: Orientation = .auto
        var fitWidth = true
        var gridlines = true

        static var saved: Options {
            let d = UserDefaults.standard
            var o = Options()
            o.scope = Scope(rawValue: d.integer(forKey: "pdf.scope")) ?? .sheet
            o.orientation = Orientation(rawValue: d.integer(forKey: "pdf.orientation")) ?? .auto
            if d.object(forKey: "pdf.fit") != nil { o.fitWidth = d.bool(forKey: "pdf.fit") }
            if d.object(forKey: "pdf.grid") != nil { o.gridlines = d.bool(forKey: "pdf.grid") }
            return o
        }

        func save() {
            let d = UserDefaults.standard
            d.set(scope.rawValue, forKey: "pdf.scope")
            d.set(orientation.rawValue, forKey: "pdf.orientation")
            d.set(fitWidth, forKey: "pdf.fit")
            d.set(gridlines, forKey: "pdf.grid")
        }
    }

    /// Detached grid laid out for printing one sheet.
    static func printView(_ sheet: Sheet, range: CellRange?, options: Options, info: NSPrintInfo) -> GridView {
        let view = GridView(frame: .zero)
        view.sheetOverride = sheet
        view.printMode = true
        view.printGridlines = options.gridlines
        view.printRange = range
        view.zoom = 0.75   // 1 pt on paper per Excel point
        view.rebuildLayout()
        let r = range ?? sheet.usedRange ?? CellRange(CellRef(row: 0, col: 0), CellRef(row: 0, col: 0))
        let width = view.x(r.end.col + 1) - view.x(r.start.col)

        let portraitWidth = min(info.paperSize.width, info.paperSize.height) - info.leftMargin - info.rightMargin
        switch options.orientation {
        case .portrait: info.orientation = .portrait
        case .landscape: info.orientation = .landscape
        case .auto: info.orientation = width > portraitWidth * 1.1 ? .landscape : .portrait
        }
        let pageWidth = info.paperSize.width - info.leftMargin - info.rightMargin
        if options.fitWidth, width > pageWidth {
            view.zoom = max(0.2, 0.75 * pageWidth / width)
            view.rebuildLayout()
        }
        return view
    }

    static func printInfo(from base: NSPrintInfo) -> NSPrintInfo {
        let info = base.copy() as! NSPrintInfo
        info.leftMargin = 36; info.rightMargin = 36; info.topMargin = 40; info.bottomMargin = 40
        info.horizontalPagination = .automatic
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        info.scalingFactor = 1
        return info
    }

    /// Multi-page PDF of the chosen sheets.
    static func pdf(_ wb: Workbook, activeSheet: Int, selection: CellRange?, options: Options, base: NSPrintInfo) -> Data {
        let indices: [Int]
        switch options.scope {
        case .workbook: indices = Array(wb.sheets.indices)
        default: indices = [activeSheet]
        }
        let merged = PDFDocument()
        for i in indices {
            let sheet = wb.sheets[i]
            guard options.scope == .selection || sheet.usedRange != nil else { continue }
            let info = printInfo(from: base)
            let view = printView(sheet, range: options.scope == .selection ? selection : nil, options: options, info: info)
            guard let part = PDFDocument(data: PaginatedPDF.render(view, info: info)) else { continue }
            for p in 0..<part.pageCount { if let page = part.page(at: p) { merged.insert(page, at: merged.pageCount) } }
        }
        return merged.dataRepresentation() ?? Data()
    }

    // MARK: - CSV

    static func csv(_ sheet: Sheet, delimiter: Character, bom: Bool) -> Data {
        guard let used = sheet.usedRange else { return Data() }
        var lines: [String] = []
        for r in 0...used.end.row {
            var fields: [String] = []
            for c in 0...used.end.col {
                let cell = sheet[CellRef(row: r, col: c)]
                var s: String
                if case .number(let d) = cell.value, cell.style.numberFormat == "General" || !NumberFormat.isDateFormat(cell.style.numberFormat) {
                    s = Value.formatGeneral(d)
                    if delimiter == ";" { s = s.replacingOccurrences(of: ".", with: ",") }
                } else {
                    s = NumberFormat.format(cell.value, cell.style.numberFormat).text
                }
                if s.contains(where: { $0 == delimiter || $0 == "\"" || $0 == "\n" }) {
                    s = "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
                }
                fields.append(s)
            }
            lines.append(fields.joined(separator: String(delimiter)))
        }
        var data = Data(bom ? [0xEF, 0xBB, 0xBF] : [])
        data.append(Data((lines.joined(separator: "\r\n") + "\r\n").utf8))
        return data
    }
}
