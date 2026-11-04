import AppKit

/// Colours of the sheet chrome and of cells without explicit colours, for light and dark appearance.
/// Explicit fills and colours from the file are kept; text and borders that would vanish against the
/// dark sheet background (black text with no fill, say) are lifted to readable values. Printing and
/// PDF export always use the light palette.
struct SheetPalette: Equatable {
    let dark: Bool

    static let light = SheetPalette(dark: false)
    static let darkMode = SheetPalette(dark: true)

    static func current(_ appearance: NSAppearance?) -> SheetPalette {
        appearance?.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .darkMode : .light
    }

    /// For a view: printing always light.
    static func `for`(_ view: NSView, print: Bool = false) -> SheetPalette { print ? .light : current(view.effectiveAppearance) }

    private static func rgb(_ v: CGFloat) -> NSColor { NSColor(srgbRed: v, green: v, blue: v, alpha: 1) }

    var background: NSColor { dark ? Self.rgb(0.118) : .white }
    var text: NSColor { dark ? Self.rgb(0.90) : .black }
    var grid: NSColor { dark ? Self.rgb(0.235) : Self.rgb(0.886) }
    var headerFill: NSColor { dark ? Self.rgb(0.17) : Self.rgb(0.965) }
    var headerLine: NSColor { dark ? Self.rgb(0.30) : Self.rgb(0.82) }
    var headerText: NSColor { dark ? Self.rgb(0.68) : Self.rgb(0.35) }
    var frozenLine: NSColor { dark ? Self.rgb(0.50) : Self.rgb(0.55) }
    var gutterFill: NSColor { dark ? Self.rgb(0.15) : Self.rgb(0.955) }
    var gutterLine: NSColor { dark ? Self.rgb(0.55) : Self.rgb(0.45) }
    var buttonFill: NSColor { dark ? Self.rgb(0.25) : .white }
    var buttonStroke: NSColor { dark ? Self.rgb(0.45) : Self.rgb(0.6) }
    var buttonGlyph: NSColor { dark ? Self.rgb(0.85) : Self.rgb(0.25) }
    var cornerGlyph: NSColor { dark ? Self.rgb(0.40) : Self.rgb(0.75) }
    var hintFill: NSColor { dark ? NSColor(srgbRed: 0.26, green: 0.24, blue: 0.15, alpha: 1) : NSColor(srgbRed: 1, green: 0.99, blue: 0.88, alpha: 1) }
    var chartFill: NSColor { dark ? Self.rgb(0.16) : .white }
    var chartFrame: NSColor { dark ? Self.rgb(0.32) : Self.rgb(0.82) }
    var chartLabel: NSColor { dark ? Self.rgb(0.70) : Self.rgb(0.35) }
    var chartTitle: NSColor { dark ? Self.rgb(0.92) : Self.rgb(0.2) }
    var chartGrid: NSColor { dark ? Self.rgb(0.26) : Self.rgb(0.9) }
    var chartAxis: NSColor { dark ? Self.rgb(0.55) : Self.rgb(0.6) }

    // MARK: - Cell colours

    /// WCAG relative luminance (0 black … 1 white).
    static func luminance(_ c: NSColor) -> CGFloat {
        guard let s = c.usingColorSpace(.sRGB) else { return 0.5 }
        func lin(_ v: CGFloat) -> CGFloat { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(s.redComponent) + 0.7152 * lin(s.greenComponent) + 0.0722 * lin(s.blueComponent)
    }

    static func contrast(_ a: NSColor, _ b: NSColor) -> CGFloat {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// Background under a cell: its fill, else the sheet background.
    func cellBackground(_ fill: NSColor?) -> NSColor { fill ?? background }

    /// Text colour of a cell: an explicit colour (style or number format) or the default; on a fill the
    /// default is black or white by the fill's lightness; in dark mode, unreadable colours on the
    /// sheet background are lightened.
    func textColor(_ explicit: NSColor?, fill: NSColor?) -> NSColor {
        if let fill {
            let auto = Self.luminance(fill) > 0.3 ? NSColor.black : Self.rgb(0.95)
            guard let explicit else { return dark ? auto : .black }
            // Dark mode only: text that would disappear into its fill (black on navy) gets black/white.
            return dark && Self.contrast(explicit, fill) < 2 ? auto : explicit
        }
        guard let explicit else { return text }
        return dark ? readable(explicit, on: background, minimum: 3) : explicit
    }

    /// Border colour on the sheet: black hairlines stay visible on the dark background.
    func borderColor(_ c: NSColor) -> NSColor { dark ? readable(c, on: background, minimum: 2.2) : c }

    /// `c` lightened just enough to reach the contrast ratio against `bg` (greys become the default text grey).
    func readable(_ c: NSColor, on bg: NSColor, minimum: CGFloat) -> NSColor {
        guard Self.contrast(c, bg) < minimum, let s = c.usingColorSpace(.sRGB) else { return c }
        let spread = max(s.redComponent, s.greenComponent, s.blueComponent) - min(s.redComponent, s.greenComponent, s.blueComponent)
        if spread < 0.12 { return minimum >= 3 ? text : Self.rgb(0.62).withAlphaComponent(s.alphaComponent) }
        var t: CGFloat = 0.1
        var out = c
        while t <= 1 {
            out = NSColor(srgbRed: s.redComponent + (1 - s.redComponent) * t, green: s.greenComponent + (1 - s.greenComponent) * t,
                          blue: s.blueComponent + (1 - s.blueComponent) * t, alpha: s.alphaComponent)
            if Self.contrast(out, bg) >= minimum { break }
            t += 0.1
        }
        return out
    }
}
