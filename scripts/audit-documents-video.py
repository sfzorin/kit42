#!/usr/bin/env python3
"""PPT42 movie regression checks. Run after swift build: python3 scripts/audit-documents-video.py."""
from pathlib import Path
import subprocess
import sys
import tempfile
import zipfile


def fixture(path, hidden=False):
    ns = "http://schemas.openxmlformats.org/presentationml/2006/main"
    rel = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as archive:
        archive.writestr("ppt/presentation.xml", f'''<p:presentation xmlns:p="{ns}" xmlns:r="{rel}">
          <p:sldMasterIdLst><p:sldMasterId id="1" r:id="rId1"/></p:sldMasterIdLst>
          <p:sldIdLst><p:sldId id="256" r:id="rId2"/></p:sldIdLst>
          <p:sldSz cx="9144000" cy="5143500"/></p:presentation>''')
        archive.writestr("ppt/_rels/presentation.xml.rels", f'''<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
          <Relationship Id="rId1" Type="{rel}/slideMaster" Target="slideMasters/slideMaster1.xml"/>
          <Relationship Id="rId2" Type="{rel}/slide" Target="slides/slide1.xml"/></Relationships>''')
        archive.writestr("ppt/slideMasters/slideMaster1.xml", f'<p:sldMaster xmlns:p="{ns}"><p:cSld><p:spTree/></p:cSld></p:sldMaster>')
        archive.writestr("ppt/slides/slide1.xml", f'<p:sld xmlns:p="{ns}" show="{0 if hidden else 1}"><p:cSld><p:spTree/></p:cSld></p:sld>')


binary = Path(sys.argv[1] if len(sys.argv) > 1 else ".build/debug/PPT42").resolve()
with tempfile.TemporaryDirectory(prefix="suite42-video-regression-") as folder:
    root = Path(folder)
    source, hidden, target = root / "minimal.pptx", root / "hidden.pptx", root / "existing.mp4"
    fixture(source)
    fixture(hidden, hidden=True)
    existing = b"KEEP EXISTING FILE"
    cases = [(["--width", width], source) for width in ["0", "1", "-2"]]
    cases += [(["--seconds", seconds], source) for seconds in ["0", "nan", "inf"]]
    cases += [([], hidden)]
    for arguments, input_path in cases:
        target.write_bytes(existing)
        result = subprocess.run([str(binary), "--export", str(input_path), str(target), *arguments], capture_output=True, timeout=30)
        assert result.returncode == 1, (arguments, result.returncode, result.stderr.decode(errors="replace"))
        assert target.read_bytes() == existing, "Failed export changed the existing movie"
        assert not list(root.glob(".PPT42-*")), "Temporary movie leaked"
        print("PASS preserves destination:", arguments or "all slides hidden")

    # Verify the successful path replaces an existing destination and creates a new one.
    for existed in [True, False]:
        if existed:
            target.write_bytes(existing)
        else:
            target.unlink()
        result = subprocess.run([str(binary), "--export", str(source), str(target), "--width", "320", "--seconds", "0.1"], capture_output=True, timeout=30)
        assert result.returncode == 0, result.stderr.decode(errors="replace")
        data = target.read_bytes()
        assert len(data) > 100 and data[4:8] == b"ftyp", "No MPEG-4 movie written"
        assert not list(root.glob(".PPT42-*")), "Temporary movie leaked"
        print("PASS movie export:", "replace" if existed else "new file")
print("9/9 passed")
