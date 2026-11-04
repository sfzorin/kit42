import AppKit
import Kit42

/// Every IMG42 action, defined once and reused by menus, toolbar and markup bar.
enum Cmd {
    typealias W = ImageWindowController
    typealias A = AppDelegate

    // Navigation
    static let previous = Command(L("Previous Image"), #selector(W.previousAction(_:)), symbol: "chevron.left",
                                  shortcut: Shortcut(Shortcut.leftArrow, []), label: L("Previous"))
    static let next = Command(L("Next Image"), #selector(W.nextAction(_:)), symbol: "chevron.right",
                              shortcut: Shortcut(Shortcut.rightArrow, []), label: L("Next"))
    static let first = Command(L("First Image"), #selector(W.firstAction(_:)), shortcut: Shortcut(Shortcut.upArrow, [.command]))
    static let last = Command(L("Last Image"), #selector(W.lastAction(_:)), shortcut: Shortcut(Shortcut.downArrow, [.command]))
    static let previousPage = Command(L("Previous Page"), #selector(W.previousPageAction(_:)), shortcut: Shortcut(Shortcut.leftArrow, [.option]))
    static let nextPage = Command(L("Next Page"), #selector(W.nextPageAction(_:)), shortcut: Shortcut(Shortcut.rightArrow, [.option]))
    static let slideshow = Command(L("Slideshow"), #selector(W.slideshowAction(_:)), symbol: "play.rectangle", shortcut: Shortcut("f", [.command, .shift]))

    // Zoom
    static let zoomIn = Command(L("Zoom In"), #selector(W.zoomInAction(_:)), symbol: "plus.magnifyingglass", shortcut: Shortcut("+"))
    static let zoomOut = Command(L("Zoom Out"), #selector(W.zoomOutAction(_:)), symbol: "minus.magnifyingglass", shortcut: Shortcut("-"))
    static let actualSize = Command(L("Actual Size"), #selector(W.actualSizeAction(_:)), symbol: "1.magnifyingglass", shortcut: Shortcut("0"))
    static let zoomToFit = Command(L("Zoom to Fit"), #selector(W.zoomToFitAction(_:)), symbol: "arrow.up.left.and.down.right.magnifyingglass",
                                   shortcut: Shortcut("0", [.command, .option]))

    // Panels
    static let info = Command(L("Info Panel"), #selector(W.toggleInfoAction(_:)), symbol: "info.circle", shortcut: Shortcut("i"),
                              toolTip: L("Inspector"), label: L("Info"))
    static let filmstrip = Command(L("Filmstrip"), #selector(W.toggleFilmstripAction(_:)), symbol: "film", shortcut: Shortcut("f", [.command, .option]),
                                   toolTip: L("Filmstrip"), label: L("Filmstrip"))
    static let markupBar = Command(L("Markup Toolbar"), #selector(W.toggleMarkupAction(_:)), symbol: "pencil.tip.crop.circle",
                                   shortcut: Shortcut("a", [.command, .shift]), toolTip: L("Markup"), label: L("Markup"))
    static let adjust = Command(L("Adjust Colour"), #selector(W.toggleAdjustAction(_:)), symbol: "slider.horizontal.3",
                                shortcut: Shortcut("c", [.command, .option]), toolTip: L("Adjust Colour"), label: L("Adjust"))

    // Image
    static let rotateLeft = Command(L("Rotate Left"), #selector(W.rotateLeftAction(_:)), symbol: "rotate.left", shortcut: Shortcut("l"))
    static let rotateRight = Command(L("Rotate Right"), #selector(W.rotateRightAction(_:)), symbol: "rotate.right", shortcut: Shortcut("r"))
    static let flipHorizontal = Command(L("Flip Horizontal"), #selector(W.flipHorizontalAction(_:)), symbol: "arrow.left.and.right.righttriangle.left.righttriangle.right")
    static let flipVertical = Command(L("Flip Vertical"), #selector(W.flipVerticalAction(_:)), symbol: "arrow.up.and.down.righttriangle.up.righttriangle.down")
    static let resize = Command(L("Adjust Size…"), #selector(W.resizeAction(_:)), symbol: "arrow.up.left.and.arrow.down.right",
                                shortcut: Shortcut("r", [.command, .option]), toolTip: L("Adjust Size"), label: L("Size"))
    static let removeBackground = Command(L("Remove Background"), #selector(W.removeBackgroundAction(_:)), symbol: "person.and.background.dotted",
                                          label: L("Background"))
    static let autoEnhance = Command(L("Auto Enhance"), #selector(W.autoEnhanceAction(_:)), symbol: "wand.and.stars")
    static let looks: [Command] = Adjustments.Look.allCases.map { Command($0.title, #selector(W.lookAction(_:)), tag: $0.rawValue) }
    static let imageDescription = Command(L("Image Description…"), #selector(W.imageDescriptionAction(_:)), symbol: "quote.bubble",
                                          toolTip: L("Image Description"), label: L("Description"))

    // Selection
    static let cropToSelection = Command(L("Crop to Selection"), #selector(W.cropToSelectionAction(_:)), symbol: "crop", shortcut: Shortcut("k"))
    static let deleteSelection = Command(L("Delete Selection"), #selector(W.deleteSelectionAction(_:)), symbol: "trash.slash")
    static let invertSelection = Command(L("Invert Selection"), #selector(W.invertSelectionAction(_:)), shortcut: Shortcut("i", [.command, .shift]))
    static let deselect = Command(L("Deselect"), #selector(W.deselectAction(_:)), shortcut: Shortcut("d"))
    static let copyText = Command(L("Copy Text in Image"), #selector(W.copyTextAction(_:)), symbol: "text.viewfinder", shortcut: Shortcut("c", [.command, .shift]))

    // File
    static let export = Command(L("Export…"), #selector(W.exportAction(_:)), symbol: "square.and.arrow.up.on.square", shortcut: Shortcut("e", [.command, .shift]))
    static let showInFinder = Command(L("Show in Finder"), #selector(W.showInFinderAction(_:)), symbol: "folder", shortcut: Shortcut("r", [.command, .shift]))
    static let trash = Command(L("Move to Trash"), #selector(W.trashAction(_:)), symbol: "trash", shortcut: Shortcut(Shortcut.backspace))
    static let print = Command(L("Print…"), #selector(W.printDocument(_:)), symbol: "printer", toolTip: L("Print"), label: L("Print"))

    // Markup tools
    static func tool(_ t: MarkTool) -> Command {
        Command(t.title, #selector(W.selectToolAction(_:)), symbol: t.symbol, tag: t.rawValue)
    }
    static let stamps = Command(L("Signature or Stamp…"), #selector(W.showStampsAction(_:)), symbol: "signature",
                                shortcut: Shortcut("k", [.command, .shift]), toolTip: L("Insert a signature or stamp"), label: L("Sign"))

    // View options
    static let sortOrders: [Command] = SortOrder.allCases.map { Command($0.title, #selector(W.sortAction(_:)), tag: $0.rawValue) }
    static let backgrounds: [Command] = Background.allCases.map { Command($0.title, #selector(W.backgroundAction(_:)), tag: $0.rawValue) }
    /// Also wired by Kit42's shared View menu item (same selector) once it lands; listed here for IMG42 meanwhile.
    static let hideAllPanels = Command(L("Hide All Panels"), #selector(W.toggleAllPanelsAction(_:)), shortcut: Shortcut("\\", [.command, .shift]))
    static let wrap = Command(L("Loop Through Folder"), #selector(W.toggleWrapAction(_:)))

    static let welcome = Command(L("Welcome Window"), #selector(A.showWelcomeAction(_:)), shortcut: Shortcut("0", [.command, .shift]))

    static func openWithItem(delegate: NSMenuDelegate) -> NSMenuItem {
        let item = NSMenuItem(title: L("Open With"), action: nil, keyEquivalent: "")
        let menu = NSMenu(title: L("Open With"))
        menu.delegate = delegate
        item.submenu = menu
        return item
    }

    static func menuBar(openWithDelegate: NSMenuDelegate) -> MenuBarSpec {
        var spec = MenuBarSpec(appName: "IMG42")
        spec.fileExtras = [.command(export), .separator, .command(showInFinder), .item(openWithItem(delegate: openWithDelegate)),
                           .separator, .command(trash)]
        spec.editExtras = [.command(copyText), .separator, .command(cropToSelection), .command(deleteSelection), .command(invertSelection), .command(deselect)]
        spec.view = [.command(zoomIn), .command(zoomOut), .command(actualSize), .command(zoomToFit), .separator,
                     .command(markupBar), .command(filmstrip), .command(info), .command(adjust), .command(hideAllPanels), .separator,
                     .submenu(L("Sort By"), sortOrders.menuElements), .submenu(L("Background"), backgrounds.menuElements), .command(wrap),
                     .separator, .command(slideshow)]
        spec.custom = [
            (L("Go"), [.command(previous), .command(next), .command(first), .command(last), .separator, .command(previousPage), .command(nextPage)]),
            (L("Image"), [.command(rotateLeft), .command(rotateRight), .command(flipHorizontal), .command(flipVertical), .separator,
                          .command(autoEnhance), .submenu(L("Look"), looks.menuElements), .separator,
                          .command(resize), .command(removeBackground), .separator, .command(imageDescription)]),
            (L("Markup"), [MarkTool.select].map { .command(tool($0)) } + [.separator]
                + (MarkTool.selectionTools + [.instantAlpha]).map { .command(tool($0)) } + [.separator]
                + [MarkTool.sketch, .draw, .highlighter].map { .command(tool($0)) } + [.separator]
                + [.submenu(L("Shapes"), MarkTool.shapeTools.map { .command(tool($0)) }), .command(tool(.text)), .command(stamps)]),
        ]
        spec.help = [.command(welcome)]
        return spec
    }
}

enum SortOrder: Int, CaseIterable {
    case name, dateModified, dateTaken, size
    var title: String {
        switch self {
        case .name: return L("Name")
        case .dateModified: return L("Date Modified")
        case .dateTaken: return L("Date Taken")
        case .size: return L("Size")
        }
    }

    func sort(_ urls: [URL]) -> [URL] {
        switch self {
        case .name:
            return urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        case .dateModified:
            let d = Dictionary(urls.map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) },
                               uniquingKeysWith: { a, _ in a })
            return urls.sorted { (d[$0]!, $0.lastPathComponent) < (d[$1]!, $1.lastPathComponent) }
        case .dateTaken:
            let d = Dictionary(urls.map { url in
                (url, ImageLoader.dateTaken(url) ?? (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
            }, uniquingKeysWith: { a, _ in a })
            return urls.sorted { (d[$0]!, $0.lastPathComponent) < (d[$1]!, $1.lastPathComponent) }
        case .size:
            let s = Dictionary(urls.map { ($0, (try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }, uniquingKeysWith: { a, _ in a })
            return urls.sorted { (s[$0]!, $0.lastPathComponent) < (s[$1]!, $1.lastPathComponent) }
        }
    }
}

enum Background: Int, CaseIterable {
    case neutral, dark, black, light
    var title: String {
        switch self {
        case .neutral: return L("Neutral")
        case .dark: return L("Dark")
        case .black: return L("Black")
        case .light: return L("Light")
        }
    }
    var color: NSColor {
        switch self {
        case .neutral: return .underPageBackgroundColor
        case .dark: return NSColor(white: 0.13, alpha: 1)
        case .black: return .black
        case .light: return NSColor(white: 0.97, alpha: 1)
        }
    }
}

