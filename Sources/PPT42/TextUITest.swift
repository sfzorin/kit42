import AppKit
import Kit42

extension DeckWindowController {
    /// Native text/Find/table commands; invoked by the isolated UI audit runner.
    func auditTextAndTables() -> Bool {
        guard let doc, let window else { print("FAIL PPT text: no document window"); return false }
        commitEditing(); doc.endSilentEdit()
        let savedDeck = deck, savedState = EditState(slide: current, selection: selection)
        let savedUndo = doc.undoManager
        let savedShowHidden = ShowSettings.showHidden, savedPresenter = ShowSettings.presenterView
        ShowSettings.showHidden = false; ShowSettings.presenterView = false
        let undo = UndoManager(); undo.groupsByEvent = false; doc.undoManager = undo
        defer {
            canvas.editor.cancel(); finder.closeForAudit()
            ShowSettings.showHidden = savedShowHidden; ShowSettings.presenterView = savedPresenter
            let old = deck; doc.replaceDeck(savedDeck); current = min(savedState.slide, max(0, savedDeck.slides.count - 1))
            doc.onChange?(old); doc.undoManager = savedUndo; selection = savedState.selection
        }
        var checks = 0, failures = 0
        func check(_ value: Bool, _ name: String) {
            checks += 1; if !value { failures += 1 }
            print("\(value ? "PASS" : "FAIL") PPT text:", name)
        }
        func action(_ block: () -> Void) { undo.beginUndoGrouping(); block(); undo.endUndoGrouping() }
        func text(_ id: Int, _ value: String, props: RunProps = RunProps()) -> SlideObject {
            var object = SlideObject(id: id, kind: .textBox, frame: CGRect(x: 60, y: 60, width: 360, height: 120))
            object.text = TextBody(paragraphs: [Paragraph(value, run: props)])
            return object
        }
        func reset(_ objects: [SlideObject], notes: String = "") {
            canvas.editor.cancel(); doc.endSilentEdit()
            var fresh = Deck.makeDefault(); fresh.slides = [Slide(layout: 0, objects: objects, notes: notes)]
            let old = deck; doc.replaceDeck(fresh); current = 0; selection = []
            doc.onChange?(old); select(slide: 0); undo.removeAllActions()
            finder.findFieldValue = ""; finder.replaceFieldValue = ""
            window.makeKeyAndOrderFront(nil)
        }
        func object(_ id: Int) -> SlideObject? { displayedSlide.object(id) }
        func selectedText() -> String {
            guard let view = canvas.editor.textView, canvas.editor.isActive else { return "" }
            return (view.string as NSString).substring(with: view.selectedRange())
        }
        func menu(_ tag: Int) -> NSMenuItem { NSMenuItem.tagged(tag) }

        var first = text(10, "")
        first.text?.paragraphs[0].runs = [TextRun(text: "Al", props: RunProps(bold: true)), TextRun(text: "pha alpha", props: RunProps(italic: true))]
        var table = SlideObject(id: 20, kind: .table, frame: CGRect(x: 60, y: 240, width: 360, height: 80))
        table.table = TableModel(rows: 2, columns: 2, width: 360, rowHeight: 40)
        table.table?.cells[0][0].text.paragraphs = [Paragraph("alpha")]
        table.table?.cells[1][1].text.paragraphs = [Paragraph("alpha")]
        reset([first, table], notes: "alpha alpha")
        finder.setQuery("alpha", replace: "Beta")
        action { finder.findNext() }
        check(canvas.editor.objectID == 10 && selectedText() == "Alpha", "Find matches across differently formatted runs")
        action { finder.findNext() }
        check(canvas.editor.objectID == 10 && canvas.editor.contentOffset(canvas.editor.textView.selectedRange().location) == 6, "Find Next selects the second occurrence in one object")
        action { finder.findPrevious() }
        check(canvas.editor.contentOffset(canvas.editor.textView.selectedRange().location) == 0, "Find Previous returns to the earlier occurrence")
        action { finder.findNext(); finder.findNext() }
        check(canvas.editor.objectID == 20 && canvas.editor.cell?.0 == 0 && canvas.editor.cell?.1 == 0 && selectedText() == "alpha", "Find selects the actual matching table cell")
        action { finder.replaceOne() }
        check(object(20)?.table?.cells[0][0].text.plainText == "Beta" && object(20)?.table?.cells[1][1].text.plainText == "alpha", "Replace One edits only the matched table cell")
        canvas.editor.cancel(); undo.undo()
        check(object(20)?.table?.cells[0][0].text.plainText == "alpha", "Undo restores the replaced table cell")
        undo.redo(); check(object(20)?.table?.cells[0][0].text.plainText == "Beta", "Redo reapplies the table-cell replacement")
        action { finder.replaceAll() }
        check(object(10)?.text?.plainText == "Beta Beta" && object(20)?.table?.cells[1][1].text.plainText == "Beta" && currentSlide?.notes == "Beta Beta", "Replace All handles run boundaries, cells and every notes occurrence")
        check(object(10)?.text?.paragraphs[0].runs.first?.props.bold == true && object(10)?.text?.paragraphs[0].runs.last?.props.italic == true, "replacement preserves first-character and surrounding run formatting")
        check(finder.statusText == L("%d replaced", 5), "Replace All reports occurrence count, including case-insensitive notes matches")
        undo.undo(); check(object(10)?.text?.plainText == "Alpha alpha" && currentSlide?.notes == "alpha alpha", "one Undo restores all Replace All changes")
        undo.redo(); check(object(10)?.text?.plainText == "Beta Beta" && currentSlide?.notes == "Beta Beta", "Redo restores all Replace All changes")

        var field = text(30, "")
        field.text?.paragraphs[0].runs = [TextRun(text: "alpha", field: "slidenum"), TextRun(text: " alpha")]
        reset([field]); finder.setQuery("alpha", replace: "Beta")
        action { finder.findNext() }
        check(selectedText() == "alpha", "Find accounts for a dynamic field whose rendered length differs from its cached text")
        action { finder.replaceAll() }
        check(object(30)?.text?.paragraphs[0].runs.first?.field == "slidenum" && object(30)?.text?.plainText == "alpha Beta", "Replace All leaves dynamic fields intact")

        let child = text(42, "Nested", props: RunProps(bold: false))
        var nested = SlideObject(id: 41, kind: .group, frame: child.frame); nested.children = [child]
        var group = SlideObject(id: 40, kind: .group, frame: child.frame); group.children = [nested, table]
        reset([group]); selection = [40]
        action { boldAction(nil); alignTextAction(menu(2)); anchorAction(menu(2)) }
        check(object(42)?.text?.paragraphs[0].runs[0].props.bold == true, "Bold reaches text inside nested groups")
        check(object(42)?.text?.paragraphs[0].props.align == .right && object(20)?.table?.cells[0][0].text.paragraphs[0].props.align == .right, "paragraph alignment reaches nested text and table cells")
        check(object(42)?.text?.anchor == .bottom && object(20)?.table?.cells[0][0].text.anchor == .bottom, "vertical alignment reaches grouped text and tables")
        check(currentRunProps.bold == true && currentLevelStyle.align == .right, "format controls report the selected group's effective text style")
        undo.undo(); check(object(42)?.text?.paragraphs[0].runs[0].props.bold == false, "group formatting is undoable")

        reset([table]); selection = [20]
        canvas.editor.begin(object(20)!, cell: (1, 1), at: nil)
        action { anchorAction(menu(2)) }
        check(object(20)?.table?.cells[1][1].text.anchor == .bottom && object(20)?.table?.cells[0][0].text.anchor == .top, "vertical alignment while editing affects only that table cell")
        undo.undo(); check(object(20)?.table?.cells[1][1].text.anchor == .top, "Undo restores table-cell vertical alignment")

        reset([text(50, "Sample")]); selection = [50]
        canvas.editor.begin(object(50)!, at: nil, selectAll: true)
        let textUndo = canvas.editor.textView.undoManager!
        textUndo.groupsByEvent = false
        textUndo.beginUndoGrouping(); boldAction(nil); textUndo.endUndoGrouping()
        check(canvas.editor.currentRunProps.bold == true && canvas.editor.hasPendingChanges, "selected text formatting changes the visible draft")
        textUndo.undo(); check(canvas.editor.currentRunProps.bold != true, "text-format Undo restores the selected characters")
        textUndo.redo(); check(canvas.editor.currentRunProps.bold == true, "text-format Redo reapplies selected-character formatting")
        textUndo.groupsByEvent = true
        action { commitEditing() }
        check(object(50)?.text?.paragraphs[0].runs[0].props.bold == true, "committing formatted text updates the model")
        undo.removeAllActions()
        let unchanged = object(50)
        canvas.editor.begin(object(50)!, at: nil)
        check(!canvas.editor.hasPendingChanges, "opening an unchanged text editor is not a pending modification")
        // An explicit empty NSUndoManager group itself reports canUndo=true on macOS.
        // A no-op must not register anything, so call it without manufacturing a test group.
        commitEditing()
        check(!undo.canUndo && object(50) == unchanged, "leaving unchanged text does not rewrite its model or create Undo")
        canvas.editor.begin(object(50)!, at: nil)
        canvas.editor.textView.insertText(" draft", replacementRange: NSRange(location: canvas.editor.textView.string.utf16.count, length: 0))
        check(canvas.editor.hasPendingChanges, "typing in the editor reports a pending modification")
        canvas.editor.cancel(); check(object(50)?.text?.plainText == "Sample" && !canvas.editor.isActive, "Cancel discards the draft without changing the saved object")

        // A placeholder remains present even when empty, so empty-paragraph formatting must survive commit.
        var empty = text(51, ""); empty.placeholder = Placeholder(type: "body", idx: 1)
        reset([empty]); selection = [51]; canvas.editor.begin(object(51)!, at: nil)
        action { setFontSize(32); alignTextAction(menu(1)); commitEditing() }
        check(object(51)?.text?.paragraphs[0].endProps.size == 32 && object(51)?.text?.paragraphs[0].props.align == .center, "empty paragraph keeps chosen font size and alignment after commit")

        // Insert/delete through merged rectangles must move the anchor and spans coherently.
        table.table = TableModel(rows: 3, columns: 3, width: 360, rowHeight: 30)
        table.frame.size.height = 90
        table.table?.cells[0][0].text = TextBody(paragraphs: [Paragraph("Merged")])
        table.table?.cells[0][0].rowSpan = 2; table.table?.cells[0][0].gridSpan = 2
        table.table?.cells[0][1].merged = true; table.table?.cells[1][0].merged = true; table.table?.cells[1][1].merged = true
        table.table?.cells[2][2].text = TextBody(paragraphs: [Paragraph("Tail")])
        reset([table]); selection = [20]; canvas.editor.begin(object(20)!, cell: (0, 0), at: nil)
        action { tableRowAction(menu(1)) }
        check(object(20)?.table?.rows.count == 4 && object(20)?.table?.cells[0][0].rowSpan == 3 && object(20)?.table?.cells[2][1].merged == true && object(20)?.table?.cells[3][2].text.plainText == "Tail", "inserting inside a merged row span expands it and preserves following content")
        undo.undo(); check(object(20)?.table?.rows.count == 3 && object(20)?.table?.cells[0][0].rowSpan == 2, "Undo restores table row geometry and spans")
        undo.redo(); check(object(20)?.table?.rows.count == 4, "Redo restores inserted merged-table row")
        canvas.editor.begin(object(20)!, cell: (0, 0), at: nil)
        action { tableRowAction(menu(2)) }
        check(object(20)?.table?.cells[0][0].text.plainText == "Merged" && object(20)?.table?.cells[0][0].rowSpan == 2, "deleting a merged anchor row retains its content in the surviving span")
        canvas.editor.begin(object(20)!, cell: (0, 0), at: nil)
        action { tableColumnAction(menu(1)) }
        check(object(20)?.table?.columns.count == 4 && object(20)?.table?.cells[0][0].gridSpan == 3 && object(20)?.table?.cells[1][2].merged == true, "inserting inside a merged column span expands it")
        canvas.editor.begin(object(20)!, cell: (0, 0), at: nil)
        action { tableColumnAction(menu(2)) }
        check(object(20)?.table?.cells[0][0].text.plainText == "Merged" && object(20)?.table?.cells[0][0].gridSpan == 2, "deleting a merged anchor column retains its content")
        canvas.editor.begin(object(20)!, cell: (100, 100), at: nil)
        check(!canvas.editor.isActive, "invalid table cell cannot crash or start editing")

        // Automatic entrance animations on the first slide must run before the first user click.
        reset([text(70, "First"), text(71, "Second")])
        action { doc.change("Animation fixture") { d in
            d.slides[0].animations = [Animation(target: 70, effect: .appear, trigger: .afterPrevious), Animation(target: 71, effect: .appear)]
            var hidden = Slide(layout: 0); hidden.hidden = true
            d.slides += [hidden, Slide(layout: 0, objects: [text(72, "Last")])]
        } }
        let show = SlideShowController(owner: self, deck: deck, start: 0, rehearse: false, windowed: true)
        show.start()
        check(show.step == 1, "first slide plays its automatic animation group at startup")
        show.next(); check(show.step == 2 && show.slideIndex == 0, "first click reveals the next on-click animation")
        show.toggleBlank(.black); show.next(); check(!show.isBlank && show.slideIndex == 0, "Next dismisses a blank screen before advancing")
        show.next(); check(show.slideIndex == 2, "show navigation skips a hidden slide")
        show.previous(); check(show.slideIndex == 0 && show.step == 2, "Previous returns with the prior slide's builds revealed")
        show.end(); check(SlideShowController.current == nil, "ending the show releases its active controller")
        print("PPT text/table/show UI regressions: \(checks - failures)/\(checks) passed")
        return failures == 0
    }
}
