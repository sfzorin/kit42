import AppKit
import Kit42

/// Debug hooks for headless UI checks (with K42_SNAPSHOT):
///   K42_SLIDE=n (1-based), K42_VIEW=normal|outline|sorter|notes|master, K42_SELECT=i[,j] (object indexes on the slide),
///   K42_INSPECTOR=1|slide|shape|text, K42_EDIT=1 (edit the selected object's text), K42_NOTES=0 (hide the notes pane),
///   K42_FORMAT=0 (hide the format bar), K42_ZOOM=x, K42_THEME=n, K42_LAYOUTS=1 (new-slide layout picker),
///   K42_SHOW=1 (slide show; K42_SHOW_STEPS=n clicks), K42_PRESENTER=1 (presenter view in a window),
///   K42_DO="cmd;cmd…" runs commands (see `run(_:)`), K42_SAVE=path writes the deck afterwards, K42_PRINT_INFO prints it.
extension DeckWindowController {
    func prepareSnapshot(_ env: [String: String]) {
        setlinebuf(stdout)
        if let n = env["K42_SLIDE"].flatMap(Int.init) { select(slide: n - 1) }
        if let v = env["K42_VIEW"] {
            let modes: [String: ViewMode] = ["normal": .normal, "outline": .outline, "sorter": .sorter, "notes": .notesPage, "master": .master]
            if let m = modes[v] { setMode(m) }
        }
        if env["K42_NOTES"] == "0", notesShown { setNotesShown(false) }
        if env["K42_FORMAT"] == "0" { formatBar.strip.isShown = false }
        if let t = env["K42_THEME"].flatMap(Int.init) { themeAction(NSMenuItem.tagged(t)) }
        if let sel = env["K42_SELECT"] {
            let objs = displayedSlide.objects
            selection = sel.split(separator: ",").compactMap { Int($0) }.filter { objs.indices.contains($0) }.map { objs[$0].id }
        }
        if let z = env["K42_ZOOM"].flatMap(Double.init) { canvas.zoom = CGFloat(z) }
        if let script = env["K42_DO"] { for cmd in script.split(separator: ";") { run(String(cmd)) } }
        if let i = env["K42_INSPECTOR"] {
            let tab = ["slide": 0, "shape": 1, "text": 2][i] ?? (selection.isEmpty ? 0 : 1)
            showInspector(true, tab: tab)
        }
        if env["K42_EDIT"] != nil, let o = selectedObjects.first { canvas.editor.begin(o, at: nil) }
        if env["K42_LAYOUTS"] != nil { showLayoutPicker() }
        if env["K42_DUMP_SIDEBAR"] != nil {
            let t = thumbnails.table
            print("table frame \(t.frame) cols \(t.tableColumns.map { $0.width }) clip \(t.enclosingScrollView?.contentView.frame ?? .zero) sidebar \(thumbnails.view.frame)")
            for r in 0..<min(2, t.numberOfRows) { print("row \(r) \(t.rect(ofRow: r)) view \(t.view(atColumn: 0, row: r, makeIfNecessary: false)?.frame ?? .zero)") }
            print("split \(contentSplit.frame) notes \(contentSplit.arrangedSubviews.map { $0.frame })")
        }
        // K42_CANVAS_PNG=path: the slide area of the canvas as drawn on screen (compare with --export).
        if let path = env["K42_CANVAS_PNG"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let c = self?.canvas, let rep = c.bitmapImageRepForCachingDisplay(in: c.slideRect) else { return }
                c.cacheDisplay(in: c.slideRect, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                print("canvas: \(c.slideRect) scale \(c.scale) visible \(c.enclosingScrollView?.visibleContentSize ?? .zero)")
            }
        }
        if env["K42_PRINT_INFO"] != nil { print(CLI.info(deck, name: "deck")) }
        if let path = env["K42_SAVE"] {
            commitEditing()
            do {
                try DeckIO.write(deck, ext: (path as NSString).pathExtension).write(to: URL(fileURLWithPath: path))
                print("saved: \(path)")
            } catch { print("save failed: \(error)") }
        }
        if env["K42_SHOW"] != nil || env["K42_PRESENTER"] != nil {
            startShow(from: current, presenter: env["K42_PRESENTER"] != nil, rehearse: env["K42_PRESENTER"] != nil && env["K42_SHOW"] == nil)
            for _ in 0..<(env["K42_SHOW_STEPS"].flatMap(Int.init) ?? 0) { SlideShowController.current?.next() }
        }
    }

    /// Test commands: newslide:<layout>, duplicate, delete, shape:<gallery index>, textbox, table:<r>x<c>, bold, italic, underline,
    /// size:<pt>, color:<RRGGBB>, align:<0-3>, bullets:<0-2>, indent, outdent, group, ungroup, front, back, alignobj:<0-5>,
    /// distribute:<0-1>, layout:<i>, transition:<i>, hide, theme:<i>, size169, size43, selectall, select:<i,j>, slide:<n>,
    /// type:<text> (types into the edited object), endedit, undo, redo, copy, paste, copyslide, pasteslide, move:<dx>,<dy>,
    /// rotate:<deg>, fill:<RRGGBB>, build:<0-4>, find:<text>, replace:<a>=<b>, outline:<text with \t and \n>, notes:<text>.
    func run(_ cmd: String) {
        let parts = cmd.split(separator: ":", maxSplits: 1).map(String.init)
        let name = parts[0], arg = parts.count > 1 ? parts[1] : ""
        let tag = NSMenuItem.tagged(Int(arg) ?? 0)
        func hex(_ s: String) -> PColor { PColor(rgb: UInt32(s, radix: 16) ?? 0) }
        switch name {
        case "newslide": addSlide(layout: Int(arg) ?? 1)
        case "duplicate": duplicateAction(nil)
        case "duplicateslide": duplicateSlideAction(nil)
        case "deleteslide": deleteSlideAction(nil)
        case "delete": deleteAction(nil)
        case "shape":
            let i = Int(arg) ?? 0
            insertShape(Shapes.gallery[min(i, Shapes.gallery.count - 1)].prst, in: CGRect(x: 120 + CGFloat(i % 5) * 150, y: 160 + CGFloat(i / 5) * 90, width: 130, height: 80))
        case "textbox": insertTextBox(in: CGRect(x: 100, y: 420, width: 400, height: 40), autoHeight: true)
        case "table":
            let n = arg.split(separator: "x").compactMap { Int($0) }
            var t = TableModel(rows: n.first ?? 3, columns: n.last ?? 3, width: 600, rowHeight: 36)
            for r in t.cells.indices { for c in t.cells[r].indices { t.cells[r][c].text.paragraphs = [Paragraph("R\(r + 1)C\(c + 1)")]; t.cells[r][c].text.anchor = .middle } }
            var o = SlideObject(id: 0, kind: .table, frame: CGRect(x: 180, y: 170, width: 600, height: t.size.height))
            o.table = t
            insert([o], name: L("Insert Table"))
        case "chart":
            // chart:<kind> inserts a sample chart; chart:edit opens the data sheet.
            if arg == "edit" { editChart(selectedObjects.first { $0.kind == .chart }); break }
            insertChart(ChartModel.sample(ChartKind(rawValue: arg) ?? .column))
        case "chartkind": let k = ChartKind(rawValue: arg) ?? .column; changeChart(L("Chart Type")) { $0.kind = k }
        case "charttitle": changeChart(L("Chart Title")) { $0.title = arg.isEmpty ? nil : arg }
        case "chartstack": let g = ChartGrouping(rawValue: arg) ?? .stacked; changeChart(L("Chart Type")) { $0.grouping = g }
        case "chartlabels": changeChart(L("Data Labels")) { $0.dataLabels = arg != "0" }
        case "chartlegend": changeChart(L("Legend")) { $0.legend = arg.isEmpty || arg == "none" ? nil : arg }
        case "chartvalue":
            // chartvalue:<series>,<row>,<value>
            let v = arg.split(separator: ",").compactMap { Double($0) }
            if v.count == 3 { changeChart(L("Chart Data")) { m in
                let s = Int(v[0]), r = Int(v[1])
                if m.series.indices.contains(s), m.series[s].values.indices.contains(r) { m.series[s].values[r] = v[2] }
            } }
        case "bold": boldAction(nil)
        case "italic": italicAction(nil)
        case "underline": underlineAction(nil)
        case "size": setFontSize(CGFloat(Double(arg) ?? 18))
        case "font": setFont(arg)
        case "color": setTextColor(hex(arg))
        case "align": alignTextAction(tag)
        case "anchor": anchorAction(tag)
        case "bullets": bulletsAction(tag)
        case "spacing": lineSpacingAction(tag)
        case "indent": indentAction(NSMenuItem.tagged(1))
        case "outdent": indentAction(NSMenuItem.tagged(-1))
        case "group": groupAction(nil)
        case "ungroup": ungroupAction(nil)
        case "front": arrangeAction(NSMenuItem.tagged(0))
        case "back": arrangeAction(NSMenuItem.tagged(3))
        case "alignobj": alignObjectsAction(tag)
        case "distribute": distributeAction(tag)
        case "layout": layoutAction(tag)
        case "transition": transitionAction(tag)
        case "hide": hideSlideAction(nil)
        case "theme": themeAction(tag)
        case "size169": slideSizeAction(NSMenuItem.tagged(0))
        case "size43": slideSizeAction(NSMenuItem.tagged(1))
        case "selectall": selection = displayedSlide.objects.map(\.id)
        case "select":
            let objs = displayedSlide.objects
            selection = arg.split(separator: ",").compactMap { Int($0) }.filter { objs.indices.contains($0) }.map { objs[$0].id }
        case "slide": select(slide: (Int(arg) ?? 1) - 1)
        case "edit": if let o = selectedObjects.first { canvas.editor.begin(o, at: nil, selectAll: arg == "all") }
        case "type": canvas.editor.textView.insertText(arg.replacingOccurrences(of: "\\n", with: "\n"), replacementRange: canvas.editor.textView.selectedRange())
        case "selecttext": canvas.editor.textView.selectAll(nil)
        case "endedit": commitEditing()
        case "dumpedit": print("editor active=\(canvas.editor.isActive) text=\(canvas.editor.textView.string.debugDescription) sel=\(selection)")
        case "undo": commitEditing(); doc?.undoManager?.undo()
        case "redo": doc?.undoManager?.redo()
        case "copy": copyObjects(cut: false)
        case "cut": copyObjects(cut: true)
        case "paste": pasteObjects()
        case "copyslide": copySlides()
        case "move":
            let v = arg.split(separator: ",").compactMap { Double($0) }
            if v.count == 2 { changeSelected(L("Move")) { $0.offset(by: CGSize(width: v[0], height: v[1])) } }
        case "rotate": let a = CGFloat(Double(arg) ?? 0); changeSelected(L("Rotate")) { $0.rotation = a }
        case "fill": setFill(.solid(hex(arg)))
        case "line": let c = hex(arg); setLine { $0.color = c; $0.width = 3 }
        case "shadow": changeSelected(L("Shadow")) { $0.shadow = true }
        case "opacity": let v = CGFloat(Double(arg) ?? 1); changeSelected(L("Opacity")) { $0.opacity = v }
        case "build":
            let i = Int(arg) ?? 0
            changeSelected(L("Animation")) { $0.build = i == 0 ? nil : BuildEffect.allCases[min(i - 1, 3)] }
        case "find":
            finder.show()
            finder.setQuery(arg)
            finder.find(forward: true)
        case "replace":
            let ab = arg.split(separator: "=", maxSplits: 1).map(String.init)
            finder.show()
            finder.setQuery(ab.first ?? "", replace: ab.count > 1 ? ab[1] : "")
            finder.replaceAll()
        case "outline":
            setMode(.outline)
            outline.string = arg.replacingOccurrences(of: "\\t", with: "\t").replacingOccurrences(of: "\\n", with: "\n")
            outline.apply()
            doc?.endSilentEdit()
        case "notes": let i = current; doc?.change(L("Edit Notes")) { $0.slides[i].notes = arg }
        case "mode": setMode(ViewMode(rawValue: Int(arg) ?? 0) ?? .normal)
        default: print("unknown command: \(cmd)")
        }
    }
}

extension FindController {
    func setQuery(_ q: String, replace: String? = nil) {
        show()
        findFieldValue = q
        if let replace { replaceFieldValue = replace }
    }
}
