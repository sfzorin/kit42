# Suite42 status — 2026-11-05

This is a dated snapshot of the local repository after the code/UI audit and documentation review
(date in Europe/Istanbul). Feature usage and commands are in [README.md](README.md); shared UI contracts are in
[DESIGN.md](DESIGN.md). A passing audit covers the scenarios listed here, not every feature or file format.

## Source, builds and publication

- All six apps are present: PDF42, DOC42, XLS42, IMG42, PPT42 and SCN42.
- Local `main` and `origin/main` point to `4d727a6d2c17dc00413851e92666e5cdb31278e4`. The audit fixes,
  regression scripts and documentation updates are still uncommitted working-tree changes. They have not been
  pushed as code changes or published as a release.
- Debug compilation and release packaging completed successfully. Updated bundles are in `build/<App>.app`;
  the initial audit did not replace installed apps. The DOC42 and XLS42 follow-ups below subsequently updated
  `/Applications/DOC42.app` and `/Applications/XLS42.app`; the other installed apps were not replaced by these follow-ups.
- All six bundles pass `codesign --verify --deep --strict`. These are ad-hoc signatures, not Developer ID
  notarization. Bundle metadata remains version **1.0**, build **1**; no version bump was made.
- Verified environment: **macOS 27.0.1 (26A434), arm64, Apple Swift 6.3.1**. The package declares macOS 14 and
  Swift tools 5.9 as its minimums; that minimum environment was not tested in this run.

The GitHub authorship cleanup is already published: AI co-author trailers were removed from 110 commits while
preserving their file trees, author/committer identities, dates and merge topology. Reachable local branches were
remapped to the cleaned history without replacing the index or working files. Author and committer remain
`sfzorin <s.zorin@dannie.cc>`. The owner-only rule is in [AGENTS.md](AGENTS.md).
Local attribution settings also disable generated commit/PR signatures; that ignored configuration is not shipped
by cloning the repository. History backups and the old/new commit mapping are in `build/backups` (local artifacts).

## Changes in the audited working tree

| Area | Current behavior after the fixes |
|---|---|
| Kit42 / previews | Recent-file menus refresh and route through each app's controller. ZIP readers reject malformed lengths, sizes and CRCs; text decoding handles UTF-16 detection; CSV/ODS previews handle quoting and invalid repeat/span values. Language relaunch passes the bundle path without interpolating it into shell code. |
| PDF42 | Parser bounds/nesting and signature byte ranges are checked. Attachment extraction sanitizes filenames and numbers collisions instead of overwriting existing files. |
| DOC42 | Hide All Panels preserves ruler/comment preferences. CLI import recognizes known document extensions before system UTI lookup, so DOCX is read as a document in headless export too. |
| XLS42 | The detailed follow-up below covers working border presets/colours, row/column sizing and Undo, pending-edit lifecycle, protected/array-safe paste and fill, formula bounds and date epochs, sheet references and XLSX/ODS/CSV/PDF round trips. Large sparse clears visit stored cells; dense operations have explicit limits documented in README. |
| IMG42 | Open remains enabled. Resize unit switches preserve pixel dimensions and reject invalid input. DPI participates in save/export and Undo/Redo. Save/Export commits pending text, and Undo after Revert restores it. |
| PPT42 | Notes replacement uses the text editor's undo history and updates the model/view. Failed movie export preserves an existing destination. |
| SCN42 | Dropping before the first page inserts at the start. Rescan keeps its target until processing finishes. Save tracks the exported snapshot; subsequent edits/OCR stay dirty. Closing cannot discard pending scanning/processing and closes after Save only when clean. |

## Verification completed during the audit

The following are historical results of the initial code/UI audit. The detailed DOC42 follow-up is recorded separately below.
Reproduction commands and prerequisites are in [Regression checks](README.md#regression-checks).

| Check | Recorded result and scope |
|---|---|
| Build / packaging | Debug build and all six release `.app` bundles succeeded; bundle signatures verified. |
| `PDF42 --selftest` | 11 groups passed: malformed input, parser/signature bounds and attachment extraction. |
| `XLS42 --selftest` | `ALL PASSED`: formula/reference, precision, file-format and model checks. |
| `SCN42 --selftest` | 7 checks passed: saved revisions, late OCR and export replacement/failure handling. |
| `audit-documents-regressions.swift` | 17 archive/text decoding cases passed. |
| `audit-media-previews.py` | 10 CSV/ODS preview cases passed. |
| `audit-documents-video.py` | 9 checks passed, including successful movie creation/replacement and preservation on failure. |
| `audit-documents-cli.py` | 4 checks passed in debug and the final release DOC42 bundle: Unicode DOCX round trip, demo reopening, and both PDF export entry points. The corrected fixture has 5 readable pages. |
| `audit-ui.py` | 19/19 runs passed: 5 behavioral runs and 14 snapshot runs across all six apps. The 3 PDF snapshot runs were repeated after correcting DOCX fixture import. |
| `check_strings.py` / `git diff --check` | Passed. String coverage is a static check, not visual verification of every translated screen. |

Native behavioral checks include XLS42 selection/formatting/sheet changes and a 100-million-position sparse range;
IMG42 resize/DPI/pending-text scenarios; SCN42 page ordering/rescan/close-save; DOC42 panels (16/16);
PPT42 note replacement with responder Undo/Redo (6/6); and the shared recent menu (8/8).
PPT42 responder checks use native actions, not simulated physical keyboard shortcuts.

Main windows were inspected in light/dark appearances and different sizes. Targeted live inspection covered PDF42,
IMG42 and the XLS42 Format Cells dialog. AppKit's cached-view capture rendered the XLS42 tab strip as black;
the live window showed normal, readable tabs. This was a capture artifact, not a layout defect.
Local UI logs and PNGs are in `build/ui-audit`; generated outputs are ignored by Git.

## Remaining limitations and unverified areas

- IMG42 and SCN42 do not have document recovery autosave. The 30-second AppKit autosave setting belongs to PDF42,
  DOC42, XLS42 and PPT42, and does not guarantee recovery of the latest unsaved keystrokes.
- XLS42 checks at most 100,000 cells per editing operation, including external paste/Paste Special and fill;
  protected or partial-legacy-array destinations are rejected before mutation. Dense formula matrices and CSV
  output rectangles are limited to 2,000,000 positions, ODS import expansion to 1,000,000 materialized cells, and
  bounded statistical/financial loops to 1,000,000 iterations. These are separate resource limits, not a workbook
  size or compatibility guarantee. The former Fill/external-paste array gap was fixed and exercised in the
  [XLS42 detailed follow-up](#xls42-detailed-follow-up--2026-11-05) below.
- PPT42 Find navigates matching objects/notes; Replace All cannot match across formatting runs and individual
  replacement does not edit table cells. Movies render slide states/poster images, without embedded media playback.
- IMG42 codec support depends on macOS. Pixel edits to animated or multi-page inputs export the displayed frame/page;
  they do not rewrite the complete animation/document. SCN42 replaces each output file atomically, not a whole set.
- Scanner tests used generated images and a virtual scanner. Physical scanner drivers, AirScan hardware,
  Continuity Camera, real printing and cross-Mac installation/notarization were not verified in this audit.
- The notarization script currently requires explicit app names. Its no-argument fallback combines the three default
  names into one array element; this was confirmed with an isolated shell-expansion check during documentation review.
  The README command supplies all six names. No signing identity or notarization service was used for that check.
- PDF malformed-data/signature-range tests do not establish complete cryptographic interoperability. Real certificate
  and timestamp-service workflows and PDF/A conformance were not validated. GOST signatures remain unsupported.
- Existing document/presentation format limitations are listed in the respective README sections. This audit did
  not repeat all historical Excel/LibreOffice compatibility comparisons or test every screen in all three languages.

When publishing these changes, update this report with the new commit/release and installation state. Keep local
test results separate from claims about distributed or installed builds.

## DOC42 detailed follow-up — 2026-11-05

The reported ruler failure exposed a gap in the earlier UI audit: a rendered control and a successful panel toggle
do not establish that dragging, editing, Undo or persistence work. The follow-up adds native event/command tests and
complex-document layout scenarios to `scripts/audit-ui.py --app DOC42`.

Changes in this follow-up:

- Added a vertical ruler and separated horizontal margin grips from paragraph-indent markers. Click-only gestures
  preserve values; drags use the correct page/section/column/header geometry, including zoom and an offscreen caret.
  Header editors relayout with the page. Print margins cannot be changed by dragging the web-layout ruler.
- Page setup supports repeated Undo/Redo, rejects unusable measurements, preserves unchanged exact values despite
  rounded centimetre labels, and retains custom paper sizes. Web layout no longer leaks synthetic geometry into
  saved sections or page-setting commands. Header commands target the header's section.
- Clear Formatting preserves embedded content and document structure. Formatting, styles, borders and link removal
  target the active text editor. Body-only structure commands are disabled while editing a header/footer.
  Inherited character styles, paragraph-style underline and its Undo/Redo, whole-word/regex replacement, and
  table-selection endpoints were corrected.
- Pending header/footer edits participate in save/export and the unsaved-document check. Unchanged header editing
  stays clean; Revert replaces saved styles and metadata and discards pending header text. Page-number toggles preserve
  first/even-page headers. RTF explicitly writes paper size and all four margins instead of relying on omitted defaults.
- PDF page ranges reject invalid or empty results and bound very large endpoints to existing pages. GUI export writes
  atomically. Export layout uses independent text storage and field-result caches, preserving the open editor's
  layout managers and field values. Malformed ODT annotation space counts are bounded.
- Complex-document book/column scenarios reproduce pagination defects that were absent from the earlier simple-window
  checks. Page and column mutations are protected against recursive layout callbacks; final container layout is
  completed before returning pages for display/export. Tests check all laid-out character/glyph ranges, growing and
  shrinking text, and deletion of sixteen sections. Their regression snapshots are part of the DOC42 runner.
- Dynamic fields repaint changed values without restarting layout when their width is unchanged. When width changes,
  the containing paragraph/table is recalculated using the field's last measured frame, including when drawing has
  already updated its displayed-value cache. This fixes a repeated-layout hang in the rich document fixture.

Final follow-up results:

| Check | Result |
|---|---|
| Native DOC42 assertions | **266/266**: panels 16, rulers 99, editing 75, document lifecycle/export/fields 60, pagination 16. Shared recent-file menu: another **8/8**. |
| `python3 scripts/audit-ui.py --app DOC42` | **10/10 runs**: five behavioral runs plus light, dark, book, columns and web snapshots. |
| `python3 scripts/audit-documents-cli.py` | **4/4** in both debug and the final release bundle; the generated demo has 5 readable PDF pages and 5,359 counted characters. |
| Additional TOC check | Changing to two columns and invoking Update completed successfully; the captured result has leaders and page numbers aligned inside each column. |
| Debug / release packaging | DOC42 compiled and `./build.sh DOC42` produced the release bundle; `codesign --verify --deep --strict` passed. |
| Static checks | `check_strings.py` and `git diff --check` passed. |

The original suite-wide results above remain historical evidence. Physical keyboard/mouse input, real printing and
exhaustive third-party interoperability are outside this automated/native-event check. The column snapshot preserves
the fixture's original fixed tab stops; an existing table of contents needs Update after changing column width.
Web mode retains explicit breaks and the status bar can therefore show multiple text containers even without paper edges.

The checked release bundle was installed at `/Applications/DOC42.app` on 2026-11-05. Its previous bundle is retained
locally at `build/backups/DOC42-before-update-20261105-133916.app`. The installer did not terminate the running app or
close user documents: save open work and fully quit/reopen DOC42 to load the new executable. Source/docs remain local,
uncommitted changes; no new code release or push was made during this follow-up.

## Design pass — 2026-11-05

Uncommitted working-tree changes (not published). XLS42 was updated later the same day at the owner's request
(trimmed toolbar, subtitle "Sheet · A1", neutral sheet tabs, "Export as PDF" label, British "Centre").

- Toolbars: `ToolbarController(optional:)` keeps rarely used items in Customize Toolbar only; identifier suffix
  `.3` → `.4`, so saved toolbar layouts reset once in all apps. DOC42 default drops Footnote, Track Changes, Zoom,
  Print, Export as PDF; SCN42 drops Overview, Delete, Enhance.
- DOC42: subtitle shows "Page X of Y" (plus Tracking changes); the status bar shows counts only. Moving the find bar
  above the rulers was tried and reverted: with a custom `NSTextFinderBarContainer`, NSTextFinder installed the bar
  view but never set it visible (traced), so the bar stays in the document scroll view as before.
- Labels: PDF42/DOC42 "Signature" → "Stamp" (RU «Факсимиле», TR «Kaşe»); PDF42 "Sign" → "Sign Digitally"
  (RU «Подписать ЭП»). British spelling outside XLS42: SCN42 colour mode "In colour / Grey / Greyscale",
  "Align Centre", "Centre"; IMG42 markup tooltips in sentence case.
- Visuals: strip group outline is a `labelColor` 8 % hairline; PPT42 inspector tabs are all icons with tooltips;
  PDF42 thumbnails are a single column with an accent ring; IMG42 filmstrip selection is an outline; IMG42 All Metadata
  is collapsible (collapsed by default); SCN42 Scan button uses the system accent.

Verified: debug builds of PDF42, DOC42, PPT42, IMG42, SCN42 compile; `scripts/audit-ui.py --app` passed for
DOC42 (10/10, including rulers, panels, editing, pagination), PDF42 3/3, PPT42 3/3, IMG42 3/3, SCN42 3/3; light/dark
snapshots inspected for DOC42, PDF42, PPT42, SCN42.
Not verified: the IMG42 metadata disclosure
and filmstrip outline by snapshot; XLS42 audit; `audit-documents-cli.py` (no import/export changes).
Known gaps: the PDF42 search field collapses to an icon at the audit window width because of the longer
"Sign Digitally" label; SCN42's page sidebar still uses a filled selection; the XLS42 items from the review
were applied later (see below).

## Signature and stamp generator — 2026-11-05

Uncommitted. Kit42: `SignatureGenerator` + `PenAlphabet` (kinematic ballpoint signatures, 240 styles, six forms),
`SealGenerator` + `SealCatalog` (132 templates in 15 categories, layout families), `InkRendering` (seeded random,
ink texture), `GeneratedMarks` (JSON recipes, imported stamp sources in `Stamps/Sources`, `MarkSamples`),
`MarkGenerator` (window with form/category/style, dynamic fields, `InkColorPopUp`). The shared library popover gains
Create Signature… / Create Stamp…; Add to Library… imports SVG/PDF/images as a stamp (new impression each insertion)
or as a fixed picture. Available wherever the popover is (PDF42, DOC42, IMG42, PPT42, XLS42).

- Signatures: smooth centripetal spline through hand-drawn centre lines, corners swept without stops, low-pass
  filtered path, speed from curvature (two-thirds power law) → width and ink, flying starts/finishes. The design seed
  fixes the style; the impression seed varies via-points (±1.8 % of the capital), size ±4 %, slant and angle ±2°,
  pressure, ink shade, skips, blobs. Earlier font-skeleton version and the prototype are superseded.
- Stamps: generic designs only (no state emblems; no notary, court, customs, police or prescription seals). Tilt per
  impression: round 2–8°, rectangular 0.3–2°, office stamps 1–7°; pad pressure, grain, gaps, optional double strike.

Verified 2026-11-05: debug builds of all six apps; `PDF42 --mark-samples` (222 PNGs: 5 forms × 4 names × 4 copies,
132 templates plus extra impressions, an imported SVG ×3) inspected visually. `audit-ui.py`: PDF42 6/6 (samples,
generator window for signature and stamp), DOC42 10/10, XLS42 4/4, IMG42 3/3, SCN42 3/3; PPT42 6/7 — `ppt-files`
fails 2 of 20 lifecycle checks ("Revert discards pending notes undo transaction", "Revert clears the notes-page
local Undo stack") in another agent's new, uncommitted PPT42 notes-undo work, not in code touched here.
Not exercised in the live app: inserting a generated or imported mark into a document, the Add to Library
round trip with a real SVG/PDF file chosen in the open panel, the custom colour panel, release-build timing.

## Ink layering — 2026-11-05

Signatures and stamps now blend like ink (multiply): text under them stays dark, overlapping inks darken each other,
and the order of layers hardly matters. PDF42 `ImageStampAnnotation` draws with multiply (the saved appearance
stream carries `/BM /Multiply`, checked in a reopened file; this also applies to images from Image from File…);
IMG42 image marks multiply; DOC42 inserts a stamp or signature as one undoable step, floating in front of the text
at the caret (`DocImage.ink`), multiplied on screen (layer compositing filter) and in export (drawn after the text).
`PDF42 --mark-overlay DIR` writes before/after renders of a saved and reopened page.

Verified: `audit-ui.py` DOC42 10/10, PDF42 6/6, IMG42 3/3; `audit-documents-cli.py` 4/4; `--mark-overlay` renders
inspected. Not verified: the DOC42 floating stamp on screen and in its PDF export with a real insertion (no audit
scenario inserts one); DOCX keeps the stamp in front of the text but not the multiply flag.

## Signature variation and smoothness — 2026-11-05

- Line flicker removed: speed (and so width and ink) is estimated from curvature over about 4 % of the capital height
  and smoothed over twice that, instead of neighbouring 1-px samples; the path low-pass grew to ~3 % of the capital.
- Copies differ more, smoothly: size ±7 %, slant ±4.5°, angle ±3.5°, width ±6 %, a low-frequency drift of the whole
  hand, each letter shifted (±0.04 cap) and scaled (±7 %) as a whole, garland heights ±18 %, exit and flourish
  control points moved; per-point noise reduced to ±0.8 %.
- Styles: 1320 (10 plans × 11 flourishes × 4 capital variants — as drawn, lead-in loop, simplified, tall — × 3 joins).

Verified: PDF42 debug build, `--mark-samples` sheets inspected (smooth at 100 %, four copies per style visibly
different). `audit-ui.py --app PDF42` 6/6 (samples, generator windows).
