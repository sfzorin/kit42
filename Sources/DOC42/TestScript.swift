import AppKit
import Kit42

extension DocWindowController {
    /// Development aid: `K42_SCRIPT="sel 10 5; comment Text; note Text; section; landscape; cols 2; replace a b; undo; save /tmp/x.docx"`
    /// drives editor commands before a K42_SNAPSHOT (the same code paths as the menus, undo included).
    func runTestScript(_ script: String) {
        let storage = textView.textStorage!
        for step in script.split(separator: ";").map({ $0.trimmingCharacters(in: .whitespaces) }) where !step.isEmpty {
            let parts = step.split(separator: " ", maxSplits: 1).map(String.init)
            let arg = parts.count > 1 ? parts[1] : ""
            let nums = arg.split(separator: " ").compactMap { Int($0) }
            textView.breakUndoCoalescing()
            switch parts[0] {
            case "sel": textView.setSelectedRange(NSRange(location: nums[0], length: nums.count > 1 ? nums[1] : 0))
            case "find":
                let r = (storage.string as NSString).range(of: arg)
                if r.location != NSNotFound { textView.setSelectedRange(r) }
            case "end": textView.setSelectedRange(NSRange(location: storage.length, length: 0))
            case "type": textView.insertText(arg, replacementRange: textView.selectedRange())
            case "bs": for _ in 0..<max(1, nums.first ?? 1) { textView.deleteBackward(nil) }
            case "del": for _ in 0..<max(1, nums.first ?? 1) { textView.deleteForward(nil) }
            case "track": toggleTrackChangesAction(nil)
            case "markup": toggleMarkupAction(nil)
            case "nextchange": nextChangeAction(nil)
            case "accept": acceptChangeAction(nil)
            case "reject": rejectChangeAction(nil)
            case "acceptall": acceptAllChangesAction(nil)
            case "rejectall": rejectAllChangesAction(nil)
            case "dumptext": print("TEXT:", storage.string.debugDescription, "CHANGES:", Revisions.changes(in: storage).map { "\($0.kind.rawValue)@\($0.range.location)+\($0.range.length)" })
            case "comment":
                newCommentAction(nil)
                if let c = commentAtCursor { setCommentText(c, arg) }
            case "note": insertFootnote(arg, edit: false)
            case "section": insertSectionBreakAction(nil)
            case "landscape", "portrait":
                let item = NSMenuItem(); item.tag = parts[0] == "landscape" ? 1 : 0
                orientationAction(item)
            case "cols":
                let item = NSMenuItem(); item.tag = (nums.first ?? 1) - 1
                columnsAction(item)
            case "replace":
                let fr = arg.split(separator: "|").map(String.init)
                let n = TextSearch.replaceAll(storage, find: fr[0], with: fr.count > 1 ? fr[1] : "", FindOptions(), textView: textView)
                print("replaced", n)
            case "undo": doc?.undoManager?.undo()
            case "redo": doc?.undoManager?.redo()
            case "toc": insertTOCAction(nil)
            case "paint":   // paint <from> <to> <len>
                textView.setSelectedRange(NSRange(location: nums[0], length: 1))
                formatPainterAction(nil)
                textView.setSelectedRange(NSRange(location: nums[1], length: nums[2]))
                textViewMouseUp(textView)
            case "link":
                let a: [NSAttributedString.Key: Any] = [.link: linkValue(arg), .foregroundColor: Self.linkColor, .underlineStyle: 1]
                if textView.shouldChangeText(in: textView.selectedRange(), replacementString: nil) {
                    storage.addAttributes(a, range: textView.selectedRange()); textView.didChangeText()
                }
            case "stats": print(TextStats.of(storage, NSRange(location: 0, length: storage.length), layout: paged.layoutManager), "pages", paged.cards.count)
            case "hidecomments": toggleCommentsAction(nil)
            case "findbar": finder.performAction(.showReplaceInterface)
            case "findnext": finder.performAction(.nextMatch)
            case "statistics": statisticsAction(nil)
            case "special": specialCharacterAction(nil)
            case "updatetoc": updateTOCAction(nil)
            case "scroll": paged.scrollRangeToVisible(NSRange(location: nums[0], length: 0))
            case "save":
                if let data = try? doc?.exportData(TextDocument.documentType(for: URL(fileURLWithPath: arg).pathExtension)) {
                    try? data.write(to: URL(fileURLWithPath: arg))
                }
            default: print("unknown step", step)
            }
            paged.layoutAll()
        }
        layoutComments()
        // The snapshot quits the app: no "save changes?" sheet.
        if ProcessInfo.processInfo.environment["K42_SNAPSHOT_KEEP"] == nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.doc?.updateChangeCount(.changeCleared) }   // after the undo group closes
        }
    }
}
