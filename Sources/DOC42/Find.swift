import AppKit
import Kit42

/// Find bar client for the whole document: the text is one storage shown by one text view per page column,
/// so matches are reported in whichever view holds them, and replacing goes through the text system (undoable).
final class PagedFinderClient: NSObject, NSTextFinderClient {
    private unowned let editor: DocWindowController
    init(_ editor: DocWindowController) { self.editor = editor }

    private var tv: NSTextView { editor.textView }
    private var lm: NSLayoutManager { editor.paged.layoutManager }

    var string: String { tv.string }
    var isSelectable: Bool { true }
    var isEditable: Bool { true }
    var allowsMultipleSelection: Bool { false }
    var firstSelectedRange: NSRange { tv.selectedRange() }
    var selectedRanges: [NSValue] {
        get { tv.selectedRanges }
        set { tv.selectedRanges = newValue }
    }

    func scrollRangeToVisible(_ range: NSRange) { editor.paged.textView(at: range.location)?.scrollRangeToVisible(range) }

    func shouldReplaceCharacters(inRanges ranges: [NSValue], with strings: [String]) -> Bool {
        tv.shouldChangeText(inRanges: ranges, replacementStrings: strings)
    }

    func replaceCharacters(in range: NSRange, with string: String) { tv.textStorage?.replaceCharacters(in: range, with: string) }

    func didReplaceCharacters() { tv.didChangeText() }

    func contentView(at index: Int, effectiveCharacterRange outRange: NSRangePointer) -> NSView {
        let view = editor.paged.textView(at: index) ?? tv
        let g = lm.glyphRange(for: view.textContainer!)
        var r = lm.characterRange(forGlyphRange: g, actualGlyphRange: nil)
        if !NSLocationInRange(index, r) { r = NSRange(location: index, length: max(0, (tv.textStorage?.length ?? 0) - index)) }
        outRange.pointee = r
        return view
    }

    func rects(forCharacterRange range: NSRange) -> [NSValue]? {
        guard let view = editor.paged.textView(at: range.location), let container = view.textContainer else { return nil }
        var rects: [NSValue] = []
        let g = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        lm.enumerateEnclosingRects(forGlyphRange: g, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: container) { r, _ in
            rects.append(NSValue(rect: r.offsetBy(dx: view.textContainerOrigin.x, dy: view.textContainerOrigin.y)))
        }
        return rects
    }

    var visibleCharacterRanges: [NSValue] {
        editor.paged.textViews.compactMap { view -> NSValue? in
            guard !view.visibleRect.isEmpty, let c = view.textContainer else { return nil }
            return NSValue(range: lm.characterRange(forGlyphRange: lm.glyphRange(for: c), actualGlyphRange: nil))
        }
    }
}

/// Search options of the Find and Replace dialog.
struct FindOptions {
    var matchCase = false
    var wholeWords = false
    var regex = false
}

enum TextSearch {
    static func expression(_ pattern: String, _ o: FindOptions) -> NSRegularExpression? {
        guard !pattern.isEmpty else { return nil }
        var p = o.regex ? pattern : NSRegularExpression.escapedPattern(for: pattern)
        if o.wholeWords { p = "(?<![\\p{L}\\p{N}_])(?:" + p + ")(?![\\p{L}\\p{N}_])" }
        return try? NSRegularExpression(pattern: p, options: o.matchCase ? [] : [.caseInsensitive])
    }

    /// Text that replaces a match: `$1` templates with regular expressions, else literal.
    static func replacement(_ m: NSTextCheckingResult, in s: String, template: String, _ re: NSRegularExpression, _ o: FindOptions) -> String {
        o.regex ? re.replacementString(for: m, in: s, offset: 0, template: template) : template
    }

    /// A selected match still obeys boundaries and lookarounds in the surrounding document.
    static func selectedMatch(in string: String, range: NSRange, expression: NSRegularExpression) -> NSTextCheckingResult? {
        guard range.length > 0,
              let match = expression.firstMatch(in: string, options: [.anchored, .withTransparentBounds, .withoutAnchoringBounds], range: range),
              match.range == range else { return nil }
        return match
    }

    /// Replaces every match in one undoable change (through `textView` when given). Returns the count.
    @discardableResult
    static func replaceAll(_ storage: NSTextStorage, find: String, with template: String, _ o: FindOptions, in scope: NSRange? = nil,
                           textView: NSTextView? = nil) -> Int {
        guard let re = expression(find, o) else { return 0 }
        let s = storage.string
        let matches = re.matches(in: s, range: scope ?? NSRange(location: 0, length: storage.length)).filter { $0.range.length > 0 }
        guard !matches.isEmpty else { return 0 }
        let strings = matches.map { replacement($0, in: s, template: template, re, o) }
        if let textView, !textView.shouldChangeText(inRanges: matches.map { NSValue(range: $0.range) }, replacementStrings: strings) { return 0 }
        storage.beginEditing()
        for (m, r) in zip(matches, strings).reversed() { storage.replaceCharacters(in: m.range, with: r) }
        storage.endEditing()
        textView?.didChangeText()
        textView?.undoManager?.setActionName(L("Replace All"))
        return matches.count
    }
}

/// Find and Replace dialog: match case, whole words, regular expressions; Replace and Replace All are undoable.
final class FindReplacePanel: NSWindowController, NSWindowDelegate {
    static let shared = FindReplacePanel()
    private let findField = NSTextField(string: "")
    private let replaceField = NSTextField(string: "")
    private let matchCase = NSButton(checkboxWithTitle: L("Match case"), target: nil, action: nil)
    private let wholeWords = NSButton(checkboxWithTitle: L("Whole words"), target: nil, action: nil)
    private let regex = NSButton(checkboxWithTitle: L("Regular expression"), target: nil, action: nil)
    private let status = NSTextField(labelWithString: "")
    private weak var editor: DocWindowController?

    private init() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 190), styleMask: [.titled, .closable, .utilityWindow],
                            backing: .buffered, defer: true)
        panel.title = L("Find and Replace")
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = true
        panel.becomesKeyOnlyIfNeeded = false
        super.init(window: panel)
        panel.delegate = self
        findField.placeholderString = L("Find")
        replaceField.placeholderString = L("Replace with")
        status.textColor = .secondaryLabelColor
        status.font = .systemFont(ofSize: 11)
        let grid = NSGridView(views: [[NSTextField(labelWithString: L("Find:")), findField],
                                      [NSTextField(labelWithString: L("Replace:")), replaceField]])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 8
        findField.widthAnchor.constraint(equalToConstant: 330).isActive = true
        let checks = NSStackView(views: [matchCase, wholeWords, regex])
        checks.spacing = 14
        func button(_ title: String, _ action: Selector) -> NSButton {
            let b = NSButton(title: title, target: self, action: action)
            b.bezelStyle = .rounded
            return b
        }
        let next = button(L("Find Next"), #selector(findNext(_:)))
        next.keyEquivalent = "\r"
        let buttons = NSStackView(views: [status, NSView(), button(L("Previous"), #selector(findPrevious(_:))), next,
                                          button(L("Replace"), #selector(replaceOne(_:))), button(L("Replace All"), #selector(replaceAll(_:)))])
        buttons.spacing = 8
        status.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let stack = NSStackView(views: [grid, checks, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        buttons.widthAnchor.constraint(equalTo: grid.widthAnchor).isActive = true
        panel.contentView = stack
        panel.setContentSize(stack.fittingSize)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    func show(for editor: DocWindowController) {
        self.editor = editor
        let sel = editor.textView.selectedRange()
        if sel.length > 0, sel.length < 200 { findField.stringValue = (editor.textView.string as NSString).substring(with: sel) }
        status.stringValue = ""
        if window?.isVisible != true { window?.center() }
        showWindow(nil)
        window?.makeFirstResponder(findField)
    }

    private var options: FindOptions { FindOptions(matchCase: matchCase.state == .on, wholeWords: wholeWords.state == .on, regex: regex.state == .on) }

    private var target: DocWindowController? {
        (NSApp.mainWindow?.windowController as? DocWindowController) ?? editor
    }

    /// Next (or previous) match from the selection, wrapping around.
    @discardableResult
    private func find(backwards: Bool) -> Bool {
        guard let editor = target, let re = TextSearch.expression(findField.stringValue, options) else {
            status.stringValue = findField.stringValue.isEmpty ? "" : L("Invalid regular expression")
            return false
        }
        let tv = editor.textView
        let s = tv.string
        let all = re.matches(in: s, range: NSRange(location: 0, length: (s as NSString).length)).filter { $0.range.length > 0 }
        guard !all.isEmpty else { status.stringValue = L("Not found"); NSSound.beep(); return false }
        let sel = tv.selectedRange()
        let m = backwards ? (all.last { NSMaxRange($0.range) <= sel.location } ?? all.last!)
                          : (all.first { $0.range.location >= NSMaxRange(sel) && $0.range != sel } ?? all.first!)
        tv.setSelectedRange(m.range)
        editor.paged.scrollRangeToVisible(m.range)
        status.stringValue = L("%d found", all.count)
        return true
    }

    @objc private func findNext(_ sender: Any?) { find(backwards: false) }
    @objc private func findPrevious(_ sender: Any?) { find(backwards: true) }

    @objc private func replaceOne(_ sender: Any?) {
        guard let editor = target, let storage = editor.textView.textStorage, let re = TextSearch.expression(findField.stringValue, options) else { return }
        let tv = editor.textView
        let sel = tv.selectedRange()
        // Replace the selection when it is a match, then go to the next one.
        if let m = TextSearch.selectedMatch(in: tv.string, range: sel, expression: re) {
            let r = TextSearch.replacement(m, in: tv.string, template: replaceField.stringValue, re, options)
            if tv.shouldChangeText(in: sel, replacementString: r) {
                storage.replaceCharacters(in: sel, with: r)
                tv.didChangeText()
                tv.undoManager?.setActionName(L("Replace"))
                tv.setSelectedRange(NSRange(location: sel.location + (r as NSString).length, length: 0))
            }
        }
        find(backwards: false)
    }

    @objc private func replaceAll(_ sender: Any?) {
        guard let editor = target, let storage = editor.textView.textStorage else { return }
        let n = TextSearch.replaceAll(storage, find: findField.stringValue, with: replaceField.stringValue, options, textView: editor.textView)
        status.stringValue = n == 0 ? L("Not found") : L("%d replaced", n)
        if n == 0 { NSSound.beep() }
    }
}

extension DocWindowController {
    // MARK: - Find

    /// Find menu and find bar commands (tags are NSTextFinder actions) for all pages.
    func performFinderAction(_ sender: Any?) {
        guard let action = NSTextFinder.Action(rawValue: commandTag(of: sender)) else { return }
        finder.performAction(action)
    }

    func validateFinderAction(_ item: NSValidatedUserInterfaceItem) -> Bool {
        guard let action = NSTextFinder.Action(rawValue: item.tag) else { return false }
        return finder.validateAction(action)
    }

    @objc func findReplaceAction(_ sender: Any?) { FindReplacePanel.shared.show(for: self) }

    @objc func findNextAction(_ sender: Any?) { finder.performAction(.nextMatch) }
    @objc func findPreviousAction(_ sender: Any?) { finder.performAction(.previousMatch) }
    @objc func useSelectionForFindAction(_ sender: Any?) { finder.performAction(.setSearchString) }
    @objc func showReplaceBarAction(_ sender: Any?) { finder.performAction(.showReplaceInterface) }
}
