import AppKit
import Kit42

/// Every PPT42 action, defined once for menus, toolbar and format strip.
enum Cmd {
    typealias W = DeckWindowController
    typealias A = AppDelegate

    // File
    static let exportPDF = Command(L("Export as PDF…"), #selector(W.exportPDFAction(_:)), symbol: "doc.richtext", shortcut: Shortcut("e", [.command, .option]))
    static let exportNotesPDF = Command(L("Export Notes Pages as PDF…"), #selector(W.exportNotesPDFAction(_:)))
    static let exportImages = Command(L("Export Images…"), #selector(W.exportImagesAction(_:)), symbol: "photo.on.rectangle")
    static let exportMovie = Command(L("Export as Movie…"), #selector(W.exportMovieAction(_:)), symbol: "film")
    static let exportOutline = Command(L("Export Outline…"), #selector(W.exportOutlineAction(_:)))

    // Edit
    static let duplicate = Command(L("Duplicate Selection"), #selector(W.duplicateAction(_:)), shortcut: Shortcut("d"))
    static let delete = Command(L("Delete"), #selector(W.deleteAction(_:)), shortcut: Shortcut(Shortcut.backspace, []))
    static let find = Command(L("Find and Replace…"), #selector(W.findAction(_:)), symbol: "text.magnifyingglass", shortcut: Shortcut("f"))
    static let findNext = Command(L("Find Next"), #selector(W.findNextAction(_:)), shortcut: Shortcut("g"))
    static let findPrevious = Command(L("Find Previous"), #selector(W.findPreviousAction(_:)), shortcut: Shortcut("g", [.command, .shift]))

    // View
    static let viewModes: [Command] = [
        Command(L("Normal"), #selector(W.viewModeAction(_:)), symbol: "rectangle.on.rectangle", shortcut: Shortcut("1", [.command, .option]), tag: 0),
        Command(L("Outline"), #selector(W.viewModeAction(_:)), symbol: "list.bullet.indent", shortcut: Shortcut("2", [.command, .option]), tag: 1),
        Command(L("Slide Sorter"), #selector(W.viewModeAction(_:)), symbol: "square.grid.3x2", shortcut: Shortcut("3", [.command, .option]), tag: 2),
        Command(L("Notes Page"), #selector(W.viewModeAction(_:)), symbol: "note.text", shortcut: Shortcut("4", [.command, .option]), tag: 3),
        Command(L("Master"), #selector(W.viewModeAction(_:)), symbol: "rectangle.stack", shortcut: Shortcut("5", [.command, .option]), tag: 4),
    ]
    static let notesPane = Command(L("Notes Pane"), #selector(W.toggleNotesAction(_:)), symbol: "note.text", shortcut: Shortcut("n", [.command, .option]))
    static let inspector = Command(L("Inspector"), #selector(W.toggleInspectorAction(_:)), symbol: "sidebar.right", shortcut: Shortcut("i", [.command, .option]),
                                   toolTip: L("Show or hide the inspector"), label: L("Inspector"))
    static let formatBar = Command(L("Format Bar"), #selector(W.toggleFormatBarAction(_:)), symbol: "textformat", shortcut: Shortcut("a", [.command, .shift]),
                                   toolTip: L("Show or hide the format bar"), label: L("Format"))
    static let zoomIn = Command(L("Zoom In"), #selector(W.zoomInAction(_:)), symbol: "plus.magnifyingglass", shortcut: Shortcut("+"))
    static let zoomOut = Command(L("Zoom Out"), #selector(W.zoomOutAction(_:)), symbol: "minus.magnifyingglass", shortcut: Shortcut("-"))
    static let zoomFit = Command(L("Zoom to Fit"), #selector(W.zoomFitAction(_:)), symbol: "arrow.up.left.and.down.right.magnifyingglass", shortcut: Shortcut("0", [.command, .option]))
    static let actualSize = Command(L("Actual Size"), #selector(W.actualSizeAction(_:)), shortcut: Shortcut("0"))
    static let guides = Command(L("Snap to Guides"), #selector(W.toggleGuidesAction(_:)))

    // Insert
    static let newSlide = Command(L("New Slide"), #selector(W.newSlideAction(_:)), symbol: "plus.rectangle.on.rectangle", shortcut: Shortcut("n", [.command, .shift]),
                                  toolTip: L("Add a slide (choose a layout)"), label: L("New Slide"))
    static let duplicateSlide = Command(L("Duplicate Slide"), #selector(W.duplicateSlideAction(_:)), symbol: "plus.square.on.square", shortcut: Shortcut("d", [.command, .shift]))
    static let deleteSlide = Command(L("Delete Slide"), #selector(W.deleteSlideAction(_:)), symbol: "trash")
    static let textBox = Command(L("Text Box"), #selector(W.insertTextBoxAction(_:)), symbol: "character.textbox", shortcut: Shortcut("t", [.command, .shift]),
                                 toolTip: L("Insert a text box"), label: L("Text"))
    static let shape = Command(L("Shape"), #selector(W.insertShapeMenuAction(_:)), symbol: "square.on.circle", toolTip: L("Insert a shape"), label: L("Shape"))
    static var shapes: [Command] {
        Shapes.gallery.enumerated().map { Command($0.element.name, #selector(W.insertShapeAction(_:)), tag: $0.offset) }
    }
    /// Insert › Shape: one submenu per gallery section.
    static var shapeMenu: [MenuElement] {
        let all = shapes
        return Shapes.sections.enumerated().map { k, name in
            .submenu(name, Shapes.gallery.indices.filter { Shapes.gallery[$0].section == k }.map { .command(all[$0]) })
        }
    }
    static let image = Command(L("Image…"), #selector(W.insertImageAction(_:)), symbol: "photo", shortcut: Shortcut("i", [.command, .shift]),
                               toolTip: L("Insert an image"), label: L("Picture"))
    static let table = Command(L("Table…"), #selector(W.insertTableAction(_:)), symbol: "tablecells", shortcut: Shortcut("t", [.command, .option, .shift]),
                               toolTip: L("Insert a table"), label: L("Table"))
    static let chart = Command(L("Chart…"), #selector(W.insertChartAction(_:)), symbol: "chart.bar", shortcut: Shortcut("c", [.command, .option, .shift]),
                               toolTip: L("Insert a chart"), label: L("Chart"))
    static let media = Command(L("Video or Audio…"), #selector(W.insertMediaAction(_:)), symbol: "film", toolTip: L("Insert a video or audio file"), label: L("Media"))
    static let comment = Command(L("Comment"), #selector(W.insertCommentAction(_:)), symbol: "text.bubble", shortcut: Shortcut("m", [.command, .option]))
    static let stamps = Command(L("Signature or Stamp…"), #selector(W.showStampsAction(_:)), symbol: "signature", shortcut: Shortcut("k", [.command, .shift]))
    static let slideNumber = Command(L("Slide Number"), #selector(W.insertSlideNumberAction(_:)), symbol: "number")
    static let date = Command(L("Date"), #selector(W.insertDateAction(_:)), symbol: "calendar")
    static let tableRows: [Command] = [(L("Insert Row Above"), "arrow.up.to.line"), (L("Insert Row Below"), "arrow.down.to.line"), (L("Delete Row"), "minus.rectangle")]
        .enumerated().map { Command($0.element.0, #selector(W.tableRowAction(_:)), symbol: $0.element.1, tag: $0.offset) }
    static let tableColumns: [Command] = [(L("Insert Column Left"), "arrow.left.to.line"), (L("Insert Column Right"), "arrow.right.to.line"), (L("Delete Column"), "minus.rectangle.portrait")]
        .enumerated().map { Command($0.element.0, #selector(W.tableColumnAction(_:)), symbol: $0.element.1, tag: $0.offset) }

    // Format: font
    static let bold = Command(L("Bold"), #selector(W.boldAction(_:)), symbol: "bold", shortcut: Shortcut("b"))
    static let italic = Command(L("Italic"), #selector(W.italicAction(_:)), symbol: "italic", shortcut: Shortcut("i"))
    static let underline = Command(L("Underline"), #selector(W.underlineAction(_:)), symbol: "underline", shortcut: Shortcut("u"))
    static let strike = Command(L("Strikethrough"), #selector(W.strikeAction(_:)), symbol: "strikethrough", shortcut: Shortcut("x", [.command, .shift]))
    static let bigger = Command(L("Bigger"), #selector(W.biggerAction(_:)), shortcut: Shortcut(".", [.command, .shift]))
    static let smaller = Command(L("Smaller"), #selector(W.smallerAction(_:)), shortcut: Shortcut(",", [.command, .shift]))
    static let superscript = Command(L("Superscript"), #selector(W.baselineAction(_:)), tag: 1)
    static let subscriptCmd = Command(L("Subscript"), #selector(W.baselineAction(_:)), tag: -1)
    static let clearFormatting = Command(L("Clear Formatting"), #selector(W.clearFormattingAction(_:)))

    // Format: paragraph
    static let alignLeft = Command(L("Align Left"), #selector(W.alignTextAction(_:)), symbol: "text.alignleft", shortcut: Shortcut("{"), tag: 0)
    static let alignCenter = Command(L("Align Center"), #selector(W.alignTextAction(_:)), symbol: "text.aligncenter", shortcut: Shortcut("|"), tag: 1)
    static let alignRight = Command(L("Align Right"), #selector(W.alignTextAction(_:)), symbol: "text.alignright", shortcut: Shortcut("}"), tag: 2)
    static let justify = Command(L("Justify"), #selector(W.alignTextAction(_:)), symbol: "text.justify", tag: 3)
    static let anchors: [Command] = [
        Command(L("Top"), #selector(W.anchorAction(_:)), symbol: "arrow.up.to.line", tag: 0),
        Command(L("Middle"), #selector(W.anchorAction(_:)), symbol: "arrow.up.and.down", tag: 1),
        Command(L("Bottom"), #selector(W.anchorAction(_:)), symbol: "arrow.down.to.line", tag: 2),
    ]
    static let bullets = Command(L("Bulleted List"), #selector(W.bulletsAction(_:)), symbol: "list.bullet", shortcut: Shortcut("7", [.command, .shift]), tag: 1)
    static let numbering = Command(L("Numbered List"), #selector(W.bulletsAction(_:)), symbol: "list.number", shortcut: Shortcut("8", [.command, .shift]), tag: 2)
    static let noBullets = Command(L("No Bullets"), #selector(W.bulletsAction(_:)), symbol: "text.justify.left", tag: 0)
    static let indent = Command(L("Increase Indent"), #selector(W.indentAction(_:)), symbol: "increase.indent", shortcut: Shortcut("]"), tag: 1)
    static let outdent = Command(L("Decrease Indent"), #selector(W.indentAction(_:)), symbol: "decrease.indent", shortcut: Shortcut("["), tag: -1)
    static let lineSpacing: [Command] = ["0.9", "1.0", "1.15", "1.5", "2.0"].enumerated().map {
        Command($0.element, #selector(W.lineSpacingAction(_:)), tag: $0.offset)
    }

    // Format: arrange, align, group
    static let bringToFront = Command(L("Bring to Front"), #selector(W.arrangeAction(_:)), symbol: "square.3.layers.3d.top.filled", shortcut: Shortcut("f", [.command, .shift]), tag: 0)
    static let bringForward = Command(L("Bring Forward"), #selector(W.arrangeAction(_:)), symbol: "square.2.layers.3d.top.filled", shortcut: Shortcut("f", [.command, .option]), tag: 1)
    static let sendBackward = Command(L("Send Backward"), #selector(W.arrangeAction(_:)), symbol: "square.2.layers.3d.bottom.filled", shortcut: Shortcut("b", [.command, .option]), tag: 2)
    static let sendToBack = Command(L("Send to Back"), #selector(W.arrangeAction(_:)), symbol: "square.3.layers.3d.bottom.filled", shortcut: Shortcut("b", [.command, .shift]), tag: 3)
    static var arrange: [Command] { [bringToFront, bringForward, sendBackward, sendToBack] }
    static let alignObjects: [Command] = [
        Command(L("Align Left Edges"), #selector(W.alignObjectsAction(_:)), symbol: "align.horizontal.left", tag: 0),
        Command(L("Align Centers"), #selector(W.alignObjectsAction(_:)), symbol: "align.horizontal.center", tag: 1),
        Command(L("Align Right Edges"), #selector(W.alignObjectsAction(_:)), symbol: "align.horizontal.right", tag: 2),
        Command(L("Align Top Edges"), #selector(W.alignObjectsAction(_:)), symbol: "align.vertical.top", tag: 3),
        Command(L("Align Middles"), #selector(W.alignObjectsAction(_:)), symbol: "align.vertical.center", tag: 4),
        Command(L("Align Bottom Edges"), #selector(W.alignObjectsAction(_:)), symbol: "align.vertical.bottom", tag: 5),
    ]
    static let distribute: [Command] = [
        Command(L("Distribute Horizontally"), #selector(W.distributeAction(_:)), symbol: "distribute.horizontal.center", tag: 0),
        Command(L("Distribute Vertically"), #selector(W.distributeAction(_:)), symbol: "distribute.vertical.center", tag: 1),
    ]
    static let group = Command(L("Group"), #selector(W.groupAction(_:)), symbol: "square.on.square.dashed", shortcut: Shortcut("g", [.command, .option]))
    static let convertToShapes = Command(L("Convert to Shapes"), #selector(W.convertToShapesAction(_:)), symbol: "square.on.square.squareshape.controlhandles")
    static let ungroup = Command(L("Ungroup"), #selector(W.ungroupAction(_:)), shortcut: Shortcut("g", [.command, .option, .shift]))

    // Slide
    static var layouts: [Command] { [] }
    static let newLayout = Command(L("New Layout"), #selector(W.newLayoutAction(_:)), symbol: "rectangle.badge.plus")
    static let duplicateLayout = Command(L("Duplicate Layout"), #selector(W.duplicateLayoutAction(_:)))
    static let renameLayout = Command(L("Rename Layout…"), #selector(W.renameLayoutAction(_:)))
    static let deleteLayout = Command(L("Delete Layout"), #selector(W.deleteLayoutAction(_:)))
    static let placeholders: [Command] = [L("Content"), L("Text"), L("Picture"), L("Title")].enumerated().map {
        Command($0.element, #selector(W.insertPlaceholderAction(_:)), tag: $0.offset)
    }
    static let background = Command(L("Background…"), #selector(W.backgroundAction(_:)), symbol: "paintbrush")
    static let hideSlide = Command(L("Hide Slide"), #selector(W.hideSlideAction(_:)), symbol: "eye.slash")
    static let transitions: [Command] = TransitionKind.allCases.enumerated().map {
        Command(Transitions.name($0.element), #selector(W.transitionAction(_:)), tag: $0.offset)
    }
    static let slideSizes: [Command] = [
        Command(L("Widescreen 16:9"), #selector(W.slideSizeAction(_:)), symbol: "rectangle", tag: 0),
        Command(L("Standard 4:3"), #selector(W.slideSizeAction(_:)), symbol: "rectangle.portrait", tag: 1),
    ]
    static var themes: [Command] {
        Themes.all.enumerated().map { Command(L($0.element.theme.name), #selector(W.themeAction(_:)), tag: $0.offset) }
    }

    // Slide Show
    static let play = Command(L("Play from Start"), #selector(W.playAction(_:)), symbol: "play.fill", shortcut: Shortcut("p", [.command, .option]),
                              toolTip: L("Play the slide show from the first slide"), label: L("Play"))
    static let playCurrent = Command(L("Play from Current Slide"), #selector(W.playCurrentAction(_:)), symbol: "play", shortcut: Shortcut("p", [.command, .shift]))
    static let playInWindow = Command(L("Present in Window"), #selector(W.playInWindowAction(_:)), symbol: "macwindow")
    static let rehearse = Command(L("Rehearse with Presenter View"), #selector(W.rehearseAction(_:)), symbol: "person.wave.2", shortcut: Shortcut("r", [.command, .option]))
    static let showSettings = Command(L("Slide Show Settings…"), #selector(W.showSettingsAction(_:)), symbol: "gearshape")

    static let newFromTemplate = Command(L("New from Template…"), #selector(A.newFromTemplateAction(_:)), symbol: "square.grid.2x2", shortcut: Shortcut("n", [.command, .option, .shift]))
    static let welcome = Command(L("Welcome Window"), #selector(A.showWelcomeAction(_:)), shortcut: Shortcut("0", [.command, .shift]))

    static func menuBar(layoutsMenu: NSMenuDelegate) -> MenuBarSpec {
        var spec = MenuBarSpec(appName: "PPT42")
        spec.fileExtras = [.command(newFromTemplate), .separator, .command(exportPDF), .command(exportNotesPDF), .command(exportImages), .command(exportMovie), .command(exportOutline)]
        spec.editExtras = [.command(duplicate), .command(delete)]
        spec.find = [.command(find), .separator, .command(findNext), .command(findPrevious)]
        let layoutItem = NSMenuItem(title: L("Layout"), action: nil, keyEquivalent: "")
        layoutItem.submenu = NSMenu(title: L("Layout"))
        layoutItem.submenu?.delegate = layoutsMenu
        layoutItem.submenu?.identifier = NSUserInterfaceItemIdentifier("layouts")
        let newSlideItem = NSMenuItem(title: L("New Slide with Layout"), action: nil, keyEquivalent: "")
        newSlideItem.submenu = NSMenu(title: L("New Slide with Layout"))
        newSlideItem.submenu?.delegate = layoutsMenu
        newSlideItem.submenu?.identifier = NSUserInterfaceItemIdentifier("newSlideLayouts")
        spec.view = viewModes.menuElements + [.separator, .command(notesPane), .command(inspector), .command(formatBar), .separator,
                                              .command(zoomIn), .command(zoomOut), .command(zoomFit), .command(actualSize), .separator, .command(guides)]
        spec.insert = [.command(newSlide), .item(newSlideItem), .command(duplicateSlide), .command(deleteSlide), .separator,
                       .command(textBox), .submenu(L("Shape"), shapeMenu), .command(image), .command(table), .command(chart), .command(media), .command(stamps), .separator,
                       .command(slideNumber), .command(date), .separator, .command(comment)]
        spec.format = [
            .submenu(L("Font"), [.command(bold), .command(italic), .command(underline), .command(strike), .separator,
                                 .command(bigger), .command(smaller), .separator, .command(superscript), .command(subscriptCmd), .separator, .command(clearFormatting)]),
            .submenu(L("Paragraph"), [.command(alignLeft), .command(alignCenter), .command(alignRight), .command(justify), .separator]
                     + anchors.menuElements + [.separator, .submenu(L("Line Spacing"), lineSpacing.menuElements)]),
            .submenu(L("Bullets"), [.command(bullets), .command(numbering), .command(noBullets), .separator, .command(indent), .command(outdent)]),
            .separator,
            .submenu(L("Arrange"), arrange.menuElements),
            .submenu(L("Align"), alignObjects.menuElements + [.separator] + distribute.menuElements),
            .command(group), .command(ungroup), .command(convertToShapes),
            .separator,
            .submenu(L("Table"), tableRows.menuElements + [.separator] + tableColumns.menuElements),
        ]
        spec.custom = [
            (L("Slide"), [.command(newSlide), .command(duplicateSlide), .command(deleteSlide), .separator, .item(layoutItem), .command(background),
                          .submenu(L("Transition"), transitions.menuElements), .command(hideSlide), .separator,
                          .submenu(L("Theme"), themes.menuElements), .submenu(L("Slide Size"), slideSizes.menuElements), .separator,
                          .submenu(L("Master Layouts"), [.command(newLayout), .command(duplicateLayout), .command(renameLayout), .command(deleteLayout), .separator,
                                                         .submenu(L("Insert Placeholder"), placeholders.menuElements)])]),
            (L("Slide Show"), [.command(play), .command(playCurrent), .command(playInWindow), .command(rehearse), .separator, .command(showSettings)]),
        ]
        spec.help = [.command(welcome)]
        return spec
    }
}

enum Transitions {
    static func name(_ k: TransitionKind) -> String {
        switch k {
        case .none: return L("None")
        case .fade: return L("Fade")
        case .push: return L("Push")
        case .wipe: return L("Wipe")
        case .cover: return L("Cover")
        case .dissolve: return L("Dissolve")
        case .split: return L("Split")
        case .zoom: return L("Zoom")
        }
    }
}
