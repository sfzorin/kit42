# macOS and Windows parity

The reference is the Swift implementation on main plus the local technical-element and label workflows.
“Implemented” requires a normal UI entry point and persisted output where applicable. “Verified” records
actual checks. A source build alone does not establish Windows runtime behavior.

| Area | Current Windows coverage | Remaining work |
| --- | --- | --- |
| Files and document lifecycle | Open/save snapshots, conflict detection, Undo/Redo, successful-file recents with clear menu; separate New/New Window sessions | Verify drag/drop, independent window lifecycle, recovery reference behavior and associations |
| Localization and appearance | Twenty bundled catalogs, shared menu picker and process language override; prompt label measurement | Verify shared language switching, complete Windows-specific translations, dark mode, panel visibility and remembered layout |
| Text proofing | System Rich Edit spelling in DOC42/PPT42 | Verify suggestions and installed-language behavior; full grammar and other editors |
| Signatures and stamps | Shared PNG/JPEG library in all six apps; optional white-paper removal; Undo/Redo for placement | Generators, sample learning and full geometry parity |
| Technical objects | Four barcode encoders, fourteen symbols, reusable PNG recipes, insertion/editing in PDF/DOC/XLS/PPT and document round trips | Full technical-object selection/placement controls and richer label artwork sources |
| Label production | A4 custom grids, 559 stock templates, row mappings, copies, first slot, serial identifiers | PDF artwork/region sources, preview and direct print |
| Printing | Native dialogs, actual-size PDF scene path, optional per-printer calibration and measurement sheet | Native print-to-file output and physical driver checks |
| PDF42 | Reading, page edits/labels, selected-page extraction/split ZIP, bounded text edits, annotations, simple forms, links, outlines, attachments, password copies, raster redaction | Comparison, batch merge workflows, headers/footers, watermarks, richer forms, OCR, certificate signing and validation, remote signing and CryptoPro integration |
| DOC42 | Rich text, tables, images, comments, notes, hyperlinks, bookmarks, TOC and several format adapters | Complete page canvas, full sections/columns, fields, tracked changes, style management, navigator, text search options, picture geometry and rich page decorations |
| XLS42 | Grid editing, formulas, styles, charts, summaries, tables, filtering, print layout | Formula coverage and dynamic arrays, full floating-object editing, advanced filtering/sorting, validation controls, outlines/subtotals, goal seek/solver, split panes, per-cell/password protection and fuller format fidelity |
| PPT42 | Native objects and text, grouping/transforms, basic transitions, PPTX/ODP and printing | Preset geometries, charts/SmartArt, master/layout editing, themes/templates, comments, media and animation playback, show tools and export workflows |
| IMG42 | Image decoding, transforms, adjustments, selections, text, metadata and batch output | Full markup selection/editing, smart lasso, live text, background removal, viewing panels and additional supported system codecs |
| SCN42 | WIA acquisition, image/PDF import, page processing, OCR and searchable output | Scan areas and rescan, device/preset controls, scan history, full export settings and physical-device checks |

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

- Full release validation run 42350889660 (84f2e3f) passed all six optimized apps, twenty language prompts,
  shared-picker Cancel/Discard/restart and next-launch settings in all six apps, and recent-document lifecycle.
- Run 42351585775 (689ee17 debug) passed shared/PDF/XLS targeted MSVC tests and the other app scenarios,
  but the added PDF export scenario timed out opening its next three-page source. Poppler independently
  confirms the fixture has three valid text pages. Native export verification is pending investigation;
  no assertions were relaxed. Numeric open-phase tracing and a repeated-async-open regression were added.
- Editable page-label ranges, numbering styles, prefixes, clear/Undo and navigation by logical label are now
  implemented. Source/export/history regressions pass in the portable suite (351 passed, one OCR test ignored).
  Native label edits, PDFium label extraction and navigation after reopen are added for the next build.

- A command-ID review found that host Save As (18) intercepted IMG/SCN Crop and PDF Draw Rectangle. Save As
  moved to 65507; native pixel/annotation/history regressions are added. Idle canvas mouse moves no longer
  trigger caption/repaint work; current tools need pointer motion only during gestures.
- The technical reopen audit now first makes an unsaved payload change, explicitly discards it while opening
  the saved file, and checks clean saved state. Earlier same-filename waits could read the existing model;
  earlier results do not establish asynchronous PDF reopen. Open-phase tracing in 42352293454 shows no
  later polling after the initial document commit. The updated host awaits native verification.

- Native audit 42353607494 passed all six aaed968 executables with the strengthened dirty/discard/reopen
  checks, real IMG/SCN crop pixels and history, drawn PDF rectangles, ordered extraction/split ZIP and
  editable labels/Undo/Redo/clear/navigation after reopen. PDFium independently checks output text,
  annotation counts and labels. Tracing confirms later async opens reach identity verification and commit
  after idle canvas work was removed. Harness fixes identify confirmation/errors separately from closing pickers.
- XLS adds 22 engineering functions, 112 shared units/27 prefixes, digit-bearing function tokenization and
  Excel compatibility prefixes. Portable tests cover reference examples, signed bounds, shifts, coercion,
  dimensional/unit limits and native/external XLSX/ODS formulas. Workspace: 357 passed; one OCR ignored.
  Windows GNU compilation passes; native editing/cached-XLSX-result checks await a new build.

- Generated Office caches now retain formula result types: XLSX numeric-looking text keeps leading zeroes,
  Boolean/string/error results remain distinct, and ODS keeps scalar cached text/Boolean values. XML regressions
  inspect types and values directly, including literal spreadsheet escapes and invalid XML character encoding.
  External XLSX/ODS tests edit inputs before recalculation to exclude saved-cache false positives.

- Static-runtime build 42355577552 passed PE ordinary/delayed-import checks for all six executables and bundled
  PDFium: no VC++ Redistributable DLL imports remain. Its native suite passed the other app/language/recent cases;
  the engineering case retained an older harness interaction. Public preview.3 was not changed.
- PDF text export now offers TXT/RTF/HTML/DOCX through one format/page-list prompt and a correctly configured
  picker. Portable regressions cover Unicode, text styling, page/blank-page boundaries, HTML escaping and safe
  cancellation/no-overwrite publication. Windows-only regressions check extraction from the current redacted and
  page-edited snapshot. Workspace: 360 portable tests passed, one OCR fixture ignored; Windows GNU test compilation
  passed. Native four-format output/history/source checks await the next build.

- A reproducible report covers all 494 macOS function examples (two locale-dependent cases skipped). The starting
  Windows evaluator matched 110 fixed examples; after 17 new text functions and range-aware CONCAT/CONCATENATE,
  136 match and 356 remain different. This is example coverage, not a count of implemented functions.
- Text regressions cover optional/missing arguments, negative delimiter occurrences, wildcard search/escapes,
  Unicode and count/code-point bounds, error propagation, range blanks/Boolean values and input edits after
  independent XLSX/ODS import. Portable workspace: 363 passed, one OCR test ignored; GNU test compilation passes.
  Native XLSX text-result and dirty/discard/reopen checks are included for the next compatible build.

- Native run 42356965075 passed all six 5918f9b executables, twenty language prompts, shared-picker/recent
  lifecycle and strict engineering dirty/discard/reopen checks. PDF text export passes real TXT/RTF/HTML/DOCX
  output from unsaved page edits, page ordering/boundaries, cancellation and unchanged source/history checks.
  The Windows PDFium regression separately verifies redacted source text is absent. Its fixture retains the
  refusal of shared-resource partial redaction and duplicates only its first page's font for the allowed case.
- Another 36 math functions plus TRUNC digit support bring fixed reference agreement to 176/492 (316 gaps).
  Domain/arity/overflow and large-finite-number regressions pass, along with every supported math reference case
  and independent XLSX/ODS recalculation. Workspace: 366 portable passes, one OCR fixture ignored; GNU tests compile.
  Native numeric/error cache and reopen scenarios are extended for the next compatible build.

- Full optimized run 42357299879 passed all workspace MSVC tests, runtime imports and the native suite on 5334878,
  including the added text-formula cache/reopen rows. Incremental run 42357757678 also passed on 25fcb16, including
  math/text numeric/error/text cache types and discard/reopen. These are development artifacts, not public releases.
- New/New Window now starts an independent document/viewer process, retains current unsaved work and forwards the
  language override. PPT exposes New. All six native window lifecycles and dirty DOC parent/child history/save/
  closure are covered by a new audit pending its first compatible build. No autosave/association claim is added.

- Native run 42358211751 passed 3481fb3, including independent windows in all six apps, inherited language,
  two DOC New commands with child history/save and unchanged dirty parent/source, and closing either side without
  terminating the other. The preceding optimized 5334878 run passed 368 MSVC tests with one OCR fixture ignored.
- All six hosts now persist normal/maximized outer placement with validated atomic preferences and paired native
  placement APIs. Fullscreen PPT preserves its original frame. Portable preference corruption/bounds/atomicity
  tests pass; GNU tests compile. Native resize/maximize/restart and synthetic offscreen relocation await a build.
