# macOS and Windows parity

The reference is the Swift implementation on main plus the local technical-element and label workflows.
“Implemented” requires a normal UI entry point and persisted output where applicable. “Verified” records
actual checks. A source build alone does not establish Windows runtime behavior.

| Area | Current Windows coverage | Remaining work |
| --- | --- | --- |
| Files and document lifecycle | Open/save snapshots, conflict detection, Undo/Redo | Verify command-line file opening, drag/drop, multiple windows, recents, recovery and associations |
| Localization and appearance | English native host | Twenty interface languages, shared picker, dark mode, panel visibility and remembered layout |
| Text proofing | System Rich Edit spelling in DOC42/PPT42 | Verify suggestions and installed-language behavior; full grammar and other editors |
| Signatures and stamps | Shared PNG/JPEG library in all six apps; optional white-paper removal; Undo/Redo for placement | Generators, sample learning and full geometry parity |
| Technical objects | Four barcode encoders, fourteen technical symbols, reusable PNG recipes and XLS insertion | Direct document insertion, vector export and recipe editing across apps |
| Label production | A4 custom grids, 559 stock templates, row mappings, copies, first slot, serial identifiers | Persisted mappings, DOC table sources, PDF artwork/region sources, preview and direct print |
| Printing | Native dialogs, actual-size PDF scene path, optional per-printer calibration and measurement sheet | Native print-to-file output and physical driver checks |
| PDF42 | Reading, page edits, bounded text edits, annotations, simple forms, links, outlines, attachments, password copies, raster redaction | Comparison, split/merge workflows, page labels, headers/footers, watermarks, richer forms, OCR, text exports, certificate signing and validation, remote signing and CryptoPro integration |
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
