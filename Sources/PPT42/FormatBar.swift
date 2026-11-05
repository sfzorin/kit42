import AppKit
import Kit42
import UniformTypeIdentifiers

/// Format strip under the toolbar: font, size, style, colour, paragraph, fill/line, arrange.
final class FormatBar: NSObject {
    weak var owner: DeckWindowController?
    private(set) lazy var fontPopup = stripPopUp(InspectorController.fonts, width: 132, toolTip: L("Font"), target: self, action: #selector(fontChanged(_:)))
    private(set) lazy var sizeStepper: SizeStepper = {
        let s = SizeStepper(toolTip: L("Font size"))
        s.steps = [8, 9, 10, 11, 12, 14, 16, 18, 20, 24, 28, 32, 36, 40, 44, 48, 54, 60, 72, 96]
        s.target = self
        s.action = #selector(sizeChanged(_:))
        return s
    }()
    private lazy var textColor: ColorButton = {
        let b = ColorButton(symbol: "textformat", toolTip: L("Text colour"), color: .black, allowsNone: false)
        b.target = self
        b.action = #selector(textColorChanged(_:))
        return b
    }()
    private lazy var fillColor: ColorButton = {
        let b = ColorButton(symbol: "paintbrush.fill", toolTip: L("Fill colour"), color: nil, allowsNone: true)
        b.target = self
        b.action = #selector(fillChanged(_:))
        return b
    }()
    private lazy var lineColor: ColorButton = {
        let b = ColorButton(symbol: "pencil.tip", toolTip: L("Line colour"), color: nil, allowsNone: true)
        b.target = self
        b.action = #selector(lineChanged(_:))
        return b
    }()
    private lazy var alignButton = StripButton(symbol: "text.alignleft", toolTip: L("Alignment"),
                                               menu: commandMenu([Cmd.alignLeft, Cmd.alignCenter, Cmd.alignRight, Cmd.justify] + [Cmd.anchors[0], Cmd.anchors[1], Cmd.anchors[2]]))
    private lazy var listButton = StripButton(symbol: "list.bullet", toolTip: L("Bullets and numbering"), menu: commandMenu([Cmd.bullets, Cmd.numbering, Cmd.noBullets]))
    private lazy var spacingButton = StripButton(symbol: "arrow.up.and.down.text.horizontal", toolTip: L("Line spacing"), menu: commandMenu(Cmd.lineSpacing))
    private lazy var arrangeButton = StripButton(symbol: "square.3.layers.3d", toolTip: L("Arrange"), menu: commandMenu(Cmd.arrange + [Cmd.group, Cmd.ungroup]))
    private lazy var alignObjectsButton = StripButton(symbol: "align.horizontal.center", toolTip: L("Align objects"), menu: commandMenu(Cmd.alignObjects + Cmd.distribute))

    private(set) lazy var strip = ToolStrip([
        .group([.view(fontPopup), .view(sizeStepper)]),
        .buttons([Cmd.bold, Cmd.italic, Cmd.underline, Cmd.strike]),
        .group([.view(textColor)]),
        .group([.view(alignButton), .view(listButton), .command(Cmd.outdent), .command(Cmd.indent), .view(spacingButton)]),
        .group([.view(fillColor), .view(lineColor)]),
        .group([.view(arrangeButton), .view(alignObjectsButton)]),
    ])

    init(owner: DeckWindowController) {
        self.owner = owner
        super.init()
    }

    /// Reflects the selection's formatting.
    func sync() {
        guard let owner else { return }
        let r = owner.currentRunProps
        let deck = owner.deck
        let family = deck.theme.font(r.font) ?? deck.theme.minorFont
        if fontPopup.item(withTitle: family) == nil { fontPopup.addItem(withTitle: family) }
        fontPopup.selectItem(withTitle: family)
        sizeStepper.value = r.size ?? 18
        textColor.color = (r.color ?? PColor(scheme: "tx1")).resolved(deck.theme)
        strip.setState(r.bold == true, for: #selector(DeckWindowController.boldAction(_:)))
        strip.setState(r.italic == true, for: #selector(DeckWindowController.italicAction(_:)))
        strip.setState(r.underline == true, for: #selector(DeckWindowController.underlineAction(_:)))
        strip.setState(r.strike == true, for: #selector(DeckWindowController.strikeAction(_:)))
        let a = owner.currentLevelStyle.align ?? .left
        alignButton.setSymbol(["text.alignleft", "text.aligncenter", "text.alignright", "text.justify"][TextAlign.allCases.firstIndex(of: a) ?? 0])
        let b = owner.currentLevelStyle.bullet?.kind ?? Bullet.Kind.none
        listButton.setSymbol(b == .number ? "list.number" : "list.bullet")
        if let o = owner.selectedObjects.first {
            fillColor.color = o.fill.solidColor?.resolved(deck.theme)
            lineColor.color = o.line.color?.resolved(deck.theme)
        } else {
            fillColor.color = nil
            lineColor.color = nil
        }
    }

    @objc private func fontChanged(_ sender: NSPopUpButton) { if let f = sender.titleOfSelectedItem { owner?.setFont(f) } }
    @objc private func sizeChanged(_ sender: Any?) { owner?.setFontSize(sizeStepper.value) }
    @objc private func textColorChanged(_ sender: Any?) { if let c = textColor.color { owner?.setTextColor(PColor(c)) } }
    @objc private func fillChanged(_ sender: Any?) { owner?.setFill(fillColor.color.map { .solid(PColor($0)) } ?? .none) }
    @objc private func lineChanged(_ sender: Any?) {
        let c = lineColor.color.map { PColor($0) }
        owner?.setLine { $0.color = c }
    }
}

/// Find and Replace across slide text, tables and notes.
final class FindController: NSObject, NSWindowDelegate {
    weak var owner: DeckWindowController?
    private var panel: NSPanel?
    private let findField = NSSearchField()
    private let replaceField = NSTextField()
    private let caseBox = NSButton(checkboxWithTitle: L("Match case"), target: nil, action: nil)
    private let notesBox = NSButton(checkboxWithTitle: L("Search notes"), target: nil, action: nil)
    private let status = NSTextField(labelWithString: "")
    private struct Hit: Equatable {
        var slide: Int
        var object: Int
        var row: Int? = nil
        var column: Int? = nil
        var range: NSRange
    }
    private var lastHit: Hit?
    private var lastQuery = ""
    var statusText: String { status.stringValue }
    func closeForAudit() { panel?.orderOut(nil) }
    var query: String { findField.stringValue }
    var findFieldValue: String { get { findField.stringValue } set { findField.stringValue = newValue } }
    var replaceFieldValue: String { get { replaceField.stringValue } set { replaceField.stringValue = newValue } }

    init(owner: DeckWindowController) {
        self.owner = owner
        super.init()
    }

    func show() {
        if panel == nil { build() }
        if let sel = owner?.canvas.editor, sel.isActive, let tv = owner?.canvas.editor.textView, tv.selectedRange().length > 0 {
            findField.stringValue = (tv.string as NSString).substring(with: tv.selectedRange())
        }
        panel?.makeKeyAndOrderFront(nil)
        panel?.makeFirstResponder(findField)
    }

    private func build() {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 150), styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: true)
        p.title = L("Find and Replace")
        p.isFloatingPanel = true
        p.hidesOnDeactivate = true
        p.delegate = self
        findField.placeholderString = L("Find")
        findField.target = self
        findField.action = #selector(findNext)
        replaceField.placeholderString = L("Replace with")
        caseBox.state = .off
        notesBox.state = .on
        status.textColor = .secondaryLabelColor
        status.font = .systemFont(ofSize: 11)
        func button(_ t: String, _ s: Selector) -> NSButton {
            let b = NSButton(title: t, target: self, action: s)
            b.bezelStyle = .rounded
            return b
        }
        let buttons = NSStackView(views: [status, NSView(), button(L("Replace All"), #selector(replaceAll)), button(L("Replace"), #selector(replaceOne)),
                                          button(L("Previous"), #selector(findPrevious)), button(L("Next"), #selector(findNext))])
        buttons.spacing = 6
        let grid = NSGridView(views: [[NSTextField(labelWithString: L("Find:")), findField], [NSTextField(labelWithString: L("Replace:")), replaceField],
                                      [NSGridCell.emptyContentView, NSStackView(views: [caseBox, notesBox])]])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 8
        let stack = NSStackView(views: [grid, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        findField.translatesAutoresizingMaskIntoConstraints = false
        findField.widthAnchor.constraint(equalToConstant: 300).isActive = true
        replaceField.translatesAutoresizingMaskIntoConstraints = false
        replaceField.widthAnchor.constraint(equalToConstant: 300).isActive = true
        buttons.translatesAutoresizingMaskIntoConstraints = false
        buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
        p.contentView = stack
        p.setContentSize(stack.fittingSize)
        if let w = owner?.window { p.setFrameTopLeftPoint(NSPoint(x: w.frame.maxX - p.frame.width - 40, y: w.frame.maxY - 90)) }
        panel = p
    }

    private var options: String.CompareOptions { caseBox.state == .on ? [] : [.caseInsensitive] }

    /// Every occurrence is a separate destination, including individual table cells and notes.
    private func hits(in slide: Slide, at index: Int) -> [Hit] {
        var result: [Hit] = []
        func visit(_ objects: [SlideObject]) {
            for object in objects {
                if let text = object.text {
                    result += TextSearch.ranges(in: text, query: query, options: options).map { Hit(slide: index, object: object.id, range: $0) }
                }
                if let table = object.table {
                    for row in table.cells.indices {
                        for column in table.cells[row].indices where !table.cells[row][column].merged {
                            result += TextSearch.ranges(in: table.cells[row][column].text, query: query, options: options).map {
                                Hit(slide: index, object: object.id, row: row, column: column, range: $0)
                            }
                        }
                    }
                }
                visit(object.children)
            }
        }
        visit(slide.objects)
        if notesBox.state == .on {
            result += TextSearch.ranges(in: slide.notes, query: query, options: options).map { Hit(slide: index, object: -1, range: $0) }
        }
        return result
    }

    @objc func findNext() { find(forward: true) }
    @objc func findPrevious() { find(forward: false) }

    func find(forward: Bool) {
        guard let owner, !query.isEmpty else { return }
        owner.commitEditing()
        if lastQuery != query { lastHit = nil; lastQuery = query }
        let list = owner.deck.slides.enumerated().flatMap { hits(in: $0.element, at: $0.offset) }
        guard !list.isEmpty else { lastHit = nil; status.stringValue = L("Not found"); NSSound.beep(); return }
        let k: Int
        if let lastHit, let current = list.firstIndex(of: lastHit) { k = (current + (forward ? 1 : -1) + list.count) % list.count }
        else { k = forward ? (list.firstIndex { $0.slide >= owner.current } ?? 0) : (list.lastIndex { $0.slide <= owner.current } ?? list.count - 1) }
        let hit = list[k]
        lastHit = hit
        if owner.mode != .normal { owner.setMode(.normal) }
        owner.select(slide: hit.slide)
        status.stringValue = L("%d of %d", k + 1, list.count)
        if hit.object == -1 {
            owner.selection = []
            if !owner.notesShown { owner.setNotesShown(true) }
            owner.notesView.setSelectedRange(hit.range)
            owner.notesView.scrollRangeToVisible(hit.range)
            owner.notesView.showFindIndicator(for: hit.range)
            return
        }
        owner.selection = [hit.object]
        if let object = owner.displayedSlide.object(hit.object) {
            let cell = hit.row.flatMap { row in hit.column.map { (row, $0) } }
            owner.canvas.editor.begin(object, cell: cell, at: nil)
            let editor = owner.canvas.editor
            guard editor.isActive, let view = editor.textView else { return }
            let originalBody = cell.flatMap { object.table?.cells[$0.0][$0.1].text } ?? object.text ?? TextBody()
            let ordinal = TextSearch.ranges(in: originalBody, query: query, options: options).firstIndex(of: hit.range) ?? 0
            let renderedBody = TextBody(paragraphs: TextRender.paragraphs(from: view.textStorage ?? NSAttributedString()))
            let renderedMatches = TextSearch.ranges(in: renderedBody, query: query, options: options)
            guard renderedMatches.indices.contains(ordinal) else { return }
            let rendered = renderedMatches[ordinal]
            let start = editor.index(forContent: rendered.location)
            let stop = editor.index(forContent: NSMaxRange(rendered))
            let range = NSRange(location: start, length: max(0, stop - start))
            view.setSelectedRange(range); view.scrollRangeToVisible(range); view.showFindIndicator(for: range)
            owner.window?.makeKeyAndOrderFront(nil)
        }
    }

    @objc func replaceOne() {
        guard let owner, !query.isEmpty else { return }
        let editor = owner.canvas.editor
        if lastHit?.slide == owner.current, lastHit?.object == -1, let notes = owner.currentSlide?.notes {
            let sel = owner.notesView.selectedRange()
            let text = notes as NSString
            if sel.location <= text.length, sel.length <= text.length - sel.location,
               text.substring(with: sel).compare(query, options: options) == .orderedSame {
                // Notes have their own text-view UndoManager. Use the text editing path so Undo
                // still reaches this replacement when the notes view is the first responder.
                owner.doc?.endSilentEdit(L("Edit Notes"))
                owner.notesView.breakUndoCoalescing()
                owner.notesView.insertText(replaceField.stringValue, replacementRange: sel)
                owner.notesView.breakUndoCoalescing()
                owner.notesView.undoManager?.setActionName(L("Replace"))
                owner.doc?.endSilentEdit(L("Replace"))
            }
        } else if editor.isActive, let tv = editor.textView {
            let sel = tv.selectedRange()
            if (tv.string as NSString).substring(with: sel).compare(query, options: options) == .orderedSame {
                tv.insertText(replaceField.stringValue, replacementRange: sel)
            }
        }
        find(forward: true)
    }

    @objc func replaceAll() {
        guard let owner, !query.isEmpty else { return }
        owner.commitEditing()
        let q = query, rep = replaceField.stringValue, opts = options, notes = notesBox.state == .on
        var count = 0
        func fix(_ body: inout TextBody) { count += TextSearch.replace(in: &body, query: q, replacement: rep, options: opts) }
        func visit(_ list: inout [SlideObject]) {
            for i in list.indices {
                if var t = list[i].text { fix(&t); list[i].text = t }
                if var tb = list[i].table {
                    for r in tb.cells.indices { for c in tb.cells[r].indices where !tb.cells[r][c].merged { fix(&tb.cells[r][c].text) } }
                    list[i].table = tb
                }
                visit(&list[i].children)
            }
        }
        owner.doc?.change(L("Replace All")) { d in
            for s in d.slides.indices {
                visit(&d.slides[s].objects)
                if notes {
                    let n = d.slides[s].notes
                    let r = n.replacingOccurrences(of: q, with: rep, options: opts)
                    if r != n { count += TextSearch.ranges(in: n, query: q, options: opts).count; d.slides[s].notes = r }
                }
            }
        }
        lastHit = nil
        status.stringValue = L("%d replaced", count)
    }
}

/// Export panels: PDF, images, outline.
enum Exporter {
    static func baseName(_ owner: DeckWindowController) -> String {
        ((owner.doc?.displayName ?? L("Presentation")) as NSString).deletingPathExtension
    }

    static func pdf(_ owner: DeckWindowController, notes: Bool) {
        owner.commitEditing()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = baseName(owner) + (notes ? " – " + L("Notes") : "") + ".pdf"
        guard let window = owner.window else { return }
        panel.beginSheetModal(for: window) { r in
            guard r == .OK, let url = panel.url else { return }
            do { try Renderer.pdf(owner.deck, notes: notes).write(to: url, options: .atomic) } catch { NSApp.presentError(error) }
        }
    }

    static func images(_ owner: DeckWindowController) {
        owner.commitEditing()
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = L("Export")
        panel.message = L("Choose a folder for the slide images")
        let format = NSPopUpButton()
        format.addItems(withTitles: ["PNG", "JPEG"])
        let size = NSPopUpButton()
        size.addItems(withTitles: ["1280", "1920", "3840"].map { L("%@ pixels wide", $0) })
        size.selectItem(at: 1)
        let hidden = NSButton(checkboxWithTitle: L("Include hidden slides"), target: nil, action: nil)
        let row = NSStackView(views: [NSTextField(labelWithString: L("Format:")), format, size, hidden])
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 10, left: 16, bottom: 10, right: 16)
        panel.accessoryView = row
        panel.isAccessoryViewDisclosed = true
        guard let window = owner.window else { return }
        panel.beginSheetModal(for: window) { r in
            guard r == .OK, let dir = panel.url else { return }
            let folder = dir.appendingPathComponent(baseName(owner))
            let width = [1280, 1920, 3840][max(0, size.indexOfSelectedItem)]
            do {
                let urls = try SlideImages.export(owner.deck, to: folder, jpeg: format.indexOfSelectedItem == 1, width: width, includeHidden: hidden.state == .on)
                NSWorkspace.shared.activateFileViewerSelecting(urls.prefix(1).map { $0 })
            } catch { NSApp.presentError(error) }
        }
    }

    static func outline(_ owner: DeckWindowController) {
        owner.commitEditing()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.rtf, UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = baseName(owner) + ".rtf"
        let format = NSPopUpButton()
        format.addItems(withTitles: [L("Rich Text (RTF)"), L("Markdown")])
        format.target = FormatSwitch.shared
        format.action = #selector(FormatSwitch.changed(_:))
        FormatSwitch.shared.panel = panel
        let row = NSStackView(views: [NSTextField(labelWithString: L("Format:")), format])
        row.edgeInsets = NSEdgeInsets(top: 10, left: 16, bottom: 10, right: 16)
        panel.accessoryView = row
        guard let window = owner.window else { return }
        panel.beginSheetModal(for: window) { r in
            guard r == .OK, let url = panel.url else { return }
            let md = url.pathExtension.lowercased() == "md"
            do { try Outline.export(owner.deck, format: md ? "md" : "rtf").write(to: url, options: .atomic) } catch { NSApp.presentError(error) }
        }
    }

    final class FormatSwitch: NSObject {
        static let shared = FormatSwitch()
        weak var panel: NSSavePanel?
        @objc func changed(_ sender: NSPopUpButton) {
            guard let panel else { return }
            let ext = sender.indexOfSelectedItem == 1 ? "md" : "rtf"
            panel.nameFieldStringValue = (panel.nameFieldStringValue as NSString).deletingPathExtension + "." + ext
        }
    }
}
