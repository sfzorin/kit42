# Suite42 — PDF42 · DOC42 · XLS42

Local macOS apps for documents, sharing one design and menu system (Kit42).
No dependencies: AppKit, PDFKit, Security; works offline. Interface in English, Russian and Turkish
(language is chosen on the welcome screen, shared by all three apps).

```bash
./build.sh                  # all apps → build/*.app
./build.sh PDF42 install    # one app, plus a copy in ~/Applications
```

Requires Xcode Command Line Tools (Swift 5.9+), macOS 14+.

## PDF42 — PDF

- Reading: thumbnails and contents, zoom, display modes, search, go to page, forms, password-protected files.
- Pages: add blank pages, delete, rotate, reorder, insert from other PDFs (merging), extract, export as PNG.
- Markup (⇧⌘A): highlight, underline, strikethrough, pencil, shapes, whiteout, text boxes, notes;
  move and resize, change colour, undo.
- Text editing: select text and press ⌘E — the original is covered with white and an editable text box
  in the same size and colour is placed on top. (The original text stays under the cover: this is not a redaction.)
- Signatures and stamps (⇧⌘K): a library of PNGs/scans, the white background is removed automatically.
- Digital signature (⌥⌘D): standard PDF signature (PKCS#7/CMS, adbe.pkcs7.detached, SHA-256), readable by Acrobat.
  Certificate from the macOS Keychain, .p12 import or a self-signed one. Counter-signing is supported
  (incremental update). Verification (⌥⌘V) and a status banner on open: valid / certificate not trusted /
  changed after signing.
- Export: Word (.docx), RTF, HTML, text, PNG/JPEG pages (72–300 dpi), copy with a password.
- Import: open PNG/JPEG/HEIC/TIFF as PDF, "New PDF from Images…", insert images as pages.

## XLS42 — spreadsheets (.xlsx, .csv)

- Displayed like Excel: column widths and row heights, fonts, fills, borders, merged cells, wrapped text,
  overflow into neighbouring cells, `###` for numbers that don't fit, theme colours.
- Number formats: thousands separators, decimals, currency, %, dates and times, `[Red]`, sections `;`.
- About 120 functions (Help › Supported Functions): SUM/SUMIF(S)/COUNTIF(S), IF/IFS/IFERROR, VLOOKUP/XLOOKUP/INDEX/MATCH,
  text, dates, statistics, PMT… Russian names (СУММ, ЕСЛИ, ВПР) are accepted too. References A1/$A$1, ranges,
  other sheets, whole columns; recalculation with cycle detection.
- Editing: formula bar, cell references picked with the mouse, copy and paste with formula shifting, fill down/right,
  insert/delete rows and columns with formulas adjusted, sorting, sheets, AutoSum, selection totals.
- Freeze panes: at the selected cell, top row or first column — frozen rows/columns stay while scrolling (saved to .xlsx).
- Export to PDF: current sheet, all sheets or the selection; automatic orientation, fit to width, gridlines;
  pages break at row/column boundaries. Printing uses the same layout. CSV export (delimiter choice, UTF-8), CSV/TSV import as a sheet.
- Context menu on cells; formatting bar with font, size, colours, alignment, number formats, borders.
- Tests: `build/XLS42.app/Contents/MacOS/XLS42 --selftest` (formulas, formats) and `--uitest` (editing operations in a window).

## DOC42 — documents (.docx, .doc, .rtf, .odt, .txt)

- Page on a grey desk, styles (title, headings, quote), font, size, colour, highlighting, alignment,
  lists, indents, line spacing, tables, images, signatures and stamps from the shared library, PDF export, word count.
- Word styles (Heading 1, Title, docDefaults, theme fonts) and lists are resolved on open, so documents
  look as intended. Saving .docx uses our own writer, which keeps tables and images.
- Export: PDF (paginated A4/Letter), Word .docx/.doc, RTF, ODT, HTML, text. Opens .md (Markdown) and HTML too.

## Structure

- `Sources/Kit42` — shared: commands, menu bar, toolbar, tool strip, banners, welcome window, localisation,
  signature library, certificates, ZIP.
- `Sources/PDF42`, `Sources/XLS42`, `Sources/DOC42` — the apps. Each has `Commands.swift` (all commands, menus, toolbar)
  and `Strings.swift` (translations).
- `DESIGN.md` — the design system: menu order, reserved shortcuts, window layout, how to add an app.
