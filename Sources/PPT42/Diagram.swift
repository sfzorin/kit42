import AppKit
import Kit42

/// SmartArt: shown and edited as the shapes of its drawing part (dsp:drawing); the diagram parts are kept for writing back.
final class DiagramSource: Equatable {
    /// Data model, layout, quick style, colours (r:dm, r:lo, r:qs, r:cs) and the drawing part.
    let data: PackagePart?
    let layout: PackagePart?
    let style: PackagePart?
    let colors: PackagePart?
    let drawing: PackagePart?
    /// The shapes as read (ids ignored): unchanged shapes write the diagram back as it was.
    let children: [SlideObject]
    /// Model ids of the drawing's shapes, in the order of `children` (flattened).
    let modelIDs: [String?]
    let frame: CGRect

    init(data: PackagePart?, layout: PackagePart?, style: PackagePart?, colors: PackagePart?, drawing: PackagePart?, children: [SlideObject], modelIDs: [String?], frame: CGRect) {
        self.data = data; self.layout = layout; self.style = style; self.colors = colors; self.drawing = drawing
        self.frame = frame
        self.children = Diagram.stripped(children)
        self.modelIDs = modelIDs
    }

    static func == (a: DiagramSource, b: DiagramSource) -> Bool { a === b }
}

enum Diagram {
    static let relDrawing = "http://schemas.microsoft.com/office/2007/relationships/diagramDrawing"
    static let nsDgm = "http://schemas.openxmlformats.org/drawingml/2006/diagram"
    static let nsDsp = "http://schemas.microsoft.com/office/drawing/2008/diagram"

    /// Objects without ids (ids are renumbered after reading).
    static func stripped(_ list: [SlideObject]) -> [SlideObject] {
        list.map { var o = $0; o.id = 0; o.children = stripped(o.children); return o }
    }

    static func flat(_ list: [SlideObject]) -> [SlideObject] { list.flatMap { [$0] + flat($0.children) } }

    enum Change { case none, text, other }

    /// How the shapes differ from the diagram as read.
    static func change(_ o: SlideObject) -> Change {
        guard let d = o.diagram, abs(o.frame.width - d.frame.width) < 0.01, abs(o.frame.height - d.frame.height) < 0.01, o.rotation == 0 else { return .other }
        // Moving the whole diagram keeps it a diagram (its drawing is relative to the frame).
        let delta = CGSize(width: d.frame.minX - o.frame.minX, height: d.frame.minY - o.frame.minY)
        let now = stripped(o.children.map { var c = $0; c.offset(by: delta); return c })
        if now == d.children { return .none }
        let a = flat(now), b = flat(d.children)
        guard a.count == b.count else { return .other }
        for (x, y) in zip(a, b) {
            var x1 = x, y1 = y
            x1.text = nil; y1.text = nil
            x1.children = []; y1.children = []
            if x1 != y1 { return .other }
        }
        return .text
    }

    /// Replaces the text of changed shapes in the drawing XML and the data model (by model id).
    static func patched(_ o: SlideObject, writer: PPTXWriter, rels: PPTXWriter.Rels) -> (drawing: Data?, data: Data?) {
        guard let d = o.diagram, let drawingData = d.drawing?.data,
              let drawingDoc = try? XMLDocument(data: drawingData, options: [.nodePreserveWhitespace]) else { return (nil, nil) }
        let dataDoc = d.data.flatMap { try? XMLDocument(data: $0.data, options: [.nodePreserveWhitespace]) }
        let now = flat(stripped(o.children)), old = flat(d.children)
        let shapes = drawingDoc.rootElement()?.descendants("sp") ?? []
        let points = dataDoc?.rootElement()?.descendants("pt") ?? []
        for (k, (a, b)) in zip(now, old).enumerated() where a.text != b.text {
            guard let t = a.text, shapes.indices.contains(k) else { continue }
            let sp = shapes[k]
            let body = writer.textBody(t, rels: rels, tag: "dsp:txBody")
            let wrapped = body.replacingOccurrences(of: "<dsp:txBody>", with: "<dsp:txBody xmlns:dsp=\"\(nsDsp)\" xmlns:a=\"\(PPTXWriter.nsA)\">")
            if let el = try? XMLElement(xmlString: wrapped), let old = sp.child("txBody") {
                sp.replaceChild(at: old.index, with: el)
            }
            // The data point behind the presentation point of this shape.
            guard let mid = sp.a("modelId") ?? (d.modelIDs.indices.contains(k) ? d.modelIDs[k] : nil),
                  let pres = points.first(where: { $0.a("modelId") == mid }) else { continue }
            let nodeID = pres.child("prSet")?.a("presAssocID") ?? mid
            guard let node = points.first(where: { $0.a("modelId") == nodeID && $0.a("type") != "pres" }) else { continue }
            var dt = body.replacingOccurrences(of: "<dsp:txBody>", with: "<dgm:t xmlns:dgm=\"\(nsDgm)\" xmlns:a=\"\(PPTXWriter.nsA)\">")
            dt = dt.replacingOccurrences(of: "</dsp:txBody>", with: "</dgm:t>")
            if let el = try? XMLElement(xmlString: dt) {
                if let old = node.child("t") { node.replaceChild(at: old.index, with: el) } else { node.addChild(el) }
            }
        }
        return (drawingDoc.xmlData(options: [.nodeCompactEmptyElement]), dataDoc?.xmlData(options: [.nodeCompactEmptyElement]))
    }
}

extension DeckWindowController {
    /// SmartArt → an ordinary group of shapes.
    @objc func convertToShapesAction(_ sender: Any?) {
        changeSelected(L("Convert to Shapes")) { o in o.diagram = nil }
    }
}
