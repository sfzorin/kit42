# Suite42 status — 2026-11-06

This report records dated source, build and UI verification evidence (dates in Europe/Istanbul).
Earlier sections retain the scope of their original snapshots; later results supersede them only where stated. Feature usage and commands are in [README.md](README.md); shared UI contracts are in
[DESIGN.md](DESIGN.md). A passing audit covers the scenarios listed here, not every feature or file format.

## Latest GitHub publication — 2026-11-06

The integrated source is published in `sfzorin/kit42` on `main`:
[`5e50cc58acfa75db02728ec1e3caa487f7b8df1b`](https://github.com/sfzorin/kit42/commit/5e50cc58acfa75db02728ec1e3caa487f7b8df1b).
GitHub's API confirmed that exact commit after the push. It contains twenty interface languages (3,003 source keys),
the latest PDF/IMG fixes and regressions, and updated README, DESIGN, STATUS and verification instructions, on top of
the already published PAdES/CSC/GOST and signature-learning work. Repository About text was updated and read back
from GitHub. Author and committer are `sfzorin <s.zorin@dannie.cc>`; no co-author trailers were added.

This is a source publication. Verified local packages are ad-hoc signed, remain version 1.0/build 1 and were not
uploaded as a downloadable/notarized release. Installed snapshots documented below retain their separate binary
identities. The original shared working checkout was preserved; integration and publication used an isolated worktree.
Final validation evidence is in [Integrated publication build](#integrated-publication-build--2026-11-06).

## Earlier source, build and publication checkpoints

- All six apps are present: PDF42, DOC42, XLS42, IMG42, PPT42 and SCN42.
- During the PPT42 follow-up, concurrent work created merge commit `85b6df66964f867353f96251619aa2b85af51ccf`
  (including `00cf48e726c0c47f58fc58255ce7518229d824de`). At that audit checkpoint, local `main` and the cached `origin/main` pointed there.
  It includes the DOC42/XLS42/PPT42 audit source changes. Both commits attribute author and committer only to
  `sfzorin <s.zorin@dannie.cc>`. The final report corrections and UI runner `--binary` option were local changes at that checkpoint.
  This audit did not perform those Git operations or verify a GitHub release; local installation evidence is below.
- Debug compilation and release packaging completed successfully. Updated bundles are in `build/<App>.app`;
  the initial audit did not replace installed apps. The DOC42, XLS42 and PPT42 follow-ups below subsequently updated
  `/Applications/DOC42.app`, `/Applications/XLS42.app` and `/Applications/PPT42.app`; the other installed apps were not
  replaced by these follow-ups.
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
| PPT42 | The detailed follow-up below covers native canvas actions, effective inspector borders/fills, grouped and table text, Find/Replace, media-safe paste, master appearance, draft/notes/outline lifecycle, file round trips and complete notes output. |
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
- PPT42 Find/Replace now visits individual occurrences and table cells and can replace across formatting runs.
  Movies still render slide states/poster images without embedded media playback. Table dash patterns and table text
  autofit remain unsupported; the on-screen Notes Page previews the first page, while PDF/printing paginate full notes.
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
close user documents: save open work and fully quit/reopen DOC42 to load the new executable. At the completion of that
DOC42 follow-up, source/docs remained local and uncommitted. The later concurrent merge
listed above now includes those changes; it is separate from the checked local installation.

## Design pass — 2026-11-05

This design snapshot was uncommitted when recorded and was later included in the concurrent merge listed above.
XLS42 was updated later the same day at the owner's request
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

Source included in the concurrent merge listed above. Kit42: `SignatureGenerator` + `PenAlphabet` (kinematic ballpoint signatures, 240 styles, six forms),
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
generator window for signature and stamp), DOC42 10/10, XLS42 4/4, IMG42 3/3, SCN42 3/3. That intermediate PPT42
run was 6/7, with two lifecycle failures. They were fixed and the final debug and release runs below passed 7/7;
the follow-up records the corrected Undo fixture and Notes Page refresh.
Not exercised in the live app: inserting a generated or imported mark into a document, the Add to Library
round trip with a real SVG/PDF file chosen in the open panel, the custom colour panel, release-build timing.


## XLS42 detailed follow-up — 2026-11-05

This follow-up completed before the PPT42 audit; its source changes were subsequently included in the concurrent
merge listed above. The verified XLS42 bundle was installed locally. The README scenario matrix describes tested
workflows; no usage percentage or full Excel compatibility was measured.

- Format Cells None, Outline and All act on the whole selection, preserve unchanged mixed/imported borders, and
  apply inner/outer colour and width. Native dialog actions, Undo/Redo and XLSX/ODS reopen are exercised. Double borders
  draw two strokes; four bitmap-profile assertions distinguish horizontal/vertical Double from single Thin/Thick lines.
- Row/column resizing uses native header events and Undo/Redo. Row Autofit grows and shrinks wrapped rows, respects
  protection and is undoable. Font/background colour choices turn off Automatic/No fill.
- Pending edits participate in dirty state and Save; invalid drafts stop Save/Print/sheet changes without losing text.
  Failed typed reads retain the old document/draft; Revert discards drafts and resets invalid active-sheet state.
- Clipboard/Paste Special preserve quoted text and formula/array semantics. Writes preflight worksheet bounds,
  protection and partial legacy arrays. Whole-array replacement updates metadata in the same Undo transaction.
  Fill, Replace, sort, duplicate removal, Text to Columns and Filter Copy have focused boundary regressions.
- Formula fixes cover sparse aggregates, explicit blank range tails, array ROW/COLUMN, numeric conversion/loop bounds
  and date epochs. Rename/copy updates supported formulas, names, validation, conditional, chart and internal-link
  references, including self-references and names with apostrophes, case changes and emoji.
- XLSX/ODS/CSV round trips preserve formula-like literal strings, styled/unlocked blank cells, names, print areas and
  XML whitespace. Malformed indices/repeats/spans/types are rejected. Large dense operations have the README limits.
  PDF scope excludes hidden sheets, selection scope is bounded, very wide sheets fit width, and oversized repeated
  title areas cannot consume the body.

| Check | Recorded result |
|---|---|
| Debug build and selftest | PASS; `ALL PASSED`, 492/492 function values; deep files 66/66, formulas 130/130, sheet references 61/61 |
| Native UI | **4/4 runs, 300/300 assertions**; includes deep editing 68, common UI/lifecycle/output 53 and sheet references 7 |
| Light/dark and Format Cells snapshots | Visually inspected; cached tab-strip compositing artifact documented separately, native tab controls exercised |
| Debug and packaged CLI | **6/6 PASS in each**, no skipped PDF checks; `build/xls-cli-audit/result.json` and `build/xls-cli-audit-release/result.json` |
| Packaged selftest/signature | ALL PASSED; ad-hoc signature verified before and after installation |

Native copy/paste scenarios use `K42_PASTEBOARD=1` to isolate the native pasteboard. A shared-pasteboard run was
intermittent; interaction with external clipboard managers remains unverified. Tests cover generated fixtures,
not every Excel/LibreOffice feature, external file corpus, locale or physical printer.

Final installed binary at `/Applications/XLS42.app`:
`b1e38a12fa3ae1e066b95aa05a2f9d2b62e47bf89ad974916170311178e3ec31` (version 1.0 / build 1).
The original installed bundle is retained as `build/backups/XLS42-before-update-20261105-200036.app`; the intermediate
checked bundle as `build/backups/XLS42-before-update-20261105-201058.app`. Record: `build/xls-deep-install.json`.
No running app or open document was closed. Logs: `build/xls-deep-*.log`, `build/ui-audit/xls-ui.log`, and the CLI reports.


## PPT42 detailed follow-up — 2026-11-05

The source fixes were included by concurrent work in merge `85b6df6` while this audit was running. The final report
and packaged-binary UI runner option remain local changes. The checked PPT42 bundle was installed locally.
The README scenario matrix defines the exercised common workflows; this is not a measured claim of
95% PowerPoint compatibility or usage coverage.

### Functional corrections and evidence

- Inspector fill/line controls now change the actual table and grouped-child styles and show the applied values.
  Table borders change both inner and outer rendered lines; No Fill stores explicit transparency rather than falling
  back to the header theme. Native controls are checked with strict rendered-pixel assertions, Undo/Redo and PPTX/ODP
  reopen. Unsupported table dash/autofit controls are disabled. Invalid/nonfinite geometry is rejected without a mutation.
- Returning from Master view re-enables slide transitions. Master/layout placeholder commits retain shadow, opacity
  and rounded-shape adjustments; native controls, Undo/Redo and PPTX reopen verify these settings.
- Group flips render correctly, and Ungroup preserves reflected child geometry. Canvas mouse/key scenarios cover
  dragging, resizing, rotation, snapping, cancellation, selection, ordering and arrangement. Slide moves sanitize stale
  or duplicate indices; duplicated/pasted objects have distinct IDs. Object changes commit visible in-place text first.
- Cross-document paste remaps colliding embedded-media names in images, picture fills and media clips. Objects and
  imported media form one Undo transaction, with selection restored on Redo. Image caching compares the complete bytes,
  preventing a different same-size image with an identical header from showing stale pixels.
- Find navigates individual occurrences, including table cells. Replacement spans formatting runs, preserves surrounding
  formatting and dynamic fields, and uses the first matched character's formatting for inserted text. Formatting reaches
  nested groups and tables, edited-cell vertical alignment and empty paragraphs. Row/column changes preserve surviving
  merged anchors, their contents and valid spans.
- In-place and outline drafts participate in dirty state. Save flushes visible text and pending outline typing before
  serialization; unchanged text creates no document Undo. Failed Revert preserves the draft/model/selection. Successful
  Revert cancels delayed outline edits and clears document and local editor Undo. Notes editors clear obsolete history
  on slide changes. Restoring a selected slide refreshes its Notes Page, inspector, format bar and title.
- PPTX rejects missing referenced slides instead of silently dropping them. ODP rejects invalid types/repeats/spans and
  bounds expansion. Text and notes preserve authored whitespace, CR/LF/tab and ODP inline breaks; table-border width and
  colour survive round trips. Image allocation validates dimensions and pixel count before rendering.
- Notes PDF and printing paginate the complete text, including long notes and portrait slides; the on-screen preview
  remains the first page. Export honors hidden-slide scope. Failed outputs preserve existing files in the tested paths.
  MOV uses a QuickTime container, MP4 its own container. Movie export still renders states/poster images without embedded
  audio/video playback.
- Show startup runs the first automatic animation group, and stale delayed callbacks cannot reveal a build after
  navigation. Native show checks also cover click builds, hidden slides, black screen and Previous/End.

### Completed checks

| Check | Observed result |
|---|---|
| `swift build --product PPT42` | PASS; `build/ppt-deep-build.log` |
| Debug and packaged release `PPT42 --selftest` | **57/57** in each binary; `build/ppt-deep-selftest.log` and `build/ppt-deep-release-selftest.log` |
| Native UI, debug and packaged release | **7/7 runs PASS in each**; **167/167** assertions: notes 6, editing 48, text/table/show 43, lifecycle 20, inspector 50; shared recent menu another 8/8. Release command: `python3 scripts/audit-ui.py --app PPT42 --binary build/PPT42.app/Contents/MacOS/PPT42` |
| Debug and packaged release `audit-presentations-cli.py` | **8/8 PASS in each**, no skips; PPTX→ODP→PPTX, POTX/OTP, visible/all-slide PDFs, complete notes, images, failure preservation and MP4/MOV containers |
| Light/dark snapshots | Generated and visually inspected; readable canvas, sidebar, format bar, notes and inspector at both audit sizes |
| Release build and signature | `swift build -c release --product PPT42` PASS; packaged with Info.plist/icon and an ad-hoc signature; `codesign --verify --deep --strict` PASS before and after installation |
| Static checks | `git diff --check` PASS. String coverage passed before packaging; the final whole-repository rerun reports one new missing DOC42 translation (`Signature or Stamp`) in concurrently edited `DocWindowController.swift`, with no PPT42 diagnostics. See `build/ppt-deep-strings.log`. |

Native tests dispatch AppKit controls, mouse/key events and text-editor actions in isolated audit app bundles; clipboard
scenarios use a private native pasteboard. They do not establish every physical shortcut, external clipboard-manager
interaction, multiple physical displays, media playback under load, physical printing, exhaustive malformed-input safety
or full interoperability with Office/LibreOffice. The independent CLI suite inspects generated artifacts: visible PDF
2 pages, all-slide PDF 3 pages, complete-notes PDF 7 pages, image scope and 320×180 dimensions, and both movie containers.

During iteration, the harness was corrected to use explicit event Undo groups where AppKit normally supplies them,
without wrapping no-op checks in empty groups. Master appearance fixtures target editable placeholders. Pixel assertions
read the renderer's sRGB samples directly to avoid a second AppKit colour-profile conversion. Expected behavior, pixel
thresholds and no-op/Undo assertions were retained; the final results above are from the corrected harness and fixed app.

Logs and images are in `build/ppt-deep-*.log`, `build/ui-audit/ppt-*.log` and `build/ui-audit/screenshots`. The debug CLI
report, binary SHA-256 and output fixtures are in `build/ppt-cli-audit/result.json` and
`build/ppt-cli-audit-release/result.json`. Debug UI logs are retained separately in `build/ppt-debug-ui-audit` and
`build/ppt-deep-debug-ui-run.log`; the final `build/ppt-deep-ui-run.log` and canonical UI logs are from the release binary.
The UI runner now accepts `--binary` with `--app`, so future audits can check the packaged executable directly.

The verified bundle was installed at `/Applications/PPT42.app` on 2026-11-05. Previous bundle:
`build/backups/PPT42-before-update-20261105-204442.app`. The installed binary SHA-256 is
`2659dfefdb63e6e000985a59c407ca6c892eafdf82e9beb6e09906bafcfd5a69`; metadata remains **1.0 / build 1**.
The installation record is `build/ppt-deep-install.json`. No running app was terminated and no user document was closed;
save open work and fully quit/reopen PPT42 to load the new executable. This local ad-hoc installation is not a published
or notarized release.

The source hash manifest used for the release is retained in `build/ppt-deep-source-manifest.json`. Concurrent work
continued after packaging (`Kit42/DocxWriter.swift` changed); those later edits are not part of this checked binary.
The installed/package/CLI-tested executable hashes match; the final native UI run used this same release executable.

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

## PDF42 PAdES baseline levels and CSC remote signing — 2026-11-06

What changed: PDF42 signs as PAdES B-B / B-T / B-LT / B-LTA (ETSI.CAdES.detached; CMS built in `CAdES.swift` with
content-type, message-digest and signing-certificate-v2, no signing-time) or the legacy adbe.pkcs7.detached. B-LT adds
a DSS (/Certs, /OCSPs, /CRLs, /VRI) with validation data fetched from AIA/CRL URLs for the signer and TSA paths;
B-LTA adds an ETSI.RFC3161 document timestamp and then extends the DSS for the timestamp's TSA. New commands: Signature ›
Enable Long-Term Validation, Signature › Add Document Timestamp; Sign dialog Format menu (default B-LTA) and Remote
(CSC)…; CLI `--sign … level=…`, `--ltv`, `--doc-timestamp`, `--csc-credentials`, `--csc-sign`. `--verify` and the
verification cards report document timestamps (imprint checked against the covered bytes), the PAdES level and the
LTV status. CSC API v2 client: info, auth/login, OAuth 2.0 (authorization code + PKCE on a loopback redirect,
client credentials), credentials/list|info|authorize|sendOTP, signatures/signHash; only the hash is sent.

Verified (debug build of this worktree, macOS 27.0.1 arm64):
- `swift build` (whole package) passes; `PDF42 --selftest` 15/15 groups (4 new: OID/DER encoding, a PAdES B-B
  signature with an in-memory key — subfilter, signing-certificate-v2 hash, no signing-time, tamper → invalid, legacy
  subfilter —, incremental stream round trip incl. FlateDecode, CRL revocation coverage); `scripts/check_strings.py`
  reports no PDF42 problems (one pre-existing DOC42 string remains).
- External validator: **EU DSS 6.3** (the library behind the EU DSS demo webapp), run locally and **offline** — no
  OCSP/CRL/AIA fetching, so only data embedded in the PDF counts; trust anchors = macOS system roots + a test root.
  `scripts/pades/run.sh WORKDIR` reproduces it with a throw-away PKI (root → issuing CA → signer, OCSP responders and
  CRLs on localhost). Results: B-LT → `PAdES-BASELINE-LT TOTAL_PASSED`; B-LTA → `PAdES-BASELINE-LTA TOTAL_PASSED`;
  B-T signed then Enable LTV → LT TOTAL_PASSED, then Add Document Timestamp → LTA TOTAL_PASSED; CSC-signed B-LTA →
  LTA TOTAL_PASSED; B-B / B-T → format BASELINE-B / BASELINE-T, INDETERMINATE (no revocation data offline, as
  expected); legacy → PKCS7-T; a one-byte change → TOTAL_FAILED/HASH_FAILURE and the document timestamp's imprint
  not intact. TSAs used: DigiCert (default) and Sectigo, both with the same results.
- CSC: tested only against `scripts/pades/csc_mock.py` (local mock of the v2 endpoints, signing with the test key):
  HTTP Basic, client credentials (wrong secret → `invalid_client`), explicit PIN+OTP (wrong PIN → error), and the
  browser flow for an `oauth2code` credential (service-scope then credential-scope authorization code with PKCE;
  the mock checks the verifier, redirect URI and that the token covers exactly the signed hash). The signHash request
  body was 185 bytes: credential ID, algorithm OIDs and one SHA-256 hash.

Not verified / limitations:
- The EU DSS demo website itself was not used (uploading files to it was not permitted in this session); the same
  DSS library was run locally instead. No EU trusted lists were loaded, so qualification is `NA`.
- In that DSS run the timestamps themselves stay INDETERMINATE (`The ResponderId does not match the OCSP issuer
  certificate`, `Unable to build a certificate chain up to a trusted list`) for both DigiCert and Sectigo even though
  the responder key hashes match their CA keys; DSS still accepts them for the LT/LTA signature result. Not resolved.
- No public CSC sandbox without an account was found (SSL.com eSigner needs a sandbox registration; BankID's
  pre-production endpoint publishes no test credentials), so no real QTSP was contacted. The mock shares PDF42's reading of the spec.
- The Sign dialog's new Format menu, the Remote (CSC)… dialogs and the two new Signature menu commands were not
  exercised in the UI (no `audit-ui.py` scenario covers signing); Acrobat was not used to check "LTV enabled".
- Not installed into /Applications; not published.
## GOST signatures with CryptoPro CSP — feasibility — 2026-11-06

Goal: ГОСТ Р 34.10-2012 qualified signatures in PDF42 on macOS through the user's own CryptoPro CSP, with no
bundled GOST cryptography. CryptoPro PDF exists only for Windows and Kontur.Krypto has no macOS client, so
this is an open gap on the Mac.

What CryptoPro CSP 5.0 provides on macOS (from CryptoPro's macOS install guides and published command references;
**not yet observed on this machine**: CSP was not installed during this work, see the implementation section):

- A macOS installer (`.dmg`/`.pkg`) that installs into `/opt/cprocsp`. The command-line tools are
  `/opt/cprocsp/bin/cryptcp` (CMS sign/verify), `/opt/cprocsp/bin/certmgr` (certificate stores),
  `/opt/cprocsp/bin/csptest` (key containers) and `/opt/cprocsp/sbin/cpconfig` (licence/configuration). The PKCS#11
  module is `/opt/cprocsp/lib/libcppkcs11.dylib`.
- Containers on disk (`HDIMAGE`) and on tokens (Rutoken, JaCarta since CSP 5.0). The personal store `uMy` links certificates
  to containers (`PrivateKey Link`). `cryptcp -sign -detached -der -thumbprint <SHA-1>` writes a detached CMS
  (CAdES-BES with `-cadesbes`, CAdES-T with `-cadest -cadestsa <url>`). `cryptcp -verify -verall -detached <data> -f <sig>`
  verifies it, and `[ErrorCode: 0x00000000]` in the output means success.

Chosen route: the `cryptcp`/`certmgr`/`csptest` command-line tools. PKCS#11 would only give raw signatures:
PDF42 would have to build CMS/CAdES itself and implement chain and revocation checking itself, which CSP already does.
Apple's Security framework has no GOST algorithms, so GOST CMS cannot be verified with `CMSDecoder`.
PDF42 parses GOST CMS and certificates (DER) itself only to display the signer (name, SNILS, INN, OGRN) and to
check the power of attorney; every cryptographic operation goes through CSP.

Licensing and distribution:

- CSP is not redistributed. Users download it from cryptopro.ru (registration required) and install it with
  administrator rights. A fresh install runs under a 90-day trial licence; after that a purchased serial number is
  needed (`cpconfig -license -set`). Whether verification keeps working after the trial expires is not verified.
- `cryptcp` is part of the CSP distribution, but CryptoPro has historically licensed some `cryptcp` uses separately;
  confirm the terms with CryptoPro before commercial distribution of PDF42 with this feature.
- Test certificates: the CryptoPro test CA for GOST 2012 is at `https://testgost2012.cryptopro.ru/certsrv`.
  It issues certificates for requests made by `cryptcp -creatrqst`; they are valid only for a short time and have no legal
  force, and its root must be installed into `uRoot`. CryptoPro sites present a TLS certificate from the Russian
  Минцифры root, so macOS `curl` rejects them unless that root is trusted (observed here).

## GOST signatures with CryptoPro CSP — implementation — 2026-11-06

Local branch `claude/vigorous-rubin-627576`; not merged, pushed or released.

Implemented in PDF42 (details in [README.md](README.md#pdf42--pdf)):

- `Sources/Kit42/DER.swift`: a read-only DER/BER, X.509 and CMS SignedData parser. It extracts the signer, signing time,
  algorithms and the SNILS/INN/OGRN attributes for display and power-of-attorney matching; it performs no cryptography.
- `Sources/PDF42/CryptoPro.swift`: CSP detection and installation help; `certmgr -list`/`-export` for the
  certificate picker (English and Russian labels); `csptest -keyset -enum_cont` for containers and
  `certmgr -inst -cont` to install a container's certificate; `cryptcp -sign -detached -der` with `-cadesbes`, or
  `-cadest -cadestsa`; and `cryptcp -verify -verall -detached … -f sig`. A second `-nochain` run tells
  "untrusted certificate" apart from "changed document".
- PDF signing: `PDFSigner.Signer` is a Keychain identity or a CryptoPro certificate. GOST signatures reserve 40 KB for
  CMS and set `/Filter /CryptoPro#20PDF`. Verification sends GOST CMS (by OID, or the CryptoPro PDF filter) to
  CSP; without CSP the status is "not checked".
- МЧД (`PowerOfAttorney.swift`): EMCHD_1 and format 002 XML. The МЧД is embedded before signing as an incremental update and
  checked on verification (dates, representative SNILS/INN, principal INN, the МЧД's own signature through CSP).
  When a PDF has several signatures, it is applied to the representative's signatures.
- UI: GOST certificates and PIN in Sign Document, an МЧД picker, Signature › CryptoPro CSP… / Sign Any File with GOST (.sig)… /
  Verify Detached Signature (.sig)…, and a banner for unchecked GOST signatures and МЧД mismatches. Strings are in RU/TR.

Verification on this machine (macOS 27.0.1 arm64, debug build):

| Check | Result |
|---|---|
| `swift build` (all products) | Passed. |
| `PDF42 --selftest` | 15/15 groups passed. 4 are new: the TC 26 reference GOST 2012 CMS (`signed_a111`, 512-bit signer) is parsed with its signer, signing time and Streebog-512 OID; a PDF with that CMS and no CSP gives `notChecked`; `certmgr` output is parsed with English and Russian labels; МЧД fields and expiry are read. |
| `audit-gost-cli.py` (stand-in CSP) | 24/24 passed: status, certificate and container listing, wrong PIN, detached `.sig` sign/verify/tamper/untrusted chain. МЧД cases: both formats, windows-1251, another representative, expired, the МЧД's own signature. PDF cases: sign with an embedded МЧД, a counter-signature keeping the first valid, tampered content, no CSP. |
| `--gost-verify` on the TC 26 vectors `signed_a111`/`signed_a121` (no CSP) | Signer, issuer, validity and the 256/512 algorithm shown; exit 3 (not checked). |
| RSA `.p12` `--sign`/`--verify` | Unchanged: a self-signed certificate is reported intact but untrusted. |
| `audit-ui.py --app PDF42` | 5/6. `mark-samples` hit the script's 60 s timeout; run alone, it succeeded (222 files) in 66 s on this debug build. That is the signature generator's workload, untouched here. Main window light/dark, properties and generator windows passed. |
| `check_strings.py` | No new problems; the one remaining (DOC42 "Signature or Stamp") predates this change. |

**Not verified — no real CryptoPro CSP was available.** CSP was not installed, installing it needs administrator rights
and a cryptopro.ru account, and this work had neither. So **the task's done-criterion (a test-CA certificate signs and
verifies a PDF and a detached signature end to end on a real CSP install) is not yet met.**
The stand-in tools (`scripts/fake-cryptopro`) imitate `cryptcp`/`certmgr`/`csptest` with OpenSSL RSA. They exercise
PDF42's own code paths, not GOST cryptography or CryptoPro's actual option names and output. Still to confirm on a
Mac with CSP 5.0 and a test-CA certificate:
`python3 scripts/audit-gost-cli.py --real --thumbprint <SHA1> --pin <PIN> --snils <SNILS>`. That run confirms the
`-cadesbes`/`-cadest` options, the `certmgr -export` and `csptest -enum_cont` syntax, the chain/`-nochain` error codes,
and PIN entry without `-pin` (stdin is closed; CSP may need its own PIN dialog).
Interoperability of the signed PDF with CryptoPro PDF in Acrobat (Windows) and with the FNS/Госуслуги `.sig` checkers is
also unverified. The Sign Document dialog with GOST entries was compiled but not opened on screen; the PDF42 UI audit
does not cover the signing dialog.

## Merge of PAdES/CSC and GOST signing — 2026-11-06

Branches `claude/quizzical-hofstadter-14a456` (01b28ec) and `claude/vigorous-rubin-627576` (3445ffe) merged into
main. Both had reworked `PDFSigner.Options`; the merge unifies them: `PDFSigner.Signer` is `.keychain`,
`.cryptoPro` (GOST), `.remote` (CSC) or `.none` (set `Options.remote` later); `identity`, `remote` and
`signerName` remain as accessors. Keychain and CSC signers use the PAdES level from the Format menu; GOST signatures
keep CryptoPro's format (`/Filter /CryptoPro#20PDF`, adbe.pkcs7.detached with CAdES, timestamp added by CSP) and skip
the PAdES level check. The Sign dialog offers Keychain, GOST and CSC certificates together, with PIN, МЧД, Format,
timestamp and TSA rows; verification reports PAdES level/LTV and МЧД findings side by side.

Verified on the merged tree: `swift build` (whole package); `PDF42 --selftest` 19 groups, 0 failures;
`scripts/audit-gost-cli.py` 24/24 (fake CSP: plumbing only); `scripts/pades/run.sh` with EU DSS 6.3 offline —
B-LT and B-T→LTV → PAdES-BASELINE-LT TOTAL_PASSED, B-LTA, T→LTV→document timestamp and CSC B-LTA →
PAdES-BASELINE-LTA TOTAL_PASSED, tampered → TOTAL_FAILED/HASH_FAILURE (timestamps INDETERMINATE as before).
Not verified after the merge: the combined Sign dialog on screen, a real CryptoPro CSP, a real CSC provider.

## PDF42 detailed follow-up — 2026-11-06

Deep PDF42 audit completed on the logged-in macOS desktop. The final packaged executable, CLI-tested executable,
native-UI-tested executable and installed executable have the same SHA-256:
`ae7a746f062a73d62ad8e34c3ad08e9ba071bd74c4f86c1e127efd6b6a15ff17`.
This is a local ad-hoc installation, not a published or notarized release. No commit or push was made for this audit;
the PDF42 changes remain local relative to `2e227ca`. Other work in the shared checkout was preserved.

### Functional corrections

- Selected shapes, ink and widgets now accept border-width changes with Undo/Redo. Colour controls reflect the
  effective selection; colour Undo retains alpha. Ineffective border/recolour commands are disabled for unsupported
  annotations. Escape and tool changes roll back unfinished drawing, movement and resizing. Deletion Undo restores
  annotation stacking. Form tools target widgets without moving unrelated markup; tall image stamps fit on the page.
- In-place text reads the active native editor, participates in dirty state and commits before Save/export/Print.
  Unchanged edits remain clean. Moving edited text retains its original source cover. Failed Revert keeps the model
  and draft; successful Revert replaces model/view together and clears obsolete Undo. Existing checkbox OFF values
  now remain OFF after saving: stale PDF appearance state no longer overrides an absent value.
- Compress This Document and Apply Redactions update the same model used by Save, with complete Undo/Redo.
  Save/export builds a separate snapshot and preserves live annotations. Explicit redaction also removes newly
  drawn overlay text; any positive overlap removes the complete covered annotation/widget, including its field data.
  A same-bounds Whiteout cannot accidentally retain covered text. Redaction/render failures abort output instead of
  returning unredacted content. Print, protected copies and text/image exports use this sanitized snapshot.
- Page moves, rotation, insertion and deletion preserve multi-selection, current-page identity and Undo/Redo.
  Bookmarks, links, link magnification and attachment lookup follow reordered/replaced pages. Crop and page-size
  controls validate before mutation, preserve custom dimensions and reject nonfinite values. Scaling transforms
  annotation geometry/fonts/ink/markup and preserves font family; pending page-content overlays are safely baked,
  with original editable pages available to Undo. Numbering, labels and Bates sequences reject overflow.
- Whole Page and Fit Width use distinct scales, including rotated pages and spreads. Search visits individual
  occurrences and wraps in both directions. Supported Initial View layout/page/zoom settings apply on opening.
  OCR captures independent input and rejects obsolete results after edits, page changes or a newer request; rendering
  does not change live page rotation or annotations. Native checkbox input also invalidates an older OCR request.
- CLI ranges, dimensions, arity and export formats are validated. Unreadable merge inputs fail instead of producing
  partial documents. Each destination is replaced atomically after successful generation; split/batch output is not
  one atomic transaction. No-gain compression writes the unchanged copy. Image and visible-signature rendering have
  finite size/allocation bounds. Signature serialization preserves document parts; invalid timestamp URLs are rejected.

### Completed checks

| Check | Observed result |
|---|---|
| Debug builds and focused native suites during development | PASS after fixes; final authoritative results below are from the packaged release |
| Release build | `swift build --package-path build/pdf-audit-source -c release --product PDF42` PASS; `build/pdf-deep-release-build.log` |
| Debug and final packaged `--selftest` | **57/57** file/output regressions and **11 base groups, 0 failures** in each; `build/pdf-deep-selftest.log`, `build/pdf-deep-release-selftest.log` |
| Final packaged native UI | **10/10 runs PASS**, **310/310** functional assertions: markup/forms 126, pages/dialogs 73, core/output/OCR 91, lifecycle 20; `build/pdf-deep-ui-run.log` |
| Command inventory | All **99 PDF menu declarations** installed and resolved through the responder chain; **11 toolbar items** checked for routing. This inventory is a wiring check, not 110 independent behavior tests |
| Debug and final packaged independent CLI suite | **12/12 PASS**, no skips; `build/pdf-cli-audit/result.json`, `build/pdf-cli-audit-release/result.json` |
| Native printing and export | Print saved an actual temporary PDF containing the visible draft and excluding replaced/redacted source text; password export, outline/page labels, TXT/RTF/HTML/DOCX and rotated PNG/JPEG dimensions checked |
| Light/dark and dialogs | Generated and visually inspected: editor at both audit sizes, Properties and the existing signature/stamp generators |
| Signature and installation | `codesign --verify --deep --strict` PASS before and after installation; tested/package/installed hashes match |
| Static checks | Scoped `git diff --check` and Python syntax PASS; PDF42 localization-key coverage and RU/TR format placeholders PASS (`build/pdf-deep-source-strings.log`). This is not a full audit of concurrently edited language catalogs |

The independent CLI suite reads generated files using pypdf and checks forms (including cleared values), removal of
source text and partially covered widgets, edited text, metadata/nested bookmarks/labels/attachments, page boxes,
URI/FitH links, split/merge order, numbering/headers/Bates/watermarks, four text-export formats, compression and output
preservation after invalid input. Temporary self-signed CMS fixtures verify visible signatures, incremental second
signatures and detection of same-length data tampering. No TSA was contacted and no certificate was added to Keychain;
temporary private keys were deleted. `--verify` still prints signature status rather than encoding validity in its exit code.

Native checks dispatch controls, mouse/key events and field-editor input in disposable documents, with Undo/Redo and
saved/reopened state. The synchronous harness supplies normal event Undo boundaries, compares geometry within
`1e-7` point and resolved sRGB components, acquires a key window before widget clicks, and restores the original dirty
state before terminating. Earlier failures exposed absent foreground activation, unfinished test Undo groups and a
test Save prompt after successful assertions. These harness corrections retained the functional assertions; the final
10/10 result is from the corrected harness. Native tests require a usable logged-in desktop.

The release freezes the audited `Sources/PDF42` changes plus shared Kit42/resources from
`2e227ca78827335bdebc3084c4be024b120f1b04`. It retains EN/RU/TR and the existing generators. PAdES/CSC/GOST integration,
concurrent signature-learning, later pen-rendering and expanded-language work are outside this binary and were not
overwritten in the checkout.
The source hashes and release hash are recorded in `build/pdf-deep-source-manifest.json`; frozen sources are in
`build/pdf-audit-source`. The matching UI driver is `build/pdf-audit-ui.py`, with the four PDF functional scenarios and
six existing generator/appearance runs. It excludes the later `mark-learn` case because that feature is absent from
this shared base. The current repository runner also tests that newer feature when built from current shared sources.

Final native command:
`python3 build/pdf-audit-ui.py --app PDF42 --binary build/pdf-deep-release/PDF42.app/Contents/MacOS/PDF42 --output build/pdf-release-ui-audit`.
Logs, screenshots and the tested-source hash report are in `build/pdf-release-ui-audit`; CLI fixtures and hash report
are in `build/pdf-cli-audit-release`. The final packaged CLI command uses the same executable with
`python3 scripts/audit-pdf-cli.py --binary build/pdf-deep-release/PDF42.app/Contents/MacOS/PDF42 --output-dir build/pdf-cli-audit-release`.

The verified bundle was installed at `/Applications/PDF42.app` on **2026-11-06, 00:39 Europe/Istanbul**
(2026-11-05 21:39 UTC). Previous bundle: `build/backups/PDF42-before-update-20261105-213905.app`.
Installation record: `build/pdf-deep-install.json`; bundle metadata remains **1.0 / build 1**. No running application
was terminated and no user document was closed. Save open work and fully quit/reopen PDF42 to load the new executable.

These results do not establish complete Acrobat parity or a measured 95% feature-usage coverage. Physical printing,
all physical shortcuts/input devices, multiple displays, the minimum supported macOS, third-party certificate trust,
external TSA interoperability, exhaustive malformed PDFs and PDF/A conformance were not validated. Generator snapshots
and sample rendering do not exercise every library/import/Continuity interaction. Redaction's documented vector-graphics
and raster-fallback limitations still apply. Initial View window/title/full-screen flags remain metadata for other
viewers where documented; they are not all applied by PDF42 itself. README and DESIGN describe these boundaries.

## Signature model: kinematics, pens, letter forms, learning — 2026-11-06

- Kinematics: `SigmaLognormal` (lognormal impulses per movement, overlapping; arc directions; perturbation of D,
  angles, onset, μ, σ per copy). A first version let the model build the line itself; the owner found it less smooth
  (polygonal between via-points), so geometry and time are now separate: the line is the smooth centripetal spline
  with a low-pass hand and smooth per-copy drift, the model supplies speed along it.
- Pens (`PenRenderer`): ballpoint (downstroke ink, slow-point blobs, rare skips at speed, striations), gel, fountain
  (width from stroke angle to the nib), felt-tip; paper-fibre texture in `InkTexture`.
- Letters: alternative forms for 30 lowercase Latin and Cyrillic letters chosen per design; i/j/ё dots and t/f bars
  as delayed strokes (none, dot or dash; short or long bar per design).
- Learning: `My Signature…` window (pad with time and pressure, Open Picture…, Continuity import from iPhone/iPad),
  `LearnedSignature` stored in the library recipe; copies blend two samples of the same structure and perturb timing.

Verified: PDF42 debug build; `--mark-samples` sheets (generated signatures; learning from three timed samples and
from a traced picture; four pens) inspected; `audit-ui.py --app PDF42 --mode tests`: mark-signature, mark-seal and
the new mark-learn window snapshot pass. `mark-samples` was killed with SIGTERM inside the audit while other sessions
ran their PDF42 audits (their timeout handler terminates every process of the shared audit bundle); run directly
with the audit environment it completes with exit 0 in about 70 s (audit timeout for it raised to 300 s).
pdf-markup (2 of 125) and pdf-pages (1 of 73) failures come from another agent's new, uncommitted PDF42 tests.
Not verified: signing in the pad with a real trackpad, Continuity import from a real iPhone, a real scan.

## Twenty-language interface — 2026-11-06

Suite42 supports the same twenty-language selection used by emshandbook.com: `en`, `zh-Hans`, `zh-Hant`, `es`,
`ar`, `fr`, `pt`, `id`, `ru`, `de`, `ja`, `vi`, `tr`, `fil`, `ko`, `th`, `it`, `pl`, `ms`, `hu`.
English/Russian/Turkish tables are retained; seventeen bundled JSON catalogs provide the additional translations.
The translations were authored with application context, without sending the catalog to an external translation
service. Traditional Chinese was derived locally and reviewed for Taiwan terminology. Language matching handles
Chinese script/region aliases and Filipino `tl`; the shared saved preference, save-before-relaunch behavior and
English default remain. `-Suite42Language <code>` is a process-only audit override and does not change preferences.
Quick Look uses the first supported system language. Arabic text uses natural Unicode shaping/direction; the whole
editor canvas is not mirrored. UI language does not change document contents, OCR languages or formula syntax.

The welcome window sizes actions and its left pane from translated labels. Apps and Quick Look extensions embed
the catalogs and declare all twenty languages. Resource lookup works from the packaged bundle without requiring
the original SwiftPM build directory. No language bundle was installed in `/Applications` by this change.

### Frozen packaged verification

The first complete language build freezes sources in `build/localization/source-20261106`; its source manifest is
`build/localization/source-manifest.json`. It includes the completed PDF editing fixes and learned-signature/pen
work, but precedes the later PAdES/CSC/GOST integration and IMG42 deep-audit changes. Its catalogs contain **2,869**
source keys each. Release packaging completed; all six apps and four Quick Look extensions passed exact locale-array,
catalog-hash and `codesign --verify --deep --strict` checks (`build/localization/package-audit.json`). These are ad-hoc
signatures, not notarization. The original SwiftPM resource bundle was temporarily renamed during packaged checks
and restored afterwards, so the checks could not accidentally read that source resource location.

- Runtime localization selftest: **129/129** in debug and release. Catalog-validator unit tests: **18/18**.
- Native localization: **120/120** light launches (all twenty languages × six apps), plus **24/24** dark launches
  (Arabic, Traditional Chinese, Thai and German × six apps). Checks cover native picker names/order/selection,
  bundled language metadata, translated menus/actions and unclipped welcome labels. Ten representative screenshots
  were visually reviewed for complex scripts and long labels. Reports: `build/localization/final-native/summary.json`.
- Full native app audits on the same packaged executables: DOC42 **10/10**, XLS42 **4/4**, PPT42 **7/7**, PDF42 **11/11**.
  DOC checks include panels 16/16, rulers 99/99, editing 75/75, lifecycle 60/60 and pagination 16/16. XLS includes
  editing 68/68, common UI 53/53 and sheet references 7/7. PPT includes notes 6/6, editing 48/48, text/table/show 43/43,
  lifecycle 20/20 and inspector 50/50. PDF includes markup/pages/core/files and signature/seal/learning windows.
- Packaged DOC CLI **4/4**, XLS CLI **6/6**, PPT CLI **8/8**, with PDF/movie exports and no skips. XLS selftest:
  `ALL PASSED` (350 checks); PPT selftest **57/57**. Binary identities and logs: `build/localization/final-cli/summary.json`.

Initial SCN language runs opened its scanner editor, so the welcome-picker assertions correctly failed. The driver
now sets the existing `K42_WELCOME=1` launch option; the twenty-language rerun passed with all assertions retained.
Initial failures are preserved separately. Filesystem-sandbox attempts that could not access WindowServer/video
encoding are also retained; successful native/CLI runs used the logged-in desktop. These checks do not prove every
translated dialog fits, complete language quality, physical scanner/printing/Continuity behavior or third-party
signing interoperability. They do not cover later source changes merely because the app name is unchanged.

## IMG42 detailed follow-up — 2026-11-06

This records the separate EN/RU/TR installation at 01:17, not the integrated twenty-language publication bundle
reported in [Integrated publication build](#integrated-publication-build--2026-11-06).

At completion of this separate IMG42 audit, the changes were **local and uncommitted**, with a verified local
installation; no commit, push,
GitHub release or notarized distribution was created by this audit. Other applications and concurrent shared-library
work remain separate. The packaged IMG42 uses current IMG42 sources with Kit42 and IMG42 bundle resources frozen at
`2e227ca78827335bdebc3084c4be024b120f1b04`. This keeps EN/RU/TR and the older shared signature generator; the expanded language catalogs
and newer signature-learning/pen implementation in the working tree are outside this binary. The source snapshot is
`build/img-audit-source`; individual source hashes and the binary hash are in `build/img-deep-source-manifest.json`.

Implemented fixes and covered behavior:

- Markup/selection: drawing, movement, resizing, selection handles and constrained selection stay within valid bounds;
  Escape and tool changes roll back unfinished gestures. Unchanged edits do not create phantom Undo entries. Text
  drafts keep authored whitespace, unchanged re-editing keeps geometry, and Save/Export/Copy/Share/Print commit visible
  text. Style controls reflect Undo/Redo and disable unsupported properties. Shadow rendering, curve hit-testing,
  tall stamps and Pixelate at the image edge were corrected; flattening fails visibly rather than dropping marks.
- Pixel editing: keyboard slider actions participate in Undo; positive Highlights now actually brightens high tones.
  Show Original uses the original geometry after Crop/Resize and cannot be replaced by a delayed adjustment render.
  Undo restores pixel selections, selected marks and inspector state. Resize units, resolution-only changes and invalid
  input are checked. Mask/size validation and Smart Lasso bounds prevent invalid allocations and indexing.
- Asynchronous work: image navigation clears the old editing source while decoding, and load/cache generations reject
  obsolete results. Background removal and selection work reject results from an earlier image/edit. The displayed GIF
  frame becomes the editing/output frame, with its dimensions. Search rejects stale queries and OCR callbacks.
- File operations: Save As adopts the chosen URL, including another folder or an existing image-set member; Export
  copies retain the source draft, while overwriting the current image establishes a new baseline. Export over a cached
  neighbour invalidates its bitmap and thumbnail. Failed Revert preserves the draft; successful Revert supports Undo.
  Lossless Rotate/Flip and Trash Undo/Redo stay bound to their original URL after navigating to another image.
- Encoding and limits: atomic writes preserve an existing destination on failure; transparent JPEG output uses white,
  while an opaque RGBA buffer is not mistaken for transparency. DPI/description/orientation and multipage metadata
  operations retain the intended data. Raster decoding is bounded; reduced still/animated previews cannot silently
  replace full-resolution originals through Save, and CLI pixel editing rejects them. CLI options/values/arity are strict.
- Viewing: All Metadata disclosure is now present and functional; invalid EXIF exposure/GPS/DPI cannot trap the inspector.
  Empty/loading states disable image-only custom controls. Panel preferences survive temporary hiding and full-screen
  transitions; stopping a slideshow preserves full screen when the user entered it beforehand. Live Text Escape now
  clears selection; native double-click, drag, Select All, Draw, Undo, Space and Page Down were exercised.

Final verification on the **same packaged executable**, macOS 27.0.1 (26A434), arm64, Swift 6.3.1:

| Check | Result | Actual coverage |
| --- | --- | --- |
| Release build and strict code-signature verification | PASS | Final release build has no compiler warnings; local ad-hoc signature, not notarization |
| Markup native scenario | 128/128 | Mouse events, shapes, styles, text, selection/Alpha, Undo/Redo and rendered pixels |
| Editing native scenario | 64/64 | Adjustment/size controls, selections, Undo/Redo, stale background-result protection |
| Files native scenario | 98/98 | Save/Save As/Export/Revert, native format/quality/size controls, private pasteboard, Share data, Print-to-PDF, actual fixture Trash and cross-file orientation/export regressions |
| Core native scenario | 67/67 | Navigation, loading races, panels/metadata, animation frame, actual Vision OCR and search; responder inventory for 68 menu declarations and 15 toolbar items |
| Full-screen native scenario | 11/11 | Actual macOS Spaces, slideshow start/stop and panel/preference restoration |
| Live Text native scenario | 20/20 | Real VisionKit analysis, queued mouse/key events, selection, Draw/Undo and navigation |
| Vision scenario | 16/16 | Real foreground removal and subject-mask Smart Lasso on a locally generated shaded subject; alpha, PNG round trip and silhouette checks |
| Headless pixel regressions | 51/51 | Independent pixel coordinates, masks, transforms, adjustments, render/filter guards and Smart Lasso |
| Headless file/output regressions | 36/36 | Formats, dimensions, alpha, metadata, orientation, bounded decoding and failure preservation |
| Independent image CLI suite | 12/12 groups, 0 skips | Pillow checks PNG/JPEG/TIFF/BMP, orientation, transforms, geometry, alpha, metadata, animations, failures and actual Vision OCR |
| Complete UI runner | 10/10 runs | The seven new scenarios above, existing IMG42 UI/Recent checks, light/dark window captures |

The seven new scenarios contain **404 assertions**; the deterministic headless suites contain **87 assertions**.
These counts are checks, not a measurement of user-feature coverage. The responder inventory establishes wiring;
behavioral claims rely on the corresponding control/pixel/file assertions, not on inventory or screenshots alone.
Light/dark packaged screenshots were visually inspected. Real Vision's generated-subject silhouette overlap exceeded
0.98 for removal, mask and Smart Lasso; this does not establish segmentation quality for arbitrary photographs.
Python syntax, scoped `git diff --check`, IMG42 source translation coverage and EN/RU/TR format signatures pass.

Reproduction commands (logged-in macOS desktop required for UI):

```sh
swift build --product IMG42
.build/debug/IMG42 --selftest
python3 scripts/audit-images-cli.py --binary .build/debug/IMG42
python3 scripts/audit-ui.py --app IMG42 --output build/img-debug-ui-audit

swift build --package-path build/img-audit-source -c release --product IMG42
build/img-deep-release/IMG42.app/Contents/MacOS/IMG42 --selftest
python3 scripts/audit-images-cli.py --binary build/img-deep-release/IMG42.app/Contents/MacOS/IMG42 --output-dir build/img-cli-audit-release
python3 scripts/audit-ui.py --app IMG42 --binary build/img-deep-release/IMG42.app/Contents/MacOS/IMG42 --output build/img-release-ui-audit
codesign --verify --deep --strict build/img-deep-release/IMG42.app
```

Final logs: `build/img-deep-release-build.log`, `build/img-deep-release-selftest.log`,
`build/img-deep-release-cli-run.log`, `build/img-deep-ui-run.log`. Per-scenario logs, screenshots, Vision fixtures and
binary identity report: `build/img-release-ui-audit`; independent CLI fixtures/report: `build/img-cli-audit-release`.
The intermediate runs found real Highlights, metadata-disclosure, Live Text Escape and cross-file Undo/cache defects;
these were fixed and rerun. Test-only corrections retained strict outcomes: empty explicit Undo groups were removed
from no-op fixtures, an overlapping red/orange pixel predicate was disambiguated, and asynchronous Alpha waited for its
real callback. The model-only Vision scenario no longer waits for an unrelated key window. None of these intermediate
failures is recorded as a successful final run.

Installed at `/Applications/IMG42.app` on **2026-11-06, 01:17 Europe/Istanbul**. Previous bundle:
`build/backups/IMG42-before-update-20261105-221741.app`. Installation record: `build/img-deep-install.json`; bundle metadata remains **1.0 / build 1**.
Installed/package/CLI/UI SHA-256: `70c782287c33dc47d917881efef4288d25f1fd97aa47b43af4baf538716bc198`.
The installer verified the exact test results and signature, retained a backup and checked the installed hash.
No running application was terminated and no user image/document was closed. Save open work and fully quit/reopen IMG42
to load the new executable.

Remaining boundaries: no claim of complete Preview parity or measured 95% usage coverage. Physical printing,
third-party Share delivery, Finder/Open With/Maps handoffs, Continuity imports, every signature-library workflow,
all physical input devices/shortcuts, multiple displays, minimum-supported macOS, every codec/RAW variant and arbitrary
malformed or very large animations were not exercised. The real model test uses one generated subject. Animation
loading still retains at most 2,000 decoded frames in memory rather than streaming; pixel output exports the displayed
frame/page. Editable text glyphs stay upright when their boxes rotate/flip, whereas image stamps rotate their bitmap.
IMG42 still has no document recovery autosave. README and DESIGN now describe these behaviors and limitations; AGENTS
records the required regression, packaged-binary and installation checks.

## Integrated publication build — 2026-11-06

The publication worktree starts at GitHub `8087d005d01ff502dd98ac298d079479519b5b2f` and combines the PAdES/CSC/GOST
and learned-signature work already on GitHub with the completed PDF editor fixes, twenty-language interface and
IMG42 regression work. The original shared checkout was preserved. The README and DESIGN describe this combined
source; repository About text has been updated to the six-app suite, twenty languages, offline core and optional
CryptoPro integration. Verified source publication is recorded at the top of this report.

All seventeen additional-language catalogs now contain **3,003 source keys** each, including 134 new signing/image
strings beyond the earlier frozen language build. Exact coverage and format validation pass; validator unit tests
pass **18/18**, and the release localization selftest passes **129/129**. The complete debug build and six-app release
packaging succeeded. All ten app/Quick Look bundles have the expected twenty locales and identical bundled catalogs;
code signatures pass strict verification. The package metadata remains 1.0/build 1 with ad-hoc signing.

Final package verification, using explicit packaged executable paths:

- DOC42 CLI **4/4**, XLS42 CLI **6/6**, PPT42 CLI **8/8**, with no skipped PDF/movie checks. XLS42 selftest reports
  `ALL PASSED` (350 checks), including file 66/66, formula 130/130 and sheet-reference 61/61 regressions;
  PPT42 file/output selftest **57/57**. These reruns use the final 3,003-key packages. The earlier full DOC/XLS/PPT
  native suites remain applicable to their unchanged editing implementation; their exact frozen binary identities
  are recorded in the preceding section, rather than being relabelled as new native runs.
- PDF42 selftest: **19 groups** plus **57/57** deep file checks. Independent PDF CLI **12/12**, no skips.
  Fake CryptoPro tests **24/24** validate process/format/МЧД integration, not GOST cryptography. A new localhost-only
  signing smoke passes **21/21**: local/CSC B-B and legacy signatures, incremental signatures, tamper detection,
  metadata retention, Basic/client-credentials login, PIN/OTP, invalid inputs and destination preservation.
  The documented bare `tsa` option is accepted for CSC; B-B makes no TSA request. Simulated HTTP 503 failures for
  B-T signing and document timestamping leave existing output unchanged. Temporary private keys were removed.
- PDF42 final native suite **11/11**: markup **126/126**, pages **73/73**, core **91/91**, lifecycle **20/20**;
  recent menu checks **8/8** in both appearances, plus signature/seal/learning windows and snapshots.

The final PDF42 executable SHA-256 is
`2b2c549b2311a2e17c9fda69dba159244e2383b63223f6a6b2cd4b8110c11c43`.
Evidence in the publication worktree: `build/publication/package-audit.json`, `source-manifest.json`,
`runtime-selftest.log`, `cli/summary.json`, `final-signing/summary.json`, and `ui/PDF42/result.json` (all under
`build/publication`). These are local generated artifacts; the test drivers and this dated report are committed.
Real third-party CSC/CryptoPro/TSA interoperability and the combined digital-signing dialog are not established by
these localhost and CLI checks. No new language package was installed and no notarized/downloadable release was
created in this publication task.

### Final language and IMG42 checks

The final six-package language matrix passes **144/144**: all twenty languages in light mode and Arabic, Traditional
Chinese, Thai and German in dark mode. The matrix uses the final IMG42 executable identified below and unchanged
PDF42/DOC42/XLS42/PPT42/SCN42 packages. Native reports verify menu/picker/catalog behavior and welcome-label fit;
representative complex-script and long-label screenshots were reviewed. Earlier IMG results were archived when
subsequent functional fixes required rebuilding that app.

IMG42 now binds Trash and lossless rotation Undo/Redo to the original file after navigation, and invalidates cached
pixels when Export replaces a previously viewed image. These fixes have cross-file regression cases. Debug and
release selftests pass **51/51** pixel checks plus **36/36** file checks; independent CLI checks pass **12/12** against
both debug and the final package, with no codec/OCR skips. The final native suite passes **10/10** runs, including
**404/404** assertions: markup 128/128, editing 64/64, file UI 98/98, navigation/core 67/67, real window-mode transitions
11/11, Live Text 20/20 and Vision 16/16, plus legacy UI and light/dark captures. The tested package hash is
`2491d3ee05d3ddae79370df95bbd1458b05c4dbfccbdca3b7f9aea6202615eb4`.

The separate locally installed IMG42 snapshot reported above remains a different EN/RU/TR binary. This final
integration package includes twenty languages and the newer shared signature implementation and was not installed.
Evidence: `build/publication/img-final-package-audit.json`, `native/*result.json`, `ui/IMG42/result.json`,
`cli/img/result.json` and `cli/img-debug/result.json`. All paths are relative to `build/publication` except the first.
Physical printing, scanner/Continuity hardware, third-party sharing and arbitrary files/codecs remain outside these
checks. The permanent `scripts/audit-signing-cli.py` preserves the 21 localhost signing regression scenarios and
passes against the final PDF42 package; its result is `build/publication/final-signing/permanent-driver/result.json`.
