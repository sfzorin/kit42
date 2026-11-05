import AppKit
import Kit42

/// A review comment on a slide (optionally attached to an object), with replies.
struct Comment: Equatable {
    var id = UUID()
    var author: String
    var initials: String
    var date: Date
    var text: String
    /// Slide coordinates of the marker.
    var position = CGPoint(x: 10, y: 10)
    var objectID: Int?
    var replies: [Comment] = []
    var resolved = false

    static func initials(_ name: String) -> String {
        let parts = name.split(separator: " ").compactMap { $0.first.map(String.init) }
        return parts.prefix(2).joined().uppercased().isEmpty ? "?" : parts.prefix(2).joined().uppercased()
    }

    static var currentAuthor: String {
        let n = NSFullUserName()
        return n.isEmpty ? NSUserName() : n
    }

    static func new(_ text: String, at p: CGPoint, object: Int? = nil) -> Comment {
        let a = currentAuthor
        return Comment(author: a, initials: initials(a), date: Date(), text: text, position: p, objectID: object)
    }
}

enum CommentDates {
    static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    static let plain = ISO8601DateFormatter()

    static func parse(_ s: String?) -> Date? {
        guard let s else { return nil }
        if let d = iso.date(from: s) ?? plain.date(from: s) { return d }
        // "2026-11-05T07:30:00.000" without a zone (legacy comments, ODF dc:date).
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        for fmt in ["yyyy-MM-dd'T'HH:mm:ss.SSS", "yyyy-MM-dd'T'HH:mm:ss.SSSSSSSSS", "yyyy-MM-dd'T'HH:mm:ss"] {
            f.dateFormat = fmt
            if let d = f.date(from: s) { return d }
        }
        return nil
    }

    static func display(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: d)
    }
}

// MARK: - Editing

extension DeckWindowController {
    @objc func insertCommentAction(_ sender: Any?) {
        showInspector(true, tab: 4)
        inspector.focusNewComment()
    }

    /// Adds a comment to the current slide (next to the selected object).
    func addComment(_ text: String) {
        guard currentSlide != nil, !text.isEmpty else { return }
        let o = selectedObjects.first
        let p = o.map { CGPoint(x: min(deck.size.width - 24, $0.frame.maxX + 4), y: max(4, $0.frame.minY)) } ?? CGPoint(x: 10, y: 10 + CGFloat(currentSlide?.comments.count ?? 0) * 26)
        var c = Comment.new(text, at: p, object: o?.id)
        if let o { c.position.y += CGFloat(currentSlide?.comments.filter { $0.objectID == o.id }.count ?? 0) * 22 }
        let i = current
        doc?.change(L("Add Comment")) { $0.slides[i].comments.append(c) }
    }

    func changeComment(_ id: UUID, _ name: String, _ body: @escaping (inout Comment) -> Void) {
        let i = current
        guard deck.slides.indices.contains(i) else { return }
        doc?.change(name) { d in
            for k in d.slides[i].comments.indices {
                if d.slides[i].comments[k].id == id { body(&d.slides[i].comments[k]); return }
                for r in d.slides[i].comments[k].replies.indices where d.slides[i].comments[k].replies[r].id == id {
                    body(&d.slides[i].comments[k].replies[r]); return
                }
            }
        }
    }

    func replyComment(_ id: UUID, _ text: String) {
        guard !text.isEmpty else { return }
        let a = Comment.currentAuthor
        changeComment(id, L("Reply")) { c in c.replies.append(Comment(author: a, initials: Comment.initials(a), date: Date(), text: text, position: c.position)) }
    }

    func deleteComment(_ id: UUID) {
        let i = current
        guard deck.slides.indices.contains(i) else { return }
        doc?.change(L("Delete Comment")) { d in
            d.slides[i].comments.removeAll { $0.id == id }
            for k in d.slides[i].comments.indices { d.slides[i].comments[k].replies.removeAll { $0.id == id } }
        }
    }
}

/// Comments of the current slide in the inspector.
final class CommentsPane: NSStackView {
    weak var owner: DeckWindowController?
    let input = NSTextField()
    private let addButton = NSButton(title: L("Add Comment"), target: nil, action: nil)
    private let list = NSStackView()
    private let empty = NSTextField(wrappingLabelWithString: L("No comments on this slide."))
    private var replyTo: UUID?
    private let replyLabel = NSTextField(labelWithString: "")

    convenience init(owner: DeckWindowController) {
        self.init(frame: .zero)
        self.owner = owner
        orientation = .vertical
        alignment = .leading
        spacing = 10
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 10
        empty.textColor = .secondaryLabelColor
        input.placeholderString = L("Write a comment")
        input.target = self
        input.action = #selector(add)
        input.translatesAutoresizingMaskIntoConstraints = false
        input.widthAnchor.constraint(equalToConstant: 240).isActive = true
        addButton.target = self
        addButton.action = #selector(add)
        addButton.bezelStyle = .rounded
        replyLabel.font = .systemFont(ofSize: 11)
        replyLabel.textColor = .secondaryLabelColor
        replyLabel.isHidden = true
        let header = NSTextField(labelWithString: L("COMMENTS"))
        header.font = .systemFont(ofSize: 11, weight: .semibold)
        header.textColor = .secondaryLabelColor
        setViews([header, list, empty, replyLabel, input, addButton], in: .top)
    }

    func reload() {
        guard let owner else { return }
        list.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let comments = owner.mode == .normal ? owner.currentSlide?.comments ?? [] : []
        empty.isHidden = !comments.isEmpty
        for c in comments { list.addArrangedSubview(card(c, reply: false)) }
        if let r = replyTo, !comments.contains(where: { $0.id == r }) { replyTo = nil }
        replyLabel.isHidden = replyTo == nil
        replyLabel.stringValue = replyTo.flatMap { id in comments.first { $0.id == id } }.map { L("Reply to %@", $0.author) } ?? ""
        addButton.title = replyTo == nil ? L("Add Comment") : L("Reply")
        input.isEnabled = owner.mode == .normal && owner.currentSlide != nil
        addButton.isEnabled = input.isEnabled
    }

    private func card(_ c: Comment, reply: Bool) -> NSView {
        let who = NSTextField(labelWithString: c.author)
        who.font = .systemFont(ofSize: 12, weight: .semibold)
        let when = NSTextField(labelWithString: CommentDates.display(c.date) + (c.resolved ? " · " + L("Resolved") : ""))
        when.font = .systemFont(ofSize: 10)
        when.textColor = .secondaryLabelColor
        let text = NSTextField(wrappingLabelWithString: c.text)
        text.font = .systemFont(ofSize: 12)
        text.preferredMaxLayoutWidth = reply ? 210 : 230
        if c.resolved { text.textColor = .secondaryLabelColor }
        var views: [NSView] = [who, when, text]
        if !reply {
            for r in c.replies { views.append(card(r, reply: true)) }
            func button(_ t: String, _ s: Selector) -> NSButton {
                let b = NSButton(title: t, target: self, action: s)
                b.bezelStyle = .inline
                b.controlSize = .small
                b.identifier = NSUserInterfaceItemIdentifier(c.id.uuidString)
                return b
            }
            let row = NSStackView(views: [button(L("Reply"), #selector(reply(_:))), button(c.resolved ? L("Reopen") : L("Resolve"), #selector(resolve(_:))),
                                          button(L("Delete"), #selector(delete(_:)))])
            row.spacing = 4
            views.append(row)
        }
        let v = NSStackView(views: views)
        v.orientation = .vertical
        v.alignment = .leading
        v.spacing = 3
        v.edgeInsets = NSEdgeInsets(top: 6, left: reply ? 14 : 8, bottom: 6, right: 8)
        if !reply {
            v.wantsLayer = true
            v.layer?.cornerRadius = 6
            v.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(c.resolved ? 0.35 : 0.8).cgColor
        }
        return v
    }

    private func id(_ sender: NSButton) -> UUID? { sender.identifier.flatMap { UUID(uuidString: $0.rawValue) } }

    @objc private func add() {
        guard let owner else { return }
        let t = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        input.stringValue = ""
        if let r = replyTo { owner.replyComment(r, t); replyTo = nil } else { owner.addComment(t) }
    }

    @objc private func reply(_ sender: NSButton) {
        replyTo = id(sender)
        reload()
        window?.makeFirstResponder(input)
    }

    @objc private func resolve(_ sender: NSButton) {
        guard let owner, let id = id(sender) else { return }
        owner.changeComment(id, L("Resolve")) { $0.resolved.toggle() }
    }

    @objc private func delete(_ sender: NSButton) {
        guard let owner, let id = id(sender) else { return }
        owner.deleteComment(id)
    }

    override func layout() {
        super.layout()
        // NSColor layers follow the appearance.
        effectiveAppearance.performAsCurrentDrawingAppearance {
            for v in list.arrangedSubviews { v.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.8).cgColor }
        }
    }
}

// MARK: - Markers on the canvas

enum CommentMarkers {
    static func rects(_ slide: Slide, scale: CGFloat) -> [(Comment, CGRect)] {
        slide.comments.map { c in (c, CGRect(x: c.position.x, y: c.position.y, width: 22 / scale, height: 18 / scale)) }
    }

    static func draw(_ slide: Slide, in ctx: CGContext, toView: (CGRect) -> CGRect, scale: CGFloat) {
        for (c, r) in rects(slide, scale: scale) {
            let v = toView(r)
            let path = CGPath(roundedRect: v, cornerWidth: 4, cornerHeight: 4, transform: nil)
            ctx.addPath(path)
            ctx.setFillColor((c.resolved ? NSColor.systemGray : NSColor.systemOrange).cgColor)
            ctx.fillPath()
            let s = NSAttributedString(string: c.initials, attributes: [.font: NSFont.systemFont(ofSize: 9, weight: .bold), .foregroundColor: NSColor.white])
            let sz = s.size()
            s.draw(at: CGPoint(x: v.midX - sz.width / 2, y: v.midY - sz.height / 2))
        }
    }
}
