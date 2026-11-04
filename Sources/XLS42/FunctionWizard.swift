import AppKit
import Kit42

/// Insert Function dialog: searchable, grouped list of the supported functions, argument fields
/// with a live preview of the result. `done` receives the finished formula ("=ROUND(A1;2)").
final class FunctionWizard: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSSearchFieldDelegate {
    private let search = NSSearchField()
    private let category = NSPopUpButton(frame: .zero, pullsDown: false)
    private let table = NSTableView()
    private let signature = NSTextField(labelWithString: "")
    private let summary = NSTextField(wrappingLabelWithString: "")
    private let argsGrid = NSStackView()
    private let preview = NSTextField(labelWithString: "")
    private var fields: [NSTextField] = []
    private(set) var shown: [FunctionCatalog.Function] = []
    private(set) var selected: FunctionCatalog.Function?
    /// Evaluates a formula for the preview (the controller computes it at the active cell).
    var evaluate: (String) -> String = { _ in "" }
    var done: ((String) -> Void)?

    init(initial: String?) {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 620, height: 470), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        panel.title = L("Insert Function")
        super.init(window: panel)
        build()
        filter()
        // Prefill from an existing formula =FUNC(args) in the active cell.
        if let initial, initial.hasPrefix("="), let e = try? Formula.parse(initial), case .call(let name, let args) = e,
           let fn = FunctionCatalog.byName[name] {
            select(fn)
            for (i, a) in args.enumerated() where i < fields.count {
                if case .missing = a { continue }
                fields[i].stringValue = Formula.serialize(a)
            }
            updatePreview()
        }
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    private func build() {
        guard let content = window?.contentView else { return }
        search.placeholderString = L("Search functions")
        search.delegate = self
        category.addItem(withTitle: L("All Categories"))
        category.addItems(withTitles: FunctionCatalog.Category.allCases.map(\.title))
        category.target = self
        category.action = #selector(categoryChanged(_:))

        let column = NSTableColumn(identifier: .init("f"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 20
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(insert(_:))
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        signature.font = .monospacedSystemFont(ofSize: 12, weight: .semibold)
        signature.lineBreakMode = .byTruncatingTail
        summary.textColor = .secondaryLabelColor
        argsGrid.orientation = .vertical
        argsGrid.alignment = .leading
        argsGrid.spacing = 6
        preview.font = .systemFont(ofSize: 12, weight: .medium)
        preview.lineBreakMode = .byTruncatingTail

        let insert = NSButton(title: L("Insert"), target: self, action: #selector(insert(_:)))
        insert.keyEquivalent = "\r"
        let cancel = NSButton(title: L("Cancel"), target: self, action: #selector(cancel(_:)))
        cancel.keyEquivalent = "\u{1b}"
        let buttons = NSStackView(views: [preview, NSView(), cancel, insert])

        let top = NSStackView(views: [search, category])
        let details = NSStackView(views: [signature, summary, argsGrid])
        details.orientation = .vertical
        details.alignment = .leading
        details.spacing = 8
        let middle = NSStackView(views: [scroll, details])
        middle.alignment = .top
        middle.spacing = 12
        let root = NSStackView(views: [top, middle, buttons])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 10
        root.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        root.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(root)
        for v in [top, middle, buttons, scroll, details] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            root.topAnchor.constraint(equalTo: content.topAnchor),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            top.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -28),
            middle.widthAnchor.constraint(equalTo: top.widthAnchor),
            buttons.widthAnchor.constraint(equalTo: top.widthAnchor),
            scroll.widthAnchor.constraint(equalToConstant: 210),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 340),
            details.widthAnchor.constraint(greaterThanOrEqualToConstant: 340),
            summary.widthAnchor.constraint(equalTo: details.widthAnchor),
            signature.widthAnchor.constraint(equalTo: details.widthAnchor),
            preview.widthAnchor.constraint(lessThanOrEqualToConstant: 360),
        ])
        window?.initialFirstResponder = search
    }

    // MARK: - List

    /// Shows the functions matching the search text (name or description) and category.
    func filter(_ text: String? = nil) {
        if let text { search.stringValue = text }
        let q = search.stringValue.trimmingCharacters(in: .whitespaces)
        let cat = category.indexOfSelectedItem > 0 ? FunctionCatalog.Category.allCases[category.indexOfSelectedItem - 1] : nil
        let canonical = Formula.canonicalFunction(q)
        shown = FunctionCatalog.all.filter { f in
            (cat == nil || f.category == cat) && (q.isEmpty || f.name.localizedCaseInsensitiveContains(q) || f.name.hasPrefix(canonical)
                                                   || f.description.localizedCaseInsensitiveContains(q))
        }
        // Grouped by category, alphabetical within.
        let order = FunctionCatalog.Category.allCases
        shown.sort { a, b in a.category != b.category ? order.firstIndex(of: a.category)! < order.firstIndex(of: b.category)! : a.name < b.name }
        if !q.isEmpty, let exact = shown.firstIndex(where: { $0.name == canonical }) { shown.insert(shown.remove(at: exact), at: 0) }
        table.reloadData()
        if let first = shown.first, selected.map({ s in !shown.contains { $0.name == s.name } }) ?? true { select(first) }
        else if let s = selected, let i = shown.firstIndex(where: { $0.name == s.name }) { table.selectRowIndexes([i], byExtendingSelection: false) }
    }

    func select(_ fn: FunctionCatalog.Function) {
        selected = fn
        if let i = shown.firstIndex(where: { $0.name == fn.name }) {
            table.selectRowIndexes([i], byExtendingSelection: false)
            table.scrollRowToVisible(i)
        }
        signature.stringValue = fn.signature
        summary.stringValue = fn.description + "  ·  " + fn.category.title
        argsGrid.arrangedSubviews.forEach { $0.removeFromSuperview() }
        fields = []
        for name in Self.fieldNames(fn) {
            let field = NSTextField(string: "")
            field.placeholderString = name.hasPrefix("[") ? L("optional") : ""
            field.delegate = self
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(equalToConstant: 200).isActive = true
            let label = NSTextField(labelWithString: name.trimmingCharacters(in: CharacterSet(charactersIn: "[]")))
            label.alignment = .right
            label.translatesAutoresizingMaskIntoConstraints = false
            label.widthAnchor.constraint(equalToConstant: 130).isActive = true
            argsGrid.addArrangedSubview(NSStackView(views: [label, field]))
            fields.append(field)
        }
        if fn.args.isEmpty { argsGrid.addArrangedSubview(NSTextField(labelWithString: L("This function takes no arguments."))) }
        updatePreview()
    }

    /// Argument fields: the named arguments, repeating groups ("number1, …") expanded to a few entries.
    static func fieldNames(_ fn: FunctionCatalog.Function) -> [String] {
        guard let ellipsis = fn.args.firstIndex(of: "…") else { return fn.args }
        var names = Array(fn.args[..<ellipsis])
        let group = names.filter { $0.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).hasSuffix("1") }
        guard !group.isEmpty else { return names }
        var n = 2
        while names.count < 6 {
            for g in group {
                let base = g.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).dropLast()
                let next = "[\(base)\(n)]"
                if !names.contains(next) && !names.contains(String(next.dropFirst().dropLast())) { names.append(next) }
            }
            n += 1
        }
        return names
    }

    func setArguments(_ values: [String]) {
        for (i, v) in values.enumerated() where i < fields.count { fields[i].stringValue = v }
        updatePreview()
    }

    /// "=NAME(a;b)" from the fields, trailing empty arguments dropped.
    var formula: String {
        guard let fn = selected else { return "" }
        var values = fields.map { $0.stringValue.trimmingCharacters(in: .whitespaces) }
        while values.last?.isEmpty == true { values.removeLast() }
        return "=\(fn.name)(\(values.joined(separator: ";")))"
    }

    private func updatePreview() {
        guard selected != nil else { preview.stringValue = ""; return }
        preview.stringValue = L("Result: %@", evaluate(formula))
    }

    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let f = shown[row]
        let showHeader = row == 0 || shown[row - 1].category != f.category
        let label = NSTextField(labelWithString: "")
        let text = NSMutableAttributedString(string: f.name, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)])
        if showHeader && search.stringValue.isEmpty && category.indexOfSelectedItem == 0 {
            text.append(NSAttributedString(string: "   " + f.category.title, attributes: [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.secondaryLabelColor]))
        }
        label.attributedStringValue = text
        label.toolTip = f.description
        return label
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let i = table.selectedRow
        guard i >= 0, i < shown.count, shown[i].name != selected?.name else { return }
        select(shown[i])
    }

    func controlTextDidChange(_ obj: Notification) {
        if (obj.object as? NSSearchField) === search { filter() } else { updatePreview() }
    }

    @objc private func categoryChanged(_ sender: Any?) { filter() }

    @objc private func insert(_ sender: Any?) {
        guard selected != nil else { NSSound.beep(); return }
        let f = formula
        close(sender)
        done?(f)
    }

    @objc private func cancel(_ sender: Any?) { close(sender) }

    private func close(_ sender: Any?) {
        guard let window else { return }
        if let parent = window.sheetParent { parent.endSheet(window) } else { window.orderOut(sender) }
    }
}

extension SheetWindowController {
    /// Insert › Function… (also the fx label in the formula bar).
    @objc func insertFunctionAction(_ sender: Any?) {
        guard let window else { return }
        let editingText = grid.isEditing ? grid.editorText : nil
        grid.savedCaret = editingText == nil ? nil : formulaCaret ?? grid.editorCaret
        let wizard = FunctionWizard(initial: editingText ?? sheet[grid.active].input)
        wizard.evaluate = { [weak self] f in self?.previewFormula(f) ?? "" }
        wizard.done = { [weak self] f in self?.insertFunction(f, editing: editingText) }
        functionWizard = wizard
        if let panel = wizard.window { window.beginSheet(panel) { [weak self] _ in self?.functionWizard = nil } }
    }

    /// Result of a formula evaluated at the active cell (for previews), as displayed text.
    func previewFormula(_ formula: String) -> String {
        guard let doc, let e = try? Formula.parse(formula) else { return "#NAME?" }
        let calc = Calculator(doc.workbook)
        let v = calc.scalar(calc.eval(e, sheet: sheetIndex, at: grid.active), at: grid.active)
        if case .bool(let b) = v { return b ? L("TRUE") : L("FALSE") }
        return NumberFormat.format(v, "General").text
    }

    /// Puts the wizard's formula into the cell being edited (at the caret, inside a formula) or the active cell.
    func insertFunction(_ formula: String, editing: String?) {
        if let editing, editing.hasPrefix("="), editing.count > 1 {
            grid.insertIntoEditor(String(formula.dropFirst()))
        } else {
            grid.cancelEdit()
            setInput(formula, at: grid.active)
        }
    }

    /// Signature of the function being typed, shown under the formula bar.
    func updateSignatureHint(_ text: String) {
        guard text.hasPrefix("="), let (fn, arg) = FunctionCatalog.call(at: text) else { hideSignatureHint(); return }
        let sep = NumberFormat.decimal == "," ? "; " : ", "
        let parts = fn.args.enumerated().map { i, a -> NSAttributedString in
            let bold = i == min(arg, fn.args.count - 1) && a != "…"
            return NSAttributedString(string: a, attributes: [.font: bold ? NSFont.boldSystemFont(ofSize: 11) : NSFont.systemFont(ofSize: 11)])
        }
        let s = NSMutableAttributedString(string: fn.name + "(", attributes: [.font: NSFont.systemFont(ofSize: 11)])
        for (i, p) in parts.enumerated() {
            if i > 0 { s.append(NSAttributedString(string: sep, attributes: [.font: NSFont.systemFont(ofSize: 11)])) }
            s.append(p)
        }
        s.append(NSAttributedString(string: ")  —  " + fn.description, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]))
        showSignatureHint(s)
    }
}
