# Suite42 — design system

PDF42, DOC42, XLS42, IMG42, PPT42 and SCN42 share a look and a menu system. Shared UI components
live in **Kit42** (`Sources/Kit42`); each app declares its commands and implements its own document or window behavior.
This describes the current implementation; dated verification and remaining gaps are in [STATUS.md](STATUS.md).

## Principles

- **Native macOS.** AppKit, system fonts, SF Symbols, system colours (light/dark). No custom chrome.
- **Quiet main toolbar.** Only frequent actions; tools for the current mode live in the tool strip.
- **One command — one definition.** A `Command` (title, SF Symbol, shortcut, selector) builds the menu item,
  toolbar button and strip button, keeping their labels and shortcuts in one place.
- **Undo follows the active editor.** Document changes use the owning document/controller's `UndoManager`;
  text views can have a separate native text undo history (for example PPT42 notes). Commit pending field/text edits
  before saving or switching context. Not every background operation is undoable; SCN42 OCR is one exception.
- **Use banners for ongoing status.** Signatures, read-only and compatibility information use `BannerView`;
  confirmations and errors can use native alerts or sheets.
- **English text is British** (Colour, Grey, Centre). Title case for menu items, buttons, toolbar labels and undo
  names; sentence case for tooltips, field labels and checkboxes. One command keeps one label in every app.
- **Three languages: English (default), Russian, Turkish.** Every string in code is English inside `L("…")`;
  translations are `[en, ru, tr]` tables (`Kit42/Strings.swift`, `<App>/Strings.swift`, registered in `main.swift`).
  The language is picked on the welcome screen and is shared by all six apps (`com.sfzorin.suite42` › `language`);
  switching restarts the app. An ellipsis "…" marks commands that open a dialog.

## Window layout

Typical PDF42 layout; other apps add their own formula bar, notes, inspectors or scan settings:

```
┌───────────────┬─────────────────────────────────────────────────────────────┐
│ ● ● ●  [▤]    │ Name.ext            [− +] [↺] [✎] [✍] [✓]    [ Поиск       ] │  toolbar (unified)
│               │ subtitle: status                                            │
│               ├─────────────────────────────────────────────────────────────┤
│ sidebar       │          tool strip (ToolStrip, toggle ⇧⌘A in PDF42)         │  titlebar accessory
│ (NSSplitView  ├─────────────────────────────────────────────────────────────┤
│  sidebar)     │ ⚠ banner (BannerView, when there is something to say)       │
│               │                                                             │
│               │                 document                                    │
└───────────────┴─────────────────────────────────────────────────────────────┘
```

- Windows use native toolbar/titlebar controls. Split-view sidebars use `NSSplitViewItem(sidebarWithViewController:)`;
  not every app has the same split-view structure.
- Toolbar order: `toggleSidebar · sidebarTrackingSeparator · flexibleSpace · view group · document actions · mode toggle · search`.
- Default toolbars hold only frequent actions. A command that already has a home elsewhere (zoom when the window has
  a zoom slider, print/export in File, page tools in a menu) goes to `ToolbarController(optional:)`: it stays in
  Customize Toolbar but is not placed by default. Never put the same action twice in one window (toolbar and inspector).
- Subtitle: position and state only ("Стр. 3 из 12", "Лист 2 · A1:C4"). Counts (words, characters) belong in the
  status bar; the two never repeat each other.
- Status bar: only where the document has counts or a view-layout/zoom control that the toolbar does not carry
  (DOC42, XLS42; SCN42 shows device state). PDF42, PPT42 and IMG42 have none by design.
- Apps can show `WelcomeWindowController` (icon, actions, recent files) when no document is open;
  SCN42 opens a new scan window by default.
- `Panels.toggleAll` saves the current visibility per window and restores it. App-specific panels must do the same;
  temporary hiding must not overwrite preferences for later windows (DOC42 ruler/comments use non-persisting setters).
- At narrow widths, `ToolStrip` moves groups into its More menu; native toolbars use their overflow menu.
- DOC42 has a 30 pt horizontal ruler above the document viewport and a 30 pt vertical ruler to its left. One View
  command shows/hides both. Horizontal page-margin grips occupy the middle band, separately from paragraph-indent triangles;
  native down/drag/up events preview the value and commit one undoable change on release. Geometry tracks scroll,
  zoom, sections and the active column/header. Web layout disables print-margin grips. Test actions as well as
  appearance: a visible ruler is not evidence that its controls work.

## XLS42 editing and output contracts

- Commit the visible cell/formula draft before Save, Print, export, Find or a sheet/context change. The commit result
  is part of the command contract: a validation failure retains the text, focus and selection and stops the command.
  Pending text participates in the document's edited state. Successful Revert discards the draft and restores a valid
  sheet/selection; a failed read must leave both draft and workbook intact.
- Cell-content mutations preflight the actual destination, including Skip blanks and stopped fill series. Reject
  writes crossing protection, worksheet bounds, the 100,000-cell operation limit or part of a legacy array before
  changing cells or undo history. A complete array replacement removes its metadata in the same undo transaction;
  format-only paste can change a subset without changing array formulas. Large sparse clears visit stored cells.
- Format Cells represents mixed border selections explicitly. Opening and accepting the dialog without changing a
  border preserves every edge, including imported line styles. None, Outline and All are explicit actions over the
  complete selection; Outline clears inner lines. Changing a border style/colour changes existing lines without
  inventing new ones. Native font/background colour wells turn off Automatic/No fill when a colour is selected.
  Number-format controls and their preview stay synchronized with typed values and category changes.
- Row Autofit is a document mutation with Undo/Redo, including shrinking a previously tall row. Formatting controls
  and preview rendering are separate from applying the final selection-wide change.
- Date serials retain the workbook's 1900/1904 epoch. Rendering, editing, Find, fill series and CSV/PDF output receive
  that context; import/export must not silently shift raw values. Text typed as a forced string remains a string after
  save/reopen even when it resembles a formula or date.
- Print and PDF use the same layout and explicit scope. Workbook scope contains visible sheets; selection scope
  contains the selection. Fit to width uses the required scale even for very wide tables. Frozen title repetition is
  disabled when it would consume at least 80% of the printable body. PDF export does not substitute a screenshot for
  complete sheet layout or mutate the user's print settings.

These describe the current local implementation, not a published release. Keep scenario coverage in README and
dated binary/test/installation evidence in STATUS; native action tests and PDFs establish more than panel snapshots.

## PPT42 editing and output contracts

- Visible in-place and outline text drafts participate in document dirty state. Commit in-place text before object
  commands; Save/export also flushes pending outline typing synchronously. Successful Revert discards drafts and delayed
  outline updates only after the replacement file has parsed. Failed reads retain the original model and draft. Opening
  and leaving unchanged text must not create a document Undo step.
- Text editing owns a text UndoManager; format changes while editing separate typing bursts. Object/document actions
  restore model and selection together. A command that commits a pending draft and changes an object can form one
  native undo group; regressions must check the complete before/after state of that group. Notes editors clear their
  local Undo when the slide/content changes; Revert clears local notes/outline histories so they cannot edit stale content.
- Character/paragraph commands visit visible text containers in nested groups and table cells. Vertical alignment
  targets the edited table cell when one is active, otherwise all selected text containers. Empty-paragraph properties
  are data and must survive commit. The inspector reports effective styles from the same text-container traversal.
- Find navigates individual occurrences in objects, cells and notes. Replacement can span run boundaries, retains
  surrounding formatting, and uses the first matched character's properties for inserted text. Dynamic fields stay
  fields. Notes replacement uses the notes text view's Undo path; whole-deck replacement is a document transaction.
- Insert/delete table rows and columns transforms merged rectangles and their covered cells together. Removing an
  anchor from a surviving span retains its content at the surviving anchor. Fill/line inspector controls mutate the
  actual table style and grouped child shapes and reflect that effective style in the panel. Table No Fill is explicit
  transparency, not absent data that inherits the header theme. Unsupported table dash/autofit controls are disabled.
  Master/layout placeholder commits retain shadow, opacity and shape adjustment values as well as fill/line/text.
- Canvas transformations and Ungroup preserve the rendered child geometry, including reflections. Cross-document
  paste imports media under noncolliding names and remaps references in the same Undo transaction as inserted objects.
  Inspector numeric fields reject invalid/nonfinite geometry before a mutation, and controls re-enable when their
  mode/selection becomes eligible again.
- Notes PDF and printed notes paginate the complete text. The on-screen Notes Page is a first-page preview. PDF/image
  scope omits hidden slides unless included explicitly. Validate bitmap dimensions before allocating; export failures
  must preserve existing destination files where the exporter promises replacement safety.
- Show startup plays its first automatic animation group. Delayed animation callbacks are tied to the navigation that
  scheduled them; moving elsewhere must not reveal a build on the wrong slide.

These are local implementation contracts. Record exercised scenarios, limitations and the exact build's results in
README/STATUS; passing model tests do not replace native actions, rendered-pixel assertions or saved-file checks.

## Menu bar (`MenuBarSpec` → `MenuBar.build`)

Same skeleton and order in every app; empty Insert and Format menus are omitted. Applications can adapt or disable
standard commands to match their document model:

| Menu | Kit42 provides | App adds |
|---|---|---|
| **App** | About, Settings (optional), Services, Hide, Quit | — |
| **Файл** | New, Open, Open Recent, Close, Save, Save As, Duplicate, Revert, Page Setup, Print | `fileExtras`: export, password, … |
| **Правка** | Undo/Redo, Cut/Copy/Paste, Select All, Find ▸ | `editExtras`, `find` |
| **Вид** | Sidebar ⌃⌘S, Toolbar ⌥⌘T, Toolbar Labels, Customize, Hide All Panels ⇧⌘\, Full Screen ⌃⌘F | `view`: zoom, modes, navigation |
| **Вставка** | — | images, signatures, pages / tables / rows |
| **Формат** | — | font, paragraph / cell format |
| *App menus* | — | See the application menu list below |
| **Окно** | Minimise, Zoom, Bring All to Front | — |
| **Справка** | system search | shortcuts, welcome window |

Custom top-level menus (`Commands.swift`, localized in the app):

- PDF42: Markup, Form, Page, Signature.
- DOC42: Review, Table.
- XLS42: Table, Sheet, Data, Tools.
- IMG42: Image, Markup.
- PPT42: Slide, Slide Show.
- SCN42: Scan, Page, Tools.

`RecentDocumentsMenu` rebuilds Open Recent from `NSDocumentController.shared.recentDocumentURLs` when opened.
Entries route through the app's document controller; Clear Menu is disabled when empty. IMG42 and SCN42 use custom
controllers, so recent-file actions must not assume every app has an `NSDocument` editor.

### Shortcuts reserved across the suite

| Shortcut | Shared meaning where supported |
|---|---|
| ⌘N ⌘O ⌘S ⇧⌘S ⌘W ⌘P | standard file commands |
| ⌘Z ⇧⌘Z ⌘X ⌘C ⌘V ⌘A | standard edit commands |
| ⌘F ⌘G ⇧⌘G | find, next, previous |
| ⌘+ ⌘- ⌘0 ⌥⌘0 | zoom in, out, actual size, fit |
| ⌃⌘S ⌥⌘T ⌃⌘F | sidebar, toolbar, full screen |
| ⇧⌘\ | temporarily hide/restore all panels |
| ⌘1…⌘9 | tools / modes of the current tool strip |
| ⇧⌘K | insert signature or seal (shared library) |
| ⇧⌘I | insert image |
| ⌘B ⌘I ⌘U | bold, italic, underline in document/text editing contexts; SCN42 uses ⌘B for Scan |
| ⌥⌘D / ⌥⌘V | digital signature: sign / verify |
| ⇧⌘0 | welcome window |

Prefer ⌥⌘ or ⇧⌘ for app-specific shortcuts and check the assembled menu for collisions. Deliberate exceptions are
documented by the app: PPT42 uses ⇧⌘P for Play from Current Slide and removes that shortcut from Page Setup.

## Kit42 components

| Type | Purpose |
|---|---|
| `Command`, `Shortcut`, `commandTag(of:)` | action description; the command tag (tool, mode) arrives in `sender` |
| `MenuBarSpec`, `MenuBar.build` | menu bar |
| `RecentDocumentsMenu` | live recent-file list with custom-controller routing and Clear validation |
| `Panels`, `PanelHiding`, `ToolbarLabelsToggle` | temporary panel hiding/restoration, toolbar labels and full-screen behavior |
| `ToolbarController`, `ToolbarElement` | toolbar from commands (button, group, search, view) |
| `ToolStrip` | slim bar under the toolbar; controls in rounded groups (`.group`, `.tools` exclusive, `.buttons`, `.view`) |
| `StripButton` | borderless icon button: soft hover, accent when on, optional drop-down menu (alignment, lists, borders) |
| `ColorButton` + palette | icon with a colour bar; click opens a curated palette with "No colour" and "More colours…" |
| `SizeStepper`, `stripPopUp` | compact "− 12 +" for sizes; borderless pop-ups for font/style/format |
| `PaginatedPDF` | paginated PDF of any view through the print system (exports) |
| `DocxWriter` | .docx writer (paragraphs, runs, tables, images) — the system writer drops tables |
| `BannerView` | status bar (`info / success / warning / error`) |
| `WelcomeWindowController` | start window |
| `StampLibrary`, `StampLibraryViewController`, `ImageTools` | shared library of signatures and seals, background removal |
| `SigmaLognormal`, `PenRenderer`, `PenType` | sigma-lognormal timing along a smooth line (geometry and time separated); ink from speed and direction for ballpoint, gel, fountain and felt-tip pens, paper fibres |
| `SignatureLearning`, `LearnedSignature`, `SignaturePad` | user's samples (timed strokes from the pad, or traced from a picture: threshold, Zhang–Suen thinning, good-continuation tracing) → RDP via-points with real durations → blended and perturbed copies |
| `SignatureGenerator`, `PenAlphabet` | signatures from a kinematic pen model: hand-drawn letter centre lines, centripetal spline, low-pass hand, speed from curvature over a few pen widths; 1320 styles (design seed low bits); copies vary by impression seed with a smooth drift, per-letter shifts and scales, and flourish changes |
| `SealGenerator`, `SealCatalog` | 132 stamp templates in 15 categories built from layout families (round, oval, rect rows, office word, CJK grid, dater, table, triangle); `impress` gives imported pictures the same impression |
| `MarkGeneratorController`, `GeneratedMark`, `InkTexture` | generator window; library items keep a JSON recipe (and imported originals in `Stamps/Sources`) so each insertion renders a new impression |
| `InkColorPopUp` | ink colour presets with swatches plus Other Colour… |
| `CertificateStore`, `SigningIdentity` | certificates from the Keychain, .p12 import, self-signed creation |
| `Theme42` | sizes, app accent colours, `NSAlert.form` |
| `DebugSnapshot` | `K42_SNAPSHOT=out.png` renders a window, requests app activation, then exits unless kept open; `K42_APPEARANCE=dark\|light` forces appearance; `K42_AUDIT_RECENT=1` checks recent-menu behavior |

## Visual parameters

- App accents (icon, details; `Theme42.App.colors` = `make_icon.swift` palette): PDF red `#FF6A5C→#D81E35`,
  DOC blue `#4FA3FF→#1659D6`, XLS green `#3FD486→#0E8A4A`, IMG purple `#B57CFF→#6A2BD9`,
  PPT orange `#FFB547→#E5671A`, SCN cyan `#3FD8E0→#0B8FA6`.
- Icons are drawn in code (`scripts/make_icon.swift`, redrawn by `build.sh` when the script changes, `./build.sh icons`
  forces it; the `.icns` files are committed). Apple's grid: 1024 px canvas, 824 px squircle body (superellipse n = 5)
  with 100 px margins and a soft drop shadow; body = vertical gradient of the app colour with a top light.
  On it the same white sheet with a folded top-right corner; the sheet carries the app's mark: PDF — text lines and a
  red "PDF" label, DOC — blue heading bar and text lines, XLS — green grid with header row, IMG — landscape photo,
  PPT — slide/chart, SCN — page crossed by a scanning beam.
  ≤ 32 px use a simplified drawing (fewer, thicker marks).
- Dark mode: only semantic colours (`labelColor`, `separatorColor`, `controlAccentColor` …) in Kit42 drawing; layer
  colours (`cgColor`) are resolved again in `viewDidChangeEffectiveAppearance`. Paper-like things (stamp tiles,
  document pages) stay white on purpose.
- Shared defaults (`Theme.swift`): tool strip 42 pt, banner 36 pt, sidebar 180 pt, spacing 8 pt, corner radius 8 pt.
  Individual window controllers set their own sidebar/inspector minimums and maximums.
- Strip: capsules fit their controls with 3 pt vertical / 4 pt horizontal padding (radius 8, 4.5 % label fill,
  hairline border), 8 pt between groups and 2 pt between controls. Buttons are 30×26 pt, or 38×26 with a menu;
  symbols 13 pt medium, hover 7 % fill, "on" = accent 18 % with accent icon.
- Group outline is a `labelColor` 8 % hairline: `separatorColor` resolves much darker on non-vibrant backgrounds.
- Related choices collapse into one drop-down that shows the current state (alignment, lists, borders, line width).
- Colours are never big wells: icon + colour bar, palette in a popover.
- Thumbnails (PDF42 sidebar, IMG42 filmstrip): one centred column in sidebars; selection is an accent outline around
  the page or picture, never a filled cell.
- Segmented tab bars use either all text or all icons with tooltips (PPT42 inspector: icons, since five text labels
  do not fit 290 pt in Russian/Turkish).
- Prominent buttons use the system accent (`bezelColor` unset); app colours are for icons only.
- Menu items carry the command's SF Symbol; cells/pages have context menus built from the same commands.
- For newly generated document text, prefer document fonts such as Helvetica Neue instead of SF, whose Cyrillic
  characters have caused PDF extraction problems. Preserve fonts from imported documents; UI text uses system fonts.

## Adding an app

1. Add `Sources/<App>/`, an executable product/target depending on Kit42 in `Package.swift`, and `Resources/<App>/Info.plist`.
2. `Commands.swift`: every `Command` plus `menuBar: MenuBarSpec` and `toolbar: [ToolbarElement]`.
3. Window controller: actions `@objc func …(_ sender: Any?)`, validation via `validateMenuItem` / `validateToolbarItem`.
4. Add the app to `Theme42.App`, `scripts/make_icon.swift` and `build.sh`'s `ALL` list; register its translations in `main.swift`.
5. Add Quick Look type mappings only if needed, and include the app in `scripts/audit-ui.py` with representative fixtures.
6. Run `./build.sh <App>` and verify both appearances and a narrow window. Update README and the dated status report.

## Interface verification

`python3 scripts/audit-ui.py` builds isolated test bundles from already-built debug executables and runs native
controller checks plus light/dark snapshots. It needs a logged-in desktop; bundle identifiers isolate app-specific
defaults, while the suite language remains shared. See [README.md](README.md#regression-checks) for commands.
Snapshots use AppKit view rendering, which can omit native composited material layers. Suspect artifacts must be
checked in a live window before changing layout. For example, the XLS42 Format Cells tabs were black in a cached-view
snapshot but rendered correctly in the live dialog. Responder-action tests do not simulate physical keyboard input.
For XLS42, `--app XLS42` runs the editing/formatting/lifecycle and print-layout regressions as well as snapshots.
Pair it with `XLS42 --selftest` for calculation/model checks and `scripts/audit-spreadsheets-cli.py --binary …` for
independent XLSX/ODS/CSV fixture conversions and PDF text/page checks. A fixture's scope and any skipped PDF checks
must remain visible in the recorded result.
For PPT42, `--app PPT42` adds canvas/editing, text/table/show, lifecycle and inspector suites. Pair those with
`PPT42 --selftest` and `scripts/audit-presentations-cli.py --binary …`; record skipped PDF/movie checks explicitly.
Native control tests include rendered fill/border samples and complete-document output assertions where relevant.

## Quick Look

- Only formats macOS shows as plain text or not at all get extensions (checked with `qlmanage`): Markdown
  (hosted by DOC42), `.ods` and `.tsv` (XLS42). `.docx/.xlsx/.xls/.csv/.rtf/.odt` are left to the system.
- Previews are data-based HTML (`QLIsDataBasedPreview`) with `prefers-color-scheme` light/dark CSS; thumbnails are drawn
  on white paper (portrait page for documents, zoomed grid for spreadsheets).
- One binary per kind (`QLPreview42`, `QLThumbnail42`); `build.sh` writes each host's Info.plist with its
  `QLSupportedContentTypes` (`QL_TYPES` in build.sh), bundle id `<app id>.preview|thumbnail`.
- Extensions are sandboxed (`Resources/QuickLook/Extension.entitlements`) and signed before the app; the app is
  signed without `--deep`, which would strip their entitlements.
- Extension strings use `PL("…")` (rows in `Previews42/Strings.swift`) and follow the system language: the sandbox
  cannot read the suite's language choice.

