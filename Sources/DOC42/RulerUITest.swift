import AppKit
import Kit42

extension DocWindowController {
    /// K42_SCRIPT=auditrulers: dispatch real mouse events through a temporary document window.
    /// The user's document, undo history and saved panel preferences are left untouched.
    func auditRulers() -> Bool {
        let fixture = TextDocument()
        fixture.undoManager?.groupsByEvent = false
        fixture.makeWindowControllers()
        guard let editor = fixture.editor, let window = editor.window, let undo = fixture.undoManager else {
            print("FAIL DOC rulers: create native editor")
            return false
        }
        editor.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        editor.setRuler(shown: true)
        editor.setComments(shown: false)
        editor.setSidebar(nil)
        defer {
            undo.removeAllActions()
            fixture.updateChangeCount(.changeCleared)
            editor.close()
            fixture.close()
            self.window?.makeKeyAndOrderFront(nil)
        }

        var checked = 0, failed = 0
        func check(_ condition: Bool, _ name: String) {
            checked += 1
            if !condition { failed += 1 }
            print("\(condition ? "PASS" : "FAIL") DOC rulers: \(name)")
        }
        func near(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < 0.1 }
        func sameMargins(_ a: NSEdgeInsets, _ b: NSEdgeInsets) -> Bool {
            near(a.top, b.top) && near(a.left, b.left) && near(a.bottom, b.bottom) && near(a.right, b.right)
        }
        func settle() {
            window.contentView?.layoutSubtreeIfNeeded()
            editor.paged.layoutAll()
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }
        func reset(_ text: String = "Ruler regression paragraph.\nSecond paragraph.", setup: PageSetup = PageSetup(),
                   paragraph: NSParagraphStyle = .default) {
            undo.removeAllActions()
            undo.disableUndoRegistration()
            editor.headerEditor?.commit()
            editor.setViewMode(.single)
            fixture.setup = setup
            var attributes = Styles.normal.attributes
            attributes[.paragraphStyle] = paragraph
            fixture.storage.setAttributedString(NSAttributedString(string: text, attributes: attributes))
            editor.textView.typingAttributes = attributes
            editor.textView.setSelectedRange(NSRange(location: 0, length: 0))
            editor.setZoom(1)
            editor.setRuler(shown: true)
            settle()
            editor.scroller.contentView.scroll(to: .zero)
            editor.scroller.reflectScrolledClipView(editor.scroller.contentView)
            editor.syncRulerSetup()
            editor.syncRuler()
            window.makeFirstResponder(editor.textView)
            undo.enableUndoRegistration()
            fixture.updateChangeCount(.changeCleared)
        }
        func paragraph() -> NSParagraphStyle {
            guard fixture.storage.length > 0 else {
                return (editor.textView.typingAttributes[.paragraphStyle] as? NSParagraphStyle) ?? .default
            }
            let at = min(editor.textView.selectedRange().location, fixture.storage.length - 1)
            return (fixture.storage.attribute(.paragraphStyle, at: at, effectiveRange: nil) as? NSParagraphStyle) ?? .default
        }
        func reveal(_ point: NSPoint, on card: PageCard) {
            _ = card.scrollToVisible(NSRect(x: point.x - 10, y: point.y - 10, width: 20, height: 20))
            editor.scroller.reflectScrolledClipView(editor.scroller.contentView)
            settle()
        }
        func horizontal(_ x: CGFloat, on card: PageCard, band: CGFloat = 15) -> NSPoint {
            NSPoint(x: editor.ruler.convert(NSPoint(x: x, y: 0), from: card).x, y: band)
        }
        func vertical(_ y: CGFloat, on card: PageCard) -> NSPoint {
            NSPoint(x: 15, y: editor.verticalRuler.convert(NSPoint(x: 0, y: y), from: card).y)
        }
        var eventNumber = 1
        @discardableResult
        func gesture(_ ruler: DocRuler, from start: NSPoint, to end: NSPoint?, flags: NSEvent.ModifierFlags = [.option]) -> Bool {
            // Explicit groups separate each synthetic gesture just as different user events do.
            editor.activeTextView.breakUndoCoalescing()
            let activeUndo = editor.activeTextView.undoManager
            undo.beginUndoGrouping()
            if let activeUndo, activeUndo !== undo { activeUndo.beginUndoGrouping() }
            defer {
                if let activeUndo, activeUndo !== undo { activeUndo.endUndoGrouping() }
                undo.endUndoGrouping()
            }
            let points: [(NSEvent.EventType, NSPoint)] = [(.leftMouseDown, start)]
                + (end.map { [(.leftMouseDragged, $0)] } ?? []) + [(.leftMouseUp, end ?? start)]
            for (type, point) in points {
                guard let event = NSEvent.mouseEvent(with: type, location: ruler.convert(point, to: nil),
                    modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: eventNumber,
                    clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1) else { return false }
                eventNumber += 1
                window.sendEvent(event)
            }
            return true
        }

        reset()
        settle()
        check(!editor.ruler.isHidden && !editor.verticalRuler.isHidden
              && editor.ruler.bounds.height >= 24 && editor.verticalRuler.bounds.width >= 24,
              "horizontal and vertical rulers are visible")
        editor.setRuler(shown: false)
        settle()
        check(editor.ruler.isHidden && editor.verticalRuler.isHidden, "Hide Ruler hides both axes")
        editor.setRuler(shown: true)
        settle()
        check(!editor.ruler.isHidden && !editor.verticalRuler.isHidden, "Show Ruler restores both axes")

        for zoom: CGFloat in [0.25, 0.5, 1, 2] {
            for edge in ["left", "right", "top", "bottom"] {
                reset()
                editor.setZoom(zoom)
                settle()
                guard let card = editor.paged.cards.first else { check(false, "page exists"); continue }
                let old = fixture.setup.margins
                var expected = old
                let start: NSPoint, end: NSPoint, ruler: DocRuler
                switch edge {
                case "left":
                    reveal(NSPoint(x: old.left, y: 100), on: card)
                    start = horizontal(old.left, on: card)
                    end = horizontal(old.left + 18, on: card)
                    ruler = editor.ruler; expected.left += 18
                case "right":
                    reveal(NSPoint(x: card.bounds.width - old.right, y: 100), on: card)
                    start = horizontal(card.bounds.width - old.right, on: card)
                    end = horizontal(card.bounds.width - old.right - 18, on: card)
                    ruler = editor.ruler; expected.right += 18
                case "top":
                    reveal(NSPoint(x: old.left, y: old.top), on: card)
                    start = vertical(old.top, on: card)
                    end = vertical(old.top + 18, on: card)
                    ruler = editor.verticalRuler; expected.top += 18
                default:
                    reveal(NSPoint(x: old.left, y: card.bounds.height - old.bottom), on: card)
                    start = vertical(card.bounds.height - old.bottom, on: card)
                    end = vertical(card.bounds.height - old.bottom - 18, on: card)
                    ruler = editor.verticalRuler; expected.bottom += 18
                }
                let sent = gesture(ruler, from: start, to: end)
                settle()
                check(sent && sameMargins(fixture.setup.margins, expected)
                      && near(paragraph().headIndent, 0) && near(paragraph().firstLineHeadIndent, 0),
                      "\(edge) margin moves independently at \(Int(zoom * 100))% zoom")
                undo.undo(); settle()
                check(sameMargins(fixture.setup.margins, old), "Undo \(edge) margin at \(Int(zoom * 100))%")
                undo.redo(); settle()
                check(sameMargins(fixture.setup.margins, expected), "Redo \(edge) margin at \(Int(zoom * 100))%")
                undo.undo(); settle()
                check(sameMargins(fixture.setup.margins, old), "second Undo \(edge) margin at \(Int(zoom * 100))%")
            }
        }

        let indented = NSMutableParagraphStyle()
        indented.firstLineHeadIndent = 24; indented.headIndent = 12; indented.tailIndent = -20
        reset(paragraph: indented)
        if let card = editor.paged.cards.first {
            let before = fixture.setup
            for (name, ruler, point) in [
                ("left margin", editor.ruler, horizontal(before.margins.left, on: card)),
                ("right margin", editor.ruler, horizontal(before.size.width - before.margins.right, on: card)),
                ("first line", editor.ruler, horizontal(before.margins.left + 24, on: card, band: 5)),
                ("left indent", editor.ruler, horizontal(before.margins.left + 12, on: card, band: DocRuler.height - 5)),
                ("right indent", editor.ruler, horizontal(before.size.width - before.margins.right - 20, on: card, band: DocRuler.height - 5)),
            ] {
                let sent = gesture(ruler, from: point, to: nil)
                let p = paragraph()
                check(sent && fixture.setup == before && near(p.firstLineHeadIndent, 24) && near(p.headIndent, 12)
                      && near(p.tailIndent, -20), "click without dragging preserves \(name)")
            }
            for edge in ["top", "bottom"] {
                let y = edge == "top" ? before.margins.top : before.size.height - before.margins.bottom
                reveal(NSPoint(x: 80, y: y), on: card)
                let sent = gesture(editor.verticalRuler, from: vertical(y, on: card), to: nil)
                check(sent && fixture.setup == before, "click without dragging preserves \(edge) margin")
            }
        }

        reset("")
        if let card = editor.paged.cards.first {
            let left = fixture.setup.margins.left
            _ = gesture(editor.ruler, from: horizontal(left, on: card, band: 5),
                        to: horizontal(left + 24, on: card, band: 5))
            check(near(paragraph().firstLineHeadIndent, 24) && near(editor.ruler.paragraph.firstLineHeadIndent, 24)
                  && near(fixture.setup.margins.left, left), "empty-document first-line indent remains visible")
        }

        var twoColumns = PageSetup(); twoColumns.columns = 2
        reset(Array(repeating: "Column regression line with enough text to flow.", count: 90).joined(separator: "\n"), setup: twoColumns)
        if let card = editor.paged.cards.first, card.textViews.count == 2, let container = card.textViews[1].textContainer {
            let glyphs = editor.paged.layoutManager.glyphRange(for: container)
            let characters = editor.paged.layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
            check(characters.length > 0, "second-column fixture contains text")
            editor.textView.setSelectedRange(NSRange(location: characters.location, length: 0))
            settle()
            let column = card.textViews[1]
            reveal(NSPoint(x: column.frame.minX, y: 100), on: card)
            _ = gesture(editor.ruler, from: horizontal(column.frame.minX, on: card, band: 5),
                        to: horizontal(column.frame.minX + 24, on: card, band: 5))
            check(near(paragraph().firstLineHeadIndent, 24) && near(paragraph().headIndent, 0)
                  && sameMargins(fixture.setup.margins, twoColumns.margins), "first-line indent uses second column origin")
            _ = gesture(editor.ruler, from: horizontal(column.frame.minX, on: card, band: DocRuler.height - 5),
                        to: horizontal(column.frame.minX + 18, on: card, band: DocRuler.height - 5))
            check(near(paragraph().headIndent, 18) && near(paragraph().firstLineHeadIndent, 42),
                  "second-column left indent carries first line")
            _ = gesture(editor.ruler, from: horizontal(column.frame.maxX, on: card, band: DocRuler.height - 5),
                        to: horizontal(column.frame.maxX - 20, on: card, band: DocRuler.height - 5))
            check(near(paragraph().tailIndent, -20), "right indent uses second column width")
        } else { check(false, "two-column fixture layout") }

        for isHeader in [true, false] {
            let label = isHeader ? "header" : "footer"
            let hf = DocHeaderFooter()
            var attributes = Styles.normal.attributes
            attributes[.paragraphStyle] = indented
            hf.header = NSAttributedString(string: "Header paragraph", attributes: attributes)
            hf.footer = NSAttributedString(string: "Footer paragraph", attributes: attributes)
            var setup = twoColumns; setup.hf = hf
            reset("Body paragraph remains unchanged.", setup: setup)
            if let card = editor.paged.cards.first {
                editor.beginHeaderEdit(card, header: isHeader)
                guard let header = editor.headerEditor else { check(false, "start \(label) editing"); continue }
                header.undo.groupsByEvent = false
                let originalBody = NSAttributedString(attributedString: fixture.storage)
                header.textView.setSelectedRange(NSRange(location: 0, length: 0))
                reveal(NSPoint(x: card.setup.margins.left, y: header.textView.frame.midY), on: card)
                let left = header.textView.frame.minX, right = header.textView.frame.maxX
                _ = gesture(editor.ruler, from: horizontal(left + 12, on: card, band: DocRuler.height - 5),
                            to: horizontal(left + 30, on: card, band: DocRuler.height - 5))
                func headerParagraph() -> NSParagraphStyle {
                    (header.textView.textStorage?.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle) ?? .default
                }
                check(near(headerParagraph().headIndent, 30) && near(headerParagraph().firstLineHeadIndent, 42)
                      && fixture.storage.isEqual(to: originalBody), "\(label) left indent changes only active header/footer")
                _ = gesture(editor.ruler, from: horizontal(right - 20, on: card, band: DocRuler.height - 5),
                            to: horizontal(right - 44, on: card, band: DocRuler.height - 5))
                check(near(headerParagraph().tailIndent, -44) && near(editor.ruler.paragraph.tailIndent, -44)
                      && fixture.storage.isEqual(to: originalBody), "\(label) right indent uses full width on two-column page")
                header.undo.undo()
                check(near(headerParagraph().tailIndent, -20), "\(label) ruler edit uses header/footer Undo")
                header.undo.redo()
                check(near(headerParagraph().tailIndent, -44), "\(label) ruler edit uses header/footer Redo")
                undo.beginUndoGrouping()
                header.commit()
                undo.endUndoGrouping()
                let saved = isHeader ? fixture.setup.hf?.header : fixture.setup.hf?.footer
                let savedParagraph = saved.flatMap { $0.length > 0 ? $0.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle : nil }
                check(savedParagraph.map { near($0.headIndent, 30) && near($0.firstLineHeadIndent, 42) && near($0.tailIndent, -44) } == true,
                      "\(label) ruler edits persist when leaving header/footer")
            } else { check(false, "\(label) fixture has a page") }
        }

        reset()
        var firstSetup = PageSetup()
        firstSetup.size = NSSize(width: 612, height: 792)
        firstSetup.margins = NSEdgeInsets(top: 54, left: 60, bottom: 66, right: 78)
        let sectionText = NSMutableAttributedString(string: "First section.\n", attributes: Styles.normal.attributes)
        var breakAttributes = Styles.normal.attributes
        breakAttributes[.docSection] = firstSetup.section
        sectionText.append(NSAttributedString(string: "\u{000C}", attributes: breakAttributes))
        sectionText.append(NSAttributedString(string: "\nLast section.", attributes: Styles.normal.attributes))
        fixture.storage.setAttributedString(sectionText)
        editor.textView.setSelectedRange(NSRange(location: 0, length: 0))
        settle()
        editor.syncRulerSetup()
        if let card = editor.paged.card(at: 0) {
            reveal(NSPoint(x: 80, y: firstSetup.margins.top), on: card)
            _ = gesture(editor.verticalRuler, from: vertical(firstSetup.margins.top, on: card),
                        to: vertical(firstSetup.margins.top + 18, on: card))
            settle()
            let first = editor.paged.sections.first?.section
            check(first.map { near($0.margins.top, 72) && $0.pageSize == firstSetup.size } == true
                  && fixture.setup == PageSetup(), "vertical margin changes only the selected first section")
        }
        editor.textView.setSelectedRange(NSRange(location: fixture.storage.length - 1, length: 0))
        settle()
        if let card = editor.paged.card(at: fixture.storage.length - 1) {
            reveal(NSPoint(x: card.bounds.width - 72, y: 100), on: card)
            _ = gesture(editor.ruler, from: horizontal(card.bounds.width - 72, on: card),
                        to: horizontal(card.bounds.width - 90, on: card))
            settle()
            check(near(fixture.setup.margins.right, 90)
                  && editor.paged.sections.first.map { near($0.section.margins.right, 78) } == true,
                  "horizontal margin changes only the selected last section")
        }

        editor.textView.setSelectedRange(NSRange(location: 0, length: 0))
        settle()
        if let firstCard = editor.paged.cards.first, let lastCard = editor.paged.cards.last, firstCard !== lastCard {
            editor.scroller.contentView.scroll(to: NSPoint(x: 0, y: lastCard.frame.minY))
            editor.scroller.reflectScrolledClipView(editor.scroller.contentView)
            settle()
            check(!firstCard.frame.intersects(editor.paged.visibleRect) && editor.textView.selectedRange().location == 0,
                  "visible-page fixture scrolls first-section caret completely offscreen")
            let oldTop = fixture.setup.margins.top
            _ = gesture(editor.verticalRuler, from: vertical(oldTop, on: lastCard),
                        to: vertical(oldTop + 24, on: lastCard))
            settle()
            check(near(fixture.setup.margins.top, oldTop + 24)
                  && editor.paged.sections.first.map { near($0.section.margins.top, 72) } == true
                  && editor.textView.selectedRange().location == 0,
                  "vertical ruler changes visible section without moving the offscreen caret")
            editor.beginHeaderEdit(lastCard, header: true)
            let oldLeft = fixture.setup.margins.left
            _ = gesture(editor.ruler, from: horizontal(oldLeft, on: lastCard),
                        to: horizontal(oldLeft + 12, on: lastCard))
            settle()
            check(near(fixture.setup.margins.left, oldLeft + 12)
                  && editor.paged.sections.first.map { near($0.section.margins.left, 60) } == true
                  && editor.textView.selectedRange().location == 0,
                  "header-page horizontal margin targets header section instead of body caret")
            let headerTop = fixture.setup.margins.top
            _ = gesture(editor.verticalRuler, from: vertical(headerTop, on: lastCard),
                        to: vertical(headerTop + 12, on: lastCard))
            settle()
            check(near(fixture.setup.margins.top, headerTop + 12)
                  && editor.paged.sections.first.map { near($0.section.margins.top, 72) } == true,
                  "header-page vertical margin targets header section instead of body caret")
            if let header = editor.headerEditor {
                check(near(header.textView.frame.minX, lastCard.setup.margins.left)
                      && near(header.textView.frame.width, lastCard.setup.textSize.width)
                      && header.textView.textContainer.map { near($0.size.width, lastCard.setup.textSize.width) } == true,
                      "active header layout follows page geometry changes")
                undo.beginUndoGrouping()
                header.commit()
                undo.endUndoGrouping()
            } else { check(true, "page geometry change commits header editor") }
        } else { check(false, "visible-page fixture has two distinct sections") }

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("DOC42-rulers-\(UUID().uuidString).docx")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            try fixture.exportData(.officeOpenXML).write(to: url)
            let reopened = TextDocument()
            try reopened.read(from: url, ofType: "docx")
            let reopenedSections = PagedView(storage: reopened.storage, setup: reopened.setup, configure: { _ in })
            check(sameMargins(reopened.setup.margins, fixture.setup.margins)
                  && reopenedSections.sections.first.map { near($0.section.margins.top, 72) && near($0.section.margins.right, 78) } == true,
                  "ruler margin edits survive DOCX save and reopen")
            reopenedSections.detach()
        } catch { check(false, "DOCX margin round trip: \(error)") }

        reset()
        let printSetup = fixture.setup
        editor.setViewMode(.web)
        settle()
        if let card = editor.paged.cards.first, !editor.ruler.isHidden {
            let left = card.setup.margins.left
            _ = gesture(editor.ruler, from: horizontal(left, on: card), to: horizontal(left + 18, on: card))
        }
        check(fixture.setup == printSetup, "web ruler cannot change hidden print margins")
        editor.setViewMode(.single)
        settle()
        check(editor.ruler.setup == printSetup && editor.verticalRuler.setup == printSetup,
              "returning to print layout restores both ruler geometries")

        print("DOC ruler UI regressions: \(checked - failed)/\(checked) passed")
        return failed == 0
    }
}
