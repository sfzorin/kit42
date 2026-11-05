#!/usr/bin/env python3
"""DOC42 headless format routing regression (requires pdfinfo and pdftotext from Poppler)."""
from pathlib import Path
import re
import subprocess
import sys
import tempfile


binary = Path(sys.argv[1] if len(sys.argv) > 1 else ".build/debug/DOC42").resolve()


def run(*arguments):
    result = subprocess.run([str(binary), *map(str, arguments)], capture_output=True, timeout=30, check=True)
    return result.stdout.decode(errors="replace")


def stats(path):
    return {key: int(value) for key, value in re.findall(r"^([\w-]+) (\d+)$", run("--stats", path), re.MULTILINE)}


with tempfile.TemporaryDirectory(prefix="suite42-document-cli-") as directory:
    root = Path(directory)
    source, document, restored = root / "source.txt", root / "document.docx", root / "restored.txt"
    text = "Headless document round trip\nРусский текст и Türkçe metin."
    source.write_text(text, encoding="utf-8")
    run("--export", source, document)
    run("--export", document, restored)
    assert restored.read_text(encoding="utf-8").strip() == text
    assert stats(document)["pages"] == 1
    print("PASS --export opens DOCX as a document and preserves Unicode text")

    demo = root / "demo.docx"
    run("--demo", demo)
    information = stats(demo)
    assert 1 <= information["pages"] < 20 and 1000 < information["characters"] < 15000, information
    run("--export", demo, root / "demo.txt")
    plain = (root / "demo.txt").read_text(encoding="utf-8")
    assert all(heading in plain for heading in ["Feature Test", "Introduction", "Conclusion"])
    print(f"PASS --stats reopens the real demo: {information['pages']} pages, {information['characters']} characters")

    for command in ["--pdf", "--export"]:
        pdf = root / (command[2:] + ".pdf")
        run(command, demo, pdf)
        metadata = subprocess.check_output(["pdfinfo", str(pdf)], text=True)
        pages = int(re.search(r"^Pages:\s+(\d+)", metadata, re.MULTILINE).group(1))
        extracted = subprocess.check_output(["pdftotext", str(pdf), "-"], text=True)
        assert pages == information["pages"], (command, pages, information)
        assert all(heading in extracted for heading in ["Feature Test", "Introduction", "Conclusion"])
        print(f"PASS {command} produces {pages} PDF pages containing document text")
print("4/4 passed")
