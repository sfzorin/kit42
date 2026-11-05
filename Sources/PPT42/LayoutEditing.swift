import AppKit
import Kit42

/// Master view: the master and each slide layout are edited in turn (placeholders' position, size and text styles),
/// layouts can be added, duplicated, renamed and deleted, and get placeholders.
extension DeckWindowController {
    var editedLayout: Int? { mode == .master ? masterSelection.flatMap { deck.layouts.indices.contains($0) ? $0 : nil } : nil }

    func selectMaster(_ layout: Int?) {
        commitEditing()
        masterSelection = layout.flatMap { deck.layouts.indices.contains($0) ? $0 : nil }
        selection = []
        thumbnails.syncSelection()
        canvas.slideChanged()
        inspector.reload()
        updateTitle()
    }

    @objc func newLayoutAction(_ sender: Any?) {
        guard mode == .master else { return }
        var l = Layout(name: L("Custom Layout"), type: "cust")
        let title = deck.master.placeholder("title")
        let body = deck.master.placeholder("body")
        var next = 2
        for var p in [title, body].compactMap({ $0 }) {
            p.id = next; next += 1
            if p.placeholder?.type == "body" { p.placeholder?.idx = 1 }
            p.text?.listStyle = ListStyle()
            l.placeholders.append(p)
        }
        for var f in deck.master.placeholders where f.placeholder?.isFooter == true { f.id = next; next += 1; l.placeholders.append(f) }
        let at = (editedLayout ?? deck.layouts.count - 1) + 1
        doc?.change(L("New Layout")) { d in
            let k = min(at, d.layouts.count)
            d.layouts.insert(l, at: k)
            // Slides keep their layouts.
            for i in d.slides.indices where d.slides[i].layout >= k { d.slides[i].layout += 1 }
        }
        thumbnails.reload()
        selectMaster(min(at, deck.layouts.count - 1))
    }

    @objc func duplicateLayoutAction(_ sender: Any?) {
        guard let li = editedLayout else { return }
        var l = deck.layouts[li]
        l.name = L("%@ Copy", Themes.displayName(l))
        doc?.change(L("Duplicate Layout")) { d in
            d.layouts.insert(l, at: li + 1)
            for i in d.slides.indices where d.slides[i].layout > li { d.slides[i].layout += 1 }
        }
        thumbnails.reload()
        selectMaster(li + 1)
    }

    @objc func deleteLayoutAction(_ sender: Any?) {
        guard let li = editedLayout, deck.layouts.count > 1 else { return }
        let fallback = li == 0 ? 0 : li - 1
        doc?.change(L("Delete Layout")) { d in
            d.layouts.remove(at: li)
            for i in d.slides.indices {
                if d.slides[i].layout == li { d.slides[i] = Self.relayout(d.slides[i], to: min(fallback, d.layouts.count - 1), deck: d) }
                else if d.slides[i].layout > li { d.slides[i].layout -= 1 }
            }
        }
        thumbnails.reload()
        selectMaster(min(fallback, deck.layouts.count - 1))
    }

    @objc func renameLayoutAction(_ sender: Any?) {
        guard let li = editedLayout, let window else { return }
        let field = NSTextField(string: Themes.displayName(deck.layouts[li]))
        let alert = NSAlert.form(L("Rename Layout"), ok: L("Rename"), rows: [(L("Name:"), field)])
        alert.beginSheetModal(for: window) { [weak self] r in
            guard r == .alertFirstButtonReturn, let self else { return }
            self.renameLayout(li, field.stringValue)
        }
    }

    func renameLayout(_ li: Int, _ name: String) {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, deck.layouts.indices.contains(li) else { return }
        doc?.change(L("Rename Layout")) { $0.layouts[li].name = n }
        thumbnails.reload()
        updateTitle()
    }

    /// Insert › Placeholder in a layout: 0 content, 1 text, 2 picture, 3 title.
    @objc func insertPlaceholderAction(_ sender: Any?) {
        guard let li = editedLayout else { return }
        let tag = commandTag(of: sender)
        let types = ["body", "body", "pic", "title"]
        let type = types[min(3, max(0, tag))]
        var l = deck.layouts[li]
        if type == "title", l.placeholders.contains(where: { $0.placeholder?.isTitle == true }) { NSSound.beep(); return }
        let id = (l.placeholders.map(\.id).max() ?? 1) + 1
        let idx = (l.placeholders.compactMap { $0.placeholder?.idx }.filter { $0 < 10 }.max() ?? 0) + 1
        let w = deck.size.width * 0.4, h = deck.size.height * 0.35
        var o = Themes.placeholder(id, type, idx: type == "title" ? nil : idx, CGRect(x: (deck.size.width - w) / 2, y: (deck.size.height - h) / 2, width: w, height: h),
                                   name: type == "pic" ? L("Picture Placeholder") : type == "title" ? L("Title") : L("Content Placeholder"))
        if type == "pic" { o.kind = .picture; o.text = nil }
        if tag == 1 { o.text?.listStyle[0] = LevelStyle(bullet: Bullet.none, marL: 0, indent: 0) }
        l.placeholders.append(o)
        doc?.change(L("Insert Placeholder")) { $0.layouts[li] = l }
        selection = [id]
    }
}

extension MasterView {
    /// Name shown for the master / a layout in the sidebar and title.
    static func label(deck: Deck, layout: Int?) -> String {
        guard let li = layout, deck.layouts.indices.contains(li) else { return L("Slide Master") }
        return Themes.displayName(deck.layouts[li])
    }
}
