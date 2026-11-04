# Suite42 — PDF42 · DOC42 · XLS42 · IMG42 · PPT42 · SCN42

A small native office suite for macOS: five apps that look and work alike, share one menu system and design
(the Kit42 library), need no internet and no third-party libraries — only AppKit, PDFKit, Core Image, Vision and
Security from macOS. Interface in English, Russian and Turkish.

| App | For | Opens | Saves |
|---|---|---|---|
| **PDF42** | reading, editing, signing PDFs | PDF, images | PDF (also signed, compressed, password-protected), DOCX, RTF, HTML, TXT, PNG/JPEG |
| **DOC42** | documents | DOCX, DOC, RTF, ODT, Markdown, TXT, HTML | the same + PDF |
| **XLS42** | spreadsheets | XLSX, XLS (97–2003), ODS, CSV/TSV | XLSX, ODS, CSV, PDF |
| **IMG42** | viewing and quick editing of images | JPEG, PNG, HEIC, AVIF, WebP, GIF, TIFF, PSD, RAW, SVG, PDF, … | the original format, PNG, JPEG, HEIC, TIFF, AVIF |
| **PPT42** | presentations and slide shows | PPTX, ODP (PPT: a message suggesting conversion) | PPTX, ODP, PDF (slides, notes pages), PNG/JPEG, outline RTF/Markdown |
| **SCN42** | scanning (replaces Image Capture) | scanners (USB, network, AirScan), iPhone/iPad camera, images, PDF | searchable PDF, PDF/A, multi-page TIFF, JPEG, PNG, HEIC, TXT/RTF |

**По-русски.** Набор из шести программ для macOS: PDF42 (PDF: правка, подписи, сжатие), DOC42 (тексты Word/ODT/RTF/
Markdown), XLS42 (таблицы Excel/ODS/CSV), IMG42 (просмотр и простая правка изображений) PPT42 (презентации PPTX/ODP, показ слайдов) и SCN42 (сканирование: сканеры и iPhone, автообрезка, распознавание текста, PDF). Работают без интернета,
интерфейс на английском, русском и турецком.

## Install

```bash
git clone https://github.com/sfzorin/kit42.git && cd kit42
./build.sh                  # all apps → build/*.app
./build.sh PDF42 install    # one app, plus a copy in /Applications
```

Requires macOS 14+ and the Xcode Command Line Tools (Swift 5.9+). To make an app the default one for a file type:
Finder › Get Info › Open with › Change All.

Quick Look (space bar in Finder) and Finder thumbnails come with the apps, for formats macOS shows as plain text or
not at all: DOC42 brings Markdown (`.md` rendered like a document: headings, lists, task lists, tables, code,
quotes, images next to the file), XLS42 brings OpenDocument spreadsheets (`.ods`: every sheet, merged cells,
bold/italic, fills, column widths) and TSV as a table. Previews follow light/dark mode. The extensions live inside
the app (`Contents/PlugIns`), so installing the app is enough; if Finder keeps the old look, run
`qlmanage -r` (and `qlmanage -r cache` for thumbnails). When another app also previews a type (LibreOffice for
`.ods`, for instance) macOS picks one of them; System Settings › General › Login Items & Extensions › Quick Look
lets you switch extensions off.

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
- Bookmarks: the sidebar's Contents tab is editable — ⌘D (Insert › Add Bookmark) adds one for the current view (named
  after the selected text, else "Page N"), double-click or Return renames, Delete removes, drag to reorder and nest,
  indent/outdent buttons, Set Destination to Current View, bold/italic/colour (Insert › Bookmarks › Style); all undoable.
  "Create Bookmarks from Headings…" turns lines set larger than the body text into a 1–3 level tree (optionally with OCR
  for pages without text). PDFKit on this macOS neither writes edited outlines nor correct page references, so the outline
  (with /C and /F styles) is written by PDF42 itself after PDFKit (`DocumentWriter`), readable by Preview, Acrobat, pypdf.
- Page › Crop… (⌥⌘K) / the Crop tool (drag a rectangle): margins in mm on the current, all, odd, even pages or a range,
  "remove white margins automatically", Remove Crop; sets the CropBox, and optionally deletes the content outside on save
  with the redaction engine. Page › Page Size…: A3/A4/A5/Letter/Legal/Tabloid/custom, scale the content to fit or keep it
  and extend/trim the canvas.
- Links: the Link tool (Insert, markup bar) — drag a rectangle → web address (e-mail becomes mailto:), page (keep zoom,
  whole page, page width) or bookmark, optional visible border; click a link with the tool to edit or delete it.
  Insert › Create Links from URLs finds web and e-mail addresses in the text; View › Show Link Borders. Saved as /Link
  annotations with /URI or /GoTo (PDFKit's broken or wrong page references are repaired on save).
- File › Properties… (⌥⌘I): title, author, subject, keywords (written to the Info dictionary and XMP: dc:title,
  dc:creator, dc:description, pdf:Keywords…), creator, producer, dates, file and page size, PDF version; Initial View
  (page layout, panel, open at page and magnification, fit/centre window, show title, hide toolbar/menu bar — also applied
  when PDF42 opens the file); fonts with embedded/subset state and pages; encryption, permissions, signatures.
- Attachments: sidebar tab (⌥⌘3) listing embedded files (/EmbeddedFiles) and file attachment annotations; add with
  Insert › Attach File… or by dropping files, save, open, drag out to Finder, delete (undoable).
- File › Export as PDF/A-2b… (also in Export As…): fonts embedded (pages with non-embedded fonts are redrawn by Quartz,
  which embeds them; failing that annotations are flattened, last resort an image with OCR text), sRGB output intent,
  XMP with pdfaid part 2 / conformance B and matching Info, document ID; JavaScript, forbidden actions and annotation
  types, attachments, image interpolation, hidden/unprintable annotation flags are removed. Not checked with veraPDF here
  (not installed): DeviceCMYK content, optional content and font program details are not converted.
- Page › Header & Footer…: six positions, codes <<page>> <<pages>> <<label>> <<date>> <<file>> <<bates>>, Bates
  prefix/suffix/digits/start, font, size, colour, margins, page set; optionally the same on other files with continuing
  Bates numbers. Editable until saved (Page › Remove Headers and Footers), then real page text.
- Page › Page Labels…: ranges of logical numbers (1, i, I, a, A, none) with prefix and start (e.g. i–iv, then 1…, "A-1");
  shown in thumbnails, the title bar and bookmarks, accepted by Go to Page; saved as /PageLabels.
- Document-level parts that PDFKit drops when pages are replaced (labels, initial view, attachments, outline) are put
  back on every save.
- Command line for these: `--bookmarks in out [clear] [headings[:levels]] "Title@page[:b][:i][:#RRGGBB]" ">Child@page"`,
  `--bookmarks file`, `--crop in out l,t,r,b|auto[:l,t,r,b] [pages] [remove]` (points), `--page-size in out A4|210x297 [scale|extend] [pages]`,
  `--link in out x,y,w,h[@page] https://…|N[:Fit|FitH] …`, `--autolink in out`, `--props in out title=… author=… subject=…
  keywords=… layout=… mode=… openpage=N zoom=… fitwindow=1 …`, `--info file`, `--attach in out file… [desc=…]`,
  `--detach in out name|all`, `--attachments file [dir]`, `--pdfa in out`, `--bates in out PREFIX start [digits] [position]`,
  `--bates-batch outdir PREFIX start a.pdf b.pdf…`, `--header-footer in out "l|c|r" "l|c|r" [pages]`,
  `--labels in out "1-4:r;5-:D;9-:D:A-"`, `--fonts file`.
- UI checks: `PDF42 file.pdf` with `K42_SNAPSHOT=out.png` (+ `K42_SNAPSHOT_SHEET=1`), `K42_APPEARANCE=dark|light`,
  `K42_MARKUP`, `K42_TOOL=n`, `K42_REDACT="x,y,w,h;…"`, `K42_COMPRESS`, `K42_STAMPS`, `K42_COMPARE=other.pdf`,
  `K42_ACTION=watermarkAction|pageNumbersAction|splitAction|signDocumentAction|applyRedactionsAction|mergeList|textField|…`
  (opens that dialog for the snapshot; also propertiesAction, pageSizeAction, headerFooterAction, pageLabelsAction,
  bookmarksFromHeadingsAction, linkDialog, cropDialog), `K42_SIDEBAR=outline|attachments`, `K42_LINK_BORDERS=1`,
  `K42_DO=action,…` (non-modal actions before the snapshot), `K42_PROPERTIES_TAB=n`.

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
  with totals. Saved as a real pivot table — .xlsx pivot cache + pivot table parts (refreshed on load by Excel,
  imported as a DataPilot by LibreOffice), .ods `table:data-pilot-tables` — with the result cells written as usual.
  Pivot tables from Excel/LibreOffice files are read too, so Refresh Pivot Table works after reopening; it rebuilds
  from the source (a source that grew or shrank is replaced by its current region; fields follow their header names).
  One pivot per sheet, one row/column/value field: richer pivots refresh in XLS42's simpler layout.
- Dark mode: cells without a fill are dark with light text (headers, gridlines, gutters, charts, buttons follow);
  fills and colours from the file stay, text on them stays readable, near-black text/borders are lifted. Printing
  and PDF export stay light.
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
  (footnotes.xml; endnotes are read as footnotes), .odt (text:note), Markdown `[^1]`, a "Notes" list in RTF/HTML/text.
- Comments (⌥⌘M): highlighted text with cards in the margin (author, date, edit, resolve, delete); .docx comments.xml
  with resolved state (commentsExtended.xml), .odt office:annotation (resolved state as LibreOffice writes it) and
  RTF Word annotations, read and written; Markdown export as `<!-- comment: … -->`, HTML as `<mark title="…">`.
- Track changes (Edit › Track Changes, ⇧⌘E; Export As… is ⌥⇧⌘E): typed text becomes an insertion (underlined, in the
  author's colour), deleted text stays struck through until accepted. Review menu: Show Markup (off = final view),
  Next/Previous Change, Accept/Reject Change, Accept/Reject All; changes appear as cards next to the comments, with
  accept and reject buttons. Undoable. Saved to .docx as w:ins / w:del (w:delText, paragraph marks) with
  w:trackRevisions, read from Word and LibreOffice files; other formats, PDF and printing get the text with all
  changes accepted. Commands (tables, footnotes, Replace All, …) are not tracked, nor are formatting changes.
- Sections: Insert › Section Break (Next Page); each section has its own paper, orientation, margins and columns
  (Document Setup applies to the cursor's section or the whole document). Columns 1–3 with spacing; the last page of a
  multi-column section balances its columns. Mixed page sizes export to PDF page by page. Saved to .docx as
  sectPr / w:cols and read back (continuous breaks open a new page).
- Dark mode: the window, rulers, comment and change cards follow the system; pages stay white paper with black text.
- Table of contents from Title/Heading 1–3 with dot leaders, page numbers and links to the headings; Update rebuilds it
  in place. Saved as a Word TOC field with bookmarks and hyperlinks.
- Find bar across all pages with replace; Find and Replace dialog (⌥⌘F): match case, whole words, regular expressions,
  Replace / Replace All (undoable).
- Links (⌘K: insert, edit, remove; saved in docx/odt/rtf/md/html), special characters, Paragraph dialog (indents, spacing,
  exact line height), Clone Formatting (⌥⌘C; double-click keeps it on), Statistics (document and selection).
- Styles panel (⌘T or F11, also Format › Styles): paragraph styles (Body, Title, Heading 1–6, Quote, List, Caption,
  TOC 1–3, Footnote, custom) and character styles (Emphasis, Strong, Code, custom), each shown in its look; click to
  apply; New Style from Selection, Update Style to Match Selection, Modify Style (font, size, bold/italic/underline,
  colour, spacing, line spacing, indents, alignment, based on, next style), delete custom styles. A changed style
  restyles every paragraph in it (and in styles based on it), keeping what was formatted by hand; undoable. Saved as
  real styles: .docx styles.xml with w:pStyle/w:rStyle (run properties equal to the style are left to it), .odt
  named styles in styles.xml (paragraph styles); read back from Word, LibreOffice and DOC42 files.
- Navigator (F5, side panel): headings as a tree (click to jump, drag a heading to move its chapter), tables, images,
  bookmarks, comments, footnotes, links, sections and fields.
- Bullets and Numbering (Format): bullets, numbers, letters, Roman numerals, text before/after ("(a)"), start value,
  restart numbering, showing higher levels (1.1.1); multi-level lists with Tab / Shift-Tab at an item's start (Format ›
  Demote/Promote One Level); numbers follow edits. Outline Numbering numbers Heading 1–6 (1, 1.1, 1.1.1 or I, A, 1, a).
  Saved as .docx numbering.xml (abstractNum/num, lvl with numFmt, lvlText, start, pStyle for headings) and read back.
- Fields (Insert › Field): page number, page count, date and time (formats, fixed or updating), title, author, file
  name, chapter (current Heading 1); also sequence numbers (captions) and table formulas. Shaded on screen, updated
  with the layout (each page shows its own number), Update Fields (F9). .docx: w:fldSimple (PAGE, NUMPAGES, DATE \@,
  TIME, TITLE, AUTHOR, FILENAME, STYLEREF, SEQ, =SUM(ABOVE); w:fldLock for fixed ones); simple and complex fields are
  read back. Title and author: File › Properties (docProps/core.xml).
- Headers and footers: rich text with fields, tab stops for left/centre/right, a different first page and different
  odd/even pages, per section (or the whole document). Double-click the top or bottom of a page to edit there
  (Esc or a click in the text ends), or Insert › Header and Footer (dialog with page number position).
  .docx header1/2/3.xml (default, first, even) with w:titlePg and w:evenAndOddHeaders, read and written; Word's rule
  that a section without its own headers inherits the previous one's is followed.
- Tables: Table Properties (column widths, borders all/outer/inner/none, line width and colour, cell padding, cell
  background, vertical alignment, repeated heading rows), Merge Cells / Split Cells (merged back, or into columns or
  rows), insert/delete rows and columns with merged cells, Sort (column, ascending/descending, numbers or text, heading
  row kept), Formula (=SUM(ABOVE), LEFT, AVERAGE, MIN, MAX, COUNT, PRODUCT; updates), Convert Text to Table (tabs,
  semicolons, commas, paragraphs) and Table to Text, AutoFormat presets, Tab moves between cells. Rows joined by a merged
  cell are kept on one page. .docx: w:tblBorders/w:tcBorders, w:shd, w:gridSpan, w:vMerge, w:tblHeader, w:tblGrid
  widths, w:tblCellMar; read back (the system reader drops spans and shading: DOC42 rebuilds the tables).
- Pictures: click for handles (corners keep proportions; Shift frees them), drag a floating picture to move it; wrap in
  line, square, top and bottom, behind or in front of text (Format › Image › Wrap); anchored to the paragraph, placed on
  its page; border, crop and size in cm in Image Properties; Insert › Caption ("Figure 1: …", numbered automatically,
  above tables). .docx wp:inline / wp:anchor with wrapSquare, wrapTopAndBottom, wrapNone/behindDoc, srcRect, a:ln.
- Paragraph borders and background (box, top, bottom, …; neighbouring paragraphs share a box; w:pBdr/w:shd), drop caps
  (2–5 lines; Word's framed drop-cap paragraph), page background colour and watermark text (Format › Page; w:background,
  Word's VML watermark in the headers), Hyphenation (w:autoHyphenation), Character dialog (font, size, bold/italic,
  colour, highlight, all caps, small caps, superscript/subscript, spacing, underline single/double/thick/dotted/dashed/
  words, strikethrough single/double; w:caps, w:smallCaps, w:dstrike, w:spacing, w:u, w:vertAlign, read back).
- PDF export (File › Export as PDF…): page range, image quality, headings as PDF bookmarks, clickable links (web
  addresses, table of contents and other internal links), comments as notes, title and author in the PDF properties.
- View: single page, book view (two pages), multiple pages, web layout (no pages); status bar with page X of Y, words
  (of the selection), language, layout buttons and a zoom slider (View › Hide Status Bar; Hide All Panels hides it too).
- Known limits: small caps are shown as capitals when the font has no small capitals (saved correctly); heading rows
  repeat on each page in Word/LibreOffice but not on DOC42's screen; .odt keeps paragraph styles but not character
  styles, list definitions, fields or rich headers (plain text there); page-relative positions of floating pictures from
  other programs are approximate.

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
- Live Text like Preview (VisionKit): text in the image is recognised in the background when it is shown (cached per
  image; Russian, English, Turkish and your preferred languages, plus automatic detection) and can be selected with the
  mouse while viewing or in the Select tool — I-beam over text, drag across words and lines (rotated text too),
  double-click a word, triple-click a line, ⌘A selects all text once some is selected, ⌘C copies, Esc deselects; the
  right-click menu has Look Up, Translate, Search With Google, Copy, Share. Links, phone numbers and e-mail addresses are
  clickable. Drawing tools and marks keep the mouse (no text selection while drawing).
- Markup bar like Preview's: Select; Selection ▾ (rectangular, elliptical, lasso, Smart Lasso, aspect ratios; Crop to Selection ⌘K,
  Delete Selection ⌫, Copy, Invert ⇧⌘I); Instant Alpha (drag on a colour: farther = wider range, then ⌫); Sketch
  (a rough line, box, circle or star becomes a clean shape); Draw; Shapes ▾ (line, arrow, rectangle, rounded rectangle,
  oval, speech bubble, star, polygon, loupe, spotlight, pixelate); Text; Sign (shared signature library ⇧⌘K);
  Adjust Colour; Adjust Size; Shape Style ▾ (width, dashed, arrowheads, shadow, loupe zoom); Border and Fill colour;
  Text Style ▾ (font, size, colour, bold/italic/underline, alignment); Image Description (alt text, saved in the metadata).
  Marks stay objects — select, move, resize with handles, restyle, ⌫ deletes — until the image is saved.
- Smart Lasso: paint a wide stroke around the object's edge (24 pt on screen at any zoom); the selection snaps to the
  edge inside the stroke — colour edges across the band, a two-region fit and Vision's subject mask, joined into one
  closed path by dynamic programming. Then Crop / Delete / Copy / Invert as with any selection.
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
  (mean luminance), `--ocr file`, `--rotate file left|right` (lossless), `--types`, `--smart-lasso in "x,y;…" mask.png
  [radius]` (selection mask for a stroke), `--smart-lasso-eval in [--gt mask.png] [--radius r] [--noise a] [--vis out.png]`
  (simulated rough strokes around the subject: IoU of plain vs Smart Lasso).
- UI checks: `K42_SNAPSHOT=out.png` plus `K42_NEXT=n`, `K42_PAGE=n`, `K42_INFO`, `K42_FILMSTRIP`, `K42_ADJUST`, `K42_MARKUP`,
  `K42_DEMO_MARKS`, `K42_TOOL=n`, `K42_SELECT=rect|ellipse|alpha` (+ `K42_CROP`, `K42_DELETE`), `K42_SEARCH=text`,
  `K42_ZOOM=x`, `K42_STAMPS`, `K42_RESIZE`, `K42_DESCRIPTION`, `K42_FULLSCREEN`, `K42_HIDE_ALL`, `K42_SAVE`, `K42_UNDO`,
  `K42_DUMP_MENUS` (prints the markup drop-downs), `K42_APPEARANCE=dark|light`, `K42_EXPORT_ACCESSORY`,
  `K42_DUMP_CANVAS`; Live Text: `K42_LIVETEXT_SELECT="from..to"`, `K42_LIVETEXT_DRAG="x,y;x,y"`, `K42_LIVETEXT_CLICK=x,y,n`,
  `K42_LIVETEXT_ALL`, `K42_LIVETEXT_MENU=x,y`, `K42_LIVETEXT_PROBE`, `K42_LIVETEXT_KEY` (synthesised events, results
  printed); `K42_SMART_LASSO="x,y;…"|@file` (+ `K42_SMART_CROP`).

## PPT42 — presentations (PPTX, ODP)

- Files: PowerPoint .pptx (PresentationML: slides, master and layouts with theme colours/fonts and placeholder positions,
  text with runs, bullets/numbering and levels, preset shapes with fill/line/shadow, lines and arrows, pictures with
  crop, tables, groups, backgrounds solid/gradient/picture, speaker notes, 16:9 and 4:3, transitions, entrance builds
  as p:timing) and OpenDocument .odp (pages, frames, custom shapes, images, tables, groups, notes, styles, transitions).
  Legacy .ppt opens with a message suggesting conversion. Charts and SmartArt are shown as placeholder boxes.
  Fonts missing on the Mac (Calibri, Aptos…) are replaced by close ones (Carlito if installed, Helvetica Neue).
- Export: PDF (⌥⌘E; one page per slide), notes pages PDF, PNG/JPEG images of slides, outline as RTF or Markdown;
  printing of slides, handouts (1–9 per page) or notes pages.
- Editing like Impress/Keynote: thumbnails sidebar (add, duplicate, delete, multi-select, drag to reorder, copy/paste
  slides, context menu with layout and transition), New Slide ⇧⌘N with a layout picker (Title, Title and Content, Two
  Content, Section Header, Title Only, Blank, Picture with Caption), canvas with zoom to fit, handles to move / resize /
  rotate (⇧ keeps proportions or snaps to 15°), snapping guides to the slide centre/edges and other objects, arrow
  keys nudge, align and distribute, arrange (front/back), group/ungroup, copy/paste objects (also images and text from
  other apps), drag & drop of images.
- Text in place (double-click, Return or just type): format bar and Format menu — font, size, bold/italic/underline/
  strikethrough, colour, super/subscript, alignment, vertical alignment, bullets/numbering, Tab/⇧Tab levels, line
  spacing; shrink-on-overflow and auto-height text boxes; slide number and date fields; tables (rows×columns, Tab to the
  next cell, add/delete rows and columns).
- Inspector (⌥⌘I): Slide (layout, background colour/gradient/picture, transition, hide, theme, slide size), Shape
  (position and size in cm, rotation, fill, line colour/width/dash/arrowheads, opacity, corner radius, shadow, build
  animation), Text. Six built-in themes; Master view (⌥⌘5) edits title/body styles, placeholder positions and
  background for all slides. Views: Normal, Outline (editable: Tab-indented lines are bullets, new title lines add
  slides), Slide Sorter, Notes Page; notes pane under the canvas. Find and Replace (⌘F) in slides and notes. Undo everywhere.
- Slide show: ⌥⌘P from the start, ⇧⌘P from the current slide (Page Setup keeps its menu item); transitions fade, push,
  wipe, cover, dissolve, split, zoom (Core Animation); builds appear/fade/fly in/zoom on click; click/→/Space next,
  ←/⌫ previous, number + Return jumps, B/W black/white screen, Esc ends; presenter view (current and next slide, notes,
  timer, clock) on a second display, or Rehearse (⌥⌘R) in a window.
- Command line: `--info file`, `--export in out.pdf [--notes] | dir [--jpeg --width N] | out.rtf | out.md`,
  `--convert in.pptx out.odp` (and back), `--demo out.pptx` (a deck with every feature).
- UI checks: `K42_SNAPSHOT` with `K42_SLIDE=n`, `K42_VIEW=sorter|outline|notes|master`, `K42_SELECT=i,j`,
  `K42_INSPECTOR=1|slide|shape|text`, `K42_EDIT`, `K42_SHOW=1` (+`K42_SHOW_STEPS`), `K42_PRESENTER=1`, `K42_LAYOUTS`,
  `K42_DO="cmd;cmd"` (scripted commands, see Snapshot.swift), `K42_SAVE=path`, `K42_PASTEBOARD=1` (private pasteboard).
- Not yet: charts/SmartArt editing, custom geometry (read as rectangles), motion paths and exit animations, embedded
  media, comments, layout editing in Master view (only the master).

## SCN42 — scanning (replaces Image Capture)

One window: pages on the left, a big preview in the middle, a few clear settings and one big **Scan** button on the
right. Every scan adds pages to the document; save them as one searchable PDF when you are done.

- Scanners: everything Image Capture sees (ImageCaptureCore: USB, network/Bonjour, AirScan/eSCL), picked in the
  toolbar and remembered; status in plain words (connecting, warming up, busy, feeder empty or jammed, needs a driver…).
  Flatbed, document feeder with duplex, transparency unit. **Scan with iPhone or iPad** (Continuity Camera: Take Photo,
  Scan Documents) from the toolbar, File menu or welcome window — no scanner needed.
- Settings: presets Document, Photo, Receipt, Draft plus your own (Scan › Save Settings as Preset…, ⌃⌘1…); source, colour
  (colour / gray / B&W), resolution, paper size (Auto, A4, Letter, Legal, A5, A6, business card, custom). More Options:
  bit depth, brightness, contrast, B&W threshold, descreen.
- Overview (⇧⌘B) shows the glass; drag to mark one or several scan areas (move, resize by the corners, ⌫ deletes; hand-drawn
  areas are remembered). **Separate photos on the glass**: the photos are found on the overview (glass background +
  Vision rectangles) and each one becomes its own straight image.
- After scanning (Core Image + Vision, in the background while the scanner goes on): crop to the page and straighten
  (perspective correction; text-line deskew for feeder pages), turn sideways / upside-down pages upright (text direction),
  remove blank pages (ink coverage + tone), document clean-up (paper made white: shadows, yellowing and uneven light
  divided out; sharper text; adaptive B&W; border clean-up), photo auto-enhance.
- Pages: thumbnails with drag-to-reorder, drop images/PDFs to insert, rotate ⌘L/⌘R, delete ⌘⌫, move ⌥⌘↑/↓, Rescan Page ⌥⌘B,
  Insert Next Scan After This Page, Split Document Here (rest goes to a new window), Enhance ⌥⌘E, colour per page,
  Crop and Straighten Again, Remove Blank Pages; everything undoable.
- Text: Recognize Text ⌥⌘R (Vision, Russian/English/Turkish + your languages): invisible text layer in PDFs (searchable,
  selectable), Copy Text ⇧⌘C, Export Text (.txt, .rtf).
- Saving ⌘S: PDF (one file or one per page), PDF/A-style (XMP pdfaid 2B, sRGB output intent), multi-page TIFF (B&W as 1-bit
  CCITT G4), JPEG/HEIC (quality), PNG. File size presets (lossless / 300 / 200 / 150 dpi with JPEG) with the expected size
  shown before saving; JPEG data goes into the PDF unchanged, B&W pages stay 1-bit. Name templates (`Scan YYYY-MM-DD HH-mm`,
  counter `{n}`, first line of text `{title}`), folder (default ~/Documents/Scans), then open in PDF42, IMG42, Finder or the
  default app. Export… (any name/place/format), Share, Send by Mail, Print, **Copy** ⌥⌘P (scan and print N copies
  on the default printer).
- History (⌥⌘3): saved scans with thumbnails; double-click opens, right-click reveals or removes.
- Command line (headless, nothing scans for real): `--make-test-inputs dir` (skewed page on a grey glass with a shadow,
  three photos on the glass, feeder pages: blank with noise, skewed, upside down, yellowed, sideways), `--process in out
  [--crop --deskew --rotate --enhance --photo --gray --bw]`, `--pipeline dir|files… out.pdf [--ocr --remove-blank --compress
  original|high|balanced|smallest --bw --gray --pdfa --format tiff|jpeg|png|heic]` (prints crop angle and box, deskew,
  rotation, ink, blank, OCR sample, sizes), `--detect-photos glass.png [outdir]`, `--fake-scan dir out.pdf [--feeder --duplex
  --photos --dpi n]`, `--list-devices [s]` (read-only discovery), `--name template`.
- Virtual scanner: `K42_FAKE_SCANNER=dir` replaces Image Capture with a scanner that "scans" the images in `dir` (`glass*`
  for the flatbed in turn, `feed*` for the feeder; areas, resolution, colour, duplex, `K42_FAKE_WARMUP`, `K42_FAKE_SPEED`).
  UI checks: `K42_SNAPSHOT` with `K42_AUTOSCAN=flatbed|feeder|overview|photos`, `K42_DEMO_PAGES=n`, `K42_SHOW=history|settings|more|glass`,
  `K42_SOURCE=feeder` (+ `K42_DUPLEX`, `K42_REMOVE_BLANK`), `K42_PRESET=n`, `K42_SAVE_NOW` (+ `K42_SAVE_FORMAT`, `K42_SAVE_OCR`),
  `K42_SAVE_SHEET`, `K42_ACTIONS="select:2,rotateRight,moveUp,undo,…"`, `K42_CONTINUITY_TEST=file` (private pasteboard),
  `K42_PRINT_TEST`, `K42_DUMP_MENUS`, `K42_WELCOME`, `K42_SCAN_DIR` (saves and history go there), `K42_WATCHDOG=s`.

## Common

- Interface language (English, Russian, Turkish) is chosen on the welcome screen and shared by all apps; system panels
  (Print, Save, toolbar items) follow it too.
- Any panel can be hidden: View › Hide All Panels (⇧⌘\\) leaves only the document; View › Show Toolbar (⌥⌘T),
  Show Toolbar Labels (icons only makes the toolbar half as tall) and each app's own bars. In full screen (⌃⌘F) the
  bars slide in only when the pointer reaches the top edge.
- Autosave every 30 s to a backup location: documents survive a crash.
- Dark mode everywhere; `K42_APPEARANCE=dark` (or `light`) forces it for one run, e.g. with `K42_SNAPSHOT`.
- `scripts/check_strings.py` — finds UI strings without a Russian/Turkish translation.
- Distribution to other Macs: `DEVELOPER_ID="Developer ID Application: …" ./scripts/sign_and_notarize.sh`
  (needs an Apple Developer account; see the script header).

## Not implemented

- GOST signatures (needs CryptoPro CSP), tracked formatting changes in DOC42, saving to legacy .xls, Excel 5.0/95 files.

## Structure

- `Sources/Kit42` — shared: commands, menu bar, toolbar, tool strip, banners, welcome window, localisation,
  signature library, certificates, ZIP.
- `Sources/Previews42` — Quick Look rendering (Markdown → HTML/page, ODS/TSV → table); `Sources/QLPreview42` and
  `Sources/QLThumbnail42` are the extension binaries that `build.sh` packs into `.appex` bundles
  (Info.plist generated, ad-hoc signed with `Resources/QuickLook/Extension.entitlements`); `ql42render` renders the
  same output to files for testing (`ql42render html file.md out.html`, `ql42render thumb file.ods 512 out.png`).
- `Sources/PDF42`, `Sources/XLS42`, `Sources/DOC42`, `Sources/IMG42`, `Sources/PPT42`, `Sources/SCN42` — the apps. Each has `Commands.swift` (all commands, menus, toolbar)
  and `Strings.swift` (translations).
- `DESIGN.md` — the design system: menu order, reserved shortcuts, window layout, how to add an app.

## License

MIT — see [LICENSE](LICENSE).
