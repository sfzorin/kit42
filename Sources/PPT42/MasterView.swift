import AppKit
import Kit42

/// Master view: the master's placeholders with sample text, edited like a slide.
enum MasterView {
    /// Sample slide carrying the layout index (for style inheritance).
    static func sampleSlide(deck: Deck, layout: Int?) -> Slide {
        var s = Slide(layout: layout ?? 0)
        s.objects = sampleObjects(deck: deck, layout: layout)
        return s
    }

    /// Master (or layout) placeholders filled with "Click to edit…" text at each level.
    static func sampleObjects(deck: Deck, layout: Int?) -> [SlideObject] {
        let list = layout.flatMap { deck.layouts.indices.contains($0) ? deck.layouts[$0].placeholders : nil } ?? deck.master.placeholders
        return list.map { ph in
            var o = ph
            guard var t = o.text, let p = o.placeholder else { return o }
            if p.isTitle {
                t.paragraphs = [Paragraph(L("Click to edit Master title style"))]
            } else if p.type == "sldNum" {
                var para = Paragraph()
                para.runs = [TextRun(text: "‹#›", field: "slidenum")]
                t.paragraphs = [para]
            } else if p.type == "dt" {
                t.paragraphs = [Paragraph(L("Date"))]
            } else if p.type == "ftr" {
                t.paragraphs = [Paragraph(L("Footer"))]
            } else if p.type == "pic" {
                return o
            } else {
                let names = [L("Click to edit Master text styles"), L("Second level"), L("Third level"), L("Fourth level"), L("Fifth level")]
                t.paragraphs = names.enumerated().map { Paragraph($0.element, level: $0.offset) }
            }
            // Sample text shows the inherited style only.
            t.paragraphs = t.paragraphs.map { var q = $0; q.props = LevelStyle(); return q }
            o.text = t
            return o
        }
    }
}
