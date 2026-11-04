import AppKit
import Kit42

@objc(SheetDocument)
final class SheetDocument: NSDocument {
    var workbook = Workbook()

    override init() {
        super.init()
        workbook.sheets = [Sheet(name: L("Sheet%d", 1))]
    }

    override class var autosavesInPlace: Bool { false }

    var editor: SheetWindowController? { windowControllers.first as? SheetWindowController }

    override func makeWindowControllers() {
        addWindowController(SheetWindowController())
    }

    static func isCSV(_ typeName: String) -> Bool {
        let t = typeName.lowercased()
        return t.contains("separated-values") || t.contains("csv") || t.contains("tsv")
    }

    override func read(from data: Data, ofType typeName: String) throws {
        workbook = Self.isCSV(typeName) ? XLSX.readCSV(data) : try XLSX.read(data)
        workbook = Calculator.recalculate(workbook)
    }

    override func data(ofType typeName: String) throws -> Data {
        editor?.grid.commitEdit(move: nil)
        if Self.isCSV(typeName) {
            return XLSX.writeCSV(workbook.sheets[editor?.sheetIndex ?? 0])
        }
        return XLSX.write(workbook)
    }

    /// Applies an undoable change to the workbook, recalculates and refreshes the window.
    func change(_ name: String, _ body: (inout Workbook) -> Void) {
        let old = workbook
        body(&workbook)
        workbook = Calculator.recalculate(workbook)
        undoManager?.beginUndoGrouping()
        undoManager?.registerUndo(withTarget: self) { $0.restore(old, name: name) }
        undoManager?.setActionName(name)
        undoManager?.endUndoGrouping()
        editor?.workbookDidChange()
    }

    private func restore(_ wb: Workbook, name: String) {
        let current = workbook
        workbook = wb
        undoManager?.registerUndo(withTarget: self) { $0.restore(current, name: name) }
        undoManager?.setActionName(name)
        editor?.workbookDidChange()
    }

    /// Non-undoable live update (column resize preview).
    func preview(_ body: (inout Workbook) -> Void) {
        body(&workbook)
        editor?.grid.rebuildLayout()
    }

    override func printOperation(withSettings printSettings: [NSPrintInfo.AttributeKey: Any]) throws -> NSPrintOperation {
        editor?.grid.commitEdit(move: nil)
        let info = SheetExport.printInfo(from: printInfo)
        let index = editor?.sheetIndex ?? 0
        let view = SheetExport.printView(workbook.sheets[index], range: nil, options: .saved, info: info)
        let op = NSPrintOperation(view: view, printInfo: info)
        op.jobTitle = displayName
        return op
    }
}
