import AppKit
import Kit42
import PDFKit

/// Results of "Compare With…": word changes page by page. Clicking a row shows it in the document;
/// the changed words are highlighted there until the window is closed (or kept, if the user asks).
final class CompareWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private weak var editor: EditorWindowController?
    private let changes: [PDFTools.Change]
    private let table = NSTableView()
    private let keepBox = NSButton(checkboxWithTitle: L("Keep highlights when saving"), target: nil, action: nil)
    private let clearButton = NSButton(title: L("Remove Highlights"), target: nil, action: nil)

    init(editor: EditorWindowController, changes: [PDFTools.Change], otherName: String) {
        self.editor = editor
        self.changes = changes
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 620, height: 420),
                             styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: false)
        window.title = L("Comparison with “%@”", otherName)
        window.isFloatingPanel = false
        window.hidesOnDeactivate = false
        window.minSize = NSSize(width: 420, height: 240)
        super.init(window: window)
        window.delegate = self
        build(summary: changes.isEmpty ? L("No differences in the text") : L("%d changes. Red: removed, orange: replaced. Words that were only added are listed here.", changes.count))
        if let parent = editor.window {
            window.setFrameTopLeftPoint(NSPoint(x: parent.frame.maxX - 640, y: parent.frame.maxY - 80))
        }
    }

    required init?(coder: NSCoder) { nil }

    private func build(summary: String) {
        let label = NSTextField(wrappingLabelWithString: summary)
        label.textColor = .secondaryLabelColor
        for (id, title, width) in [("page", L("Page"), 50.0), ("removed", L("Removed"), 250.0), ("added", L("Added"), 250.0)] {
            let column = NSTableColumn(identifier: .init(id))
            column.title = title
            column.width = width
            table.addTableColumn(column)
        }
        table.dataSource = self
        table.delegate = self
        table.usesAlternatingRowBackgroundColors = true
        table.rowSizeStyle = .medium
        table.target = self
        table.action = #selector(rowClicked)
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        keepBox.target = self
        keepBox.action = #selector(keepChanged)
        clearButton.target = self
        clearButton.action = #selector(clearHighlights)
        let bottom = NSStackView(views: [keepBox, NSView(), clearButton])
        let stack = NSStackView(views: [label, scroll, bottom])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor), stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor), stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
            bottom.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
            label.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
        ])
        window?.contentView = content
    }

    func numberOfRows(in tableView: NSTableView) -> Int { changes.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let c = changes[row]
        let text: String
        let color: NSColor
        switch tableColumn?.identifier.rawValue {
        case "page": text = "\(c.page + 1)"; color = .labelColor
        case "removed": text = c.removed.map(\.text).joined(separator: " "); color = .systemRed
        default: text = c.added.joined(separator: " "); color = .systemGreen
        }
        let label = NSTextField(labelWithString: text)
        label.textColor = color
        label.lineBreakMode = .byTruncatingTail
        label.toolTip = text
        return label
    }

    func tableViewSelectionDidChange(_ notification: Notification) { rowClicked() }

    @objc private func rowClicked() {
        let row = table.selectedRow
        guard row >= 0, row < changes.count else { return }
        editor?.showChange(changes[row])
    }

    @objc private func keepChanged() {
        editor?.pdfDoc?.keepCompareHighlights = keepBox.state == .on
        if keepBox.state == .on { editor?.pdfDoc?.updateChangeCount(.changeDone) }
    }

    @objc private func clearHighlights() {
        editor?.clearCompareHighlights()
        highlightsRemoved()
    }

    func highlightsRemoved() {
        keepBox.state = .off
        keepBox.isEnabled = false
        clearButton.isEnabled = false
    }

    func windowWillClose(_ notification: Notification) {
        if keepBox.state != .on { editor?.clearCompareHighlights() }
        if editor?.compareWindow === self { editor?.compareWindow = nil }
    }
}
