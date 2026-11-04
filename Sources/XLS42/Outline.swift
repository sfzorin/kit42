import AppKit
import Kit42

/// Row/column grouping (outline): levels 1…7, collapsing hides the members of a group.
extension Sheet {
    static let maxOutlineLevel = 7

    func level(_ index: Int, rows: Bool) -> Int { (rows ? rowLevels[index] : colLevels[index]) ?? 0 }

    /// Contiguous runs of rows (or columns) at `level` or deeper.
    func outlineGroups(rows: Bool, level: Int) -> [ClosedRange<Int>] {
        let keys = (rows ? rowLevels : colLevels).filter { $0.value >= level }.keys.sorted()
        var out: [ClosedRange<Int>] = []
        for k in keys {
            if let last = out.last, last.upperBound + 1 == k { out[out.count - 1] = last.lowerBound...k } else { out.append(k...k) }
        }
        return out
    }

    func isOutlineHidden(_ index: Int, rows: Bool) -> Bool { rows ? outlineHiddenRows.contains(index) : outlineHiddenCols.contains(index) }

    /// A group is collapsed when all of its members are hidden by the outline.
    func isCollapsed(_ group: ClosedRange<Int>, rows: Bool) -> Bool { group.allSatisfy { isOutlineHidden($0, rows: rows) } }

    /// Changes the level of `range` by ±1 (Group / Ungroup).
    mutating func changeOutline(_ range: ClosedRange<Int>, rows: Bool, by delta: Int) {
        for i in range {
            let n = max(0, min(Self.maxOutlineLevel, level(i, rows: rows) + delta))
            if rows { rowLevels[i] = n == 0 ? nil : n } else { colLevels[i] = n == 0 ? nil : n }
            if n == 0 { if rows { outlineHiddenRows.remove(i) } else { outlineHiddenCols.remove(i) } }
        }
    }

    /// Hides or shows the members of a group.
    mutating func setCollapsed(_ group: ClosedRange<Int>, rows: Bool, _ collapsed: Bool) {
        for i in group {
            if rows { if collapsed { outlineHiddenRows.insert(i) } else { outlineHiddenRows.remove(i) } }
            else { if collapsed { outlineHiddenCols.insert(i) } else { outlineHiddenCols.remove(i) } }
        }
    }

    /// Level buttons 1, 2, …: shows rows above `level`, hides deeper ones.
    mutating func showOutlineLevel(_ level: Int, rows: Bool) {
        for (i, l) in rows ? rowLevels : colLevels {
            if rows { if l >= level { outlineHiddenRows.insert(i) } else { outlineHiddenRows.remove(i) } }
            else { if l >= level { outlineHiddenCols.insert(i) } else { outlineHiddenCols.remove(i) } }
        }
    }
}

extension SheetWindowController {
    /// Rows, columns or (asking) either for the current selection.
    private func outlineTarget() -> (rows: Bool, range: ClosedRange<Int>)? {
        let sel = grid.selection
        if sel.rows.count >= grid.rowCount - 1 || sel.end.row >= RefPart.maxRow { return (false, sel.cols) }
        if sel.cols.count >= grid.colCount - 1 || sel.end.col >= RefPart.maxCol { return (true, sel.rows) }
        if suppressAlerts { return (true, sel.rows) }
        let alert = NSAlert()
        alert.messageText = L("Group")
        alert.informativeText = sel.a1
        alert.addButton(withTitle: L("Rows"))
        alert.addButton(withTitle: L("Columns"))
        alert.addButton(withTitle: L("Cancel"))
        switch alert.runModal() {
        case .alertFirstButtonReturn: return (true, sel.rows)
        case .alertSecondButtonReturn: return (false, sel.cols)
        default: return nil
        }
    }

    @objc func groupAction(_ sender: Any?) {
        guard guardEditable(nil), let t = outlineTarget() else { return }
        group(t.range, rows: t.rows, by: 1)
    }

    @objc func ungroupAction(_ sender: Any?) {
        guard guardEditable(nil), let t = outlineTarget() else { return }
        group(t.range, rows: t.rows, by: -1)
    }

    func group(_ range: ClosedRange<Int>, rows: Bool, by delta: Int) {
        doc?.change(delta > 0 ? L("Group") : L("Ungroup"), recalc: false) { $0.sheets[sheetIndex].changeOutline(range, rows: rows, by: delta) }
    }

    /// Collapses or expands the group (at `level`) containing `index`.
    func toggleOutline(_ group: ClosedRange<Int>, rows: Bool) {
        let collapsed = sheet.isCollapsed(group, rows: rows)
        doc?.change(collapsed ? L("Expand Group") : L("Collapse Group"), recalc: false) {
            $0.sheets[sheetIndex].setCollapsed(group, rows: rows, !collapsed)
        }
    }

    @objc func collapseAllAction(_ sender: Any?) {
        doc?.change(L("Collapse Group"), recalc: false) { wb in
            wb.sheets[sheetIndex].showOutlineLevel(1, rows: true)
            wb.sheets[sheetIndex].showOutlineLevel(1, rows: false)
        }
    }

    @objc func expandAllAction(_ sender: Any?) {
        doc?.change(L("Expand Group"), recalc: false) { wb in
            wb.sheets[sheetIndex].outlineHiddenRows = []
            wb.sheets[sheetIndex].outlineHiddenCols = []
        }
    }

    func showOutlineLevel(_ level: Int, rows: Bool) {
        doc?.change(L("Outline Level"), recalc: false) { $0.sheets[sheetIndex].showOutlineLevel(level, rows: rows) }
    }
}

/// Gutter beside the row headers (or above the column headers) with group brackets and +/− buttons.
/// The row gutter's top part (above the rows) holds the level buttons 1, 2, ….
final class OutlineGutter: NSView {
    weak var grid: GridView?
    let isColumns: Bool
    static let step: CGFloat = 13

    init(grid: GridView, columns: Bool) {
        self.grid = grid
        isColumns = columns
        super.init(frame: .zero)
        clipsToBounds = true
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override var isFlipped: Bool { true }

    /// Gutter thickness for a sheet (0 when nothing is grouped).
    static func thickness(_ levels: Int) -> CGFloat { levels == 0 ? 0 : CGFloat(levels + 1) * step + 4 }

    /// Offset of the cell area inside this view along the axis (the gutter also spans the corner).
    var leading: CGFloat = 0

    private func position(_ index: Int) -> (CGFloat, CGFloat) {
        guard let grid else { return (0, 0) }
        let frozen = isColumns ? grid.sheet.frozenCols : grid.sheet.frozenRows
        let o = isColumns ? grid.scrollOrigin.x : grid.scrollOrigin.y
        let a = isColumns ? grid.x(index) : grid.y(index), b = isColumns ? grid.x(index + 1) : grid.y(index + 1)
        let shift = index < frozen ? 0 : o
        return (leading + a - shift, leading + b - shift)
    }

    /// +/− button of a group: on the row (column) after it, like Excel's "summary below".
    func buttonRect(_ group: ClosedRange<Int>, level: Int) -> NSRect {
        let (a, b) = position(group.upperBound + 1)
        let size: CGFloat = 11
        let mid = (a + b) / 2
        let across = CGFloat(level - 1) * Self.step + 3
        return isColumns ? NSRect(x: mid - size / 2, y: across, width: size, height: size) : NSRect(x: across, y: mid - size / 2, width: size, height: size)
    }

    func levelButtonRect(_ level: Int) -> NSRect {
        let across = CGFloat(level - 1) * Self.step + 3
        return isColumns ? NSRect(x: 4, y: across, width: 11, height: 11) : NSRect(x: across, y: 4, width: 11, height: 11)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let grid else { return }
        NSColor(srgbRed: 0.955, green: 0.955, blue: 0.955, alpha: 1).setFill()
        bounds.fill()
        let sheet = grid.sheet
        let maxLevel = isColumns ? sheet.maxColLevel : sheet.maxRowLevel
        guard maxLevel > 0 else { return }
        let rows = !isColumns
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: isColumns ? NSRect(x: leading, y: 0, width: bounds.width, height: bounds.height)
                                     : NSRect(x: 0, y: leading, width: bounds.width, height: bounds.height)).addClip()
        let line = NSColor(white: 0.45, alpha: 1)
        for level in 1...maxLevel {
            for g in sheet.outlineGroups(rows: rows, level: level) {
                let collapsed = sheet.isCollapsed(g, rows: rows)
                let button = buttonRect(g, level: level)
                if !collapsed {
                    let (a, _) = position(g.lowerBound)
                    let end = isColumns ? button.minX : button.minY
                    line.setFill()
                    if isColumns {
                        NSRect(x: a + 2, y: button.midY - 0.5, width: max(0, end - a - 2), height: 1).fill()
                        NSRect(x: a + 2, y: button.midY - 0.5, width: 1, height: 4).fill()
                    } else {
                        NSRect(x: button.midX - 0.5, y: a + 2, width: 1, height: max(0, end - a - 2)).fill()
                        NSRect(x: button.midX - 0.5, y: a + 2, width: 4, height: 1).fill()
                    }
                }
                drawButton(button, collapsed ? "+" : "−")
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        // Level buttons in the corner part.
        for level in 1...(maxLevel + 1) { drawButton(levelButtonRect(level), "\(level)") }
    }

    private func drawButton(_ r: NSRect, _ text: String) {
        NSColor.white.setFill()
        let path = NSBezierPath(rect: r.insetBy(dx: 0.5, dy: 0.5))
        path.fill()
        NSColor(white: 0.5, alpha: 1).setStroke()
        path.lineWidth = 1
        path.stroke()
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 9, weight: .semibold), .foregroundColor: NSColor(white: 0.25, alpha: 1)]
        let size = (text as NSString).size(withAttributes: attrs)
        (text as NSString).draw(at: NSPoint(x: r.midX - size.width / 2, y: r.midY - size.height / 2), withAttributes: attrs)
    }

    override func mouseDown(with event: NSEvent) {
        guard let grid, let controller = grid.controller else { return }
        let p = convert(event.locationInWindow, from: nil)
        let sheet = grid.sheet
        let rows = !isColumns
        let maxLevel = isColumns ? sheet.maxColLevel : sheet.maxRowLevel
        guard maxLevel > 0 else { return }
        if (isColumns ? p.x : p.y) < leading {
            for level in 1...(maxLevel + 1) where levelButtonRect(level).insetBy(dx: -2, dy: -2).contains(p) {
                controller.showOutlineLevel(level, rows: rows)
                return
            }
            return
        }
        for level in (1...maxLevel).reversed() {
            for g in sheet.outlineGroups(rows: rows, level: level) where buttonRect(g, level: level).insetBy(dx: -3, dy: -3).contains(p) {
                controller.toggleOutline(g, rows: rows)
                return
            }
        }
    }
}
