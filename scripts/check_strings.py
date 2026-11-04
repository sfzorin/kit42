#!/usr/bin/env python3
"""Finds UI strings without a Russian/Turkish translation and literal UI strings not wrapped in L().
Usage: scripts/check_strings.py  (exit code 1 when something is missing)"""
import re, sys, pathlib

root = pathlib.Path(__file__).resolve().parent.parent / "Sources"
lit = r'"((?:[^"\\]|\\.)*)"'

def table(path):
    keys = set()
    for m in re.finditer(r'\[\s*' + lit + r'\s*,\s*' + lit + r'\s*,\s*' + lit + r'\s*\]', path.read_text()):
        keys.add(m.group(1))
    return keys

# Not translatable: names, examples.
ALLOWED = {"name@example.com", "PDF42", "DOC42", "XLS42", "IMG42", "SCN42", "PDF", "HTML", "CSV"}

kit = table(root / "Kit42/Strings.swift")
problems = 0
for app in ["Kit42", "PDF42", "DOC42", "XLS42", "IMG42", "SCN42"]:
    known = kit | (table(root / app / "Strings.swift") if app != "Kit42" else set())
    # Kit42 strings may be shown by any app: they must be in Kit42's own table.
    missing, unwrapped = {}, []
    for f in sorted((root / app).glob("*.swift")):
        if f.name == "Strings.swift":
            continue
        # Comments are not UI.
        text = "\n".join("" if l.strip().startswith("//") else l for l in f.read_text().split("\n"))
        for m in re.finditer(r'\bL\(\s*' + lit, text):
            key = m.group(1)
            if key not in known:
                missing.setdefault(key, f.name)
        # Literal text put straight into UI.
        for m in re.finditer(r'(labelWithString|wrappingLabelWithString|withTitle|title|messageText|informativeText|placeholderString|toolTip|label)\s*[:=]\s*' + lit, text):
            s = m.group(2)
            if re.search(r'[A-Za-zА-Яа-я]{3}', s) and not s.startswith(("http", "com.", "public.")) and "\\(" not in s \
                    and "L(" not in s and s not in ALLOWED and not re.fullmatch(r'[a-z0-9]+\.[a-z0-9.]+', s):
                line = text[:m.start()].count("\n") + 1
                unwrapped.append(f"{f.name}:{line}: {s}")
    for key, f in sorted(missing.items()):
        print(f"{app}: no translation: {key!r} ({f})"); problems += 1
    for u in unwrapped:
        print(f"{app}: not localized: {u}"); problems += 1
# Quick Look extensions (sandboxed, follow the system language): PL("…") with rows in Previews42/Strings.swift.
ql = table(root / "Previews42/Strings.swift")
for f in sorted((root / "Previews42").glob("*.swift")):
    for m in re.finditer(r'\bPL\(\s*' + lit, f.read_text()):
        if m.group(1) not in ql:
            print(f"Previews42: no translation: {m.group(1)!r} ({f.name})"); problems += 1
print("OK" if problems == 0 else f"{problems} problems")
sys.exit(1 if problems else 0)
