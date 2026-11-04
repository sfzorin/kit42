import AppKit
import Kit42

final class AppDelegate: NSObject, NSApplicationDelegate {
    private lazy var welcome = WelcomeWindowController(
        app: .xls, tagline: L("Spreadsheets with formulas"),
        actions: [
            .init(L("Open Spreadsheet…"), symbol: "folder", action: #selector(NSDocumentController.openDocument(_:))),
            .init(L("New Spreadsheet"), symbol: "tablecells.badge.ellipsis", action: #selector(NSDocumentController.newDocument(_:))),
        ])

    func applicationWillFinishLaunching(_ notification: Notification) {
        _ = NSDocumentController.shared
        NSApp.mainMenu = MenuBar.build(Cmd.menuBar)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--uitest") {
            DispatchQueue.main.async { UITest.run() }
            return
        }
        NSApp.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [self] in
            if NSDocumentController.shared.documents.isEmpty { welcome.showWindow(nil) }
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeMainNotification, object: nil, queue: .main) { [weak self] note in
            if (note.object as? NSWindow)?.windowController is SheetWindowController { self?.welcome.close() }
        }
        DebugSnapshot.scheduleIfRequested {
            // K42_SCROLL=x,y scrolls the front sheet; K42_SELECT=C10 selects a cell (UI checks).
            let env = ProcessInfo.processInfo.environment
            guard let editor = NSApp.orderedWindows.compactMap({ $0.windowController as? SheetWindowController }).first else { return }
            if let ref = env["K42_SELECT"].flatMap(CellRef.init) { editor.grid.select(ref) }
            if let xy = env["K42_SCROLL"]?.split(separator: ",").compactMap({ Double($0) }), xy.count == 2 {
                editor.debugScroll(to: NSPoint(x: xy[0], y: xy[1]))
            }
        }
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { welcome.showWindow(nil) }
        return true
    }

    @objc func showWelcomeAction(_ sender: Any?) { welcome.showWindow(nil) }

    @objc func showFunctionsAction(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = L("Supported Functions")
        alert.informativeText = L("Russian function names (СУММ, ЕСЛИ, ВПР…) are accepted too.") + "\n\n" + Self.functionList
        alert.runModal()
    }

    static let functionList = """
    SUM PRODUCT AVERAGE AVERAGEA MIN MAX COUNT COUNTA COUNTBLANK MEDIAN MODE STDEV STDEV.S STDEV.P VAR VAR.S VAR.P \
    LARGE SMALL RANK SUMPRODUCT SUMSQ SUBTOTAL · SUMIF SUMIFS COUNTIF COUNTIFS AVERAGEIF AVERAGEIFS MAXIFS MINIFS · \
    IF IFS IFERROR IFNA AND OR XOR NOT SWITCH CHOOSE · VLOOKUP HLOOKUP XLOOKUP INDEX MATCH OFFSET INDIRECT ROW COLUMN ROWS COLUMNS · \
    ABS SIGN INT TRUNC ROUND ROUNDUP ROUNDDOWN MROUND CEILING FLOOR EVEN ODD MOD POWER SQRT EXP LN LOG LOG10 PI RAND RANDBETWEEN FACT \
    DEGREES RADIANS SIN COS TAN · LEN LEFT RIGHT MID UPPER LOWER PROPER TRIM CONCAT CONCATENATE TEXTJOIN SUBSTITUTE REPLACE \
    FIND SEARCH REPT EXACT CHAR CODE T N TEXT VALUE · TODAY NOW DATE TIME YEAR MONTH DAY WEEKDAY HOUR MINUTE SECOND EDATE \
    EOMONTH DAYS DATEDIF NETWORKDAYS WORKDAY · ISBLANK ISNUMBER ISTEXT ISLOGICAL ISERROR ISERR ISNA NA · PMT FV PV
    """
}
