import AppKit
import Kit42
import PDFKit

/// PDF/print and CSV export of sheets.
enum SheetExport {
    enum Scope: Int { case sheet, workbook, selection }
    enum Orientation: Int { case auto, portrait, landscape }

    /// Print/export settings, shared by the PDF dialog and the print panel (KVO for live preview).
    final class Options: NSObject {
        @objc dynamic var scopeIndex = 0          // Scope raw value
        @objc dynamic var orientationIndex = 0    // Orientation raw value
        @objc dynamic var fitWidth = true
        @objc dynamic var gridlines = true
        @objc dynamic var repeatTitles = true     // frozen rows repeat on every page
        @objc dynamic var pageNumbers = true

        var scope: Scope { get { Scope(rawValue: scopeIndex) ?? .sheet } set { scopeIndex = newValue.rawValue } }
        var orientation: Orientation { get { Orientation(rawValue: orientationIndex) ?? .auto } set { orientationIndex = newValue.rawValue } }

        static let keys = ["scopeIndex", "orientationIndex", "fitWidth", "gridlines", "repeatTitles", "pageNumbers"]

        static var saved: Options {
            let o = Options()
            let d = UserDefaults.standard
            for key in keys where d.object(forKey: "print." + key) != nil { o.setValue(d.object(forKey: "print." + key), forKey: key) }
            return o
        }

        func save() {
            for key in Self.keys { UserDefaults.standard.set(value(forKey: key), forKey: "print." + key) }
        }
    }

    static func printInfo(from base: NSPrintInfo) -> NSPrintInfo {
        let info = base.copy() as! NSPrintInfo
        info.leftMargin = 36; info.rightMargin = 36; info.topMargin = 36; info.bottomMargin = 30
        info.horizontalPagination = .clip
        info.verticalPagination = .clip
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        info.scalingFactor = 1
        return info
    }

    /// Multi-page PDF of the chosen sheets.
    static func pdf(_ wb: Workbook, activeSheet: Int, selection: CellRange?, options: Options, base: NSPrintInfo) -> Data {
        let info = printInfo(from: base)
        let view = SheetPrintView(workbook: wb, activeSheet: activeSheet, selection: selection, options: options)
        view.prepare(info)
        return PaginatedPDF.render(view, info: info)
    }

    // MARK: - CSV

    /// CSV is rectangular, including empty positions preceding the last used cell.
    static func validateCSVSize(_ sheet: Sheet) throws {
        guard let used = sheet.usedRange else { return }
        guard used.end.row + 1 <= 2_000_000 / (used.end.col + 1) else {
            throw NSError(domain: "XLS42", code: 2, userInfo: [NSLocalizedDescriptionKey: L("CSV export supports up to %d cells, including empty cells before the last used cell.", 2_000_000)])
        }
    }

    static func csv(_ sheet: Sheet, delimiter: Character, bom: Bool, date1904: Bool = false) throws -> Data {
        try validateCSVSize(sheet)
        guard let used = sheet.usedRange else { return Data() }
        var lines: [String] = []
        for r in 0...used.end.row {
            var fields: [String] = []
            for c in 0...used.end.col {
                let cell = sheet[CellRef(row: r, col: c)]
                var s: String
                if case .number(let d) = cell.value, cell.style.numberFormat == "General" || !NumberFormat.isDateFormat(cell.style.numberFormat) {
                    s = Value.numberLiteral(d)
                    if delimiter == ";" { s = s.replacingOccurrences(of: ".", with: ",") }
                } else {
                    s = NumberFormat.format(cell.value, cell.style.numberFormat, date1904: date1904).text
                }
                if s.contains(where: { $0 == delimiter || $0 == "\"" || $0 == "\n" || $0 == "\r" }) {
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
