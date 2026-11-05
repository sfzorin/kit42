import AppKit
import Kit42

extension DocWindowController {
    /// K42_SCRIPT=auditpagination after opening the rich DOCX fixture. Isolated copies
    /// check actual laid-out ranges, so a successful screenshot of only page one cannot pass.
    func auditPagination() -> Bool {
        guard let source = doc else { print("FAIL DOC pagination: no source document"); return false }
        var count = 0, failures = 0
        func check(_ ok: Bool, _ name: String) {
            count += 1
            if !ok { failures += 1 }
            print("\(ok ? "PASS" : "FAIL") DOC pagination: \(name)")
            fflush(stdout)
        }
        func withDocument(_ document: TextDocument, _ body: (TextDocument, DocWindowController) -> Void) {
            document.makeWindowControllers()
            guard let editor = document.editor else { check(false, "create fixture editor"); return }
            let undo = document.undoManager
            undo?.groupsByEvent = false
            undo?.disableUndoRegistration()
            defer {
                undo?.enableUndoRegistration()
                undo?.removeAllActions()
                document.updateChangeCount(.changeCleared)
                document.close()
                editor.paged.detach()
            }
            editor.paged.layoutAll()
            body(document, editor)
        }
        func fixture(_ text: NSAttributedString, _ body: (TextDocument, DocWindowController) -> Void) {
            let document = TextDocument()
            document.storage.setAttributedString(text)
            withDocument(document, body)
        }
        func coversAllText(_ editor: DocWindowController) -> Bool {
            editor.paged.layoutAll()
            let layout = editor.paged.layoutManager
            let textLength = editor.textView.textStorage?.length ?? 0
            let glyphCount = layout.numberOfGlyphs
            var glyphEnd = 0, characterEnd = 0, contiguous = true
            var containerDetails: [(Int, NSRange, NSRange, NSSize)] = []
            for (index, container) in layout.textContainers.enumerated() {
                let glyphs = layout.glyphRange(for: container)
                let characters = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
                containerDetails.append((index, glyphs, characters, container.size))
                guard glyphs.length > 0 else { continue }
                if glyphs.location > glyphEnd { contiguous = false }
                glyphEnd = max(glyphEnd, NSMaxRange(glyphs))
                characterEnd = max(characterEnd, NSMaxRange(characters))
            }
            let ok = contiguous && glyphEnd >= glyphCount && characterEnd >= textLength
                && layout.firstUnlaidCharacterIndex() >= textLength
            if !ok {
                print("DOC pagination coverage: pages=\(editor.paged.cards.count), characters=\(characterEnd)/\(textLength), glyphs=\(glyphEnd)/\(glyphCount), firstUnlaid=\(layout.firstUnlaidCharacterIndex()), contiguous=\(contiguous)")
                for (index, glyphs, characters, size) in containerDetails {
                    print("DOC pagination container \(index): glyphs=\(glyphs), characters=\(characters), size=\(size)")
                }
                for (index, page) in editor.paged.cards.enumerated() {
                    print("DOC pagination page \(index + 1): start=\(page.characterStart), section=\(page.sectionIndex), balancedHeight=\(String(describing: page.balancedHeight)), balanceKey=\(page.balanceKey)")
                }
                if let text = editor.textView.textStorage?.string as NSString?, characterEnd < text.length {
                    let tail = text.substring(with: NSRange(location: characterEnd, length: min(512, text.length - characterEnd)))
                    print("DOC pagination missing tail at \(characterEnd): \(tail.debugDescription)")
                }
                fflush(stdout)
            }
            return ok
        }

        do {
            // An attributed-string copy shares mutable attachment/field cells with its
            // source. Reparse DOCX so reflow cannot alter the original editor's objects;
            // this also carries the document's styles and rich headers/footers.
            let isolated = TextDocument()
            try isolated.read(from: source.exportData(.officeOpenXML), ofType: "docx")
            withDocument(isolated) { document, editor in
                let richText = document.storage.string
                editor.setViewMode(.single)
                check(coversAllText(editor), "rich document lays out every character and glyph")
                let baseline = editor.paged.cards.count
                check(document.storage.length > 1000 && baseline > 1, "rich fixture really occupies multiple pages")
                for (mode, label) in [(PagedView.ViewMode.book, "book"), (.multi, "multiple pages"), (.single, "single page")] {
                    editor.setViewMode(mode)
                    check(coversAllText(editor) && document.storage.string == richText,
                          "\(label) layout preserves and lays out the complete rich text")
                    check(editor.paged.cards.count == baseline, "\(label) layout preserves the printed page count")
                }
                for columns in [2, 3, 1] {
                    let applied = editor.changeSetup("Pagination regression", wholeDocument: true) { $0.columns = columns }
                    check(applied && coversAllText(editor) && document.storage.string == richText,
                          "\(columns)-column reflow reaches the final character")
                }
            }
        } catch { check(false, "isolate rich DOCX fixture: \(error)") }

        let plain = Array(repeating: "Pagination must keep the final sentence visible when the font size changes.", count: 60).joined(separator: "\n")
        let small: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .paragraphStyle: NSParagraphStyle.default]
        fixture(NSAttributedString(string: plain, attributes: small)) { document, editor in
            check(coversAllText(editor), "font-growth fixture initially has complete layout")
            let before = editor.paged.cards.count
            document.storage.addAttribute(.font, value: NSFont.systemFont(ofSize: 28), range: NSRange(location: 0, length: document.storage.length))
            check(coversAllText(editor) && editor.paged.cards.count > before && document.storage.string == plain,
                  "larger font grows existing pagination without dropping the tail")
            document.storage.addAttribute(.font, value: NSFont.systemFont(ofSize: 11), range: NSRange(location: 0, length: document.storage.length))
            check(coversAllText(editor) && editor.paged.cards.count == before,
                  "smaller font removes obsolete trailing pages")
        }

        let sections = NSMutableAttributedString()
        for index in 0..<16 {
            sections.append(NSAttributedString(string: "Section \(index + 1).\n", attributes: small))
            var setup = PageSetup()
            setup.size = NSSize(width: 500 + CGFloat(index % 3) * 25, height: 700 + CGFloat(index % 2) * 30)
            setup.margins.top = 48 + CGFloat(index)
            var attributes = small
            attributes[.docSection] = setup.section
            sections.append(NSAttributedString(string: "\u{000C}", attributes: attributes))
            sections.append(NSAttributedString(string: "\n", attributes: small))
        }
        sections.append(NSAttributedString(string: "Final section.", attributes: small))
        fixture(sections) { document, editor in
            check(coversAllText(editor) && editor.paged.cards.count >= 16,
                  "section fixture exceeds one reconciliation pass")
            document.storage.setAttributedString(NSAttributedString(string: "", attributes: small))
            editor.textView.setSelectedRange(NSRange(location: 0, length: 0))
            check(coversAllText(editor) && editor.paged.cards.count == 1,
                  "deleting all sections leaves exactly one empty page")
        }

        print("DOC pagination UI regressions: \(count - failures)/\(count) passed")
        return failures == 0
    }
}
