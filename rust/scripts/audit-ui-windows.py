#!/usr/bin/env python3
"""Exercise native windows and production dialogs through their normal commands."""
import argparse
import ctypes as c
from ctypes import wintypes as w
import hashlib
import json
import os
from pathlib import Path
import struct
import subprocess
import time
import traceback
import uuid
import zlib

if os.name != "nt":
    raise SystemExit("Run this audit on Windows.")

u = c.WinDLL("user32", use_last_error=True)
u.EnumWindows.argtypes = [c.WINFUNCTYPE(w.BOOL, w.HWND, w.LPARAM), w.LPARAM]
u.EnumChildWindows.argtypes = [w.HWND] + u.EnumWindows.argtypes
u.GetWindowThreadProcessId.argtypes = [w.HWND, c.POINTER(w.DWORD)]
u.GetClassNameW.argtypes = [w.HWND, w.LPWSTR, c.c_int]
u.GetWindowTextLengthW.argtypes = [w.HWND]
u.GetWindowTextW.argtypes = [w.HWND, w.LPWSTR, c.c_int]
u.GetDlgItem.argtypes = [w.HWND, c.c_int]
u.GetDlgItem.restype = w.HWND
u.GetDlgCtrlID.argtypes = [w.HWND]
u.IsWindowVisible.argtypes = [w.HWND]
u.IsWindowEnabled.argtypes = [w.HWND]
u.SetForegroundWindow.argtypes = [w.HWND]
u.PostMessageW.argtypes = [w.HWND, w.UINT, w.WPARAM, w.LPARAM]
u.SendMessageW.argtypes = [w.HWND, w.UINT, w.WPARAM, w.LPARAM]
u.SendMessageW.restype = w.LPARAM
WM_COMMAND, WM_SETTEXT, WM_CLOSE = 0x111, 0xC, 0x10


def text(hwnd):
    length = u.SendMessageW(hwnd, 0xE, 0, 0)  # WM_GETTEXTLENGTH marshals cross-process controls.
    value = c.create_unicode_buffer(length + 1)
    u.SendMessageW(hwnd, 0xD, len(value), c.cast(value, c.c_void_p).value)
    return value.value


def classname(hwnd):
    value = c.create_unicode_buffer(256)
    u.GetClassNameW(hwnd, value, len(value))
    return value.value


def windows(pid, parent=None):
    found = []
    @c.WINFUNCTYPE(w.BOOL, w.HWND, w.LPARAM)
    def collect(hwnd, _):
        owner = w.DWORD()
        u.GetWindowThreadProcessId(hwnd, c.byref(owner))
        if owner.value == pid and u.IsWindowVisible(hwnd):
            found.append(hwnd)
        return True
    if parent:
        u.EnumChildWindows(parent, collect, 0)
    else:
        u.EnumWindows(collect, 0)
    return found


def wait_for(predicate, description, process, timeout=25):
    until = time.monotonic() + timeout
    while time.monotonic() < until:
        result = predicate()
        if result:
            return result
        if process.poll() is not None:
            raise AssertionError(f"App exited while waiting for {description}, code {process.returncode}")
        time.sleep(0.05)
    snapshot = [(classname(h), text(h), [(classname(c), text(c)) for c in windows_for_dialog(h)]) for h in windows(process.pid)]
    raise AssertionError(f"Timed out waiting for {description}. Windows: {snapshot}")


def modal(process, title=None, native_class=None):
    return wait_for(lambda: next((h for h in windows(process.pid)
        if u.IsWindowEnabled(h) and (title is None or text(h) == title)
        and (native_class is None or classname(h) == native_class)), None),
        title or native_class or "modal", process)


def command(hwnd, identifier):
    assert u.PostMessageW(hwnd, WM_COMMAND, identifier, 0)


def click(dialog, identifier):
    button = u.GetDlgItem(dialog, identifier)
    if not button and identifier == 1:
        matches = [h for h in windows_for_dialog(dialog) if classname(h).lower() == "button" and text(h).replace("&", "").lower() in {"ok", "save", "open"}]
        if len(matches) == 1:
            button = matches[0]
    assert button, [(classname(h), u.GetDlgCtrlID(h), text(h)) for h in windows_for_dialog(dialog)]
    u.SetForegroundWindow(dialog)
    assert u.PostMessageW(button, 0xF5, 0, 0)  # BM_CLICK


def windows_for_dialog(dialog):
    pid = w.DWORD()
    u.GetWindowThreadProcessId(dialog, c.byref(pid))
    return windows(pid.value, dialog)


def set_text(hwnd, value):
    data = c.create_unicode_buffer(value)
    u.SendMessageW(hwnd, WM_SETTEXT, 0, c.cast(data, c.c_void_p).value)
    assert text(hwnd) == value, (classname(hwnd), u.GetDlgCtrlID(hwnd), text(hwnd), value)


def fill_prompt(process, main, identifier, title, values):
    command(main, identifier)
    dialog = modal(process, title=title, native_class="Suite42InputDialog")
    for index, value in enumerate(values):
        control = u.GetDlgItem(dialog, 100 + index)
        assert control, f"Missing field {index} in {title}"
        set_text(control, value)
    click(dialog, 1)
    return dialog


def choose_file(process, path):
    def filename_control():
        for dialog in windows(process.pid):
            if classname(dialog) != "#32770" or not u.IsWindowEnabled(dialog):
                continue
            edits = [h for h in windows(process.pid, dialog) if classname(h).lower() == "edit"]
            control = next((h for h in edits if u.GetDlgCtrlID(h) in (1148, 1001)), edits[0] if len(edits) == 1 else None)
            if control:
                return dialog, control
        return None
    dialog, control = wait_for(filename_control, "file dialog filename field", process)
    set_text(control, str(path))
    click(dialog, 1)


def output_ready(process, main, path, signature):
    wait_for(lambda: path.is_file() and path.stat().st_size > 32 and u.IsWindowEnabled(main), str(path), process)
    assert path.read_bytes().startswith(signature), path


def minimal_pdf(path):
    objects = [b"<< /Type /Catalog /Pages 2 0 R >>", b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Contents 4 0 R >>", b"<< /Length 0 >>\nstream\n\nendstream"]
    data = bytearray(b"%PDF-1.4\n")
    offsets = [0]
    for number, obj in enumerate(objects, 1):
        offsets.append(len(data))
        data.extend(f"{number} 0 obj\n".encode() + obj + b"\nendobj\n")
    xref = len(data)
    data.extend(f"xref\n0 {len(offsets)}\n0000000000 65535 f \n".encode())
    for offset in offsets[1:]:
        data.extend(f"{offset:010d} 00000 n \n".encode())
    data.extend(f"trailer\n<< /Root 1 0 R /Size {len(offsets)} >>\nstartxref\n{xref}\n%%EOF\n".encode())
    path.write_bytes(data)


def write_png(path, width, height, rgba):
    def chunk(name, data):
        return struct.pack(">I", len(data)) + name + data + struct.pack(">I", zlib.crc32(name + data))
    rows = b"".join(b"\0" + rgba[y * width * 4:(y + 1) * width * 4] for y in range(height))
    path.write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b""))


def png_pixels(path):
    data = path.read_bytes()
    assert data.startswith(b"\x89PNG\r\n\x1a\n")
    offset, compressed = 8, bytearray()
    while offset < len(data):
        size = struct.unpack_from(">I", data, offset)[0]
        kind = data[offset + 4:offset + 8]
        payload = data[offset + 8:offset + 8 + size]
        if kind == b"IHDR":
            width, height, depth, color, _, _, interlace = struct.unpack(">IIBBBBB", payload)
            assert depth == 8 and color in (2, 6) and interlace == 0
        elif kind == b"IDAT":
            compressed.extend(payload)
        offset += size + 12
    channels = 4 if color == 6 else 3
    stride = width * channels
    raw, rows, previous = zlib.decompress(compressed), [], bytearray(stride)
    for row in range(height):
        start = row * (stride + 1)
        mode, line = raw[start], bytearray(raw[start + 1:start + stride + 1])
        for index in range(stride):
            left = line[index - channels] if index >= channels else 0
            above = previous[index]
            corner = previous[index - channels] if index >= channels else 0
            if mode == 1:
                predictor = left
            elif mode == 2:
                predictor = above
            elif mode == 3:
                predictor = (left + above) // 2
            elif mode == 4:
                prediction = left + above - corner
                scores = [(abs(prediction - value), order, value) for order, value in enumerate((left, above, corner))]
                predictor = min(scores)[2]
            else:
                assert mode == 0
                predictor = 0
            line[index] = (line[index] + predictor) & 255
        rows.extend(line[i:i + 3] + b"\xff" for i in range(0, stride, channels))
        previous = line
    return width, height, b"".join(rows)


def finish_prompt(process, title, values):
    dialog = modal(process, title=title, native_class="Suite42InputDialog")
    for index, value in enumerate(values):
        control = u.GetDlgItem(dialog, 100 + index)
        assert control
        set_text(control, value)
    click(dialog, 1)


def audit_marks(process, main, binary, output, results):
    source = output / f"audit-mark-{uuid.uuid4().hex}.png"
    write_png(source, 2, 2, bytes([255,255,255,255, 0,0,0,255, 0,0,255,255, 255,255,255,255]))
    library = Path(os.environ["LOCALAPPDATA"]) / "off42" / "Signatures and Stamps" / ("Mark - " + source.stem + ".png")
    try:
        command(main, 65516)
        choose_file(process, source)
        finish_prompt(process, "Import Signature or Stamp", ["yes"])
        message = modal(process, native_class="#32770")
        click(message, 1)
        wait_for(lambda: library.is_file() and u.IsWindowEnabled(main), "shared library import", process)
        command(main, 65515)
        choose_file(process, library)
        finish_prompt(process, "Place Signature or Stamp", ["8", "12", "20", "20"])
        wait_for(lambda: u.IsWindowEnabled(main), "mark placed", process)
        def export(name):
            path = output / f"{binary.stem}-{name}.png"
            command(main, 31 if binary.stem.lower() == "scn42" else 18)
            choose_file(process, path)
            output_ready(process, main, path, b"\x89PNG\r\n\x1a\n")
            return png_pixels(path)
        marked = export("marked")
        assert marked[:2] == (64, 64)
        pixels = marked[2]
        assert any(value != 255 for value in pixels)
        for y in range(64):
            for x in range(64):
                if not (8 <= x < 28 and 12 <= y < 32):
                    assert pixels[(y * 64 + x) * 4:(y * 64 + x + 1) * 4] == bytes([255] * 4)
        command(main, 4)
        restored = export("undo")
        assert restored[2] == bytes([255] * (64 * 64 * 4))
        command(main, 5)
        assert export("redo") == marked
        if binary.stem.lower() == "scn42":
            project = output / "marked.scn42"
            command(main, 18)
            choose_file(process, project)
            wait_for(lambda: project.is_file() and u.IsWindowEnabled(main), "scan project saved", process)
            command(main, 1)
            choose_file(process, project)
            wait_for(lambda: project.name in text(main) and u.IsWindowEnabled(main), "scan project reopened", process)
            assert export("reopened") == marked
        results["checks"].append("shared mark import, white cleanup, placement, pixel bounds, Undo/Redo and saved output")
    finally:
        if library.exists():
            library.unlink()


def audit_sheet_pictures(process, main, output, results):
    source = output / "sheet-own-stamp.png"
    write_png(source, 20, 10, bytes([255, 0, 0, 255] * 200))
    command(main, 76)
    choose_file(process, source)
    wait_for(lambda: u.IsWindowEnabled(main), "picture inserted", process)
    fill_prompt(process, main, 77, "Picture Position and Size", ["2", "2", "6", "6", "30", "15"])
    wait_for(lambda: u.IsWindowEnabled(main), "picture geometry applied", process)
    project = output / "pictures.xls42"
    command(main, 18)
    choose_file(process, project)
    output_ready(process, main, project, b"{")
    def picture():
        images = json.loads(project.read_text(encoding="utf-8"))["sheets"][0]["images"]
        return images[0] if images else None
    original = picture()
    assert (original["row"], original["column"], original["width_points"], original["height_points"]) == (1, 1, 30, 15)
    grid = u.GetDlgItem(main, 102)
    assert classname(grid) == "Off42VariableGrid"
    gdi = c.WinDLL("gdi32", use_last_error=True)
    gdi.GetPixel.argtypes = [w.HDC, c.c_int, c.c_int]
    gdi.GetPixel.restype = w.DWORD
    u.GetDC.argtypes, u.GetDC.restype = [w.HWND], w.HDC
    u.ReleaseDC.argtypes = [w.HWND, w.HDC]
    def red(x, y):
        dc = u.GetDC(grid)
        try:
            return gdi.GetPixel(dc, x, y) == 0x0000FF
        finally:
            u.ReleaseDC(grid, dc)
    wait_for(lambda: red(150, 63), "rendered picture pixels", process)
    def point(x, y):
        return (y << 16) | x
    u.SendMessageW(grid, 0x201, 1, point(150, 63))
    u.SendMessageW(grid, 0x200, 1, point(230, 83))
    u.SendMessageW(grid, 0x202, 0, point(230, 83))
    command(main, 2)
    wait_for(lambda: picture()["column"] == 2 and picture()["row"] == 2, "drag saved at the new anchor", process)
    moved = picture()
    wait_for(lambda: red(230, 83), "picture renders after dragging", process)
    command(main, 4)
    command(main, 2)
    wait_for(lambda: picture() == original, "Undo restores complete picture geometry", process)
    command(main, 5)
    command(main, 2)
    wait_for(lambda: picture() == moved, "Redo restores complete picture geometry", process)
    command(main, 78)
    command(main, 2)
    wait_for(lambda: picture() is None, "picture deletion saved", process)
    command(main, 4)
    command(main, 2)
    wait_for(lambda: picture() == moved, "Undo restores deleted picture and data", process)
    command(main, 1)
    choose_file(process, project)
    wait_for(lambda: project.name in text(main) and u.IsWindowEnabled(main), "picture project reopened", process)
    wait_for(lambda: red(230, 83), "saved picture renders after reopening", process)
    results["checks"].append("spreadsheet picture insertion, exact geometry, native pixels, mouse drag, Undo/Redo, deletion and reopen")


def audit_technical_objects(process, main, binary, output, results):
    fill_prompt(process, main, 65509, "Symbol or Code", ["QR", "PCB-0007", "20", "no"])
    wait_for(lambda: u.IsWindowEnabled(main), "technical object inserted", process)
    def editor_value(expected, change=False):
        command(main, 65508)
        dialog = modal(process, title="Symbol or Code", native_class="Suite42InputDialog")
        actual = text(u.GetDlgItem(dialog, 101))
        assert actual == expected, {"expected": expected, "actual": actual, "saved": text(main)}
        if change:
            set_text(u.GetDlgItem(dialog, 101), "PCB-0008")
            set_text(u.GetDlgItem(dialog, 102), "25")
        click(dialog, 1 if change else 2)
        wait_for(lambda: u.IsWindowEnabled(main), "technical editor closed", process)
    editor_value("PCB-0007", True)
    extension = {"doc42": "doc42", "xls42": "xls42", "pdf42": "pdf", "ppt42": "json"}[binary.stem.lower()]
    saved = output / f"{binary.stem}-technical.{extension}"
    command(main, 18)
    choose_file(process, saved)
    output_ready(process, main, saved, b"%PDF-" if extension == "pdf" else b"{")
    command(main, 4)
    editor_value("PCB-0007")
    command(main, 5)
    editor_value("PCB-0008")
    command(main, 1)
    choose_file(process, saved)
    wait_for(lambda: saved.name in text(main) and u.IsWindowEnabled(main), "technical document reopened", process)
    editor_value("PCB-0008")
    results["checks"].append("technical object insertion, recipe editing, Undo/Redo and edit after saved-document reopen")


def pdf_text(dll_path, path):
    pdf = c.WinDLL(str(dll_path))
    pdf.FPDF_LoadDocument.argtypes, pdf.FPDF_LoadDocument.restype = [c.c_char_p, c.c_char_p], c.c_void_p
    pdf.FPDF_GetPageCount.argtypes = [c.c_void_p]
    pdf.FPDF_LoadPage.argtypes, pdf.FPDF_LoadPage.restype = [c.c_void_p, c.c_int], c.c_void_p
    pdf.FPDFText_LoadPage.argtypes, pdf.FPDFText_LoadPage.restype = [c.c_void_p], c.c_void_p
    pdf.FPDFText_CountChars.argtypes = [c.c_void_p]
    pdf.FPDFText_GetText.argtypes = [c.c_void_p, c.c_int, c.c_int, c.POINTER(c.c_ushort)]
    for name in ("FPDF_CloseDocument", "FPDF_ClosePage", "FPDFText_ClosePage"):
        getattr(pdf, name).argtypes = [c.c_void_p]
    pdf.FPDF_InitLibrary()
    document = pdf.FPDF_LoadDocument(str(path).encode("utf-8"), None)
    assert document, str(path)
    try:
        output = []
        assert 0 < pdf.FPDF_GetPageCount(document) <= 1000
        for index in range(pdf.FPDF_GetPageCount(document)):
            page = pdf.FPDF_LoadPage(document, index)
            assert page
            text_page = pdf.FPDFText_LoadPage(page)
            assert text_page
            try:
                count = pdf.FPDFText_CountChars(text_page)
                assert 0 <= count <= 500_000
                data = (c.c_ushort * (count + 1))()
                length = pdf.FPDFText_GetText(text_page, 0, count, data)
                output.append(bytes(data)[:max(0, length - 1) * 2].decode("utf-16-le"))
            finally:
                pdf.FPDFText_ClosePage(text_page)
                pdf.FPDF_ClosePage(page)
        return "\n".join(output)
    finally:
        pdf.FPDF_CloseDocument(document)
        pdf.FPDF_DestroyLibrary()


def audit_table_labels(process, main, binary, output, results):
    source = output / "table-label-source.rtf"
    body = br"{\rtf1\ansi\deff0{\fonttbl{\f0 Arial;}}"
    for row in [("Name", "Code", "Copies"), ("Board 0007", "PCB-0007", "2"), ("Board 0008", "PCB-0008", "1")]:
        body += br"\trowd\cellx1600\cellx3200\cellx4000\pard\intbl "
        body += b"\\cell ".join(value.encode("ascii") for value in row) + br"\cell\row "
    body += br"\pard\par}"
    source.write_bytes(body)
    command(main, 1)
    choose_file(process, source)
    wait_for(lambda: source.name in text(main) and u.IsWindowEnabled(main), "table document opened", process)
    command(main, 65518)
    finish_prompt(process, "Label Source", ["Table 1"])
    fields = ["1", "2, 3, 1", "QR", "70, 37, 0, 0", "1, 1"]
    finish_prompt(process, "Create Label Sheet", fields)
    target = output / "table-labels.pdf"
    choose_file(process, target)
    output_ready(process, main, target, b"%PDF-")
    actual = pdf_text(binary.parent / "pdfium.dll", target)
    assert actual.count("Board 0007") == 2, actual
    assert actual.count("Board 0008") == 1, actual
    assert "Name" not in actual and "Copies" not in actual, actual
    assert source.read_bytes() == body and "*" not in text(main)
    command(main, 65518)
    finish_prompt(process, "Label Source", ["Table 1"])
    dialog = modal(process, title="Create Label Sheet", native_class="Suite42InputDialog")
    actual_fields = [text(u.GetDlgItem(dialog, 100 + index)) for index in range(5)]
    assert actual_fields == fields, actual_fields
    click(dialog, 2)
    wait_for(lambda: u.IsWindowEnabled(main), "remembered label settings dismissed", process)
    results["checks"].append("DOC table label source, mapped text/code/copies, skipped header, PDFium text, unchanged source and restored preferences")


def audit(binary, output, extended, pictures=False, technical=False, labels=False):
    startup = None
    if extended:
        if binary.stem.lower() == "pdf42":
            startup = output / "startup.pdf"
            minimal_pdf(startup)
        elif binary.stem.lower() == "xls42":
            startup = output / "startup.csv"
            startup.write_text("Name,Code,,,,,,\nBoard 0007,PCB-0007,,,,,,\nBoard 0008,PCB-0008,,,,,,\n", encoding="utf-8")
        elif binary.stem.lower() in {"img42", "scn42"}:
            startup = output / (binary.stem + "-canvas.png")
            write_png(startup, 64, 64, bytes([255] * (64 * 64 * 4)))
        elif binary.stem.lower() == "doc42":
            startup = output / "startup.rtf"
            startup.write_bytes(br"{\rtf1\ansi Board 0007}")
    environment = os.environ.copy()
    environment["OFF42_UI_TRACE_FILE"] = str(output / (binary.stem + "-commands.log"))
    process = subprocess.Popen([str(binary)] + ([str(startup)] if startup else []), env=environment)
    results = {"app": binary.name, "sha256": hashlib.sha256(binary.read_bytes()).hexdigest(), "checks": []}
    try:
        main = modal(process, native_class="Suite42Native")
        results["checks"].append("native main window visible")
        if startup:
            if binary.stem.lower() == "scn42":
                wait_for(lambda: any(text(h).startswith("1 pages |") for h in windows(process.pid, main)), "scan image import", process)
            else:
                wait_for(lambda: startup.name in text(main) and u.IsWindowEnabled(main), "command-line file open", process)
            results["checks"].append("command-line file open reaches the normal document session")
        command(main, 6)
        about = modal(process, native_class="#32770")
        content = " ".join(text(h) for h in windows(process.pid, about))
        assert binary.stem.upper() in content, content
        click(about, 1)
        wait_for(lambda: u.IsWindowEnabled(main), "About closed", process)
        results["checks"].append("About command identifies app and closes")
        if extended and binary.stem.lower() in {"doc42", "ppt42"}:
            edit = u.GetDlgItem(main, 101)
            assert u.SendMessageW(edit, 1024 + 121, 0, 0) & 0x0800
            command(main, 65510)
            wait_for(lambda: not (u.SendMessageW(edit, 1024 + 121, 0, 0) & 0x0800), "spelling disabled", process)
            command(main, 65510)
            wait_for(lambda: u.SendMessageW(edit, 1024 + 121, 0, 0) & 0x0800, "spelling enabled", process)
            results["checks"].append("native inline proofing flags follow the menu toggle")
        if extended and binary.stem.lower() in {"img42", "scn42"}:
            audit_marks(process, main, binary, output, results)
        if binary.stem.lower() not in {"doc42", "pdf42", "xls42"}:
            if technical and binary.stem.lower() == "ppt42":
                audit_technical_objects(process, main, binary, output, results)
            return results
        if binary.stem.lower() == "pdf42" and not startup:
            source = output / "input.pdf"
            minimal_pdf(source)
            command(main, 1)
            choose_file(process, source)
            wait_for(lambda: source.name in text(main) and u.IsWindowEnabled(main), "PDF open", process)
        elif binary.stem.lower() == "xls42":
            if not startup:
                source = output / "input.csv"
                source.write_text("Name,Code\nBoard 0007,PCB-0007\nBoard 0008,PCB-0008\n", encoding="utf-8")
                command(main, 1)
                choose_file(process, source)
                wait_for(lambda: source.name in text(main) and u.IsWindowEnabled(main), "CSV open", process)
            fill_prompt(process, main, 25, "Range (1-based)", ["1", "1", "3", "2"])
            wait_for(lambda: u.IsWindowEnabled(main), "range selected", process)
        png = output / f"{binary.stem}-barcode.png"
        fill_prompt(process, main, 65517, "Create Barcode", ["PCB-0007", "Code 128", "55"])
        choose_file(process, png)
        output_ready(process, main, png, b"\x89PNG\r\n\x1a\n")
        width, height = struct.unpack_from(">II", png.read_bytes(), 16)
        assert width > 100 and height > 20
        results["checks"].append("barcode created through native dialog and saved as PNG")
        pdf = output / f"{binary.stem}-labels.pdf"
        fields = (["1", "2, 0, 1", "Code 128", "100, 140, 2, 2", "1, 4"]
            if binary.stem.lower() == "xls42" else
            ["Board 0007", "PCB-0007", "Code 128", "100, 140, 2, 2", "2, 4"])
        fill_prompt(process, main, 65518, "Create Label Sheet", fields)
        choose_file(process, pdf)
        output_ready(process, main, pdf, b"%PDF-")
        results["checks"].append("label sheet created through native dialog and saved as PDF")
        if extended:
            preset = output / f"{binary.stem}-stock.pdf"
            fields[3] = "AVERY L4732 — 35.6 × 16.9 mm"
            fields[2] = "QR"
            fields[4] = "1, 1"
            if binary.stem.lower() == "xls42":
                fields[0], fields[1] = "1", "0, 0, 1"
            else:
                fields[0], fields[1] = "Board", ""
            fill_prompt(process, main, 65518, "Create Label Sheet", fields)
            choose_file(process, preset)
            output_ready(process, main, preset, b"%PDF-")
            results["checks"].append("named stock selected through the native combo box")
            symbol = output / f"{binary.stem}-symbol.png"
            fill_prompt(process, main, 65514, "Symbol or Code", ["Protective earth", "", "20", "no"])
            choose_file(process, symbol)
            output_ready(process, main, symbol, b"\x89PNG\r\n\x1a\n")
            raw = symbol.read_bytes()
            assert b"Description\0Suite42.TechnicalElement.v1:" in raw
            results["checks"].append("technical symbol exported with a reusable recipe")
            calibration = output / f"{binary.stem}-calibration.pdf"
            command(main, 65511)
            choose_file(process, calibration)
            output_ready(process, main, calibration, b"%PDF-")
            results["checks"].append("calibration sheet exported through the normal menu")
        if pictures and binary.stem.lower() == "xls42":
            audit_sheet_pictures(process, main, output, results)
        if technical:
            audit_technical_objects(process, main, binary, output, results)
        if labels and binary.stem.lower() == "doc42":
            audit_table_labels(process, main, binary, output, results)
        return results
    finally:
        if process.poll() is None:
            for hwnd in windows(process.pid):
                if classname(hwnd) == "Suite42Native":
                    u.PostMessageW(hwnd, WM_CLOSE, 0, 0)
            try:
                process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                process.terminate()
                process.wait(timeout=5)



def capture_window(hwnd, path):
    """Capture the actual test-owned native window as a standalone BMP."""
    gdi = c.WinDLL("gdi32", use_last_error=True)
    u.GetWindowRect.argtypes = [w.HWND, c.POINTER(w.RECT)]
    u.GetWindowDC.argtypes, u.GetWindowDC.restype = [w.HWND], w.HDC
    u.ReleaseDC.argtypes = [w.HWND, w.HDC]
    gdi.CreateCompatibleDC.argtypes, gdi.CreateCompatibleDC.restype = [w.HDC], w.HDC
    gdi.CreateCompatibleBitmap.argtypes, gdi.CreateCompatibleBitmap.restype = [w.HDC, c.c_int, c.c_int], w.HBITMAP
    gdi.SelectObject.argtypes, gdi.SelectObject.restype = [w.HDC, w.HANDLE], w.HANDLE
    gdi.BitBlt.argtypes = [w.HDC, c.c_int, c.c_int, c.c_int, c.c_int, w.HDC, c.c_int, c.c_int, w.DWORD]
    gdi.GetDIBits.argtypes = [w.HDC, w.HBITMAP, w.UINT, w.UINT, c.c_void_p, c.c_void_p, w.UINT]
    gdi.DeleteObject.argtypes, gdi.DeleteDC.argtypes = [w.HANDLE], [w.HDC]
    rect = w.RECT()
    assert u.GetWindowRect(hwnd, c.byref(rect))
    width, height = rect.right - rect.left, rect.bottom - rect.top
    assert 0 < width < 5000 and 0 < height < 5000
    dc = u.GetWindowDC(hwnd)
    target = gdi.CreateCompatibleDC(dc)
    bitmap = gdi.CreateCompatibleBitmap(dc, width, height)
    previous = gdi.SelectObject(target, bitmap)
    try:
        assert gdi.BitBlt(target, 0, 0, width, height, dc, 0, 0, 0x00CC0020)
        gdi.SelectObject(target, previous)
        info = struct.pack("<IiiHHIIiiII", 40, width, height, 1, 32, 0, width * height * 4, 0, 0, 0, 0)
        header = c.create_string_buffer(info)
        pixels = c.create_string_buffer(width * height * 4)
        assert gdi.GetDIBits(dc, bitmap, 0, height, pixels, header, 0) == height
        path.write_bytes(struct.pack("<2sIHHI", b"BM", 54 + len(pixels), 0, 0, 54) + info + pixels.raw)
    finally:
        gdi.SelectObject(target, previous)
        gdi.DeleteObject(bitmap)
        gdi.DeleteDC(target)
        u.ReleaseDC(hwnd, dc)


def audit_language(binary, output, code, index):
    source = output / "language-source.rtf"
    source.write_bytes(br"{\rtf1\ansi Board 0007}")
    environment = os.environ.copy()
    environment["OFF42_UI_TRACE_FILE"] = str(output / f"language-{code}-commands.log")
    process = subprocess.Popen([str(binary), "--language", code, "--", str(source)], env=environment)
    result = {"language": code, "checks": []}
    try:
        main = modal(process, native_class="Suite42Native")
        wait_for(lambda: source.name in text(main) and u.IsWindowEnabled(main), "localized file opening", process)
        catalogs = Path(__file__).resolve().parents[1] / "crates" / "win42" / "resources" / "translations"
        catalog = {} if code == "en" else json.loads((catalogs / (code + ".json")).read_text(encoding="utf-8"))
        u.GetMenu.argtypes, u.GetMenu.restype = [w.HWND], w.HMENU
        u.GetMenuStringW.argtypes = [w.HMENU, w.UINT, w.LPWSTR, c.c_int, w.UINT]
        u.GetMenuState.argtypes = [w.HMENU, w.UINT, w.UINT]
        menu = u.GetMenu(main)
        label = c.create_unicode_buffer(512)
        assert u.GetMenuStringW(menu, 0, label, len(label), 0x400)
        assert label.value.replace("&", "") == catalog.get("File", "File"), (code, label.value)
        assert u.GetMenuState(menu, 64000 + index, 0) & 8, (code, "language not checked")
        assert text(u.GetDlgItem(main, 101)) == "Board 0007", (code, "document text changed")
        result["checks"].append("translated File menu, checked language and unchanged document text")
        command(main, 65509)
        dialog = modal(process, native_class="Suite42InputDialog")
        assert text(u.GetDlgItem(dialog, 2)) == catalog.get("Cancel", "Cancel")
        set_text(u.GetDlgItem(dialog, 101), "PCB-0007")
        set_text(u.GetDlgItem(dialog, 102), "20")
        # Leave the translated Yes choice selected: returning its stable original value is essential.
        if code in {"ru", "ar", "zh-Hans", "zh-Hant", "de", "ja"}:
            u.SetForegroundWindow(dialog)
            time.sleep(0.15)
            capture_window(dialog, output / f"language-{code}.bmp")
        click(dialog, 1)
        wait_for(lambda: u.IsWindowEnabled(main), "localized technical insertion", process)
        command(main, 65508)
        dialog = modal(process, native_class="Suite42InputDialog")
        assert text(u.GetDlgItem(dialog, 101)) == "PCB-0007", (code, "barcode value changed")
        yes = next((value for key, value in catalog.items() if key.lower() == "yes"), "yes")
        assert text(u.GetDlgItem(dialog, 103)) == yes, (code, "choice lost its value")
        click(dialog, 2)
        wait_for(lambda: u.IsWindowEnabled(main), "localized Cancel", process)
        command(main, 4)
        wait_for(lambda: text(u.GetDlgItem(main, 101)) == "Board 0007", "localized Undo preserves text", process)
        result["checks"].append("translated prompt actions and choice survive insertion/edit; barcode payload and text preserved")
        return result
    finally:
        if process.poll() is None:
            process.terminate()
            process.wait(timeout=5)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--bin-dir", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--extended", action="store_true")
    parser.add_argument("--pictures", action="store_true")
    parser.add_argument("--technical-objects", action="store_true")
    parser.add_argument("--label-sources", action="store_true")
    parser.add_argument("--languages", action="store_true")
    args = parser.parse_args()
    args.bin_dir = args.bin_dir.resolve()
    args.output = args.output.resolve()
    args.output.mkdir(parents=True, exist_ok=True)
    results = []
    try:
        for app in ["DOC42", "XLS42", "PDF42", "IMG42", "PPT42", "SCN42"]:
            try:
                results.append(audit(args.bin_dir / (app + ".exe"), args.output, args.extended, args.pictures, args.technical_objects, args.label_sources))
            except Exception as error:
                results.append({"app": app, "error": str(error), "traceback": traceback.format_exc()})
            print(json.dumps(results[-1]), flush=True)
    finally:
        (args.output / "results.json").write_text(json.dumps(results, indent=2), encoding="utf-8")
    if args.languages:
        languages = ["en", "zh-Hans", "zh-Hant", "es", "ar", "fr", "pt", "id", "ru", "de", "ja", "vi", "tr", "fil", "ko", "th", "it", "pl", "ms", "hu"]
        for index, code in enumerate(languages):
            try:
                results.append(audit_language(args.bin_dir / "DOC42.exe", args.output, code, index))
            except Exception as error:
                results.append({"language": code, "error": str(error), "traceback": traceback.format_exc()})
            print(json.dumps(results[-1]), flush=True)
        (args.output / "results.json").write_text(json.dumps(results, indent=2), encoding="utf-8")
    assert all("error" not in result for result in results), results


if __name__ == "__main__":
    main()
