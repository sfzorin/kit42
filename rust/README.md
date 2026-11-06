# Suite42 Windows foundation handoff

This separate Rust workspace provides an early native Windows foundation for all six apps. The macOS Swift apps
remain separate. The base passed hosted Windows MSVC tests and builds; interactive Windows use remains untested.
This is not a Windows release or feature-parity claim. The intended archives are `build/rust-port-windows/Suite42-windows-x64.zip` and
`build/rust-port-windows/Suite42-windows-source.zip`.

## Build on Windows

Install stable Rust with the `x86_64-pc-windows-msvc` toolchain, and Visual Studio Build Tools with the Desktop
C++ workload and Windows SDK. In a Developer PowerShell from the repository root:

```powershell
cd rust
cargo test --locked --workspace
Push-Location scripts
rc.exe /fo windows-app.res windows-app.rc
Pop-Location
$env:RUSTFLAGS = "-C link-arg=$((Resolve-Path scripts/windows-app.res).Path)"
cargo build --locked --release -p img42 -p doc42 -p xls42 -p ppt42 -p pdf42 -p scn42
.\target\release\doc42.exe
```

Run any of the other five executables from `target\release` similarly. Resource compilation embeds common controls
v6 and PerMonitorV2 declarations. The Windows CI workflow contains the corresponding MSVC build. For the existing
macOS/Linux GNU cross-build and archive, install the `x86_64-pc-windows-gnu` Rust target, MinGW-w64 tools and Python 3,
then run `rust/scripts/package-windows.sh` from the repository root. Refresh the source archive after documentation
changes with `rust/scripts/package-source.sh`; it excludes build outputs and local `AGENTS.md` and `STATUS.md`.

## Scope and boundaries

All saves require a new file and refuse to overwrite an existing destination. Core histories include newline policies and PDF42 page-operation Undo/Redo.
When a TXT or CSV file contains no newline, its hidden newline policy cannot be persisted in that file. The Windows
editor refuses NUL, mixed or lone-CR line endings and text it cannot represent. See the source for current exact limits.

| App | Foundation | Boundaries |
| --- | --- | --- |
| DOC42 | Bounded UTF-8 TXT editing, case-sensitive literal Find Next with wrap, atomic Replace All as one Undo, and whitespace word count | No rich document editing or DOCX. The separate [layout probe](crates/doc42-layout-probe/README.md) outputs PNG and trace for a shaping fixture; it is not editor pagination. |
| XLS42 | Computed two-dimensional CSV grid with raw cell editor; add rows and columns | Bounded formulas as described below; no typed XLSX parity, exponent syntax or automatic reference shifts. |
| PPT42 | Title/body and slides in native JSON v2; duplicate preserves policies and creates a new ID | Rejects v1; no PPTX or shapes. |
| PDF42 | Real PDF structure, page commands, rotation, metadata/page info and 20-entry Undo/Redo, including after save | No page renderer. Nested trees can open and rotate; nested reorder/delete are refused. Navigation, forms and annotations are guarded; signatures and encryption are refused. |
| IMG42 | PNG/JPEG pixels, EXIF orientation normalization, rotation, horizontal/vertical flips, nearest-neighbour resize, pixel history and PNG save | No metadata/profile preservation or lossless JPEG parity. |
| SCN42 | Import PNG/JPEG pages, reorder, rotate and flip; save/open versioned raw-RGBA `.scn42` projects; export PDF with alpha composited on white | Projects cap at 32 pages and 16 MiB of current pixels. Opening selects the first page; PDF export does not mark the project clean. No scanner hardware or OCR. |

XLS formulas support decimal numbers, unary signs, `+ - * /`, parentheses, ASCII A1 references and
`SUM`, `AVERAGE`, `MIN` and `MAX` over one rectangular range. CSV numeric strings are inferred as numbers. Blank
references evaluate to zero; text in arithmetic yields `#VALUE!`. Aggregates ignore blank/plain text, include zeros
and propagate formula errors; empty averages yield `#DIV/0!`. Formulas are limited to 4096 bytes, depth 128 and a shared
one-million grid-operation budget (`#LIMIT!`). DOC Find uses UTF-16/CRLF offsets; replacement validates limits before
committing.

The shared `win42` layer uses windows-rs, native system controls, fonts and dialogs, File/Edit/Help menus, View where implemented, and
Ctrl+O, Ctrl+S, Ctrl+Shift+S, Ctrl+Z and Ctrl+Y. Dirty guards protect lifecycle actions. These are implemented
contracts, not evidence of native runtime behavior.

## Next Windows validation

On a logged-in Windows desktop, first exercise native menu and keyboard dispatch, system dialogs, fonts, controls,
resizing, multiple DPI settings, dirty guards and complete Undo/Redo. For each app, save to a new path and reopen:
check DOC find/replace and newline edge cases; XLS grid selection, raw and computed values; PPT slide identity and JSON policy;
PDF page order/rotation, history and guarded inputs; IMG orientation and rendered pixels; SCN project reopen, transparency and PDF
geometry. Check failure paths preserve existing files. Then prioritise missing formats and features from the table.
Do not infer installer, code-signing, trusted PKI, OCR or interoperability coverage from this foundation.

The increment passed 61 workspace tests after the find/planner fixes, followed by 16 affected tests after the final
selection fix; formatting and host and Windows GNU all-target Clippy with warnings denied passed. Independent probes
covered DOC Unicode and atomic replacement, XLS formulas/errors/budget, PDF page content and history, PPT duplicate
identity and policies, IMG pixel transforms and reopen, and SCN project validation, pixels and export dirty state.
The earlier [Windows MSVC CI run](https://github.com/sfzorin/kit42/actions/runs/42187010902) passed tests and builds
for the base commit, not this increment. Interactive GUI, native events and DPI remain unverified; there is no HWND
test harness. The portable event reducer is an actual consumer, not evidence of native event execution. No 20-language
matrix was run. Local audit logs are under `build/rust-features-audit`.

Any eventual commits must use `sfzorin <s.zorin@dannie.cc>` as author and committer, with no additional attribution.
