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
        // Autosave every 30 s to a backup location (not over the file): documents survive a crash.
        NSDocumentController.shared.autosavingDelay = 30
        // Debug hook: K42_APPEARANCE=dark|light forces the appearance before any window opens (snapshot checks).
        if let mode = ProcessInfo.processInfo.environment["K42_APPEARANCE"] {
            NSApp.appearance = NSAppearance(named: mode == "dark" ? .darkAqua : .aqua)
        }
        NSApp.mainMenu = MenuBar.build(Cmd.menuBar)
        CellStyleMenu.install(in: NSApp.mainMenu)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--uitest") {
            DispatchQueue.main.async { UITest.run() }
            return
        }
        NSApp.activate()
        // Debug hook: K42_OPEN=/path/file.xlsx opens a document at launch (snapshot checks of the unbundled binary).
        if let path = ProcessInfo.processInfo.environment["K42_OPEN"] {
            NSDocumentController.shared.openDocument(withContentsOf: URL(fileURLWithPath: path), display: true) { _, _, _ in }
        }
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
            // K42_ACTION=insertFunctionAction: sends a command (non-modal dialogs: wizard, find panel).
            if let action = env["K42_ACTION"], let path = env["K42_SNAPSHOT"] {
                // The dialog itself goes to <snapshot>-dialog.png; a sheet is closed and a modal alert
                // cancelled so the app can quit. A run-loop timer scheduled first: modal dialogs block
                // sendAction, and nested main-queue blocks don't run while this one does.
                let capture = Timer(timeInterval: 0.6, repeats: false) { _ in
                    let modal = NSApp.modalWindow
                    guard let dialog = modal ?? editor.window?.attachedSheet ?? editor.findPanel?.window ?? editor.functionWizard?.window,
                          let frame = dialog.contentView?.superview, let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else { return }
                    frame.cacheDisplay(in: frame.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path.replacingOccurrences(of: ".png", with: "-dialog.png")))
                    if modal != nil { NSApp.abortModal(); dialog.orderOut(nil) }
                    else if dialog.sheetParent != nil { editor.window?.endSheet(dialog) } else { dialog.orderOut(nil) }
                }
                RunLoop.main.add(capture, forMode: .common)
                NSApp.sendAction(NSSelectorFromString(action), to: editor, from: nil)
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

    /// Function names grouped by category (from the engine's catalog).
    static var functionList: String {
        FunctionCatalog.Category.allCases.map { c in
            c.title + ": " + FunctionCatalog.all.filter { $0.category == c }.map(\.name).joined(separator: " ")
        }.joined(separator: "\n\n") + "\n\n" + L("Insert › Function… lists them with descriptions.")
    }
}
