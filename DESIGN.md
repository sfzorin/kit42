# Suite42 — design system

PDF42, DOC42 and XLS42 are three apps with one look and one menu system. Everything
shared lives in the **Kit42** library (`Sources/Kit42`); an app only describes its own commands.

## Principles

- **Native macOS.** AppKit, system fonts, SF Symbols, system colours (light/dark). No custom chrome.
- **Quiet main toolbar.** Only frequent actions; tools for the current mode live in the tool strip.
- **One command — one definition.** A `Command` (title, SF Symbol, shortcut, selector) builds the menu item,
  toolbar button and strip button. Titles and shortcuts never diverge.
- **Every edit can be undone.** All changes go through the document's `UndoManager`.
- **Status comes as a banner, not a modal alert.** Signatures, read-only, compatibility → `BannerView`.
- **Three languages: English (default), Russian, Turkish.** Every string in code is English inside `L("…")`;
  translations are `[en, ru, tr]` tables (`Kit42/Strings.swift`, `<App>/Strings.swift`, registered in `main.swift`).
  The language is picked on the welcome screen and is shared by all 42 apps (`com.sfzorin.suite42` › `language`);
  switching restarts the app. An ellipsis "…" marks commands that open a dialog.

## Window layout

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

- Window: `.fullSizeContentView`, `toolbarStyle = .unified`, sidebar via `NSSplitViewItem(sidebarWithViewController:)`.
- Toolbar order: `toggleSidebar · sidebarTrackingSeparator · flexibleSpace · view group · document actions · mode toggle · search`.
- Subtitle: position and state ("Стр. 3 из 12", "Лист 2 · A1:C4", "1 240 слов").
- No document open → `WelcomeWindowController` (icon, actions, recent files).

## Menu bar (`MenuBarSpec` → `MenuBar.build`)

Same order in every app; empty menus are omitted:

| Menu | Kit42 provides | App adds |
|---|---|---|
| **App** | About, Settings (optional), Services, Hide, Quit | — |
| **Файл** | New, Open, Open Recent, Close, Save, Save As, Duplicate, Revert, Page Setup, Print | `fileExtras`: export, password, … |
| **Правка** | Undo/Redo, Cut/Copy/Paste, Select All, Find ▸ | `editExtras`, `find` |
| **Вид** | Sidebar ⌃⌘S, Toolbar ⌥⌘T, Customize, Full Screen ⌃⌘F | `view`: zoom, modes, navigation |
| **Вставка** | — | images, signatures, pages / tables / rows |
| **Формат** | — | font, paragraph / cell format |
| *App menus* | — | PDF42: Разметка, Страница, Подпись · DOC42: Таблица? · XLS42: Таблица, Данные |
| **Окно** | Minimise, Zoom, Bring All to Front | — |
| **Справка** | system search | shortcuts, welcome window |

### Shortcuts reserved across the suite

| Shortcut | Meaning everywhere |
|---|---|
| ⌘N ⌘O ⌘S ⇧⌘S ⌘W ⌘P | standard file commands |
| ⌘Z ⇧⌘Z ⌘X ⌘C ⌘V ⌘A | standard edit commands |
| ⌘F ⌘G ⇧⌘G | find, next, previous |
| ⌘+ ⌘- ⌘0 ⌥⌘0 | zoom in, out, actual size, fit |
| ⌃⌘S ⌥⌘T ⌃⌘F | sidebar, toolbar, full screen |
| ⌘1…⌘9 | tools / modes of the current tool strip |
| ⇧⌘K | insert signature or seal (shared library) |
| ⇧⌘I | insert image |
| ⌘B ⌘I ⌘U | bold, italic, underline (DOC42, XLS42) |
| ⌥⌘D / ⌥⌘V | digital signature: sign / verify |
| ⇧⌘0 | welcome window |

App-specific shortcuts use ⌥⌘ or ⇧⌘ so they don't collide with the shared ones.

## Kit42 components

| Type | Purpose |
|---|---|
| `Command`, `Shortcut`, `commandTag(of:)` | action description; the command tag (tool, mode) arrives in `sender` |
| `MenuBarSpec`, `MenuBar.build` | menu bar |
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
| `CertificateStore`, `SigningIdentity` | certificates from the Keychain, .p12 import, self-signed creation |
| `Theme42` | sizes, app accent colours, `NSAlert.form` |
| `DebugSnapshot` | `K42_SNAPSHOT=out.png` — window snapshot for checking the UI; `K42_APPEARANCE=dark\|light` forces the appearance (hooked in `Localization.register`, before the first window) |

## Visual parameters

- App accents (icon, details; `Theme42.App.colors` = `make_icon.swift` palette): PDF red `#FF6A5C→#D81E35`,
  DOC blue `#4FA3FF→#1659D6`, XLS green `#3FD486→#0E8A4A`, IMG purple `#B57CFF→#6A2BD9`.
- Icons are drawn in code (`scripts/make_icon.swift`, redrawn by `build.sh` when the script changes, `./build.sh icons`
  forces it; the `.icns` files are committed). Apple's grid: 1024 px canvas, 824 px squircle body (superellipse n = 5)
  with 100 px margins and a soft drop shadow; body = vertical gradient of the app colour with a top light.
  On it the same white sheet with a folded top-right corner; the sheet carries the app's mark: PDF — text lines and a
  red "PDF" label, DOC — blue heading bar and text lines, XLS — green grid with header row, IMG — landscape photo.
  ≤ 32 px use a simplified drawing (fewer, thicker marks).
- Dark mode: only semantic colours (`labelColor`, `separatorColor`, `controlAccentColor` …) in Kit42 drawing; layer
  colours (`cgColor`) are resolved again in `viewDidChangeEffectiveAppearance`. Paper-like things (stamp tiles,
  document pages) stay white on purpose.
- Tool strip 38 pt, banner 36 pt, sidebar 150–320 pt, spacing 8 pt, corner radius 8 pt.
- Strip: groups are 28 pt capsules (radius 8, 4.5 % label fill, hairline border), 8 pt between groups;
  buttons 30×26, symbols 13 pt medium, hover 7 % fill, "on" = accent 18 % with accent icon.
- Related choices collapse into one drop-down that shows the current state (alignment, lists, borders, line width).
- Colours are never big wells: icon + colour bar, palette in a popover.
- Menu items carry the command's SF Symbol; cells/pages have context menus built from the same commands.
- Document content never uses the system font (SF): its Cyrillic "к" extracts from PDFs as "ĸ". Use Helvetica Neue.

## Adding an app

1. `Sources/<App>/` — executable target depending on Kit42; `Resources/<App>/Info.plist`.
2. `Commands.swift`: every `Command` plus `menuBar: MenuBarSpec` and `toolbar: [ToolbarElement]`.
3. Window controller: actions `@objc func …(_ sender: Any?)`, validation via `validateMenuItem` / `validateToolbarItem`.
4. `./build.sh <App>` — the icon is generated automatically.

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

