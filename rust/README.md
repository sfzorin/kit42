# Suite42 for Windows

This separate Rust workspace implements six native Windows apps; the macOS Swift apps remain separate. The current
implementation is a work in progress, not a feature-parity or Windows release claim. Native interaction, printing,
scanner hardware and PDFium interoperability still need testing on a logged-in Windows desktop.

## Build and run

Install stable Rust with the `x86_64-pc-windows-msvc` toolchain, Visual Studio Build Tools with the Desktop C++
workload and Windows SDK, and Python 3. In a Developer PowerShell from the repository root:

```powershell
cd rust
cargo test --locked --workspace
Push-Location scripts
rc.exe /fo windows-app.res windows-app.rc
Pop-Location
$env:RUSTFLAGS = "-C link-arg=$((Resolve-Path scripts/windows-app.res).Path)"
cargo build --locked --release -p img42 -p doc42 -p xls42 -p ppt42 -p pdf42 -p scn42
python scripts/fetch-pdfium.py target/release
.\target\release\pdf42.exe
```

Run the other apps from `target/release` similarly. The resource embeds common controls v6 and PerMonitorV2
settings. PDF42 uses the adjacent `pdfium.dll` for text search and selection; the fetch script supplies a pinned
runtime and licenses. `PDFIUM_ARCHIVE` can select a local pinned archive. A custom `PDFIUM_DLL` also requires
`PDFIUM_DLL_SHA256` and `PDFIUM_LICENSE_DIR`. SCN42 OCR requires a separately installed Tesseract executable and
language data; select its path and available languages in the app.

For a GNU cross-build on macOS or Linux, install the `x86_64-pc-windows-gnu` Rust target, MinGW-w64 tools and
Python 3, then run `rust/scripts/package-windows.sh` from the repository root. It creates
`build/rust-port-windows/Suite42-windows-x64.zip` with PDFium and licenses. `rust/scripts/package-source.sh` creates
the source archive and excludes build outputs and local `AGENTS.md` and `STATUS.md`. Cross-building does not verify
Windows runtime behavior. The Windows CI workflow also builds with MSVC.

## Implemented scope and limits

| App | Current implementation | Important limits |
| --- | --- | --- |
| DOC42 | Rich text styles, tables, images and lists; DOCX, RTF, ODT, HTML and Markdown subsets; draggable ruler, paginated preview and print with simple header/footer page fields | Format adapters are bounded; imported Office layout and advanced formatting are incomplete. ODT header/page edits are rejected, and the editing canvas is not fully paginated. |
| XLS42 | Sheets, styles, formulas, validation, conditional formatting, XLSX charts, materialized pivot summaries, filters and paginated print; external XLSX/ODS adapters preserve cell, style and merge edits | Pivot export is not an interactive Excel pivot. External structural, chart and rule preservation and advanced functions are incomplete. |
| PPT42 | Native objects, slides, slideshow and printing; source-preserving PPTX/ODP adapters, inserts and slide operations | Mixed per-run text, rotated/flipped groups, full master/theme semantics and advanced Office fidelity are incomplete; charts and media playback are incomplete. |
| PDF42 | WinRT page rendering; PDFium text search/selection; Unicode multiline, ink and shape annotations and forms; outlines, attachments, compression, range printing and PNG/JPEG ZIP export; all-page raster redaction | Some annotation, form, navigation and page-label operations are guarded. Redaction removes original metadata, attachments, forms and navigation. Digital signing, reusable/image stamps and headers/footers are absent; no conformance claim. |
| IMG42 | Image transforms, tone, text and masks; directory navigation, GIF/WebP frames and multipage TIFF; selected-codec DPI/ICC and all-frame printing | EXIF and 16-bit data are not generally preserved; loss-aware Save As routes conversions to a new copy. TIFF palette, CMYK and floating-point inputs are unsupported. |
| SCN42 | Asynchronous WIA acquisition and WIC processing; v3 projects with DPI and OCR geometry; Tesseract OCR, Unicode searchable PDF, deskew, perspective correction, cleanup, image/TIFF export and printing | PDF import and compression options are incomplete; OCR needs external Tesseract and language data. Physical devices have not been exercised. |

The shared save snapshot detects changes to an existing destination and uses atomic replacement. The apps include
native commands and toolbars, document history, asynchronous work and cancellation. Format support is a subset, and
preservation varies by feature and source file; test important documents before relying on round trips.

## Validation boundary

Workspace tests and cross-build checks do not establish native event dispatch, controls, rendered output, DPI,
printing, scanner acquisition or third-party interoperability. On Windows, exercise actual controls and keyboard
commands, Undo/Redo, failure paths and save/reopen for representative documents in each app. Test PDFium alongside
the packaged executable, print to file, and separately test scanner hardware and installed OCR languages. Retain
fixtures for defects and record the executable identity and any skipped checks.
