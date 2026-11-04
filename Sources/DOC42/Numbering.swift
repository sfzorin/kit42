import AppKit
import Kit42

/// List markers are text at the start of list paragraphs ("\t1.\t", like TextEdit); their numbers follow
/// the lists (NSTextList per level, nested in textLists): counted per list, restarted under a new parent item,
/// enclosing numbers prepended for "1.1.1".
enum ListNumbering {
    static let markerPattern = try! NSRegularExpression(pattern: "^\t[^\t\n]*\t")

    /// List paragraphs with the marker they should show.
    static func markers(_ text: NSAttributedString) -> [(range: NSRange, marker: String, level: Int)] {
        var out: [(NSRange, String, Int)] = []
        var counters: [ObjectIdentifier: Int] = [:]
        var lastAtLevel: [ObjectIdentifier: [Int: NSTextList]] = [:]   // root → level → list that counted last
        let ns = text.string as NSString
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: [.byParagraphs, .substringNotRequired]) { _, _, r, _ in
            guard r.length > 0 || r.location < text.length,
                  let p = text.attribute(.paragraphStyle, at: min(r.location, text.length - 1), effectiveRange: nil) as? NSParagraphStyle,
                  let list = p.textLists.last, let root = p.textLists.first else { return }
            let level = p.textLists.count - 1
            let rootKey = ObjectIdentifier(root)
            // A new item at this level restarts every deeper level.
            for (l, deeper) in lastAtLevel[rootKey] ?? [:] where l > level { counters[ObjectIdentifier(deeper)] = nil; lastAtLevel[rootKey]?[l] = nil }
            let key = ObjectIdentifier(list)
            let n = (counters[key] ?? (list.startingItemNumber - 1)) + 1
            counters[key] = n
            lastAtLevel[rootKey, default: [:]][level] = list
            var marker = list.marker(forItemNumber: n)
            if list.listOptions.contains(.prependEnclosingMarker), level > 0 {
                var prefix = ""
                for k in 0..<level {
                    let outer = p.textLists[k]
                    prefix += outer.marker(forItemNumber: max(1, counters[ObjectIdentifier(outer)] ?? outer.startingItemNumber))
                }
                marker = prefix + marker
            }
            out.append((r, marker, level))
        }
        return out
    }

    /// Marker text currently at the start of a paragraph.
    static func currentMarker(_ text: NSAttributedString, _ r: NSRange) -> NSRange? {
        markerPattern.firstMatch(in: text.string, options: .anchored, range: r)?.range
    }

    /// Changes needed to bring the markers up to date (range of the old marker, new marker text with "\t").
    static func changes(_ text: NSAttributedString) -> [(NSRange, String)] {
        markers(text).compactMap { m in
            let want = "\t\(m.marker)\t"
            if let cur = currentMarker(text, m.range) {
                return (text.string as NSString).substring(with: cur) == want ? nil : (cur, want)
            }
            return (NSRange(location: m.range.location, length: 0), want)
        }
    }

    /// Default marker format for a nesting level (bullets or numbers).
    static func format(forLevel level: Int, numbered: Bool) -> NSTextList.MarkerFormat {
        numbered ? NSTextList.MarkerFormat(rawValue: ["{decimal}.", "{lower-alpha}.", "{lower-roman}."][level % 3]) : [.disc, .circle, .square][level % 3]
    }

    /// Indents of a list paragraph at `level`.
    static func indent(_ p: NSMutableParagraphStyle, level: Int, heading: Bool = false) {
        if heading {
            p.headIndent = 0
            p.firstLineHeadIndent = 0
            p.tabStops = [NSTextTab(textAlignment: .left, location: 0.5), NSTextTab(textAlignment: .left, location: 48)]
            p.defaultTabInterval = 12
            return
        }
        p.headIndent = 36 + CGFloat(level) * 24
        p.firstLineHeadIndent = p.headIndent - 36
        p.tabStops = [NSTextTab(textAlignment: .left, location: p.firstLineHeadIndent + 12), NSTextTab(textAlignment: .left, location: p.headIndent)]
    }
}

/// Number formats offered in the Bullets and Numbering dialog.
struct ListStyleChoice {
    let title: String
    let token: String
    var isBullet: Bool { !token.hasPrefix("{") || ["{disc}", "{circle}", "{square}", "{hyphen}", "{check}", "{diamond}", "{box}"].contains(token) }
    static let all: [ListStyleChoice] = [
        ListStyleChoice(title: L("Bullet •"), token: "{disc}"), ListStyleChoice(title: L("Bullet ◦"), token: "{circle}"),
        ListStyleChoice(title: L("Bullet ▪"), token: "{square}"), ListStyleChoice(title: L("Dash –"), token: "–"),
        ListStyleChoice(title: L("Check ✓"), token: "{check}"), ListStyleChoice(title: L("Numbers 1, 2, 3"), token: "{decimal}"),
        ListStyleChoice(title: L("Letters a, b, c"), token: "{lower-alpha}"), ListStyleChoice(title: L("Letters A, B, C"), token: "{upper-alpha}"),
        ListStyleChoice(title: L("Roman i, ii, iii"), token: "{lower-roman}"), ListStyleChoice(title: L("Roman I, II, III"), token: "{upper-roman}"),
    ]

    /// Splits a marker format into prefix, choice and suffix ("({decimal})" → "(", Numbers, ")").
    static func parse(_ f: NSTextList.MarkerFormat) -> (prefix: String, choice: Int, suffix: String) {
        let raw = f.rawValue
        for (i, c) in all.enumerated() where raw.contains(c.token) {
            let parts = raw.components(separatedBy: c.token)
            return (parts.first ?? "", i, parts.dropFirst().joined(separator: c.token))
        }
        return ("", 0, "")
    }
}

extension DocWindowController {
    // MARK: Keeping numbers right

    func scheduleRenumber() {
        guard !extras.renumberScheduled, !(doc?.undoManager?.isUndoing ?? false), !(doc?.undoManager?.isRedoing ?? false) else { return }
        extras.renumberScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.extras.renumberScheduled = false
            self?.renumberLists(name: nil)
        }
    }

    /// Rewrites list markers whose number is out of date (one undo step).
    func renumberLists(name: String?) {
        guard let storage = textView.textStorage, headerEditor == nil else { return }
        let changes = ListNumbering.changes(storage)
        guard !changes.isEmpty else { return }
        let ranges = changes.map { NSValue(range: $0.0) }
        guard textView.shouldChangeText(inRanges: ranges, replacementStrings: changes.map(\.1)) else { return }
        let sel = textView.selectedRange()
        var shift = 0
        storage.beginEditing()
        for (r, s) in changes.reversed() {
            var attrs = storage.attributes(at: min(r.location, max(0, storage.length - 1)), effectiveRange: nil)
            attrs[.attachment] = nil
            attrs[.docField] = nil
            attrs[.docNote] = nil
            storage.replaceCharacters(in: r, with: NSAttributedString(string: s, attributes: attrs))
            if r.location < sel.location { shift += (s as NSString).length - r.length }
        }
        storage.endEditing()
        textView.didChangeText()
        if let name { textView.undoManager?.setActionName(name) } else { textView.undoManager?.setActionName(L("Renumber List")) }
        textView.setSelectedRange(NSRange(location: max(0, min(storage.length, sel.location + shift)), length: sel.length))
    }

    // MARK: List levels (Tab / Shift-Tab)

    /// Moves list paragraphs a level down (`by` 1) or up (-1). Returns false when the selection is not at a list item's start.
    @discardableResult
    func changeListLevel(by delta: Int, onlyAtStart: Bool = true) -> Bool {
        guard let storage = textView.textStorage, storage.length > 0 else { return false }
        let ns = storage.string as NSString
        let sel = textView.selectedRange()
        var paragraphs: [NSRange] = []
        ns.enumerateSubstrings(in: ns.paragraphRange(for: sel), options: [.byParagraphs, .substringNotRequired]) { _, _, r, _ in paragraphs.append(r) }
        if paragraphs.isEmpty { paragraphs = [ns.paragraphRange(for: sel)] }
        guard let first = paragraphs.first, first.location < storage.length,
              let p0 = storage.attribute(.paragraphStyle, at: first.location, effectiveRange: nil) as? NSParagraphStyle, !p0.textLists.isEmpty else { return false }
        if onlyAtStart, sel.length == 0 {
            let marker = ListNumbering.currentMarker(storage, first)
            guard sel.location <= NSMaxRange(marker ?? NSRange(location: first.location, length: 0)) else { return false }
        }
        guard textView.shouldChangeText(inRanges: paragraphs.map { NSValue(range: $0) }, replacementStrings: nil) else { return true }
        storage.beginEditing()
        for r in paragraphs where r.location < storage.length {
            guard let p = storage.attribute(.paragraphStyle, at: r.location, effectiveRange: nil) as? NSParagraphStyle, let root = p.textLists.first else { continue }
            var lists = p.textLists
            if delta > 0, lists.count < 9 {
                // Same list as the previous item at that level, else a new one.
                let level = lists.count
                var reuse: NSTextList?
                var k = r.location - 1
                while k > 0, reuse == nil {
                    let pr = ns.paragraphRange(for: NSRange(location: k, length: 0))
                    if let q = storage.attribute(.paragraphStyle, at: pr.location, effectiveRange: nil) as? NSParagraphStyle, q.textLists.first === root {
                        if q.textLists.count > level, q.textLists[level - 1] === lists.last { reuse = q.textLists[level] }
                        if q.textLists.count <= level - 1 { break }
                    } else { break }
                    k = pr.location - 1
                }
                let numbered = !ListStyleChoice.all[ListStyleChoice.parse(lists.last!.markerFormat).choice].isBullet
                let new = reuse ?? NSTextList(markerFormat: ListNumbering.format(forLevel: level, numbered: numbered),
                                              options: lists.last!.listOptions.contains(.prependEnclosingMarker) ? Int(NSTextList.Options.prependEnclosingMarker.rawValue) : 0)
                lists.append(new)
            } else if delta < 0, lists.count > 1 {
                lists.removeLast()
            } else { continue }
            let m = p.mutableCopy() as! NSMutableParagraphStyle
            m.textLists = lists
            ListNumbering.indent(m, level: lists.count - 1, heading: (storage.attribute(Styles.styleKey, at: r.location, effectiveRange: nil) as? String)?.hasPrefix("Heading") == true)
            storage.addAttribute(.paragraphStyle, value: m, range: r)
        }
        storage.endEditing()
        textView.didChangeText()
        textView.undoManager?.setActionName(delta > 0 ? L("Demote") : L("Promote"))
        renumberLists(name: delta > 0 ? L("Demote") : L("Promote"))
        return true
    }

    @objc func demoteListAction(_ sender: Any?) { if !changeListLevel(by: 1, onlyAtStart: false) { NSSound.beep() } }
    @objc func promoteListAction(_ sender: Any?) { if !changeListLevel(by: -1, onlyAtStart: false) { NSSound.beep() } }

    // MARK: Bullets and Numbering dialog

    @objc func bulletsAndNumberingAction(_ sender: Any?) {
        guard let storage = textView.textStorage else { return }
        let at = min(textView.selectedRange().location, max(0, storage.length - 1))
        let p = storage.length > 0 ? storage.attribute(.paragraphStyle, at: at, effectiveRange: nil) as? NSParagraphStyle : nil
        let current = p?.textLists.last
        let parsed = current.map { ListStyleChoice.parse($0.markerFormat) } ?? ("", 0, "")
        let type = NSPopUpButton(frame: .zero, pullsDown: false)
        type.addItems(withTitles: ListStyleChoice.all.map(\.title) + [L("None (remove the list)")])
        type.selectItem(at: parsed.1)
        let prefix = NSTextField(string: parsed.0), suffix = NSTextField(string: current == nil ? "." : parsed.2)
        let start = NSTextField(string: "\(current?.startingItemNumber ?? 1)")
        let sub = NSButton(checkboxWithTitle: L("Show the numbers of higher levels (1.1, 1.1.1)"), target: nil, action: nil)
        sub.state = current?.listOptions.contains(.prependEnclosingMarker) == true ? .on : .off
        let restart = NSButton(checkboxWithTitle: L("Restart numbering here"), target: nil, action: nil)
        let alert = NSAlert.form(L("Bullets and Numbering"), info: L("Applies to this list level. Tab and Shift-Tab at the start of an item change its level."), ok: L("Apply"),
                                 rows: [(L("Type:"), type), (L("Before:"), prefix), (L("After:"), suffix), (L("Start at:"), start), ("", sub), ("", restart)])
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if type.indexOfSelectedItem >= ListStyleChoice.all.count {
            removeList()
            return
        }
        var o = ListOptions()
        o.choice = type.indexOfSelectedItem
        o.prefix = prefix.stringValue
        o.suffix = suffix.stringValue
        o.start = Int(start.stringValue) ?? 1
        o.showLevels = sub.state == .on
        o.restart = restart.state == .on
        applyListOptions(o)
    }

    struct ListOptions {
        var choice = 5
        var prefix = ""
        var suffix = "."
        var start = 1
        var showLevels = false
        var restart = false
    }

    func listFormat(_ o: ListOptions) -> NSTextList.MarkerFormat {
        let c = ListStyleChoice.all[max(0, min(ListStyleChoice.all.count - 1, o.choice))]
        return NSTextList.MarkerFormat(rawValue: c.isBullet ? o.prefix + c.token + (o.suffix == "." ? "" : o.suffix) : o.prefix + c.token + o.suffix)
    }

    /// Applies a list format to the selected paragraphs' level (the whole list at that level), or makes them a list.
    func applyListOptions(_ o: ListOptions) {
        guard let storage = textView.textStorage, storage.length > 0 else { return }
        let ns = storage.string as NSString
        let sel = textView.selectedRange()
        let here = ns.paragraphRange(for: sel)
        guard let p = storage.attribute(.paragraphStyle, at: min(here.location, storage.length - 1), effectiveRange: nil) as? NSParagraphStyle else { return }
        let options = o.showLevels ? Int(NSTextList.Options.prependEnclosingMarker.rawValue) : 0
        let new = NSTextList(markerFormat: listFormat(o), options: options)
        new.startingItemNumber = o.start
        var targets: [(NSRange, [NSTextList])] = []
        if let old = p.textLists.last, let root = p.textLists.first {
            let level = p.textLists.count - 1
            let restartRoot = o.restart && level == 0
            // Every paragraph of the list: this level's list is replaced (from here on when restarting).
            ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: [.byParagraphs, .substringNotRequired]) { _, _, r, _ in
                guard r.location < storage.length, let q = storage.attribute(.paragraphStyle, at: r.location, effectiveRange: nil) as? NSParagraphStyle,
                      q.textLists.first === root else { return }
                if o.restart, r.location < here.location { return }
                var lists = q.textLists
                if lists.count > level, lists[level] === old { lists[level] = new } else if restartRoot { lists[0] = new } else { return }
                targets.append((r, lists))
            }
        } else {
            ns.enumerateSubstrings(in: here, options: [.byParagraphs, .substringNotRequired]) { _, _, r, _ in targets.append((r, [new])) }
            if targets.isEmpty { targets = [(here, [new])] }
        }
        guard !targets.isEmpty, textView.shouldChangeText(inRanges: targets.map { NSValue(range: $0.0) }, replacementStrings: nil) else { return }
        storage.beginEditing()
        for (r, lists) in targets where r.location < storage.length {
            storage.enumerateAttribute(.paragraphStyle, in: r) { v, sub, _ in
                let m = ((v as? NSParagraphStyle) ?? .default).mutableCopy() as! NSMutableParagraphStyle
                let wasList = !m.textLists.isEmpty
                m.textLists = lists
                if !wasList { ListNumbering.indent(m, level: lists.count - 1, heading: (storage.attribute(Styles.styleKey, at: r.location, effectiveRange: nil) as? String)?.hasPrefix("Heading") == true) }
                storage.addAttribute(.paragraphStyle, value: m, range: sub)
            }
        }
        storage.endEditing()
        textView.didChangeText()
        textView.undoManager?.setActionName(L("Bullets and Numbering"))
        renumberLists(name: L("Bullets and Numbering"))
    }

    func removeList() {
        guard let storage = textView.textStorage, storage.length > 0 else { return }
        let ns = storage.string as NSString
        var paragraphs: [NSRange] = []
        ns.enumerateSubstrings(in: ns.paragraphRange(for: textView.selectedRange()), options: [.byParagraphs, .substringNotRequired]) { _, _, r, _ in paragraphs.append(r) }
        let out = NSMutableAttributedString()
        guard let full = paragraphs.first.map({ NSRange(location: $0.location, length: NSMaxRange(paragraphs.last!) - $0.location) }) else { return }
        for r in paragraphs {
            let para = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: r))
            if let m = ListNumbering.currentMarker(para, NSRange(location: 0, length: para.length)) { para.deleteCharacters(in: m) }
            para.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: para.length)) { v, sub, _ in
                let m = ((v as? NSParagraphStyle) ?? .default).mutableCopy() as! NSMutableParagraphStyle
                m.textLists = []; m.headIndent = 0; m.firstLineHeadIndent = 0; m.tabStops = []
                para.addAttribute(.paragraphStyle, value: m, range: sub)
            }
            out.append(para)
        }
        guard textView.shouldChangeText(in: full, replacementString: out.string) else { return }
        storage.replaceCharacters(in: full, with: out)
        textView.didChangeText()
        textView.undoManager?.setActionName(L("Bullets and Numbering"))
        renumberLists(name: nil)
    }

    // MARK: Outline (chapter) numbering

    /// The lists numbering the headings (levels 1–6), from the first numbered heading of each level.
    var outlineLists: [NSTextList] {
        guard let storage = textView.textStorage else { return [] }
        var found: [NSTextList] = []
        storage.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: storage.length)) { v, r, stop in
            guard let p = v as? NSParagraphStyle, !p.textLists.isEmpty, (storage.attribute(Styles.styleKey, at: r.location, effectiveRange: nil) as? String)?.hasPrefix("Heading") == true else { return }
            if p.textLists.count > found.count { found = p.textLists }
            if found.count >= 6 { stop.pointee = true }
        }
        return found
    }

    @objc func outlineNumberingAction(_ sender: Any?) {
        let current = outlineLists
        let preset = NSPopUpButton(frame: .zero, pullsDown: false)
        preset.addItems(withTitles: ["1, 1.1, 1.1.1", "I, A, 1, a", "1), a), i)", L("None")])
        let first = current.first.map { ListStyleChoice.parse($0.markerFormat).choice } ?? 5
        preset.selectItem(at: first == 9 ? 1 : current.first?.markerFormat.rawValue.hasSuffix(")") == true ? 2 : 0)
        let start = NSTextField(string: "\(current.first?.startingItemNumber ?? 1)")
        let alert = NSAlert.form(L("Outline Numbering"), info: L("Numbers the headings: Heading 1 is 1, Heading 2 is 1.1 and so on. Saved in .docx as Word's outline numbering."),
                                 ok: L("Apply"), rows: [(L("Numbering:"), preset), (L("Start at:"), start)])
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        applyOutlineNumbering(preset: preset.indexOfSelectedItem, start: Int(start.stringValue) ?? 1)
    }

    /// Numbers every heading (Heading 1–6) with one multi-level list; preset 4 removes the numbers.
    func applyOutlineNumbering(preset: Int, start: Int = 1) {
        guard let storage = textView.textStorage else { return }
        let formats: [[String]] = [
            Array(repeating: "{decimal}.", count: 6),
            ["{upper-roman}.", "{upper-alpha}.", "{decimal}.", "{lower-alpha})", "{lower-roman})", "{decimal})"],
            ["{decimal})", "{lower-alpha})", "{lower-roman})", "{decimal})", "{lower-alpha})", "{lower-roman})"],
        ]
        var lists: [NSTextList] = []
        if preset < formats.count {
            for (k, f) in formats[preset].enumerated() {
                let l = NSTextList(markerFormat: NSTextList.MarkerFormat(rawValue: f), options: preset == 0 && k > 0 ? Int(NSTextList.Options.prependEnclosingMarker.rawValue) : 0)
                if k == 0 { l.startingItemNumber = start }
                lists.append(l)
            }
        }
        let ns = storage.string as NSString
        var targets: [NSRange] = []
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: [.byParagraphs, .substringNotRequired]) { _, _, r, _ in
            guard r.location < storage.length, let id = storage.attribute(Styles.styleKey, at: r.location, effectiveRange: nil) as? String,
                  id.hasPrefix("Heading"), let n = Int(id.dropFirst(7)), (1...6).contains(n) else { return }
            targets.append(r)
        }
        guard !targets.isEmpty else { NSSound.beep(); return }
        let out = NSMutableAttributedString(attributedString: storage)
        for r in targets.reversed() {
            let n = Int((storage.attribute(Styles.styleKey, at: r.location, effectiveRange: nil) as! String).dropFirst(7))!
            if let m = ListNumbering.currentMarker(out, r) { out.deleteCharacters(in: m) }
            let range = NSRange(location: r.location, length: r.length - (ListNumbering.currentMarker(storage, r)?.length ?? 0))
            out.enumerateAttribute(.paragraphStyle, in: range) { v, sub, _ in
                let m = ((v as? NSParagraphStyle) ?? .default).mutableCopy() as! NSMutableParagraphStyle
                m.textLists = lists.isEmpty ? [] : Array(lists[0..<n])
                if lists.isEmpty { m.tabStops = []; m.headIndent = 0; m.firstLineHeadIndent = 0 } else { ListNumbering.indent(m, level: n - 1, heading: true) }
                out.addAttribute(.paragraphStyle, value: m, range: sub)
            }
        }
        // Only the headings change: replace the span from the first to the last heading.
        let span = NSRange(location: targets.first!.location, length: NSMaxRange(targets.last!) - targets.first!.location)
        let delta = out.length - storage.length
        let replacement = out.attributedSubstring(from: NSRange(location: span.location, length: span.length + delta))
        textView.breakUndoCoalescing()
        doc?.undoManager?.beginUndoGrouping()
        if textView.shouldChangeText(in: span, replacementString: replacement.string) {
            storage.replaceCharacters(in: span, with: replacement)
            textView.didChangeText()
        }
        renumberLists(name: L("Outline Numbering"))
        doc?.undoManager?.setActionName(L("Outline Numbering"))
        doc?.undoManager?.endUndoGrouping()
    }
}
