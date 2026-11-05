import AppKit
import Kit42

extension DeckWindowController {
    /// Native inspector controls, with model, rendered-pixel and saved-file checks.
    func auditInspector() -> Bool {
        guard let doc, let window else { print("FAIL PPT inspector: no document window"); return false }
        commitEditing(); doc.endSilentEdit()
        let original = deck, originalState = EditState(slide: current, selection: selection), originalMode = mode
        let originalUndo = doc.undoManager
        let undo = UndoManager(); undo.groupsByEvent = false; doc.undoManager = undo
        var checks = 0, failures = 0
        func check(_ ok: Bool, _ name: String) { checks += 1; if !ok { failures += 1 }; print(ok ? "PASS" : "FAIL", "PPT inspector:", name) }
        func action(_ block: () -> Void) { undo.beginUndoGrouping(); block(); undo.endUndoGrouping() }
        func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
        func controls(_ selector: String) -> [NSControl] { views(inspector.view).compactMap { $0 as? NSControl }.filter { $0.action == NSSelectorFromString(selector) } }
        func send(_ control: NSControl) { action { _ = control.sendAction(control.action, to: control.target) } }
        func reset(_ objects: [SlideObject]) {
            action { commitEditing(); doc.endSilentEdit() }
            var d = Deck.makeDefault(); d.slides = [Slide(layout: 0)]; d.slides[0].objects = objects; d.slides[0].background = .solid(.white)
            let old = deck; doc.replaceDeck(d); current = 0; slideSelection = [0]; selection = []
            doc.onChange?(old); setMode(.normal); selection = objects.map(\.id); inspector.select(tab: 1)
            undo.removeAllActions()
        }
        defer {
            action { commitEditing(); doc.endSilentEdit() }
            let old = deck; doc.replaceDeck(original); doc.undoManager = originalUndo; doc.onChange?(old)
            setMode(originalMode); doc.restoreState?(originalState)
        }
        func shape(_ id: Int, x: CGFloat = 100) -> SlideObject {
            var o = SlideObject(id: id, kind: .shape, frame: CGRect(x: x, y: 100, width: 100, height: 60))
            o.fill = .solid(.white); o.line.color = .black; return o
        }
        func pixel(_ x: Int, _ y: Int) -> NSColor? {
            guard let cg = Renderer.image(displayedSlide, deck: deck, pixelWidth: Int(deck.size.width)), cg.colorSpace?.name == CGColorSpace.sRGB else { return nil }
            let bitmap = NSBitmapImageRep(cgImage: cg)
            guard bitmap.bitsPerSample == 8, bitmap.samplesPerPixel == 4, !bitmap.isPlanar else { return nil }
            var components = [Int](repeating: 0, count: bitmap.samplesPerPixel)
            bitmap.getPixel(&components, atX: x, y: y)
            let first = bitmap.bitmapFormat.contains(.alphaFirst) ? 1 : 0
            return NSColor(srgbRed: CGFloat(components[first]) / 255, green: CGFloat(components[first + 1]) / 255, blue: CGFloat(components[first + 2]) / 255, alpha: 1)
        }
        func red(_ colour: NSColor?) -> Bool { guard let colour else { return false }; return colour.redComponent > 0.85 && colour.greenComponent < 0.15 && colour.blueComponent < 0.15 }
        func blue(_ colour: NSColor?) -> Bool { guard let colour else { return false }; return colour.blueComponent > 0.85 && colour.redComponent < 0.15 && colour.greenComponent < 0.15 }
        reset([shape(2)])
        showInspector(true, tab: 0)
        let transition = controls("transitionChanged").compactMap { $0 as? NSPopUpButton }.first!
        check(transition.isEnabled, "transition control enabled in normal view")
        setMode(.master); check(!transition.isEnabled, "transition control disabled in master view")
        setMode(.normal); check(transition.isEnabled, "returning from master re-enables transitions")
        selection = [2]; inspector.select(tab: 1)
        let geometry = controls("geometryChanged").compactMap { $0 as? NSTextField }
        check(geometry.count == 5, "native position and size fields exist")
        if geometry.count == 5 {
            let before = displayedSlide.objects[0].frame
            geometry[2].stringValue = "nan"; _ = geometry[2].sendAction(geometry[2].action, to: geometry[2].target)
            check(displayedSlide.objects[0].frame == before && !undo.canUndo, "NaN size is rejected without changing geometry or Undo")
            geometry[0].stringValue = "1e300"; _ = geometry[0].sendAction(geometry[0].action, to: geometry[0].target)
            check(displayedSlide.objects[0].frame == before && !undo.canUndo, "unrepresentable position is rejected")
            geometry[2].stringValue = "5"; send(geometry[2])
            check(abs(displayedSlide.objects[0].frame.width - 5 * pointsPerCm) < 0.01, "typed width in centimetres resizes the object")
            undo.undo(); check(displayedSlide.objects[0].frame == before, "inspector size Undo restores the frame")
            undo.redo(); check(abs(displayedSlide.objects[0].frame.width - 5 * pointsPerCm) < 0.01, "inspector size Redo restores the width")
        }
        let fills = controls("fillChanged")
        let fillKind = fills.compactMap { $0 as? NSPopUpButton }.first!
        let fillColour = fills.compactMap { $0 as? ColorButton }.first!
        let lineControls = controls("lineChanged")
        let lineColour = lineControls.compactMap { $0 as? ColorButton }.first!
        let lineWidth = lineControls.compactMap { $0 as? NSTextField }.first!
        let dash = lineControls.compactMap { $0 as? NSPopUpButton }.first!
        reset([shape(2)])
        fillKind.selectItem(at: 1); fillColour.color = .red; send(fillColour)
        check(red(pixel(150, 130)), "fill colour changes the rendered shape")
        undo.undo(); check(!red(pixel(150, 130)), "fill Undo changes rendered pixels back")
        undo.redo(); check(red(pixel(150, 130)), "fill Redo restores rendered colour")
        lineColour.color = .blue; lineWidth.stringValue = "6"; send(lineColour)
        if !blue(pixel(100, 125)) {
            print("border diagnostic", displayedSlide.objects[0].line, "colour", pixel(100, 125) as Any, "mirror", pixel(100, Int(deck.size.height) - 125) as Any)
            if let dir = ProcessInfo.processInfo.environment["K42_UI_TEST_DIR"], let cg = Renderer.image(displayedSlide, deck: deck, pixelWidth: Int(deck.size.width)) {
                try? NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent("ppt-inspector-border.png"))
            }
        }
        check(displayedSlide.objects[0].line.width == 6 && blue(pixel(100, 125)), "line width and colour change the visible border")
        undo.undo(); check(displayedSlide.objects[0].line.width != 6, "border Undo restores previous width")
        undo.redo(); check(displayedSlide.objects[0].line.width == 6, "border Redo restores width")
        lineColour.color = nil; send(lineColour)
        check(displayedSlide.objects[0].line.color == nil && !blue(pixel(100, 125)), "No line removes the rendered border")
        var group = SlideObject(id: 5, kind: .group, frame: CGRect(x: 100, y: 100, width: 250, height: 60))
        group.children = [shape(2), shape(3, x: 250)]
        reset([group]); fillKind.selectItem(at: 1); fillColour.color = .red; send(fillColour)
        check(red(pixel(150, 130)) && red(pixel(300, 130)), "group fill reaches both rendered children")
        check(fillKind.indexOfSelectedItem == 1 && red(fillColour.color), "group inspector reflects the applied fill")
        lineColour.color = .blue; lineWidth.stringValue = "6"; send(lineColour)
        check(blue(pixel(100, 125)) && blue(pixel(250, 125)), "group border reaches both rendered children")
        check(lineWidth.doubleValue == 6 && blue(lineColour.color), "group inspector reflects the applied border")
        lineColour.color = .red; send(lineColour)
        check(displayedSlide.objects[0].children.allSatisfy { $0.line.width == 6 }, "changing group colour keeps the displayed border width")
        var table = SlideObject(id: 8, kind: .table, frame: CGRect(x: 100, y: 100, width: 240, height: 80))
        table.table = TableModel(rows: 2, columns: 2, width: 240, rowHeight: 40)
        reset([table]); check(fillKind.indexOfSelectedItem == 1, "table inspector displays inherited header fill")
        check(!dash.isEnabled, "table disables unsupported dashed-border control")
        lineColour.color = .blue; lineWidth.stringValue = "6"; send(lineColour)
        check(displayedSlide.objects[0].table?.borderWidth == 6 && blue(pixel(100, 125)) && blue(pixel(220, 125)), "table border controls change outer and inner rendered lines")
        undo.undo(); check(displayedSlide.objects[0].table?.borderWidth == 1, "table border Undo restores table style")
        undo.redo(); check(displayedSlide.objects[0].table?.borderWidth == 6, "table border Redo restores table style")
        fillKind.selectItem(at: 1); fillColour.color = .red; send(fillColour)
        check(red(pixel(140, 120)) && red(pixel(270, 160)), "table fill colours cells in every row")
        for ext in ["pptx", "odp"] {
            do {
                let roundtrip = try DeckIO.read(DeckIO.write(deck, ext: ext), ext: ext)
                let restored = roundtrip.slides[0].objects[0].table
                check(restored?.borderWidth == 6 && blue(restored?.borderColor?.resolved(roundtrip.theme)), ext + " roundtrip keeps table border width and colour")
                check(restored?.cells[0][0].fill == displayedSlide.objects[0].table?.cells[0][0].fill, ext + " roundtrip keeps table fill")
            } catch { check(false, ext + " inspector formatting roundtrip: " + error.localizedDescription) }
        }
        fillKind.selectItem(at: 0); send(fillKind)
        check(displayedSlide.objects[0].table?.cells.allSatisfy { $0.allSatisfy { $0.fill == Fill.none } } == true, "table No Fill stores an explicit transparent fill")
        check(!red(pixel(140, 120)) && (pixel(140, 120)?.greenComponent ?? 0) > 0.9, "table No Fill clears the rendered background")
        for ext in ["pptx", "odp"] {
            do {
                let restored = try DeckIO.read(DeckIO.write(deck, ext: ext), ext: ext)
                check(restored.slides[0].objects[0].table?.cells[0][0].fill == Fill.none, ext + " roundtrip preserves explicit table No Fill")
            } catch { check(false, ext + " No Fill roundtrip") }
        }
        reset([shape(2)])
        var rounded = shape(90); rounded.geometry = "roundRect"
        rounded.placeholder = Placeholder(type: "body", idx: 0)
        rounded.text = TextBody(paragraphs: [Paragraph("Master fixture")])
        action { doc.change("Master inspector fixture") { d in
            d.master.placeholders = [rounded]; d.layouts[0].placeholders = [rounded]
        } }
        let shadow = controls("shadowChanged").compactMap { $0 as? NSButton }.first!
        let opacity = controls("opacityChanged").compactMap { $0 as? NSSlider }.first!
        let corner = controls("cornerChanged").compactMap { $0 as? NSSlider }.first!
        for layout in [nil, 0] as [Int?] {
            setMode(.master); selectMaster(layout); selection = [90]; inspector.select(tab: 1)
            let label = layout == nil ? "master" : "layout"
            func edited() -> SlideObject { layout.map { deck.layouts[$0].placeholders[0] } ?? deck.master.placeholders[0] }
            action { shadow.performClick(nil) }
            check(edited().shadow && shadow.state == .on, label + " Shadow control changes the model and remains checked")
            opacity.doubleValue = 55; send(opacity)
            check(abs(edited().opacity - 0.55) < 0.001, label + " Opacity control persists its value")
            corner.doubleValue = 28; send(corner)
            check(edited().adjust["adj"] == 28000, label + " Corner Radius control persists its value")
            undo.undo(); check(edited().adjust["adj"] != 28000, label + " corner change is undoable")
            undo.redo(); check(edited().adjust["adj"] == 28000, label + " corner change supports Redo")
        }
        do {
            let restored = try DeckIO.read(DeckIO.write(deck, ext: "pptx"), ext: "pptx")
            func alpha(_ object: SlideObject) -> CGFloat {
                if case .solid(let colour) = object.fill { return object.opacity * colour.alpha }
                return object.opacity
            }
            check(restored.master.placeholders[0].shadow && abs(alpha(restored.master.placeholders[0]) - 0.55) < 0.001 && restored.master.placeholders[0].adjust["adj"] == 28000, "PPTX preserves master shadow, opacity and rounding")
            check(restored.layouts[0].placeholders[0].shadow && abs(alpha(restored.layouts[0].placeholders[0]) - 0.55) < 0.001 && restored.layouts[0].placeholders[0].adjust["adj"] == 28000, "PPTX preserves layout shadow, opacity and rounding")
        } catch { check(false, "PPTX master appearance roundtrip") }
        var textShape = shape(12); textShape.text = TextBody(paragraphs: [Paragraph("before")])
        reset([textShape]); window.makeKeyAndOrderFront(nil)
        action { canvas.editor.begin(displayedSlide.objects[0], at: nil, selectAll: true); canvas.editor.textView.insertText("visible draft", replacementRange: canvas.editor.textView.selectedRange()) }
        lineColour.color = .blue; lineWidth.stringValue = "4"; send(lineColour)
        check(displayedSlide.objects[0].text?.plainText == "visible draft" && displayedSlide.objects[0].line.width == 4, "changing inspector border commits visible text first")
        undo.undo(); check(displayedSlide.objects[0].text?.plainText == "before" && displayedSlide.objects[0].line.width != 4, "Undo restores the complete state before the combined draft and border action")
        undo.redo(); check(displayedSlide.objects[0].text?.plainText == "visible draft" && displayedSlide.objects[0].line.width == 4, "Redo restores committed draft and border together")
        print("PPT inspector UI regressions: \(checks - failures)/\(checks) passed")
        return failures == 0
    }
}
