import AppKit

/// Self-test of light / dark colour resolution for cells and sheet chrome.
extension SelfTest {
    static func colors() -> Int {
        var failed = 0
        func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
            print(ok ? "ok  " : "FAIL", name, ok ? "" : detail())
            if !ok { failed += 1 }
        }
        func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: 1) }
        func same(_ a: NSColor, _ b: NSColor) -> Bool {
            guard let x = a.usingColorSpace(.sRGB), let y = b.usingColorSpace(.sRGB) else { return false }
            return abs(x.redComponent - y.redComponent) < 0.01 && abs(x.greenComponent - y.greenComponent) < 0.01 && abs(x.blueComponent - y.blueComponent) < 0.01
        }
        let light = SheetPalette.light, dark = SheetPalette.darkMode
        let yellow = rgb(1, 1, 0), navy = rgb(0.13, 0.22, 0.39), blue = rgb(0.12, 0.25, 0.75), red = rgb(1, 0, 0)

        // Light mode keeps the file's colours exactly.
        check("light: default text black on white", same(light.textColor(nil, fill: nil), .black) && same(light.background, .white))
        check("light: explicit colours kept", same(light.textColor(blue, fill: nil), blue) && same(light.textColor(.black, fill: navy), .black)
              && same(light.borderColor(.black), .black))
        check("appearance resolves palette", SheetPalette.current(NSAppearance(named: .darkAqua)) == dark && SheetPalette.current(NSAppearance(named: .aqua)) == light)

        // Dark mode: cells without a fill are dark with light text.
        check("dark: background dark, default text light", SheetPalette.luminance(dark.background) < 0.05 && SheetPalette.contrast(dark.textColor(nil, fill: nil), dark.background) > 10)
        check("dark: black text on no fill becomes readable", SheetPalette.contrast(dark.textColor(.black, fill: nil), dark.background) >= 3)
        let lifted = dark.textColor(blue, fill: nil)
        check("dark: dark blue text lifted but stays blue", SheetPalette.contrast(lifted, dark.background) >= 3
              && (lifted.usingColorSpace(.sRGB)!.blueComponent > lifted.usingColorSpace(.sRGB)!.redComponent))
        check("dark: bright explicit colour kept", same(dark.textColor(red, fill: nil), red))
        // Explicit fills stay; text on them stays readable.
        check("dark: text on a light fill is black", same(dark.textColor(nil, fill: yellow), .black) && same(dark.textColor(.black, fill: yellow), .black))
        check("dark: text on a dark fill is light", SheetPalette.contrast(dark.textColor(nil, fill: navy), navy) > 4.5
              && SheetPalette.contrast(dark.textColor(.black, fill: navy), navy) > 4.5)
        check("dark: explicit white on red kept", same(dark.textColor(.white, fill: red), .white))
        check("dark: black borders visible", SheetPalette.contrast(dark.borderColor(.black), dark.background) >= 2.2 && same(dark.borderColor(red), red))
        check("dark: chrome differs from light", !same(dark.headerFill, light.headerFill) && !same(dark.grid, light.grid) && !same(dark.chartFill, light.chartFill))

        // Grid views: printing is always light, the window follows its appearance.
        let grid = GridView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        grid.appearance = NSAppearance(named: .darkAqua)
        check("grid view uses dark palette in dark appearance", grid.palette == dark)
        grid.printMode = true
        check("printing uses light palette", grid.palette == light)
        return failed
    }
}
