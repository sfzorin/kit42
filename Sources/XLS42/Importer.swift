import Foundation
import Kit42

/// Picks the reader by file contents: OLE2 → .xls, ZIP with OpenDocument mimetype → .ods,
/// other ZIP → .xlsx, anything else → CSV/TSV text.
enum SpreadsheetFile {
    enum Kind { case xlsx, xls, ods, csv }

    static func kind(of data: Data, typeName: String = "") -> Kind {
        let b = [UInt8](data.prefix(8))
        if b.starts(with: [0xD0, 0xCF, 0x11, 0xE0]) { return .xls }
        if b.starts(with: [0x50, 0x4B, 0x03, 0x04]) {
            if let zip = try? ZipArchive(data: data), let m = zip.string("mimetype"), m.contains("opendocument.spreadsheet") { return .ods }
            return .xlsx
        }
        return .csv
    }

    static func read(_ data: Data, typeName: String = "") throws -> Workbook {
        switch kind(of: data, typeName: typeName) {
        case .xls: return try XLSReader.read(data)
        case .ods: return try ODS.read(data)
        case .xlsx: return try XLSX.read(data)
        case .csv: return XLSX.readCSV(data)
        }
    }
}
