import AppKit
import Kit42

/// Chart data editor: a small grid (first row: series names, first column: categories) and the chart type.
final class ChartDataEditor: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    var grid: [[String]]
    var kind: ChartKind
    let table = NSTableView()
    let typePopup = NSPopUpButton()
    private var base: ChartModel

    init(_ m: ChartModel) {
        base = m
        kind = m.kind
        let rows = max(m.categories.count, m.series.map { $0.values.count }.max() ?? 0)
        var g: [[String]] = [[""] + m.series.map(\.name)]
        for r in 0..<rows {
            var row = [m.kind == .scatter ? (m.series.first.flatMap { r < $0.xValues.count ? $0.xValues[r].map { ChartRenderer.format($0) } : nil } ?? "\(r + 1)")
                                         : (r < m.categories.count ? m.categories[r] : "")]
            for s in m.series { row.append(r < s.values.count ? s.values[r].map { Self.plain($0) } ?? "" : "") }
            g.append(row)
        }
        grid = g
        super.init()
    }

    static func plain(_ v: Double) -> String { v == v.rounded() && abs(v) < 1e15 ? String(Int(v)) : String(v) }

    /// The edited model (formatting of the original kept).
    var model: ChartModel {
        var m = base
        let oldKind = m.kind
        m.kind = kind
        let cols = grid.first?.count ?? 1
        let body = grid.dropFirst()
        m.categories = body.map { $0.first ?? "" }
        var series: [ChartSeries] = []
        for c in 1..<max(1, cols) {
            var s = c - 1 < base.series.count ? base.series[c - 1] : ChartSeries(name: "", values: [])
            s.name = grid[0][c].isEmpty ? L("Series %d", c) : grid[0][c]
            s.values = body.map { Double($0[c].replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)) }
            s.xValues = kind == .scatter ? body.map { Double(($0.first ?? "").replacingOccurrences(of: ",", with: ".")) } : []
            series.append(s)
        }
        m.series = series
        if (kind == .pie || kind == .doughnut) && oldKind != kind { m.varyColors = true }
        if kind != .pie && kind != .doughnut && (oldKind == .pie || oldKind == .doughnut) { m.varyColors = false }
        return m
    }

    func view() -> NSView {
        typePopup.removeAllItems()
        for k in ChartKind.allCases {
            typePopup.addItem(withTitle: k.name)
            typePopup.lastItem?.image = NSImage(systemSymbolName: k.symbol, accessibilityDescription: k.name)
        }
        typePopup.selectItem(at: ChartKind.allCases.firstIndex(of: kind) ?? 0)
        typePopup.target = self
        typePopup.action = #selector(typeChanged)
        table.dataSource = self
        table.delegate = self
        table.usesAlternatingRowBackgroundColors = true
        table.gridStyleMask = [.solidVerticalGridLineMask, .solidHorizontalGridLineMask]
        table.headerView = nil
        table.rowHeight = 20
        rebuildColumns()
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.widthAnchor.constraint(equalToConstant: 460).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: 200).isActive = true
        func button(_ title: String, _ action: Selector) -> NSButton {
            let b = NSButton(title: title, target: self, action: action)
            b.bezelStyle = .rounded
            b.controlSize = .small
            return b
        }
        let buttons = NSStackView(views: [button(L("Add Row"), #selector(addRow)), button(L("Delete Row"), #selector(deleteRow)),
                                          button(L("Add Series"), #selector(addSeries)), button(L("Delete Series"), #selector(deleteSeries))])
        buttons.spacing = 6
        let typeRow = NSStackView(views: [NSTextField(labelWithString: L("Chart type:")), typePopup])
        let hint = NSTextField(wrappingLabelWithString: L("First row: series names. First column: categories (scatter: x values)."))
        hint.textColor = .secondaryLabelColor
        hint.font = .systemFont(ofSize: 11)
        hint.preferredMaxLayoutWidth = 460
        let stack = NSStackView(views: [typeRow, scroll, buttons, hint])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.frame.size = stack.fittingSize
        return stack
    }

    private func rebuildColumns() {
        for c in table.tableColumns { table.removeTableColumn(c) }
        let n = grid.first?.count ?? 1
        for i in 0..<n {
            let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("c\(i)"))
            c.width = i == 0 ? 120 : 80
            table.addTableColumn(c)
        }
        table.reloadData()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { grid.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let col = tableColumn.flatMap({ tableView.tableColumns.firstIndex(of: $0) }) else { return nil }
        let f = NSTextField(string: grid[row].indices.contains(col) ? grid[row][col] : "")
        f.isBordered = false
        f.drawsBackground = false
        f.isEditable = !(row == 0 && col == 0)
        f.font = .systemFont(ofSize: 12, weight: row == 0 || col == 0 ? .semibold : .regular)
        f.alignment = col == 0 || row == 0 ? .left : .right
        f.tag = row * 1000 + col
        f.target = self
        f.action = #selector(cellEdited(_:))
        f.placeholderString = row == 0 && col > 0 ? L("Series %d", col) : nil
        return f
    }

    @objc private func cellEdited(_ f: NSTextField) {
        let r = f.tag / 1000, c = f.tag % 1000
        guard grid.indices.contains(r), grid[r].indices.contains(c) else { return }
        grid[r][c] = f.stringValue
    }

    /// Commits a cell still being typed in.
    func commitEditing() {
        if let f = table.window?.firstResponder as? NSTextView, let field = f.delegate as? NSTextField { cellEdited(field) }
    }

    @objc private func typeChanged() { kind = ChartKind.allCases[max(0, typePopup.indexOfSelectedItem)] }

    @objc private func addRow() {
        commitEditing()
        grid.append(["\(L("Category")) \(grid.count)"] + Array(repeating: "", count: max(0, (grid.first?.count ?? 1) - 1)))
        table.reloadData()
    }

    @objc private func deleteRow() {
        commitEditing()
        let r = table.selectedRow > 0 ? table.selectedRow : grid.count - 1
        guard grid.count > 2, r > 0 else { return }
        grid.remove(at: r)
        table.reloadData()
    }

    @objc private func addSeries() {
        commitEditing()
        let n = grid.first?.count ?? 1
        for r in grid.indices { grid[r].append(r == 0 ? L("Series %d", n) : "") }
        rebuildColumns()
    }

    @objc private func deleteSeries() {
        commitEditing()
        let n = grid.first?.count ?? 1
        guard n > 2 else { return }
        let c = table.selectedColumn > 0 ? table.selectedColumn : n - 1
        for r in grid.indices { grid[r].remove(at: c) }
        rebuildColumns()
    }
}

extension DeckWindowController {
    @objc func insertChartAction(_ sender: Any?) {
        editChart(nil)
    }

    /// Insert › Chart… (nil) or Edit Data… of the selected chart.
    func editChart(_ object: SlideObject?) {
        guard let window else { return }
        let editor = ChartDataEditor(object?.chart ?? ChartModel.sample())
        let alert = NSAlert()
        alert.messageText = object == nil ? L("Insert Chart") : L("Chart Data")
        alert.addButton(withTitle: object == nil ? L("Insert") : L("OK"))
        alert.addButton(withTitle: L("Cancel"))
        alert.accessoryView = editor.view()
        chartEditor = editor
        alert.beginSheetModal(for: window) { [weak self] r in
            guard let self else { return }
            self.chartEditor = nil
            guard r == .alertFirstButtonReturn else { return }
            editor.commitEditing()
            self.applyChartEditor(editor, to: object)
        }
    }

    func applyChartEditor(_ editor: ChartDataEditor, to object: SlideObject?) {
        let m = editor.model
        if let object {
            changeSlide(L("Chart Data")) { s in s.update(object.id) { $0.chart = m } }
        } else {
            insertChart(m)
        }
    }

    func insertChart(_ m: ChartModel) {
        let w = deck.size.width * 0.62, h = deck.size.height * 0.6
        var o = SlideObject(id: 0, kind: .chart, frame: CGRect(x: (deck.size.width - w) / 2, y: deck.size.height * 0.25, width: w, height: h))
        o.chart = m
        o.name = L("Chart")
        guard currentSlide != nil else { return }
        var s = displayedSlide
        // An empty content placeholder takes the chart.
        if let ph = s.objects.first(where: { ($0.placeholder?.type == "body" || $0.placeholder?.type == "obj") && ($0.text?.isEmpty ?? true) }),
           s.objects.filter({ $0.placeholder != nil && !($0.placeholder?.isTitle ?? false) && !($0.placeholder?.isFooter ?? false) }).count == 1 {
            o.frame = ph.frame
            s.objects.removeAll { $0.id == ph.id }
        }
        o.id = s.maxID + 1
        s.objects.append(o)
        commit(slide: s, name: L("Insert Chart"))
        selection = [o.id]
    }

    func changeChart(_ name: String, _ body: @escaping (inout ChartModel) -> Void) {
        changeSelected(name) { o in
            guard var m = o.chart else { return }
            body(&m)
            o.chart = m
        }
    }
}
