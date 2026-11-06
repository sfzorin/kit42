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
| DOC42 | Rich text, lists, images and tables with merge/split, sizing and formatting; comments, notes and linked TOC; DOCX, RTF, ODT, HTML and Markdown subsets; ruler, preview and print | Office adapters are bounded; individual table-edge styles and revisions are incomplete. TOC has no page numbers and requires explicit refresh; unsupported annotation or TOC exports refuse fidelity loss. The editing canvas is not fully paginated. Markdown image sidecar saves are not OS-atomic. |
| XLS42 | Native grid with sizing, merged cells, selection, clipboard and inline editing; sheets, formulas, tables, styles, validation, charts, filters and paginated print; XLSX and ODS adapters | Pivot summaries are materialized, not interactive Excel pivots. Dynamic arrays, complex imported tables and structured references are incomplete; complex ODS changes and active filter/print export are guarded. |
| PPT42 | Mixed-run in-place text editing, native objects, multi-selection, grouping and rotation, slides, slideshow and printing; PPTX/ODP adapters | Complex source text and existing source-group structural edits are guarded. Complex source transforms and rotated source groups may be preserved without rendering. Animation, full master/theme semantics, charts and media playback are incomplete. |
| PDF42 | WinRT rendering; PDFium search, selection and supported top-level text-object edits; annotations, forms, bookmarks, attachments, password-prompted PDF open and AES-128 copy, compression, printing, image export and raster redaction | Complex text, forms and navigation remain guarded. Protected files use conservative permissions; new AES-128 passwords require 1–32 printable ASCII characters, and original permissions and encryption are not preserved. Encrypted interoperability is unverified. Redaction removes metadata, attachments, forms and navigation. Trusted digital signatures and PDF/A conformance are not supported. |
| IMG42 | Transforms, tone, text, masks and lasso; directory navigation, GIF/WebP frames, multipage TIFF, PDF and bounded SVG import; standard EXIF fields, DPI/ICC and printing | Proprietary MakerNote, TIFF EXIF subdirectories, palette/CMYK and floating-point TIFF remain limited. TIFF and PNG support 16-bit edits; other 16-bit sources may require conversion. Some PNG metadata requires a converted copy; profile conversion is not color-managed. |
| SCN42 | Asynchronous WIA acquisition, PDF import and WIC processing; v3 projects with DPI and OCR geometry; Tesseract OCR, Unicode searchable PDF, deskew, perspective correction, cleanup, compression, image/TIFF export and printing | OCR needs external Tesseract and language data. Physical devices have not been exercised. |

Shared save snapshots detect changes to existing destinations and use atomic replacement. Multi-file saves stage
sidecars before the main document with verified reuse and best-effort rollback; they are not OS-atomic. Async open
keeps the existing document and session until the new identity is verified and loading succeeds. The apps include
native commands and toolbars, document history, asynchronous work and cancellation. Format support is a subset, and
preservation varies by feature and source file; test important documents before relying on round trips.

## Validation boundary

Workspace tests and cross-build checks do not establish native event dispatch, controls, rendered output, DPI,
printing, scanner acquisition or third-party interoperability. On Windows, exercise actual controls and keyboard
commands, Undo/Redo, failure paths and save/reopen for representative documents in each app. Test PDFium alongside
the packaged executable, print to file, and separately test scanner hardware and installed OCR languages. Retain
fixtures for defects and record the executable identity and any skipped checks.
