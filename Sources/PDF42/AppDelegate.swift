import AppKit
import Kit42
import PDFKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private lazy var welcome = WelcomeWindowController(
        app: .pdf, tagline: L("View and edit PDF"),
        actions: [
            .init(L("Open PDF…"), symbol: "folder", action: #selector(NSDocumentController.openDocument(_:))),
            .init(L("New Document"), symbol: "doc.badge.plus", action: #selector(NSDocumentController.newDocument(_:))),
            .init(L("Signatures and Stamps"), symbol: "signature", action: #selector(showStampLibraryAction(_:))),
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
            if (note.object as? NSWindow)?.windowController is EditorWindowController { self?.welcome.close() }
        }
        DebugSnapshot.scheduleIfRequested {
            let env = ProcessInfo.processInfo.environment
            let editor = NSApp.orderedWindows.compactMap { $0.windowController as? EditorWindowController }.first
            if env["K42_MARKUP"] != nil { editor?.toggleMarkupAction(nil) }
            if env["K42_STAMPS"] != nil { editor?.showStampsAction(nil) }
            if let tool = env["K42_TOOL"].flatMap(Int.init).flatMap(Tool.init) { editor?.setTool(tool) }
            if let text = env["K42_WATERMARK"], let editor, let pdf = editor.pdf {
                var spec = WatermarkSpec()
                spec.text = text
                for i in 0..<pdf.pageCount { if let p = pdf.page(at: i) { editor.add(WatermarkOverlay(spec: spec, page: p), to: p, name: "") } }
                for (i, t) in PageNumberSpec().labels(for: Array(0..<pdf.pageCount)) {
                    if let p = pdf.page(at: i) { editor.add(PageNumberOverlay(text: t, spec: PageNumberSpec(), page: p), to: p, name: "") }
                }
            }
            if let text = env["K42_EDIT_TEXT"], let editor, let hit = editor.pdf?.findString(text, withOptions: []).first, let page = hit.pages.first {
                editor.setTool(.editText)
                editor.editPageText(hit, on: page)
            }
            if let path = env["K42_COMPARE"], let other = PDFDocument(url: URL(fileURLWithPath: path)) {
                editor?.showComparison(with: other, name: (path as NSString).lastPathComponent)
            }
        }
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { welcome.showWindow(nil) }
        return true
    }

    // MARK: - App-level actions

    @objc func showWelcomeAction(_ sender: Any?) { welcome.showWindow(nil) }

    @objc func newFromImagesAction(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.message = L("Each image becomes an A4 page")
        guard panel.runModal() == .OK else { return }
        let pdf = PDFDocument()
        for url in panel.urls.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
            if let image = NSImage(contentsOf: url), let page = PDFDoc.page(from: image) { pdf.insert(page, at: pdf.pageCount) }
        }
        guard pdf.pageCount > 0 else { return }
        let doc = PDFDoc(pdf: pdf)
        NSDocumentController.shared.addDocument(doc)
        doc.makeWindowControllers()
        doc.showWindows()
        doc.updateChangeCount(.changeDone)
    }

    @objc func showStampLibraryAction(_ sender: Any?) {
        let popover = NSPopover()
        let vc = StampLibraryViewController { _ in }
        vc.popover = popover
        popover.contentViewController = vc
        popover.behavior = .transient
        if let view = sender as? NSView { popover.show(relativeTo: view.bounds, of: view, preferredEdge: .maxX) }
    }

    @objc func importCertificateAction(_ sender: Any?) {
        if let identity = SignDialog.importCertificate() {
            info(L("Certificate added"), L("“%@” is saved in the Keychain and can be used for signing.", identity.displayName))
        }
    }

    @objc func createCertificateAction(_ sender: Any?) {
        if let identity = SignDialog.createCertificate() {
            info(L("Certificate created"), L("“%@” is saved in the Keychain. It is a self-signed certificate: the signature will be intact, but other apps will show that the certificate is not confirmed by a certification authority.", identity.displayName))
        }
    }

    @objc func showShortcutsAction(_ sender: Any?) {
        let lines = [
            L("⌘1…⌘9 — markup tools, Esc — select"),
            L("⇧⌘A — markup toolbar, ⇧⌘K — signature or stamp"),
            L("⌘E — edit selected text, ⌘⌫ — delete annotation"),
            L("⌥⌘M — merge files, ⌘E — edit text (click a line)"),
            L("⌘L / ⌘R — rotate page, ⌥⌘⌫ — delete pages"),
            L("⇧⌘N — blank page, ⌥⌘I — pages from file"),
            L("⌥⌘D — sign, ⌥⌘V — verify signatures"),
            L("⌘F / ⌘G — find, ⌥⌘G — go to page"),
            L("⌘+ / ⌘- / ⌘0 — zoom, ⌃⌘S — sidebar"),
        ]
        info(L("Keyboard Shortcuts"), lines.joined(separator: "\n"))
    }

    private func info(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.runModal()
    }
}
