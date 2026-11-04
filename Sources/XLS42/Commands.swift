import AppKit
import Kit42

enum Cmd {
    typealias W = SheetWindowController
    typealias A = AppDelegate

    // File
    static let exportPDF = Command(L("Export as PDF…"), #selector(W.exportPDFAction(_:)), symbol: "doc.richtext",
                                   shortcut: Shortcut("e", [.command, .option]), toolTip: L("Export as PDF"), label: L("PDF"))
    static let exportCSV = Command(L("Export Sheet as CSV…"), #selector(W.exportCSVAction(_:)))
    static let importCSV = Command(L("Import CSV as Sheet…"), #selector(W.importCSVAction(_:)))

    // Data & objects
    static let replace = Command(L("Find and Replace…"), #selector(W.findReplaceAction(_:)), symbol: "arrow.left.arrow.right",
                                 shortcut: Shortcut("f", [.command, .option]))
    static let hideRows = Command(L("Hide Rows"), #selector(W.hideRowsAction(_:)), symbol: "eye.slash", shortcut: Shortcut("9", [.command, .control]))
    static let unhideRows = Command(L("Unhide Rows"), #selector(W.unhideRowsAction(_:)), symbol: "eye", shortcut: Shortcut("9", [.command, .control, .shift]))
    static let hideColumns = Command(L("Hide Columns"), #selector(W.hideColumnsAction(_:)), shortcut: Shortcut("0", [.command, .control]))
    static let unhideColumns = Command(L("Unhide Columns"), #selector(W.unhideColumnsAction(_:)), shortcut: Shortcut("0", [.command, .control, .shift]))
    static let filter = Command(L("Filter"), #selector(W.toggleFilterAction(_:)), symbol: "line.3.horizontal.decrease.circle",
                                shortcut: Shortcut("l", [.command, .shift]), toolTip: L("Filter rows by values"))
    static let setPrintArea = Command(L("Set Print Area"), #selector(W.setPrintAreaAction(_:)), symbol: "printer")
    static let clearPrintArea = Command(L("Clear Print Area"), #selector(W.clearPrintAreaAction(_:)))
    static let defineName = Command(L("Define Name…"), #selector(W.defineNameAction(_:)), symbol: "tag", shortcut: Shortcut("n", [.command, .control]))
    static let comment = Command(L("Comment…"), #selector(W.editCommentAction(_:)), symbol: "text.bubble", shortcut: Shortcut("m", [.command, .option]))
    static let deleteComment = Command(L("Delete Comment"), #selector(W.deleteCommentAction(_:)))
    static let conditionalRules: [Command] = [L("Greater Than…"), L("Less Than…"), L("Between…"), L("Equal To…"), L("Text Contains…"), L("Duplicate Values")]
        .enumerated().map { Command($0.element, #selector(W.conditionalRuleAction(_:)), tag: $0.offset) }
    static let colorScale = Command(L("Colour Scale"), #selector(W.colorScaleAction(_:)), symbol: "paintpalette")
    static let dataBars = Command(L("Data Bars"), #selector(W.dataBarAction(_:)), symbol: "chart.bar.fill")
    static let clearRules = Command(L("Clear Rules from Selection"), #selector(W.clearRulesAction(_:)))
    static let insertPicture = Command(L("Picture…"), #selector(W.insertImageAction(_:)), symbol: "photo", shortcut: Shortcut("i", [.command, .shift]))
    static let stamps = Command(L("Signature or Stamp…"), #selector(W.showStampsAction(_:)), symbol: "signature", shortcut: Shortcut("k", [.command, .shift]))
    static let charts: [Command] = [(L("Column Chart"), "chart.bar"), (L("Bar Chart"), "chart.bar.xaxis"), (L("Line Chart"), "chart.xyaxis.line"),
                                    (L("Area Chart"), "chart.line.uptrend.xyaxis"), (L("Pie Chart"), "chart.pie"), (L("Scatter Chart"), "chart.dots.scatter")]
        .enumerated().map { Command($0.element.0, #selector(W.insertChartAction(_:)), symbol: $0.element.1, tag: $0.offset) }
    static let print = Command(L("Print…"), #selector(NSDocument.printDocument(_:)), symbol: "printer", toolTip: L("Print"), label: L("Print"))

    // Edit (context menu)
    static let cut = Command(L("Cut"), #selector(NSText.cut(_:)), symbol: "scissors")
    static let copy = Command(L("Copy"), #selector(NSText.copy(_:)), symbol: "doc.on.doc")
    static let paste = Command(L("Paste"), #selector(NSText.paste(_:)), symbol: "doc.on.clipboard")

    static var contextMenu: NSMenu {
        MenuBar.menu("", [.command(cut), .command(copy), .command(paste), .separator,
                          .command(insertRows), .command(insertColumns), .command(deleteRows), .command(deleteColumns), .separator,
                          .command(clear), .command(clearFormats), .separator,
                          .command(sortAscending), .command(sortDescending), .separator,
                          .command(merge), .command(freeze), .separator,
                          .command(comment), .command(hideRows), .command(unhideRows), .command(defineName)])
    }

    // Edit
    static let clear = Command(L("Clear Contents"), #selector(W.clearContents(_:)), symbol: "delete.left")
    static let clearFormats = Command(L("Clear Formats"), #selector(W.clearFormats(_:)))
    static let fillDown = Command(L("Fill Down"), #selector(W.fillDown(_:)), shortcut: Shortcut("d"))
    static let fillRight = Command(L("Fill Right"), #selector(W.fillRight(_:)), shortcut: Shortcut("r"))
    static let find = Command(L("Find…"), #selector(W.focusSearchAction(_:)), shortcut: Shortcut("f"))
    static let findNext = Command(L("Find Next"), #selector(W.findNextAction(_:)), shortcut: Shortcut("g"))
    static let goToCell = Command(L("Go to Cell…"), #selector(W.goToCellAction(_:)), shortcut: Shortcut("g", [.command, .option]))

    // View
    static let zoomIn = Command(L("Zoom In"), #selector(W.zoomInAction(_:)), symbol: "plus.magnifyingglass", shortcut: Shortcut("+"))
    static let zoomOut = Command(L("Zoom Out"), #selector(W.zoomOutAction(_:)), symbol: "minus.magnifyingglass", shortcut: Shortcut("-"))
    static let actualSize = Command(L("Actual Size"), #selector(W.actualSizeAction(_:)), shortcut: Shortcut("0"))
    static let formatBar = Command(L("Hide Format Bar"), #selector(W.toggleFormatBarAction(_:)), symbol: "textformat",
                                   shortcut: Shortcut("a", [.command, .shift]), toolTip: L("Format bar"), label: L("Format"))
    static let gridlines = Command(L("Gridlines"), #selector(W.toggleGridlines(_:)))
    static let freeze = Command(L("Freeze Panes"), #selector(W.freezeAction(_:)), symbol: "rectangle.split.2x2",
                                toolTip: L("Freeze rows above and columns left of the selected cell"), label: L("Freeze"))
    static let freezeTopRow = Command(L("Freeze Top Row"), #selector(W.freezeTopRowAction(_:)))
    static let freezeFirstColumn = Command(L("Freeze First Column"), #selector(W.freezeFirstColumnAction(_:)))

    // Insert
    static let insertRows = Command(L("Rows Above"), #selector(W.insertRowsAction(_:)), symbol: "plus.rectangle.portrait",
                                    shortcut: Shortcut("+", [.command, .shift]))
    static let insertColumns = Command(L("Columns Left"), #selector(W.insertColumnsAction(_:)), symbol: "plus.rectangle",
                                       shortcut: Shortcut("+", [.command, .option]))
    static let insertSheet = Command(L("Sheet"), #selector(W.addSheet(_:)), shortcut: Shortcut("n", [.command, .shift]))
    static let autoSum = Command(L("AutoSum"), #selector(W.autoSumAction(_:)), symbol: "sum", shortcut: Shortcut("t", [.command, .shift]),
                                 toolTip: L("AutoSum"), label: L("Sum"))

    // Format
    static let bold = Command(L("Bold"), #selector(W.toggleBold(_:)), symbol: "bold", shortcut: Shortcut("b"))
    static let italic = Command(L("Italic"), #selector(W.toggleItalic(_:)), symbol: "italic", shortcut: Shortcut("i"))
    static let underline = Command(L("Underline"), #selector(W.toggleUnderline(_:)), symbol: "underline", shortcut: Shortcut("u"))
    static let strike = Command(L("Strikethrough"), #selector(W.toggleStrike(_:)), symbol: "strikethrough", shortcut: Shortcut("x", [.command, .shift]))
    static let alignLeft = Command(L("Align Left"), #selector(W.alignAction(_:)), symbol: "text.alignleft", shortcut: Shortcut("{"), tag: 0)
    static let alignCenter = Command(L("Align Center"), #selector(W.alignAction(_:)), symbol: "text.aligncenter", shortcut: Shortcut("|"), tag: 1)
    static let alignRight = Command(L("Align Right"), #selector(W.alignAction(_:)), symbol: "text.alignright", shortcut: Shortcut("}"), tag: 2)
    static let wrap = Command(L("Wrap Text"), #selector(W.toggleWrap(_:)), symbol: "text.word.spacing")
    static let merge = Command(L("Merge Cells"), #selector(W.mergeAction(_:)), symbol: "rectangle.compress.vertical")
    static let increaseDecimals = Command(L("Increase Decimals"), #selector(W.increaseDecimals(_:)), symbol: "increase.indent")
    static let decreaseDecimals = Command(L("Decrease Decimals"), #selector(W.decreaseDecimals(_:)), symbol: "decrease.indent")
    static let bordersAll = Command(L("All Borders"), #selector(W.bordersAction(_:)), symbol: "squareshape.split.3x3", tag: 0)
    static let bordersOutside = Command(L("Outside Borders"), #selector(W.bordersAction(_:)), symbol: "square", tag: 1)
    static let bordersBottom = Command(L("Bottom Border"), #selector(W.bordersAction(_:)), symbol: "square.bottomhalf.filled", tag: 2)
    static let bordersNone = Command(L("No Borders"), #selector(W.bordersAction(_:)), symbol: "square.dashed", tag: 3)
    static let noFill = Command(L("No Fill"), #selector(W.noFillAction(_:)))
    static var numberFormats: [Command] {
        W.numberFormats.enumerated().map { Command($0.element.title, #selector(W.numberFormatAction(_:)), tag: $0.offset) }
    }

    // Table
    static let sortAscending = Command(L("Sort Ascending"), #selector(W.sortAscending(_:)), symbol: "arrow.up.arrow.down", toolTip: L("Sort A→Z"))
    static let sortDescending = Command(L("Sort Descending"), #selector(W.sortDescending(_:)), symbol: "arrow.down")
    static let deleteRows = Command(L("Delete Rows"), #selector(W.deleteRowsAction(_:)), symbol: "minus.rectangle",
                                    shortcut: Shortcut("-", [.command, .shift]))
    static let deleteColumns = Command(L("Delete Columns"), #selector(W.deleteColumnsAction(_:)), symbol: "minus.rectangle.portrait",
                                       shortcut: Shortcut("-", [.command, .option]))

    static let welcome = Command(L("Welcome Window"), #selector(A.showWelcomeAction(_:)), shortcut: Shortcut("0", [.command, .shift]))
    static let functions = Command(L("Supported Functions"), #selector(A.showFunctionsAction(_:)))

    static var menuBar: MenuBarSpec {
        var spec = MenuBarSpec(appName: "XLS42")
        spec.fileExtras = [.command(exportPDF), .command(exportCSV), .separator, .command(importCSV), .separator,
                           .command(setPrintArea), .command(clearPrintArea)]
        spec.editExtras = [.command(clear), .command(clearFormats), .separator, .command(fillDown), .command(fillRight)]
        spec.find = [.command(find), .command(findNext), .command(replace), .command(goToCell)]
        spec.view = [.command(zoomIn), .command(zoomOut), .command(actualSize), .separator,
                     .command(formatBar), .command(gridlines), .separator,
                     .command(freeze), .command(freezeTopRow), .command(freezeFirstColumn)]
        spec.insert = [.command(insertRows), .command(insertColumns), .command(insertSheet), .separator, .command(autoSum),
                       .command(defineName), .separator, .command(insertPicture), .command(stamps), .submenu(L("Chart"), charts.menuElements),
                       .separator, .command(comment), .command(deleteComment)]
        spec.format = [.command(bold), .command(italic), .command(underline), .command(strike), .separator,
                       .command(alignLeft), .command(alignCenter), .command(alignRight), .command(wrap), .command(merge), .separator,
                       .submenu(L("Number"), numberFormats.menuElements + [.separator, .command(increaseDecimals), .command(decreaseDecimals)]),
                       .submenu(L("Borders"), [.command(bordersAll), .command(bordersOutside), .command(bordersBottom), .command(bordersNone)]),
                       .command(noFill), .separator,
                       .submenu(L("Conditional Formatting"), conditionalRules.menuElements + [.separator, .command(colorScale), .command(dataBars),
                                                                                              .separator, .command(clearRules)]),
                       .separator, .command(clearFormats)]
        spec.custom = [(L("Table"), [.command(sortAscending), .command(sortDescending), .command(filter), .separator,
                                     .command(hideRows), .command(unhideRows), .command(hideColumns), .command(unhideColumns), .separator,
                                     .command(deleteRows), .command(deleteColumns), .separator,
                                     .command(freeze), .command(freezeTopRow), .command(freezeFirstColumn)])]
        spec.help = [.command(functions), .command(welcome)]
        return spec
    }

    static var toolbar: [ToolbarElement] {
        [
            .command(autoSum), .command(sortAscending), .command(filter), .command(freeze),
            .flexibleSpace,
            .group(id: "zoom", label: L("Zoom"), [zoomOut, zoomIn]),
            .command(formatBar), .command(print), .command(exportPDF),
            .search(id: "search", placeholder: L("Search"), action: #selector(W.searchChanged(_:))),
        ]
    }
}
