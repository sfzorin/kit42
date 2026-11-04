import AppKit
import Kit42

/// Every PDF42 action, defined once and reused by menus, toolbar and markup bar.
enum Cmd {
    typealias W = EditorWindowController
    typealias A = AppDelegate

    // Tools (markup bar, L("Markup") menu)
    static let tools: [Command] = Tool.allCases.map { tool in
        Command(tool.title, #selector(W.selectToolAction(_:)), symbol: tool.symbol,
                shortcut: tool.rawValue < 9 ? Shortcut("\(tool.rawValue + 1)") : nil, tag: tool.rawValue)
    }
    static func tool(_ t: Tool) -> Command { tools[t.rawValue] }
    static let markupTools = tools.filter { !(Tool(rawValue: $0.tag)?.isFormField ?? false) }
    static let formTools = tools.filter { Tool(rawValue: $0.tag)?.isFormField ?? false }

    // File
    static let exportProtected = Command(L("Export with Password…"), #selector(W.exportWithPasswordAction(_:)), symbol: "lock.doc")
    static let exportImages = Command(L("Export Pages as Images…"), #selector(W.exportPNGAction(_:)), symbol: "photo")
    static let exportAs = Command(L("Export As…"), #selector(W.exportAsAction(_:)), symbol: "square.and.arrow.up",
                                  shortcut: Shortcut("e", [.command, .shift]))
    static let recognizeText = Command(L("Recognize Text (OCR)…"), #selector(W.recognizeTextAction(_:)), symbol: "text.viewfinder",
                                       shortcut: Shortcut("t", [.command, .option]))
    static let reduceSize = Command(L("Reduce File Size…"), #selector(W.reduceSizeAction(_:)), symbol: "arrow.down.right.and.arrow.up.left")
    static let printSelected = Command(L("Print Selected Pages…"), #selector(W.printSelectedPagesAction(_:)), symbol: "printer",
                                       shortcut: Shortcut("p", [.command, .option]))
    static let print = Command(L("Print…"), #selector(NSDocument.printDocument(_:)), symbol: "printer", toolTip: L("Print"), label: L("Print"))
    static let createFromImages = Command(L("New PDF from Images…"), #selector(A.newFromImagesAction(_:)), symbol: "photo.stack")
    static let mergeFiles = Command(L("Merge Files…"), #selector(A.mergeFilesAction(_:)), symbol: "doc.on.doc",
                                    shortcut: Shortcut("m", [.command, .option]))
    static let split = Command(L("Split…"), #selector(W.splitAction(_:)), symbol: "scissors")
    static let compare = Command(L("Compare With…"), #selector(W.compareAction(_:)), symbol: "doc.text.magnifyingglass",
                                 toolTip: L("Compare the text with another PDF"), label: L("Compare"))
    static let applyRedactions = Command(L("Apply Redactions…"), #selector(W.applyRedactionsAction(_:)), symbol: "checkmark.rectangle")
    static let clearCompare = Command(L("Remove Comparison Highlights"), #selector(W.clearCompareHighlightsAction(_:)))

    // Edit
    static let deleteAnnotation = Command(L("Delete Annotation"), #selector(W.deleteSelectedAnnotation(_:)),
                                          shortcut: Shortcut(Shortcut.backspace))
    static let replaceText = Command(L("Edit Selected Text…"), #selector(W.replaceSelectedTextAction(_:)),
                                     symbol: "character.cursor.ibeam", shortcut: Shortcut("e"),
                                     toolTip: L("Edit selected text"), label: L("Edit Text"))
    static let highlightSelection = Command(L("Highlight Selection"), #selector(W.highlightSelectionAction(_:)), symbol: "highlighter",
                                            shortcut: Shortcut("h", [.command, .control]))
    static let find = Command(L("Find…"), #selector(W.focusSearchAction(_:)), shortcut: Shortcut("f"))
    static let findNext = Command(L("Find Next"), #selector(W.findNextAction(_:)), shortcut: Shortcut("g"))
    static let findPrevious = Command(L("Find Previous"), #selector(W.findPreviousAction(_:)), shortcut: Shortcut("g", [.command, .shift]))

    // View
    static let zoomIn = Command(L("Zoom In"), #selector(W.zoomInAction(_:)), symbol: "plus.magnifyingglass", shortcut: Shortcut("+"))
    static let zoomOut = Command(L("Zoom Out"), #selector(W.zoomOutAction(_:)), symbol: "minus.magnifyingglass", shortcut: Shortcut("-"))
    static let actualSize = Command(L("Actual Size"), #selector(W.actualSizeAction(_:)), shortcut: Shortcut("0"))
    static let zoomToFit = Command(L("Whole Page"), #selector(W.zoomToFitAction(_:)), shortcut: Shortcut("0", [.command, .option]))
    static let fitWidth = Command(L("Fit Width"), #selector(W.fitWidthAction(_:)), shortcut: Shortcut("9", [.command, .option]))
    static let displayModes: [Command] = [
        (L("Single Page"), 0), (L("Continuous Scroll"), 1), (L("Two Pages"), 2), (L("Two Pages, Continuous"), 3),
    ].map { Command($0.0, #selector(W.setDisplayModeAction(_:)), tag: $0.1) }
    static let thumbnails = Command(L("Thumbnails"), #selector(W.showThumbnailsAction(_:)), shortcut: Shortcut("1", [.command, .option]))
    static let outline = Command(L("Contents"), #selector(W.showOutlineAction(_:)), shortcut: Shortcut("2", [.command, .option]))
    static let nextPage = Command(L("Next Page"), #selector(W.nextPageAction(_:)), shortcut: Shortcut(Shortcut.downArrow, [.command, .option]))
    static let previousPage = Command(L("Previous Page"), #selector(W.previousPageAction(_:)), shortcut: Shortcut(Shortcut.upArrow, [.command, .option]))
    static let goToPage = Command(L("Go to Page…"), #selector(W.goToPageAction(_:)), shortcut: Shortcut("g", [.command, .option]))
    static let markupBar = Command(L("Show Markup Toolbar"), #selector(W.toggleMarkupAction(_:)), symbol: "pencil.tip.crop.circle",
                                   shortcut: Shortcut("a", [.command, .shift]), toolTip: L("Markup"), label: L("Markup"))

    // Insert
    static let stamps = Command(L("Signature or Stamp…"), #selector(W.showStampsAction(_:)), symbol: "signature",
                                shortcut: Shortcut("k", [.command, .shift]), toolTip: L("Insert a signature or stamp"), label: L("Signature"))
    static let insertImage = Command(L("Image from File…"), #selector(W.insertImageAction(_:)), symbol: "photo.badge.plus",
                                     shortcut: Shortcut("i", [.command, .shift]))
    static let insertBlank = Command(L("Blank Page"), #selector(W.insertBlankPageAction(_:)), symbol: "doc.badge.plus",
                                     shortcut: Shortcut("n", [.command, .shift]))
    static let insertFromFile = Command(L("Pages from File…"), #selector(W.insertFromFileAction(_:)), symbol: "doc.on.doc",
                                        shortcut: Shortcut("i", [.command, .option]))

    // Page
    static let rotateLeft = Command(L("Rotate Left"), #selector(W.rotateLeftAction(_:)), symbol: "rotate.left", shortcut: Shortcut("l"))
    static let rotateRight = Command(L("Rotate Right"), #selector(W.rotateRightAction(_:)), symbol: "rotate.right", shortcut: Shortcut("r"))
    static let deletePages = Command(L("Delete Pages"), #selector(W.deletePagesAction(_:)), symbol: "trash",
                                     shortcut: Shortcut(Shortcut.backspace, [.command, .option]))
    static let movePageUp = Command(L("Move Up"), #selector(W.movePageUpAction(_:)), shortcut: Shortcut(Shortcut.upArrow, [.command, .shift]))
    static let movePageDown = Command(L("Move Down"), #selector(W.movePageDownAction(_:)), shortcut: Shortcut(Shortcut.downArrow, [.command, .shift]))
    static let watermark = Command(L("Watermark…"), #selector(W.watermarkAction(_:)), symbol: "drop.halffull",
                                   toolTip: L("Add a watermark"), label: L("Watermark"))
    static let pageNumbers = Command(L("Page Numbers…"), #selector(W.pageNumbersAction(_:)), symbol: "number")
    static let removeWatermarks = Command(L("Remove Watermarks and Page Numbers"), #selector(W.removeWatermarksAction(_:)))
    static let extractPages = Command(L("Extract to New Document"), #selector(W.extractPagesAction(_:)), shortcut: Shortcut("e", [.command, .option]))

    // Signature
    static let sign = Command(L("Sign Document…"), #selector(W.signDocumentAction(_:)), symbol: "checkmark.seal",
                              shortcut: Shortcut("d", [.command, .option]), toolTip: L("Add a digital signature"), label: L("Sign"))
    static let verify = Command(L("Verify Signatures"), #selector(W.verifySignaturesAction(_:)), shortcut: Shortcut("v", [.command, .option]))
    static let importCertificate = Command(L("Import Certificate (.p12)…"), #selector(A.importCertificateAction(_:)))
    static let createCertificate = Command(L("Create Self-Signed Certificate…"), #selector(A.createCertificateAction(_:)))

    static let welcome = Command(L("Welcome Window"), #selector(A.showWelcomeAction(_:)), shortcut: Shortcut("0", [.command, .shift]))
    static let shortcuts = Command(L("PDF42 Keyboard Shortcuts"), #selector(A.showShortcutsAction(_:)))

    static var menuBar: MenuBarSpec {
        var spec = MenuBarSpec(appName: "PDF42")
        spec.fileExtras = [.command(exportAs), .command(exportImages), .command(exportProtected), .command(reduceSize), .separator,
                           .command(createFromImages), .command(mergeFiles), .command(split), .separator,
                           .command(compare), .command(clearCompare), .separator,
                           .command(recognizeText), .separator, .command(printSelected)]
        spec.editExtras = [.command(tool(.editText)), .command(replaceText), .command(highlightSelection), .command(deleteAnnotation)]
        spec.find = [.command(find), .command(findNext), .command(findPrevious)]
        spec.view = [.command(thumbnails), .command(outline), .separator,
                     .command(zoomIn), .command(zoomOut), .command(actualSize), .command(zoomToFit), .command(fitWidth), .separator]
            + displayModes.menuElements
            + [.separator, .command(nextPage), .command(previousPage), .command(goToPage), .separator, .command(markupBar)]
        spec.insert = [.command(stamps), .command(insertImage), .separator,
                       .command(tool(.text)), .command(tool(.note)), .separator,
                       .command(insertBlank), .command(insertFromFile)]
        spec.custom = [
            (L("Markup"), markupTools.menuElements + [.separator, .command(applyRedactions)]),
            (L("Form"), formTools.menuElements),
            (L("Page"), [.command(rotateLeft), .command(rotateRight), .separator,
                          .command(deletePages), .command(movePageUp), .command(movePageDown), .separator,
                          .command(extractPages), .separator,
                          .command(watermark), .command(pageNumbers), .command(removeWatermarks)]),
            (L("Signature"), [.command(sign), .command(verify), .separator,
                         .command(importCertificate), .command(createCertificate)]),
        ]
        spec.help = [.command(shortcuts), .command(welcome)]
        return spec
    }

    static let toolbar: [ToolbarElement] = [
        .toggleSidebar, .sidebarSeparator,
        .flexibleSpace,
        .group(id: "zoom", label: L("Zoom"), [zoomOut, zoomIn]),
        .command(rotateLeft),
        .command(markupBar),
        .command(stamps),
        .command(sign),
        .command(print),
        .search(id: "search", placeholder: L("Search"), action: #selector(W.searchChanged(_:))),
    ]
}
