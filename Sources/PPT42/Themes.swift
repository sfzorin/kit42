import AppKit
import Kit42

/// Built-in colour/font themes and the standard master with its seven layouts.
enum Themes {
    struct Entry {
        let theme: Theme
        let background: Fill
    }

    static func make(_ name: String, _ c: [UInt32], major: String, minor: String) -> Theme {
        Theme(name: name, colors: Dictionary(uniqueKeysWithValues: zip(Theme.slots, c)), majorFont: major, minorFont: minor)
    }

    static let all: [Entry] = [
        Entry(theme: make("Classic", [0x1F1F1F, 0xFFFFFF, 0x2B3A55, 0xE8ECF2, 0x2F6FDB, 0xF0883E, 0x8E9AAF, 0xF2C14E, 0x3FB6C6, 0x5DAE5B, 0x2F6FDB, 0x7A4FBF],
                                  major: "Helvetica Neue", minor: "Helvetica Neue"),
              background: .solid(PColor(scheme: "bg1"))),
        Entry(theme: make("Midnight", [0xF2F4F8, 0x141B2D, 0xDCE3F0, 0x24304A, 0x4FC3F7, 0xFFB74D, 0x81C784, 0xF06292, 0xBA68C8, 0xFFF176, 0x4FC3F7, 0xBA68C8],
                                  major: "Avenir Next", minor: "Avenir Next"),
              background: .gradient(Gradient(stops: [GradientStop(position: 0, color: PColor(scheme: "bg2")),
                                                     GradientStop(position: 1, color: PColor(scheme: "bg1"))], angle: 90))),
        Entry(theme: make("Sunrise", [0x3B2A20, 0xFFF8F0, 0x8A3B12, 0xFBE3CF, 0xE5671A, 0xF2A541, 0xC0392B, 0x7D9D52, 0x4A7C9B, 0x9B59B6, 0xE5671A, 0x9B59B6],
                                  major: "Gill Sans", minor: "Gill Sans"),
              background: .solid(PColor(scheme: "bg1"))),
        Entry(theme: make("Forest", [0x1E2B22, 0xF6F8F3, 0x2E5E3E, 0xDDE8D6, 0x2E8B57, 0x8FB339, 0xD9A441, 0x4F7CAC, 0xB5563A, 0x6B8F71, 0x2E8B57, 0x6B8F71],
                                  major: "Georgia", minor: "Helvetica Neue"),
              background: .solid(PColor(scheme: "bg1"))),
        Entry(theme: make("Slate", [0xECEFF1, 0x263238, 0xCFD8DC, 0x37474F, 0xFF7043, 0x26C6DA, 0xFFCA28, 0x9CCC65, 0xAB47BC, 0x78909C, 0x26C6DA, 0xAB47BC],
                                  major: "Futura", minor: "Helvetica Neue"),
              background: .solid(PColor(scheme: "bg1"))),
        Entry(theme: make("Paper", [0x2B2B2B, 0xFBF7EE, 0x5A4632, 0xEFE6D2, 0x8C5A3C, 0x3D6B8C, 0xA67C2E, 0x6E8B3D, 0x9C3D54, 0x5E5E5E, 0x3D6B8C, 0x9C3D54],
                                  major: "Palatino", minor: "Palatino"),
              background: .solid(PColor(scheme: "bg1"))),
    ]

    static var names: [String] { all.map { L($0.theme.name) } }

    // MARK: - Master and layouts

    static func masterStyles() -> (title: ListStyle, body: ListStyle, other: ListStyle) {
        var title = ListStyle()
        title[0] = LevelStyle(align: .left, bullet: Bullet.none, lineSpacing: 0.9, spaceBefore: 0,
                              run: RunProps(font: "+mj-lt", size: 44, bold: false, italic: false, color: PColor(scheme: "tx1")))
        var body = ListStyle()
        let sizes: [CGFloat] = [28, 24, 20, 18, 18, 18, 18, 18, 18]
        for i in 0..<9 {
            body[i] = LevelStyle(align: .left, bullet: Bullet(kind: .char, char: i % 2 == 0 ? "•" : "–"), marL: 18 + CGFloat(i) * 36, indent: -18,
                                 lineSpacing: 0.9, spaceBefore: i == 0 ? 10 : 5, spaceAfter: 0,
                                 run: RunProps(font: "+mn-lt", size: sizes[i], bold: false, italic: false, color: PColor(scheme: "tx1")))
        }
        var other = ListStyle()
        for i in 0..<9 {
            other[i] = LevelStyle(align: .left, bullet: Bullet.none, marL: CGFloat(i) * 36, indent: 0, lineSpacing: 1,
                                  run: RunProps(font: "+mn-lt", size: 18, bold: false, italic: false, color: PColor(scheme: "tx1")))
        }
        return (title, body, other)
    }

    static func placeholder(_ id: Int, _ type: String, idx: Int?, _ r: CGRect, name: String, anchor: Anchor = .top,
                            style: LevelStyle? = nil, autofit: Autofit = .none) -> SlideObject {
        var o = SlideObject(id: id, kind: .textBox, frame: r)
        o.name = name
        o.placeholder = Placeholder(type: type, idx: idx)
        var t = TextBody()
        t.anchor = anchor
        t.autofit = autofit
        if let style { t.listStyle[0] = style }
        o.text = t
        return o
    }

    /// Standard master and layouts for a slide size.
    static func standard(size: CGSize) -> (Master, [Layout]) {
        let sx = size.width / 960, sy = size.height / 540
        func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect { CGRect(x: x * sx, y: y * sy, width: w * sx, height: h * sy) }
        let styles = masterStyles()
        var master = Master()
        master.titleStyle = styles.title
        master.bodyStyle = styles.body
        master.otherStyle = styles.other
        let footStyle = LevelStyle(align: .left, run: RunProps(size: 12, color: PColor(scheme: "tx1", mods: [.init(name: "tint", val: 75000)])))
        var center = footStyle; center.align = .center
        var right = footStyle; right.align = .right
        let footers = [
            placeholder(4, "dt", idx: 10, r(66, 500.5, 216, 28.75), name: "Date Placeholder", anchor: .middle, style: footStyle),
            placeholder(5, "ftr", idx: 11, r(318, 500.5, 324, 28.75), name: "Footer Placeholder", anchor: .middle, style: center),
            placeholder(6, "sldNum", idx: 12, r(678, 500.5, 216, 28.75), name: "Slide Number Placeholder", anchor: .middle, style: right),
        ]
        master.placeholders = [
            placeholder(2, "title", idx: nil, r(66, 28.75, 828, 104.4), name: "Title Placeholder", anchor: .middle, autofit: .shrink),
            placeholder(3, "body", idx: 1, r(66, 143.75, 828, 342.6), name: "Text Placeholder", autofit: .shrink),
        ] + footers

        let noBullet = LevelStyle(align: .center, bullet: Bullet.none, marL: 0, indent: 0)
        var subtitle = noBullet; subtitle.run.size = 24
        var bigTitle = LevelStyle(align: .center); bigTitle.run.size = 60
        var secTitle = LevelStyle(); secTitle.run.size = 60
        var secBody = LevelStyle(bullet: Bullet.none, marL: 0, indent: 0)
        secBody.run.size = 24
        secBody.run.color = PColor(scheme: "tx1", mods: [.init(name: "tint", val: 75000)])
        var capTitle = LevelStyle(); capTitle.run.size = 32
        var capBody = LevelStyle(bullet: Bullet.none, marL: 0, indent: 0); capBody.run.size = 16

        func layout(_ name: String, _ type: String, _ ph: [SlideObject]) -> Layout {
            Layout(name: name, type: type, placeholders: ph + footers)
        }
        let title = placeholder(2, "title", idx: nil, r(66, 28.75, 828, 104.4), name: "Title 1", anchor: .middle, autofit: .shrink)
        let layouts = [
            layout("Title Slide", "title", [
                placeholder(2, "ctrTitle", idx: nil, r(120, 88.4, 720, 188), name: "Title 1", anchor: .bottom, style: bigTitle, autofit: .shrink),
                placeholder(3, "subTitle", idx: 1, r(120, 283.6, 720, 130.4), name: "Subtitle 2", style: subtitle, autofit: .shrink),
            ]),
            layout("Title and Content", "obj", [title, placeholder(3, "body", idx: 1, r(66, 143.75, 828, 342.6), name: "Content Placeholder 2", autofit: .shrink)]),
            layout("Two Content", "twoObj", [title,
                placeholder(3, "body", idx: 1, r(66, 143.75, 408, 342.6), name: "Content Placeholder 2", autofit: .shrink),
                placeholder(4, "body", idx: 2, r(486, 143.75, 408, 342.6), name: "Content Placeholder 3", autofit: .shrink)]),
            layout("Section Header", "secHead", [
                placeholder(2, "title", idx: nil, r(65.5, 134.6, 828, 224.6), name: "Title 1", anchor: .bottom, style: secTitle, autofit: .shrink),
                placeholder(3, "body", idx: 1, r(65.5, 361.4, 828, 118.1), name: "Text Placeholder 2", style: secBody, autofit: .shrink),
            ]),
            layout("Title Only", "titleOnly", [title]),
            layout("Blank", "blank", []),
            layout("Picture with Caption", "picTx", [
                placeholder(2, "title", idx: nil, r(66.1, 36, 309.6, 126), name: "Title 1", anchor: .bottom, style: capTitle, autofit: .shrink),
                placeholder(3, "pic", idx: 1, r(408.1, 77.75, 486, 383.75), name: "Picture Placeholder 2"),
                placeholder(4, "body", idx: 2, r(66.1, 162, 309.6, 300.1), name: "Text Placeholder 3", style: capBody, autofit: .shrink),
            ]),
        ]
        return (master, layouts)
    }

    /// Layout names shown in the UI (standard ones translated).
    static func displayName(_ layout: Layout) -> String { L(layout.name) }
}

extension Deck {
    /// A new presentation: standard master, seven layouts, one title slide.
    static func makeDefault(size: CGSize = CGSize(width: 960, height: 540), theme: Int = 0) -> Deck {
        var deck = Deck()
        deck.size = size
        deck.theme = Themes.all[theme].theme
        let (master, layouts) = Themes.standard(size: size)
        deck.master = master
        deck.master.background = Themes.all[theme].background
        deck.layouts = layouts
        deck.slides = [deck.newSlide(layout: 0)]
        return deck
    }

    /// Empty slide with the placeholders of a layout.
    func newSlide(layout index: Int) -> Slide {
        var slide = Slide(layout: min(max(index, 0), max(0, layouts.count - 1)))
        guard layouts.indices.contains(slide.layout) else { return slide }
        var id = 2
        for ph in layouts[slide.layout].placeholders where ph.placeholder?.isFooter != true {
            var o = ph
            o.id = id
            id += 1
            if var t = o.text {
                t.paragraphs = [Paragraph()]
                t.listStyle = ListStyle()
                o.text = t
            }
            slide.objects.append(o)
        }
        return slide
    }

    /// Changes the slide size, scaling every object, layout and master shape.
    mutating func resize(to newSize: CGSize) {
        let sx = newSize.width / size.width, sy = newSize.height / size.height
        guard sx.isFinite, sy.isFinite, sx > 0, sy > 0 else { return }
        func scale(_ list: inout [SlideObject]) {
            for i in list.indices {
                let f = list[i].frame
                list[i].setFrame(CGRect(x: f.minX * sx, y: f.minY * sy, width: f.width * sx, height: f.height * sy))
            }
        }
        for i in slides.indices { scale(&slides[i].objects) }
        for i in layouts.indices { scale(&layouts[i].placeholders); scale(&layouts[i].objects) }
        scale(&master.placeholders)
        scale(&master.objects)
        size = newSize
    }

    /// Applies a built-in theme (colours, fonts, background) to the whole deck.
    mutating func apply(theme index: Int) {
        guard Themes.all.indices.contains(index) else { return }
        theme = Themes.all[index].theme
        master.background = Themes.all[index].background
        // Explicit theme fonts on runs would hide the change: fonts equal to the old theme fonts become inherited.
    }
}
