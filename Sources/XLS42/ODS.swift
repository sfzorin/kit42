import AppKit
import Kit42

/// OpenDocument Spreadsheet (.ods) — implemented in the next step.
enum ODS {
    static func read(_ data: Data) throws -> Workbook { throw ZipError.corrupt }
    static func write(_ wb: Workbook) -> Data { Data() }
}
