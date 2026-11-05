import AppKit
import Kit42

/// `IMG42 --uitest`: real controls/controllers, temporary images, no external UI automation.
@MainActor enum UITest {
    static func wait(_ condition: () -> Bool, seconds: Double = 5) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline { try? await Task.sleep(nanoseconds: 20_000_000) }
        return condition()
    }

    static func capture(_ window: NSWindow, _ name: String) {
        guard let directory = ProcessInfo.processInfo.environment["K42_UI_TEST_DIR"],
              let frame = window.contentView?.superview,
              let bitmap = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else { return }
        frame.cacheDisplay(in: frame.bounds, to: bitmap)
        let folder = URL(fileURLWithPath: directory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent(name + ".png"))
    }

    static func run() async {
        setlinebuf(stdout)
        var failed = 0
        func check(_ name: String, _ ok: Bool) {
            print("\(ok ? "PASS" : "FAIL") \(name)")
            if !ok { failed += 1 }
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("IMG42-uitest-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let size = CGSize(width: 1001, height: 601)
            guard let image = ImageLoader.render(size: size, { ctx in
                ctx.setFillColor(.white); ctx.fill(CGRect(origin: .zero, size: size))
            }) else { throw CocoaError(.fileWriteUnknown) }
            let url = folder.appendingPathComponent("image.png")
            try ImageWriter.write(image, to: url, type: "public.png")
            let w = ImageWindowController(urls: [url], start: url)
            w.showWindow(nil)
            check("image loads into window", await wait { w.base != nil })
            guard let window = w.window else { throw CocoaError(.fileReadUnknown) }
            let openItem = NSMenuItem(title: "", action: #selector(NSDocumentController.openDocument(_:)), keyEquivalent: "")
            check("File Open remains enabled", NSDocumentController.shared.validateUserInterfaceItem(openItem))
            check("recent files menu", DebugSnapshot.auditRecentMenu())

            print("STEP resize: construct dialog")
            let resize = ResizeDialog(size: size, dpi: 300)
            print("STEP resize: present sheet")
            resize.alert.beginSheetModal(for: window) { _ in }
            print("STEP resize: controls ready")
            guard let grid = resize.alert.accessoryView as? NSGridView,
                  let units = grid.cell(atColumnIndex: 2, rowIndex: 0).contentView as? NSPopUpButton,
                  let width = grid.cell(atColumnIndex: 1, rowIndex: 0).contentView as? NSTextField,
                  let resolution = grid.cell(atColumnIndex: 1, rowIndex: 2).contentView as? NSTextField else {
                throw CocoaError(.coderInvalidValue)
            }
            for unit in [ResizeDialog.Unit.percent, .cm, .inches, .pixels] {
                print("STEP resize: select \(unit)")
                units.selectItem(at: unit.rawValue)
                if let action = units.action { _ = NSApp.sendAction(action, to: units.target, from: units) }
                check("resize units preserve exact pixels: \(unit)", resize.pixelSize == size)
            }
            capture(resize.alert.window, "img-resize-units")
            func change(_ field: NSTextField, _ value: String) {
                field.stringValue = value
                resize.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
            }
            for invalid in ["1e99", "0", "not a number"] {
                change(width, invalid)
                check("invalid resize disables OK: \(invalid)", resize.alert.buttons.first?.isEnabled == false)
            }
            capture(resize.alert.window, "img-resize-invalid")
            change(width, "1001")
            change(resolution, "0")
            check("invalid resolution disables OK", resize.alert.buttons.first?.isEnabled == false)
            change(resolution, "300")
            check("valid resize re-enables OK", resize.alert.buttons.first?.isEnabled == true)
            let tiny = ResizeDialog(size: CGSize(width: 1, height: 1), dpi: 300)
            if let tinyGrid = tiny.alert.accessoryView as? NSGridView,
               let tinyUnits = tinyGrid.cell(atColumnIndex: 2, rowIndex: 0).contentView as? NSPopUpButton {
                tinyUnits.selectItem(at: ResizeDialog.Unit.inches.rawValue)
                if let action = tinyUnits.action { _ = NSApp.sendAction(action, to: tinyUnits.target, from: tinyUnits) }
                check("rounded physical units keep a valid one-pixel size", tiny.pixelSize == CGSize(width: 1, height: 1)
                    && tiny.alert.buttons.first?.isEnabled == true)
            } else { check("tiny resize controls exist", false) }
            window.endSheet(resize.alert.window, returnCode: .cancel)
            _ = await wait { window.attachedSheet == nil }

            // Exercise Adjust Size's real sheet callback, including its non-resampling branch.
            let oldDPI = w.imageDPI
            let originalPixels = w.base
            w.resizeAction(nil)
            _ = await wait { window.attachedSheet != nil }
            func descendants<T: NSView>(_ view: NSView, _ type: T.Type) -> [T] {
                ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { descendants($0, type) }
            }
            if let sheet = window.attachedSheet, let content = sheet.contentView,
               let grid = descendants(content, NSGridView.self).first,
               let resample = grid.cell(atColumnIndex: 1, rowIndex: 4).contentView as? NSButton,
               let dpiField = grid.cell(atColumnIndex: 1, rowIndex: 2).contentView as? NSTextField {
                resample.state = .off
                if let action = resample.action { _ = NSApp.sendAction(action, to: resample.target, from: resample) }
                dpiField.stringValue = "144"
                dpiField.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: dpiField))
                descendants(content, NSButton.self).first { $0.title == L("OK") }?.performClick(nil)
            } else { check("resolution controls exist in live sheet", false) }
            _ = await wait { window.attachedSheet == nil }
            check("no-resample resolution edit preserves bitmap", w.base === originalPixels && w.imageDPI == 144 && w.isDirty)
            w.undo.undo()
            check("resolution edit is undoable", w.imageDPI == oldDPI)
            w.undo.redo()
            check("resolution edit is redoable", w.imageDPI == 144)
            var resolutionSaved = false
            w.save(confirmed: true) { resolutionSaved = $0 }
            let storedDPI = ImageLoader.properties(url)[kCGImagePropertyDPIWidth] as? Double ?? 0
            check("resolution edit survives save and reload", resolutionSaved && abs(storedDPI - 144) < 0.05
                && w.base?.width == 1001 && w.base?.height == 601 && !w.isDirty)
            let copy = folder.appendingPathComponent("metadata-copy.png")
            try ImageWriter.write(w.base ?? image, to: copy, type: "public.png", metadataFrom: url)
            check("pixel export preserves source resolution", abs((ImageLoader.properties(copy)[kCGImagePropertyDPIWidth] as? Double ?? 0) - 144) < 0.05)

            func beginText(_ text: String, y: CGFloat = 90) -> Bool {
                w.markupBar.show(true)
                w.markupBar.setTool(.text)
                let markup = w.canvas.markup
                let point = markup.convert(CGPoint(x: 80, y: y), to: nil)
                guard let event = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { return false }
                markup.mouseDown(with: event)
                guard let field = markup.subviews.compactMap({ $0 as? NSTextField }).first else { return false }
                field.stringValue = text
                field.currentEditor()?.string = text
                markup.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
                return markup.isEditingText
            }
            check("text editor starts with uncommitted text", beginText("Saved pending text") && w.canvas.markup.marks.isEmpty && w.isDirty)
            capture(window, "img-pending-text")
            var saved = false
            w.save(confirmed: true) { saved = $0 }
            let pixels = ImageLoader.render(size: size) { $0.draw(w.base ?? image, in: CGRect(origin: .zero, size: size)) }
            let bytes = pixels?.dataProvider?.data.map { [UInt8]($0 as Data) } ?? []
            let hasInk = stride(from: 0, to: max(0, bytes.count - 3), by: 4).contains { bytes[$0] < 200 }
            check("Save commits pending text to pixels", saved && hasInk && !w.isDirty && !w.canvas.markup.isEditingText)

            check("pending text starts for Revert", beginText("Discard pending text", y: 180))
            w.undo.removeAllActions()
            w.undo.beginUndoGrouping()
            w.revertDocumentToSaved(nil)
            w.undo.endUndoGrouping()
            check("Revert clears pending editor and text", !w.isDirty && !w.canvas.markup.isEditingText && w.canvas.markup.marks.isEmpty)
            w.undo.undo()
            check("Undo Revert restores pending text", w.canvas.markup.marks.contains { $0.text == "Discard pending text" })
            w.revertDocumentToSaved(nil)

            check("pending text starts for Export", beginText("Export pending text", y: 250))
            w.runExportPanel(saveAs: false)
            check("Export commits pending text before rendering", !w.canvas.markup.isEditingText && w.canvas.markup.marks.contains { $0.text == "Export pending text" })
            if await wait({ window.attachedSheet != nil }), let sheet = window.attachedSheet {
                window.endSheet(sheet, returnCode: .cancel)
                _ = await wait { window.attachedSheet == nil }
            }
            w.revertDocumentToSaved(nil)
            window.close()
        } catch {
            print("FAIL IMG42 UI fixture: \(error)")
            failed += 1
        }
        try? FileManager.default.removeItem(at: folder)
        print("IMG42 UI: \(failed) failures")
        exit(failed == 0 ? 0 : 1)
    }
}
