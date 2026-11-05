import AppKit
import Kit42
import PDFKit

extension UITest {
    /// Exercise the actual modal controls, document lifecycle and paginated output.
    static func deepCommon(_ w: SheetWindowController, _ doc: SheetDocument) -> Int {
        var checks = 0, failures = 0
        let suppress = w.suppressAlerts
        w.suppressAlerts = true
        defer { w.grid.cancelEdit(); w.suppressAlerts = suppress }
        func check(_ name: String, _ value: Bool) {
            checks += 1; if !value { failures += 1 }
            print(value ? "ok  " : "FAIL", "deep common:", name)
        }
        func ref(_ a: String) -> CellRef { CellRef(a)! }
        func cell(_ a: String) -> Cell { w.sheet[ref(a)] }
        func select(_ a: String, _ b: String? = nil) {
            w.grid.select(ref(a)); if let b { w.grid.select(ref(b), extend: true) }
        }
        func clean() {
            w.grid.cancelEdit(); doc.workbook = Workbook(); doc.workbook.sheets = [Sheet(name: "Common")]
            w.sheetIndex = 0; w.workbookDidChange(); w.restoreSplit(); select("A1")
            doc.undoManager?.removeAllActions(); doc.updateChangeCount(.changeCleared)
            w.lastAlertMessage = nil
        }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func format(tab: String, _ act: @escaping (NSView) -> Bool) {
            var operated = false
            let timer = Timer(timeInterval: 0.08, repeats: false) { _ in
                guard let window = NSApp.modalWindow, let content = window.contentView,
                      let tabs = descendants(content).compactMap({ $0 as? NSTabView }).first,
                      let item = tabs.tabViewItems.first(where: { $0.label == L(tab) }), let view = item.view else {
                    NSApp.abortModal(); return
                }
                tabs.selectTabViewItem(item)
                operated = act(view)
                if let ok = descendants(content).compactMap({ $0 as? NSButton }).first(where: { $0.title == L("OK") }) { ok.performClick(nil) }
                else { NSApp.abortModal() }
            }
            RunLoop.main.add(timer, forMode: .modalPanel)
            w.formatCellsAction(nil)
            timer.invalidate()
            check("native Format Cells controls: " + tab, operated)
        }
        func preset(_ title: String, line: String? = nil) {
            format(tab: "Borders") { view in
                let views = descendants(view)
                if let line, let popup = views.compactMap({ $0 as? NSPopUpButton }).first { popup.selectItem(withTitle: L(line)) }
                guard let button = views.compactMap({ $0 as? NSButton }).first(where: { $0.title == L(title) }) else { return false }
                button.performClick(nil); return true
            }
        }
        func noBorder(_ c: Cell) -> Bool { c.style.left == nil && c.style.right == nil && c.style.top == nil && c.style.bottom == nil }
        func allBorders(_ c: Cell, _ style: String = "thin") -> Bool {
            [c.style.left, c.style.right, c.style.top, c.style.bottom].allSatisfy { $0?.style == style }
        }
        func renderedBorderRuns(_ kind: String, horizontal: Bool) -> Int {
            var sheet = Sheet(name: "Borders")
            sheet.columnWidths = [0: 40, 1: 40]; sheet.rowHeights = [0: 20, 1: 20]
            var cell = Cell()
            if horizontal { cell.style.top = BorderSide(style: kind, color: .black) }
            else { cell.style.left = BorderSide(style: kind, color: .black) }
            sheet[ref("B2")] = cell
            let grid = GridView(frame: NSRect(x: 0, y: 0, width: 400, height: 240))
            grid.sheetOverride = sheet; grid.printMode = true; grid.printGridlines = false; grid.zoom = 4
            grid.rebuildLayout()
            guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 400, pixelsHigh: 240, bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return -1 }
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
            grid.drawContent(NSRect(x: 0, y: 0, width: 400, height: 240))
            NSGraphicsContext.restoreGraphicsState()
            let profile = (0..<(horizontal ? 240 : 400)).map { position in
                (0..<(horizontal ? 400 : 240)).contains { other in
                    guard let c = bitmap.colorAt(x: horizontal ? other : position, y: horizontal ? position : other)?.usingColorSpace(.deviceRGB) else { return false }
                    return c.redComponent < 0.2 && c.greenComponent < 0.2 && c.blueComponent < 0.2
                }
            }
            var runs = 0, previous = false
            for dark in profile { if dark && !previous { runs += 1 }; previous = dark }
            return runs
        }
        check("vertical Double border renders two separate strokes", renderedBorderRuns("double", horizontal: false) == 2)
        check("horizontal Double border renders two separate strokes", renderedBorderRuns("double", horizontal: true) == 2)
        check("Thick border renders one solid stroke", renderedBorderRuns("thick", horizontal: false) == 1)
        check("Thin border renders one solid stroke", renderedBorderRuns("thin", horizontal: true) == 1)
        clean()
        doc.change("Mixed borders", recalc: false) { wb in
            var a = Cell(); a.style.left = BorderSide(style: "mediumDashed", color: .red)
            a.style.bottom = BorderSide(style: "mediumDashed", color: .red)
            wb.sheets[0][ref("A1")] = a
        }
        select("A1", "B2")
        let mixed = w.sheet.cells
        format(tab: "Borders") { view in
            let buttons = descendants(view).compactMap { $0 as? NSButton }
            return buttons.first(where: { $0.title == L("Left") })?.state == .mixed && buttons.first(where: { $0.title == L("Inner horizontal") })?.state == .mixed
        }
        check("accepting mixed borders preserves every original edge and imported style", w.sheet.cells == mixed)
        preset("All", line: "Double")
        check("All adds double borders to every selected cell", CellRange("A1:B2")!.cells.allSatisfy { allBorders(w.sheet[$0], "double") })
        let all = w.sheet.cells
        doc.undoManager?.undo(); check("one Undo restores original mixed borders", w.sheet.cells == mixed)
        doc.undoManager?.redo(); check("Redo restores every double border", w.sheet.cells == all)
        preset("None")
        check("None removes inner and outer borders", CellRange("A1:B2")!.cells.allSatisfy { noBorder(w.sheet[$0]) })
        doc.undoManager?.undo(); check("Undo border removal restores all borders", w.sheet.cells == all)
        preset("Outline", line: "Thick")
        check("Outline clears inner edges and sets only the outer thick border", cell("A1").style.left?.style == "thick" && cell("A1").style.top?.style == "thick" && cell("A1").style.right == nil && cell("A1").style.bottom == nil && cell("B2").style.right?.style == "thick" && cell("B2").style.bottom?.style == "thick" && cell("B2").style.left == nil && cell("B2").style.top == nil)
        format(tab: "Borders") { view in
            guard let color = descendants(view).compactMap({ $0 as? NSColorWell }).first else { return false }
            color.color = .blue
            return true
        }
        check("border colour restyles existing edges without inventing inner lines", cell("A1").style.top?.color.usingColorSpace(.sRGB)?.blueComponent == 1 && cell("A1").style.right == nil)
        for (name, data) in [("XLSX", XLSX.write(doc.workbook)), ("ODS", ODS.write(doc.workbook))] {
            do {
                let restored = try SpreadsheetFile.read(data)
                let a = restored.sheets[0][ref("A1")].style, b = restored.sheets[0][ref("B2")].style
                check(name + " keeps border thickness, colour, outer edges and absent inner edges", a.top?.style == "thick" && a.top?.color.usingColorSpace(.sRGB)?.blueComponent == 1 && a.right == nil && b.bottom?.style == "thick" && b.left == nil)
            } catch { check(name + " border roundtrip", false) }
        }
        format(tab: "Background") { view in
            guard let well = descendants(view).compactMap({ $0 as? NSColorWell }).first else { return false }
            well.color = .yellow; _ = well.sendAction(well.action, to: well.target)
            return descendants(view).compactMap({ $0 as? NSButton }).first(where: { $0.title == L("No fill") })?.state == .off
        }
        check("choosing background colour applies it to the whole selection", CellRange("A1:B2")!.cells.allSatisfy { w.sheet[$0].style.fill?.usingColorSpace(.sRGB)?.redComponent == 1 })
        format(tab: "Font") { view in
            let views = descendants(view)
            guard let well = views.compactMap({ $0 as? NSColorWell }).first,
                  let bold = views.compactMap({ $0 as? NSButton }).first(where: { $0.title == L("Bold") }) else { return false }
            well.color = .red; _ = well.sendAction(well.action, to: well.target); bold.performClick(nil)
            return views.compactMap({ $0 as? NSButton }).first(where: { $0.title == L("Automatic colour") })?.state == .off
        }
        check("font colour and Bold apply across selected cells", CellRange("A1:B2")!.cells.allSatisfy { w.sheet[$0].style.bold && w.sheet[$0].style.textColor?.usingColorSpace(.sRGB)?.redComponent == 1 })
        format(tab: "Alignment") { view in
            guard let wrap = descendants(view).compactMap({ $0 as? NSButton }).first(where: { $0.title == L("Wrap text automatically") }) else { return false }
            wrap.performClick(nil); return true
        }
        check("Wrap applies to all selected cells", CellRange("A1:B2")!.cells.allSatisfy { w.sheet[$0].style.wrap })
        clean(); w.setInput("long long long long long long long long long long", at: ref("A1"))
        doc.change("Narrow wrapped row", recalc: false) { wb in
            wb.sheets[0].columnWidths[0] = 60; wb.sheets[0].cells[ref("A1")]?.style.wrap = true
        }
        doc.undoManager?.removeAllActions(); doc.updateChangeCount(.changeCleared)
        let originalHeight = w.sheet.height(0)
        w.autofit(.row(0)); let fittedHeight = w.sheet.height(0)
        check("row Autofit expands wrapped content and marks the document edited", fittedHeight > originalHeight && doc.isDocumentEdited)
        doc.undoManager?.undo(); check("row Autofit Undo restores height", w.sheet.height(0) == originalHeight)
        doc.undoManager?.redo(); check("row Autofit Redo restores height", w.sheet.height(0) == fittedHeight)
        w.setInput("x", at: ref("A1")); w.autofit(.row(0))
        check("row Autofit shrinks a formerly tall row", w.sheet.height(0) < fittedHeight)

        clean()
        if let content = w.window?.contentView {
            for columns in [true, false] {
                select("A1")
                guard let header = descendants(content).compactMap({ $0 as? HeaderView }).first(where: { $0.isColumns == columns }) else { check("resize header exists", false); continue }
                func drag(_ delta: CGFloat) {
                    let edge = columns ? w.grid.x(1) : w.grid.y(1)
                    let p = columns ? NSPoint(x: edge, y: header.bounds.midY) : NSPoint(x: header.bounds.midX, y: edge)
                    let q = columns ? NSPoint(x: p.x + delta, y: p.y) : NSPoint(x: p.x, y: p.y + delta)
                    for (type, point) in [(NSEvent.EventType.leftMouseDown, p), (.leftMouseDragged, q), (.leftMouseUp, q)] {
                        guard let event = NSEvent.mouseEvent(with: type, location: header.convert(point, to: nil), modifierFlags: [], timestamp: 0, windowNumber: w.window!.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { continue }
                        if type == .leftMouseDown { header.mouseDown(with: event) }
                        else if type == .leftMouseDragged { header.mouseDragged(with: event) }
                        else { header.mouseUp(with: event) }
                    }
                }
                let before = columns ? w.sheet.width(0) : w.sheet.height(0)
                drag(30 * w.grid.scale)
                let after = columns ? w.sheet.width(0) : w.sheet.height(0)
                check(columns ? "column boundary drag changes width" : "row boundary drag changes height", abs(after - before - 30) < 0.1)
                doc.undoManager?.undo(); check("boundary drag is one Undo", (columns ? w.sheet.width(0) : w.sheet.height(0)) == before)
                doc.undoManager?.redo(); check("boundary drag Redo restores size", (columns ? w.sheet.width(0) : w.sheet.height(0)) == after)
                doc.workbook.sheets[0].protection = SheetProtection()
                drag(20)
                check("protected sheet refuses boundary resizing", (columns ? w.sheet.width(0) : w.sheet.height(0)) == after)
                doc.workbook.sheets[0].protection = nil
            }
        } else { check("resize window exists", false) }
        clean(); w.grid.beginEdit(initial: "unsaved draft")
        check("an uncommitted cell edit marks the document edited", doc.isDocumentEdited)
        do {
            let saved = try doc.data(ofType: "org.openxmlformats.spreadsheetml.sheet")
            let reopened = try SpreadsheetFile.read(saved)
            check("Save commits the visible draft before serializing", reopened.sheets[0][ref("A1")].value == .string("unsaved draft") && !w.grid.isEditing)
        } catch { check("Save commits pending edit", false) }
        clean(); var validation = DataValidation(ranges: [CellRange("A1")!], kind: .whole)
        validation.formula1 = "1"; validation.formula2 = "10"
        w.setValidation(validation, for: CellRange("A1")!)
        w.grid.beginEdit(initial: "99")
        do { _ = try doc.data(ofType: "org.openxmlformats.spreadsheetml.sheet"); check("Save rejects invalid pending input", false) }
        catch { check("Save rejects invalid pending input without losing it", w.grid.pendingEdit?.text == "99" && cell("A1").input.isEmpty) }
        do { _ = try doc.printOperation(withSettings: [:]); check("Print rejects invalid pending input", false) }
        catch { check("Print rejects invalid pending input without losing it", w.grid.pendingEdit?.text == "99") }
        w.addSheet(nil); check("New Sheet cannot abandon an invalid draft", doc.workbook.sheets.count == 1 && w.grid.isEditing)
        do { try doc.read(from: Data([0, 1, 2]), ofType: "org.openxmlformats.spreadsheetml.sheet"); check("invalid Revert rejects file", false) }
        catch { check("failed Revert preserves current workbook and draft", w.grid.pendingEdit?.text == "99" && w.sheet.validations.count == 1) }
        w.grid.cancelEdit(); w.addSheet(nil); w.grid.beginEdit(initial: "discard on revert")
        var replacement = Workbook(); replacement.sheets = [Sheet(name: "Restored")]; replacement.sheets[0][ref("A1")] = Cell(input: "saved", value: .string("saved"))
        do {
            try doc.read(from: XLSX.write(replacement), ofType: "org.openxmlformats.spreadsheetml.sheet")
            check("successful Revert resets obsolete sheet selection and discards its draft", w.sheetIndex == 0 && w.sheet.name == "Restored" && !w.grid.isEditing && cell("A1").input == "saved" && w.grid.active == ref("A1"))
        } catch { check("Revert lifecycle", false) }
        replacement.sheets.append(Sheet(name: "Hidden")); replacement.sheets[1].hidden = true
        w.addSheet(nil)
        do {
            try doc.read(from: XLSX.write(replacement), ofType: "org.openxmlformats.spreadsheetml.sheet")
            check("Revert never leaves a hidden sheet active", w.sheetIndex == 0 && !w.sheet.hidden)
        } catch { check("Revert to visible sheet", false) }
        clean(); doc.workbook.date1904 = true; w.setInput("1904-01-02", at: ref("A1"))
        check("typing a date respects workbook epoch and display", cell("A1").value == .number(1) && NumberFormat.format(cell("A1").value, "yyyy-mm-dd", date1904: true).text == "1904-01-02")
        let csv = String(data: try! SheetExport.csv(w.sheet, delimiter: ",", bom: false, date1904: true), encoding: .utf8) ?? ""
        check("CSV exports the displayed 1904 date", csv.contains("02.01.1904"))

        clean()
        doc.workbook.sheets[0][ref("A1")] = Cell(input: "10", value: .number(10))
        doc.workbook.sheets[0][ref("A2")] = Cell(input: "20", value: .number(20))
        doc.workbook.sheets[0].conditionalFormats = [ConditionalFormat(range: CellRange("A1:XFD1048576")!, kind: .dataBar(.blue))]
        let engine = ConditionalEngine(sheet: w.sheet, workbook: doc.workbook, sheetIndex: 0)
        check("conditional formatting on an entire sparse sheet stays bounded and correct", engine.bar(at: ref("A1"))?.0 == 0.5 && engine.bar(at: ref("A2"))?.0 == 1)

        var sparse = Sheet(name: "Sparse")
        sparse[ref("XFD1048576")] = Cell(input: "last", value: .string("last"))
        do { _ = try SheetExport.csv(sparse, delimiter: ",", bom: false); check("huge sparse CSV rejects dense materialization", false) }
        catch { check("huge sparse CSV rejects dense materialization explicitly", (error as NSError).domain == "XLS42") }

        // Inspect real PDF pages/text; a panel toggle alone does not prove printable output.
        var printed = Workbook(); printed.sheets = [Sheet(name: "Visible"), Sheet(name: "Hidden")]
        printed.sheets[0][ref("A1")] = Cell(input: "VISIBLE-TOKEN", value: .string("VISIBLE-TOKEN"))
        printed.sheets[1][ref("A1")] = Cell(input: "HIDDEN-TOKEN", value: .string("HIDDEN-TOKEN")); printed.sheets[1].hidden = true
        let options = SheetExport.Options(); options.scope = .workbook; options.pageNumbers = false
        var pdf = PDFDocument(data: SheetExport.pdf(printed, activeSheet: 0, selection: nil, options: options, base: doc.printInfo))
        check("All Sheets PDF prints visible sheets and omits hidden sheets", pdf?.pageCount == 1 && pdf?.string?.contains("VISIBLE-TOKEN") == true && pdf?.string?.contains("HIDDEN-TOKEN") == false)
        options.scope = .selection
        printed.sheets[0][ref("B1")] = Cell(input: "SELECTED-TOKEN", value: .string("SELECTED-TOKEN"))
        pdf = PDFDocument(data: SheetExport.pdf(printed, activeSheet: 0, selection: CellRange("B1")!, options: options, base: doc.printInfo))
        check("Selection PDF includes only selected cells", pdf?.string?.contains("SELECTED-TOKEN") == true && pdf?.string?.contains("VISIBLE-TOKEN") == false)
        options.scope = .sheet; options.orientation = .portrait
        printed.sheets[0] = Sheet(name: "Wide"); printed.sheets[0][CellRef(row: 0, col: 199)] = Cell(input: "LAST", value: .string("LAST"))
        pdf = PDFDocument(data: SheetExport.pdf(printed, activeSheet: 0, selection: nil, options: options, base: doc.printInfo))
        check("Fit width fits 200 columns onto one page", pdf?.pageCount == 1 && pdf?.string?.contains("LAST") == true)
        printed.sheets[0] = Sheet(name: "Long")
        for r in 0..<100 { printed.sheets[0][CellRef(row: r, col: 0)] = Cell(input: "ROW-\(r)", value: .string("ROW-\(r)")) }
        printed.sheets[0].frozenRows = 80
        pdf = PDFDocument(data: SheetExport.pdf(printed, activeSheet: 0, selection: nil, options: options, base: doc.printInfo))
        let pdfText = pdf?.string ?? ""
        check("oversized frozen titles cannot hide the printed body", pdfText.contains("ROW-0") && pdfText.contains("ROW-79") && pdfText.contains("ROW-99"))
        clean()
        print("XLS deep common regressions: \(checks - failures)/\(checks) passed")
        return failures
    }
}
