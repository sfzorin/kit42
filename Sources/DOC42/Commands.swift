import AppKit
import Kit42

enum Cmd {
    typealias W = DocWindowController
    typealias A = AppDelegate

    static let exportPDF = Command(L("Export as PDF…"), #selector(W.exportPDFAction(_:)), symbol: "doc.richtext", shortcut: Shortcut("e", [.command, .option]))

    static let exportAs = Command(L("Export As…"), #selector(W.exportAsAction(_:)), shortcut: Shortcut("e", [.command, .shift]))
    static let find = Command(L("Find…"), #selector(W.findAction(_:)), shortcut: Shortcut("f"))

    static let zoomIn = Command(L("Zoom In"), #selector(W.zoomInAction(_:)), symbol: "plus.magnifyingglass", shortcut: Shortcut("+"))
    static let zoomOut = Command(L("Zoom Out"), #selector(W.zoomOutAction(_:)), symbol: "minus.magnifyingglass", shortcut: Shortcut("-"))
    static let actualSize = Command(L("Actual Size"), #selector(W.actualSizeAction(_:)), shortcut: Shortcut("0"))
    static let formatBar = Command(L("Hide Format Bar"), #selector(W.toggleFormatBarAction(_:)), symbol: "textformat",
                                   shortcut: Shortcut("a", [.command, .shift]), toolTip: L("Format bar"), label: L("Format"))
    static let ruler = Command(L("Show Ruler"), #selector(W.toggleRulerAction(_:)), shortcut: Shortcut("r", [.command, .option]))

    static let insertImage = Command(L("Image…"), #selector(W.insertImageAction(_:)), symbol: "photo", shortcut: Shortcut("i", [.command, .shift]))
    static let insertTable = Command(L("Table…"), #selector(W.insertTableAction(_:)), symbol: "tablecells", shortcut: Shortcut("t", [.command, .option]))
    static let stamps = Command(L("Signature or Stamp…"), #selector(W.showStampsAction(_:)), symbol: "signature",
                                shortcut: Shortcut("k", [.command, .shift]), toolTip: L("Insert a signature or stamp"), label: L("Signature"))
    static let pageBreak = Command(L("Page Break"), #selector(W.insertPageBreakAction(_:)), shortcut: Shortcut("\r", [.command, .shift]))
    static let date = Command(L("Date"), #selector(W.insertDateAction(_:)))

    static let bold = Command(L("Bold"), #selector(W.toggleBold(_:)), symbol: "bold", shortcut: Shortcut("b"))
    static let italic = Command(L("Italic"), #selector(W.toggleItalic(_:)), symbol: "italic", shortcut: Shortcut("i"))
    static let underline = Command(L("Underline"), #selector(W.toggleUnderline(_:)), symbol: "underline", shortcut: Shortcut("u"))
    static let strike = Command(L("Strikethrough"), #selector(W.toggleStrike(_:)), symbol: "strikethrough", shortcut: Shortcut("x", [.command, .shift]))
    static let bigger = Command(L("Bigger"), #selector(W.biggerAction(_:)), shortcut: Shortcut(".", [.command, .shift]))
    static let smaller = Command(L("Smaller"), #selector(W.smallerAction(_:)), shortcut: Shortcut(",", [.command, .shift]))
    static let alignLeft = Command(L("Align Left"), #selector(W.alignAction(_:)), symbol: "text.alignleft", shortcut: Shortcut("{"), tag: 0)
    static let alignCenter = Command(L("Align Center"), #selector(W.alignAction(_:)), symbol: "text.aligncenter", shortcut: Shortcut("|"), tag: 1)
    static let alignRight = Command(L("Align Right"), #selector(W.alignAction(_:)), symbol: "text.alignright", shortcut: Shortcut("}"), tag: 2)
    static let justify = Command(L("Justify"), #selector(W.alignAction(_:)), symbol: "text.justify", tag: 3)
    static let bulletList = Command(L("Bulleted List"), #selector(W.bulletListAction(_:)), symbol: "list.bullet", shortcut: Shortcut("7", [.command, .shift]))
    static let numberedList = Command(L("Numbered List"), #selector(W.numberedListAction(_:)), symbol: "list.number", shortcut: Shortcut("8", [.command, .shift]))
    static let indent = Command(L("Increase Indent"), #selector(W.indentAction(_:)), symbol: "increase.indent", shortcut: Shortcut("]"))
    static let outdent = Command(L("Decrease Indent"), #selector(W.outdentAction(_:)), symbol: "decrease.indent", shortcut: Shortcut("["))
    static let removeHighlight = Command(L("Remove Highlight"), #selector(W.removeHighlightAction(_:)))
    static let clearFormatting = Command(L("Clear Formatting"), #selector(W.clearFormattingAction(_:)))
    static var styles: [Command] {
        Styles.all.enumerated().map { i, s in
            Command(s.name, #selector(W.applyStyleAction(_:)), shortcut: i < 4 ? Shortcut("\(i + 1)", [.command, .option]) : nil, tag: i)
        }
    }
    static let lineSpacing: [Command] = ["1.0", "1.15", "1.5", "2.0"].enumerated().map {
        Command($0.element, #selector(W.lineSpacingAction(_:)), tag: $0.offset)
    }

    static let welcome = Command(L("Welcome Window"), #selector(A.showWelcomeAction(_:)), shortcut: Shortcut("0", [.command, .shift]))

    static var menuBar: MenuBarSpec {
        var spec = MenuBarSpec(appName: "DOC42")
        spec.fileExtras = [.command(exportPDF), .command(exportAs)]
        spec.find = [.command(find)]
        spec.view = [.command(zoomIn), .command(zoomOut), .command(actualSize), .separator, .command(formatBar), .command(ruler)]
        spec.insert = [.command(insertImage), .command(insertTable), .command(stamps), .separator, .command(pageBreak), .command(date)]
        spec.format = [.submenu(L("Style"), styles.menuElements), .separator,
                       .command(bold), .command(italic), .command(underline), .command(strike), .command(bigger), .command(smaller), .separator,
                       .command(alignLeft), .command(alignCenter), .command(alignRight), .command(justify), .separator,
                       .command(bulletList), .command(numberedList), .command(indent), .command(outdent),
                       .submenu(L("Line Spacing"), lineSpacing.menuElements), .separator,
                       .command(removeHighlight), .command(clearFormatting)]
        spec.help = [.command(welcome)]
        return spec
    }

    static var toolbar: [ToolbarElement] {
        [
            .command(insertImage), .command(insertTable), .command(stamps),
            .flexibleSpace,
            .group(id: "zoom", label: L("Zoom"), [zoomOut, zoomIn]),
            .command(formatBar), .command(exportPDF),
            .search(id: "search", placeholder: L("Search"), action: #selector(W.searchChanged(_:))),
        ]
    }
}
