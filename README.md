# Suite42 — PDF42 · DOC42 · XLS42 · IMG42

A small native office suite for macOS: four apps that look and work alike, share one menu system and design
(the Kit42 library), need no internet and no third-party libraries — only AppKit, PDFKit, Core Image, Vision and
Security from macOS. Interface in English, Russian and Turkish.

| App | For | Opens | Saves |
|---|---|---|---|
| **PDF42** | reading, editing, signing PDFs | PDF, images | PDF (also signed, compressed, password-protected), DOCX, RTF, HTML, TXT, PNG/JPEG |
| **DOC42** | documents | DOCX, DOC, RTF, ODT, Markdown, TXT, HTML | the same + PDF |
| **XLS42** | spreadsheets | XLSX, XLS (97–2003), ODS, CSV/TSV | XLSX, ODS, CSV, PDF |
| **IMG42** | viewing and quick editing of images | JPEG, PNG, HEIC, AVIF, WebP, GIF, TIFF, PSD, RAW, SVG, PDF, … | the original format, PNG, JPEG, HEIC, TIFF, AVIF |

**По-русски.** Набор из четырёх программ для macOS: PDF42 (PDF: правка, подписи, сжатие), DOC42 (тексты Word/ODT/RTF/
Markdown), XLS42 (таблицы Excel/ODS/CSV) и IMG42 (просмотр и простая правка изображений). Работают без интернета,
интерфейс на английском, русском и турецком.

## Install

```bash
git clone https://github.com/sfzorin/kit42.git && cd kit42
./build.sh                  # all apps → build/*.app
./build.sh PDF42 install    # one app, plus a copy in /Applications
```

Requires macOS 14+ and the Xcode Command Line Tools (Swift 5.9+). To make an app the default one for a file type:
Finder › Get Info › Open with › Change All.

## PDF42 — PDF

- Reading: thumbnails and contents, zoom, display modes, search, go to page, forms, password-protected files.
- Pages: add blank pages, delete, rotate, reorder, insert from other PDFs, extract, export as PNG.
- Markup (⇧⌘A): highlight, underline, strikethrough, pencil, shapes, whiteout, text boxes, notes;
  move and resize, change colour, undo.
- Text editing: the Edit Text tool (Edit menu, markup bar, or ⌘E with nothing selected) — click a line of page text
  (⌥-click: one word), edit it in place, Return applies, Esc cancels. The original glyphs are covered with white and the
  new text is drawn on the same baseline in the original font (when installed; otherwise Helvetica/Times) and size.
  Double-click to re-edit, undo works; on save the edit is flattened into the page content. A multi-line selection + ⌘E
  places an editable text box instead. On save the replaced text is truly removed from the file (see Redaction).
- Redaction: the Redact tool (Markup menu / markup bar) marks boxes (black, or any colour picked); they can be moved,
  resized, deleted. Markup › Apply Redactions… (after a warning) or saving removes everything under the boxes, under
  edited text and under Whiteout boxes from the file: glyphs are cut out of the text operators (Tj/TJ/'/", all text state
  operators, Form XObjects, Type0/CID 2-byte and embedded-CMap fonts, simple TrueType/Type1 fonts with /Widths or the
  standard 14 metrics, Type3) and replaced by equal TJ offsets, so the rest of the line does not move; image pixels
  under a box are overwritten and the image re-encoded (raw samples in their colour space, JPEG/JPEG 2000 re-encoded);
  notes, text boxes, markup, links and form fields mostly under a box are dropped; /ActualText of marked content and
  the page thumbnail go too; the file is rewritten without the old objects. Vector graphics stay (under the box).
  Pages that cannot be rewritten safely (vertical text, unknown CMaps, inline images under a box…) become a 300 dpi
  picture with an OCR text layer, and the app says so. CLI: `--redact in out x,y,w,h[@page] … [white]` prints what
  was removed (so does `--edit-text`).
- Forms: fill existing AcroForm fields with the Select tool (values are saved). Form menu / markup bar: drag to add a
  text field, checkbox or dropdown list with a name (and options); with a form tool, fields can be moved, resized and
  deleted. Saved as real widgets with an /AcroForm entry and checkbox on/off appearances, fillable in Acrobat and Preview.
- Merge Files… (⌥⌘M): PDFs and images in a chosen order → a new document. Split… (File): every N pages,
  by ranges ("1-3, 4-10") or one file per page, into a chosen folder.
- Page › Watermark…: text (font size, colour, opacity, rotation — diagonal by default) or an image, on all pages or a range.
  Page › Page Numbers…: position, format ("1", "Page 1 of N", "- 1 -"), start number, skip first page, font size, range.
  Both stay editable (undo, Remove Watermarks and Page Numbers) until saved, then become page content.
- File › Compare With…: word-level text differences per page in a list (click to jump); removed/replaced words are
  highlighted in the document. The highlights are not saved unless "Keep highlights when saving" is ticked.
- Command line (headless): `--watermark in out TEXT [pages]`, `--number-pages in out [format] [position] [skip-first]`,
  `--split in dir 1-2,3|every:N|each`, `--merge out a.pdf b.png …`, `--compare a b [marked.pdf]`,
  `--edit-text in out OLD NEW`, `--redact in out x,y,w,h[@page] …`, `--add-field in out`, `--fill in out name=value …`, `--fields file`.
- Signatures and stamps (⇧⌘K): a library of PNGs/scans, the white background is removed automatically.
- Digital signature (⌥⌘D): standard PDF signature (PKCS#7/CMS, adbe.pkcs7.detached, SHA-256), readable by Acrobat.
  Certificate from the macOS Keychain, .p12 import or a self-signed one. Counter-signing is supported
  (incremental update). Visible signature (select a placed signature image first, or bottom right of the page)
  and RFC 3161 trusted timestamp (default TSA: DigiCert). Verification (⌥⌘V) and a status banner on open.
- Thumbnails: drag to reorder pages, multi-select, drop PDFs/images to insert.
- OCR (⌥⌘T): Vision (ru/en/tr) adds an invisible searchable text layer to scans. Print selected pages.
- Reduce File Size (File menu): pictures are downsampled (100 / 150 / 220 dpi) and re-encoded as JPEG, text and vector
  graphics stay untouched; the resulting size of every level is shown before choosing (a 17 MB scan → 2–8 MB). Save a
  compressed copy or compress the open document; a file is never made bigger. CLI: `--compress in out [smallest|balanced|high]`.
- Export: Word (.docx), RTF, HTML, text, PNG/JPEG pages (72–300 dpi), copy with a password.
- Import: open PNG/JPEG/HEIC/TIFF as PDF, "New PDF from Images…", insert images as pages.
- UI checks: `PDF42 file.pdf` with `K42_SNAPSHOT=out.png` (+ `K42_SNAPSHOT_SHEET=1`), `K42_APPEARANCE=dark|light`,
  `K42_MARKUP`, `K42_TOOL=n`, `K42_REDACT="x,y,w,h;…"`, `K42_COMPRESS`, `K42_STAMPS`, `K42_COMPARE=other.pdf`,
  `K42_ACTION=watermarkAction|pageNumbersAction|splitAction|signDocumentAction|applyRedactionsAction|mergeList|textField|…`
  (opens that dialog for the snapshot).

## XLS42 — spreadsheets (.xlsx, .xls, .ods, .csv)

- Opens .xlsx, legacy .xls (Excel 97–2003, formulas decompiled), .ods (LibreOffice/OpenOffice) and CSV/TSV
  (UTF-8/UTF-16/Windows-1251, delimiter detection); saves .xlsx, .ods and CSV. The format is detected by content.
- Displayed like Excel: column widths and row heights, fonts, fills, borders, merged cells, wrapped text,
  overflow into neighbouring cells, `###` for numbers that don't fit, theme colours.
- Number formats: thousands separators, decimals, currency, %, dates and times, `[Red]`, sections `;`.
- 139 functions (Help › Supported Functions, Insert › Function…): SUM/SUMIF(S)/COUNTIF(S), IF/IFS/IFERROR, VLOOKUP/XLOOKUP/INDEX/MATCH,
  text, dates, statistics, PMT… Russian names (СУММ, ЕСЛИ, ВПР) are accepted too. References A1/$A$1, ranges,
  other sheets, whole columns; recalculation with cycle detection.
- Editing: formula bar, cell references picked with the mouse, copy and paste with formula shifting, fill down/right,
  insert/delete rows and columns with formulas adjusted, sorting, sheets, AutoSum, selection totals.
- Freeze panes: at the selected cell, top row or first column — frozen rows/columns stay while scrolling (saved to .xlsx).
- Export to PDF: current sheet, all sheets or the selection; automatic orientation, fit to width, gridlines;
  pages break at row/column boundaries. Printing uses the same layout. CSV export (delimiter choice, UTF-8), CSV/TSV import as a sheet.
- Context menu on cells; formatting bar with font, size, colours, alignment, number formats, borders.
- Fill handle (series of numbers/dates, "Item 1 → Item 2", formulas), find and replace, hide/unhide rows and columns,
  AutoFilter with value checklist, defined names, comments, conditional formatting (value rules, text, duplicates,
  colour scales, data bars), pictures and charts (column, bar, line, area, pie, scatter) — all saved to .xlsx.
- Printing: print area, frozen rows repeated on every page, page numbers, options in the print dialog.
- Insert › Function… (also the `fx` button by the formula bar, ⇧⌘F): searchable list of all 139 functions grouped by
  category, with signature, description (en/ru/tr), argument fields and a live result; while typing a formula the
  signature of the current function is shown above the grid.
- Data › Validation…: list (values or a range like `=$H$1:$H$5`, drop-down arrow in the cell, ⌥↓), whole number,
  decimal, date, time, text length, custom formula; stop/warning/information messages. Saved to .xlsx and .ods.
- Data › Pivot Table…: row field, optional column field, value field with Sum/Count/Average/Min/Max on a new sheet
  with totals; Refresh Pivot Table re-runs it (settings are kept while the document is open, not saved in the file).
- Data › Group / Ungroup (⌥⇧⌘→/←, up to 7 levels): +/− and level buttons in a gutter beside the headers;
  outline levels and collapsed groups are saved to .xlsx, .ods and read from .xls.
- Data › Protect Sheet… with optional password; Format › Protection › Locked per cell. Locked cells refuse edits
  while the sheet is protected. .xlsx keeps the legacy password hash (and verifies Excel's SHA-512 hashes), .ods uses
  SHA-256 or LibreOffice's Excel-hash key.
- Find and Replace panel (⌥⌘F): Find Next / Replace / Replace All in the sheet or workbook, in formulas or values,
  match case, entire cell; Replace All is one undo step. Edit › Paste Special… (⌥⌘V): all/values/formulas/formats,
  add/subtract/multiply/divide, skip blanks, transpose.
- Tests: `build/XLS42.app/Contents/MacOS/XLS42 --selftest` (formulas, formats) and `--uitest` (editing operations in a window).

## DOC42 — documents (.docx, .doc, .rtf, .odt, .md, .txt)

- Page on a grey desk, styles (title, headings, quote), font, size, colour, highlighting, alignment,
  lists, indents, line spacing, tables, images, signatures and stamps from the shared library, PDF export, word count.
- Word styles (Heading 1, Title, docDefaults, theme fonts) and lists are resolved on open, so documents
  look as intended. Saving .docx uses our own writer, which keeps tables and images.
- Opens and saves .docx, .rtf, .odt, .md, .txt (and .doc, HTML) keeping pictures, tables, lists (bulleted, numbered,
  lettered), headings, page size, margins, header, footer and page numbers. Markdown: GitHub tables, nested lists,
  code, links, strikethrough, pictures by relative path. Text: UTF-8/UTF-16/Windows-1251 detected and saved back as found.
- Export: PDF (paginated A4/Letter), Word .docx/.doc, RTF, ODT, HTML, Markdown, text.
- Real pages on screen (text flows across sheets), paper size, orientation, margins, header/footer, page numbers —
  printed and exported exactly as shown. Table rows/columns insert/delete. Pictures and Word styles survive .docx round trips.
- Footnotes (⌥⌘N): numbered automatically, shown at the bottom of their page, click to edit; read from and saved to .docx
  (footnotes.xml; endnotes are read as footnotes), Markdown `[^1]`, a "Notes" list in RTF/ODT/HTML/text.
- Comments (⌥⌘M): highlighted text with cards in the margin (author, date, edit, resolve, delete); .docx comments.xml
  with resolved state (commentsExtended.xml), read and written.
- Sections: Insert › Section Break (Next Page); each section has its own paper, orientation, margins and columns
  (Document Setup applies to the cursor's section or the whole document). Columns 1–3 with spacing. Mixed page sizes
  export to PDF page by page. Saved to .docx as sectPr / w:cols and read back (continuous breaks open a new page).
- Table of contents from Title/Heading 1–3 with dot leaders, page numbers and links to the headings; Update rebuilds it
  in place. Saved as a Word TOC field with bookmarks and hyperlinks.
- Find bar across all pages with replace; Find and Replace dialog (⌥⌘F): match case, whole words, regular expressions,
  Replace / Replace All (undoable).
- Links (⌘K: insert, edit, remove; saved in docx/odt/rtf/md/html), special characters, Paragraph dialog (indents, spacing,
  exact line height), Clone Formatting (⌥⌘C; double-click keeps it on), Statistics (document and selection).

## IMG42 — images (everything ImageIO reads, plus SVG and PDF)

- Formats: whatever ImageIO decodes on this Mac (asked at runtime) — JPEG, PNG, HEIC/HEIF, AVIF, WebP, GIF, TIFF, BMP,
  ICO/ICNS, PSD, TGA, JPEG 2000, OpenEXR, JPEG XL, camera RAW (CR2/CR3/NEF/ARW/DNG/RAF/ORF…), plus SVG and PDF (pages).
  EXIF orientation is applied. Animated GIF/APNG/WebP/HEICS play; multi-page TIFF and PDF page with ⌥← / ⌥→.
  A broken file shows a message in the window, and navigation carries on.
- Flipping through: opening a file shows its whole folder in Finder name order; several files or a folder make the set.
  → / ← (also Space / ⇧Space, Page Up/Down, a mouse wheel notch or a two-finger swipe when the image fits), ⌘↑ / ⌘↓ first/last;
  position "12 / 87" in the subtitle; View › Loop Through Folder; Sort By name, date modified, date taken, size.
- Viewing: fit (⌥⌘0), actual size (⌘0), ⌘+ / ⌘−, pinch, ⌘-scroll, double-click toggles fit / 100 %, drag to pan,
  checkerboard behind transparency, background Neutral/Dark/Black/Light, full screen (⌃⌘F or F; black, every bar hidden,
  the toolbar slides in at the top), slideshow (⇧⌘F, 3 s, Space pauses, Esc stops).
- Panels (View menu, each with a check mark; state remembered): Markup Toolbar ⇧⌘A, Filmstrip ⌥⌘F (lazy cached
  thumbnails, click to jump), Info Panel ⌘I (file, dimensions, format, colour profile, camera, lens, exposure, ISO,
  GPS with Show in Maps, all EXIF/IPTC/TIFF fields), Adjust Colour ⌥⌘C, Hide All Panels ⇧⌘\.
- Toolbar like Preview's: Previous/Next · Zoom − 1:1 + · Highlight ▾ (colour) · Remove Background, Rotate · Markup ·
  Adjust · Info · Share · Search (Live Text: words are recognised with Vision and highlighted, Return goes to the next
  match; Edit › Copy Text in Image ⇧⌘C).
- Markup bar like Preview's: Select; Selection ▾ (rectangular, elliptical, lasso, aspect ratios; Crop to Selection ⌘K,
  Delete Selection ⌫, Copy, Invert ⇧⌘I); Instant Alpha (drag on a colour: farther = wider range, then ⌫); Sketch
  (a rough line, box, circle or star becomes a clean shape); Draw; Shapes ▾ (line, arrow, rectangle, rounded rectangle,
  oval, speech bubble, star, polygon, loupe, spotlight, pixelate); Text; Sign (shared signature library ⇧⌘K);
  Adjust Colour; Adjust Size; Shape Style ▾ (width, dashed, arrowheads, shadow, loupe zoom); Border and Fill colour;
  Text Style ▾ (font, size, colour, bold/italic/underline, alignment); Image Description (alt text, saved in the metadata).
  Marks stay objects — select, move, resize with handles, restyle, ⌫ deletes — until the image is saved.
- Adjust panel (Core Image, live, non-destructive): exposure, brightness, contrast, highlights, shadows, saturation,
  vibrance, temperature, tint, sharpness, vignette; looks (Black & White, Noir, Sepia, Invert); Auto Enhance; double-click
  a slider resets it; hold Show Original to compare; Reset All. One undo step per slider drag.
- Image: Rotate ⌘L / ⌘R and Flip — untouched JPEG/HEIC/PNG/TIFF files get a new orientation tag (no re-encoding, undoable);
  otherwise it becomes an edit. Adjust Size ⌥⌘R (pixels, %, cm, inches, resolution, keep proportions), Remove Background
  (Vision subject lifting), Image Description.
- Files: Save ⌘S writes markup + adjustments in the original format (JPEG quality 0.92, EXIF/GPS kept, orientation reset),
  asking once before replacing; Save As ⇧⌘S and Export ⇧⌘E (PNG, JPEG with quality, HEIC, TIFF, AVIF; size presets).
  Leaving an edited image asks Save / Don't Save / Cancel. Move to Trash ⌘⌫ (undo puts it back), Copy ⌘C (image or
  selection), Show in Finder ⇧⌘R, Open With, Share, Print (fit to page), Open Recent.
- Command line (headless): `--info files…`, `--edit in out [--brightness N --contrast N … --look sepia --auto --demo-marks
  --rotate right --flip h --resize WxH --crop x,y,w,h --remove-background --description TEXT]`, `--stats file`
  (mean luminance), `--ocr file`, `--rotate file left|right` (lossless), `--types`.
- UI checks: `K42_SNAPSHOT=out.png` plus `K42_NEXT=n`, `K42_PAGE=n`, `K42_INFO`, `K42_FILMSTRIP`, `K42_ADJUST`, `K42_MARKUP`,
  `K42_DEMO_MARKS`, `K42_TOOL=n`, `K42_SELECT=rect|ellipse|alpha` (+ `K42_CROP`, `K42_DELETE`), `K42_SEARCH=text`,
  `K42_ZOOM=x`, `K42_STAMPS`, `K42_RESIZE`, `K42_DESCRIPTION`, `K42_FULLSCREEN`, `K42_HIDE_ALL`, `K42_SAVE`, `K42_UNDO`,
  `K42_DUMP_MENUS` (prints the markup drop-downs).

## Common

- Interface language (English, Russian, Turkish) is chosen on the welcome screen and shared by all apps; system panels
  (Print, Save, toolbar items) follow it too.
- Any panel can be hidden: View › Hide All Panels (⇧⌘\\) leaves only the document; View › Show Toolbar (⌥⌘T),
  Show Toolbar Labels (icons only makes the toolbar half as tall) and each app's own bars. In full screen (⌃⌘F) the
  bars slide in only when the pointer reaches the top edge.
- Autosave every 30 s to a backup location: documents survive a crash.
- `scripts/check_strings.py` — finds UI strings without a Russian/Turkish translation.
- Distribution to other Macs: `DEVELOPER_ID="Developer ID Application: …" ./scripts/sign_and_notarize.sh`
  (needs an Apple Developer account; see the script header).

## Not implemented

- GOST signatures (needs CryptoPro CSP), track changes in DOC42, saving to legacy .xls, Excel 5.0/95 files.

## Structure

- `Sources/Kit42` — shared: commands, menu bar, toolbar, tool strip, banners, welcome window, localisation,
  signature library, certificates, ZIP.
- `Sources/PDF42`, `Sources/XLS42`, `Sources/DOC42`, `Sources/IMG42` — the apps. Each has `Commands.swift` (all commands, menus, toolbar)
  and `Strings.swift` (translations).
- `DESIGN.md` — the design system: menu order, reserved shortcuts, window layout, how to add an app.

## License

MIT — see [LICENSE](LICENSE).
