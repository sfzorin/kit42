import AppKit

extension TableModel {
    /// Structural edits transform complete merged rectangles, including anchors deleted from a multi-cell span.
    mutating func shift(axisRows: Bool, at index: Int, insert: Bool) {
        let oldRows = rows.count, oldColumns = columns.count
        guard oldRows > 0, oldColumns > 0, cells.count == oldRows, cells.allSatisfy({ $0.count == oldColumns }) else { return }
        let dimension = axisRows ? oldRows : oldColumns
        guard index >= 0, index <= (insert ? dimension : dimension - 1), insert || dimension > 1 else { return }
        let previous = cells
        if axisRows {
            if insert { rows.insert(rows[min(index, oldRows - 1)], at: index) } else { rows.remove(at: index) }
        } else {
            if insert { columns.insert(columns[min(index, oldColumns - 1)], at: index) } else { columns.remove(at: index) }
        }
        func blank(_ cell: TableCell) -> TableCell {
            var result = cell
            result.gridSpan = 1; result.rowSpan = 1; result.merged = false
            var paragraph = cell.text.paragraphs.first ?? Paragraph()
            paragraph.runs = []
            result.text.paragraphs = [paragraph]
            return result
        }
        cells = (0..<rows.count).map { r in
            (0..<columns.count).map { c in blank(previous[min(r, oldRows - 1)][min(c, oldColumns - 1)]) }
        }
        for r in 0..<oldRows {
            for c in 0..<oldColumns where !previous[r][c].merged {
                var cell = previous[r][c]
                var row = r, column = c
                cell.rowSpan = min(max(1, cell.rowSpan), oldRows - r)
                cell.gridSpan = min(max(1, cell.gridSpan), oldColumns - c)
                var start = axisRows ? row : column
                var span = axisRows ? cell.rowSpan : cell.gridSpan
                if insert {
                    if start >= index { start += 1 }
                    else if start + span > index { span += 1 }
                } else {
                    if start > index { start -= 1 }
                    else if start + span > index { span -= 1 }
                    if span == 0 { continue }
                }
                if axisRows { row = start; cell.rowSpan = span } else { column = start; cell.gridSpan = span }
                guard cells.indices.contains(row), cells[row].indices.contains(column) else { continue }
                cells[row][column] = cell
                for rr in row..<min(rows.count, row + cell.rowSpan) {
                    for cc in column..<min(columns.count, column + cell.gridSpan) where rr != row || cc != column {
                        cells[rr][cc].merged = true
                    }
                }
            }
        }
    }
}
