import AppKit
import Kit42
import UniformTypeIdentifiers

/// Routes File › Open, Open Recent and the welcome window's recent list to image windows (no NSDocument).
final class ImageDocumentController: NSDocumentController {
    override func openDocument(_ sender: Any?) { AppDelegate.shared?.runOpenPanel() }

    override func openDocument(withContentsOf url: URL, display displayDocument: Bool,
                               completionHandler: @escaping (NSDocument?, Bool, Error?) -> Void) {
        AppDelegate.shared?.open([url])
        completionHandler(nil, false, nil)
    }

    override func newDocument(_ sender: Any?) {}

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(newDocument(_:)) { return false }
        return super.validateUserInterfaceItem(item)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static weak var shared: AppDelegate?
    private(set) var windows: [ImageWindowController] = []

    private lazy var welcome = WelcomeWindowController(
        app: .img, tagline: L("Images: view, flip through, mark up and adjust"),
        actions: [
            .init(L("Open Image…"), symbol: "photo", action: #selector(NSDocumentController.openDocument(_:))),
            .init(L("Open Folder…"), symbol: "folder", action: #selector(AppDelegate.openFolderAction(_:))),
        ])

    override init() {
        super.init()
        AppDelegate.shared = self
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MenuBar.build(Cmd.menuBar(openWithDelegate: self))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [self] in
            if windows.isEmpty {
                // Started from the command line with paths (`IMG42 photo.jpg`).
                let paths = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") && FileManager.default.fileExists(atPath: $0) }
                if !paths.isEmpty { open(paths.map { URL(fileURLWithPath: $0) }) } else { welcome.showWindow(nil) }
            }
        }
        DebugSnapshot.scheduleIfRequested { [weak self] in self?.prepareSnapshot() }
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { welcome.showWindow(nil) }
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) { open(urls) }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let dirty = windows.filter(\.isDirty)
        // Debug snapshots quit on their own.
        guard !dirty.isEmpty, ProcessInfo.processInfo.environment["K42_SNAPSHOT"] == nil else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = L("Quit without saving your changes?")
        alert.informativeText = L("%d edited images have not been saved.", dirty.count)
        alert.addButton(withTitle: L("Quit"))
        alert.addButton(withTitle: L("Cancel"))
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    // MARK: - Opening

    @objc func showWelcomeAction(_ sender: Any?) { welcome.showWindow(nil) }

    func runOpenPanel(foldersOnly: Bool = false) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = !foldersOnly
        panel.canChooseDirectories = true
        panel.canChooseFiles = !foldersOnly
        if !foldersOnly { panel.allowedContentTypes = ImageFormats.readableTypes + [.folder] }
        panel.message = foldersOnly ? L("Choose a folder with images") : L("Choose images or a folder")
        guard panel.runModal() == .OK else { return }
        open(panel.urls)
    }

    @objc func openFolderAction(_ sender: Any?) { runOpenPanel(foldersOnly: true) }

    /// One file → its whole folder; one folder → its images; several items → exactly those (folders expanded).
    func open(_ items: [URL]) {
        guard !items.isEmpty else { return }
        var set: [URL] = []
        var start: URL?
        let isDir: (URL) -> Bool = { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        if items.count == 1, let only = items.first {
            if isDir(only) {
                set = ImageFormats.images(in: only)
            } else {
                set = ImageFormats.images(in: only.deletingLastPathComponent())
                if !set.contains(where: { $0.standardizedFileURL == only.standardizedFileURL }) { set.append(only) }
                start = only
            }
        } else {
            for item in items {
                if isDir(item) { set += ImageFormats.images(in: item) } else { set.append(item) }
            }
            start = items.first { !isDir($0) }
        }
        guard !set.isEmpty else {
            let alert = NSAlert()
            alert.messageText = L("No images found")
            alert.informativeText = L("The folder contains no images IMG42 can open.")
            alert.runModal()
            return
        }
        // Already open in a window: bring it to the front at that image.
        if let start, let w = windows.first(where: { $0.url?.standardizedFileURL == start.standardizedFileURL }) {
            w.showWindow(nil)
            return
        }
        let controller = ImageWindowController(urls: set, start: start)
        windows.append(controller)
        controller.showWindow(nil)
        welcome.close()
        for item in items where !isDir(item) { NSDocumentController.shared.noteNewRecentDocumentURL(item) }
    }

    func windowClosed(_ controller: ImageWindowController) {
        windows.removeAll { $0 === controller }
    }

    var frontController: ImageWindowController? {
        NSApp.orderedWindows.compactMap { $0.windowController as? ImageWindowController }.first
    }

    // MARK: - Open With

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let url = frontController?.url else {
            menu.addItem(withTitle: L("No image"), action: nil, keyEquivalent: "").isEnabled = false
            return
        }
        let own = Bundle.main.bundleURL.standardizedFileURL
        let apps = NSWorkspace.shared.urlsForApplications(toOpen: url).filter { $0.standardizedFileURL != own }
        let fm = FileManager.default
        for app in apps.prefix(24) {
            let item = NSMenuItem(title: fm.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: ""),
                                  action: #selector(openWithApp(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = app
            let icon = NSWorkspace.shared.icon(forFile: app.path)
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon
            menu.addItem(item)
        }
        if apps.isEmpty { menu.addItem(withTitle: L("No other apps"), action: nil, keyEquivalent: "").isEnabled = false }
        menu.addItem(.separator())
        let other = NSMenuItem(title: L("Other…"), action: #selector(openWithOther(_:)), keyEquivalent: "")
        other.target = self
        menu.addItem(other)
    }

    @objc func openWithApp(_ sender: NSMenuItem) {
        guard let app = sender.representedObject as? URL, let url = frontController?.url else { return }
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    @objc func openWithOther(_ sender: Any?) {
        guard let url = frontController?.url else { return }
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.message = L("Choose an app to open the image")
        guard panel.runModal() == .OK, let app = panel.url else { return }
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    // MARK: - Debug hooks (K42_SNAPSHOT)

    /// K42_NEXT=n flips n images, K42_PAGE=n pages, K42_INFO / K42_FILMSTRIP / K42_ADJUST open panels,
    /// K42_MARKUP shows the markup strip, K42_DEMO_MARKS adds sample marks, K42_TOOL=<n> picks a tool,
    /// K42_SELECT=rect|ellipse|alpha makes a sample selection, K42_SEARCH=text runs Live Text search,
    /// K42_ZOOM=x zooms, K42_DUMP_MENUS prints the markup drop-downs, K42_STAMPS opens the signature popover,
    /// K42_RESIZE / K42_DESCRIPTION open those sheets, K42_BACKGROUND=n picks the background.
    private func prepareSnapshot() {
        let env = ProcessInfo.processInfo.environment
        guard let w = frontController else { return }
        if let n = env["K42_NEXT"].flatMap(Int.init) {
            for _ in 0..<abs(n) { w.step(n < 0 ? -1 : 1) }
        }
        if let p = env["K42_PAGE"].flatMap(Int.init) {
            for _ in 0..<p { w.nextPageAction(nil) }
        }
        if let b = env["K42_BACKGROUND"].flatMap(Int.init) { w.backgroundAction(NSMenuItem.tagged(b)) }
        if env["K42_FILMSTRIP"] != nil, w.filmstrip.isHidden { w.toggleFilmstripAction(nil) }
        if env["K42_NOFILMSTRIP"] != nil, !w.filmstrip.isHidden { w.toggleFilmstripAction(nil) }
        // Let the image load before panels and markup that depend on it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            if env["K42_INFO"] != nil { w.toggleInspector(w.infoPanel, forceShow: true) }
            if env["K42_ADJUST"] != nil {
                var a = Adjustments()
                a[.exposure] = 10; a[.contrast] = 25; a[.saturation] = 30; a[.temperature] = 20; a[.vignette] = 40
                w.toggleInspector(w.adjustPanel, forceShow: true)
                w.applyAdjustments(a, name: "demo")
            }
            if env["K42_MARKUP"] != nil { w.markupBar.show(true) }
            if let t = env["K42_TOOL"].flatMap(Int.init), let tool = MarkTool(rawValue: t) { w.markupBar.setTool(tool) }
            if env["K42_DEMO_MARKS"] != nil, let base = w.base {
                w.markupBar.show(true)
                let before = w.canvas.markup.marks
                w.canvas.markup.marks = Mark.demo(for: CGSize(width: base.width, height: base.height))
                w.marksCommitted(before: before, name: "demo")
                if env["K42_SELECT_MARK"] != nil { w.canvas.markup.selectedID = w.canvas.markup.marks.last?.id }
            }
            if let sel = env["K42_SELECT"], let base = w.base {
                let r = CGRect(x: CGFloat(base.width) * 0.2, y: CGFloat(base.height) * 0.2, width: CGFloat(base.width) * 0.5, height: CGFloat(base.height) * 0.45)
                w.markupBar.show(true)
                switch sel {
                case "ellipse":
                    w.markupBar.setTool(.selectEllipse)
                    w.canvas.markup.pixelSelection = PixelSelection.from(path: CGPath(ellipseIn: r, transform: nil), size: CGSize(width: base.width, height: base.height))
                case "alpha":
                    w.markupBar.setTool(.instantAlpha)
                    w.canvas.markup.pixelSelection = PixelSelection.similarColors(in: base, seed: CGPoint(x: 2, y: 2), tolerance: 0.15)
                default:
                    w.markupBar.setTool(.selectRect)
                    w.canvas.markup.pixelSelection = PixelSelection.from(path: CGPath(rect: r, transform: nil), size: CGSize(width: base.width, height: base.height), isRectangle: true)
                }
                if env["K42_CROP"] != nil { w.cropToSelectionAction(nil) }
                if env["K42_DELETE"] != nil { w.deleteSelectionAction(nil) }
            }
            if let q = env["K42_SEARCH"], let image = w.displayed ?? w.base {
                // Recognise synchronously so the snapshot shows the result.
                w.textLines = PixelOps.recognizeText(image)
                w.textLinesFor = image
                w.toolbarImpl.searchField?.stringValue = q
                w.runSearch(q)
            }
            if let z = env["K42_ZOOM"].flatMap(Double.init) { w.canvas.zoom(to: CGFloat(z)) }
            if env["K42_DUMP_MENUS"] != nil { print(w.markupBar.dumpMenus()) }
            if env["K42_STAMPS"] != nil, let b = w.markupBar.strip.view.firstSubview(withToolTipPrefix: L("Insert a signature or stamp")) {
                w.showStampsAction(b)
            }
            if env["K42_RESIZE"] != nil { w.resizeAction(nil) }
            if env["K42_DESCRIPTION"] != nil { w.imageDescriptionAction(nil) }
            if env["K42_EXPORT"] != nil { w.exportAction(nil) }
            if env["K42_UNDO"] != nil { w.undo.undo() }
            if env["K42_SAVE"] != nil { w.save(confirmed: true) { ok in print("saved:", ok) } }
            if env["K42_FULLSCREEN"] != nil { w.window?.toggleFullScreen(nil) }
            if env["K42_HIDE_ALL"] != nil { w.toggleAllPanelsAction(nil) }
        }
    }
}

extension NSMenuItem {
    static func tagged(_ tag: Int) -> NSMenuItem {
        let i = NSMenuItem()
        i.tag = tag
        return i
    }
}

extension NSView {
    func firstSubview(withToolTipPrefix prefix: String) -> NSView? {
        if toolTip?.hasPrefix(prefix) == true { return self }
        for s in subviews { if let v = s.firstSubview(withToolTipPrefix: prefix) { return v } }
        return nil
    }
}
