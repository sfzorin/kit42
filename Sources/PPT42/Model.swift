import AppKit

// Presentation model. Value types throughout: a whole Deck is the undo snapshot.
// Geometry is in points (1 pt = 12 700 EMU), origin at the slide's top-left corner, y down.

let emuPerPoint: CGFloat = 12700
let pointsPerCm: CGFloat = 72 / 2.54

// MARK: - Colour

/// A colour as authored: an RGB value or a theme slot (accent1, tx1…) with modifiers (lumMod, alpha…).
struct PColor: Equatable, Hashable {
    var scheme: String?
    var rgb: UInt32
    /// OOXML colour transforms in their 1/1000 % units, applied in order: lumMod, lumOff, tint, shade, satMod, alpha.
    var mods: [Mod] = []

    struct Mod: Equatable, Hashable {
        var name: String
        var val: Int
    }

    init(rgb: UInt32, alpha: CGFloat = 1) {
        self.rgb = rgb
        if alpha < 1 { mods = [Mod(name: "alpha", val: Int(alpha * 100000))] }
    }

    init(scheme: String, mods: [Mod] = []) {
        self.scheme = scheme
        self.rgb = 0
        self.mods = mods
    }

    static let black = PColor(rgb: 0x000000)
    static let white = PColor(rgb: 0xFFFFFF)

    init(_ color: NSColor) {
        let c = color.usingColorSpace(.sRGB) ?? NSColor.black
        rgb = UInt32(round(c.redComponent * 255)) << 16 | UInt32(round(c.greenComponent * 255)) << 8 | UInt32(round(c.blueComponent * 255))
        if c.alphaComponent < 0.999 { mods = [Mod(name: "alpha", val: Int(c.alphaComponent * 100000))] }
    }

    var alpha: CGFloat {
        mods.last { $0.name == "alpha" }.map { CGFloat($0.val) / 100000 } ?? 1
    }

    func withAlpha(_ a: CGFloat) -> PColor {
        var c = self
        c.mods.removeAll { $0.name == "alpha" }
        if a < 0.999 { c.mods.append(Mod(name: "alpha", val: Int(a * 100000))) }
        return c
    }

    /// Concrete colour with the deck's theme.
    func resolved(_ theme: Theme) -> NSColor {
        let base = scheme.map { theme.color($0) } ?? rgb
        var r = CGFloat(base >> 16 & 0xFF) / 255, g = CGFloat(base >> 8 & 0xFF) / 255, b = CGFloat(base & 0xFF) / 255
        var a: CGFloat = 1
        for m in mods {
            let v = CGFloat(m.val) / 100000
            switch m.name {
            case "lumMod", "lumOff":
                var (h, s, l) = rgbToHSL(r, g, b)
                if m.name == "lumMod" { l *= v } else { l += v }
                l = min(1, max(0, l))
                (r, g, b) = hslToRGB(h, s, l)
                _ = h; _ = s
            case "satMod":
                var (h, s, l) = rgbToHSL(r, g, b)
                s = min(1, max(0, s * v))
                (r, g, b) = hslToRGB(h, s, l)
                _ = h; _ = l
            case "tint", "shade":
                // In linear light, as Office does.
                func lin(_ c: CGFloat) -> CGFloat { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
                func srgb(_ c: CGFloat) -> CGFloat { c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1 / 2.4) - 0.055 }
                func f(_ c: CGFloat) -> CGFloat { srgb(m.name == "tint" ? lin(c) * v + (1 - v) : lin(c) * v) }
                r = f(r); g = f(g); b = f(b)
            case "alpha":
                a = v
            default: break
            }
        }
        return NSColor(srgbRed: r, green: g, blue: b, alpha: a)
    }

    /// RGB value after the theme and modifiers (for formats without theme colours).
    func flattened(_ theme: Theme) -> PColor { PColor(resolved(theme)) }

    var hex: String { String(format: "%06X", rgb) }
}

func rgbToHSL(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> (CGFloat, CGFloat, CGFloat) {
    let mx = max(r, g, b), mn = min(r, g, b)
    let l = (mx + mn) / 2
    guard mx != mn else { return (0, 0, l) }
    let d = mx - mn
    let s = l > 0.5 ? d / (2 - mx - mn) : d / (mx + mn)
    var h: CGFloat
    if mx == r { h = (g - b) / d + (g < b ? 6 : 0) } else if mx == g { h = (b - r) / d + 2 } else { h = (r - g) / d + 4 }
    h /= 6
    return (h, s, l)
}

func hslToRGB(_ h: CGFloat, _ s: CGFloat, _ l: CGFloat) -> (CGFloat, CGFloat, CGFloat) {
    guard s > 0 else { return (l, l, l) }
    func hue(_ p: CGFloat, _ q: CGFloat, _ t0: CGFloat) -> CGFloat {
        var t = t0
        if t < 0 { t += 1 }
        if t > 1 { t -= 1 }
        if t < 1 / 6 { return p + (q - p) * 6 * t }
        if t < 1 / 2 { return q }
        if t < 2 / 3 { return p + (q - p) * (2 / 3 - t) * 6 }
        return p
    }
    let q = l < 0.5 ? l * (1 + s) : l + s - l * s
    let p = 2 * l - q
    return (hue(p, q, h + 1 / 3), hue(p, q, h), hue(p, q, h - 1 / 3))
}

// MARK: - Theme

struct Theme: Equatable {
    var name: String
    /// dk1, lt1, dk2, lt2, accent1…6, hlink, folHlink
    var colors: [String: UInt32]
    var majorFont: String
    var minorFont: String

    static let slots = ["dk1", "lt1", "dk2", "lt2", "accent1", "accent2", "accent3", "accent4", "accent5", "accent6", "hlink", "folHlink"]

    func color(_ name: String) -> UInt32 {
        switch name {
        case "tx1": return colors["dk1"] ?? 0
        case "bg1": return colors["lt1"] ?? 0xFFFFFF
        case "tx2": return colors["dk2"] ?? 0x44546A
        case "bg2": return colors["lt2"] ?? 0xE7E6E6
        case "phClr": return colors["accent1"] ?? 0x4472C4
        default: return colors[name] ?? 0
        }
    }

    /// "+mj-lt" / "+mn-lt" → the theme font.
    func font(_ name: String?) -> String? {
        guard let name else { return nil }
        if name.hasPrefix("+mj") { return majorFont }
        if name.hasPrefix("+mn") { return minorFont }
        return name
    }
}

// MARK: - Fill, line, shadow

struct GradientStop: Equatable {
    var position: CGFloat   // 0…1
    var color: PColor
}

struct Gradient: Equatable {
    var stops: [GradientStop]
    /// Degrees, clockwise from left→right (OOXML a:lin ang).
    var angle: CGFloat = 90
    var radial = false
}

enum Fill: Equatable {
    case none
    case solid(PColor)
    case gradient(Gradient)
    /// Media name in Deck.media.
    case picture(String)

    var isNone: Bool { if case .none = self { return true }; return false }

    var solidColor: PColor? {
        switch self {
        case .solid(let c): return c
        case .gradient(let g): return g.stops.first?.color
        default: return nil
        }
    }
}

enum Dash: String, CaseIterable {
    case solid, dash, dot, dashDot, lgDash

    var pattern: [CGFloat] {
        switch self {
        case .solid: return []
        case .dash: return [4, 3]
        case .dot: return [1, 2]
        case .dashDot: return [4, 2, 1, 2]
        case .lgDash: return [8, 3]
        }
    }
}

enum Arrowhead: String, CaseIterable {
    case none, triangle, arrow, stealth, oval, diamond
}

struct LineStyle: Equatable {
    var color: PColor?
    var width: CGFloat = 1
    var dash: Dash = .solid
    var head: Arrowhead = .none
    var tail: Arrowhead = .none

    static let none = LineStyle(color: nil)
}

// MARK: - Text

enum TextAlign: String, CaseIterable {
    case left = "l", center = "ctr", right = "r", justify = "just"

    var ns: NSTextAlignment {
        switch self {
        case .left: return .left
        case .center: return .center
        case .right: return .right
        case .justify: return .justified
        }
    }
}

enum Anchor: String {
    case top = "t", middle = "ctr", bottom = "b"
}

struct Bullet: Equatable {
    enum Kind: Equatable { case none, char, number }
    var kind: Kind
    var char = "•"
    /// OOXML a:buAutoNum type: arabicPeriod, arabicParenR, alphaLcPeriod, alphaUcPeriod, romanUcPeriod, romanLcPeriod.
    var scheme = "arabicPeriod"
    var startAt = 1
    var font: String?
    var color: PColor?
    var sizePercent: CGFloat?

    static let none = Bullet(kind: .none)
    static let disc = Bullet(kind: .char, char: "•")
    static let numbered = Bullet(kind: .number)

    func marker(_ n: Int) -> String {
        switch kind {
        case .none: return ""
        case .char: return char
        case .number:
            let v = startAt + n
            var s: String
            if scheme.hasPrefix("alphaLc") { s = Self.alpha(v).lowercased() }
            else if scheme.hasPrefix("alphaUc") { s = Self.alpha(v) }
            else if scheme.hasPrefix("romanUc") { s = Self.roman(v) }
            else if scheme.hasPrefix("romanLc") { s = Self.roman(v).lowercased() }
            else { s = "\(v)" }
            if scheme.hasSuffix("ParenR") { return s + ")" }
            if scheme.hasSuffix("ParenBoth") { return "(" + s + ")" }
            if scheme.hasSuffix("Plain") { return s }
            return s + "."
        }
    }

    static func alpha(_ n: Int) -> String {
        var n = max(1, n), s = ""
        while n > 0 { n -= 1; s = String(UnicodeScalar(65 + n % 26)!) + s; n /= 26 }
        return s
    }

    static func roman(_ n: Int) -> String {
        let table: [(Int, String)] = [(1000, "M"), (900, "CM"), (500, "D"), (400, "CD"), (100, "C"), (90, "XC"), (50, "L"), (40, "XL"), (10, "X"), (9, "IX"), (5, "V"), (4, "IV"), (1, "I")]
        var n = max(1, n), s = ""
        for (v, r) in table { while n >= v { s += r; n -= v } }
        return s
    }
}

/// Character formatting; nil = inherited.
struct RunProps: Equatable {
    var font: String?
    var size: CGFloat?
    var bold: Bool?
    var italic: Bool?
    var underline: Bool?
    var strike: Bool?
    var color: PColor?
    /// Superscript (> 0) / subscript (< 0), percent.
    var baseline: CGFloat?

    /// `self` over `base`.
    func over(_ base: RunProps) -> RunProps {
        RunProps(font: font ?? base.font, size: size ?? base.size, bold: bold ?? base.bold, italic: italic ?? base.italic,
                 underline: underline ?? base.underline, strike: strike ?? base.strike, color: color ?? base.color,
                 baseline: baseline ?? base.baseline)
    }

    var isEmpty: Bool { self == RunProps() }
}

/// Paragraph formatting of one outline level; nil = inherited.
struct LevelStyle: Equatable {
    var align: TextAlign?
    var bullet: Bullet?
    /// Left margin and first-line indent (negative = hanging), points.
    var marL: CGFloat?
    var indent: CGFloat?
    /// Line spacing as a multiple (1.0 = single).
    var lineSpacing: CGFloat?
    var spaceBefore: CGFloat?
    var spaceAfter: CGFloat?
    var run = RunProps()

    func over(_ base: LevelStyle) -> LevelStyle {
        LevelStyle(align: align ?? base.align, bullet: bullet ?? base.bullet, marL: marL ?? base.marL, indent: indent ?? base.indent,
                   lineSpacing: lineSpacing ?? base.lineSpacing, spaceBefore: spaceBefore ?? base.spaceBefore,
                   spaceAfter: spaceAfter ?? base.spaceAfter, run: run.over(base.run))
    }

    var isEmpty: Bool { self == LevelStyle() }
}

/// Nine outline levels (missing ones are empty).
struct ListStyle: Equatable {
    var levels: [LevelStyle] = Array(repeating: LevelStyle(), count: 9)

    subscript(_ i: Int) -> LevelStyle {
        get { levels[min(max(i, 0), 8)] }
        set { levels[min(max(i, 0), 8)] = newValue }
    }

    func over(_ base: ListStyle) -> ListStyle {
        var out = ListStyle()
        for i in 0..<9 { out.levels[i] = levels[i].over(base.levels[i]) }
        return out
    }

    var isEmpty: Bool { levels.allSatisfy(\.isEmpty) }
}

struct TextRun: Equatable {
    var text: String
    var props = RunProps()
    /// "slidenum", "datetime" (text is the last rendered value).
    var field: String?
    var link: String?
}

struct Paragraph: Equatable {
    var runs: [TextRun] = []
    var level = 0
    var props = LevelStyle()
    /// Formatting of the empty end of the paragraph (a:endParaRPr): used when the paragraph is empty.
    var endProps = RunProps()

    var text: String { runs.map(\.text).joined() }

    init(_ text: String = "", level: Int = 0, props: LevelStyle = LevelStyle(), run: RunProps = RunProps()) {
        runs = text.isEmpty ? [] : [TextRun(text: text, props: run)]
        self.level = level
        self.props = props
        endProps = run
    }
}

enum Autofit: Equatable {
    case none
    /// Shrink text on overflow (a:normAutofit). Scale is computed when drawing.
    case shrink
    /// Resize shape to fit text (a:spAutoFit).
    case resize
}

struct TextBody: Equatable {
    var paragraphs: [Paragraph] = [Paragraph()]
    var anchor: Anchor = .top
    var insets = NSEdgeInsets(top: 3.6, left: 7.2, bottom: 3.6, right: 7.2)
    var wrap = true
    var autofit: Autofit = .none
    var vertical = false
    /// Object-level overrides (a:lstStyle).
    var listStyle = ListStyle()

    var plainText: String { paragraphs.map(\.text).joined(separator: "\n") }
    var isEmpty: Bool { paragraphs.allSatisfy { $0.text.isEmpty } }

    static func == (a: TextBody, b: TextBody) -> Bool {
        a.paragraphs == b.paragraphs && a.anchor == b.anchor && a.wrap == b.wrap && a.autofit == b.autofit && a.vertical == b.vertical
            && a.listStyle == b.listStyle && a.insets.top == b.insets.top && a.insets.left == b.insets.left
            && a.insets.bottom == b.insets.bottom && a.insets.right == b.insets.right
    }
}

// MARK: - Tables

struct TableCell: Equatable {
    var text = TextBody(paragraphs: [Paragraph()], insets: NSEdgeInsets(top: 3.6, left: 7.2, bottom: 3.6, right: 7.2))
    var fill: Fill?
    var gridSpan = 1
    var rowSpan = 1
    /// Covered by a neighbour's span.
    var merged = false
}

struct TableModel: Equatable {
    var columns: [CGFloat]
    var rows: [CGFloat]
    var cells: [[TableCell]]
    var firstRow = true
    var bandRows = true
    /// Accent used by the built-in look (header and banded rows).
    var accent = "accent1"
    var borderColor: PColor? = PColor(rgb: 0xFFFFFF)
    var borderWidth: CGFloat = 1

    init(rows: Int, columns: Int, width: CGFloat, rowHeight: CGFloat = 28) {
        self.columns = Array(repeating: width / CGFloat(max(1, columns)), count: max(1, columns))
        self.rows = Array(repeating: rowHeight, count: max(1, rows))
        cells = (0..<max(1, rows)).map { _ in (0..<max(1, columns)).map { _ in TableCell() } }
    }

    var size: CGSize { CGSize(width: columns.reduce(0, +), height: rows.reduce(0, +)) }

    /// Cell rectangle relative to the table's top-left corner (with its spans).
    func rect(row: Int, column: Int) -> CGRect {
        let x = columns.prefix(column).reduce(0, +), y = rows.prefix(row).reduce(0, +)
        let cell = cells[row][column]
        let w = columns[column..<min(columns.count, column + max(1, cell.gridSpan))].reduce(0, +)
        let h = rows[row..<min(rows.count, row + max(1, cell.rowSpan))].reduce(0, +)
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// Default fill of a cell in the built-in banded look.
    func defaultFill(row: Int) -> Fill {
        if firstRow && row == 0 { return .solid(PColor(scheme: accent)) }
        let band = firstRow ? row - 1 : row
        if bandRows && band % 2 == 0 { return .solid(PColor(scheme: accent, mods: [.init(name: "tint", val: 40000)])) }
        return .solid(PColor(scheme: accent, mods: [.init(name: "tint", val: 20000)]))
    }

    /// Scales row heights and column widths to a new size.
    mutating func fit(to size: CGSize) {
        let s = self.size
        guard s.width > 0, s.height > 0 else { return }
        columns = columns.map { $0 * size.width / s.width }
        rows = rows.map { $0 * size.height / s.height }
    }
}

// MARK: - Objects

struct Placeholder: Equatable {
    /// title, ctrTitle, subTitle, body, obj, pic, dt, ftr, sldNum, tbl, chart…
    var type: String
    var idx: Int?

    var role: TextRole {
        switch type {
        case "title", "ctrTitle": return .title
        case "dt", "ftr", "sldNum": return .other
        default: return .body
        }
    }

    var isTitle: Bool { type == "title" || type == "ctrTitle" }
    var isFooter: Bool { type == "dt" || type == "ftr" || type == "sldNum" }
}

enum TextRole { case title, body, other }

enum ObjectKind: String {
    case shape, textBox, picture, table, group, line
}

/// Entrance animation played on click in the slide show (p:timing).
enum BuildEffect: String, CaseIterable {
    case appear, fade, flyIn, zoom
}

struct SlideObject: Equatable {
    var id: Int
    var name = ""
    var kind: ObjectKind
    var frame: CGRect
    /// Degrees, clockwise.
    var rotation: CGFloat = 0
    var flipH = false
    var flipV = false
    /// Preset geometry (OOXML prst): rect, roundRect, ellipse, triangle, rightArrow…
    var geometry = "rect"
    /// Adjust values (prst-specific, 1/100000 of the shorter side for most).
    var adjust: [String: Int] = [:]
    /// Custom outline (a:custGeom, ODF paths).
    var custom: CustomGeometry?
    var fill: Fill = .none
    var line: LineStyle = .none
    var shadow = false
    var opacity: CGFloat = 1
    var text: TextBody?
    var placeholder: Placeholder?
    /// Picture: media name and crop (fractions of each side: left, top, right, bottom).
    var media: String?
    var crop = NSEdgeInsets()
    var table: TableModel?
    var children: [SlideObject] = []
    var build: BuildEffect?
    /// Description / alt text.
    var descr = ""
    /// Shapes the reader could not represent (charts, SmartArt) are kept as a picture fallback or a box.
    var unsupported: String?

    static func == (a: SlideObject, b: SlideObject) -> Bool {
        a.id == b.id && a.name == b.name && a.kind == b.kind && a.frame == b.frame && a.rotation == b.rotation && a.flipH == b.flipH
            && a.flipV == b.flipV && a.geometry == b.geometry && a.adjust == b.adjust && a.custom == b.custom && a.fill == b.fill && a.line == b.line
            && a.shadow == b.shadow && a.opacity == b.opacity && a.text == b.text && a.placeholder == b.placeholder && a.media == b.media
            && a.crop.left == b.crop.left && a.crop.top == b.crop.top && a.crop.right == b.crop.right && a.crop.bottom == b.crop.bottom
            && a.table == b.table && a.children == b.children && a.build == b.build && a.descr == b.descr && a.unsupported == b.unsupported
    }

    init(id: Int, kind: ObjectKind, frame: CGRect) {
        self.id = id
        self.kind = kind
        self.frame = frame
    }

    var isLine: Bool { kind == .line }

    /// Line end points (from the frame and flips).
    var lineStart: CGPoint { CGPoint(x: flipH ? frame.maxX : frame.minX, y: flipV ? frame.maxY : frame.minY) }
    var lineEnd: CGPoint { CGPoint(x: flipH ? frame.minX : frame.maxX, y: flipV ? frame.minY : frame.maxY) }

    mutating func setLine(from a: CGPoint, to b: CGPoint) {
        frame = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
        flipH = b.x < a.x
        flipV = b.y < a.y
    }

    /// Moves the object (and group children).
    mutating func offset(by d: CGSize) {
        frame = frame.offsetBy(dx: d.width, dy: d.height)
        for i in children.indices { children[i].offset(by: d) }
    }

    /// Resizes to `r`; group children scale with it.
    mutating func setFrame(_ r: CGRect) {
        let old = frame
        frame = r
        if kind == .table, var t = table { t.fit(to: r.size); table = t }
        guard !children.isEmpty, old.width > 0.01, old.height > 0.01 else { return }
        let sx = r.width / old.width, sy = r.height / old.height
        for i in children.indices {
            let c = children[i].frame
            children[i].setFrame(CGRect(x: r.minX + (c.minX - old.minX) * sx, y: r.minY + (c.minY - old.minY) * sy,
                                        width: c.width * sx, height: c.height * sy))
        }
    }

    /// All ids in the object and its children.
    var allIDs: [Int] { [id] + children.flatMap(\.allIDs) }
}

// MARK: - Transitions

enum TransitionKind: String, CaseIterable {
    case none, fade, push, wipe, cover, dissolve, split, zoom
}

struct Transition: Equatable {
    var kind: TransitionKind = .none
    var duration: Double = 0.7
    /// l, r, u, d (OOXML dir): where the new slide comes from.
    var direction = "l"
    /// Advance automatically after seconds (nil = on click).
    var advanceAfter: Double?
}

// MARK: - Slide, layout, master

struct Slide: Equatable {
    var uid = UUID()
    var layout: Int
    var objects: [SlideObject] = []
    var background: Fill?
    var notes = ""
    var hidden = false
    var transition = Transition()
    var showMasterShapes = true

    var title: String {
        objects.first { $0.placeholder?.isTitle == true }?.text?.plainText ?? ""
    }

    var maxID: Int { objects.flatMap(\.allIDs).max() ?? 1 }

    func object(_ id: Int) -> SlideObject? {
        func find(_ list: [SlideObject]) -> SlideObject? {
            for o in list {
                if o.id == id { return o }
                if let c = find(o.children) { return c }
            }
            return nil
        }
        return find(objects)
    }

    /// Changes the object with `id` wherever it is (also inside groups).
    mutating func update(_ id: Int, _ body: (inout SlideObject) -> Void) {
        func visit(_ list: inout [SlideObject]) -> Bool {
            for i in list.indices {
                if list[i].id == id { body(&list[i]); return true }
                if visit(&list[i].children) { return true }
            }
            return false
        }
        _ = visit(&objects)
    }
}

struct Layout: Equatable {
    var name: String
    /// OOXML layout type: title, obj, twoObj, secHead, titleOnly, blank, picTx, …
    var type: String
    var placeholders: [SlideObject] = []
    var objects: [SlideObject] = []
    var background: Fill?
    var showMasterShapes = true

    func placeholder(_ p: Placeholder) -> SlideObject? {
        if let idx = p.idx, let m = placeholders.first(where: { $0.placeholder?.idx == idx && $0.placeholder?.type == p.type }) { return m }
        if let idx = p.idx, p.idx != 0, let m = placeholders.first(where: { $0.placeholder?.idx == idx }) { return m }
        return placeholders.first { ph in
            guard let t = ph.placeholder?.type else { return false }
            if t == p.type { return true }
            if p.isTitle, ph.placeholder?.isTitle == true { return true }
            if (p.type == "obj" || p.type == "body") && (t == "body" || t == "obj") && p.idx == ph.placeholder?.idx { return true }
            return false
        }
    }
}

struct Master: Equatable {
    var background: Fill = .solid(PColor(scheme: "bg1"))
    var titleStyle = ListStyle()
    var bodyStyle = ListStyle()
    var otherStyle = ListStyle()
    var placeholders: [SlideObject] = []
    var objects: [SlideObject] = []

    func placeholder(_ type: String) -> SlideObject? {
        let t = type == "ctrTitle" ? "title" : (type == "subTitle" || type == "obj") ? "body" : type
        return placeholders.first { $0.placeholder?.type == t }
    }

    func style(_ role: TextRole) -> ListStyle {
        switch role {
        case .title: return titleStyle
        case .body: return bodyStyle
        case .other: return otherStyle
        }
    }
}

// MARK: - Deck

struct Deck: Equatable {
    var size = CGSize(width: 960, height: 540)
    var theme = Themes.all[0].theme
    var master = Master()
    var layouts: [Layout] = []
    var slides: [Slide] = []
    var media: [String: Data] = [:]
    /// Starting number of slide numbers.
    var firstSlideNumber = 1
    var notesSize = CGSize(width: 540, height: 720)

    static func == (a: Deck, b: Deck) -> Bool {
        a.size == b.size && a.theme == b.theme && a.master == b.master && a.layouts == b.layouts && a.slides == b.slides
            && a.media.keys.sorted() == b.media.keys.sorted() && a.firstSlideNumber == b.firstSlideNumber
    }

    func layout(of slide: Slide) -> Layout? {
        layouts.indices.contains(slide.layout) ? layouts[slide.layout] : layouts.first
    }

    /// Index of the layout of a given OOXML type (title, obj, …).
    func layoutIndex(type: String) -> Int? { layouts.firstIndex { $0.type == type } }

    /// Effective paragraph style of `level` in object `o` on `slide` (master → layout → object).
    func levelStyle(for o: SlideObject, on slide: Slide?, level: Int) -> LevelStyle {
        var base: ListStyle
        if let ph = o.placeholder {
            base = master.style(ph.role)
            if let mp = master.placeholder(ph.type) { base = (mp.text?.listStyle ?? ListStyle()).over(base) }
            if let slide, let lp = layout(of: slide)?.placeholder(ph) { base = (lp.text?.listStyle ?? ListStyle()).over(base) }
        } else {
            base = master.otherStyle
        }
        let own = o.text?.listStyle ?? ListStyle()
        return own[level].over(base[level])
    }

    /// Unique media name with the extension of the data.
    mutating func addMedia(_ data: Data, ext: String) -> String {
        for (k, v) in media where v == data { return k }
        var n = media.count + 1
        while media["image\(n).\(ext)"] != nil { n += 1 }
        let name = "image\(n).\(ext)"
        media[name] = data
        return name
    }

    /// Drops media no longer used by any slide, layout, master or background.
    mutating func pruneMedia() {
        var used = Set<String>()
        func visit(_ list: [SlideObject]) {
            for o in list {
                if let m = o.media { used.insert(m) }
                if case .picture(let m) = o.fill { used.insert(m) }
                visit(o.children)
            }
        }
        func bg(_ f: Fill?) { if case .picture(let m)? = f { used.insert(m) } }
        for s in slides { visit(s.objects); bg(s.background) }
        for l in layouts { visit(l.objects); visit(l.placeholders); bg(l.background) }
        visit(master.objects); bg(master.background)
        media = media.filter { used.contains($0.key) }
    }
}

extension NSEdgeInsets: @retroactive Equatable {
    public static func == (a: NSEdgeInsets, b: NSEdgeInsets) -> Bool {
        a.top == b.top && a.left == b.left && a.bottom == b.bottom && a.right == b.right
    }
}

/// Image format extension from the data's signature.
func imageExtension(_ data: Data) -> String {
    let b = [UInt8](data.prefix(12))
    if b.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }
    if b.starts(with: [0xFF, 0xD8]) { return "jpeg" }
    if b.starts(with: [0x47, 0x49, 0x46]) { return "gif" }
    if b.starts(with: [0x42, 0x4D]) { return "bmp" }
    if b.starts(with: [0x49, 0x49]) || b.starts(with: [0x4D, 0x4D]) { return "tiff" }
    if b.count > 4, String(decoding: data.prefix(256), as: UTF8.self).contains("<svg") { return "svg" }
    return "png"
}
