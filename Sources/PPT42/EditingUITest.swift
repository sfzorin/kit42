import AppKit
import Kit42

extension DeckWindowController {
    /// Native edit commands and pointer/key events; the harness supplies a private pasteboard.
    func auditEditing() -> Bool {
        guard let doc, let window, ProcessInfo.processInfo.environment["K42_PASTEBOARD"] != nil else {
            print("FAIL PPT editing: a document window and private audit pasteboard are required"); return false
        }
        commitEditing(); doc.endSilentEdit()
        let originalDeck = deck, originalCurrent = current, originalSelection = selection
        let originalUndo = doc.undoManager, originalZoom = canvas.zoom, originalSnap = snapToGuides
        let savedObjects = Clipboard.objects, savedSlides = Clipboard.slides
        let undo = UndoManager(); undo.groupsByEvent = false; doc.undoManager = undo
        var checks = 0, failures = 0
        func check(_ value: Bool, _ name: String) {
            checks += 1; if !value { failures += 1 }
            print("\(value ? "PASS" : "FAIL") PPT editing: \(name)")
        }
        func action(_ body: () -> Void) { undo.beginUndoGrouping(); body(); undo.endUndoGrouping() }
        func reset(_ objects: [SlideObject] = [], media: [String: Data] = [:], slides: [Slide]? = nil) {
            action { commitEditing(); doc.endSilentEdit() }
            var d = Deck.makeDefault(); d.slides = slides ?? [Slide(layout: 0)]
            if slides == nil { d.slides[0].objects = objects }
            d.slides[0].background = .solid(.white); d.media = media
            let before = deck; doc.replaceDeck(d); current = 0; selection = []; slideSelection = [0]
            doc.onChange?(before); canvas.zoom = 1; snapToGuides = false
            window.makeFirstResponder(canvas); undo.removeAllActions()
        }
        defer {
            action { commitEditing(); doc.endSilentEdit() }
            let tested = deck; doc.replaceDeck(originalDeck); doc.undoManager = originalUndo
            doc.onChange?(tested); select(slide: originalCurrent); selection = originalSelection
            canvas.zoom = originalZoom; snapToGuides = originalSnap
            Clipboard.objects = savedObjects; Clipboard.slides = savedSlides
        }
        func shape(_ id: Int, _ x: CGFloat, _ y: CGFloat, _ width: CGFloat = 100, _ height: CGFloat = 60) -> SlideObject {
            var o = SlideObject(id: id, kind: .shape, frame: CGRect(x: x, y: y, width: width, height: height))
            o.fill = .solid(PColor(rgb: 0xFF0000)); return o
        }
        func object(_ id: Int) -> SlideObject? { displayedSlide.object(id) }
        func key(_ text: String, flags: NSEvent.ModifierFlags = []) {
            guard let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                           windowNumber: window.windowNumber, context: nil, characters: text,
                                           charactersIgnoringModifiers: text, isARepeat: false, keyCode: 0) else { return }
            canvas.keyDown(with: e)
        }
        func mouse(_ type: NSEvent.EventType, _ point: CGPoint, flags: NSEvent.ModifierFlags = []) {
            let location = canvas.convert(canvas.toView(point), to: nil)
            guard let e = NSEvent.mouseEvent(with: type, location: location, modifierFlags: flags, timestamp: 0,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { return }
            if type == .leftMouseDown { canvas.mouseDown(with: e) }
            else if type == .leftMouseDragged { canvas.mouseDragged(with: e) }
            else { canvas.mouseUp(with: e) }
        }
        func drag(_ start: CGPoint, _ end: CGPoint, flags: NSEvent.ModifierFlags = []) {
            mouse(.leftMouseDown, start, flags: flags); mouse(.leftMouseDragged, end, flags: flags); mouse(.leftMouseUp, end, flags: flags)
        }
        var rendered = 0
        func image(_ slide: Slide? = nil) -> NSBitmapImageRep? {
            guard let cg = Renderer.image(slide ?? displayedSlide, deck: deck, pixelWidth: Int(deck.size.width)),
                  cg.colorSpace?.name == CGColorSpace.sRGB, cg.bitsPerComponent == 8 else { return nil }
            let bitmap = NSBitmapImageRep(cgImage: cg)
            if let dir = ProcessInfo.processInfo.environment["K42_UI_TEST_DIR"], let png = bitmap.representation(using: .png, properties: [:]) {
                rendered += 1; try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("ppt-editing-render-\(rendered).png"))
            }
            return bitmap
        }
        func colour(_ bitmap: NSBitmapImageRep?, x: Int, y: Int) -> NSColor? {
            guard let bitmap, bitmap.bitsPerSample == 8, bitmap.samplesPerPixel == 4, !bitmap.isPlanar,
                  x >= 0, y >= 0, x < bitmap.pixelsWide, y < bitmap.pixelsHigh else { return nil }
            // The source CGContext is explicitly sRGB. Avoid AppKit assigning a device profile during colourAt conversion.
            var components = [UInt](repeating: 0, count: 4)
            bitmap.getPixel(&components, atX: x, y: y)
            let first = bitmap.bitmapFormat.contains(.alphaFirst) ? 1 : 0
            return NSColor(srgbRed: CGFloat(components[first]) / 255, green: CGFloat(components[first + 1]) / 255,
                           blue: CGFloat(components[first + 2]) / 255, alpha: 1)
        }
        func isRed(_ c: NSColor?) -> Bool { (c?.redComponent ?? 0) > 0.9 && (c?.greenComponent ?? 1) < 0.1 && (c?.blueComponent ?? 1) < 0.1 }

        reset([shape(2, 100, 100), shape(3, 300, 100), shape(4, 500, 100)])
        key("\t", flags: .shift); check(selection == [4], "Shift-Tab without a selection starts at the last object")
        key("\t"); check(selection == [2], "Tab wraps from the last object")
        selection = [4]
        mouse(.leftMouseDown, CGPoint(x: 20, y: 20), flags: .shift)
        mouse(.leftMouseDragged, CGPoint(x: 250, y: 180), flags: .shift)
        key("\u{1B}"); mouse(.leftMouseUp, CGPoint(x: 250, y: 180))
        check(selection == [4], "Escape cancels rubber-band selection and restores its starting selection")
        selection = [2, 3]
        action { drag(CGPoint(x: 150, y: 130), CGPoint(x: 180, y: 155)) }
        check(object(2)?.frame.origin == CGPoint(x: 130, y: 125) && object(3)?.frame.origin == CGPoint(x: 330, y: 125), "native drag moves every selected object")
        check(object(4)?.frame.origin == CGPoint(x: 500, y: 100), "native drag leaves unselected objects unchanged")
        undo.undo(); check(object(2)?.frame.origin == CGPoint(x: 100, y: 100) && object(3)?.frame.origin == CGPoint(x: 300, y: 100), "drag is one Undo")
        undo.redo(); check(object(2)?.frame.origin == CGPoint(x: 130, y: 125), "drag Redo restores geometry")
        selection = [2]
        action { mouse(.leftMouseDown, CGPoint(x: 180, y: 155)); mouse(.leftMouseDragged, CGPoint(x: 230, y: 155)); key("\u{1B}"); mouse(.leftMouseUp, CGPoint(x: 230, y: 155)) }
        check(object(2)?.frame.origin == CGPoint(x: 130, y: 125) && canvas.slide.object(2)?.frame == object(2)?.frame, "Escape cancels the live drag before mouse-up")
        action { key(String(UnicodeScalar(NSRightArrowFunctionKey)!), flags: .shift) }
        check(object(2)?.frame.minX == 140, "Shift-arrow nudges by ten slide points")
        undo.undo(); check(object(2)?.frame.minX == 130, "keyboard nudge Undo restores geometry")

        reset([shape(2, 100, 100)])
        selection = [2]
        action { drag(CGPoint(x: 200, y: 160), CGPoint(x: 250, y: 190)) }
        check(object(2)?.frame == CGRect(x: 100, y: 100, width: 150, height: 90), "native corner handle resizes from the opposite anchor")
        undo.undo(); check(object(2)?.frame == CGRect(x: 100, y: 100, width: 100, height: 60), "resize Undo restores the frame")
        undo.redo(); check(object(2)?.frame.size == CGSize(width: 150, height: 90), "resize Redo restores the frame")
        reset([shape(2, 100, 100)])
        selection = [2]
        action { drag(CGPoint(x: 150, y: 78), CGPoint(x: 230, y: 130), flags: .shift) }
        check(abs((object(2)?.rotation ?? -1) - 90) < 0.001, "native rotation handle snaps to fifteen degrees with Shift")
        undo.undo(); check(object(2)?.rotation == 0, "rotation Undo restores the angle")

        reset([shape(2, 100, 100), shape(3, 200, 100), shape(4, 300, 100), shape(5, 400, 100)])
        selection = [2, 3]
        action { arrangeAction(NSMenuItem.tagged(1)) }
        check(displayedSlide.objects.map(\.id) == [4, 2, 3, 5], "Bring Forward preserves relative order of selected objects")
        undo.undo(); check(displayedSlide.objects.map(\.id) == [2, 3, 4, 5], "arrange Undo restores stack order")
        action { arrangeAction(NSMenuItem.tagged(0)) }
        check(displayedSlide.objects.map(\.id) == [4, 5, 2, 3], "Bring to Front preserves relative order")
        action { arrangeAction(NSMenuItem.tagged(3)) }
        check(displayedSlide.objects.map(\.id) == [2, 3, 4, 5], "Send to Back preserves relative order")
        selection = [2, 4, 5]
        action { alignObjectsAction(NSMenuItem.tagged(4)) }
        check(selectedObjects.allSatisfy { $0.frame.midY == 130 }, "Align Middle aligns all selected objects")
        action { distributeAction(NSMenuItem.tagged(0)) }
        check(object(4)?.frame.minX == 250, "Distribute Horizontal uses equal gaps")
        undo.undo(); check(object(4)?.frame.minX == 300, "distribution Undo restores positions")
        selection = [2, 3]
        action { groupAction(nil) }
        let groupID = selection.first!
        check(object(groupID)?.children.map(\.id) == [2, 3] && displayedSlide.objects.count == 3, "Group keeps child identities and stack order")
        action { ungroupAction(nil) }
        check(displayedSlide.objects.map(\.id) == [2, 3, 4, 5], "Ungroup restores objects at the group's stack position")
        undo.undo(); check(object(groupID)?.kind == .group && selection == [groupID], "Ungroup Undo restores group and selection")
        undo.redo(); check(object(2) != nil && object(groupID) == nil, "Ungroup Redo restores children")

        var group = SlideObject(id: 10, kind: .group, frame: CGRect(x: 100, y: 100, width: 200, height: 160))
        group.children = [shape(11, 120, 120, 40, 30)]; group.flipH = true
        reset([group]); selection = [10]
        let mirrored = image()
        check(isRed(colour(mirrored, x: 260, y: 135)) && !isRed(colour(mirrored, x: 140, y: 135)), "rendered group horizontal flip mirrors its child pixels")
        action { ungroupAction(nil) }
        check(object(11)?.frame == CGRect(x: 240, y: 120, width: 40, height: 30) && object(11)?.flipH == true, "Ungroup retains the reflected child geometry")
        check(isRed(colour(image(), x: 260, y: 135)), "Ungroup preserves the rendered reflected appearance")
        group.rotation = 90; group.flipV = true; group.children[0].rotation = 30
        reset([group]); selection = [10]
        action { ungroupAction(nil) }
        check(object(11)?.rotation == 120 && object(11)?.flipH == true && object(11)?.flipV == true, "Ungroup composes rotation with two reflections")

        // BMPs have identical headers/lengths and differ only after byte 64, reproducing the former cache collision.
        func bitmap(_ pixel: UInt8) -> Data {
            var bytes = [UInt8](repeating: 0, count: 102)
            func u16(_ offset: Int, _ value: UInt16) { bytes[offset] = UInt8(value & 255); bytes[offset + 1] = UInt8(value >> 8) }
            func u32(_ offset: Int, _ value: UInt32) { for i in 0..<4 { bytes[offset + i] = UInt8((value >> (i * 8)) & 255) } }
            bytes[0] = 66; bytes[1] = 77; u32(2, 102); u32(10, 54); u32(14, 40); u32(18, 4); u32(22, 4); u16(26, 1); u16(28, 24); u32(34, 48)
            for i in 54..<102 { bytes[i] = 255 }
            for i in 78..<102 { bytes[i] = pixel }
            return Data(bytes)
        }
        let white = bitmap(255), black = bitmap(0)
        check(white.count == black.count && white.prefix(64) == black.prefix(64) && white != black, "media collision fixture differs beyond the old cache fingerprint")
        let cachedWhite = MediaCache.image("editing-cache.bmp", white), cachedBlack = MediaCache.image("editing-cache.bmp", black)
        check(cachedWhite != nil && cachedBlack != nil && cachedWhite !== cachedBlack, "media cache invalidates when equal-size equal-header bytes differ")
        var picture = SlideObject(id: 2, kind: .picture, frame: CGRect(x: 100, y: 100, width: 120, height: 80))
        picture.media = "image1.bmp"; picture.clip = MediaClip(media: "video1.mp4")
        let movie = Data([1, 2, 3, 4, 5])
        reset([picture], media: ["image1.bmp": white, "video1.mp4": movie]); selection = [2]
        copyObjects(cut: false)
        check(Clipboard.objects?.media["video1.mp4"] == movie, "object copy includes embedded video data")
        reset([picture], media: ["image1.bmp": black, "video1.mp4": Data([8, 9])])
        let beforePaste = deck
        action { pasteObjects() }
        let pasted = selectedObjects.first
        check(pasted?.media != "image1.bmp" && pasted?.media.flatMap { deck.media[$0] } == white && deck.media["image1.bmp"] == black, "cross-document paste remaps colliding picture names")
        check(pasted?.clip?.media != "video1.mp4" && (pasted?.clip?.media).flatMap { deck.media[$0] } == movie, "cross-document paste remaps colliding embedded clips")
        check(pasted?.frame.origin == CGPoint(x: 118, y: 118), "paste offsets an object occupying the same position")
        undo.undo(); check(deck == beforePaste && deck.media == beforePaste.media, "Paste Undo removes inserted objects and media together")
        undo.redo()
        check(displayedSlide.objects.count == 2 && selectedObjects.first?.media.flatMap { deck.media[$0] } == white, "Paste Redo restores objects and media together")

        reset([picture], media: ["image1.bmp": white, "video1.mp4": movie]); copySlides()
        reset([picture], media: ["image1.bmp": black, "video1.mp4": Data([8, 9])])
        action { pasteObjects() }
        check(deck.slides.count == 2 && deck.slides[1].objects[0].media.flatMap { deck.media[$0] } == white && (deck.slides[1].objects[0].clip?.media).flatMap { deck.media[$0] } == movie, "slide paste remaps image and clip bytes without corrupting the destination")
        undo.undo(); check(deck.slides.count == 1 && deck.media["image1.bmp"] == black, "slide paste Undo restores destination deck")

        var text = SlideObject(id: 2, kind: .textBox, frame: CGRect(x: 100, y: 100, width: 240, height: 80))
        text.text = TextBody(paragraphs: [Paragraph("old")])
        reset([text]); selection = [2]; canvas.editor.begin(text, at: nil, selectAll: true)
        canvas.editor.textView.insertText("edited before duplicate", replacementRange: NSRange(location: 0, length: 3))
        action { duplicateAction(nil) }
        check(displayedSlide.objects.count == 2 && displayedSlide.objects.allSatisfy { $0.text?.plainText == "edited before duplicate" } && !canvas.editor.isActive, "Duplicate commits the pending text before making a copy")
        check(Set(displayedSlide.objects.flatMap(\.allIDs)).count == 2, "Duplicate gives every copied object a unique identity")
        undo.undo(); check(displayedSlide.objects.count == 1 && object(2)?.text?.plainText == "old", "Duplicate with a pending draft is one native undo group")
        undo.redo(); check(displayedSlide.objects.count == 2 && displayedSlide.objects.allSatisfy { $0.text?.plainText == "edited before duplicate" }, "Duplicate Redo restores current text and copy")

        let slideA = Slide(layout: 0), slideB = Slide(layout: 0), slideC = Slide(layout: 0)
        reset(slides: [slideA, slideB, slideC])
        action { moveSlides([0, 0, -1, 999], to: 3) }
        check(deck.slides.map(\.uid) == [slideB.uid, slideC.uid, slideA.uid] && current == 2, "Move Slides filters duplicate/stale indexes and selects the moved slide")
        undo.undo(); check(deck.slides.map(\.uid) == [slideA.uid, slideB.uid, slideC.uid], "Move Slides Undo restores original order")
        slideSelection = [0, 2]
        action { duplicateSlideAction(nil) }
        check(deck.slides.count == 5 && Set(deck.slides.map(\.uid)).count == 5 && slideSelection == IndexSet(3..<5), "Duplicate Slides creates unique slides and selects every new copy")
        undo.undo(); check(deck.slides.count == 3, "Duplicate Slides is one Undo")
        print("PPT editing UI regressions: \(checks - failures)/\(checks) passed")
        return failures == 0
    }
}
