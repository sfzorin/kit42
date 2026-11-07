# macOS and Windows parity

The reference is the Swift implementation on main plus the local technical-element and label workflows.
“Implemented” requires a normal UI entry point and persisted output where applicable. “Verified” records
actual checks. A source build alone does not establish Windows runtime behavior.

| Area | Current Windows coverage | Remaining work |
| --- | --- | --- |
| Files and document lifecycle | Open/save snapshots, conflict detection, Undo/Redo, successful-file recents with clear menu | Verify drag/drop, multiple windows, recovery and associations |
| Localization and appearance | Twenty bundled catalogs, shared menu picker and process language override; prompt label measurement | Verify shared language switching, complete Windows-specific translations, dark mode, panel visibility and remembered layout |
| Text proofing | System Rich Edit spelling in DOC42/PPT42 | Verify suggestions and installed-language behavior; full grammar and other editors |
| Signatures and stamps | Shared PNG/JPEG library in all six apps; optional white-paper removal; Undo/Redo for placement | Generators, sample learning and full geometry parity |
| Technical objects | Four barcode encoders, fourteen symbols, reusable PNG recipes, insertion/editing in PDF/DOC/XLS/PPT and document round trips | IMG/SCN technical placement, full selection controls and remaining native UI verification |
| Label production | A4 custom grids, 559 stock templates, row mappings, copies, first slot, serial identifiers | PDF artwork/region sources, preview and direct print |
| Printing | Native dialogs, actual-size PDF scene path, optional per-printer calibration and measurement sheet | Native print-to-file output and physical driver checks |
| PDF42 | Reading, page edits, bounded text edits, annotations, simple forms, links, outlines, attachments, password copies, raster redaction | Comparison, batch merge workflows, editable page labels, headers/footers, watermarks, richer forms, OCR, text exports, certificate signing and validation, remote signing and CryptoPro integration |
| DOC42 | Rich text, tables, images, comments, notes, hyperlinks, bookmarks, TOC and several format adapters | Complete page canvas, full sections/columns, fields, tracked changes, style management, navigator, text search options, picture geometry and rich page decorations |
| XLS42 | Grid editing, formulas, styles, charts, summaries, tables, filtering, print layout | Formula coverage and dynamic arrays, full floating-object editing, advanced filtering/sorting, validation controls, outlines/subtotals, goal seek/solver, split panes, per-cell/password protection and fuller format fidelity |
| PPT42 | Native objects and text, grouping/transforms, basic transitions, PPTX/ODP and printing | Preset geometries, charts/SmartArt, master/layout editing, themes/templates, comments, media and animation playback, show tools and export workflows |
| IMG42 | Image decoding, transforms, adjustments, selections, text, metadata and batch output | Full markup selection/editing, smart lasso, live text, background removal, viewing panels and additional supported system codecs |
| SCN42 | WIA acquisition, image/PDF import, page processing, OCR and searchable output | Scan areas and rescan, device/preset controls, scan history, mark placement, full export settings and physical-device checks |

## Recorded checks

- Windows preview.3 passed 319 MSVC tests and packaged all six apps. One OCR test was ignored.
- Native audit run 42341903682 launched all six actual executables, invoked About, and generated PNG barcodes
  and PDF label sheets through the real dialogs in PDF42, DOC42 and XLS42.
- Ongoing changes are developed on `codex/windows-parity`. Release links remain tied to verified tagged binaries.

- Run 42344453119 verified production workflows in DOC42/PDF42/XLS42 and proofing flags in DOC42/PPT42.
  IMG42/SCN42 mark checks were blocked by the audit harness retaining a temporary shell dialog handle.
- Portable image regressions verify native and external XLSX/ODS image geometry/data round trips,
  insertion/movement/deletion, preservation of an unrelated package entry, protection and Undo/Redo.
  Spreadsheet native mouse/render/save checks are added and await a Windows run.

- The technical-object adapter regressions pass insertion, replacement as one history step, Undo/Redo,
  and reopen for PDF, DOCX/ODT/RTF, XLSX/ODS and PPTX/ODP. The full portable workspace passed 334 tests
  with one OCR test ignored; Windows GNU target compilation passed. Native technical-object checks await a build.

- Native audit run 42345868618 passed all six apps on the built 8298357 executables, including actual
  spreadsheet rendered pixels, mouse movement, Undo/Redo, deletion/save/reopen and IMG/SCN mark pixels.
- Run 42346392111 verified technical recipe editing and save/reopen in PDF42, XLS42 and PPT42.
  It found a DOC42 command-state defect: Undo/Redo was blocked with a collapsed caret despite the menu
  being enabled. The dispatcher now checks history availability separately from text-format selection.
- Vector QA covers fourteen symbols and four captioned code types: independent Poppler renders match
  reference SVG/PNG ink geometry within one pixel. It found and fixed the text-subtree transform for
  captions. PDF annotations and standalone PDF exports retain the macOS recipe key and have no raster
  image resource in the technical appearance. The next Windows build must verify the updated dispatcher.

- DOC label sources now enumerate explicit tables or custom/selected text. Layout and mapping profiles
  remember only settings; header signatures guard restored mappings. Portable tests cover source
  snapshots, merged covered slots, Undo, layout restoration and exclusion of document values from
  preferences. A native DOC-table/PDFium-output/preferences audit is included for the next build.

- Language host changes pass 341 portable tests (one OCR test ignored) and Windows GNU compilation.
  Translation checks cover all catalogs, language aliases, CLI paths and bounded preference round trips.
  Numeric opt-in command tracing and a nonpublishing debug CI build support diagnosis of DOC42 About,
  which still times out in runs 42347783278 and 42347967756. The earlier refresh deferral did not resolve it.

- ODS picture regression reproduced duplication after sheet reordering. Original image identity now resolves
  through the imported sheet ID/order instead of its current position. All 66 XLS core tests pass, including
  move/save/reopen/delete and opaque package preservation. This is portable format evidence only.

- Run 42350186789 verified all six debug Windows executables after the notification dispatcher fix.
  DOC42 About, proofing toggle, technical Undo/Redo/save/reopen and real table-derived labels now pass.
  The table audit checks PDFium-extracted text/copies, source preservation and restored profiles.
  All twenty DOC42 language launches pass translated File menu/current-language checks, prompt actions,
  translated choice identity and unchanged document/code data. Six real prompt screenshots were inspected;
  special Windows labels still often use English fallback. This is not complete UI translation coverage.

- Run 42350595478 passed all six apps, twenty language scenarios and the recent-document lifecycle audit.
  The latter checks ordering, deduplication, actual Cancel/Discard handling with unsaved text, process restart,
  Clear Menu persistence and byte-for-byte source preservation using isolated preferences.

- PDF page-list extraction and per-page ZIP exports are implemented with background progress/cancellation and
  no-clobber final publication. Portable regressions cover reverse order, effective labels, annotations,
  bookmarks/forms, overlapping ranges, source preservation, cancellation and existing destination safety.
  The portable workspace passed 348 tests (one OCR test ignored); Windows GNU compilation passed.
  Native page-export interaction and PDFium-output checks await a Windows build.
