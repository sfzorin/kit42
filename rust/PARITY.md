# macOS and Windows parity

The reference is the Swift implementation on main plus the local technical-element and label workflows.
“Implemented” requires a normal UI entry point and persisted output where applicable. “Verified” records
actual checks. A source build alone does not establish Windows runtime behavior.

| Area | Current Windows coverage | Remaining work |
| --- | --- | --- |
| Files and document lifecycle | Open/save snapshots, conflict detection, Undo/Redo | Verify command-line file opening, drag/drop, multiple windows, recents, recovery and associations |
| Localization and appearance | English native host | Twenty interface languages, shared picker, dark mode, panel visibility and remembered layout |
| Text proofing | Native text editing | System spelling, suggestions, languages and grammar capabilities |
| Signatures and stamps | Shared PNG/JPEG library in PDF42, DOC42 and PPT42 | XLS42/IMG42/SCN42 placement; background cleanup; generators and sample learning |
| Technical objects | Four barcode encoders and PNG export | Native symbol chooser, vector export, insertion, recipe editing and round trips in PDF/DOCX/XLSX/ODS |
| Label production | A4 custom grids, row mappings, copies, first slot, serial identifiers | Stock chooser, persisted mappings, DOC table sources, PDF artwork/region sources, preview and direct print |
| Printing | Native print dialogs, rich text and scene output | Actual-size PDF checks, calibration profiles, measurement sheet, print-to-file behavior |
| PDF42 | Reading, page edits, bounded text edits, annotations, simple forms, links, outlines, attachments, password copies, raster redaction | Comparison, split/merge workflows, page labels, headers/footers, watermarks, richer forms, OCR, text exports, certificate signing and validation, remote signing and CryptoPro integration |
| DOC42 | Rich text, tables, images, comments, notes, hyperlinks, bookmarks, TOC and several format adapters | Complete page canvas, full sections/columns, fields, tracked changes, style management, navigator, text search options, picture geometry and rich page decorations |
| XLS42 | Grid editing, formulas, styles, charts, summaries, tables, filtering, print layout | Formula coverage and dynamic arrays, floating objects, advanced filtering/sorting, validation controls, outlines/subtotals, goal seek/solver, split panes, per-cell/password protection and fuller format fidelity |
| PPT42 | Native objects and text, grouping/transforms, basic transitions, PPTX/ODP and printing | Preset geometries, charts/SmartArt, master/layout editing, themes/templates, comments, media and animation playback, show tools and export workflows |
| IMG42 | Image decoding, transforms, adjustments, selections, text, metadata and batch output | Full markup selection/editing, smart lasso, live text, background removal, viewing panels and additional supported system codecs |
| SCN42 | WIA acquisition, image/PDF import, page processing, OCR and searchable output | Scan areas and rescan, device/preset controls, scan history, mark placement, full export settings and physical-device checks |

## Recorded checks

- Windows preview.3 passed 319 MSVC tests and packaged all six apps. One OCR test was ignored.
- Native audit run 42341903682 launched all six actual executables, invoked About, and generated PNG barcodes
  and PDF label sheets through the real dialogs in PDF42, DOC42 and XLS42.
- Ongoing changes are developed on `codex/windows-parity`. Release links remain tied to verified tagged binaries.
