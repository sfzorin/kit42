import AppKit
import Kit42

/// A table as it is in the text: cells (paragraph ranges sharing a block) with their grid positions and spans.
final class TableCell {
    var row: Int, col: Int, rowSpan: Int, colSpan: Int
    var range: NSRange
    let block: NSTextTableBlock
    init(_ b: NSTextTableBlock, range: NSRange) {
        row = b.startingRow; col = b.startingColumn; rowSpan = max(1, b.rowSpan); colSpan = max(1, b.columnSpan)
        self.range = range
        block = b
    }
    func text(in s: NSAttributedString) -> String {
        (s.string as NSString).substring(with: range).trimmingCharacters(in: .newlines).replacingOccurrences(of: "\n", with: " ")
    }
}

struct TableGrid {
    let table: NSTextTable
    let range: NSRange
    var cells: [TableCell]
    var rows: Int
    var columns: Int

    static func block(_ s: NSAttributedString, at i: Int) -> NSTextTableBlock? {
        guard s.length > 0 else { return nil }
        return (s.attribute(.paragraphStyle, at: min(max(0, i), s.length - 1), effectiveRange: nil) as? NSParagraphStyle)?.textBlocks.last as? NSTextTableBlock
    }

    init?(_ s: NSAttributedString, at index: Int) {
        let ns = s.string as NSString
        let loc = min(max(0, index), max(0, s.length - 1))
        guard let current = Self.block(s, at: loc) else { return nil }
        let table = current.table
        var start = ns.paragraphRange(for: NSRange(location: loc, length: 0)).location
        while start > 0, Self.block(s, at: start - 1)?.table === table { start = ns.paragraphRange(for: NSRange(location: start - 1, length: 0)).location }
        var end = NSMaxRange(ns.paragraphRange(for: NSRange(location: loc, length: 0)))
        while end < s.length, Self.block(s, at: end)?.table === table { end = NSMaxRange(ns.paragraphRange(for: NSRange(location: end, length: 0))) }
        self.table = table
        range = NSRange(location: start, length: end - start)
        cells = []
        var p = start
        while p < end {
            let pr = ns.paragraphRange(for: NSRange(location: p, length: 0))
            if let b = Self.block(s, at: pr.location) {
                if let last = cells.last, last.block === b, NSMaxRange(last.range) == pr.location { last.range.length += pr.length } else { cells.append(TableCell(b, range: pr)) }
            }
            p = NSMaxRange(pr)
        }
        rows = cells.map { $0.row + $0.rowSpan }.max() ?? 0
        columns = max(table.numberOfColumns, cells.map { $0.col + $0.colSpan }.max() ?? 0)
    }

    func cell(containing index: Int) -> TableCell? {
        cells.first { NSLocationInRange(index, $0.range) } ?? (index == NSMaxRange(range) ? cells.last : nil)
    }

    func cell(row: Int, col: Int) -> TableCell? {
        cells.first { row >= $0.row && row < $0.row + $0.rowSpan && col >= $0.col && col < $0.col + $0.colSpan }
    }
}

/// Editable copy of a table: a grid of cells (nil where a span covers), column widths in percent.
struct TableModel {
    struct Cell {
        var content: NSAttributedString
        var rowSpan = 1
        var colSpan = 1
        var props: CellProps
    }
    var rows: [[Cell?]]
    var widths: [CGFloat]
    var headerRows = 0
    var columns: Int { widths.count }

    init(rows: [[Cell?]], widths: [CGFloat], headerRows: Int = 0) {
        self.rows = rows
        self.widths = widths
        self.headerRows = headerRows
    }

    init(_ g: TableGrid, _ s: NSAttributedString) {
        var grid = [[Cell?]](repeating: [Cell?](repeating: nil, count: g.columns), count: g.rows)
        var widths = [CGFloat](repeating: 0, count: g.columns)
        for c in g.cells {
            grid[c.row][c.col] = Cell(content: s.attributedSubstring(from: c.range), rowSpan: c.rowSpan, colSpan: c.colSpan, props: CellProps(c.block))
            if c.colSpan == 1, widths[c.col] == 0, c.block.valueType(for: .width) == .percentageValueType { widths[c.col] = c.block.value(for: .width) }
        }
        let known = widths.reduce(0, +), unknown = widths.filter { $0 == 0 }.count
        if unknown > 0 { widths = widths.map { $0 > 0 ? $0 : max(5, (100 - known) / CGFloat(unknown)) } }
        let total = widths.reduce(0, +)
        self.widths = widths.map { $0 / max(1, total) * 100 }
        rows = grid
        headerRows = (g.table as? DocTextTable)?.headerRows ?? 0
    }

    /// Anchor (top-left) of the cell covering a position.
    func anchor(_ r: Int, _ c: Int) -> (Int, Int)? {
        for rr in stride(from: r, through: 0, by: -1) {
            for cc in stride(from: c, through: 0, by: -1) {
                if let cell = rows[rr][cc], rr + cell.rowSpan > r, cc + cell.colSpan > c { return (rr, cc) }
            }
        }
        return nil
    }

    static func empty(_ attrs: [NSAttributedString.Key: Any]) -> NSAttributedString {
        NSAttributedString(string: "\n", attributes: attrs.filter { $0.key != .paragraphStyle && $0.key != .attachment })
    }

    /// The table as text, every cell a new block of a new table.
    func render(template: CellProps = CellProps()) -> NSAttributedString {
        let table = DocTextTable()
        table.numberOfColumns = max(1, columns)
        table.collapsesBorders = true
        table.layoutAlgorithm = .automaticLayoutAlgorithm
        table.headerRows = headerRows
        let out = NSMutableAttributedString()
        for (r, row) in rows.enumerated() {
            for (c, cell) in row.enumerated() {
                guard let cell else { continue }
                let block = NSTextTableBlock(table: table, startingRow: r, rowSpan: cell.rowSpan, startingColumn: c, columnSpan: cell.colSpan)
                cell.props.apply(to: block)
                block.setValue(widths[c..<min(columns, c + cell.colSpan)].reduce(0, +), type: .percentageValueType, for: .width)
                let content = NSMutableAttributedString(attributedString: cell.content)
                if content.length == 0 || !content.string.hasSuffix("\n") {
                    content.append(TableModel.empty(content.length > 0 ? content.attributes(at: content.length - 1, effectiveRange: nil) : [.font: Styles.normal.font]))
                }
                content.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: content.length)) { v, range, _ in
                    let p = (v as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
                    p.textBlocks = [block]
                    content.addAttribute(.paragraphStyle, value: p, range: range)
                }
                out.append(content)
            }
        }
        return out
    }
}

/// Look of a cell: borders (per edge), background, padding, vertical alignment.
struct CellProps: Equatable {
    var borders: [CGFloat] = [0.5, 0.5, 0.5, 0.5]   // minX, minY, maxX, maxY
    var colors: [NSColor] = Array(repeating: NSColor(white: 0.6, alpha: 1), count: 4)
    var background: NSColor?
    var padding: CGFloat = 5
    var vertical: NSTextBlock.VerticalAlignment = .topAlignment
    static let edges: [NSRectEdge] = [.minX, .minY, .maxX, .maxY]

    init() {}
    init(_ b: NSTextTableBlock) {
        borders = Self.edges.map { b.width(for: .border, edge: $0) }
        colors = Self.edges.map { b.borderColor(for: $0) ?? NSColor(white: 0.6, alpha: 1) }
        background = b.backgroundColor
        padding = b.width(for: .padding, edge: .minX)
        vertical = b.verticalAlignment
    }

    func apply(to b: NSTextTableBlock) {
        for (i, e) in Self.edges.enumerated() {
            b.setWidth(borders[i], type: .absoluteValueType, for: .border, edge: e)
            b.setBorderColor(colors[i], for: e)
        }
        b.setWidth(padding, type: .absoluteValueType, for: .padding)
        b.backgroundColor = background
        b.verticalAlignment = vertical
    }
}

// MARK: - Editor commands

extension DocWindowController {
    var tableGrid: TableGrid? {
        guard let s = textView.textStorage else { return nil }
        return TableGrid(s, at: textView.selectedRange().location)
    }

    var isInTable: Bool { tableGrid != nil }

    /// Cells touched by the selection (grid rectangle).
    func selectedCellBox(_ g: TableGrid) -> (r0: Int, c0: Int, r1: Int, c1: Int) {
        let sel = textView.selectedRange()
        let touched = g.cells.filter { NSIntersectionRange($0.range, sel).length > 0 || NSLocationInRange(sel.location, $0.range) }
        guard !touched.isEmpty else { return (0, 0, 0, 0) }
        var box = (r0: touched.map(\.row).min()!, c0: touched.map(\.col).min()!,
                   r1: touched.map { $0.row + $0.rowSpan - 1 }.max()!, c1: touched.map { $0.col + $0.colSpan - 1 }.max()!)
        // Grow until no cell sticks out.
        var grew = true
        while grew {
            grew = false
            for c in g.cells where c.row <= box.r1 && c.row + c.rowSpan - 1 >= box.r0 && c.col <= box.c1 && c.col + c.colSpan - 1 >= box.c0 {
                if c.row < box.r0 { box.r0 = c.row; grew = true }
                if c.col < box.c0 { box.c0 = c.col; grew = true }
                if c.row + c.rowSpan - 1 > box.r1 { box.r1 = c.row + c.rowSpan - 1; grew = true }
                if c.col + c.colSpan - 1 > box.c1 { box.c1 = c.col + c.colSpan - 1; grew = true }
            }
        }
        return box
    }

    /// Replaces the table with a changed model (one undo step), caret into cell (row, col).
    func replaceTable(_ g: TableGrid, with m: TableModel, name: String, caret: (Int, Int)) {
        guard let storage = textView.textStorage else { return }
        let hasCells = m.rows.contains { $0.contains { $0 != nil } }
        let text = hasCells ? m.render() : NSAttributedString(string: "")
        guard textView.shouldChangeText(in: g.range, replacementString: text.string) else { return }
        storage.replaceCharacters(in: g.range, with: text)
        textView.didChangeText()
        textView.undoManager?.setActionName(name)
        guard hasCells, let ng = TableGrid(storage, at: g.range.location) else { return }
        let target = ng.cell(row: caret.0, col: caret.1) ?? ng.cells.first
        textView.setSelectedRange(NSRange(location: target?.range.location ?? g.range.location, length: 0))
    }

    private func emptyCell(_ m: TableModel, like other: TableModel.Cell?) -> TableModel.Cell {
        TableModel.Cell(content: TableModel.empty(textView.typingAttributes), props: other?.props ?? CellProps())
    }

    @objc func insertTableAction(_ sender: Any?) {
        let rows = NSTextField(string: "3"), cols = NSTextField(string: "3")
        let header = NSButton(checkboxWithTitle: L("Heading row"), target: nil, action: nil)
        let alert = NSAlert.form(L("Insert Table"), ok: L("Insert"), rows: [(L("Rows:"), rows), (L("Columns:"), cols), ("", header)])
        guard alert.runModal() == .alertFirstButtonReturn,
              let r = Int(rows.stringValue), let c = Int(cols.stringValue), (1...100).contains(r), (1...20).contains(c) else { return }
        insertTable(rows: r, columns: c, header: header.state == .on)
    }

    func insertTable(rows r: Int, columns c: Int, header: Bool = false) {
        let font = (textView.typingAttributes[.font] as? NSFont) ?? Styles.normal.font
        var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        if let p = textView.typingAttributes[.paragraphStyle] as? NSParagraphStyle {
            let q = p.mutableCopy() as! NSMutableParagraphStyle
            q.textLists = []; q.headIndent = 0; q.firstLineHeadIndent = 0; q.tailIndent = 0; q.paragraphSpacingBefore = 0; q.paragraphSpacing = 0
            attrs[.paragraphStyle] = q
        }
        var model = TableModel(rows: (0..<r).map { _ in (0..<c).map { _ in TableModel.Cell(content: NSAttributedString(string: "\n", attributes: attrs), props: CellProps()) } },
                               widths: Array(repeating: 100 / CGFloat(c), count: c), headerRows: header ? 1 : 0)
        if header {
            let bold = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
            for k in 0..<c { var a = attrs; a[.font] = bold; model.rows[0][k]?.content = NSAttributedString(string: "\n", attributes: a) }
        }
        let out = NSMutableAttributedString()
        let start = textView.selectedRange().location
        let ns = textView.string as NSString
        if start > 0, ns.character(at: start - 1) != 10 { out.append(NSAttributedString(string: "\n", attributes: [.font: font])) }
        let firstCell = out.length
        out.append(model.render())
        insert(out)
        textView.setSelectedRange(NSRange(location: start + firstCell, length: 0))
    }

    @objc func tableRowAction(_ sender: Any?) {
        guard let g = tableGrid, let storage = textView.textStorage, let me = g.cell(containing: textView.selectedRange().location) else { NSSound.beep(); return }
        var m = TableModel(g, storage)
        let tag = commandTag(of: sender)
        if tag == 2 {   // delete
            let r = me.row
            for c in 0..<m.columns {
                guard let (ar, ac) = m.anchor(r, c), ac == c else { continue }
                if ar < r { m.rows[ar][ac]?.rowSpan -= 1 }
                else if let cell = m.rows[r][c], cell.rowSpan > 1 {   // the cell moves down a row, shorter
                    var moved = cell
                    moved.rowSpan -= 1
                    m.rows[r + 1][c] = moved
                }
            }
            m.rows.remove(at: r)
            m.headerRows = r < m.headerRows ? m.headerRows - 1 : m.headerRows
            replaceTable(g, with: m, name: L("Delete Row"), caret: (max(0, r - 1), me.col))
            return
        }
        let at = tag == 0 ? me.row : me.row + me.rowSpan
        var row = [TableModel.Cell?](repeating: nil, count: m.columns)
        var c = 0
        while c < m.columns {
            if at > 0, at < m.rows.count, let (ar, ac) = m.anchor(at, c), ar < at, let cell = m.rows[ar][ac] {
                m.rows[ar][ac]?.rowSpan += 1      // a span across the new row grows
                c = ac + cell.colSpan
                continue
            }
            let above = at > 0 ? m.anchor(at - 1, c).flatMap { m.rows[$0.0][$0.1] } : m.rows.first?[c] ?? nil
            row[c] = emptyCell(m, like: above)
            c += 1
        }
        m.rows.insert(row, at: at)
        if at < m.headerRows { m.headerRows += 1 }
        replaceTable(g, with: m, name: tag == 0 ? L("Insert Row Above") : L("Insert Row Below"), caret: (at, me.col))
    }

    @objc func tableColumnAction(_ sender: Any?) {
        guard let g = tableGrid, let storage = textView.textStorage, let me = g.cell(containing: textView.selectedRange().location) else { NSSound.beep(); return }
        var m = TableModel(g, storage)
        let tag = commandTag(of: sender)
        if tag == 2 {
            let c = me.col
            for r in 0..<m.rows.count {
                guard let (ar, ac) = m.anchor(r, c), ar == r else { continue }
                if ac < c { m.rows[r][ac]?.colSpan -= 1 }
                else if let cell = m.rows[r][c], cell.colSpan > 1 { var moved = cell; moved.colSpan -= 1; m.rows[r][c + 1] = moved }
            }
            for r in 0..<m.rows.count { m.rows[r].remove(at: c) }
            let w = m.widths.remove(at: c)
            if !m.widths.isEmpty { m.widths = m.widths.map { $0 + w / CGFloat(m.widths.count) } }
            replaceTable(g, with: m, name: L("Delete Column"), caret: (me.row, max(0, c - 1)))
            return
        }
        let at = tag == 0 ? me.col : me.col + me.colSpan
        for r in 0..<m.rows.count {
            if at > 0, at < m.columns, let (ar, ac) = m.anchor(r, at), ac < at {
                if ar == r { m.rows[r][ac]?.colSpan += 1 }
                m.rows[r].insert(nil, at: at)
                continue
            }
            let left = at > 0 ? m.anchor(r, at - 1).flatMap { m.rows[$0.0][$0.1] } : m.rows[r].first ?? nil
            m.rows[r].insert(emptyCell(m, like: left), at: at)
        }
        let share = 100 / CGFloat(m.columns + 1)
        m.widths = m.widths.map { $0 * (100 - share) / 100 }
        m.widths.insert(share, at: at)
        replaceTable(g, with: m, name: tag == 0 ? L("Insert Column Left") : L("Insert Column Right"), caret: (me.row, at))
    }

    @objc func deleteTableAction(_ sender: Any?) {
        guard let g = tableGrid else { NSSound.beep(); return }
        guard textView.shouldChangeText(in: g.range, replacementString: "") else { return }
        textView.textStorage?.replaceCharacters(in: g.range, with: "")
        textView.didChangeText()
        textView.undoManager?.setActionName(L("Delete Table"))
    }

    // MARK: Merge and split

    @objc func mergeCellsAction(_ sender: Any?) {
        guard let g = tableGrid, let storage = textView.textStorage else { NSSound.beep(); return }
        let box = selectedCellBox(g)
        guard box.r1 > box.r0 || box.c1 > box.c0 else { NSSound.beep(); return }
        var m = TableModel(g, storage)
        let content = NSMutableAttributedString()
        var props: CellProps?
        for r in box.r0...box.r1 {
            for c in box.c0...box.c1 {
                guard let cell = m.rows[r][c] else { continue }
                props = props ?? cell.props
                let text = cell.content.string.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty || content.length == 0 { content.append(cell.content) }
                m.rows[r][c] = nil
            }
        }
        m.rows[box.r0][box.c0] = TableModel.Cell(content: content, rowSpan: box.r1 - box.r0 + 1, colSpan: box.c1 - box.c0 + 1, props: props ?? CellProps())
        replaceTable(g, with: m, name: L("Merge Cells"), caret: (box.r0, box.c0))
    }

    @objc func splitCellsAction(_ sender: Any?) {
        guard let g = tableGrid, let storage = textView.textStorage, let me = g.cell(containing: textView.selectedRange().location) else { NSSound.beep(); return }
        if me.rowSpan > 1 || me.colSpan > 1 {
            splitCell(g, me, columns: 0, rows: 0)
            return
        }
        let count = NSTextField(string: "2")
        let direction = NSPopUpButton(frame: .zero, pullsDown: false)
        direction.addItems(withTitles: [L("Into columns"), L("Into rows")])
        let alert = NSAlert.form(L("Split Cells"), ok: L("Split"), rows: [(L("Number:"), count), (L("Direction:"), direction)])
        guard alert.runModal() == .alertFirstButtonReturn, let n = Int(count.stringValue), (2...10).contains(n) else { return }
        splitCell(g, me, columns: direction.indexOfSelectedItem == 0 ? n : 0, rows: direction.indexOfSelectedItem == 1 ? n : 0)
        _ = storage
    }

    /// Splits a merged cell back into single cells, or a single cell into `columns` columns / `rows` rows.
    func splitCell(_ g: TableGrid, _ me: TableCell, columns: Int, rows: Int) {
        guard let storage = textView.textStorage else { return }
        var m = TableModel(g, storage)
        guard let cell = m.rows[me.row][me.col] else { return }
        if cell.rowSpan > 1 || cell.colSpan > 1 {
            for r in me.row..<(me.row + cell.rowSpan) {
                for c in me.col..<(me.col + cell.colSpan) where !(r == me.row && c == me.col) { m.rows[r][c] = emptyCell(m, like: cell) }
            }
            m.rows[me.row][me.col]?.rowSpan = 1
            m.rows[me.row][me.col]?.colSpan = 1
        } else if columns > 1 {
            // New grid columns after this one; cells of other rows span them.
            for r in 0..<m.rows.count {
                if r == me.row {
                    for _ in 1..<columns { m.rows[r].insert(emptyCell(m, like: cell), at: me.col + 1) }
                } else {
                    for _ in 1..<columns { m.rows[r].insert(nil, at: me.col + 1) }
                    if let (ar, ac) = m.anchor(r, me.col), ar == r { m.rows[r][ac]?.colSpan += columns - 1 }
                }
            }
            let w = m.widths[me.col] / CGFloat(columns)
            m.widths.replaceSubrange(me.col...me.col, with: Array(repeating: w, count: columns))
        } else if rows > 1 {
            for k in 1..<rows {
                var row = [TableModel.Cell?](repeating: nil, count: m.columns)
                row[me.col] = emptyCell(m, like: cell)
                m.rows.insert(row, at: me.row + k)
            }
            // Other cells of the row span the new rows.
            for c in 0..<m.columns where c != me.col {
                if let (ar, ac) = m.anchor(me.row, c), ac == c { m.rows[ar][ac]?.rowSpan += rows - 1 }
            }
        }
        replaceTable(g, with: m, name: L("Split Cells"), caret: (me.row, me.col))
    }

    // MARK: Sort, formula, conversion

    @objc func sortTableAction(_ sender: Any?) {
        guard let g = tableGrid else { NSSound.beep(); return }
        let column = NSPopUpButton(frame: .zero, pullsDown: false)
        column.addItems(withTitles: (1...max(1, g.columns)).map { L("Column %d", $0) })
        if let me = g.cell(containing: textView.selectedRange().location) { column.selectItem(at: me.col) }
        let order = NSPopUpButton(frame: .zero, pullsDown: false)
        order.addItems(withTitles: [L("Ascending"), L("Descending")])
        let type = NSPopUpButton(frame: .zero, pullsDown: false)
        type.addItems(withTitles: [L("Text"), L("Numbers")])
        let header = NSButton(checkboxWithTitle: L("First row is a heading"), target: nil, action: nil)
        header.state = ((g.table as? DocTextTable)?.headerRows ?? 0) > 0 ? .on : .off
        let alert = NSAlert.form(L("Sort Table"), ok: L("Sort"), rows: [(L("Sort by:"), column), (L("Order:"), order), (L("Type:"), type), ("", header)])
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        sortTable(column: column.indexOfSelectedItem, descending: order.indexOfSelectedItem == 1, numbers: type.indexOfSelectedItem == 1, header: header.state == .on)
    }

    func sortTable(column: Int, descending: Bool, numbers: Bool, header: Bool) {
        guard let g = tableGrid, let storage = textView.textStorage else { NSSound.beep(); return }
        var m = TableModel(g, storage)
        let skip = header ? max(1, m.headerRows) : m.headerRows
        guard m.rows.count > skip, column < m.columns,
              !m.rows.contains(where: { $0.contains { ($0?.rowSpan ?? 1) > 1 } }) else { NSSound.beep(); return }
        func key(_ row: [TableModel.Cell?]) -> String {
            var c = column
            while c > 0, row[c] == nil { c -= 1 }
            return row[c]?.content.string.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        let body = m.rows[skip...].sorted { a, b in
            let ka = key(a), kb = key(b)
            let less: Bool
            if numbers {
                less = (Fields.number(ka) ?? -.infinity) < (Fields.number(kb) ?? -.infinity)
            } else {
                less = ka.localizedStandardCompare(kb) == .orderedAscending
            }
            return descending ? !less && ka != kb : less
        }
        m.rows.replaceSubrange(skip..., with: body)
        replaceTable(g, with: m, name: L("Sort Table"), caret: (0, 0))
    }

    @objc func tableFormulaAction(_ sender: Any?) {
        guard isInTable else { NSSound.beep(); return }
        let formula = NSComboBox()
        formula.addItems(withObjectValues: ["SUM(ABOVE)", "SUM(LEFT)", "AVERAGE(ABOVE)", "AVERAGE(LEFT)", "MIN(ABOVE)", "MAX(ABOVE)", "COUNT(ABOVE)", "PRODUCT(LEFT)"])
        formula.stringValue = "SUM(ABOVE)"
        let alert = NSAlert.form(L("Formula"), info: L("The result updates when the numbers change."), ok: L("Insert"), rows: [(L("Formula:"), formula)])
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        insertField(DocField(.formula, argument: formula.stringValue.trimmingCharacters(in: CharacterSet(charactersIn: "= "))))
    }

    @objc func textToTableAction(_ sender: Any?) {
        let separator = NSPopUpButton(frame: .zero, pullsDown: false)
        separator.addItems(withTitles: [L("Tabs"), L("Semicolons"), L("Commas"), L("Paragraphs")])
        let alert = NSAlert.form(L("Convert Text to Table"), ok: L("Convert"), rows: [(L("Separate at:"), separator)])
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        textToTable(separator: ["\t", ";", ",", ""][max(0, separator.indexOfSelectedItem)])
    }

    func textToTable(separator: String) {
        guard let storage = textView.textStorage, storage.length > 0, !isInTable else { NSSound.beep(); return }
        let ns = storage.string as NSString
        let range = ns.paragraphRange(for: textView.selectedRange())
        var lines: [[NSAttributedString]] = []
        ns.enumerateSubstrings(in: range, options: [.byParagraphs, .substringNotRequired]) { _, r, _, _ in
            let para = storage.attributedSubstring(from: r)
            guard !separator.isEmpty else { lines.append([para]); return }
            var parts: [NSAttributedString] = []
            var start = 0
            let s = para.string as NSString
            var i = 0
            while i <= s.length {
                if i == s.length || s.substring(with: NSRange(location: i, length: 1)) == separator {
                    let piece = NSMutableAttributedString(attributedString: para.attributedSubstring(from: NSRange(location: start, length: i - start)))
                    let trimmed = piece.string.trimmingCharacters(in: .whitespaces)
                    if separator != "\t", piece.length > 0, let lead = piece.string.range(of: "^\\s+", options: .regularExpression) {
                        piece.deleteCharacters(in: NSRange(lead, in: piece.string))
                    }
                    _ = trimmed
                    parts.append(piece)
                    start = i + 1
                }
                i += 1
            }
            lines.append(parts)
        }
        guard !lines.isEmpty else { return }
        let cols = lines.map(\.count).max() ?? 1
        let attrs = storage.attributes(at: range.location, effectiveRange: nil)
        let m = TableModel(rows: lines.map { line in (0..<cols).map { c in
            let content = NSMutableAttributedString(attributedString: c < line.count ? line[c] : NSAttributedString())
            content.append(TableModel.empty(content.length > 0 ? content.attributes(at: 0, effectiveRange: nil) : attrs))
            return TableModel.Cell(content: content, props: CellProps())
        } }, widths: Array(repeating: 100 / CGFloat(cols), count: cols))
        let text = m.render()
        guard textView.shouldChangeText(in: range, replacementString: text.string) else { return }
        storage.replaceCharacters(in: range, with: text)
        textView.didChangeText()
        textView.undoManager?.setActionName(L("Convert Text to Table"))
        textView.setSelectedRange(NSRange(location: range.location, length: 0))
    }

    @objc func tableToTextAction(_ sender: Any?) {
        guard let g = tableGrid, let storage = textView.textStorage else { NSSound.beep(); return }
        let m = TableModel(g, storage)
        let out = NSMutableAttributedString()
        for row in m.rows {
            var first = true
            for cell in row {
                guard let cell else { continue }
                let content = NSMutableAttributedString(attributedString: cell.content)
                while content.string.hasSuffix("\n") { content.deleteCharacters(in: NSRange(location: content.length - 1, length: 1)) }
                let s = content.mutableString
                s.replaceOccurrences(of: "\n", with: " ", range: NSRange(location: 0, length: s.length))
                if !first { out.append(NSAttributedString(string: "\t", attributes: content.length > 0 ? content.attributes(at: 0, effectiveRange: nil) : [:])) }
                out.append(content)
                first = false
            }
            out.append(NSAttributedString(string: "\n", attributes: out.length > 0 ? out.attributes(at: out.length - 1, effectiveRange: nil) : [:]))
        }
        out.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: out.length)) { v, r, _ in
            let p = (v as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
            p.textBlocks = []
            out.addAttribute(.paragraphStyle, value: p, range: r)
        }
        guard textView.shouldChangeText(in: g.range, replacementString: out.string) else { return }
        storage.replaceCharacters(in: g.range, with: out)
        textView.didChangeText()
        textView.undoManager?.setActionName(L("Convert Table to Text"))
    }

    // MARK: Properties and AutoFormat

    enum BorderPreset: Int { case keep, all, outer, inner, none }

    /// Borders of every cell for a preset (the table's outline, the lines inside, or both).
    static func applyBorders(_ m: inout TableModel, _ preset: BorderPreset, width: CGFloat, color: NSColor) {
        guard preset != .keep else { return }
        let rows = m.rows.count, cols = m.columns
        for r in 0..<rows {
            for c in 0..<cols {
                guard var cell = m.rows[r][c] else { continue }
                let outer = [c == 0, r == 0, c + cell.colSpan >= cols, r + cell.rowSpan >= rows]   // minX, minY, maxX, maxY
                cell.props.borders = outer.map { isOuter in
                    switch preset {
                    case .all: return width
                    case .outer: return isOuter ? width : 0
                    case .inner: return isOuter ? 0 : width
                    default: return 0
                    }
                }
                cell.props.colors = Array(repeating: color, count: 4)
                m.rows[r][c] = cell
            }
        }
    }

    @objc func tablePropertiesAction(_ sender: Any?) {
        guard let g = tableGrid, let storage = textView.textStorage else { NSSound.beep(); return }
        let m = TableModel(g, storage)
        let textWidth = paged.setup(at: g.range.location).columnWidth
        let widths = NSTextField(string: m.widths.map { String(format: "%.1f", $0 * textWidth / 100 / DocRuler.cm) }.joined(separator: "; "))
        let borders = NSPopUpButton(frame: .zero, pullsDown: false)
        borders.addItems(withTitles: [L("Keep"), L("All"), L("Outer"), L("Inner"), L("None")])
        let first = m.rows.first?.compactMap { $0 }.first?.props ?? CellProps()
        let lineWidth = NSTextField(string: String(format: "%.1f", first.borders.max() ?? 0.5))
        let lineColor = NSColorWell(frame: NSRect(x: 0, y: 0, width: 44, height: 24))
        lineColor.color = first.colors.first ?? .gray
        let padding = NSTextField(string: String(format: "%.1f", first.padding))
        let shading = NSColorWell(frame: NSRect(x: 0, y: 0, width: 44, height: 24))
        let me = g.cell(containing: textView.selectedRange().location)
        shading.color = me?.block.backgroundColor ?? .white
        let noShading = NSButton(checkboxWithTitle: L("No background"), target: nil, action: nil)
        noShading.state = me?.block.backgroundColor == nil ? .on : .off
        let vertical = NSPopUpButton(frame: .zero, pullsDown: false)
        vertical.addItems(withTitles: [L("Top"), L("Middle"), L("Bottom")])
        vertical.selectItem(at: [.topAlignment: 0, .middleAlignment: 1, .bottomAlignment: 2][me?.block.verticalAlignment ?? .topAlignment] ?? 0)
        let header = NSPopUpButton(frame: .zero, pullsDown: false)
        header.addItems(withTitles: ["0", "1", "2", "3"])
        header.selectItem(at: min(3, m.headerRows))
        let alert = NSAlert.form(L("Table Properties"), info: L("Column widths in centimetres, separated by semicolons. Background and alignment apply to the selected cells."),
                                 ok: L("Apply"), rows: [(L("Column widths:"), widths), (L("Borders:"), borders), (L("Line width (pt):"), lineWidth),
                                                        (L("Line colour:"), lineColor), (L("Cell padding (pt):"), padding), (L("Cell background:"), shading),
                                                        ("", noShading), (L("Vertical alignment:"), vertical), (L("Repeat heading rows:"), header)])
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        func num(_ s: String) -> CGFloat? { Double(s.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)).map { CGFloat($0) } }
        let cm = widths.stringValue.split(separator: ";").compactMap { num(String($0)) }
        var p = TableProperties()
        if cm.count == m.columns, cm.allSatisfy({ $0 > 0 }) { p.widths = cm.map { $0 * DocRuler.cm / textWidth * 100 } }
        p.borders = BorderPreset(rawValue: borders.indexOfSelectedItem) ?? .keep
        p.lineWidth = num(lineWidth.stringValue) ?? 0.5
        p.lineColor = lineColor.color
        p.padding = num(padding.stringValue)
        p.background = noShading.state == .on ? .some(nil) : .some(shading.color)
        p.vertical = [NSTextBlock.VerticalAlignment.topAlignment, .middleAlignment, .bottomAlignment][max(0, vertical.indexOfSelectedItem)]
        p.headerRows = header.indexOfSelectedItem
        applyTableProperties(p)
    }

    struct TableProperties {
        var widths: [CGFloat]?
        var borders: BorderPreset = .keep
        var lineWidth: CGFloat = 0.5
        var lineColor: NSColor = .gray
        var padding: CGFloat?
        /// .some(nil): no background for the selected cells.
        var background: NSColor??
        var vertical: NSTextBlock.VerticalAlignment?
        var headerRows: Int?
    }

    func applyTableProperties(_ p: TableProperties) {
        guard let g = tableGrid, let storage = textView.textStorage else { NSSound.beep(); return }
        var m = TableModel(g, storage)
        if let w = p.widths, w.count == m.columns { let t = w.reduce(0, +); m.widths = w.map { $0 / t * 100 } }
        Self.applyBorders(&m, p.borders, width: p.lineWidth, color: p.lineColor)
        let box = selectedCellBox(g)
        for r in 0..<m.rows.count {
            for c in 0..<m.columns {
                guard m.rows[r][c] != nil else { continue }
                if let pad = p.padding { m.rows[r][c]?.props.padding = pad }
                if r >= box.r0, r <= box.r1, c >= box.c0, c <= box.c1 {
                    if let bg = p.background { m.rows[r][c]?.props.background = bg }
                    if let v = p.vertical { m.rows[r][c]?.props.vertical = v }
                }
            }
        }
        if let h = p.headerRows { m.headerRows = min(h, m.rows.count) }
        let caret = g.cell(containing: textView.selectedRange().location).map { ($0.row, $0.col) } ?? (0, 0)
        replaceTable(g, with: m, name: L("Table Properties"), caret: caret)
    }

    static let autoFormats: [String] = [L("Simple Grid"), L("Blue Heading"), L("Striped Rows"), L("Elegant"), L("Green"), L("No Borders")]

    @objc func tableAutoFormatAction(_ sender: Any?) { applyAutoFormat(commandTag(of: sender)) }

    func applyAutoFormat(_ k: Int) {
        guard let g = tableGrid, let storage = textView.textStorage else { NSSound.beep(); return }
        var m = TableModel(g, storage)
        func hex(_ v: Int) -> NSColor { NSColor(srgbRed: CGFloat(v >> 16 & 0xFF) / 255, green: CGFloat(v >> 8 & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1) }
        let heading: (bg: NSColor?, text: NSColor)
        var band: NSColor?
        switch k {
        case 1: Self.applyBorders(&m, .all, width: 0.5, color: hex(0x8EA9DB)); heading = (hex(0x4472C4), .white)
        case 2: Self.applyBorders(&m, .none, width: 0, color: .black); heading = (nil, .black); band = hex(0xF2F2F2)
        case 3: Self.applyBorders(&m, .none, width: 0, color: .black); heading = (nil, .black)
        case 4: Self.applyBorders(&m, .all, width: 0.5, color: hex(0xA9D08E)); heading = (hex(0x70AD47), .white); band = hex(0xE2EFDA)
        case 5: Self.applyBorders(&m, .none, width: 0, color: .black); heading = (nil, .black)
        default: Self.applyBorders(&m, .all, width: 0.5, color: NSColor(white: 0.6, alpha: 1)); heading = (nil, .black)
        }
        let rows = m.rows.count
        for r in 0..<rows {
            for c in 0..<m.columns {
                guard var cell = m.rows[r][c] else { continue }
                cell.props.background = r == 0 ? heading.bg : (band != nil && r % 2 == 0 ? band : nil)
                if k == 2 || k == 3 {
                    // Lines under the heading and at the top and bottom of the table.
                    cell.props.borders = [0, r == 0 ? 1.5 : 0, 0, r == 0 ? 0.75 : (r + cell.rowSpan >= rows ? 1.5 : 0)]
                    cell.props.colors = Array(repeating: .black, count: 4)
                }
                let content = NSMutableAttributedString(attributedString: cell.content)
                let full = NSRange(location: 0, length: content.length)
                if r == 0, k != 5 {
                    content.enumerateAttribute(.font, in: full) { v, sub, _ in
                        content.addAttribute(.font, value: NSFontManager.shared.convert(v as? NSFont ?? Styles.normal.font, toHaveTrait: .boldFontMask), range: sub)
                    }
                    content.addAttribute(.foregroundColor, value: heading.text, range: full)
                } else if r > 0 {
                    content.addAttribute(.foregroundColor, value: NSColor.black, range: full)
                }
                cell.content = content
                m.rows[r][c] = cell
            }
        }
        if k != 5 { m.headerRows = max(1, m.headerRows) }
        replaceTable(g, with: m, name: L("AutoFormat"), caret: (0, 0))
    }
}

// MARK: - .docx tables

extension DocxStyles {
    /// Each cell's grid position, spans, borders and shading → a marker in its first paragraph
    /// (the system reader drops spans, shading and most borders); `restoreTables` rebuilds the tables.
    static func markTables(_ body: XMLElement, styles: XMLElement?) {
        var tableStyles: [String: XMLElement] = [:]
        for s in styles?.children("style") ?? [] where s.attr("type") == "table" { if let id = s.attr("styleId") { tableStyles[id] = s } }
        var n = 0
        for tbl in descendants(body, named: "tbl") {
            // Top-level tables only (nested ones stay as the system reads them).
            var parent = tbl.parent
            var nested = false
            while let p = parent as? XMLElement { if p.localName == "tbl" { nested = true; break }; parent = p.parent }
            guard !nested else { continue }
            n += 1
            let tblPr = tbl.child("tblPr")
            let style = tblPr?.child("tblStyle")?.attr("val").flatMap { tableStyles[$0] }
            func borders(_ e: XMLElement?) -> [String: String] {
                var out: [String: String] = [:]
                for case let b as XMLElement in e?.children ?? [] {
                    guard let name = b.localName else { continue }
                    let v = b.attr("val") ?? "single"
                    out[name == "start" ? "left" : name == "end" ? "right" : name] = ["nil", "none"].contains(v) ? "0:000000" : "\(b.attr("sz") ?? "4"):\(b.attr("color").flatMap { $0 == "auto" ? nil : $0 } ?? "000000")"
                }
                return out
            }
            var tableBorders = borders(style?.child("tblPr")?.child("tblBorders"))
            tableBorders.merge(borders(tblPr?.child("tblBorders"))) { $1 }
            let margin = (tblPr?.child("tblCellMar")?.child("left") ?? tblPr?.child("tblCellMar")?.child("start") ?? style?.child("tblPr")?.child("tblCellMar")?.child("left"))?
                .attr("w").flatMap(Double.init) ?? 108
            let grid = tbl.child("tblGrid")?.children("gridCol").compactMap { $0.attr("w").flatMap(Double.init) } ?? []
            let rows = tbl.children("tr")
            var header = 0
            for tr in rows { if let h = tr.child("trPr")?.child("tblHeader"), onOff(h) { header += 1 } else { break } }
            let rowCount = rows.count
            let gridCount = max(grid.count, rows.map { tr in tr.children("tc").reduce(0) { $0 + ($1.child("tcPr")?.child("gridSpan")?.attr("val").flatMap(Int.init) ?? 1) } }.max() ?? 1)
            for (r, tr) in rows.enumerated() {
                var c = tr.child("trPr")?.child("gridBefore")?.attr("val").flatMap(Int.init) ?? 0
                for tc in tr.children("tc") {
                    let pr = tc.child("tcPr")
                    let span = pr?.child("gridSpan")?.attr("val").flatMap(Int.init) ?? 1
                    let vm = pr?.child("vMerge").map { ($0.attr("val") ?? "continue") == "restart" ? "r" : "c" } ?? ""
                    var b: [String: String] = [:]
                    b["top"] = tableBorders[r == 0 ? "top" : "insideH"]
                    b["bottom"] = tableBorders[r == rowCount - 1 ? "bottom" : "insideH"]
                    b["left"] = tableBorders[c == 0 ? "left" : "insideV"]
                    b["right"] = tableBorders[c + span >= gridCount ? "right" : "insideV"]
                    b.merge(borders(pr?.child("tcBorders"))) { $1 }
                    let fill = pr?.child("shd")?.attr("fill").flatMap { $0 == "auto" ? nil : $0 } ?? ""
                    let valign = pr?.child("vAlign")?.attr("val") ?? ""
                    var payload = "t=\(n);r=\(r);c=\(c);s=\(span);v=\(vm);f=\(fill);a=\(valign)"
                    payload += ";b=" + ["left", "top", "right", "bottom"].map { b[$0] ?? "0:000000" }.joined(separator: ",")
                    if r == 0, c == 0 || tr.children("tc").first === tc {
                        payload += ";h=\(header);m=\(Int(margin));g=" + grid.map { "\(Int($0))" }.joined(separator: ",")
                    }
                    let p = tc.children("p").first ?? {
                        let p = XMLElement(name: "w:p", uri: ns)
                        tc.addChild(p)
                        return p
                    }()
                    p.insertChild(mark("t", payload), at: (p.child("pPr")?.index ?? -1) + 1)
                    c += span
                }
            }
        }
    }

    /// Rebuilds the tables marked by `markTables`: grid columns, spans, borders, shading, widths, heading rows.
    static func restoreTables(_ text: NSMutableAttributedString, _ marks: [(payload: String, at: Int)]) {
        guard !marks.isEmpty else { return }
        struct M { var t = 0, r = 0, c = 0, s = 1; var v = ""; var f = ""; var a = ""; var b: [String] = []; var h = 0; var m = 108.0; var g: [Double] = []; var at = 0 }
        var byTable: [Int: [M]] = [:]
        for mk in marks {
            var m = M()
            m.at = mk.at
            for kv in mk.payload.split(separator: ";") {
                let parts = kv.split(separator: "=", maxSplits: 1).map(String.init)
                guard parts.count == 2 || (parts.count == 1 && kv.hasSuffix("=")) else { continue }
                let k = parts[0], v = parts.count > 1 ? parts[1] : ""
                switch k {
                case "t": m.t = Int(v) ?? 0
                case "r": m.r = Int(v) ?? 0
                case "c": m.c = Int(v) ?? 0
                case "s": m.s = max(1, Int(v) ?? 1)
                case "v": m.v = v
                case "f": m.f = v
                case "a": m.a = v
                case "b": m.b = v.split(separator: ",").map(String.init)
                case "h": m.h = Int(v) ?? 0
                case "m": m.m = Double(v) ?? 108
                case "g": m.g = v.split(separator: ",").compactMap { Double($0) }
                default: break
                }
            }
            byTable[m.t, default: []].append(m)
        }
        var deletions: [NSRange] = []
        let ns = text.string as NSString
        for (_, cells) in byTable {
            let columns = max(cells.map { $0.c + $0.s }.max() ?? 1, cells.first(where: { !$0.g.isEmpty })?.g.count ?? 0)
            let info = cells.first { !$0.g.isEmpty } ?? cells.first!
            let table = DocTextTable()
            table.numberOfColumns = columns
            table.collapsesBorders = true
            table.layoutAlgorithm = .automaticLayoutAlgorithm
            table.headerRows = info.h
            let gridTotal = info.g.reduce(0, +)
            func pct(_ c: Int, _ s: Int) -> CGFloat {
                guard gridTotal > 0, info.g.count >= c + s else { return 100 * CGFloat(s) / CGFloat(columns) }
                return CGFloat(info.g[c..<(c + s)].reduce(0, +) / gridTotal * 100)
            }
            for m in cells {
                // The cell's paragraphs: those sharing the system reader's block.
                guard m.at <= text.length, let sys = TableGrid.block(text, at: m.at) else { continue }
                var start = ns.paragraphRange(for: NSRange(location: min(m.at, max(0, ns.length - 1)), length: 0)).location
                while start > 0, TableGrid.block(text, at: start - 1) === sys { start = ns.paragraphRange(for: NSRange(location: start - 1, length: 0)).location }
                var end = NSMaxRange(ns.paragraphRange(for: NSRange(location: min(m.at, max(0, ns.length - 1)), length: 0)))
                while end < text.length, TableGrid.block(text, at: end) === sys { end = NSMaxRange(ns.paragraphRange(for: NSRange(location: end, length: 0))) }
                let range = NSRange(location: start, length: end - start)
                if m.v == "c" { deletions.append(range); continue }
                var rowSpan = 1
                if m.v == "r" {
                    while cells.contains(where: { $0.c == m.c && $0.r == m.r + rowSpan && $0.v == "c" }) { rowSpan += 1 }
                }
                let block = NSTextTableBlock(table: table, startingRow: m.r, rowSpan: rowSpan, startingColumn: m.c, columnSpan: m.s)
                var props = CellProps()
                props.padding = CGFloat(m.m) / 20
                for (i, spec) in m.b.prefix(4).enumerated() {
                    let parts = spec.split(separator: ":")
                    props.borders[i] = CGFloat(Double(parts.first ?? "0") ?? 0) / 8
                    props.colors[i] = parts.count > 1 ? hexColor(String(parts[1])) ?? .black : .black
                }
                props.background = m.f.isEmpty ? nil : hexColor(m.f)
                props.vertical = m.a == "center" ? .middleAlignment : m.a == "bottom" ? .bottomAlignment : .topAlignment
                props.apply(to: block)
                block.setValue(pct(m.c, m.s), type: .percentageValueType, for: .width)
                text.enumerateAttribute(.paragraphStyle, in: range) { v, r, _ in
                    let p = (v as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
                    p.textBlocks = Array(p.textBlocks.dropLast()) + [block]
                    text.addAttribute(.paragraphStyle, value: p, range: r)
                }
            }
        }
        for r in deletions.sorted(by: { $0.location > $1.location }) { text.deleteCharacters(in: r) }
    }
}
