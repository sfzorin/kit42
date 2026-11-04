import AppKit
import Kit42

final class AppDelegate: NSObject, NSApplicationDelegate {
    private lazy var welcome = WelcomeWindowController(
        app: .doc, tagline: L("Documents: Word, RTF, OpenDocument"),
        actions: [
            .init(L("Open Document…"), symbol: "folder", action: #selector(NSDocumentController.openDocument(_:))),
            .init(L("New Document"), symbol: "doc.badge.plus", action: #selector(NSDocumentController.newDocument(_:))),
        ])

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Autosave every 30 s to a backup location (not over the file): documents survive a crash.
        NSDocumentController.shared.autosavingDelay = 30
        NSApp.mainMenu = MenuBar.build(Cmd.menuBar)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [self] in
            if NSDocumentController.shared.documents.isEmpty { welcome.showWindow(nil) }
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeMainNotification, object: nil, queue: .main) { [weak self] note in
            if (note.object as? NSWindow)?.windowController is DocWindowController { self?.welcome.close() }
        }
        DebugSnapshot.scheduleIfRequested {
            // K42_ZOOM=0.5 zooms the front document (UI checks).
            if let z = ProcessInfo.processInfo.environment["K42_ZOOM"].flatMap(Double.init),
               let editor = NSApp.orderedWindows.compactMap({ $0.windowController as? DocWindowController }).first {
                editor.setZoom(CGFloat(z))
            }
        }
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { welcome.showWindow(nil) }
        return true
    }

    @objc func showWelcomeAction(_ sender: Any?) { welcome.showWindow(nil) }
}
