import AppKit
import Kit42

extension Deck {
    /// Object ids unique on every slide (pptx needs them; builds and selection use them).
    mutating func normalizeIDs() {
        for si in slides.indices {
            var used = Set<Int>([1])
            var next = (slides[si].maxID) + 1
            func visit(_ list: inout [SlideObject]) {
                for i in list.indices {
                    if list[i].id <= 1 || used.contains(list[i].id) { list[i].id = next; next += 1 }
                    used.insert(list[i].id)
                    visit(&list[i].children)
                }
            }
            visit(&slides[si].objects)
        }
    }

    /// Fills a placeholder of `type` on a slide with paragraphs.
    mutating func setText(slide: Int, placeholder type: String, idx: Int? = nil, _ paras: [Paragraph]) {
        guard slides.indices.contains(slide) else { return }
        for i in slides[slide].objects.indices {
            guard let ph = slides[slide].objects[i].placeholder else { continue }
            let match = ph.type == type || (type == "title" && ph.isTitle) || (type == "body" && ph.type == "body")
            guard match, idx == nil || ph.idx == idx else { continue }
            slides[slide].objects[i].text?.paragraphs = paras
            return
        }
    }

    /// A deck that uses every feature (CLI --demo and tests).
    static func demo() -> Deck {
        var d = Deck.makeDefault()
        func p(_ s: String, _ level: Int = 0, _ r: RunProps = RunProps()) -> Paragraph { Paragraph(s, level: level, run: r) }
        // 1. Title
        d.setText(slide: 0, placeholder: "ctrTitle", [p("PPT42 Feature Tour")])
        d.setText(slide: 0, placeholder: "subTitle", [p("Slides, shapes, text, tables, pictures, notes and transitions")])
        d.slides[0].notes = "Welcome everyone.\nThis deck exercises every feature of PPT42."
        d.slides[0].transition = Transition(kind: .fade, duration: 0.7)

        // 2. Bullets with levels and formatting
        var s2 = d.newSlide(layout: 1)
        s2.transition = Transition(kind: .push, duration: 0.6, direction: "l")
        d.slides.append(s2)
        var bold = RunProps(); bold.bold = true
        var colored = RunProps(); colored.color = PColor(scheme: "accent2"); colored.italic = true
        var first = p("Plain, ")
        first.runs += [TextRun(text: "bold", props: bold), TextRun(text: " and "), TextRun(text: "coloured italic", props: colored), TextRun(text: " runs")]
        var numbered = LevelStyle(); numbered.bullet = .numbered
        var n1 = p("Numbered item one", 1); n1.props = numbered
        var n2 = p("Numbered item two", 1); n2.props = numbered
        var under = RunProps(); under.underline = true; under.strike = false
        var centred = p("Centred line, underlined", 0, under); centred.props.align = .center; centred.props.bullet = Bullet.none
        d.setText(slide: 1, placeholder: "title", [p("Text and Bullets")])
        d.setText(slide: 1, placeholder: "body", [first, p("Second level bullet", 1), p("Third level", 2), n1, n2, centred])
        d.slides[1].notes = "Bullets at three levels, numbering and run formatting."

        // 3. Shapes and lines
        var s3 = d.newSlide(layout: 4)
        s3.transition = Transition(kind: .wipe, duration: 0.8, direction: "r")
        var id = 10
        func shape(_ prst: String, _ r: CGRect, _ fill: PColor, text: String = "", rot: CGFloat = 0) -> SlideObject {
            var o = SlideObject(id: id, kind: .shape, frame: r)
            id += 1
            o.geometry = prst
            o.fill = .solid(fill)
            o.line = LineStyle(color: fill.withAlpha(1), width: 1)
            o.line.color = PColor(scheme: "tx1", mods: [.init(name: "lumMod", val: 75000), .init(name: "lumOff", val: 25000)])
            o.rotation = rot
            var t = TextBody()
            t.anchor = .middle
            var c = Paragraph(text, run: RunProps(size: 16, color: PColor(scheme: "bg1")))
            c.props.align = .center
            t.paragraphs = [c]
            o.text = t
            return o
        }
        s3.objects.append(shape("rect", CGRect(x: 70, y: 160, width: 150, height: 100), PColor(scheme: "accent1"), text: "Rectangle"))
        var rr = shape("roundRect", CGRect(x: 250, y: 160, width: 150, height: 100), PColor(scheme: "accent2"), text: "Rounded")
        rr.shadow = true
        s3.objects.append(rr)
        s3.objects.append(shape("ellipse", CGRect(x: 430, y: 160, width: 150, height: 100), PColor(scheme: "accent3"), text: "Oval"))
        s3.objects.append(shape("triangle", CGRect(x: 610, y: 150, width: 120, height: 110), PColor(scheme: "accent4")))
        s3.objects.append(shape("star5", CGRect(x: 760, y: 150, width: 120, height: 115), PColor(scheme: "accent5"), rot: 15))
        var grad = shape("rightArrow", CGRect(x: 70, y: 300, width: 220, height: 90), PColor(scheme: "accent6"), text: "Gradient")
        grad.fill = .gradient(Gradient(stops: [GradientStop(position: 0, color: PColor(scheme: "accent1")), GradientStop(position: 1, color: PColor(scheme: "accent6"))], angle: 0))
        s3.objects.append(grad)
        var half = shape("hexagon", CGRect(x: 330, y: 300, width: 140, height: 100), PColor(scheme: "accent2"), text: "50 %")
        half.opacity = 0.5
        s3.objects.append(half)
        var line = SlideObject(id: id, kind: .line, frame: .zero); id += 1
        line.geometry = "straightConnector1"
        line.setLine(from: CGPoint(x: 520, y: 400), to: CGPoint(x: 700, y: 310))
        line.line = LineStyle(color: PColor(scheme: "tx1"), width: 2.5, dash: .solid, head: .none, tail: .triangle)
        s3.objects.append(line)
        var dashed = SlideObject(id: id, kind: .line, frame: .zero); id += 1
        dashed.geometry = "line"
        dashed.setLine(from: CGPoint(x: 720, y: 420), to: CGPoint(x: 890, y: 420))
        dashed.line = LineStyle(color: PColor(scheme: "accent1"), width: 2, dash: .dash, head: .oval, tail: .arrow)
        s3.objects.append(dashed)
        var g1 = shape("ellipse", CGRect(x: 760, y: 300, width: 50, height: 50), PColor(scheme: "accent1"))
        var g2 = shape("ellipse", CGRect(x: 820, y: 300, width: 50, height: 50), PColor(scheme: "accent2"))
        g1.text = nil; g2.text = nil
        var group = SlideObject(id: id, kind: .group, frame: g1.frame.union(g2.frame)); id += 1
        group.children = [g1, g2]
        s3.objects.append(group)
        d.slides.append(s3)
        d.setText(slide: 2, placeholder: "title", [p("Shapes, Lines and Groups")])

        // 4. Table
        var s4 = d.newSlide(layout: 4)
        s4.transition = Transition(kind: .cover, duration: 0.6, direction: "u")
        var t = TableModel(rows: 4, columns: 3, width: 700, rowHeight: 50)
        let data = [["Quarter", "Revenue", "Growth"], ["Q1", "1.2 M", "4 %"], ["Q2", "1.5 M", "25 %"], ["Q3", "1.9 M", "27 %"]]
        for r in 0..<4 { for c in 0..<3 { t.cells[r][c].text.paragraphs = [Paragraph(data[r][c])]; t.cells[r][c].text.anchor = .middle } }
        var table = SlideObject(id: id, kind: .table, frame: CGRect(x: 130, y: 170, width: 700, height: 200)); id += 1
        table.table = t
        s4.objects.append(table)
        d.slides.append(s4)
        d.setText(slide: 3, placeholder: "title", [p("A Table")])

        // 5. Picture and builds
        var s5 = d.newSlide(layout: 4)
        s5.transition = Transition(kind: .dissolve, duration: 0.7)
        let img = NSImage(size: NSSize(width: 320, height: 200), flipped: false) { r in
            NSGradient(starting: NSColor(srgbRed: 1, green: 0.71, blue: 0.28, alpha: 1), ending: NSColor(srgbRed: 0.9, green: 0.4, blue: 0.1, alpha: 1))!.draw(in: r, angle: -60)
            NSColor.white.setFill()
            NSBezierPath(ovalIn: NSRect(x: 220, y: 120, width: 50, height: 50)).fill()
            NSColor(white: 1, alpha: 0.5).setFill()
            let m = NSBezierPath()
            m.move(to: .zero); m.line(to: NSPoint(x: 120, y: 130)); m.line(to: NSPoint(x: 200, y: 60)); m.line(to: NSPoint(x: 260, y: 100)); m.line(to: NSPoint(x: 320, y: 0)); m.close()
            m.fill()
            return true
        }
        if let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
            let name = d.addMedia(png, ext: "png")
            var pic = SlideObject(id: id, kind: .picture, frame: CGRect(x: 80, y: 160, width: 384, height: 240)); id += 1
            pic.media = name
            pic.name = "Landscape"
            pic.descr = "A drawn landscape"
            s5.objects.append(pic)
        }
        var b1 = SlideObject(id: id, kind: .textBox, frame: CGRect(x: 520, y: 170, width: 360, height: 60)); id += 1
        b1.text = TextBody(paragraphs: [Paragraph("Appears on click", run: RunProps(size: 24))])
        var b2 = SlideObject(id: id, kind: .textBox, frame: CGRect(x: 520, y: 250, width: 360, height: 60)); id += 1
        b2.text = TextBody(paragraphs: [Paragraph("Fades in next", run: RunProps(size: 24, color: PColor(scheme: "accent1")))])
        s5.objects += [b1, b2]
        s5.animations = [Animation(target: b1.id, effect: .appear), Animation(target: b2.id, effect: .fade)]
        var num = SlideObject(id: id, kind: .textBox, frame: CGRect(x: 820, y: 480, width: 80, height: 30)); id += 1
        var np = Paragraph()
        np.runs = [TextRun(text: "5", props: RunProps(size: 12), field: "slidenum")]
        np.props.align = .right
        num.text = TextBody(paragraphs: [np])
        s5.objects.append(num)
        d.slides.append(s5)
        d.setText(slide: 4, placeholder: "title", [p("Pictures and Builds")])
        d.slides[4].notes = "Click twice to reveal the two text boxes."

        // 6. Section header with gradient background
        var s6 = d.newSlide(layout: 3)
        s6.background = .gradient(Gradient(stops: [GradientStop(position: 0, color: PColor(scheme: "accent1")), GradientStop(position: 1, color: PColor(scheme: "tx2"))], angle: 45))
        s6.transition = Transition(kind: .zoom, duration: 0.6)
        d.slides.append(s6)
        var white = RunProps(); white.color = .white
        d.setText(slide: 5, placeholder: "title", [Paragraph("Two Columns Next", run: white)])
        d.setText(slide: 5, placeholder: "body", [Paragraph("Section header on a gradient background", run: white)])

        // 7. Two content, hidden slide
        let s7 = d.newSlide(layout: 2)
        d.slides.append(s7)
        d.setText(slide: 6, placeholder: "title", [p("Two Content")])
        d.setText(slide: 6, placeholder: "body", idx: 1, [p("Left column"), p("Point A", 1)])
        d.setText(slide: 6, placeholder: "body", idx: 2, [p("Right column"), p("Point B", 1)])
        var s8 = d.newSlide(layout: 5)
        s8.hidden = true
        var hb = SlideObject(id: 20, kind: .textBox, frame: CGRect(x: 100, y: 220, width: 760, height: 80))
        var hp = Paragraph("Hidden slide (skipped in the show)", run: RunProps(size: 32))
        hp.props.align = .center
        hb.text = TextBody(paragraphs: [hp])
        s8.objects.append(hb)
        d.slides.append(s8)
        d.addDemoExtras()
        d.normalizeIDs()
        return d
    }

    /// Charts, presets with adjust values, custom geometry, SmartArt-like group, media, comments, animations, a custom layout.
    mutating func addDemoExtras() {
        func title(_ s: inout Slide, _ t: String) {
            for i in s.objects.indices where s.objects[i].placeholder?.isTitle == true { s.objects[i].text?.paragraphs = [Paragraph(t)] }
        }
        // 9. Charts
        var s9 = newSlide(layout: 4)
        title(&s9, "Charts")
        var col = SlideObject(id: 30, kind: .chart, frame: CGRect(x: 50, y: 140, width: 440, height: 340))
        var m = ChartModel.sample(.column)
        m.title = Optional("Sales by quarter")  // demo content, not UI
        m.dataLabels = true
        m.valAxisTitle = "M€"
        col.chart = m
        var pie = SlideObject(id: 31, kind: .chart, frame: CGRect(x: 510, y: 140, width: 400, height: 340))
        var pm = ChartModel.sample(.doughnut)
        pm.title = Optional("Budget")
        pm.percentLabels = true
        pie.chart = pm
        s9.objects += [col, pie]
        s9.animations = [Animation(target: 30, effect: .fade), Animation(target: 31, effect: .zoom, trigger: .afterPrevious)]
        slides.append(s9)

        // 10. Preset shapes with adjust values and a custom outline
        var s10 = newSlide(layout: 4)
        title(&s10, "Preset and Custom Shapes")
        var id = 40
        func shape(_ prst: String, _ r: CGRect, _ c: String, adjust: [String: Int] = [:]) -> SlideObject {
            var o = SlideObject(id: id, kind: .shape, frame: r)
            id += 1
            o.geometry = prst
            o.adjust = adjust
            o.fill = .solid(PColor(scheme: c))
            o.line = LineStyle(color: PColor(scheme: c, mods: [.init(name: "shade", val: 50000)]), width: 1)
            o.text = TextBody(paragraphs: [Paragraph()], anchor: .middle)
            return o
        }
        s10.objects += [
            shape("cloud", CGRect(x: 60, y: 150, width: 160, height: 110), "accent1"),
            shape("lightningBolt", CGRect(x: 250, y: 150, width: 110, height: 130), "accent4"),
            shape("smileyFace", CGRect(x: 390, y: 150, width: 120, height: 120), "accent6", adjust: ["adj": -4653]),
            shape("wedgeRoundRectCallout", CGRect(x: 550, y: 150, width: 180, height: 90), "accent2", adjust: ["adj1": -30000, "adj2": 90000, "adj3": 16667]),
            shape("rightArrow", CGRect(x: 760, y: 160, width: 150, height: 80), "accent5", adjust: ["adj1": 30000, "adj2": 70000]),
            shape("flowChartMultidocument", CGRect(x: 60, y: 320, width: 150, height: 110), "accent3"),
            shape("star12", CGRect(x: 250, y: 310, width: 130, height: 130), "accent2"),
            shape("can", CGRect(x: 420, y: 310, width: 100, height: 130), "accent1"),
        ]
        // A custom outline (a:custGeom) with guides and an arc.
        var c = SlideObject(id: id, kind: .shape, frame: CGRect(x: 570, y: 300, width: 300, height: 150)); id += 1
        var g = CustomGeometry()
        g.guides = [GeoGuide(name: "rad", fmla: "*/ h 1 2")]
        g.paths = [GeoPath(commands: [.move("0", "h"), .line("0", "rad"), .arc(wR: "rad", hR: "rad", st: "cd2", sw: "cd2"), .line("w", "h"), .close])]
        c.custom = g
        c.geometry = "custom"
        c.fill = .gradient(Gradient(stops: [GradientStop(position: 0, color: PColor(scheme: "accent1")), GradientStop(position: 1, color: PColor(scheme: "accent5"))], angle: 0))
        c.text = TextBody(paragraphs: [Paragraph("Custom outline", run: RunProps(size: 18, color: PColor(scheme: "bg1")))], anchor: .bottom)
        s10.objects.append(c)
        s10.animations = [Animation(target: 40, effect: .flyIn), Animation(target: 41, effect: .spin, trigger: .withPrevious),
                          Animation(target: 42, effect: .pulse), Animation(target: 43, effect: .colorChange),
                          Animation(target: 44, effect: .path), Animation(target: 45, effect: .fadeOut, trigger: .afterPrevious)]
        var cm = Comment.new("Check the colours of the callout", at: CGPoint(x: 734, y: 150), object: 43)
        cm.author = "PPT42 Demo"; cm.initials = "PD"
        var reply = Comment.new("Done", at: cm.position)
        reply.author = "Reviewer"; reply.initials = "RV"
        cm.replies = [reply]
        s10.comments = [cm]
        slides.append(s10)

        // 11. Media: a short generated clip (its own poster frame) and a custom layout from the master view.
        var quote = Layout(name: "Quote", type: "cust")
        quote.placeholders = [Themes.placeholder(2, "title", idx: nil, CGRect(x: 120, y: 150, width: 720, height: 200), name: "Quote Title", anchor: .middle,
                                                 style: LevelStyle(align: .center, run: RunProps(size: 40, italic: true)))]
        quote.objects = [{ var o = SlideObject(id: 90, kind: .line, frame: .zero); o.setLine(from: CGPoint(x: 380, y: 380), to: CGPoint(x: 580, y: 380))
            o.line = LineStyle(color: PColor(scheme: "accent1"), width: 3); return o }()]
        layouts.append(quote)
        var s11 = newSlide(layout: layouts.count - 1)
        title(&s11, "“Every feature, one deck.”")
        var clipDeck = Deck.makeDefault()
        clipDeck.setText(slide: 0, placeholder: "ctrTitle", [Paragraph("PPT42")])
        clipDeck.slides[0].transition = Transition()
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("ppt42-demo-\(ProcessInfo.processInfo.processIdentifier).mp4")
        var o = VideoExport.Options()
        o.width = 320
        o.secondsPerSlide = 1
        if (try? VideoExport.export(clipDeck, to: tmp, options: o)) != nil, let data = try? Data(contentsOf: tmp),
           let poster = Renderer.image(clipDeck.slides[0], deck: clipDeck, pixelWidth: 320).flatMap({ NSBitmapImageRep(cgImage: $0).representation(using: .png, properties: [:]) }) {
            var v = SlideObject(id: 60, kind: .picture, frame: CGRect(x: 700, y: 400, width: 192, height: 108))
            v.media = addMedia(poster, ext: "png")
            v.clip = MediaClip(media: addClip(data, ext: "mp4"), audio: false, autoplay: false, loop: true)
            v.name = "Clip"
            s11.objects.append(v)
        }
        try? FileManager.default.removeItem(at: tmp)
        slides.append(s11)
    }
}
