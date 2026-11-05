import AppKit
import Kit42

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private lazy var welcome = WelcomeWindowController(
        app: .ppt, tagline: L("Presentations: PowerPoint and OpenDocument"),
        actions: [
            .init(L("New Presentation"), symbol: "rectangle.badge.plus", action: #selector(NSDocumentController.newDocument(_:))),
            .init(L("Open Presentation…"), symbol: "folder", action: #selector(NSDocumentController.openDocument(_:))),
            .init(L("New from Template…"), symbol: "square.grid.2x2", action: #selector(AppDelegate.newFromTemplateAction(_:))),
        ])

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Autosave every 30 s to a backup location (not over the file): documents survive a crash.
        NSDocumentController.shared.autosavingDelay = PresentationDocument.testMode ? 0 : 30
        DebugSnapshot.applyAppearanceIfRequested()
        let menu = MenuBar.build(Cmd.menuBar(layoutsMenu: self))
        // ⇧⌘P plays from the current slide (as in PowerPoint); Page Setup keeps its menu item.
        if let file = menu.items.first(where: { $0.submenu?.items.contains { $0.action == #selector(NSDocument.runPageLayout(_:)) } == true })?.submenu,
           let setup = file.items.first(where: { $0.action == #selector(NSDocument.runPageLayout(_:)) }) {
            setup.keyEquivalent = ""
        }
        NSApp.mainMenu = menu
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if !PresentationDocument.testMode { NSApp.activate() }
        let env = ProcessInfo.processInfo.environment
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [self] in
            guard NSDocumentController.shared.documents.isEmpty else { return }
            // Started from the command line with a path (`PPT42 deck.pptx`).
            let paths = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") && FileManager.default.fileExists(atPath: $0) }
            if let p = paths.first {
                NSDocumentController.shared.openDocument(withContentsOf: URL(fileURLWithPath: p), display: true) { _, _, error in
                    if let error { NSApp.presentError(error) }
                }
            } else if env["K42_NEW"] != nil {
                NSDocumentController.shared.newDocument(nil)
            } else {
                welcome.showWindow(nil)
            }
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeMainNotification, object: nil, queue: .main) { [weak self] note in
            if (note.object as? NSWindow)?.windowController is DeckWindowController { self?.welcome.close() }
        }
        DebugSnapshot.scheduleIfRequested {
            let front = NSApp.orderedWindows.compactMap { $0.windowController as? DeckWindowController }.first
            front?.prepareSnapshot(env)
        }
        // Debug runs never outlive their snapshot.
        if env["K42_SNAPSHOT"] != nil, env["K42_SNAPSHOT_KEEP"] == nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 25) { exit(0) }
        }
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { welcome.showWindow(nil) }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        SlideShowController.current?.end()
        return .terminateNow
    }

    @objc func showWelcomeAction(_ sender: Any?) { welcome.showWindow(nil) }

    // MARK: - Layout menus (filled from the front presentation)

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let deck = (NSDocumentController.shared.currentDocument as? PresentationDocument)?.deck ?? Deck.makeDefault()
        let newSlide = menu.identifier?.rawValue == "newSlideLayouts"
        for (i, layout) in deck.layouts.enumerated() {
            let item = NSMenuItem(title: Themes.displayName(layout), action: newSlide ? #selector(DeckWindowController.newSlideWithLayoutAction(_:)) : #selector(DeckWindowController.layoutAction(_:)), keyEquivalent: "")
            item.tag = i
            item.image = LayoutIcons.icon(layout, deck: deck, width: 32)
            menu.addItem(item)
        }
    }
}

/// Small pictures of layouts (placeholder boxes) for menus and the new-slide picker.
enum LayoutIcons {
    static func icon(_ layout: Layout, deck: Deck, width: CGFloat) -> NSImage {
        let h = width * deck.size.height / deck.size.width
        let img = NSImage(size: NSSize(width: width, height: h), flipped: true) { r in
            NSColor.white.setFill()
            r.fill()
            NSColor(white: 0.55, alpha: 1).setStroke()
            NSBezierPath(rect: r.insetBy(dx: 0.5, dy: 0.5)).stroke()
            let s = width / deck.size.width
            for ph in layout.placeholders where ph.placeholder?.isFooter != true {
                let f = CGRect(x: ph.frame.minX * s, y: ph.frame.minY * s, width: ph.frame.width * s, height: ph.frame.height * s).insetBy(dx: 0.5, dy: 0.5)
                (ph.placeholder?.isTitle == true ? NSColor(white: 0.45, alpha: 1) : NSColor(white: 0.75, alpha: 1)).setFill()
                if ph.placeholder?.isTitle == true {
                    NSBezierPath(rect: CGRect(x: f.minX + f.width * 0.1, y: f.midY - max(1, f.height * 0.15), width: f.width * 0.8, height: max(1.5, f.height * 0.3))).fill()
                } else if ph.placeholder?.type == "pic" {
                    NSBezierPath(rect: f).fill()
                } else {
                    let lines = max(1, Int(f.height / max(2.5, width / 20)))
                    for k in 0..<min(lines, 5) {
                        NSBezierPath(rect: CGRect(x: f.minX + 1, y: f.minY + 1 + CGFloat(k) * max(2.5, width / 20), width: f.width * (k % 2 == 0 ? 0.9 : 0.7), height: max(0.8, width / 60))).fill()
                    }
                }
            }
            return true
        }
        return img
    }
}
