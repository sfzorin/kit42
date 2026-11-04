import AppKit
import Kit42

Localization.register(rows: xls42Strings)

if CommandLine.arguments.contains("--selftest") { exit(SelfTest.run()) }
// XLS42 --roundtrip in.xlsx out.xlsx: read, recalculate, write (for testing compatibility)
if let i = CommandLine.arguments.firstIndex(of: "--roundtrip"), CommandLine.arguments.count > i + 2 {
    let args = CommandLine.arguments
    var wb = try SpreadsheetFile.read(Data(contentsOf: URL(fileURLWithPath: args[i + 1])))
    wb = Calculator.recalculate(wb)
    for s in wb.sheets {
        print("[\(s.name)] cells: \(s.cells.count), formulas: \(s.cells.values.filter(\.isFormula).count), merges: \(s.merges.count)")
        for ref in s.cells.keys.sorted().prefix(40) {
            let c = s.cells[ref]!
            print("  \(ref.a1) \(c.input.prefix(50)) → \(NumberFormat.format(c.value, c.style.numberFormat).text)")
        }
    }
    try XLSX.write(wb).write(to: URL(fileURLWithPath: args[i + 2]))
    exit(0)
}

// XLS42 --info file: summary of structure (for format tests)
if let i = CommandLine.arguments.firstIndex(of: "--info"), CommandLine.arguments.count > i + 1 {
    let wb = Calculator.recalculate(try SpreadsheetFile.read(Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[i + 1]))))
    for s in wb.sheets {
        let formulas = s.cells.values.filter(\.isFormula).count
        let errors = s.cells.filter { $0.value.isFormula && $0.value.value.isError }.map { "\($0.key.a1)=\($0.value.input)→\($0.value.value.plain)" }
        print("[\(s.name)] cells \(s.cells.count) formulas \(formulas) merges \(s.merges.count) frozen \(s.frozenRows)x\(s.frozenCols) widths \(s.columnWidths.count) comments \(s.comments.count) printArea \(s.printArea?.a1 ?? "-") bold \(s.cells.values.filter(\.style.bold).count) fills \(s.cells.values.filter { $0.style.fill != nil }.count) errors \(errors.prefix(5))")
        for v in s.validations { print("  validation \(v.ranges.map(\.a1).joined(separator: " ")): \(v.kind.rawValue) \(v.op) \(v.formula1) \(v.formula2) style \(v.errorStyle) \"\(v.errorMessage)\"") }
        if !s.rowLevels.isEmpty || !s.colLevels.isEmpty {
            print("  outline rows \(s.rowLevels.sorted { $0.key < $1.key }.map { "\($0.key + 1):\($0.value)" }) hidden \(s.outlineHiddenRows.sorted().map { $0 + 1 })"
                  + " cols \(s.colLevels.sorted { $0.key < $1.key }.map { "\(CellRef.columnName($0.key)):\($0.value)" }) hidden \(s.outlineHiddenCols.sorted().map(CellRef.columnName))")
        }
        if let p = s.protection {
            print("  protected hash \(p.passwordHash ?? "-") sha512 \(p.sha512Hash != nil) ods \(p.odsKey != nil); unlocked \(s.cells.filter { !$0.value.style.locked }.keys.sorted().map(\.a1))")
        }
    }
    print("names", wb.names)
    exit(0)
}

// XLS42 --convert in.(xlsx|xls|ods|csv) out.(xlsx|ods|csv)
if let i = CommandLine.arguments.firstIndex(of: "--convert"), CommandLine.arguments.count > i + 2 {
    let args = CommandLine.arguments
    var wb = Calculator.recalculate(try SpreadsheetFile.read(Data(contentsOf: URL(fileURLWithPath: args[i + 1]))))
    if args.contains("freeze") { wb.sheets[0].frozenRows = 3; wb.sheets[0].frozenCols = 1 }
    let out = URL(fileURLWithPath: args[i + 2])
    let data: Data
    switch out.pathExtension.lowercased() {
    case "ods": data = ODS.write(wb)
    case "csv": data = SheetExport.csv(wb.sheets[0], delimiter: ",", bom: true)
    default: data = XLSX.write(wb)
    }
    try data.write(to: out)
    print("\(out.pathExtension): \(data.count) bytes")
    exit(0)
}

// XLS42 --export-pdf in.xlsx out.pdf [all|landscape|nogrid|nofit]
if let i = CommandLine.arguments.firstIndex(of: "--export-pdf"), CommandLine.arguments.count > i + 2 {
    let args = CommandLine.arguments
    let wb = Calculator.recalculate(try SpreadsheetFile.read(Data(contentsOf: URL(fileURLWithPath: args[i + 1]))))
    var options = SheetExport.Options()
    if args.contains("all") { options.scope = .workbook }
    if args.contains("landscape") { options.orientation = .landscape }
    if args.contains("nogrid") { options.gridlines = false }
    if args.contains("nofit") { options.fitWidth = false }
    let data = SheetExport.pdf(wb, activeSheet: 0, selection: nil, options: options, base: NSPrintInfo.shared)
    try data.write(to: URL(fileURLWithPath: args[i + 2]))
    print("pdf \(data.count) bytes")
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
