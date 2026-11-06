# Suite42 Windows foundation handoff

This separate Rust workspace provides an early native Windows foundation for all six apps. The macOS Swift apps
remain separate. It was cross-built on macOS, not run on Windows; this is not a Windows release or feature-parity
claim. The intended archives are `build/rust-port-windows/Suite42-windows-x64.zip` and
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

All saves require a new file and refuse to overwrite an existing destination. Supported core histories include newline policies; PDF42 has no Undo/Redo.
When a TXT or CSV file contains no newline, its hidden newline policy cannot be persisted in that file. The Windows
editor refuses NUL, mixed or lone-CR line endings and text it cannot represent. See the source for current exact limits.

| App | Foundation | Boundaries |
| --- | --- | --- |
| DOC42 | Bounded UTF-8 TXT editing | No rich document editing or DOCX. The separate [layout probe](crates/doc42-layout-probe/README.md) outputs PNG and trace for a shaping fixture; it is not editor pagination. |
| XLS42 | Two-dimensional grid of raw CSV cells; add rows and columns | Formulas remain text and are not calculated. |
| PPT42 | Title/body and slides in native JSON v2, stable IDs and policies | Rejects v1; no PPTX or shapes. |
| PDF42 | Real PDF structure, page commands, rotation and save | No PDF page reader, renderer or Undo/Redo. Nested trees can open and rotate; nested reorder/delete are refused. Navigation, forms and annotations are guarded; signatures and encryption are refused. |
| IMG42 | PNG/JPEG pixels, EXIF orientation normalization, rotation, history and PNG save | No metadata/profile preservation or lossless JPEG parity. |
| SCN42 | Import PNG/JPEG pages, reorder and rotate, export PDF with alpha composited on white | No scanner hardware, OCR or project reopen. |

The shared `win42` layer uses windows-rs, native system controls, fonts and dialogs, File/Edit/Help menus, View where implemented, and
Ctrl+O, Ctrl+S, Ctrl+Shift+S, Ctrl+Z and Ctrl+Y. Dirty guards protect lifecycle actions. These are implemented
contracts, not evidence of native runtime behavior.

## Next Windows validation

On a logged-in Windows desktop, first exercise native menu and keyboard dispatch, system dialogs, fonts, controls,
resizing, multiple DPI settings, dirty guards and complete Undo/Redo. For each app, save to a new path and reopen:
check DOC text and newline edge cases; XLS grid destinations and formula text; PPT slide identity and JSON policy;
PDF page order/rotation and guarded inputs; IMG orientation and rendered pixels; SCN page order, transparency and PDF
geometry. Check failure paths preserve existing files. Then prioritise missing formats and features from the table.
Do not infer installer, code-signing, trusted PKI, OCR or interoperability coverage from this foundation.

The final independent workspace run passed 45 tests, formatting, and host and `x86_64-pc-windows-gnu` all-target
Clippy with warnings denied. Cross-target check passed before the final schema declaration; final Clippy compiled the
latest code. Independent probes covered pixels and EXIF permutations, PNG output, TXT/CSV round trips and failures,
PDF page structure and encrypted refusal, scan alpha/PDF geometry and slide newline/identity/history. The separate
DOC fixture rendered four default pages and seven after width/font changes, with visual inspection; no 20-language
matrix was run. Logs are local under `build/rust-port-audit`. Native Windows remains untested.

Any eventual commits must use `sfzorin <s.zorin@dannie.cc>` as author and committer, with no additional attribution.
