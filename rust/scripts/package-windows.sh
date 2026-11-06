#!/bin/sh
# Cross-build a portable Windows x64 archive. Requires Rust target, MinGW-w64 and Python 3.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
TARGET=x86_64-pc-windows-gnu
OUT="$ROOT/build/rust-port-windows"
command -v x86_64-w64-mingw32-gcc >/dev/null
command -v x86_64-w64-mingw32-objdump >/dev/null
cd "$ROOT/rust"
command -v x86_64-w64-mingw32-windres >/dev/null
mkdir -p "$OUT"
(cd scripts && x86_64-w64-mingw32-windres windows-app.rc -O coff -o "$OUT/windows-app-res.o")
RUSTFLAGS="${RUSTFLAGS:-} -C link-arg=$OUT/windows-app-res.o" cargo build --locked --release --target "$TARGET" -p img42 -p doc42 -p xls42 -p ppt42 -p pdf42 -p scn42
mkdir -p "$OUT"
STAGE=$(mktemp -d "$OUT/.package.XXXXXXXX")
trap 'rm -rf "$STAGE"' EXIT HUP INT TERM
mkdir -p "$STAGE/Suite42/licenses"
for app in img42 doc42 xls42 ppt42 pdf42 scn42; do
    NAME=$(printf '%s' "$app" | tr '[:lower:]' '[:upper:]')
    cp "target/$TARGET/release/$app.exe" "$STAGE/Suite42/$NAME.exe"
    x86_64-w64-mingw32-objdump -p "$STAGE/Suite42/$NAME.exe" > "$OUT/$NAME-objdump.txt"
    cp "$STAGE/Suite42/$NAME.exe" "$OUT/$NAME.exe"
done
cp "$ROOT/LICENSE" "$STAGE/Suite42/licenses/Suite42-LICENSE"
cat > "$STAGE/Suite42/README.txt" <<'TEXT'
Suite42 for Windows x64 — preliminary build

IMG42: PNG/JPEG image rotation, flips, nearest-neighbour resize and new PNG output.
DOC42: UTF-8 plain text editing, find and replace all.
XLS42: CSV editing with bounded formula calculation; formulas are saved as raw CSV text.
PPT42: basic slide title/body and slide duplication in Suite42 JSON, not PPTX.
PDF42: selected PDF page structure operations with Undo/Redo; no page renderer.
SCN42: import image pages, save/reopen editable projects and export PDF; no scanner acquisition or OCR.
Save As requires a NEW file. Existing files cannot be overwritten.
Image metadata, profiles and animation are not retained in saved output.
This cross-built executable has not been run or validated on Windows.
TEXT
cargo metadata --locked --format-version 1 --filter-platform "$TARGET" > "$STAGE/metadata.json"
python3 - "$STAGE/metadata.json" "$STAGE/Suite42/licenses" <<'PY'
import json, pathlib, shutil, sys
m = json.load(open(sys.argv[1], encoding='utf-8'))
out = pathlib.Path(sys.argv[2])
# Include all resolved crates (including build-time dependencies), conservatively.
resolved = {n['id'] for n in m['resolve']['nodes']}
with (out / 'DEPENDENCIES.txt').open('w', encoding='utf-8') as f:
    for p in sorted(m['packages'], key=lambda p: (p['name'], p['version'])):
        if p['id'] not in resolved or p['source'] is None:
            continue
        f.write(f"{p['name']} {p['version']}: {p.get('license') or 'see included license files'}\n")
        directory = pathlib.Path(p['manifest_path']).parent
        files = [x for x in directory.iterdir() if x.is_file() and x.name.upper().startswith(('LICENSE', 'LICENCE', 'COPYING', 'NOTICE'))]
        if p.get('license_file'):
            files.append(directory / p['license_file'])
        dest = out / f"{p['name']}-{p['version']}"
        for index, src in enumerate(dict.fromkeys(files)):
            if src.is_file():
                dest.mkdir(exist_ok=True)
                shutil.copyfile(src, dest / f'{index}-{src.name}')
PY
RUST_LICENSES="$(rustc --print sysroot)/share/doc/rust/licenses"
if [ -d "$RUST_LICENSES" ]; then cp -R "$RUST_LICENSES" "$STAGE/Suite42/licenses/rust-toolchain"; fi
rm -f "$OUT/Suite42-windows-x64.zip"
(cd "$STAGE" && zip -qr "$OUT/Suite42-windows-x64.zip" Suite42)
shasum -a 256 "$OUT"/*.exe "$OUT/Suite42-windows-x64.zip"
